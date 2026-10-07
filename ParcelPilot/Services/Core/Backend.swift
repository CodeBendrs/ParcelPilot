import Foundation
import ParcelPilotKit

/// One operation against user-owned route data. App sessions acknowledge a ChangeSet only after
/// its protected materialization and replayable commands commit in the WP2 SQLite transaction.
enum ChangeOp: Codable, Hashable, Sendable {
    case createRoute(Route)
    /// Writes route fields. When `bumpRevision` is true the input revision is incremented
    /// atomically (FieldValue.increment) instead of being overwritten.
    case updateRoute(Route, bumpRevision: Bool)
    /// A retry-safe field-level invalidation; never replays stale route settings.
    case bumpRouteRevision(RouteID, expectedMinimum: Int)
    case putStop(RouteID, Stop)
    case deleteStop(RouteID, StopID)
    case putPackage(RouteID, Package)
    case deletePackage(RouteID, PackageID)
    case putTask(RouteID, LocationTask)
    case deleteTask(RouteID, TaskID)
    case createOutcome(RouteID, DeliveryOutcome)
    case voidOutcome(RouteID, OutcomeID, at: Date)
    case putPhoto(RouteID, DeliveryPhoto)
    case deletePhoto(RouteID, PhotoID)
    /// Account-wide execution compare-and-set, committed with the same route command locally.
    case transitionExecution(RouteID, expected: RouteExecutionSession?, session: RouteExecutionSession)

    var documentKey: String {
        switch self {
        case let .createRoute(r), let .updateRoute(r, _): return "routes/\(r.id)"
        case let .bumpRouteRevision(rid, _): return "routes/\(rid)"
        case let .putStop(rid, s): return "routes/\(rid)/stops/\(s.id)"
        case let .deleteStop(rid, id): return "routes/\(rid)/stops/\(id)"
        case let .putPackage(rid, p): return "routes/\(rid)/packages/\(p.id)"
        case let .deletePackage(rid, id): return "routes/\(rid)/packages/\(id)"
        case let .putTask(rid, task): return "routes/\(rid)/tasks/\(task.id)"
        case let .deleteTask(rid, id): return "routes/\(rid)/tasks/\(id)"
        case let .createOutcome(rid, o): return "routes/\(rid)/outcomes/\(o.id)"
        case let .voidOutcome(rid, id, _): return "routes/\(rid)/outcomes/\(id)"
        case let .putPhoto(rid, p): return "routes/\(rid)/photos/\(p.id)"
        case let .deletePhoto(rid, id): return "routes/\(rid)/photos/\(id)"
        case .transitionExecution: return "execution/current"
        }
    }
}

struct ChangeSet: Codable, Hashable, Sendable {
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
    /// A failed collection decode must be visible, rather than silently hiding work.
    var readIssues: [String] = []
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

/// Route data boundary. App sessions use DurableRouteBackend; raw Firestore/legacy JSON adapters
/// supply transport and compatibility fixtures, and are not the production UI durability boundary.
@MainActor
protocol RouteBackend: AnyObject {
    var kind: BackendKind { get }
    func observeRoutes(_ onChange: @escaping ([Route], Set<String>) -> Void) -> ListenerToken
    func observeRoute(_ id: RouteID, _ onChange: @escaping (RouteSnapshotEnvelope?) -> Void) -> ListenerToken
    @discardableResult func commit(_ change: ChangeSet) -> LocalCommitResult
    func loadSettings() async -> UserSettings?
    func saveSettings(_ settings: UserSettings)
    /// Reads a full snapshot once (used by duplicate-route and summaries).
    func fetchRoute(_ id: RouteID) async throws -> RouteSnapshot?
}

struct LocalCommitAck: Equatable, Sendable {
    var commandIDs: [String]
    var syncPending: Bool
}

enum LocalPersistenceFailure: Error, LocalizedError, Equatable, Sendable {
    case storage(String), corrupt(String), unsupportedSchema(Int), ownership, conflict(String)
    var errorDescription: String? {
        switch self {
        case .storage: return "Couldn't save on this iPhone. Free space or retry. Your action hasn't been recorded."
        case let .corrupt(message): return "Saved route data needs recovery. Original data has been preserved. \(message)"
        case let .unsupportedSchema(version): return "Saved route version \(version) needs a compatible ParcelPilot update."
        case .ownership: return "Sign in with the original account to recover this iPhone's saved work."
        case let .conflict(message): return message
        }
    }
}

enum LocalCommitResult: Equatable, Sendable {
    case committed(LocalCommitAck)
    case failed(LocalPersistenceFailure)
    var isCommitted: Bool { if case .committed = self { true } else { false } }
    var commandIDs: [String] { if case let .committed(ack) = self { ack.commandIDs } else { [] } }
}

struct DurableCommand: Codable, Hashable, Sendable, Identifiable {
    enum State: String, Codable, Sendable { case pending, sending, verified, retryable, authentication, blocked }
    var schemaVersion = 1
    var id: String
    var accountID: String
    var routeID: RouteID
    var sequence: Int64
    var createdAt: Date
    var label: String
    var ops: [ChangeOp]
    var baseRevision: Int
    var baseRouteCreatedAt: Date?
    var baseRouteUpdatedAt: Date? = nil
    var baselines: [CommandDocumentBaseline]? = nil
    var payloadDigest: String
    var state: State = .pending
    var lastError: String?
}

struct CommandDocumentBaseline: Codable, Hashable, Sendable {
    var documentKey: String
    var payload: Data?
}

enum RemoteReplayResult: Sendable {
    case verified, retryable(String), authentication(String), blocked(String)
}

@MainActor protocol DurableCommandTransport: AnyObject {
    func replay(_ command: DurableCommand) async -> RemoteReplayResult
    func fetchVerifiedRoute(_ id: RouteID) async throws -> RouteSnapshot?
}

/// Separate verified-read capability: older fixture transports cannot accidentally imply a
/// server-confirmed missing execution record by inheriting an unsafe default nil implementation.
@MainActor protocol ExecutionSessionTransport: DurableCommandTransport {
    func fetchVerifiedExecutionSession() async throws -> RouteExecutionSession?
}

struct DurablePhotoRecord: Codable, Hashable, Sendable {
    var item: PendingPhoto
    var bytes: Data?
    var contentHash: String?
    var phase: String = "queued"
    var metadataCommandID: String?
}

enum BackendKind: Equatable {
    case firestore
    case onDevice
}
