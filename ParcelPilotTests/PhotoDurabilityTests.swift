import CryptoKit
import FirebaseCore
import FirebaseStorage
import Foundation
import ParcelPilotKit
import Testing
import UIKit
@testable import ParcelPilot

@Suite("Protected optional photos", .serialized)
@MainActor
struct PhotoDurabilityTests {
    final class Owner { var id: String? = "photo-owner" }

    final class MetadataTransport: DurableCommandTransport {
        var photoResult: RemoteReplayResult = .retryable("Metadata unavailable.")
        func replay(_ command: DurableCommand) async -> RemoteReplayResult {
            if command.ops.contains(where: { op in if case .putPhoto = op { true } else { false } }) { return photoResult }
            return .verified
        }
        func fetchVerifiedRoute(_ id: RouteID) async throws -> RouteSnapshot? { throw ServiceError.offline }
    }

    actor Objects: PhotoObjectTransport {
        var objects: [String: Data] = [:]
        private(set) var uploads = 0
        var deletionFailure: String?
        func failDeletion(_ message: String?) { deletionFailure = message }
        func matches(path: String, data: Data, contentHash: String) async throws -> Bool {
            guard let bytes = objects[path] else { return false }
            guard bytes == data, SHA256Digest(bytes) == contentHash else { throw ServiceError.rejected("Conflicting photo ID.") }
            return true
        }
        func uploadJPEG(path: String, data: Data, contentHash: String?) async throws { objects[path] = data; uploads += 1 }
        func download(path: String, maxSize: Int64) async throws -> Data {
            guard let bytes = objects[path] else { throw ServiceError.unavailable("Missing object.") }
            return bytes
        }
        func delete(path: String) async throws {
            if let deletionFailure { throw ServiceError.permission(deletionFailure) }
            objects[path] = nil
        }
        func isMissing(path: String) async throws -> Bool { objects[path] == nil }
        private func SHA256Digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    }

    struct Fixture {
        let directory: URL
        let database: ActiveRoutePersistence
        let backend: DurableRouteBackend
        let store: RouteStore
        let owner = Owner()
        let transport = MetadataTransport()
        let objects = Objects()
        let storage: Storage
        let snapshot: RouteSnapshot

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("pp-photo-durability-\(UUID().uuidString)")
            let source = TestEnvironment(directory: directory.appendingPathComponent("source"))
            _ = source.makeRoute()
            source.store.addDelivery(to: source.snapshot, address: .e1(), status: .pendingVerification, resolution: nil, reviewReasons: [], packages: [PackageDraft()], source: .manual)
            snapshot = source.snapshot
            database = try ActiveRoutePersistence(ownerID: "photo-owner", databaseURL: directory.appendingPathComponent("operations.sqlite"))
            try database.pin(snapshot, selected: true)
            let owner = self.owner
            backend = DurableRouteBackend(remote: source.backend, ownerID: "photo-owner", persistence: database, transport: transport, authenticatedOwner: { owner.id })
            store = RouteStore(backend: backend)
            store.currentRouteID = snapshot.route.id
            let options = FirebaseOptions(googleAppID: "1:123:ios:abcdef123456", gcmSenderID: "123")
            options.apiKey = "AIzaSyEmulatorOnlyNotARealKey0000000000"
            options.projectID = "demo-parcelpilot"
            options.storageBucket = "demo-parcelpilot.appspot.com"
            let appName = "photos-\(UUID().uuidString)"
            FirebaseApp.configure(name: appName, options: options)
            storage = Storage.storage(app: FirebaseApp.app(name: appName)!)
            storage.useEmulator(withHost: "127.0.0.1", port: 9199)
        }

        func photos(online: Bool = false, database: ActiveRoutePersistence? = nil, fallback: URL? = nil) -> FirebasePhotoStore {
            let owner = self.owner
            return FirebasePhotoStore(uid: "photo-owner", store: store, connectivity: ConnectivityMonitor(forceOffline: !online), storage: storage, baseDirectory: directory, persistence: database ?? self.database, currentUserID: { owner.id }, storageOperations: objects, legacyFallbackBaseDirectory: fallback)
        }

        func add(to photos: FirebasePhotoStore) throws -> PhotoID {
            try photos.add(jpeg: Self.jpeg, routeID: snapshot.route.id, stopID: snapshot.stops[0].id, packageIDs: snapshot.packages.map(\.id))
        }

        static var jpeg: Data {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 10)).image { context in
                UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
            }
            return PhotoEncoder.jpeg(from: image)!
        }
    }

    private func eventually(_ predicate: () async throws -> Bool) async throws -> Bool {
        for _ in 0..<80 {
            if try await predicate() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @Test("Capture acknowledgement contains photo bytes and intent, and both restore offline")
    func durableCapture() throws {
        let fixture = try Fixture()
        let photos = fixture.photos()
        let id = try fixture.add(to: photos)
        let saved = try #require(fixture.database.loadPhotos().first)
        #expect(saved.item.id == id)
        #expect(saved.bytes == Fixture.jpeg)
        #expect(saved.contentHash == ActiveRoutePersistence.digest(Fixture.jpeg))
        let reopened = try ActiveRoutePersistence(ownerID: "photo-owner", databaseURL: fixture.database.databaseURL)
        let relaunched = fixture.photos(database: reopened)
        #expect(relaunched.pending.map(\.id) == [id])
        #expect(relaunched.pendingImage(id) != nil)
        #expect(try reopened.loadPhotos().first?.bytes == saved.bytes)
    }

    @Test("Failed photo transaction never reports capture success or publishes a pending photo")
    func failedCapture() throws {
        let fixture = try Fixture()
        let photos = fixture.photos()
        fixture.database.injectFailure = { point in if case .beforeCommit = point { throw LocalPersistenceFailure.storage("Disk full.") } }
        #expect(throws: (any Error).self) { try fixture.add(to: photos) }
        #expect(photos.pending.isEmpty)
        fixture.database.injectFailure = nil
        #expect(try fixture.database.loadPhotos().isEmpty)
        let reopened = try ActiveRoutePersistence(ownerID: "photo-owner", databaseURL: fixture.database.databaseURL)
        #expect(try reopened.loadPhotos().isEmpty)
    }

    @Test("Logout quarantines pending proof; a different account cannot capture, view or upload it")
    func ownershipAndLogout() async throws {
        let fixture = try Fixture()
        let photos = fixture.photos()
        let id = try fixture.add(to: photos)
        photos.eraseLocal()
        #expect(try fixture.database.loadPhotos().count == 1)
        fixture.owner.id = "another-user"
        let otherAccount = fixture.photos(online: true)
        #expect(throws: LocalPersistenceFailure.ownership) { try fixture.add(to: otherAccount) }
        #expect(otherAccount.pendingImage(id) == nil)
        otherAccount.resumeUploads()
        #expect(await fixture.objects.uploads == 0)
        #expect(try fixture.database.loadPhotos().first?.bytes != nil)
    }

    @Test("Frozen legacy manifest migrates once; missing photo bytes stay visible")
    func legacyMigration() throws {
        let fixture = try Fixture()
        let directory = fixture.directory.appendingPathComponent("PendingUploads/photo-owner")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let present = PendingPhoto(id: "legacy-photo", routeID: fixture.snapshot.route.id, stopID: fixture.snapshot.stops[0].id, packageIDs: [], capturedAt: Date(timeIntervalSince1970: 1_700_000_000), byteSize: Fixture.jpeg.count, attempts: 2, lastError: nil)
        var missing = present; missing.id = "missing-photo"
        // Frozen pre-WP2 wire shape; only fixture identities and JPEG byte length vary.
        let legacyJSON = """
        [{"id":"legacy-photo","routeID":"\(fixture.snapshot.route.id)","stopID":"\(fixture.snapshot.stops[0].id)","packageIDs":[],"capturedAt":1700000000,"byteSize":\(Fixture.jpeg.count),"attempts":2},
         {"id":"missing-photo","routeID":"\(fixture.snapshot.route.id)","stopID":"\(fixture.snapshot.stops[0].id)","packageIDs":[],"capturedAt":1700000000,"byteSize":\(Fixture.jpeg.count),"attempts":2}]
        """
        try Data(legacyJSON.utf8).write(to: directory.appendingPathComponent("manifest.json"))
        try Fixture.jpeg.write(to: directory.appendingPathComponent("legacy-photo.jpg"))
        let photos = fixture.photos()
        #expect(photos.storageIssue == nil)
        #expect(Set(photos.pending.map(\.id)) == ["legacy-photo", "missing-photo"])
        let saved = try fixture.database.loadPhotos()
        #expect(saved.first { $0.item.id == present.id }?.bytes == Fixture.jpeg)
        #expect(saved.first { $0.item.id == missing.id }?.bytes == nil)
        #expect(saved.first { $0.item.id == missing.id }?.item.lastError?.contains("missing") == true)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("legacy-photo.jpg").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path))
        #expect(try fixture.database.hasLegacyPhotoMigration(sourceKey: "pending-uploads-manifest-v1"))
        let relaunched = fixture.photos()
        #expect(relaunched.pending.count == 2)
        #expect(try fixture.database.loadPhotos().count == 2)
    }

    @Test("Legacy temporary-directory photos are salvaged when the new primary directory is empty")
    func temporaryFallbackMigration() throws {
        let fixture = try Fixture()
        let fallback = fixture.directory.appendingPathComponent("old-temporary")
        let oldDirectory = fallback.appendingPathComponent("PendingUploads/photo-owner")
        try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        let item = PendingPhoto(id: "temporary-photo", routeID: fixture.snapshot.route.id, stopID: fixture.snapshot.stops[0].id, packageIDs: [], capturedAt: Date(), byteSize: Fixture.jpeg.count, attempts: 0, lastError: nil)
        let manifest = oldDirectory.appendingPathComponent("manifest.json")
        try JSONEncoder.appStorage.encode([item]).write(to: manifest)
        let original = oldDirectory.appendingPathComponent("temporary-photo.jpg")
        try Fixture.jpeg.write(to: original)
        let photos = fixture.photos(fallback: fallback)
        #expect(photos.storageIssue == nil)
        #expect(photos.pending.map(\.id) == [item.id])
        #expect(try fixture.database.loadPhotos().first?.bytes == Fixture.jpeg)
        #expect(try fixture.database.hasLegacyPhotoMigration(sourceKey: "pending-uploads-temporary-fallback-v1"))
        #expect(FileManager.default.fileExists(atPath: manifest.path))
        #expect(try Data(contentsOf: original) == Fixture.jpeg)
        let relaunched = fixture.photos(fallback: fallback)
        #expect(relaunched.pending.count == 1)
        #expect(try fixture.database.loadPhotos().count == 1)
    }

    @Test("Corrupt legacy bytes are preserved and prevent a false photo-saved acknowledgement")
    func corruptLegacyManifest() throws {
        let fixture = try Fixture()
        let directory = fixture.directory.appendingPathComponent("PendingUploads/photo-owner")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("broken manifest".utf8)
        let url = directory.appendingPathComponent("manifest.json")
        try original.write(to: url)
        let photos = fixture.photos()
        #expect(photos.storageIssue != nil)
        #expect(throws: (any Error).self) { try fixture.add(to: photos) }
        #expect(try Data(contentsOf: url) == original)
        #expect(try fixture.database.loadPhotos().isEmpty)
    }

    @Test("Interrupted photo migration is restart-safe and keeps original files")
    func interruptedMigration() throws {
        let fixture = try Fixture()
        let directory = fixture.directory.appendingPathComponent("PendingUploads/photo-owner")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let item = PendingPhoto(id: "legacy-interrupted", routeID: fixture.snapshot.route.id, stopID: fixture.snapshot.stops[0].id, packageIDs: [], capturedAt: Date(), byteSize: Fixture.jpeg.count, attempts: 0, lastError: nil)
        let manifest = directory.appendingPathComponent("manifest.json")
        try JSONEncoder.appStorage.encode([item]).write(to: manifest)
        try Fixture.jpeg.write(to: directory.appendingPathComponent("legacy-interrupted.jpg"))
        fixture.database.injectFailure = { point in if case .beforeCommit = point { throw LocalPersistenceFailure.storage("Unavailable storage.") } }
        let failed = fixture.photos()
        #expect(failed.storageIssue != nil)
        #expect(FileManager.default.fileExists(atPath: manifest.path))
        fixture.database.injectFailure = nil
        let recovered = fixture.photos()
        #expect(recovered.storageIssue == nil)
        #expect(recovered.pending.map(\.id) == [item.id])
        #expect(try fixture.database.loadPhotos().count == 1)
    }

    @Test("Unsupported photo phase or invalid content hash blocks capture and retains the packet", arguments: ["future-phase", "invalid-hash"])
    func invalidPacket(reason: String) throws {
        let fixture = try Fixture()
        let item = PendingPhoto(id: "invalid-photo", routeID: fixture.snapshot.route.id, stopID: fixture.snapshot.stops[0].id, packageIDs: [], capturedAt: Date(), byteSize: Fixture.jpeg.count, attempts: 0, lastError: nil)
        let record = DurablePhotoRecord(item: item, bytes: Fixture.jpeg, contentHash: reason == "invalid-hash" ? "bad" : ActiveRoutePersistence.digest(Fixture.jpeg), phase: reason == "future-phase" ? "future" : "queued")
        try fixture.database.savePhoto(record)
        let persisted = try #require(fixture.database.loadPhotos().first)
        #expect(persisted.bytes == record.bytes && persisted.phase == record.phase && persisted.contentHash == record.contentHash)
        #expect(abs(persisted.item.capturedAt.timeIntervalSince(record.item.capturedAt)) < 0.000_002)
        let photos = fixture.photos()
        #expect(photos.storageIssue != nil)
        #expect(photos.pending.map(\.id) == [item.id])
        #expect(throws: (any Error).self) { try fixture.add(to: photos) }
        #expect(try fixture.database.loadPhotos().first == persisted)
    }

    @Test("Uploaded bytes remain durable when metadata is rejected")
    func uploadedMetadataRejected() async throws {
        let fixture = try Fixture()
        fixture.transport.photoResult = .blocked("Permission denied.")
        let offline = fixture.photos()
        let id = try fixture.add(to: offline)
        let online = fixture.photos(online: true)
        online.resumeUploads()
        #expect(try await eventually { online.pending.first?.lastError?.contains("rejected") == true })
        let record = try #require(fixture.database.loadPhotos().first)
        #expect(record.item.id == id)
        #expect(record.bytes == Fixture.jpeg)
        #expect(record.phase == "uploadedAwaitingMetadata")
        #expect(record.metadataCommandID != nil)
        #expect(await fixture.objects.uploads == 1)
        online.eraseLocal()
        let relaunched = fixture.photos()
        #expect(relaunched.pending.map(\.id) == [id])
        #expect(relaunched.pendingImage(id) != nil)
    }

    @Test("Metadata retry after restart reuses the uploaded object and only verified proof compacts")
    func metadataRetryAfterRestart() async throws {
        let fixture = try Fixture()
        let id = try fixture.add(to: fixture.photos())
        let first = fixture.photos(online: true)
        first.resumeUploads()
        #expect(try await eventually { try fixture.database.loadPhotos().first?.metadataCommandID != nil })
        first.eraseLocal()
        let pending = try #require(fixture.database.loadPhotos().first)
        let commandID = try #require(pending.metadataCommandID)
        #expect(pending.bytes != nil)
        fixture.transport.photoResult = .verified
        #expect(fixture.backend.retry(commandID: commandID).isCommitted)
        let relaunched = fixture.photos(online: true)
        relaunched.resumeUploads()
        #expect(try await eventually { relaunched.pending.isEmpty })
        #expect(await fixture.objects.uploads == 1)
        #expect(try fixture.database.loadPhotos().isEmpty)
        #expect(fixture.store.current?.photos.map(\.id) == [id])
    }

    @Test("Deleting an uploaded pending photo durably orders cleanup after its metadata command")
    func deleteUploadedPendingPhoto() async throws {
        let fixture = try Fixture()
        let id = try fixture.add(to: fixture.photos())
        let online = fixture.photos(online: true)
        online.resumeUploads()
        #expect(try await eventually { try fixture.database.loadPhotos().first?.metadataCommandID != nil })
        let putID = try #require(fixture.database.loadPhotos().first?.metadataCommandID)
        online.deletePending(id)
        let deletion = try #require(fixture.database.loadPhotos().first)
        #expect(deletion.phase == "deleting")
        #expect(deletion.bytes == nil) // Explicit cancellation permits removal of local image data.
        #expect(fixture.store.current?.photos.isEmpty == true)
        let commands = try fixture.database.commands(routeID: fixture.snapshot.route.id)
        let put = try #require(commands.first { $0.id == putID })
        let delete = try #require(commands.first { $0.id == deletion.metadataCommandID })
        #expect(put.sequence < delete.sequence)
        online.eraseLocal()
        fixture.transport.photoResult = .verified
        #expect(fixture.backend.retry(commandID: putID).isCommitted)
        let relaunched = fixture.photos(online: true)
        relaunched.resumeUploads()
        #expect(try await eventually { relaunched.pending.isEmpty })
        let path = FirebasePhotoStore.storagePath(uid: "photo-owner", routeID: fixture.snapshot.route.id, photoID: id)
        #expect(try await fixture.objects.isMissing(path: path))
        #expect(try fixture.database.loadPhotos().isEmpty)
    }

    @Test("Failed metadata transaction leaves packet, protected photo state and outbox unchanged")
    func atomicMetadataFailure() throws {
        let fixture = try Fixture()
        let id = try fixture.add(to: fixture.photos())
        let before = try #require(fixture.database.loadPhotos().first)
        var attempted = before; attempted.phase = "uploadedAwaitingMetadata"
        let photo = DeliveryPhoto(id: id, stopID: before.item.stopID, packageIDs: before.item.packageIDs, storagePath: FirebasePhotoStore.storagePath(uid: "photo-owner", routeID: before.item.routeID, photoID: id), byteSize: before.item.byteSize, capturedAt: before.item.capturedAt)
        fixture.database.injectFailure = { point in if case .beforeCommit = point { throw LocalPersistenceFailure.storage("Disk full.") } }
        #expect(!fixture.store.commitPhotoChange(attempted, ops: [.putPhoto(before.item.routeID, photo)], label: "Proof").isCommitted)
        fixture.database.injectFailure = nil
        #expect(try fixture.database.loadPhotos().first == before)
        #expect(try fixture.database.commands().isEmpty)
        #expect(fixture.store.current?.photos.isEmpty == true)
    }

    @Test("Storage deletion denial keeps durable cleanup intent visible across restart")
    func storageDeletionFailure() async throws {
        let fixture = try Fixture()
        fixture.transport.photoResult = .verified
        let id = try fixture.add(to: fixture.photos())
        let online = fixture.photos(online: true)
        online.resumeUploads()
        #expect(try await eventually { online.pending.isEmpty })
        let photo = try #require(fixture.store.current?.photos.first { $0.id == id })
        await fixture.objects.failDeletion("Photo storage permission denied.")
        try await online.delete(photo: photo, routeID: fixture.snapshot.route.id)
        #expect(try await eventually { online.pending.first?.lastError?.contains("permission denied") == true })
        let saved = try #require(fixture.database.loadPhotos().first)
        #expect(saved.phase == "deleting")
        #expect(saved.metadataCommandID != nil)
        online.eraseLocal()
        let relaunched = fixture.photos()
        #expect(relaunched.pending.map(\.id) == [id])
        #expect(relaunched.pending.first?.lastError?.contains("permission denied") == true)
        await fixture.objects.failDeletion(nil)
        let recovered = fixture.photos(online: true)
        recovered.resumeUploads()
        #expect(try await eventually { recovered.pending.isEmpty })
    }

    @Test("A verified metadata receipt remains until its photo packet is compacted")
    func receiptRetention() throws {
        let fixture = try Fixture()
        let id = try fixture.add(to: fixture.photos())
        let photo = DeliveryPhoto(id: id, stopID: fixture.snapshot.stops[0].id, packageIDs: [], storagePath: FirebasePhotoStore.storagePath(uid: "photo-owner", routeID: fixture.snapshot.route.id, photoID: id), byteSize: Fixture.jpeg.count, capturedAt: Date())
        let ack = try fixture.database.commit([ChangeSet([.putPhoto(fixture.snapshot.route.id, photo)], label: "Proof")], synchronize: true)
        let commandID = try #require(ack.commandIDs.first)
        var command = try #require(fixture.database.commands().first { $0.id == commandID })
        command.state = .verified; try fixture.database.update(command)
        var packet = try #require(fixture.database.loadPhotos().first)
        packet.metadataCommandID = commandID; try fixture.database.savePhoto(packet)
        try fixture.database.compact()
        #expect(try fixture.database.commands().contains { $0.id == commandID })
        try fixture.database.removePhoto(id: id)
        try fixture.database.compact()
        #expect(try fixture.database.commands().allSatisfy { $0.id != commandID })
    }
}
