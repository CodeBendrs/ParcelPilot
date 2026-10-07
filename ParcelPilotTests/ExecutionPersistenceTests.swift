import Foundation
import ParcelPilotKit
import SQLite3
import Testing
@testable import ParcelPilot

@MainActor
@Suite("Protected execution persistence", .serialized)
struct ExecutionPersistenceTests {
    private let epoch = Date(timeIntervalSince1970: 1_790_000_000)
    private func url() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("execution-contract-\(UUID().uuidString)/operations.sqlite") }
    private func snapshot(_ id: String = "route") -> RouteSnapshot {
        var route = Route(id: id, name: id, serviceDate: "2026-10-06", timeZoneID: "America/Vancouver", now: epoch)
        route.status = .active; route.appliedRequestID = "accepted"; route.appliedRevision = route.inputRevision
        return RouteSnapshot(route: route, stops: [], packages: [], outcomes: [])
    }
    private func transition(_ previous: RouteExecutionSession, to state: RouteExecutionSession.State) -> RouteExecutionSession {
        var next = previous; next.state = state; next.transitionCount += 1
        next.changedAt = previous.changedAt.addingTimeInterval(1)
        return next
    }

    @Test("Starting execution is one checked transaction with its replayable command")
    func atomicStart() throws {
        let disk = try ActiveRoutePersistence(ownerID: "owner", databaseURL: url())
        let route = snapshot(); try disk.pin(route, selected: true)
        let session = RouteExecutionSession(routeID: route.route.id, now: epoch)
        disk.injectFailure = { if case .beforeCommit = $0 { throw LocalPersistenceFailure.storage("disk full") } }
        #expect(throws: LocalPersistenceFailure.self) { try disk.commit([ChangeSet([.transitionExecution(route.route.id, expected: nil, session: session)], label: "Start")], synchronize: true) }
        disk.injectFailure = nil
        #expect(try disk.executionSession() == nil && disk.commands().isEmpty)
        let ack = try disk.commit([ChangeSet([.transitionExecution(route.route.id, expected: nil, session: session)], label: "Start")], synchronize: true)
        #expect(ack.commandIDs.count == 1 && ack.syncPending)
        #expect(try disk.executionSession()?.matches(session) == true)
        #expect(try disk.snapshot(route.route.id)?.route.inputRevision == route.route.inputRevision)
        #expect(try disk.commands().first?.ops.count == 1)
    }

    @Test("Execution and selection restore independently, while cold start favors unfinished execution")
    func independentSelection() throws {
        let path = url(), disk = try ActiveRoutePersistence(ownerID: "owner", databaseURL: path)
        let a = snapshot("a"), b = snapshot("b")
        try disk.pin(a, selected: true); try disk.pin(b)
        let active = RouteExecutionSession(routeID: "a", now: epoch)
        _ = try disk.commit([ChangeSet([.transitionExecution("a", expected: nil, session: active)], label: "Start")], synchronize: false)
        try disk.select("b")
        let reopened = try ActiveRoutePersistence(ownerID: "owner", databaseURL: path)
        let backend = DurableRouteBackend(remote: LocalRouteBackend(fileURL: path.deletingLastPathComponent().appendingPathComponent("legacy.json")), ownerID: "owner", persistence: reopened, authenticatedOwner: { "owner" })
        #expect(backend.currentExecutionSession?.matches(active) == true)
        #expect(backend.selectedRouteID == "b" && backend.restoredRouteID == "a")
        let paused = transition(active, to: .paused)
        #expect(backend.commit(ChangeSet([.transitionExecution("a", expected: active, session: paused)], label: "Pause")).isCommitted)
        #expect(backend.selectedRouteID == "b" && backend.currentExecutionSession?.state == .paused)
        #expect(backend.select(nil).isCommitted && backend.restoredRouteID == "a")
        backend.suspend()
    }

    @Test("One unfinished singleton cannot switch route or close implicitly, and Finish closeout is atomic")
    func singletonAndFinish() throws {
        let disk = try ActiveRoutePersistence(ownerID: "owner", databaseURL: url())
        let route = snapshot(), other = snapshot("other")
        try disk.pin(route, selected: true); try disk.pin(other)
        let active = RouteExecutionSession(routeID: route.route.id, now: epoch)
        _ = try disk.commit([ChangeSet([.transitionExecution(route.route.id, expected: nil, session: active)], label: "Start")], synchronize: true)
        let replacement = RouteExecutionSession(routeID: other.route.id, now: epoch.addingTimeInterval(2))
        #expect(throws: LocalPersistenceFailure.self) { try disk.commit([ChangeSet([.transitionExecution(other.route.id, expected: active, session: replacement)], label: "Switch")], synchronize: true) }
        var closed = route.route; closed.status = .completed; closed.completedAt = epoch.addingTimeInterval(1)
        #expect(throws: LocalPersistenceFailure.self) { try disk.commit([ChangeSet([.updateRoute(closed, bumpRevision: false)], label: "Close")], synchronize: true) }
        let finished = transition(active, to: .finished)
        disk.injectFailure = { if case .beforeCommit = $0 { throw LocalPersistenceFailure.storage("disk full") } }
        let finish = ChangeSet([.transitionExecution(route.route.id, expected: active, session: finished), .updateRoute(closed, bumpRevision: false)], label: "Finish")
        #expect(throws: LocalPersistenceFailure.self) { try disk.commit([finish], synchronize: true) }
        disk.injectFailure = nil
        #expect(try disk.executionSession()?.state == .active && disk.snapshot(route.route.id)?.route.isOpen == true)
        #expect(try disk.commands().count == 1 && disk.selectedRouteID() == route.route.id)
        _ = try disk.commit([finish], synchronize: true)
        #expect(try disk.executionSession()?.state == .finished && disk.snapshot(route.route.id)?.route.isOpen == false)
        #expect(try disk.commands().count == 2 && disk.selectedRouteID() == nil)
    }

    @Test("Schema-1 migration is additive, failure rolls back its table/version, and legacy active never implies execution")
    func migration() throws {
        let path = url(), disk = try ActiveRoutePersistence(ownerID: "owner", databaseURL: path)
        let route = snapshot(); try disk.pin(route, selected: true)
        _ = try disk.commit([ChangeSet([.bumpRouteRevision(route.route.id, expectedMinimum: 2)], label: "Work")], synchronize: true)
        let commands = try disk.commands()
        try sql("DROP TABLE execution; PRAGMA user_version=1", at: path)
        #expect(throws: LocalPersistenceFailure.self) { try ActiveRoutePersistence(ownerID: "owner", databaseURL: path, migrationFailure: { throw LocalPersistenceFailure.storage("interrupted") }) }
        #expect(try count("PRAGMA user_version", at: path) == 1)
        #expect(try count("SELECT COUNT(*) FROM sqlite_master WHERE name='execution'", at: path) == 0)
        let migrated = try ActiveRoutePersistence(ownerID: "owner", databaseURL: path)
        #expect(try count("PRAGMA user_version", at: path) == 2)
        #expect(try migrated.executionSession() == nil && migrated.commands() == commands)
        #expect(try migrated.selectedRouteID() == route.route.id && migrated.snapshot(route.route.id)?.route.status == .active)
    }

    @Test("Frozen pre-WP3 schema and literal delivery history migrate without inferring a started session")
    func frozenVersionOne() throws {
        let path = url()
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        // These bytes are deliberately independent of today's Codable model/command encoders.
        let route = #"{"id":"legacy","schemaVersion":1,"name":"Legacy","status":"active","createdAt":1790000000,"updatedAt":1790000001,"startedAt":1790000000,"serviceDate":"2026-10-05","timeZoneID":"America/Vancouver","departureMinute":480,"returnToStart":false,"defaultServiceSeconds":120,"objective":"balanced","considerTraffic":true,"inputRevision":7}"#
        let stop = #"{"id":"legacy-stop","schemaVersion":1,"createdAt":1790000000,"updatedAt":1790000000,"address":{"unit":"204","civicNumber":"123","streetName":"EXAMPLE ST","municipality":"VICTORIA","province":"BC","postalCode":"V8W 1A1","country":"CA","additionalLines":[]},"destinationKey":"legacy-unit-204","addressStatus":"needsReview","reviewReasons":[],"sequence":1,"pin":"none","notes":"Buzzer 204"}"#
        let package = #"{"id":"legacy-package","schemaVersion":1,"stopID":"legacy-stop","createdAt":1790000000,"updatedAt":1790000000,"trackingID":"TRACK123","trackingKey":"TRACK123","notes":"","source":"scan"}"#
        let outcome = #"{"id":"legacy-outcome","schemaVersion":1,"packageID":"legacy-package","stopID":"legacy-stop","kind":"delivered","recordedAt":1790000001,"photoIDs":[]}"#
        try sql("""
            CREATE TABLE meta (key TEXT PRIMARY KEY, value BLOB NOT NULL);
            CREATE TABLE documents (route TEXT NOT NULL, kind TEXT NOT NULL, id TEXT NOT NULL, payload BLOB NOT NULL, digest TEXT NOT NULL, PRIMARY KEY(route,kind,id));
            CREATE TABLE route_state (route TEXT PRIMARY KEY, next_sequence INTEGER NOT NULL DEFAULT 1);
            CREATE TABLE commands (id TEXT PRIMARY KEY, route TEXT NOT NULL, sequence INTEGER NOT NULL, payload BLOB NOT NULL, UNIQUE(route,sequence));
            CREATE TABLE photos (id TEXT PRIMARY KEY, payload BLOB NOT NULL, digest TEXT NOT NULL);
            INSERT INTO meta VALUES ('owner','owner'); INSERT INTO meta VALUES ('selected','legacy');
            INSERT INTO route_state VALUES ('legacy',1); PRAGMA user_version=1;
            """, at: path)
        for (kind, id, payload) in [("route", "legacy", route), ("stops", "legacy-stop", stop), ("packages", "legacy-package", package), ("outcomes", "legacy-outcome", outcome)] {
            let digest = ActiveRoutePersistence.digest(Data(payload.utf8))
            try sql("INSERT INTO documents VALUES ('legacy','\(kind)','\(id)','\(payload)','\(digest)')", at: path)
        }
        let migrated = try ActiveRoutePersistence(ownerID: "owner", databaseURL: path)
        let saved = try #require(try migrated.snapshot("legacy"))
        #expect(saved.route.status == .active && saved.route.startedAt != nil)
        #expect(saved.outcomes.map(\.id) == ["legacy-outcome"] && saved.workSummary.completed == 1)
        #expect(saved.packages[0].trackingID == "TRACK123" && saved.stops[0].address.unit == "204")
        #expect(try migrated.executionSession() == nil && migrated.selectedRouteID() == "legacy")
        let repeated = try ActiveRoutePersistence(ownerID: "owner", databaseURL: path)
        #expect(try repeated.executionSession() == nil && repeated.snapshot("legacy")?.outcomes == saved.outcomes)
        #expect(try count("PRAGMA user_version", at: path) == 2)
    }

    @Test("Verified route pins cannot erase execution, and missing or competing remote execution preserves intent")
    func refreshProtection() throws {
        let disk = try ActiveRoutePersistence(ownerID: "owner", databaseURL: url())
        let route = snapshot(); try disk.pin(route)
        let active = RouteExecutionSession(routeID: route.route.id, now: epoch)
        _ = try disk.commit([ChangeSet([.transitionExecution(route.route.id, expected: nil, session: active)], label: "Start")], synchronize: false)
        try disk.pin(route)
        #expect(try disk.executionSession()?.matches(active) == true)
        #expect(throws: LocalPersistenceFailure.self) { try disk.pinExecutionSession(nil) }
        let competing = RouteExecutionSession(routeID: "other", now: epoch.addingTimeInterval(1))
        #expect(throws: LocalPersistenceFailure.self) { try disk.pinExecutionSession(competing) }
        var closed = route; closed.route.status = .completed
        #expect(throws: LocalPersistenceFailure.self) { try disk.pin(closed) }
        #expect(try disk.executionSession()?.matches(active) == true && disk.snapshot(route.route.id)?.route.isOpen == true)
        let paused = transition(active, to: .paused)
        try disk.pinExecutionSession(paused)
        #expect(try disk.executionSession()?.state == .paused)
        #expect(throws: LocalPersistenceFailure.self) { try disk.pinExecutionSession(active) }
    }

    @Test("Execution session corruption preserves bytes, while compaction retains accepted lifecycle state")
    func corruptionAndCompaction() throws {
        let path = url(), disk = try ActiveRoutePersistence(ownerID: "owner", databaseURL: path)
        let route = snapshot(); try disk.pin(route)
        let active = RouteExecutionSession(routeID: route.route.id, now: epoch)
        _ = try disk.commit([ChangeSet([.transitionExecution(route.route.id, expected: nil, session: active)], label: "Start")], synchronize: false)
        try disk.compact()
        #expect(try disk.commands().isEmpty && disk.executionSession()?.matches(active) == true)
        try sql("UPDATE execution SET digest='corrupt'", at: path)
        #expect(throws: LocalPersistenceFailure.self) { try ActiveRoutePersistence(ownerID: "owner", databaseURL: path) }
        #expect(try count("SELECT COUNT(*) FROM execution WHERE digest='corrupt'", at: path) == 1)
    }

    @Test("Cross-route replay preserves explicit finish then start dependency despite lexical route order")
    func crossRouteReplay() async throws {
        let disk = try ActiveRoutePersistence(ownerID: "owner", databaseURL: url())
        let z = snapshot("z-route"), a = snapshot("a-route")
        try disk.pin(z); try disk.pin(a)
        let activeZ = RouteExecutionSession(routeID: z.route.id, now: epoch), finishedZ = transition(activeZ, to: .finished)
        let activeA = RouteExecutionSession(routeID: a.route.id, now: epoch.addingTimeInterval(2))
        var closedZ = z.route; closedZ.status = .completed
        _ = try disk.commit([ChangeSet([.transitionExecution(z.route.id, expected: nil, session: activeZ)], label: "Start Z"),
                               ChangeSet([.transitionExecution(z.route.id, expected: activeZ, session: finishedZ), .updateRoute(closedZ, bumpRevision: false)], label: "Finish Z"),
                               ChangeSet([.transitionExecution(a.route.id, expected: finishedZ, session: activeA)], label: "Start A")], synchronize: true)
        let remote = ExecutionReplayFixture([z, a])
        let backend = DurableRouteBackend(remote: LocalRouteBackend(fileURL: url()), ownerID: "owner", persistence: disk, transport: remote, authenticatedOwner: { "owner" })
        await backend.synchronize(); await backend.synchronize()
        #expect(remote.replayedRoutes == ["z-route", "z-route", "a-route"])
        #expect(try disk.commands().allSatisfy { $0.state == .verified })
        #expect(backend.currentExecutionSession?.matches(activeA) == true)
        backend.suspend()
    }

    @Test("Blocked or authentication execution commands fence later lifecycle changes account-wide", arguments: [DurableCommand.State.blocked, .authentication])
    func accountWideFailureFence(state: DurableCommand.State) throws {
        let disk = try ActiveRoutePersistence(ownerID: "owner", databaseURL: url())
        let a = snapshot("a"), b = snapshot("b"); try disk.pin(a); try disk.pin(b)
        let active = RouteExecutionSession(routeID: "a", now: epoch), finished = transition(active, to: .finished)
        var closed = a.route; closed.status = .completed
        _ = try disk.commit([ChangeSet([.transitionExecution("a", expected: nil, session: active)], label: "Start A"),
                               ChangeSet([.transitionExecution("a", expected: active, session: finished), .updateRoute(closed, bumpRevision: false)], label: "Finish A")], synchronize: true)
        var command = try #require(try disk.commands(routeID: "a").last)
        command.state = state; command.lastError = "Preserved sync problem"; try disk.update(command)
        let next = RouteExecutionSession(routeID: "b", now: epoch.addingTimeInterval(2))
        let start = ChangeSet([.transitionExecution("b", expected: finished, session: next)], label: "Start B")
        #expect(throws: LocalPersistenceFailure.self) { try disk.commit([start], synchronize: true) }
        #expect(try disk.executionSession()?.state == .finished && disk.commands().count == 2)
        command.state = .pending; command.lastError = nil; try disk.update(command)
        _ = try disk.commit([start], synchronize: true)
        #expect(try disk.executionSession()?.matches(next) == true && disk.commands().count == 3)
    }

    private func sql(_ query: String, at path: URL) throws {
        var connection: OpaquePointer?
        guard sqlite3_open(path.path, &connection) == SQLITE_OK else { throw LocalPersistenceFailure.storage("test open") }
        defer { sqlite3_close(connection) }
        guard sqlite3_exec(connection, query, nil, nil, nil) == SQLITE_OK else { throw LocalPersistenceFailure.storage("test SQL") }
    }
    private func count(_ query: String, at path: URL) throws -> Int {
        var connection: OpaquePointer?, statement: OpaquePointer?
        guard sqlite3_open(path.path, &connection) == SQLITE_OK else { throw LocalPersistenceFailure.storage("test open") }
        defer { sqlite3_finalize(statement); sqlite3_close(connection) }
        guard sqlite3_prepare_v2(connection, query, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else { throw LocalPersistenceFailure.storage("test count") }
        return Int(sqlite3_column_int64(statement, 0))
    }
}

@MainActor
private final class ExecutionReplayFixture: ExecutionSessionTransport {
    var session: RouteExecutionSession?
    var routes: [RouteID: RouteSnapshot]
    var receipts = Set<String>()
    var replayedRoutes: [RouteID] = []
    init(_ snapshots: [RouteSnapshot]) { routes = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.route.id, $0) }) }
    func replay(_ command: DurableCommand) async -> RemoteReplayResult {
        if receipts.contains(command.id) { return .verified }
        for operation in command.ops {
            if case let .transitionExecution(_, expected, next) = operation {
                guard (session == nil && expected == nil) || (session != nil && expected != nil && session!.matches(expected!)) else { return .blocked("execution conflict") }
                do { try RouteExecutionSession.validateTransition(from: session, to: next) }
                catch { return .blocked("invalid transition") }
                session = next
            }
            if case let .updateRoute(route, _) = operation { routes[route.id]?.route = route }
        }
        receipts.insert(command.id); replayedRoutes.append(command.routeID); return .verified
    }
    func fetchVerifiedExecutionSession() async throws -> RouteExecutionSession? { session }
    func fetchVerifiedRoute(_ id: RouteID) async throws -> RouteSnapshot? { routes[id] }
}
