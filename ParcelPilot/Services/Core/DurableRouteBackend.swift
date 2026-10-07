import Foundation
import Observation
import ParcelPilotKit

/// Firestore is transport. This adapter publishes only checked protected materializations, and
/// keeps pending intent over listener/cache churn. All callbacks and SQLite access share MainActor.
@MainActor
@Observable
final class DurableRouteBackend: RouteBackend {
    var kind: BackendKind { remote.kind }
    let remote: RouteBackend
    let ownerID: String
    let persistence: ActiveRoutePersistence?
    private(set) var issue: LocalPersistenceFailure?
    private var syncStorageIssue: String?
    private var protectedExecutionSession: RouteExecutionSession?
    private let transport: DurableCommandTransport?
    private let authenticatedOwner: () -> String?
    private var routeObservers: [UUID: ([Route], Set<String>) -> Void] = [:]
    private var detailObservers: [UUID: (RouteID, (RouteSnapshotEnvelope?) -> Void)] = [:]
    private var tokens: [ListenerToken] = []
    private var remoteRoutes: [Route] = []
    private var requestedRefreshes = Set<RouteID>()
    private var requestedSelection: RouteID?
    private var readIssues: [RouteID: [String]] = [:]
    private var syncTask: Task<Void, Never>?
    private var suspended = false
    private var isSynchronizing = false
    var networkAvailable = true
    var onStateChange: (() -> Void)?

    init(remote: RouteBackend, ownerID: String, persistence: ActiveRoutePersistence?, transport: DurableCommandTransport? = nil,
         authenticatedOwner: @escaping () -> String?, initializationFailure: LocalPersistenceFailure? = nil) {
        self.remote = remote; self.ownerID = ownerID; self.persistence = persistence
        self.transport = transport; self.authenticatedOwner = authenticatedOwner; issue = initializationFailure
        if let persistence, persistence.ownerID != ownerID { issue = .ownership }
        if persistence == nil && issue == nil { issue = .storage("Protected storage is unavailable.") }
        do { protectedExecutionSession = try persistence?.executionSession() }
        catch { issue = error as? LocalPersistenceFailure ?? .corrupt("Route execution couldn't be restored.") }
        tokens.append(remote.observeRoutes { [weak self] routes, _ in self?.remoteRoutes = routes; self?.notify() })
    }

    func quarantine(_ error: Error) { issue = error as? LocalPersistenceFailure ?? .storage(error.localizedDescription); notify() }
    var restoredRouteID: RouteID? {
        guard !suspended, authenticatedOwner() == ownerID else { return nil }
        if let session = currentExecutionSession, session.isUnfinished { return session.routeID }
        return selectedRouteID
    }
    var selectedRouteID: RouteID? {
        guard !suspended, authenticatedOwner() == ownerID else { return nil }
        return try? persistence?.selectedRouteID()
    }
    var currentExecutionSession: RouteExecutionSession? {
        guard !suspended, authenticatedOwner() == ownerID else { return nil }
        return protectedExecutionSession
    }
    var recoveryMessage: String? {
        if let issue { return issue.localizedDescription }
        if let syncStorageIssue { return syncStorageIssue }
        if let command = try? persistence?.commands().first(where: { $0.state == .blocked || $0.state == .authentication }) { return command.lastError }
        return nil
    }
    func suspend() { suspended = true; syncTask?.cancel(); syncTask = nil; tokens.forEach { $0.remove() }; tokens = [] }
    func select(_ id: RouteID?) -> LocalCommitResult {
        guard !suspended, authenticatedOwner() == ownerID else { return .failed(.ownership) }
        guard let persistence, issue == nil else { return .failed(issue ?? .storage("Protected store unavailable.")) }
        do {
            if let id, try persistence.snapshot(id) == nil {
                // Loading a new remote route must not replace the last complete selection with
                // an incomplete pointer if the process stops before its snapshot is pinned.
                requestedSelection = id
                return .committed(.init(commandIDs: [], syncPending: false))
            }
            if try persistence.selectedRouteID() != id { try persistence.select(id) }
            requestedSelection = nil
            return .committed(.init(commandIDs: [], syncPending: false))
        }
        catch { return fail(error) }
    }
    func observeRoutes(_ onChange: @escaping ([Route], Set<String>) -> Void) -> ListenerToken {
        let id = UUID(); routeObservers[id] = onChange; notify()
        return ListenerToken { [weak self] in Task { @MainActor in self?.routeObservers[id] = nil } }
    }
    func observeRoute(_ routeID: RouteID, _ onChange: @escaping (RouteSnapshotEnvelope?) -> Void) -> ListenerToken {
        let id = UUID(); detailObservers[id] = (routeID, onChange)
        emit(routeID, onChange)
        if transport == nil, (try? persistence?.containsRoute(routeID)) == true {
            // Demo JSON is an import source, not an operational replica. Its frozen historical
            // generation must not overwrite or conflict with later SQLite-only work.
            return ListenerToken { [weak self] in Task { @MainActor in self?.detailObservers[id] = nil } }
        }
        let token = remote.observeRoute(routeID) { [weak self] envelope in
            guard let self else { return }
            guard let envelope else {
                // A cached missing document is not deletion evidence. Verify independently online.
                self.requestedRefreshes.insert(routeID)
                self.requestSync(); return
            }
            self.readIssues[routeID] = envelope.readIssues
            guard envelope.readIssues.isEmpty else { self.notify(); return }
            guard !envelope.fromCache, envelope.pendingKeys.isEmpty else { self.notify(); return }
            if self.transport != nil {
                self.requestedRefreshes.insert(routeID)
                self.requestSync()
            } else { self.acceptRemote(envelope.snapshot) }
        }
        return ListenerToken { [weak self] in
            token.remove(); Task { @MainActor in self?.detailObservers[id] = nil }
        }
    }
    private func acceptRemote(_ snapshot: RouteSnapshot) {
        guard let persistence, issue == nil, !suspended, authenticatedOwner() == ownerID else { return }
        do {
            let pending = try persistence.commands(routeID: snapshot.route.id).filter { $0.state != .verified }
            if !pending.isEmpty { requestSync(); notify(); return }
            if let local = try persistence.snapshot(snapshot.route.id) {
                guard abs(local.route.createdAt.timeIntervalSince(snapshot.route.createdAt)) < 0.000_002 else {
                    issue = .conflict("This route was replaced remotely. Saved work has been preserved."); notify(); return
                }
                // Verified local outcome history must not disappear in a remote generation.
                guard ActiveRoutePersistence.preservesHistory(local.outcomes, in: snapshot.outcomes) else {
                    issue = .conflict("Server work history is incomplete. Saved work has been preserved."); notify(); return
                }
                if snapshot.route.inputRevision < local.route.inputRevision { return }
            }
            try persistence.pin(snapshot, selected: requestedSelection == snapshot.route.id || selectedRouteID == snapshot.route.id)
            if requestedSelection == snapshot.route.id { requestedSelection = nil }
            notify()
        } catch { _ = fail(error); notify() }
    }

    @discardableResult func commit(_ change: ChangeSet) -> LocalCommitResult { commitAtomically([change]) }
    func commitAtomically(_ changes: [ChangeSet]) -> LocalCommitResult {
        guard !suspended, authenticatedOwner() == ownerID else { return .failed(.ownership) }
        guard let persistence, issue == nil else { return .failed(issue ?? .storage("Protected store unavailable.")) }
        do {
            let routeIDs = Set(changes.flatMap(\.ops).map(LocalRouteBackend.routeID(of:)))
            guard routeIDs.allSatisfy({ readIssues[$0, default: []].isEmpty }) else { return .failed(.conflict("Route data couldn't be read safely. Retry before recording work.")) }
            for routeID in routeIDs where try !persistence.containsRoute(routeID) {
                guard changes.flatMap(\.ops).contains(where: { if case let .createRoute(route) = $0 { route.id == routeID } else { false } }) else {
                    return .failed(.conflict("Open this route completely before editing it. Reconnect if it isn't saved on this iPhone yet."))
                }
            }
            let ack = try persistence.commit(changes, synchronize: transport != nil)
            issue = nil; syncStorageIssue = nil; notify(); requestSync()
            return .committed(ack)
        } catch { return fail(error) }
    }
    func commitPhotoChange(_ record: DurablePhotoRecord, change: ChangeSet) -> LocalCommitResult {
        guard !suspended, authenticatedOwner() == ownerID else { return .failed(.ownership) }
        guard let persistence, issue == nil else { return .failed(issue ?? .storage("Protected storage unavailable.")) }
        guard readIssues[record.item.routeID, default: []].isEmpty,
              change.ops.allSatisfy({ LocalRouteBackend.routeID(of: $0) == record.item.routeID }) else { return .failed(.conflict("Photo route couldn't be read safely.")) }
        do {
            let ack = try persistence.commitPhotoChange(record, changes: [change], synchronize: transport != nil)
            notify(); requestSync(); return .committed(ack)
        } catch { return fail(error) }
    }
    private func fail(_ error: Error) -> LocalCommitResult {
        let failure = error as? LocalPersistenceFailure ?? .storage(error.localizedDescription)
        // Transient write errors allow Retry; corruption/identity conflicts quarantine the store.
        switch failure { case .storage: break; default: issue = failure }
        onStateChange?()
        return .failed(failure)
    }

    func commandStatus(id: String) -> DurableCommand.State? { (try? persistence?.commands().first { $0.id == id })?.state }
    func retry(commandID: String) -> LocalCommitResult {
        guard let persistence, issue == nil, authenticatedOwner() == ownerID,
              var command = try? persistence.commands().first(where: { $0.id == commandID }) else { return .failed(.ownership) }
        // Historical operations with no baseline cannot be force replayed as modern commands.
        guard command.baseRevision >= 0 else { return .failed(.conflict(command.lastError ?? "Legacy work needs recovery.")) }
        do {
            command.state = .pending; command.lastError = nil; try persistence.update(command)
            notify(); requestSync(); return .committed(.init(commandIDs: [command.id], syncPending: true))
        } catch { return fail(error) }
    }
    func requestSync() {
        guard syncTask == nil, networkAvailable, !suspended, transport != nil, issue == nil, authenticatedOwner() == ownerID else { return }
        syncTask = Task { [weak self] in
            guard let self else { return }
            await self.synchronize(); self.syncTask = nil
            let commands = (try? self.persistence?.commands()) ?? []
            let heads = Dictionary(grouping: commands.filter { $0.state != .verified }, by: \.routeID).values.compactMap { $0.min { $0.sequence < $1.sequence } }
            if heads.contains(where: { $0.state == .pending && !Self.hasPendingExecutionPredecessor($0, commands: commands) }) || !self.requestedRefreshes.isEmpty { self.requestSync() }
        }
    }
    func synchronize() async {
        guard networkAvailable, !isSynchronizing, let persistence, let transport, issue == nil, !suspended, authenticatedOwner() == ownerID else { return }
        isSynchronizing = true
        defer { isSynchronizing = false }
        do {
            let routes = Set(try persistence.commands().filter { $0.state != .verified }.map(\.routeID))
            for routeID in routes.sorted() {
                for var command in try persistence.commands(routeID: routeID) where command.state != .verified {
                    guard !Task.isCancelled, !suspended, authenticatedOwner() == ownerID else { return }
                    if command.state == .blocked { break }
                    let changesExecution = command.ops.contains { if case .transitionExecution = $0 { true } else { false } }
                    // Execution is account-wide, whereas route commands are FIFO per route.
                    // An offline finish A → start B must replay the explicit predecessor first.
                    if changesExecution {
                        let commands = try persistence.commands()
                        if Self.hasPendingExecutionPredecessor(command, commands: commands) { break }
                    }
                    let wasRecovering = command.lastError != nil || command.state == .retryable || command.state == .authentication
                    // A same-account foreground/reconnect/reauthentication attempt can recover an
                    // expired token. Do not spin: authentication results are not auto-rescheduled.
                    command.state = .sending; command.lastError = nil; try persistence.update(command)
                    let result = await transport.replay(command)
                    guard !suspended, authenticatedOwner() == ownerID else { return }
                    switch result {
                    case .verified: command.state = .verified; command.lastError = nil
                    case let .retryable(message): command.state = .retryable; command.lastError = message
                    case let .authentication(message): command.state = .authentication; command.lastError = message
                    case let .blocked(message): command.state = .blocked; command.lastError = message
                    }
                    try persistence.update(command); syncStorageIssue = nil; notify()
                    if command.state != .verified, command.ops.contains(where: {
                        switch $0 { case let .createOutcome(_, outcome): outcome.schemaVersion == 2; case .voidOutcome: true; default: false }
                    }) { PilotTelemetry.record(.init(name: .taskOutcomeSyncFailure, failure: command.state)) }
                    if changesExecution {
                        if command.state != .verified { PilotTelemetry.record(.init(name: .syncFailure, failure: command.state)) }
                        else if wasRecovering { PilotTelemetry.record(.init(name: .syncRecovered)) }
                    }
                    if command.state != .verified { break }
                }
            }
            if let executionTransport = transport as? ExecutionSessionTransport,
               try persistence.commands().filter({ $0.ops.contains { if case .transitionExecution = $0 { true } else { false } } }).allSatisfy({ $0.state == .verified }) {
                do {
                    let session = try await executionTransport.fetchVerifiedExecutionSession()
                    guard !suspended, authenticatedOwner() == ownerID else { return }
                    if let session, session.isUnfinished, try persistence.snapshot(session.routeID) == nil {
                        let snapshot = try await transport.fetchVerifiedRoute(session.routeID)
                        guard !suspended, authenticatedOwner() == ownerID else { return }
                        guard let snapshot else {
                            throw LocalPersistenceFailure.conflict("The server's executing route is missing. Saved execution has been preserved.")
                        }
                        acceptRemote(snapshot)
                    }
                    try persistence.pinExecutionSession(session); notify()
                } catch let failure as LocalPersistenceFailure {
                    if case .storage = failure { throw failure }
                    _ = fail(failure); notify(); return
                }
                catch { /* An unavailable execution read cannot replace accepted local intent. */ }
            }
            var refreshes = requestedRefreshes
            requestedRefreshes = []
            if let selected = selectedRouteID { refreshes.insert(selected) }
            if let execution = currentExecutionSession, execution.isUnfinished { refreshes.insert(execution.routeID) }
            for routeID in refreshes.sorted() where try persistence.commands(routeID: routeID).allSatisfy({ $0.state == .verified }) {
                do {
                    let snapshot = try await transport.fetchVerifiedRoute(routeID)
                    guard !suspended, authenticatedOwner() == ownerID else { return }
                    if let snapshot { acceptRemote(snapshot) }
                    else if try persistence.snapshot(routeID) != nil {
                        issue = .conflict("The loaded route was removed from the server. Saved work has been preserved for recovery."); notify()
                    } else {
                        for (observed, observer) in detailObservers.values where observed == routeID { observer(nil) }
                    }
                } catch { /* An unavailable verified read cannot invalidate protected work. */ }
            }
            let verified = try persistence.commands().filter { $0.state == .verified }
            if try verified.count >= 64 || ActiveRoutePersistence.encode(verified).count >= 2 * 1024 * 1024 { try persistence.compact() }
        } catch {
            if let failure = error as? LocalPersistenceFailure, case .storage = failure {
                syncStorageIssue = "Saved work is preserved, but sync status couldn't be saved on this iPhone. Free space and retry."
            }
            _ = fail(error); notify()
        }
    }
    private static func hasPendingExecutionPredecessor(_ command: DurableCommand, commands: [DurableCommand]) -> Bool {
        let expected = command.ops.compactMap { operation -> RouteExecutionSession? in
            if case let .transitionExecution(_, expected, _) = operation { return expected }
            return nil
        }.first
        guard let expected else { return false }
        return commands.contains { other in
            other.id != command.id && other.state != .verified && other.ops.contains { operation in
                if case let .transitionExecution(_, _, session) = operation { return session.matches(expected) }
                return false
            }
        }
    }
    func retrySavedCommand(_ id: String) async -> LocalCommitResult {
        guard let persistence, let transport, authenticatedOwner() == ownerID, !suspended,
              let command = try? persistence.commands().first(where: { $0.id == id }) else { return .failed(.ownership) }
        if command.baseRevision >= 0 { return retry(commandID: id) }
        do {
            guard let snapshot = try await transport.fetchVerifiedRoute(command.routeID) else { return .failed(.conflict("The legacy route was removed. Saved intent has been preserved.")) }
            guard authenticatedOwner() == ownerID, !suspended else { return .failed(.ownership) }
            let ack = try persistence.recoverLegacy(commandID: id, serverSnapshot: snapshot)
            notify(); requestSync(); return .committed(ack)
        } catch { return .failed(error as? LocalPersistenceFailure ?? .conflict("Reconnect and sign in with the original account to recover this legacy change.")) }
    }
    func fetchRoute(_ id: RouteID) async throws -> RouteSnapshot? {
        guard !suspended, authenticatedOwner() == ownerID else { throw LocalPersistenceFailure.ownership }
        if let issue { throw issue }
        if let snapshot = try persistence?.snapshot(id) { return snapshot }
        if let transport {
            guard authenticatedOwner() == ownerID else { throw LocalPersistenceFailure.ownership }
            if let snapshot = try await transport.fetchVerifiedRoute(id) {
                guard !suspended, authenticatedOwner() == ownerID else { throw LocalPersistenceFailure.ownership }
                acceptRemote(snapshot); return try persistence?.snapshot(id)
            }
            return nil
        }
        if let snapshot = try await remote.fetchRoute(id) {
            guard !suspended, authenticatedOwner() == ownerID else { throw LocalPersistenceFailure.ownership }
            acceptRemote(snapshot); return try persistence?.snapshot(id)
        }
        return nil
    }
    func loadSettings() async -> UserSettings? { await remote.loadSettings() }
    func saveSettings(_ settings: UserSettings) { remote.saveSettings(settings) }
    private func notify() {
        guard authenticatedOwner() == ownerID, !suspended else { return }
        let local: [RouteSnapshot]; let commands: [DurableCommand]
        do {
            local = try persistence?.allSnapshots() ?? []; commands = try persistence?.commands() ?? []
            protectedExecutionSession = try persistence?.executionSession()
        }
        catch { issue = error as? LocalPersistenceFailure ?? .corrupt("Protected data couldn't be read."); onStateChange?(); return }
        var routes = Dictionary(uniqueKeysWithValues: remoteRoutes.map { ($0.id, $0) })
        for snapshot in local { routes[snapshot.route.id] = snapshot.route }
        let pendingKeys = Set(commands.filter { $0.state != .verified }.flatMap { $0.ops.map(\.documentKey) })
        for observer in routeObservers.values { observer(Array(routes.values), pendingKeys) }
        for (routeID, observer) in detailObservers.values {
            if let snapshot = local.first(where: { $0.route.id == routeID }) {
                publish(snapshot, commands: commands.filter { $0.routeID == routeID }, observer)
            }
        }
        onStateChange?()
    }
    private func emit(_ routeID: RouteID, _ observer: (RouteSnapshotEnvelope?) -> Void) {
        guard authenticatedOwner() == ownerID, !suspended else { return }
        do {
            guard let snapshot = try persistence?.snapshot(routeID) else {
                if !networkAvailable { observer(nil) }
                return
            }
            let commands = try persistence?.commands(routeID: routeID) ?? []
            publish(snapshot, commands: commands, observer)
        } catch { _ = fail(error) }
    }
    private func publish(_ snapshot: RouteSnapshot, commands: [DurableCommand], _ observer: (RouteSnapshotEnvelope?) -> Void) {
        let pending = Set(commands.filter { $0.state != .verified }.flatMap { $0.ops.map(\.documentKey) })
        var problems = readIssues[snapshot.route.id, default: []]
        if let issue { problems.append(issue.localizedDescription) }
        if let blocked = commands.first(where: { $0.state == .blocked || $0.state == .authentication }) { problems.append(blocked.lastError ?? "Saved work needs recovery.") }
        observer(.init(snapshot: snapshot, pendingKeys: pending, fromCache: true, readIssues: problems))
    }
}
