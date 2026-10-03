import FirebaseStorage
import Foundation
import Observation
import ParcelPilotKit
import UIKit

/// Proof-of-delivery photos.
///
/// 1. The JPEG (re-encoded, so no EXIF/location metadata) is written to Application Support/PendingUploads
///    with a manifest entry — durable across termination.
/// 2. The uploader puts it at users/{uid}/routes/{routeID}/pod/{photoID}.jpg. Uploads are idempotent by
///    photo ID: if the object already exists (an earlier attempt finished), it is not uploaded again.
/// 3. The photo document is written through the route store, then the local file is removed.
/// Delivery completion never waits for a photo.
@MainActor
@Observable
final class FirebasePhotoStore: PhotoStore {
    private(set) var pending: [PendingPhoto] = []
    private let uid: String
    private let store: RouteStore
    private let connectivity: ConnectivityMonitor
    private let directory: URL
    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }
    private var uploading = Set<PhotoID>()
    private var cache = NSCache<NSString, UIImage>()
    private let ops: StorageOps

    init(uid: String, store: RouteStore, connectivity: ConnectivityMonitor, storage: Storage = Storage.storage(), baseDirectory: URL? = nil) {
        self.uid = uid
        self.store = store
        self.connectivity = connectivity
        self.ops = StorageOps(storage: storage)
        let base = baseDirectory ?? (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent("PendingUploads/\(uid)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        if let data = try? Data(contentsOf: manifestURL), let decoded = try? JSONDecoder.appStorage.decode([PendingPhoto].self, from: data) {
            pending = decoded.filter { FileManager.default.fileExists(atPath: fileURL($0.id).path) }
        }
        connectivity.onChange { [weak self] online in if online { self?.resumeUploads() } }
    }

    static func storagePath(uid: String, routeID: RouteID, photoID: PhotoID) -> String {
        "users/\(uid)/routes/\(routeID)/pod/\(photoID).jpg"
    }

    private func fileURL(_ id: PhotoID) -> URL { directory.appendingPathComponent("\(id).jpg") }

    private func saveManifest() {
        try? JSONEncoder.appStorage.encode(pending).write(to: manifestURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func add(jpeg: Data, routeID: RouteID, stopID: StopID, packageIDs: [PackageID]) throws -> PhotoID {
        let id = StableID.make()
        try jpeg.write(to: fileURL(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        pending.append(PendingPhoto(id: id, routeID: routeID, stopID: stopID, packageIDs: packageIDs, capturedAt: Date(), byteSize: jpeg.count, attempts: 0, lastError: nil))
        saveManifest()
        resumeUploads()
        return id
    }

    func resumeUploads() {
        guard connectivity.isOnline else { return }
        for item in pending where !uploading.contains(item.id) {
            uploading.insert(item.id)
            Task { await upload(item) }
        }
    }

    private func upload(_ item: PendingPhoto) async {
        defer { uploading.remove(item.id) }
        let path = Self.storagePath(uid: uid, routeID: item.routeID, photoID: item.id)
        do {
            let alreadyUploaded = await ops.exists(path: path)
            if !alreadyUploaded {
                let data = try Data(contentsOf: fileURL(item.id))
                try await ops.uploadJPEG(path: path, data: data)
            }
            let photo = DeliveryPhoto(id: item.id, stopID: item.stopID, packageIDs: item.packageIDs, storagePath: path, byteSize: item.byteSize, capturedAt: item.capturedAt)
            store.commitPrepared([.putPhoto(item.routeID, photo)], label: "Proof-of-delivery photo")
            if let image = UIImage(contentsOfFile: fileURL(item.id).path) { cache.setObject(image, forKey: item.id as NSString) }
            try? FileManager.default.removeItem(at: fileURL(item.id))
            pending.removeAll { $0.id == item.id }
            saveManifest()
        } catch {
            if let i = pending.firstIndex(where: { $0.id == item.id }) {
                pending[i].attempts += 1
                pending[i].lastError = connectivity.isOnline ? "Upload failed. It will retry automatically." : "Waiting for a connection."
                saveManifest()
            }
            AppLog.storage.error("Photo upload failed: \((error as NSError).code, privacy: .public)")
        }
    }

    func pendingImage(_ id: PhotoID) -> UIImage? { UIImage(contentsOfFile: fileURL(id).path) }

    func image(for photo: DeliveryPhoto, routeID: RouteID) async throws -> UIImage {
        if let cached = cache.object(forKey: photo.id as NSString) { return cached }
        if let local = pendingImage(photo.id) { return local }
        let data = try await ops.download(path: photo.storagePath, maxSize: 6 * 1024 * 1024)
        guard let image = UIImage(data: data) else { throw ServiceError.unavailable("The photo couldn't be opened.") }
        cache.setObject(image, forKey: photo.id as NSString)
        return image
    }

    func delete(photo: DeliveryPhoto, routeID: RouteID) async throws {
        do {
            try await ops.delete(path: photo.storagePath)
        } catch let error as NSError where error.domain == StorageErrorDomain && error.code == StorageErrorCode.objectNotFound.rawValue {
            // Already gone — continue removing the record.
        }
        store.commitPrepared([.deletePhoto(routeID, photo.id)], label: "Delete photo")
        cache.removeObject(forKey: photo.id as NSString)
    }

    func deletePending(_ id: PhotoID) {
        try? FileManager.default.removeItem(at: fileURL(id))
        pending.removeAll { $0.id == id }
        saveManifest()
    }

    func eraseLocal() {
        try? FileManager.default.removeItem(at: directory)
        pending = []
    }
}

/// Cloud Storage calls made off the main actor with references created locally (StorageReference
/// is not Sendable).
/// Storage calls kept off the main actor (the SDK's async APIs are not main-actor isolated).
nonisolated struct StorageOps: @unchecked Sendable {
    let storage: Storage

    func exists(path: String) async -> Bool {
        (try? await storage.reference(withPath: path).getMetadata()) != nil
    }

    func uploadJPEG(path: String, data: Data) async throws {
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"
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
