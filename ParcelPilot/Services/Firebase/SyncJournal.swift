import Foundation
import Observation
import ParcelPilotKit

/// Compatibility reader/UI for pre-WP2 journal records. Production commands are acknowledged by
/// the protected transactional store. Legacy JSON write errors remain explicit and corrupt source
/// bytes are never replaced with an empty journal during migration.
@MainActor
@Observable
final class SyncJournal {
    struct Entry: Codable, Identifiable, Hashable {
        enum State: String, Codable { case pending, failed }
        var id: String
        var label: String
        var createdAt: Date
        var state: State
        var lastError: String?
        /// Encoded operations so the change can be retried exactly.
        var ops: [JournalOp]
    }

    private(set) var entries: [Entry] = []
    private(set) var lastPersistenceFailure: LocalPersistenceFailure?
    private var protectedCommandIDs = Set<String>()
    func isProtectedCommand(_ id: String) -> Bool { protectedCommandIDs.contains(id) }
    private let fileURL: URL
    @ObservationIgnored private weak var protectedBackend: DurableRouteBackend?
    func unbindForAccountDeletion() { protectedBackend?.onStateChange = nil; protectedBackend = nil }
    func bind(to backend: DurableRouteBackend) {
        protectedBackend = backend
        backend.onStateChange = { [weak self] in self?.refreshProtectedEntries() }
        refreshProtectedEntries()
    }
    private func refreshProtectedEntries() {
        guard let persistence = protectedBackend?.persistence else { return }
        do {
            let commands = try persistence.commands().filter { $0.state != .verified }
            protectedCommandIDs = Set(commands.map(\.id))
            entries = commands.map { command in
                Entry(id: command.id, label: command.label, createdAt: command.createdAt,
                    state: command.state == .blocked || command.state == .authentication ? .failed : .pending,
                    lastError: command.lastError, ops: command.ops.compactMap(JournalOp.init))
            }
        } catch { lastPersistenceFailure = error as? LocalPersistenceFailure ?? .corrupt("Saved commands couldn't be read.") }
    }
    private var sourceReadFailure: LocalPersistenceFailure?

    init(fileURL: URL = SyncJournal.defaultURL) {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                do { entries = try JSONDecoder.appStorage.decode([Entry].self, from: data) }
                catch { throw LocalPersistenceFailure.corrupt("The legacy sync journal couldn't be decoded.") }
            } catch {
                let failure = (error as? LocalPersistenceFailure) ?? .storage(error.localizedDescription)
                sourceReadFailure = failure; lastPersistenceFailure = failure
            }
        }
    }

    static var defaultURL: URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("sync-journal.json")
    }

    var failed: [Entry] { entries.filter { $0.state == .failed } }
    var pending: [Entry] { entries.filter { $0.state == .pending } }

    func begin(_ change: ChangeSet) -> String {
        if protectedBackend != nil { lastPersistenceFailure = .conflict("Driver writes must use the protected route store."); return StableID.make() }
        var revisionRoutes = Set<RouteID>()
        let ops = change.ops.compactMap(JournalOp.init).filter { op in
            if case let .bumpRouteRevision(routeID, _) = op { return revisionRoutes.insert(routeID).inserted }
            return true
        }
        let entry = Entry(id: StableID.make(), label: change.label, createdAt: Date(), state: .pending, lastError: nil, ops: ops)
        mutate { entries.append(entry) }
        return entry.id
    }

    func succeeded(_ id: String) {
        guard protectedBackend == nil else { return }
        mutate { entries.removeAll { $0.id == id } }
    }

    func failed(_ id: String, message: String) {
        guard protectedBackend == nil else { return }
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        mutate {
            entries[i].state = .failed
            entries[i].lastError = message
        }
    }

    func discard(_ id: String) { guard protectedBackend == nil else { return }; succeeded(id) }

    /// Records a rejected change that has no retryable payload (shown with Discard only).
    func reportRejected(label: String, message: String) {
        guard protectedBackend == nil else { return }
        mutate { entries.append(Entry(id: StableID.make(), label: label, createdAt: Date(), state: .failed, lastError: message, ops: [])) }
    }

    func clear() {
        guard protectedBackend == nil else { return }
        mutate { entries = [] }
    }

    private func mutate(_ change: () -> Void) {
        guard sourceReadFailure == nil else { lastPersistenceFailure = sourceReadFailure; return }
        let previous = entries
        change()
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.appStorage.encode(entries).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            lastPersistenceFailure = nil
        } catch {
            entries = previous
            lastPersistenceFailure = .storage(error.localizedDescription)
        }
    }
}

/// Codable mirror of the journaled subset of `ChangeOp`.
enum JournalOp: Codable, Hashable {
    case putStop(RouteID, Stop)
    case putPackage(RouteID, Package)
    case deleteStop(RouteID, StopID)
    case deletePackage(RouteID, PackageID)
    case putTask(RouteID, LocationTask)
    case deleteTask(RouteID, TaskID)
    case bumpRouteRevision(RouteID, expectedMinimum: Int)
    case createOutcome(RouteID, DeliveryOutcome)
    case voidOutcome(RouteID, OutcomeID, Date)

    var routeID: RouteID {
        switch self {
        case let .putStop(id, _), let .putPackage(id, _), let .deleteStop(id, _), let .deletePackage(id, _),
             let .putTask(id, _), let .deleteTask(id, _), let .bumpRouteRevision(id, _),
             let .createOutcome(id, _), let .voidOutcome(id, _, _): return id
        }
    }

    init?(_ op: ChangeOp) {
        switch op {
        case let .putStop(r, s): self = .putStop(r, s)
        case let .putPackage(r, p): self = .putPackage(r, p)
        case let .deleteStop(r, s): self = .deleteStop(r, s)
        case let .deletePackage(r, p): self = .deletePackage(r, p)
        case let .putTask(r, task): self = .putTask(r, task)
        case let .deleteTask(r, id): self = .deleteTask(r, id)
        case let .updateRoute(route, true): self = .bumpRouteRevision(route.id, expectedMinimum: route.inputRevision + 1)
        case let .bumpRouteRevision(r, minimum): self = .bumpRouteRevision(r, expectedMinimum: minimum)
        case let .createOutcome(r, o): self = .createOutcome(r, o)
        case let .voidOutcome(r, o, at): self = .voidOutcome(r, o, at)
        case .createRoute, .updateRoute(_, false), .putPhoto, .deletePhoto, .transitionExecution: return nil
        }
    }

    var changeOp: ChangeOp {
        switch self {
        case let .putStop(r, s): return .putStop(r, s)
        case let .putPackage(r, p): return .putPackage(r, p)
        case let .deleteStop(r, s): return .deleteStop(r, s)
        case let .deletePackage(r, p): return .deletePackage(r, p)
        case let .putTask(r, task): return .putTask(r, task)
        case let .deleteTask(r, id): return .deleteTask(r, id)
        case let .bumpRouteRevision(r, minimum): return .bumpRouteRevision(r, expectedMinimum: minimum)
        case let .createOutcome(r, o): return .createOutcome(r, o)
        case let .voidOutcome(r, o, at): return .voidOutcome(r, o, at: at)
        }
    }
}
