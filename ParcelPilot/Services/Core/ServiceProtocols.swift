import Foundation
import ParcelPilotKit
import UIKit

// MARK: - Address resolution

enum ResolveRequest: Sendable {
    case address(PostalAddress)
    case query(String)
    case placeID(String)
}

struct ResolveResponse: Sendable {
    var candidates: [GeocodeCandidate]
    var provider: ProviderKind
    var resolvedAt: Date
    var coordinatesExpireAt: Date
}

/// An autocomplete suggestion. It carries no coordinates: picking it resolves `placeID` with
/// `resolve(.placeID)`, which is where the address is checked.
struct AddressSuggestion: Identifiable, Hashable, Sendable {
    var placeID: String
    var primaryText: String
    var secondaryText: String?
    var id: String { placeID }
}

enum ServiceError: LocalizedError, Equatable {
    case offline
    case signedOut
    case notConfigured(String)
    case quotaExceeded(String)
    case unavailable(String)
    case rejected(String)
    case invalid(String)
    case permission(String)

    var errorDescription: String? {
        switch self {
        case .offline: return "You're offline. Your work is saved on this iPhone and will sync when you're back online."
        case .signedOut: return "You're signed out. Sign in to continue."
        case let .notConfigured(m), let .quotaExceeded(m), let .unavailable(m), let .rejected(m), let .invalid(m), let .permission(m): return m
        }
    }

    var isOffline: Bool { self == .offline }
}

@MainActor
protocol AddressResolver: AnyObject {
    var provider: ProviderKind { get }
    func resolve(_ request: ResolveRequest) async throws -> ResolveResponse
    /// Address suggestions while typing. `sessionToken` groups one search for provider billing.
    func suggest(_ input: String, sessionToken: String, near: GeoPoint?) async throws -> [AddressSuggestion]
}

// MARK: - Optimization

@MainActor
protocol RouteOptimizer: AnyObject {
    var provider: ProviderKind { get }
    /// Starts (or re-attaches to) the job with this request ID. Repeating the call with the same ID
    /// never starts a second paid optimization.
    func start(snapshot: RouteSnapshot, options: OptimizationOptions, requestID: String) async throws -> OptimizationJob
    func observe(jobID: String, _ onChange: @escaping (OptimizationJob?) -> Void) -> ListenerToken
}

// MARK: - Photos

struct PendingPhoto: Codable, Hashable, Identifiable, Sendable {
    var id: PhotoID
    var routeID: RouteID
    var stopID: StopID
    var packageIDs: [PackageID]
    var capturedAt: Date
    var byteSize: Int
    var attempts: Int
    var lastError: String?
}

@MainActor
protocol PhotoStore: AnyObject {
    var pending: [PendingPhoto] { get }
    /// Storage/corruption failures requiring attention; normal offline photos remain quiet.
    var storageIssue: String? { get }
    /// Saves the JPEG durably on the device and schedules upload. Returns the photo ID.
    func add(jpeg: Data, routeID: RouteID, stopID: StopID, packageIDs: [PackageID]) throws -> PhotoID
    func image(for photo: DeliveryPhoto, routeID: RouteID) async throws -> UIImage
    func pendingImage(_ id: PhotoID) -> UIImage?
    func delete(photo: DeliveryPhoto, routeID: RouteID) async throws
    func deletePending(_ id: PhotoID)
    func resumeUploads()
}

extension PhotoStore { var storageIssue: String? { nil } }

// MARK: - Account

@MainActor
protocol AccountService: AnyObject {
    /// Deletes all server data for the signed-in user, who must have signed in again within the last
    /// 10 minutes. `appleAuthorizationCode` (Sign in with Apple accounts) revokes the Apple token first.
    func deleteAccount(appleAuthorizationCode: String?) async throws
    func signOut() throws
}
