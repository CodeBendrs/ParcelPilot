import Foundation
import ParcelPilotKit
import UIKit

/// **Demo only.** Produces synthetic coordinates near the postal code's region so the demo route can be
/// drawn. Every result is `ProviderKind.demo`, which the match assessor reports as
/// "Demo location — not verified": nothing produced here is ever presented as a real address check.
@MainActor
final class DemoAddressResolver: AddressResolver {
    let provider = ProviderKind.demo

    static let anchors: [Character: (Double, Double)] = [
        "A": (47.56, -52.71), "B": (44.65, -63.58), "C": (46.24, -63.13), "E": (45.96, -66.64), "G": (46.81, -71.21),
        "H": (45.50, -73.57), "J": (45.40, -72.73), "K": (45.42, -75.69), "L": (43.59, -79.64), "M": (43.65, -79.38),
        "N": (43.45, -80.49), "P": (46.49, -80.99), "R": (49.90, -97.14), "S": (52.13, -106.67), "T": (51.05, -114.07),
        "V": (48.43, -123.37), "X": (62.45, -114.37), "Y": (60.72, -135.06),
    ]

    func resolve(_ request: ResolveRequest) async throws -> ResolveResponse {
        try await Task.sleep(nanoseconds: 150_000_000)
        let now = Date()
        let candidates: [GeocodeCandidate]
        switch request {
        case let .address(address): candidates = Self.candidates(for: address)
        case let .query(text): candidates = Self.candidates(for: CanadianAddressParser.parse(singleLine: text).address)
        case .placeID: candidates = []
        }
        return ResolveResponse(candidates: candidates, provider: .demo, resolvedAt: now, coordinatesExpireAt: now.addingTimeInterval(ProviderContentPolicy.geocodeCoordinateLifetime))
    }

    /// Demo mode has no address provider, so there is nothing to suggest.
    func suggest(_ input: String, sessionToken: String, near: GeoPoint?) async throws -> [AddressSuggestion] { [] }

    static func candidates(for a: PostalAddress) -> [GeocodeCandidate] {
        guard let code = a.validPostalCode else { return [] }
        let anchor = anchors[code.firstLetter] ?? (45.4, -75.7)
        let seed = DestinationKey.buildingKey(a) ?? code.value
        let h1 = Double(abs(seed.hashValueStable % 10_000)) / 10_000 - 0.5
        let h2 = Double(abs((seed + "#").hashValueStable % 10_000)) / 10_000 - 0.5
        let point = GeoPoint(latitude: anchor.0 + h1 * 0.05, longitude: anchor.1 + h2 * 0.07)
        if let civic = a.civicNumber, let street = a.streetName {
            return [GeocodeCandidate(placeID: nil, formattedAddress: "\(civic) \(street) (demo)", location: point, granularity: .rooftop, types: ["street_address"], streetNumber: civic, route: street, locality: a.municipality, provinceCode: a.province?.rawValue, postalCode: code.value, countryCode: "CA", provider: .demo)]
        }
        return [GeocodeCandidate(placeID: nil, formattedAddress: "\(code.value) (demo postal area)", location: GeoPoint(latitude: anchor.0, longitude: anchor.1), granularity: .approximate, types: ["postal_code"], postalCode: code.value, countryCode: "CA", provider: .demo)]
    }
}

extension String {
    /// FNV-1a — stable across launches (unlike `hashValue`).
    var hashValueStable: Int {
        var h: UInt64 = 1469598103934665603
        for b in utf8 { h ^= UInt64(b); h = h &* 1099511628211 }
        return Int(truncatingIfNeeded: h)
    }
}

/// **Demo only.** Runs the straight-line `DemoOptimizer` on device. Labelled everywhere as a demo
/// estimate — it is not the production road-network optimizer.
@MainActor
final class LocalRouteOptimizer: RouteOptimizer {
    let provider = ProviderKind.demo
    private var jobs: [String: OptimizationJob] = [:]
    private var listeners: [String: [UUID: (OptimizationJob?) -> Void]] = [:]

    func start(snapshot: RouteSnapshot, options: OptimizationOptions, requestID: String) async throws -> OptimizationJob {
        if let existing = jobs[requestID] { return existing }
        let now = Date()
        var job = OptimizationJob(id: requestID, routeID: snapshot.route.id, inputRevision: snapshot.route.inputRevision, status: .running, createdAt: now, updatedAt: now, provider: .demo, proposal: nil, error: nil)
        update(job)
        let result: Result<OptimizationProposal, DemoOptimizer.Failure> = await Task.detached(priority: .userInitiated) {
            do {
                return .success(try DemoOptimizer().optimize(snapshot: snapshot, options: options, requestID: requestID, now: now))
            } catch let failure as DemoOptimizer.Failure {
                return .failure(failure)
            } catch {
                return .failure(.noEligibleStops)
            }
        }.value
        switch result {
        case let .success(proposal):
            job.status = proposal.status == .feasible ? .succeeded : .infeasible
            job.proposal = proposal
        case let .failure(failure):
            job.status = .failed
            job.error = failure.issue
        }
        job.updatedAt = Date()
        update(job)
        return job
    }

    func observe(jobID: String, _ onChange: @escaping (OptimizationJob?) -> Void) -> ListenerToken {
        let id = UUID()
        listeners[jobID, default: [:]][id] = onChange
        onChange(jobs[jobID])
        return ListenerToken { [weak self] in Task { @MainActor in self?.listeners[jobID]?[id] = nil } }
    }

    private func update(_ job: OptimizationJob) {
        jobs[job.id] = job
        for l in listeners[job.id]?.values ?? [:].values { l(job) }
    }
}

/// **Demo only.** Proof-of-delivery photos kept on this iPhone (no upload).
@MainActor
final class LocalPhotoStore: PhotoStore {
    private(set) var pending: [PendingPhoto] = []
    private let store: RouteStore
    private let directory: URL

    init(store: RouteStore) {
        self.store = store
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent("DemoPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func add(jpeg: Data, routeID: RouteID, stopID: StopID, packageIDs: [PackageID]) throws -> PhotoID {
        let id = StableID.make()
        try jpeg.write(to: directory.appendingPathComponent("\(id).jpg"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let photo = DeliveryPhoto(id: id, stopID: stopID, packageIDs: packageIDs, storagePath: "device://DemoPhotos/\(id).jpg", byteSize: jpeg.count, capturedAt: Date())
        store.commitPrepared([.putPhoto(routeID, photo)], label: "Save photo")
        return id
    }

    func image(for photo: DeliveryPhoto, routeID: RouteID) async throws -> UIImage {
        guard let image = UIImage(contentsOfFile: directory.appendingPathComponent("\(photo.id).jpg").path) else { throw ServiceError.unavailable("The photo file is missing on this iPhone.") }
        return image
    }

    func pendingImage(_ id: PhotoID) -> UIImage? { nil }

    func delete(photo: DeliveryPhoto, routeID: RouteID) async throws {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(photo.id).jpg"))
        store.commitPrepared([.deletePhoto(routeID, photo.id)], label: "Delete photo")
    }

    func deletePending(_ id: PhotoID) {}
    func resumeUploads() {}

    func eraseAll() { try? FileManager.default.removeItem(at: directory) }
}

/// **Demo only.** Account actions for demo mode just erase on-device data.
@MainActor
final class DemoAccountService: AccountService {
    let erase: () -> Void
    init(erase: @escaping () -> Void) { self.erase = erase }
    func deleteAccount(appleAuthorizationCode: String?) async throws { erase() }
    func signOut() throws { erase() }
}
