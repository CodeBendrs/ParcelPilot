import CryptoKit
import FirebaseAuth
import FirebaseStorage
import Foundation
import Observation
import ParcelPilotKit
import UIKit

/// Optional proof photos are packets in the account-bound protected SQLite store. JPEG bytes and
/// queue metadata commit together; neither upload success nor local metadata success removes them.
/// Bytes are compacted only after the metadata command has been verified against the server.
@MainActor
@Observable
final class FirebasePhotoStore: PhotoStore {
    private(set) var pending: [PendingPhoto] = []
    private(set) var storageIssue: String?
    private let uid: String
    private let store: RouteStore
    private let connectivity: ConnectivityMonitor
    private let persistence: ActiveRoutePersistence?
    private let currentUserID: () -> String?
    private let legacyDirectory: URL?
    private let legacyFallbackDirectory: URL?
    private var records: [PhotoID: DurablePhotoRecord] = [:]
    private var uploadTasks: [PhotoID: Task<Void, Never>] = [:]
    private var paused = false
    private var cache = NSCache<NSString, UIImage>()
    private let ops: any PhotoObjectTransport

    init(uid: String, store: RouteStore, connectivity: ConnectivityMonitor, storage: Storage = Storage.storage(), baseDirectory: URL? = nil, persistence: ActiveRoutePersistence? = nil, currentUserID: (() -> String?)? = nil, storageOperations: (any PhotoObjectTransport)? = nil, legacyFallbackBaseDirectory: URL? = nil) {
        self.uid = uid
        self.store = store
        self.connectivity = connectivity
        self.persistence = persistence ?? store.operationalPersistence
        self.currentUserID = currentUserID ?? { Auth.auth(app: storage.app).currentUser?.uid }
        self.ops = storageOperations ?? StorageOps(storage: storage)
        let legacyBase = baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        self.legacyDirectory = legacyBase?.appendingPathComponent("PendingUploads/\(uid)", isDirectory: true)
        let fallbackBase = legacyFallbackBaseDirectory ?? (baseDirectory == nil ? FileManager.default.temporaryDirectory : nil)
        self.legacyFallbackDirectory = fallbackBase?.appendingPathComponent("PendingUploads/\(uid)", isDirectory: true)
        do {
            guard let persistence = self.persistence else { throw LocalPersistenceFailure.storage("Protected photo storage is unavailable.") }
            guard persistence.ownerID == uid else { throw LocalPersistenceFailure.ownership }
            // Never silently discard missing, corrupt, unsupported or wrong-account packets.
            records = Dictionary(uniqueKeysWithValues: try persistence.loadPhotos().map { ($0.item.id, $0) })
            for record in records.values { try validate(record) }
            if let legacyDirectory { try migrateLegacyPhotos(from: legacyDirectory) }
            if let legacyFallbackDirectory { try migrateLegacyPhotos(from: legacyFallbackDirectory, sourceKey: "pending-uploads-temporary-fallback-v1") }
            refreshPending()
        } catch {
            storageIssue = "Saved photos need recovery. Original data has been preserved. \(error.localizedDescription)"
            refreshPending()
        }
        connectivity.onChange { [weak self] online in if online { self?.resumeUploads() } }
    }

    static func storagePath(uid: String, routeID: RouteID, photoID: PhotoID) -> String {
        "users/\(uid)/routes/\(routeID)/pod/\(photoID).jpg"
    }

    static func contentHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func validate(_ record: DurablePhotoRecord) throws {
        let item = record.item
        let validID: (String) -> Bool = { $0.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil }
        guard validID(item.id), validID(item.routeID), validID(item.stopID), item.packageIDs.count <= 50,
              item.packageIDs.allSatisfy(validID), item.byteSize > 0, item.byteSize < 5 * 1024 * 1024,
              ["queued", "uploadedAwaitingMetadata", "deleting", "verified"].contains(record.phase) else {
            throw LocalPersistenceFailure.corrupt("Invalid saved photo identity, size or phase.")
        }
        if let bytes = record.bytes {
            guard bytes.count == item.byteSize, Self.contentHash(bytes) == record.contentHash else {
                throw LocalPersistenceFailure.corrupt("Saved photo integrity check failed.")
            }
        }
    }

    private func refreshPending() {
        pending = records.values.map(\.item).sorted {
            ($0.capturedAt, $0.id) < ($1.capturedAt, $1.id)
        }
    }

    private func requireOwner() throws {
        guard !paused, currentUserID() == uid else { throw LocalPersistenceFailure.ownership }
    }

    private func save(_ record: DurablePhotoRecord) throws {
        guard let persistence else { throw LocalPersistenceFailure.storage("Protected photo storage is unavailable.") }
        guard persistence.ownerID == uid else { throw LocalPersistenceFailure.ownership }
        try validate(record)
        try persistence.savePhoto(record)
        records[record.item.id] = record
        refreshPending()
    }

    /// Legacy packets and the migration marker commit in one SQLite transaction. The manifest
    /// remains preserved; missing bytes are represented explicitly rather than filtered away.
    private func migrateLegacyPhotos(from directory: URL, sourceKey: String = "pending-uploads-manifest-v1") throws {
        guard let persistence else { throw LocalPersistenceFailure.storage("Protected photo storage is unavailable.") }
        guard try !persistence.hasLegacyPhotoMigration(sourceKey: sourceKey) else { return }
        let manifest = directory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return }
        var protectedDirectory = directory
        var backupPolicy = URLResourceValues(); backupPolicy.isExcludedFromBackup = true
        try protectedDirectory.setResourceValues(backupPolicy)
        let old = try JSONDecoder.appStorage.decode([PendingPhoto].self, from: Data(contentsOf: manifest))
        guard Set(old.map(\.id)).count == old.count else { throw LocalPersistenceFailure.corrupt("Duplicate legacy photo IDs.") }
        var imported: [DurablePhotoRecord] = []
        for original in old {
            guard original.id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil,
                  original.routeID.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else {
                throw LocalPersistenceFailure.corrupt("Invalid legacy photo identity.")
            }
            let file = directory.appendingPathComponent("\(original.id).jpg")
            var item = original
            let bytes: Data?
            if FileManager.default.fileExists(atPath: file.path) { bytes = try Data(contentsOf: file) }
            else {
                bytes = nil
                item.lastError = "The saved photo file is missing. Retake this optional photo or delete its pending entry."
            }
            let record = DurablePhotoRecord(item: item, bytes: bytes, contentHash: bytes.map(Self.contentHash))
            try validate(record)
            imported.append(record)
        }
        try persistence.importLegacyPhotos(imported, sourceKey: sourceKey)
        records = Dictionary(uniqueKeysWithValues: try persistence.loadPhotos().map { ($0.item.id, $0) })
    }

    func add(jpeg: Data, routeID: RouteID, stopID: StopID, packageIDs: [PackageID]) throws -> PhotoID {
        try requireOwner()
        if storageIssue != nil {
            do { try recoverQueue() } catch { throw ServiceError.unavailable(storageIssue ?? error.localizedDescription) }
        }
        guard !jpeg.isEmpty, jpeg.count < 5 * 1024 * 1024 else { throw ServiceError.invalid("The photo must be a JPEG smaller than 5 MB.") }
        guard let snapshot = store.current, snapshot.route.id == routeID,
              store.currentReadIssues.isEmpty, snapshot.stops.contains(where: { $0.id == stopID }),
              packageIDs.allSatisfy({ id in snapshot.packages.contains { $0.id == id && $0.stopID == stopID } }) else {
            throw ServiceError.invalid("Open this photo's route and stop before saving it.")
        }
        let id = StableID.make()
        let item = PendingPhoto(id: id, routeID: routeID, stopID: stopID, packageIDs: packageIDs, capturedAt: Date(), byteSize: jpeg.count, attempts: 0, lastError: nil)
        // This is the UI success boundary: one SQLite transaction contains bytes AND intent.
        try save(DurablePhotoRecord(item: item, bytes: jpeg, contentHash: Self.contentHash(jpeg)))
        resumeUploads()
        return id
    }

    private func recoverQueue() throws {
        guard let persistence, persistence.ownerID == uid else { throw LocalPersistenceFailure.ownership }
        let saved = try persistence.loadPhotos()
        for record in saved { try validate(record) }
        records = Dictionary(uniqueKeysWithValues: saved.map { ($0.item.id, $0) })
        if let legacyDirectory { try migrateLegacyPhotos(from: legacyDirectory) }
        if let legacyFallbackDirectory { try migrateLegacyPhotos(from: legacyFallbackDirectory, sourceKey: "pending-uploads-temporary-fallback-v1") }
        storageIssue = nil
        refreshPending()
    }

    func resumeUploads() {
        guard !paused, currentUserID() == uid else { return }
        if storageIssue != nil {
            do { try recoverQueue() } catch { storageIssue = error.localizedDescription; return }
        }
        guard connectivity.isOnline else { return }
        for item in pending where uploadTasks[item.id] == nil {
            uploadTasks[item.id] = Task { [weak self] in await self?.upload(item.id) }
        }
    }

    private func upload(_ id: PhotoID) async {
        let phaseAtStart = records[id]?.phase
        defer {
            uploadTasks[id] = nil
            // A user may cancel capture while the SDK upload is finishing. Process its durable
            // deletion after the cancelled uploader exits, without racing the two operations.
            if phaseAtStart != "deleting", records[id]?.phase == "deleting" { resumeUploads() }
        }
        guard var record = records[id] else { return }
        do {
            try requireOwner()
            try Task.checkCancellation()
            if record.phase == "verified" {
                try removeVerified(record)
                return
            }
            if record.phase == "deleting" {
                try await synchronizeDeletion(record)
                return
            }
            guard record.phase == "queued" || record.phase == "uploadedAwaitingMetadata" else {
                throw LocalPersistenceFailure.corrupt("Unsupported saved photo phase.")
            }
            guard let bytes = record.bytes else { throw ServiceError.unavailable("The saved photo file is missing. Retake this optional photo or delete its pending entry.") }
            let hash = Self.contentHash(bytes)
            guard bytes.count == record.item.byteSize, hash == record.contentHash else {
                throw LocalPersistenceFailure.corrupt("Saved photo integrity check failed.")
            }
            let path = Self.storagePath(uid: uid, routeID: record.item.routeID, photoID: id)
            if try await !ops.matches(path: path, data: bytes, contentHash: hash) {
                try requireOwner()
                try Task.checkCancellation()
                try await ops.uploadJPEG(path: path, data: bytes, contentHash: hash)
                guard try await ops.matches(path: path, data: bytes, contentHash: hash) else {
                    throw ServiceError.unavailable("Photo upload could not be verified. The photo remains saved on this iPhone.")
                }
            }
            try requireOwner()
            try Task.checkCancellation()
            record.phase = "uploadedAwaitingMetadata"
            record.item.lastError = nil
            try save(record)
            let photo = DeliveryPhoto(id: id, stopID: record.item.stopID, packageIDs: record.item.packageIDs, storagePath: path, byteSize: record.item.byteSize, capturedAt: record.item.capturedAt)
            // A verified command may have been compacted on relaunch. Reissuing the exact stable
            // photo document is safe; a missing local receipt is never treated as acknowledgement.
            if let commandID = record.metadataCommandID, store.commandStatus(id: commandID) == nil {
                record.metadataCommandID = nil
            }
            if record.metadataCommandID == nil {
                let result = store.commitPhotoChange(record, ops: [.putPhoto(record.item.routeID, photo)], label: "Proof-of-delivery photo")
                switch result {
                case let .failed(error): throw error
                case let .committed(ack):
                    guard let commandID = ack.commandIDs.last else {
                        throw ServiceError.unavailable("Photo metadata has no durable verification receipt. The photo remains saved on this iPhone.")
                    }
                    record.metadataCommandID = commandID
                    records[id] = record
                    refreshPending()
                }
            }
            guard let commandID = record.metadataCommandID else { return }
            // Bounded polling only waits for the existing outbox; it sends no duplicate network
            // writes. Unknown/offline verification remains pending and is resumed later.
            for _ in 0..<40 {
                try requireOwner()
                try Task.checkCancellation()
                switch store.commandStatus(id: commandID) {
                case .verified:
                    record.phase = "verified"
                    try save(record)
                    try removeVerified(record)
                    return
                case .blocked:
                    throw ServiceError.rejected("The server rejected this photo's metadata. The photo is still saved on this iPhone; retry after resolving the route sync issue.")
                case .authentication:
                    throw LocalPersistenceFailure.ownership
                default: break
                }
                guard connectivity.isOnline else { return }
                try await Task.sleep(for: .milliseconds(200))
            }
        } catch is CancellationError {
            // Cancellation/sign-out preserves the existing durable packet.
        } catch {
            guard var latest = records[id] else { return }
            latest.item.attempts += 1
            latest.item.lastError = error.localizedDescription
            do { try save(latest) } catch {
                storageIssue = "Couldn't update saved photo status. The original photo is preserved. \(error.localizedDescription)"
            }
            AppLog.storage.error("Photo synchronization remains pending: \((error as NSError).code, privacy: .public)")
        }
    }

    private func removeVerified(_ record: DurablePhotoRecord) throws {
        guard record.phase == "verified", let persistence else { return }
        guard persistence.ownerID == uid else { throw LocalPersistenceFailure.ownership }
        if let bytes = record.bytes, let image = UIImage(data: bytes) { cache.setObject(image, forKey: record.item.id as NSString) }
        for originalDirectory in [legacyDirectory, legacyFallbackDirectory].compactMap({ $0 }) {
            let original = originalDirectory.appendingPathComponent("\(record.item.id).jpg")
            if FileManager.default.fileExists(atPath: original.path) { try FileManager.default.removeItem(at: original) }
        }
        try persistence.removePhoto(id: record.item.id)
        records[record.item.id] = nil
        refreshPending()
    }

    func pendingImage(_ id: PhotoID) -> UIImage? {
        guard !paused, currentUserID() == uid, let data = records[id]?.bytes else { return nil }
        return UIImage(data: data)
    }

    func image(for photo: DeliveryPhoto, routeID: RouteID) async throws -> UIImage {
        try requireOwner()
        if let cached = cache.object(forKey: photo.id as NSString) { return cached }
        if let local = pendingImage(photo.id) { return local }
        guard photo.storagePath == Self.storagePath(uid: uid, routeID: routeID, photoID: photo.id) else { throw LocalPersistenceFailure.ownership }
        let data = try await ops.download(path: photo.storagePath, maxSize: 5 * 1024 * 1024)
        try requireOwner()
        guard let image = UIImage(data: data) else { throw ServiceError.unavailable("The photo couldn't be opened.") }
        cache.setObject(image, forKey: photo.id as NSString)
        return image
    }

    func delete(photo: DeliveryPhoto, routeID: RouteID) async throws {
        try requireOwner()
        if storageIssue != nil { try recoverQueue() }
        guard photo.storagePath == Self.storagePath(uid: uid, routeID: routeID, photoID: photo.id) else { throw LocalPersistenceFailure.ownership }
        // The cleanup packet is durable before metadata mutation, so termination cannot lose the
        // remote object deletion. Its stable photo ID makes both retries idempotent.
        let item = PendingPhoto(id: photo.id, routeID: routeID, stopID: photo.stopID, packageIDs: photo.packageIDs, capturedAt: photo.capturedAt, byteSize: photo.byteSize, attempts: 0, lastError: "Photo deletion is saved on this iPhone and waiting to sync.")
        var record = DurablePhotoRecord(item: item, bytes: nil, contentHash: nil, phase: "deleting")
        let result = store.commitPhotoChange(record, ops: [.deletePhoto(routeID, photo.id)], label: "Delete photo")
        if case let .failed(error) = result { throw error }
        record.metadataCommandID = result.commandIDs.last
        records[photo.id] = record
        refreshPending()
        cache.removeObject(forKey: photo.id as NSString)
        resumeUploads()
    }

    private func synchronizeDeletion(_ original: DurablePhotoRecord) async throws {
        var record = original
        if let commandID = record.metadataCommandID, store.commandStatus(id: commandID) == nil {
            record.metadataCommandID = nil
        }
        if record.metadataCommandID == nil {
            let result = store.commitPhotoChange(record, ops: [.deletePhoto(record.item.routeID, record.item.id)], label: "Delete photo")
            if case let .failed(error) = result { throw error }
            guard let commandID = result.commandIDs.last else { throw ServiceError.unavailable("Photo deletion is awaiting a durable server receipt.") }
            record.metadataCommandID = commandID
            records[record.item.id] = record
            refreshPending()
        }
        guard let commandID = record.metadataCommandID else { return }
        for _ in 0..<40 {
            try requireOwner()
            try Task.checkCancellation()
            switch store.commandStatus(id: commandID) {
            case .verified:
                let path = Self.storagePath(uid: uid, routeID: record.item.routeID, photoID: record.item.id)
                do { try await ops.delete(path: path) }
                catch let error as NSError where error.domain == StorageErrorDomain && error.code == StorageErrorCode.objectNotFound.rawValue { }
                try requireOwner()
                try Task.checkCancellation()
                guard try await ops.isMissing(path: path) else { return }
                record.phase = "verified"
                try save(record)
                try removeVerified(record)
                return
            case .blocked: throw ServiceError.rejected("The server rejected photo deletion. Its saved intent needs recovery.")
            case .authentication: throw LocalPersistenceFailure.ownership
            default: break
            }
            guard connectivity.isOnline else { return }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    func deletePending(_ id: PhotoID) {
        do {
            try requireOwner()
            guard var record = records[id] else { return }
            // Metadata might already be queued, or an SDK upload might finish after cancellation.
            // Persist an ordered deletion instead of dropping the only cleanup reference.
            record.phase = "deleting"
            record.bytes = nil
            record.contentHash = nil
            record.metadataCommandID = nil
            record.item.lastError = "Photo deletion is saved on this iPhone and waiting to sync."
            let result = store.commitPhotoChange(record, ops: [.deletePhoto(record.item.routeID, id)], label: "Delete pending photo")
            if case let .failed(error) = result { throw error }
            record.metadataCommandID = result.commandIDs.last
            records[id] = record
            refreshPending()
            uploadTasks[id]?.cancel()
            resumeUploads()
        } catch { storageIssue = error.localizedDescription }
    }

    /// Only the explicit successful account-deletion flow calls this. Logout calls eraseLocal,
    /// retaining the original account's protected proof packets and migration recovery copies.
    func eraseLegacyFilesAfterAccountDeletion() throws {
        eraseLocal()
        for directory in [legacyDirectory, legacyFallbackDirectory].compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        }
    }

    /// Called by account cleanup. Logout quarantines proof data; it never erases unsynchronized
    /// bytes. The new account graph has a separate owner-bound store and cannot see this queue.
    func eraseLocal() {
        paused = true
        for task in uploadTasks.values { task.cancel() }
        cache.removeAllObjects()
    }
}

/// Storage calls happen through locally constructed references. Existing objects are checked by
/// content hash (legacy objects without hash metadata are downloaded and hashed).
nonisolated protocol PhotoObjectTransport: Sendable {
    func matches(path: String, data: Data, contentHash: String) async throws -> Bool
    func uploadJPEG(path: String, data: Data, contentHash: String?) async throws
    func download(path: String, maxSize: Int64) async throws -> Data
    func delete(path: String) async throws
    func isMissing(path: String) async throws -> Bool
}

nonisolated struct StorageOps: PhotoObjectTransport, @unchecked Sendable {
    let storage: Storage

    func exists(path: String) async -> Bool {
        (try? await storage.reference(withPath: path).getMetadata()) != nil
    }

    func isMissing(path: String) async throws -> Bool {
        do { _ = try await storage.reference(withPath: path).getMetadata(); return false }
        catch let error as NSError where error.domain == StorageErrorDomain && error.code == StorageErrorCode.objectNotFound.rawValue { return true }
    }

    func matches(path: String, data: Data, contentHash: String) async throws -> Bool {
        let metadata: StorageMetadata
        do { metadata = try await storage.reference(withPath: path).getMetadata() }
        catch let error as NSError where error.domain == StorageErrorDomain && error.code == StorageErrorCode.objectNotFound.rawValue { return false }
        guard metadata.size == Int64(data.count), metadata.contentType == "image/jpeg" else {
            throw ServiceError.rejected("A different photo already uses this photo ID. The saved photo needs recovery.")
        }
        if let declaredHash = metadata.customMetadata?["sha256"], declaredHash != contentHash {
            throw ServiceError.rejected("A different photo already uses this photo ID. The saved photo needs recovery.")
        }
        // Custom metadata is client-declared. Use the server-calculated object checksum as
        // transfer-integrity evidence, or hash the actual downloaded object if unavailable.
        if let md5 = metadata.md5Hash {
            guard md5 == Data(Insecure.MD5.hash(data: data)).base64EncodedString() else {
                throw ServiceError.rejected("A different photo already uses this photo ID. The saved photo needs recovery.")
            }
        } else {
            let downloaded = try await download(path: path, maxSize: 5 * 1024 * 1024)
            let remoteHash = SHA256.hash(data: downloaded).map { String(format: "%02x", $0) }.joined()
            guard remoteHash == contentHash else { throw ServiceError.rejected("A different photo already uses this photo ID. The saved photo needs recovery.") }
        }
        return true
    }

    func uploadJPEG(path: String, data: Data, contentHash: String? = nil) async throws {
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"
        if let contentHash { metadata.customMetadata = ["sha256": contentHash] }
        _ = try await storage.reference(withPath: path).putDataAsync(data, metadata: metadata)
    }

    func download(path: String, maxSize: Int64) async throws -> Data {
        try await storage.reference(withPath: path).data(maxSize: maxSize)
    }

    func delete(path: String) async throws {
        try await storage.reference(withPath: path).delete()
    }
}

/// Re-encodes a captured image as a bounded JPEG. Re-encoding drops EXIF metadata (including GPS).
enum PhotoEncoder {
    static func jpeg(from image: UIImage, maxDimension: CGFloat = 1600, quality: CGFloat = 0.7) -> Data? {
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return rendered.jpegData(compressionQuality: quality)
    }
}
