import Foundation
import ParcelPilotKit

/// One write operation against user-owned data. Change sets are applied atomically (a Firestore
/// batch, or one save of the on-device store) and return immediately — the local copy updates at
/// once, and the server copy follows when online.
enum ChangeOp: Sendable {
    case createRoute(Route)
    /// Writes route fields. When `bumpRevision` is true the input revision is incremented
    /// atomically (FieldValue.increment) instead of being overwritten.
    case updateRoute(Route, bumpRevision: Bool)
    case putStop(RouteID, Stop)
    case deleteStop(RouteID, StopID)
    case putPackage(RouteID, Package)
    case deletePackage(RouteID, PackageID)
    case createOutcome(RouteID, DeliveryOutcome)
    case voidOutcome(RouteID, OutcomeID, at: Date)
    case putPhoto(RouteID, DeliveryPhoto)
    case deletePhoto(RouteID, PhotoID)

    var documentKey: String {
        switch self {
        case let .createRoute(r), let .updateRoute(r, _): return "routes/\(r.id)"
        case let .putStop(rid, s): return "routes/\(rid)/stops/\(s.id)"
        case let .deleteStop(rid, id): return "routes/\(rid)/stops/\(id)"
        case let .putPackage(rid, p): return "routes/\(rid)/packages/\(p.id)"
        case let .deletePackage(rid, id): return "routes/\(rid)/packages/\(id)"
        case let .createOutcome(rid, o): return "routes/\(rid)/outcomes/\(o.id)"
        case let .voidOutcome(rid, id, _): return "routes/\(rid)/outcomes/\(id)"
        case let .putPhoto(rid, p): return "routes/\(rid)/photos/\(p.id)"
        case let .deletePhoto(rid, id): return "routes/\(rid)/photos/\(id)"
        }
    }
}

struct ChangeSet: Sendable {
    var ops: [ChangeOp]
    /// Plain description shown if the change is rejected ("Delivered 123 Example St").
    var label: String
    /// Outcome-critical changes are recorded in the sync journal so a rejected or unverified write
    /// is surfaced and can be retried.
    var critical: Bool

    init(_ ops: [ChangeOp], label: String, critical: Bool = false) {
        self.ops = ops
        self.label = label
        self.critical = critical
    }
}

/// Sync state of one document as shown in the UI.
enum DocumentSyncState: Equatable, Sendable {
    case synced
    case pending
    case failed(String)
}

struct RouteSnapshotEnvelope: Sendable {
    var snapshot: RouteSnapshot
    /// Document keys ("routes/r/stops/s") with writes not yet acknowledged by the server.
    var pendingKeys: Set<String>
    var fromCache: Bool
}

/// Removes a listener when `remove()` is called or the token is released. Listener removal
/// (Firestore registrations, main-actor hops for local listeners) is safe from any thread.
nonisolated final class ListenerToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancel: (() -> Void)?
    init(_ cancel: @escaping () -> Void) { self.cancel = cancel }

    func remove() {
        lock.lock()
        let c = cancel
        cancel = nil
        lock.unlock()
        c?()
    }

    deinit { cancel?() }
}

/// Persistence for routes and everything under them. Implemented by Firestore (production /
/// emulator) and by an on-device JSON store (demo mode).
@MainActor
protocol RouteBackend: AnyObject {
    var kind: BackendKind { get }
    func observeRoutes(_ onChange: @escaping ([Route], Set<String>) -> Void) -> ListenerToken
    func observeRoute(_ id: RouteID, _ onChange: @escaping (RouteSnapshotEnvelope?) -> Void) -> ListenerToken
    func commit(_ change: ChangeSet)
    func loadSettings() async -> UserSettings?
    func saveSettings(_ settings: UserSettings)
    /// Reads a full snapshot once (used by duplicate-route and summaries).
    func fetchRoute(_ id: RouteID) async throws -> RouteSnapshot?
}

enum BackendKind: Equatable {
    case firestore
    case onDevice
}
