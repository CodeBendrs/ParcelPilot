import FirebaseAuth
import FirebaseFirestore
import Foundation
import ParcelPilotKit
import Testing
@testable import ParcelPilot

/// Exercises production store entry against SQLite and the real Firebase transaction/receipt
/// transport. An empty listener adapter deliberately cannot supply a cache on relaunch.
@MainActor
@Suite("Production task Firebase replay", .serialized, .enabled(if: ProcessInfo.processInfo.environment["PP_EMULATOR"] == "1"))
struct TaskDefinitionReplayTests {
    typealias Environment = FirestoreDurableReplayTests.Environment
    let fixtures = FirestoreDurableReplayTests()

    private func environment() async throws -> Environment {
        var env = try await fixtures.environment()
        env.route.status = .active; env.route.inputRevision = 3
        env.route.appliedRequestID = "accepted-work-entry"; env.route.appliedRevision = 3
        env.stop.addressStatus = .driverConfirmed
        env.stop.resolution = StopResolution(provider: nil, placeID: nil,
            located: LocatedPoint(point: GeoPoint(latitude: 48.4, longitude: -123.3), source: .driverPin),
            match: .driverPin, resolvedAt: Date())
        env.task.required = false // Existing optional work remains visible but cannot create a visit.
        let batch = env.db.batch()
        batch.updateData(["status": "active", "inputRevision": 3, "appliedRequestID": "accepted-work-entry", "appliedRevision": 3], forDocument: fixtures.root(env))
        try batch.setData(from: env.stop, forDocument: fixtures.root(env).collection("stops").document(env.stop.id))
        try batch.setData(from: env.task, forDocument: fixtures.root(env).collection("tasks").document(env.task.id))
        try await batch.commit()
        return env
    }

    private func url() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("task-entry-replay-\(UUID().uuidString)/operations.sqlite")
    }
    private func protected(_ env: Environment, disk: ActiveRoutePersistence) -> DurableRouteBackend {
        let backend = DurableRouteBackend(remote: TaskReplayEmptyCache(), ownerID: env.uid, persistence: disk,
            transport: env.backend, authenticatedOwner: { Auth.auth(app: env.db.app).currentUser?.uid })
        backend.networkAvailable = false
        return backend
    }
    private func store(_ backend: DurableRouteBackend) -> RouteStore {
        RouteStore(backend: backend, generalizedWorkAvailability: .development)
    }

    @Test("Offline pickup/checklist entry, outcomes, Retry and immediate Undo termination replay once")
    func offlineEntryOutcomesRestartAndReceipts() async throws {
        let env = try await environment(), path = url()
        let initial = try #require(try await env.backend.fetchVerifiedRoute(env.route.id))
        var disk: ActiveRoutePersistence? = try ActiveRoutePersistence(ownerID: env.uid, databaseURL: path)
        try disk!.pin(initial, selected: true)
        try await env.db.disableNetwork()
        var backend: DurableRouteBackend? = protected(env, disk: disk!)
        var current: RouteStore? = store(backend!)
        #expect(current!.startExecution(initial).isCommitted)
        let session = try #require(current!.executionSession)
        let pickup = LocationTask(stopID: env.stop.id, kind: .pickup, title: "Collect return", instructions: "Ask reception for the blue bag")
        let checklist = LocationTask(stopID: env.stop.id, kind: .checklist, title: "Confirm parcel count", instructions: "Two parcels expected", orderRank: 1)
        #expect(current!.saveTask(pickup, in: try #require(current!.current)).isCommitted)
        #expect(current!.saveTask(checklist, in: try #require(current!.current)).isCommitted)
        var eventIDs: [OutcomeID] = []
        for (kind, taskID) in [(OutcomeKind.delivered, LocationTask.deliveryID(for: env.package.id)), (.completed, checklist.id), (.skipped, pickup.id)] {
            let action = current!.recordWorkAction(kind, taskIDs: [taskID], in: try #require(current!.current), label: "Explicit work offline")
            #expect(action.isCommitted && action.outcomeIDs.count == 1)
            eventIDs += action.outcomeIDs
        }
        #expect(current!.current?.workSummary.completed == 2 && current!.current?.workSummary.deferred == 1)
        #expect(current!.executionSession?.matches(session) == true)
        backend!.suspend(); current = nil; backend = nil; disk = nil

        disk = try ActiveRoutePersistence(ownerID: env.uid, databaseURL: path)
        backend = protected(env, disk: disk!); current = store(backend!)
        #expect(current!.currentRouteID == env.route.id && current!.executionSession?.matches(session) == true)
        let recovered = try #require(current!.current)
        #expect(recovered.tasks.first { $0.id == pickup.id }?.instructions == pickup.instructions)
        #expect(recovered.tasks.first { $0.id == checklist.id }?.instructions == checklist.instructions)
        #expect(Set(recovered.outcomes.map(\.id)) == Set(eventIDs))
        #expect(recovered.workSummary.deferred == 1 && recovered.nextStop()?.id == env.stop.id)
        #expect(!recovered.workLedger.hasActionableRequiredWork(at: env.stop.id))
        #expect(Eligibility.evaluate(recovered, now: Date(), demoMode: true).eligible.isEmpty)
        let retry = current!.recordWorkAction(.requeued, taskIDs: [pickup.id], in: recovered, label: "Retry pickup")
        #expect(retry.isCommitted && retry.outcomeIDs.count == 1); eventIDs += retry.outcomeIDs
        #expect(current!.current?.nextStop()?.id == env.stop.id)
        let completed = current!.recordWorkAction(.completed, taskIDs: [pickup.id], in: try #require(current!.current), label: "Picked up")
        #expect(completed.isCommitted && completed.outcomeIDs.count == 1); eventIDs += completed.outcomeIDs
        #expect(current!.undo(outcomeIDs: completed.outcomeIDs, in: try #require(current!.current)).isCommitted)
        // Termination immediately after Undo must restore pending state, not the success screen.
        backend!.suspend(); current = nil; backend = nil; disk = nil
        disk = try ActiveRoutePersistence(ownerID: env.uid, databaseURL: path)
        backend = protected(env, disk: disk!); current = store(backend!)
        #expect(current!.current?.workLedger.status(of: pickup.id) == .pending)
        let finalPickup = current!.recordWorkAction(.completed, taskIDs: [pickup.id], in: try #require(current!.current), label: "Picked up")
        #expect(finalPickup.isCommitted && finalPickup.outcomeIDs.count == 1); eventIDs += finalPickup.outcomeIDs
        #expect(current!.current?.workSummary.completed == 3 && current!.current?.workSummary.pending == 0)
        #expect(current!.current?.workLedger.status(of: env.task.id) == .pending) // Optional sibling unchanged.
        #expect(current!.executionSession?.matches(session) == true) // All work cannot auto-Finish.
        let commands = try disk!.commands()
        #expect(commands.count == 10 && commands.map(\.sequence) == Array(1...10).map(Int64.init))
        try await env.db.enableNetwork(); backend!.networkAvailable = true
        await backend!.synchronize()
        #expect(try disk!.commands().allSatisfy { $0.state == .verified })
        // Recognition of every existing immutable receipt must not replay old materializations.
        for command in commands { fixtures.requireVerified(await env.backend.replay(command)) }
        let server = try #require(try await env.backend.fetchVerifiedRoute(env.route.id))
        #expect(server.tasks.count == 3 && server.outcomes.count == eventIDs.count)
        #expect(Set(server.outcomes.map(\.id)) == Set(eventIDs))
        #expect(server.outcomes.first { $0.id == completed.outcomeIDs[0] }?.voidedAt != nil)
        #expect(server.workSummary.completed == 3 && server.workSummary.deferred == 0)
        #expect(try await fixtures.root(env).collection("mutationReceipts").getDocuments(source: .server).count == commands.count)
        #expect(try await env.backend.fetchVerifiedExecutionSession()?.matches(session) == true)
        backend!.suspend(); current = nil; backend = nil; disk = nil
        let finalDisk = try ActiveRoutePersistence(ownerID: env.uid, databaseURL: path)
        let final = try #require(try finalDisk.snapshot(env.route.id))
        #expect(final.outcomes.count == eventIDs.count && final.workSummary.completed == 3)
        #expect(try finalDisk.commands().allSatisfy { $0.state == .verified })
        #expect(try finalDisk.executionSession()?.matches(session) == true)
    }

    @Test("Offline create, edit and no-history delete stay FIFO across restart with no remote resurrection")
    func pendingDefinitionChain() async throws {
        let env = try await environment(), path = url()
        let disk = try ActiveRoutePersistence(ownerID: env.uid, databaseURL: path)
        try disk.pin(try #require(try await env.backend.fetchVerifiedRoute(env.route.id)), selected: true)
        let backend = protected(env, disk: disk), current = store(backend)
        var task = LocationTask(stopID: env.stop.id, kind: .checklist, title: "New item", instructions: "Original instructions")
        #expect(current.saveTask(task, in: try #require(current.current)).isCommitted)
        task = try #require(current.current?.tasks.first { $0.id == task.id })
        task.title = "Revised item"; task.instructions = "Revised instructions"; task.required = false; task.orderRank = 4
        #expect(current.saveTask(task, in: try #require(current.current)).isCommitted)
        task = try #require(current.current?.tasks.first { $0.id == task.id })
        #expect(current.deleteTask(task, in: try #require(current.current)).isCommitted)
        #expect(current.current?.tasks.contains { $0.id == task.id } == false)
        let commands = try disk.commands(); #expect(commands.count == 3 && commands.map(\.sequence) == [1, 2, 3])
        backend.suspend()
        let reopened = try ActiveRoutePersistence(ownerID: env.uid, databaseURL: path)
        let replay = protected(env, disk: reopened); replay.networkAvailable = true; await replay.synchronize()
        #expect(try reopened.commands().allSatisfy { $0.state == .verified })
        for command in commands { fixtures.requireVerified(await env.backend.replay(command)) }
        #expect(try await fixtures.root(env).collection("tasks").document(task.id).getDocument(source: .server).exists == false)
        #expect(try await fixtures.root(env).collection("outcomes").getDocuments(source: .server).isEmpty)
        #expect(try await fixtures.root(env).collection("mutationReceipts").getDocuments(source: .server).count == 3)
        replay.suspend()
    }

    @Test("Concurrent server outcome history rejects stale standalone deletion and keeps the entire suffix")
    func historyRaceBlocksDelete() async throws {
        let env = try await environment(), disk = try ActiveRoutePersistence(ownerID: env.uid, databaseURL: url())
        let initial = try #require(try await env.backend.fetchVerifiedRoute(env.route.id)); try disk.pin(initial, selected: true)
        let backend = protected(env, disk: disk), current = store(backend)
        let known = try #require(current.current?.tasks.first { $0.id == env.task.id })
        #expect(current.deleteTask(known, in: try #require(current.current)).isCommitted)
        let suffix = LocationTask(stopID: env.stop.id, kind: .checklist, title: "Preserved local suffix")
        #expect(current.saveTask(suffix, in: try #require(current.current)).isCommitted)
        let event = TaskOutcome(taskID: env.task.id, stopID: env.stop.id, kind: .completed)
        fixtures.requireVerified(await env.backend.replay(fixtures.command(env,
            ops: [.createOutcome(env.route.id, event), .bumpRouteRevision(env.route.id, expectedMinimum: 4)])))
        backend.networkAvailable = true; await backend.synchronize()
        let commands = try disk.commands()
        #expect(commands.count == 2 && commands[0].state == .blocked && commands[1].state == .pending)
        #expect(backend.recoveryMessage != nil)
        #expect(try await fixtures.root(env).collection("tasks").document(env.task.id).getDocument(source: .server).exists)
        let server = try #require(try await env.backend.fetchVerifiedRoute(env.route.id))
        #expect(server.outcomes.map(\.id) == [event.id] && server.tasks.contains { $0.id == env.task.id })
        #expect(try disk.snapshot(env.route.id)?.tasks.contains { $0.id == suffix.id } == true)
        #expect(!current.saveTask(LocationTask(stopID: env.stop.id, kind: .pickup, title: "Blocked new intent"), in: try #require(current.current)).isCommitted)
        backend.suspend()
    }

    @Test("Remote task deletion without revision cannot silently recreate a task or acknowledge its outcome")
    func remoteDefinitionDeletion() async throws {
        let env = try await environment(), disk = try ActiveRoutePersistence(ownerID: env.uid, databaseURL: url())
        let initial = try #require(try await env.backend.fetchVerifiedRoute(env.route.id)); try disk.pin(initial, selected: true)
        let backend = protected(env, disk: disk), current = store(backend)
        var edited = try #require(current.current?.tasks.first { $0.id == env.task.id }); edited.instructions = "Preserved local correction"
        #expect(current.saveTask(edited, in: try #require(current.current)).isCommitted)
        try await fixtures.administrator(path: "users/\(env.uid)/routes/\(env.route.id)/tasks/\(env.task.id)", method: "DELETE")
        backend.networkAvailable = true; await backend.synchronize()
        #expect(try disk.commands().first?.state == .blocked)
        #expect(try disk.snapshot(env.route.id)?.tasks.first { $0.id == env.task.id }?.instructions == edited.instructions)
        #expect(try await fixtures.root(env).collection("tasks").document(env.task.id).getDocument(source: .server).exists == false)
        #expect(try await fixtures.root(env).collection("mutationReceipts").getDocuments(source: .server).isEmpty)
        backend.suspend()
    }

    @Test("Task rules rejection preserves acknowledged definition and cannot fabricate a receipt")
    func serverValidationRejection() async throws {
        let env = try await environment(), disk = try ActiveRoutePersistence(ownerID: env.uid, databaseURL: url())
        try disk.pin(try #require(try await env.backend.fetchVerifiedRoute(env.route.id)), selected: true)
        let backend = protected(env, disk: disk)
        var invalid = try #require(try disk.snapshot(env.route.id)?.tasks.first { $0.id == env.task.id }); invalid.title = String(repeating: "x", count: 121)
        // Low-level fault fixture bypasses entry validation so actual production rules are exercised.
        #expect(backend.commit(ChangeSet([.putTask(env.route.id, invalid), .bumpRouteRevision(env.route.id, expectedMinimum: 4)], label: "Invalid fixture", critical: true)).isCommitted)
        backend.networkAvailable = true; await backend.synchronize()
        #expect(try disk.commands().first?.state == .blocked && backend.recoveryMessage != nil)
        #expect(try disk.snapshot(env.route.id)?.tasks.first { $0.id == env.task.id }?.title == invalid.title)
        #expect(try await fixtures.root(env).collection("tasks").document(env.task.id).getDocument(source: .server).get("title") as? String == env.task.title)
        #expect(try await fixtures.root(env).collection("mutationReceipts").getDocuments(source: .server).isEmpty)
        backend.suspend()
    }

    @Test("Production creation gate does not hide known work; local failure and wrong account cannot acknowledge entry")
    func gateStorageAndAccountBoundaries() async throws {
        let env = try await environment(), path = url(), disk = try ActiveRoutePersistence(ownerID: env.uid, databaseURL: path)
        let initial = try #require(try await env.backend.fetchVerifiedRoute(env.route.id)); try disk.pin(initial, selected: true)
        let backend = protected(env, disk: disk)
        let locked = RouteStore(backend: backend, generalizedWorkAvailability: .compatibilityReviewRequired)
        #expect(locked.current?.tasks.contains { $0.id == env.task.id } == true)
        let fresh = LocationTask(stopID: env.stop.id, kind: .pickup, title: "New pickup")
        #expect(!locked.saveTask(fresh, in: initial).isCommitted)
        #expect(try disk.commands().isEmpty)
        let current = store(backend)
        disk.injectFailure = { if case .beforeCommit = $0 { throw LocalPersistenceFailure.storage("Full device") } }
        #expect(!current.saveTask(fresh, in: initial).isCommitted)
        #expect(current.current?.tasks.contains { $0.id == fresh.id } == false)
        #expect(try disk.commands().isEmpty)
        disk.injectFailure = nil
        #expect(current.saveTask(fresh, in: initial).isCommitted)
        let command = try #require(try disk.commands().first)
        try Auth.auth(app: env.db.app).signOut()
        _ = try await Auth.auth(app: env.db.app).signInAnonymously()
        #expect(Auth.auth(app: env.db.app).currentUser?.uid != env.uid)
        #expect(!current.saveTask(LocationTask(stopID: env.stop.id, kind: .checklist, title: "Wrong owner"), in: try #require(current.current)).isCommitted)
        if case .authentication = await env.backend.replay(command) {} else { Issue.record("Wrong-account task replay must stay fenced") }
        #expect(throws: LocalPersistenceFailure.ownership) { try ActiveRoutePersistence(ownerID: "other-owner", databaseURL: path) }
        #expect(try disk.commands().count == 1 && disk.snapshot(env.route.id)?.tasks.contains { $0.id == fresh.id } == true)
        backend.suspend()
    }
}

@MainActor
private final class TaskReplayEmptyCache: RouteBackend {
    let kind = BackendKind.firestore
    func observeRoutes(_ onChange: @escaping ([Route], Set<String>) -> Void) -> ListenerToken { onChange([], []); return ListenerToken {} }
    func observeRoute(_ id: RouteID, _ onChange: @escaping (RouteSnapshotEnvelope?) -> Void) -> ListenerToken { onChange(nil); return ListenerToken {} }
    func commit(_ change: ChangeSet) -> LocalCommitResult { .failed(.storage("No cache mutation is permitted")) }
    func loadSettings() async -> UserSettings? { nil }
    func saveSettings(_ settings: UserSettings) {}
    func fetchRoute(_ id: RouteID) async throws -> RouteSnapshot? { nil }
}
