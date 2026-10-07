import FirebaseAuth
import FirebaseFirestore
import Foundation
import ParcelPilotKit
import Testing
@testable import ParcelPilot

/// Real SDK transactions, production rules, and server-source receipts. Emulator-only fixtures
/// have isolated anonymous accounts and never call production resources.
@MainActor
@Suite("Explicit execution Firebase replay", .serialized, .enabled(if: ProcessInfo.processInfo.environment["PP_EMULATOR"] == "1"))
struct ExecutionReplayTests {
    typealias Environment = FirestoreDurableReplayTests.Environment
    let fixtures = FirestoreDurableReplayTests()

    func environment() async throws -> Environment {
        var env = try await fixtures.environment()
        env.route.status = .active
        env.route.appliedRequestID = "accepted-fixture"
        env.route.appliedRevision = env.route.inputRevision
        try await fixtures.root(env).updateData(["status": "active", "appliedRequestID": "accepted-fixture", "appliedRevision": env.route.inputRevision])
        return env
    }

    func step(_ value: RouteExecutionSession, to state: RouteExecutionSession.State) -> RouteExecutionSession {
        var next = value
        next.state = state; next.transitionCount += 1
        next.changedAt = max(Date(), value.changedAt.addingTimeInterval(0.000_020))
        return next
    }

    func transition(_ env: Environment, from expected: RouteExecutionSession?, to next: RouteExecutionSession,
                    sequence: Int64 = 1, other: [ChangeOp] = []) -> DurableCommand {
        fixtures.command(env, ops: [.transitionExecution(env.route.id, expected: expected, session: next)] + other, sequence: sequence)
    }

    @Test("Start Pause Resume Finish have one singleton and stable receipts; session-only actions preserve revision")
    func lifecycleAndDuplicateReplay() async throws {
        let env = try await environment()
        let wireBoundary = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) + 0.000_000_95)
        let start = RouteExecutionSession(routeID: env.route.id, startedAt: wireBoundary)
        let pause = step(start, to: .paused)
        let resume = step(pause, to: .active)
        let finish = step(resume, to: .finished)
        var closed = env.route; closed.status = .completed; closed.completedAt = finish.changedAt; closed.updatedAt = finish.changedAt
        let commands = [
            transition(env, from: nil, to: start),
            transition(env, from: start, to: pause, sequence: 2),
            transition(env, from: pause, to: resume, sequence: 3),
            transition(env, from: resume, to: finish, sequence: 4, other: [.updateRoute(closed, bumpRevision: false)]),
        ]
        for (command, expected) in zip(commands, [start, pause, resume, finish]) {
            fixtures.requireVerified(await env.backend.replay(command))
            fixtures.requireVerified(await env.backend.replay(command))
            let server = try #require(try await env.backend.fetchVerifiedExecutionSession())
            #expect(server.matches(expected))
        }
        #expect(try await fixtures.root(env).getDocument(source: .server).get("inputRevision") as? Int == 2)
        #expect(try await fixtures.root(env).collection("mutationReceipts").getDocuments(source: .server).count == 4)
        #expect(try await fixtures.root(env).collection("outcomes").getDocuments(source: .server).isEmpty)
        // Replaying an already acknowledged old Start after Finish cannot reactivate anything.
        fixtures.requireVerified(await env.backend.replay(commands[0]))
        #expect(try await env.backend.fetchVerifiedExecutionSession()?.state == .finished)
    }

    @Test("Server-applied Start with lost local receipt restores offline and verifies the same command once")
    func protectedRestartAfterLostReceipt() async throws {
        let env = try await environment()
        var stop = env.stop; stop.addressStatus = .driverConfirmed
        stop.resolution = StopResolution(provider: nil, placeID: nil,
            located: LocatedPoint(point: GeoPoint(latitude: 48.4, longitude: -123.3), source: .driverPin), match: .driverPin, resolvedAt: Date())
        try await fixtures.root(env).collection("stops").document(stop.id).setData(Firestore.Encoder().encode(stop))
        let initial = try #require(try await env.backend.fetchVerifiedRoute(env.route.id))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("session-receipt-\(UUID().uuidString)/operations.sqlite")
        let disk = try ActiveRoutePersistence(ownerID: env.uid, databaseURL: url)
        try disk.pin(initial, selected: true)
        let protected = DurableRouteBackend(remote: env.backend, ownerID: env.uid, persistence: disk, transport: env.backend,
            authenticatedOwner: { Auth.auth(app: env.db.app).currentUser?.uid })
        protected.networkAvailable = false
        let store = RouteStore(backend: protected)
        #expect(store.startExecution(initial).isCommitted)
        let session = try #require(store.executionSession)
        var command = try #require(try disk.commands().first)
        command.state = .sending; try disk.update(command)
        fixtures.requireVerified(await env.backend.replay(command))
        // Terminate after Firebase applied the receipt, before the local verified status write.
        protected.suspend()
        try await env.db.disableNetwork()
        let reopened = try ActiveRoutePersistence(ownerID: env.uid, databaseURL: url)
        let recovered = DurableRouteBackend(remote: env.backend, ownerID: env.uid, persistence: reopened, transport: env.backend,
            authenticatedOwner: { Auth.auth(app: env.db.app).currentUser?.uid })
        recovered.networkAvailable = false
        let restored = RouteStore(backend: recovered)
        #expect(restored.executionSession?.matches(session) == true && restored.currentRouteID == env.route.id)
        #expect(try reopened.commands().first?.state == .pending)
        try await env.db.enableNetwork()
        recovered.networkAvailable = true; await recovered.synchronize()
        #expect(try reopened.commands().first?.state == .verified)
        #expect(restored.executionSession?.matches(session) == true)
        #expect(try await fixtures.root(env).collection("mutationReceipts").getDocuments(source: .server).count == 1)
        #expect(try await env.backend.fetchVerifiedExecutionSession()?.transitionCount == 0)
        recovered.suspend()
    }

    @Test("An expected-session mismatch blocks preserved intent rather than overwriting the newer decision")
    func compareAndSetConflict() async throws {
        let env = try await environment()
        let start = RouteExecutionSession(routeID: env.route.id, startedAt: Date())
        fixtures.requireVerified(await env.backend.replay(transition(env, from: nil, to: start)))
        let pause = step(start, to: .paused)
        fixtures.requireVerified(await env.backend.replay(transition(env, from: start, to: pause, sequence: 2)))
        let competingFinish = step(start, to: .finished)
        var closed = env.route; closed.status = .completed; closed.completedAt = Date()
        fixtures.requireBlocked(await env.backend.replay(transition(env, from: start, to: competingFinish, sequence: 3,
                                                                   other: [.updateRoute(closed, bumpRevision: false)])))
        let server = try #require(try await env.backend.fetchVerifiedExecutionSession())
        #expect(server.matches(pause))
        #expect(try await fixtures.root(env).getDocument(source: .server).get("status") as? String == "active")
        #expect(try await fixtures.root(env).collection("mutationReceipts").getDocuments(source: .server).count == 2)
    }

    @Test("Finish needs atomic close-out and raw archive cannot orphan active or paused execution")
    func atomicFinishAndArchiveGuard() async throws {
        let env = try await environment()
        let start = RouteExecutionSession(routeID: env.route.id, startedAt: Date())
        fixtures.requireVerified(await env.backend.replay(transition(env, from: nil, to: start)))
        fixtures.requireBlocked(await env.backend.replay(transition(env, from: start, to: step(start, to: .finished), sequence: 2)))
        await #expect(throws: (any Error).self) { try await fixtures.root(env).updateData(["status": "archived", "archivedAt": Timestamp(date: Date())]) }
        let pause = step(start, to: .paused)
        fixtures.requireVerified(await env.backend.replay(transition(env, from: start, to: pause, sequence: 2)))
        await #expect(throws: (any Error).self) { try await fixtures.root(env).updateData(["status": "completed", "completedAt": Timestamp(date: Date())]) }
        let server = try #require(try await env.backend.fetchVerifiedExecutionSession())
        #expect(server.matches(pause))
    }

    @Test("Finish route A then Start route B preserves the account-wide chain and receipt replay cannot revive A")
    func crossRouteChain() async throws {
        let env = try await environment()
        let start = RouteExecutionSession(routeID: env.route.id, startedAt: Date())
        fixtures.requireVerified(await env.backend.replay(transition(env, from: nil, to: start)))
        var second = env
        second.route = Route(name: "Route B", serviceDate: "2026-10-06", timeZoneID: "America/Vancouver")
        second.route.inputRevision = 2; second.route.status = .active
        second.route.appliedRequestID = "accepted-route-b"; second.route.appliedRevision = 2
        try await fixtures.root(second).setData(FirestoreRouteBackend.routeData(second.route))
        var startB = RouteExecutionSession(routeID: second.route.id, startedAt: Date())
        fixtures.requireBlocked(await env.backend.replay(transition(second, from: nil, to: startB)))
        let finish = step(start, to: .finished)
        var closed = env.route; closed.status = .completed; closed.completedAt = finish.changedAt
        let finishCommand = transition(env, from: start, to: finish, sequence: 2, other: [.updateRoute(closed, bumpRevision: false)])
        fixtures.requireVerified(await env.backend.replay(finishCommand))
        startB.startedAt = max(Date(), finish.changedAt.addingTimeInterval(0.000_020)); startB.changedAt = startB.startedAt
        fixtures.requireVerified(await env.backend.replay(transition(second, from: finish, to: startB)))
        fixtures.requireVerified(await env.backend.replay(finishCommand))
        let server = try #require(try await env.backend.fetchVerifiedExecutionSession())
        #expect(server.matches(startB))
        #expect(server.routeID == second.route.id)
    }

    @Test("Concurrent Starts on two routes admit exactly one unfinished account session")
    func concurrentStarts() async throws {
        let env = try await environment()
        var second = env
        second.route = Route(name: "Concurrent B", serviceDate: "2026-10-06", timeZoneID: "America/Vancouver")
        second.route.inputRevision = 2; second.route.status = .active
        second.route.appliedRequestID = "accepted-concurrent-b"; second.route.appliedRevision = 2
        try await fixtures.root(second).setData(FirestoreRouteBackend.routeData(second.route))
        let firstSession = RouteExecutionSession(routeID: env.route.id, startedAt: Date())
        let secondSession = RouteExecutionSession(routeID: second.route.id, startedAt: Date())
        async let first = env.backend.replay(transition(env, from: nil, to: firstSession))
        async let other = env.backend.replay(transition(second, from: nil, to: secondSession))
        let results = await [first, other]
        #expect(results.filter { if case .verified = $0 { true } else { false } }.count == 1)
        #expect(results.filter { if case .blocked = $0 { true } else { false } }.count == 1)
        let server = try #require(try await env.backend.fetchVerifiedExecutionSession())
        #expect(server.matches(firstSession) || server.matches(secondSession))
    }

    @Test("Work changes invalidate proposals without starting, pausing or finishing execution")
    func workIndependentOfExecution() async throws {
        var env = try await environment()
        let delivered = TaskOutcome(packageID: env.package.id, stopID: env.stop.id, kind: .delivered)
        fixtures.requireVerified(await env.backend.replay(fixtures.command(env, ops: [.createOutcome(env.route.id, delivered), .bumpRouteRevision(env.route.id, expectedMinimum: 3)])))
        #expect(try await env.backend.fetchVerifiedExecutionSession() == nil)
        env.route.inputRevision = 3 // appliedRevision remains 2: accepted ordering survives work revisions.
        let start = RouteExecutionSession(routeID: env.route.id, startedAt: Date())
        fixtures.requireVerified(await env.backend.replay(transition(env, from: nil, to: start, sequence: 2)))
        let collected = TaskOutcome(taskID: env.task.id, stopID: env.stop.id, kind: .completed)
        fixtures.requireVerified(await env.backend.replay(fixtures.command(env, ops: [.createOutcome(env.route.id, collected), .bumpRouteRevision(env.route.id, expectedMinimum: 4)], sequence: 3)))
        let server = try #require(try await env.backend.fetchVerifiedExecutionSession())
        #expect(server.matches(start))
        #expect(try await env.backend.fetchVerifiedRoute(env.route.id)?.workSummary.pending == 0)
    }

    @Test("Owner mismatch cannot replay or read, and the raw SDK compatibility API refuses session actions")
    func ownerAndCompatibilityBoundary() async throws {
        let env = try await environment()
        let start = RouteExecutionSession(routeID: env.route.id, startedAt: Date())
        var wrong = transition(env, from: nil, to: start); wrong.accountID = "another-account"
        if case .authentication = await env.backend.replay(wrong) {} else { Issue.record("Wrong-account replay must be authentication-gated") }
        let result = env.backend.commit(ChangeSet([.transitionExecution(env.route.id, expected: nil, session: start)], label: "Start", critical: true))
        #expect(!result.isCommitted)
        #expect(try await env.backend.fetchVerifiedExecutionSession() == nil)
        try Auth.auth(app: env.db.app).signOut()
        await #expect(throws: (any Error).self) { try await env.backend.fetchVerifiedExecutionSession() }
    }

    @Test("Server unavailability and corrupt or future execution documents throw rather than becoming not-started")
    func unavailableAndCorruptRead() async throws {
        let env = try await environment()
        #expect(try await env.backend.fetchVerifiedExecutionSession() == nil)
        try await env.db.disableNetwork()
        await #expect(throws: (any Error).self) { try await env.backend.fetchVerifiedExecutionSession() }
        try await env.db.enableNetwork()
        let path = "users/\(env.uid)/execution/current"
        try await fixtures.administrator(path: path, method: "PATCH", fields: ["id": ["stringValue": "malformed"]])
        await #expect(throws: (any Error).self) { try await env.backend.fetchVerifiedExecutionSession() }
        let at = ISO8601DateFormatter().string(from: Date())
        try await fixtures.administrator(path: path, method: "PATCH", fields: [
            "id": ["stringValue": "future"], "routeID": ["stringValue": env.route.id], "schemaVersion": ["integerValue": "2"],
            "state": ["stringValue": "active"], "startedAt": ["timestampValue": at], "changedAt": ["timestampValue": at], "transitionCount": ["integerValue": "0"],
        ])
        await #expect(throws: (any Error).self) { try await env.backend.fetchVerifiedExecutionSession() }
    }
}
