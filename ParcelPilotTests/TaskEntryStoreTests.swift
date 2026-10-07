import Foundation
import ParcelPilotKit
import Testing
@testable import ParcelPilot

@MainActor
@Suite("Protected production work entry", .serialized)
struct TaskEntryStoreTests {
    private let epoch = Date(timeIntervalSince1970: 1_790_100_000)

    private func fixture() -> RouteSnapshot {
        var route = Route(id: "work-route", name: "Work route", serviceDate: "2026-10-06", timeZoneID: "America/Vancouver", now: epoch)
        route.start = RoutePlace(label: "Depot", located: LocatedPoint(point: GeoPoint(latitude: 48.41, longitude: -123.31), source: .driverPin))
        route.appliedRequestID = "accepted"; route.appliedRevision = route.inputRevision
        let resolution = StopResolution(provider: nil, placeID: nil,
            located: LocatedPoint(point: GeoPoint(latitude: 48.4, longitude: -123.3), source: .driverPin), match: .driverPin, resolvedAt: epoch)
        let stops = (1...3).map { number -> Stop in
            var address = PostalAddress.e1(); address.unit = String(200 + number)
            return Stop(id: "stop-\(number)", address: address, addressStatus: .driverConfirmed, resolution: resolution, sequence: Double(number), now: epoch)
        }
        return RouteSnapshot(route: route, stops: stops, packages: [Package(id: "package", stopID: stops[0].id, source: .manual, now: epoch)], outcomes: [])
    }
    private func disk(_ snapshot: RouteSnapshot? = nil) throws -> ActiveRoutePersistence {
        let disk = try ActiveRoutePersistence(ownerID: "driver", databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("work-entry-\(UUID().uuidString)/operations.sqlite"))
        try disk.pin(snapshot ?? fixture(), selected: true)
        return disk
    }
    private func graph(_ disk: ActiveRoutePersistence, availability: GeneralizedWorkAvailability = .development,
                       owner: @escaping () -> String? = { "driver" }, telemetry: @escaping @MainActor (ExecutionPilotEvent) -> Void = { _ in }) -> RouteStore {
        let remote = LocalRouteBackend(fileURL: disk.databaseURL.deletingLastPathComponent().appendingPathComponent("unused.json"))
        let backend = DurableRouteBackend(remote: remote, ownerID: "driver", persistence: disk, transport: nil, authenticatedOwner: owner)
        backend.networkAvailable = false
        return RouteStore(backend: backend, clock: { epoch }, executionTelemetry: telemetry, generalizedWorkAvailability: availability)
    }
    private func live(_ store: RouteStore) throws -> RouteSnapshot { try #require(store.current) }
    private func task(_ kind: WorkKind = .pickup, stop: String = "stop-1", required: Bool = true) -> LocationTask {
        LocationTask(stopID: stop, kind: kind, required: required, title: kind == .pickup ? "Collect blue tote" : "Verify count", instructions: "Ask reception", now: epoch)
    }

    @Test("Pickup/checklist definitions, instructions and edits survive checked SQLite restart without starting execution")
    func definitionsAndEdits() throws {
        let disk = try disk(), store = graph(disk), before = try live(store)
        let pickup = task(), checklist = task(.checklist)
        #expect(store.saveTask(pickup, in: before).isCommitted)
        #expect(store.saveTask(checklist, in: try live(store)).isCommitted)
        let created = try #require(store.current?.tasks.first { $0.id == pickup.id })
        var edited = created; edited.title = "Collect red tote"; edited.instructions = "Door code 204"; edited.required = false; edited.orderRank = 9
        #expect(store.saveTask(edited, in: try live(store)).isCommitted)
        #expect(store.executionSession == nil)
        #expect(store.current?.route.inputRevision == before.route.inputRevision + 3)
        let restored = graph(try ActiveRoutePersistence(ownerID: "driver", databaseURL: disk.databaseURL))
        let saved = try #require(restored.current?.tasks.first { $0.id == pickup.id })
        #expect(saved.id == created.id && saved.createdAt == created.createdAt && saved.kind == created.kind)
        #expect(saved.title == edited.title && saved.instructions == edited.instructions && saved.orderRank == 9 && !saved.required)
        #expect(restored.current?.tasks.count == 2 && restored.executionSession == nil)
        #expect(try disk.commands().count == 3)
    }

    @Test("Material task edits invalidate proposals without changing accepted order or execution")
    func revisionsAndOrder() throws {
        let disk = try disk(), store = graph(disk), before = try live(store)
        #expect(store.startExecution(before).isCommitted)
        let session = store.executionSession
        let proposal = try DemoOptimizer().optimize(snapshot: before, options: OptimizationOptions(departNow: true), requestID: "stale", now: epoch)
        #expect(store.saveTask(task(), in: before).isCommitted)
        let after = try live(store)
        #expect(after.orderedStops.map(\.id) == before.orderedStops.map(\.id))
        #expect(after.route.appliedRequestID == before.route.appliedRequestID)
        #expect(after.route.inputRevision == before.route.inputRevision + 1 && store.executionSession == session)
        #expect(!store.apply(proposal, to: after).isCommitted)
    }

    @Test("One work action never dispositions sibling tasks, and the last outcome never Finishes execution")
    func independentMixedOutcomes() throws {
        let disk = try disk(), store = graph(disk)
        #expect(store.startExecution(try live(store)).isCommitted)
        let session = store.executionSession
        let pickups = [task(), task()], checks = [task(.checklist), task(.checklist)]
        for item in pickups + checks { #expect(store.saveTask(item, in: try live(store)).isCommitted) }
        let delivery = store.recordWorkAction(.delivered, taskIDs: [LocationTask.deliveryID(for: "package")], in: try live(store), label: "Delivered")
        #expect(delivery.isCommitted && delivery.outcomeIDs.count == 1)
        #expect(store.current?.workSummary.pending == 4 && store.current?.nextStop()?.id == "stop-1")
        let pickedUp = store.recordWorkAction(.completed, taskIDs: [pickups[0].id], in: try live(store), label: "Picked up")
        #expect(pickedUp.isCommitted && pickedUp.outcomeIDs.count == 1)
        #expect(store.current?.workLedger.status(of: pickups[1].id) == .pending)
        #expect(store.current?.workLedger.status(of: checks[0].id) == .pending)
        for item in [pickups[1]] + checks { #expect(store.recordWorkAction(.completed, taskIDs: [item.id], in: try live(store), label: "Done").isCommitted) }
        #expect(store.current?.workSummary.completed == 5 && store.current?.nextStop() == nil)
        #expect(store.executionSession == session && store.executionSession?.state == .active)
        #expect(store.current?.summary().delivered == 1)
        #expect(store.recordWorkAction(.completed, taskIDs: [pickups[0].id], in: try live(store), label: "Repeat").outcomeIDs.isEmpty)
    }

    @Test("Pickup-only/checklist-only visits preserve separate apartment identities despite identical coordinates")
    func independentUnitsAndOptionalEligibility() throws {
        let disk = try disk(), store = graph(disk)
        let pickup = task(stop: "stop-2"), checklist = task(.checklist, stop: "stop-3")
        let optional = task(.pickup, stop: "stop-1", required: false)
        for item in [pickup, checklist, optional] { #expect(store.saveTask(item, in: try live(store)).isCommitted) }
        let initial = try live(store)
        #expect(Set(Eligibility.evaluate(initial, now: epoch, demoMode: true).eligible.map(\.id)) == ["stop-1", "stop-2", "stop-3"])
        #expect(store.recordWorkAction(.delivered, taskIDs: [LocationTask.deliveryID(for: "package")], in: initial, label: "Delivered").isCommitted)
        let after = try live(store)
        #expect(after.nextStop()?.id == "stop-2")
        #expect(Set(Eligibility.evaluate(after, now: epoch, demoMode: true).eligible.map(\.id)) == ["stop-2", "stop-3"])
        #expect(after.workLedger.status(of: optional.id) == .pending)
        #expect(after.workLedger.tasks(at: "stop-2").map(\.id) == [pickup.id])
        #expect(after.workLedger.tasks(at: "stop-3").map(\.id) == [checklist.id])
    }

    @Test("Failed is handled unsuccessful; deferred is unfinished and ineligible until Retry; Undo of Retry restores it")
    func failDeferRetryUndoRestart() throws {
        let disk = try disk(), store = graph(disk), pickup = task(stop: "stop-2"), check = task(.checklist, stop: "stop-3")
        for item in [pickup, check] { #expect(store.saveTask(item, in: try live(store)).isCommitted) }
        let failure = store.recordWorkAction(.failed, taskIDs: [pickup.id], reason: .accessIssue, in: try live(store), label: "Failed")
        let deferred = store.recordWorkAction(.skipped, taskIDs: [check.id], in: try live(store), label: "Deferred")
        #expect(failure.isCommitted && deferred.isCommitted)
        let summary = try live(store).workSummary
        #expect(summary.failed == 1 && summary.deferred == 1 && summary.completed == 0)
        #expect(Eligibility.evaluate(try live(store), now: epoch, demoMode: true).eligible.map(\.id) == ["stop-1"])
        let retry = store.recordWorkAction(.requeued, taskIDs: [check.id], in: try live(store), label: "Retry")
        #expect(retry.isCommitted && store.current?.workLedger.status(of: check.id) == .pending)
        #expect(store.undo(outcomeIDs: retry.outcomeIDs, in: try live(store)).isCommitted)
        let restored = graph(try ActiveRoutePersistence(ownerID: "driver", databaseURL: disk.databaseURL))
        if case .deferred = restored.current?.workLedger.status(of: check.id) {} else { Issue.record("Undo of Retry must survive termination as deferred") }
        #expect(restored.current?.workSummary.failed == 1 && restored.current?.workSummary.deferred == 1)
        #expect(restored.recordWorkAction(.requeued, taskIDs: [pickup.id], in: try live(restored), label: "Retry failed").isCommitted)
        #expect(restored.recordWorkAction(.completed, taskIDs: [pickup.id], in: try live(restored), label: "Picked up").isCommitted)
    }

    @Test("Only no-history definitions can be deleted, including references from pending create/edit commands")
    func deletionHistoryAndFIFO() throws {
        let disk = try disk(), store = graph(disk), pending = task(), history = task(.checklist)
        #expect(store.saveTask(pending, in: try live(store)).isCommitted)
        let saved = try #require(store.current?.tasks.first { $0.id == pending.id })
        #expect(store.deleteTask(saved, in: try live(store)).isCommitted)
        #expect(store.current?.tasks.isEmpty == true)
        #expect(store.saveTask(history, in: try live(store)).isCommitted)
        let outcome = store.recordWorkAction(.completed, taskIDs: [history.id], in: try live(store), label: "Done")
        #expect(outcome.isCommitted)
        #expect(!store.deleteTask(try #require(store.current?.tasks.first { $0.id == history.id }), in: try live(store)).isCommitted)
        #expect(store.undo(outcomeIDs: outcome.outcomeIDs, in: try live(store)).isCommitted)
        #expect(store.taskHasOutcomeHistory(history, in: try live(store)))
        #expect(!store.deleteTask(try #require(store.current?.tasks.first { $0.id == history.id }), in: try live(store)).isCommitted)
        #expect(store.recordWorkAction(.excluded, taskIDs: [history.id], in: try live(store), label: "Exclude known work").isCommitted)
        #expect(store.current?.workSummary.excluded == 1)
        #expect(try disk.commands().map(\.sequence) == [1, 2, 3, 4, 5, 6])
    }

    @Test("Protected backend also rejects direct historical task deletion but keeps stop-removal Undo and fresh copies")
    func removalUndoAndCopy() async throws {
        let disk = try disk(); var store = graph(disk); let pickup = task()
        #expect(store.saveTask(pickup, in: try live(store)).isCommitted)
        #expect(store.recordWorkAction(.completed, taskIDs: [pickup.id], in: try live(store), label: "Picked up").isCommitted)
        let before = try live(store)
        #expect(!store.commitPrepared([.deleteTask(before.route.id, pickup.id), .bumpRouteRevision(before.route.id, expectedMinimum: before.route.inputRevision + 1)], label: "Unsafe delete").isCommitted)
        // An unsafe low-level command quarantines that backend instance; reopening the unchanged
        // protected database demonstrates that the refused deletion didn't corrupt its history.
        #expect((store.backend as? DurableRouteBackend)?.issue != nil)
        store = graph(try ActiveRoutePersistence(ownerID: "driver", databaseURL: disk.databaseURL))
        #expect(store.delete(stop: before.stops[0], from: before).isCommitted)
        #expect(store.restore(stop: before.stops[0], packages: before.packages(for: "stop-1"), tasks: before.tasks, in: before.route.id).isCommitted)
        #expect(store.current?.workLedger.status(of: pickup.id).isSuccessful == true)
        let copied = try await store.duplicate(try live(store).route)
        #expect(copied.id != before.route.id && store.current?.tasks.count == 1)
        let copy = try #require(store.current?.tasks.first)
        #expect(copy.id != pickup.id && copy.stopID != pickup.stopID && copy.createdAt != .distantPast)
        #expect(store.current?.outcomes.isEmpty == true && store.current?.workSummary.pending == 2)
    }

    @Test("Stale editors cannot overwrite or resurrect removed definitions; immutable identity and creation time cannot change")
    func staleEditorsAndIdentity() throws {
        let disk = try disk(), store = graph(disk), item = task()
        #expect(store.saveTask(item, in: try live(store)).isCommitted)
        let before = try live(store), saved = try #require(before.tasks.first)
        var edit = saved; edit.instructions = "New access note"
        #expect(store.saveTask(edit, in: before).isCommitted)
        var stale = saved; stale.title = "Stale title"
        #expect(!store.saveTask(stale, in: before).isCommitted)
        #expect(!store.recordWorkAction(.completed, taskIDs: [saved.id], in: before, label: "Old instructions").isCommitted)
        var wrong = try #require(store.current?.tasks.first); wrong.createdAt = wrong.createdAt.addingTimeInterval(1)
        #expect(!store.saveTask(wrong, in: try live(store)).isCommitted)
        wrong = try #require(store.current?.tasks.first); wrong.kind = .checklist
        #expect(!store.saveTask(wrong, in: try live(store)).isCommitted)
        let current = try live(store), currentTask = try #require(current.tasks.first)
        #expect(store.deleteTask(currentTask, in: current).isCommitted)
        #expect(!store.saveTask(stale, in: before).isCommitted)
        #expect(store.current?.tasks.isEmpty == true)
    }

    @Test("Local storage faults cannot acknowledge create, edit, outcome, delete or Undo")
    func localFailureAtomicity() throws {
        let disk = try disk(), store = graph(disk), item = task()
        #expect(store.saveTask(item, in: try live(store)).isCommitted)
        let before = try live(store), count = try disk.commands().count
        var edit = try #require(before.tasks.first); edit.title = "Unsaved correction"
        disk.injectFailure = { if case .beforeCommit = $0 { throw LocalPersistenceFailure.storage("Full disk") } }
        #expect(!store.saveTask(task(.checklist), in: before).isCommitted)
        #expect(!store.saveTask(edit, in: before).isCommitted)
        #expect(!store.recordWorkAction(.completed, taskIDs: [item.id], in: before, label: "Unsaved").isCommitted)
        #expect(!store.deleteTask(try #require(before.tasks.first), in: before).isCommitted)
        let unchanged = try #require(try disk.snapshot(before.route.id))
        #expect(unchanged.route == before.route && unchanged.tasks == before.tasks && unchanged.outcomes == before.outcomes)
        #expect(try disk.commands().count == count)
        disk.injectFailure = nil
        let outcome = store.recordWorkAction(.completed, taskIDs: [item.id], in: before, label: "Saved")
        #expect(outcome.isCommitted)
        disk.injectFailure = { if case .beforeCommit = $0 { throw LocalPersistenceFailure.storage("Full disk") } }
        #expect(!store.undo(outcomeIDs: outcome.outcomeIDs, in: try live(store)).isCommitted)
        #expect(store.current?.workLedger.status(of: item.id).isSuccessful == true)
    }

    @Test("Active and paused permit manual work; closed routes reject definitions, outcomes and Undo without resurrecting execution")
    func sessionAndClosedGates() throws {
        let disk = try disk(), store = graph(disk), original = try live(store)
        #expect(store.startExecution(original).isCommitted)
        let item = task(); #expect(store.saveTask(item, in: try live(store)).isCommitted)
        #expect(store.pauseExecution(try live(store)).isCommitted)
        let session = store.executionSession
        let checklist = task(.checklist); #expect(store.saveTask(checklist, in: try live(store)).isCommitted)
        let outcome = store.recordWorkAction(.completed, taskIDs: [item.id], in: try live(store), label: "Picked up while paused")
        #expect(outcome.isCommitted && store.executionSession == session)
        let before = try live(store); #expect(store.finish(before, confirmOutstandingWork: true).isCommitted)
        #expect(!store.saveTask(task(), in: before).isCommitted)
        #expect(!store.recordWorkAction(.completed, taskIDs: [checklist.id], in: before, label: "Closed").isCommitted)
        #expect(!store.undo(outcomeIDs: outcome.outcomeIDs, in: before).isCommitted)
        #expect(store.executionSession?.state == .finished)
        let closed = try #require(try disk.snapshot(original.route.id)); #expect(store.resume(closed.route).isCommitted)
        #expect(store.executionSession?.state == .finished)
        #expect(store.saveTask(task(), in: try live(store)).isCommitted)
        #expect(store.executionSession?.state == .finished)
    }

    @Test("Production creation gate covers compatibility API/prepared writes/copy, while known obligations stay actionable")
    func rolloutProtection() async throws {
        #expect(AppMode.production.generalizedWorkAvailability == .compatibilityReviewRequired)
        #expect(AppMode.demo.generalizedWorkAvailability == .development)
        #expect(AppMode.emulator(host: "127.0.0.1").generalizedWorkAvailability == .development)
        let disk = try disk(), dev = graph(disk), item = task()
        #expect(dev.saveTask(item, in: try live(dev)).isCommitted)
        let locked = graph(disk, availability: .compatibilityReviewRequired), initial = try live(locked)
        #expect(!locked.canCreateLocationTasks && locked.taskCreationUnavailableReason != nil && initial.tasks.count == 1)
        let fresh = task(.checklist)
        #expect(!locked.saveTask(fresh, in: initial).isCommitted)
        #expect(throws: LocalPersistenceFailure.self) { try locked.put(task: fresh, in: initial) }
        #expect(!locked.commitPrepared([.putTask(initial.route.id, fresh), .bumpRouteRevision(initial.route.id, expectedMinimum: initial.route.inputRevision + 1)], label: "Bypass").isCommitted)
        await #expect(throws: LocalPersistenceFailure.self) { _ = try await locked.duplicate(initial.route) }
        var edited = try #require(initial.tasks.first); edited.instructions = "Known compatible work"
        #expect(locked.saveTask(edited, in: initial).isCommitted)
        #expect(locked.recordWorkAction(.completed, taskIDs: [item.id], in: try live(locked), label: "Known work").isCommitted)
        #expect(locked.current?.tasks.count == 1 && locked.current?.workSummary.completed == 1)
    }

    @Test("Locked rollout preserves exact stop-removal Undo rather than reclassifying it as arbitrary new task creation")
    func gatedStopUndo() throws {
        let disk = try disk(), dev = graph(disk), item = task()
        #expect(dev.saveTask(item, in: try live(dev)).isCommitted)
        let locked = graph(disk, availability: .compatibilityReviewRequired), initial = try live(locked)
        #expect(locked.delete(stop: initial.stops[0], from: initial).isCommitted)
        #expect(locked.restore(stop: initial.stops[0], packages: initial.packages, tasks: initial.tasks, in: initial.route.id).isCommitted)
        #expect(locked.current?.tasks.first?.id == item.id)
    }

    @Test("Blocked commands and wrong owners cannot mutate tasks or acknowledge their outcomes")
    func conflictAndOwnership() throws {
        let disk = try disk(), store = graph(disk), item = task()
        #expect(store.saveTask(item, in: try live(store)).isCommitted)
        var command = try #require(try disk.commands().first); command.state = .blocked; command.lastError = "Conflict"; try disk.update(command)
        #expect(!store.saveTask(task(.checklist), in: try live(store)).isCommitted)
        #expect(!store.recordWorkAction(.completed, taskIDs: [item.id], in: try live(store), label: "Blocked").isCommitted)
        let wrong = graph(disk, owner: { "different-account" })
        #expect(wrong.current == nil && wrong.executionSession == nil)
        #expect(!wrong.saveTask(task(), in: fixture()).isCommitted)
        #expect(try disk.commands().count == 1)
    }

    @Test("Unknown required work remains visible and blocked; failure reasons/note bounds prevent invalid acknowledged UI actions")
    func unsupportedAndValidation() throws {
        var initial = fixture(); var future = task(); future.kind = WorkKind(rawValue: "future")
        initial.tasks = [future]
        let disk = try disk(initial), store = graph(disk)
        #expect(store.current?.workLedger.status(of: future.id) == .unsupported)
        #expect(!store.recordWorkAction(.completed, taskIDs: [future.id], in: initial, label: "Unsafe").isCommitted)
        #expect(!store.finishReview(initial).canFinish)
        var invalid = task(); invalid.title = " "
        #expect(!store.saveTask(invalid, in: initial).isCommitted)
        invalid.title = "Valid"; invalid.orderRank = 1_000_000_001
        #expect(!store.saveTask(invalid, in: initial).isCommitted)
        invalid.orderRank = 0; #expect(store.saveTask(invalid, in: initial).isCommitted)
        #expect(!store.recordWorkAction(.failed, taskIDs: [invalid.id], in: try live(store), label: "Missing reason").isCommitted)
        #expect(!store.recordWorkAction(.failed, taskIDs: [invalid.id], reason: .other, note: String(repeating: "a", count: 501), in: try live(store), label: "Long note").isCommitted)
    }

    @Test("Finite pilot events follow local acknowledgement and distinguish task kinds and mixed-work presentation")
    func telemetryAcknowledgement() throws {
        let disk = try disk(); var events: [ExecutionPilotEvent] = []
        let store = graph(disk, telemetry: { events.append($0) }), item = task()
        disk.injectFailure = { if case .beforeCommit = $0 { throw LocalPersistenceFailure.storage("Private content stays out of events") } }
        #expect(!store.saveTask(item, in: try live(store)).isCommitted)
        #expect(!events.contains { $0.name == .taskCreatedLocally })
        disk.injectFailure = nil; #expect(store.saveTask(item, in: try live(store)).isCommitted)
        store.recordWorkPresentation(in: try live(store), stopID: item.stopID)
        store.recordPendingWorkReminder(in: try live(store), stopID: item.stopID)
        let action = store.recordWorkAction(.completed, taskIDs: [item.id], in: try live(store), label: "Do not log this text")
        #expect(action.isCommitted); #expect(store.undo(outcomeIDs: action.outcomeIDs, in: try live(store)).isCommitted)
        #expect(events.contains { $0.name == .taskCreatedLocally && $0.workType == .pickup })
        #expect(events.contains { $0.name == .mixedWorkPresented && $0.mixed })
        #expect(events.contains { $0.name == .pendingWorkReminderShown })
        #expect(events.contains { $0.name == .taskCompletedLocally && $0.workType == .pickup })
        #expect(events.contains { $0.name == .taskUndoneLocally })
    }
}
