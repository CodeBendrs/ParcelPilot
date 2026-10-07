import Foundation
import ParcelPilotKit
import Testing
@testable import ParcelPilot

@MainActor
@Suite("Explicit protected execution contract", .serialized)
struct ExecutionSessionTests {
    private let epoch = Date(timeIntervalSince1970: 1_790_100_000)

    private func fixture(_ id: String = "route-a", accepted: Bool = true) -> RouteSnapshot {
        var route = Route(id: id, name: id, serviceDate: "2026-10-06", timeZoneID: "America/Vancouver", now: epoch)
        route.start = RoutePlace(label: "Depot", located: LocatedPoint(point: GeoPoint(latitude: 48.41, longitude: -123.31), source: .driverPin))
        if accepted { route.appliedRequestID = "accepted-plan"; route.appliedRevision = route.inputRevision }
        let resolution = StopResolution(provider: nil, placeID: nil,
            located: LocatedPoint(point: GeoPoint(latitude: 48.4, longitude: -123.3), source: .driverPin), match: .driverPin, resolvedAt: epoch)
        let stop = Stop(id: id + "-stop", address: .e1(), addressStatus: .driverConfirmed, resolution: resolution, sequence: 1, now: epoch)
        let package = Package(id: id + "-package", stopID: stop.id, source: .manual, now: epoch)
        return RouteSnapshot(route: route, stops: [stop], packages: [package], outcomes: [])
    }
    private func disk() throws -> ActiveRoutePersistence {
        try ActiveRoutePersistence(ownerID: "driver", databaseURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("execution-\(UUID().uuidString)/operations.sqlite"))
    }
    private func graph(_ disk: ActiveRoutePersistence, owner: @escaping () -> String? = { "driver" }, transport: DurableCommandTransport? = nil,
                       telemetry: @escaping @MainActor (ExecutionPilotEvent) -> Void = { _ in }) -> RouteStore {
        let remote = LocalRouteBackend(fileURL: disk.databaseURL.deletingLastPathComponent().appendingPathComponent("unused.json"))
        let backend = DurableRouteBackend(remote: remote, ownerID: "driver", persistence: disk, transport: transport, authenticatedOwner: owner)
        backend.networkAvailable = false
        return RouteStore(backend: backend, clock: { epoch }, executionTelemetry: telemetry)
    }
    private func reopened(_ store: RouteStore) throws -> RouteStore {
        let old = try #require(store.backend as? DurableRouteBackend); old.suspend()
        let original = try #require(old.persistence)
        return graph(try ActiveRoutePersistence(ownerID: "driver", databaseURL: original.databaseURL))
    }
    private func snapshot(_ store: RouteStore) throws -> RouteSnapshot { try #require(store.current) }

    @Test("Start, Pause, Resume and Finish restore exactly across four offline process restarts")
    func durableLifecycle() throws {
        let disk = try disk(); try disk.pin(fixture(), selected: true)
        var store = graph(disk)
        let revision = try snapshot(store).route.inputRevision
        #expect(store.executionSession == nil)
        #expect(store.startExecution(try snapshot(store)).isCommitted)
        let id = try #require(store.executionSession?.id)
        store = try reopened(store)
        #expect(store.executionSession?.state == .active && store.executionSession?.id == id)
        #expect(store.pauseExecution(try snapshot(store)).isCommitted)
        store = try reopened(store)
        #expect(store.executionSession?.state == .paused && store.executionSession?.id == id)
        #expect(store.resumeExecution(try snapshot(store)).isCommitted)
        store = try reopened(store)
        #expect(store.executionSession?.state == .active && store.executionSession?.id == id)
        let before = try snapshot(store)
        #expect(!store.finish(before).isCommitted)
        #expect(store.finish(before, confirmOutstandingWork: true).isCommitted)
        store = try reopened(store)
        #expect(store.executionSession?.state == .finished && store.executionSession?.id == id)
        #expect(store.activeExecutionRouteID == nil)
        let saved = try #require(try store.operationalPersistence?.snapshot(before.route.id))
        #expect(saved.route.status == .completed && saved.workSummary.pending == 1 && saved.outcomes.isEmpty)
        #expect(saved.route.inputRevision == revision)
        #expect(store.executionSession?.transitionCount == 3)
    }

    @Test("Repeated controls create no extra session or commands and invalid transitions are rejected")
    func idempotentControls() throws {
        let disk = try disk(); try disk.pin(fixture(), selected: true)
        let store = graph(disk), snap = try snapshot(store)
        #expect(!store.pauseExecution(snap).isCommitted && !store.resumeExecution(snap).isCommitted)
        #expect(store.startExecution(snap).isCommitted)
        let id = store.executionSession?.id
        #expect(store.startExecution(snap).isCommitted)
        #expect(try disk.commands().count == 1)
        #expect(store.pauseExecution(snap).isCommitted && store.pauseExecution(snap).isCommitted)
        #expect(!store.startExecution(snap).isCommitted)
        #expect(store.resumeExecution(snap).isCommitted && store.resumeExecution(snap).isCommitted)
        #expect(try disk.commands().count == 3)
        #expect(store.finish(snap, confirmOutstandingWork: true).isCommitted)
        let closed = try #require(try disk.snapshot(snap.route.id))
        #expect(store.finish(closed, confirmOutstandingWork: true).isCommitted)
        #expect(store.finish(snap, confirmOutstandingWork: true).isCommitted)
        #expect(try disk.commands().count == 4)
        #expect(store.executionSession?.id == id && store.executionSession?.state == .finished)
        #expect(!store.pauseExecution(closed).isCommitted && !store.resumeExecution(closed).isCommitted && !store.startExecution(closed).isCommitted)
    }

    @Test("Selection, first/last outcome and repeated snapshot observations do not change execution intent")
    func independentWorkAndSelection() throws {
        let disk = try disk(); try disk.pin(fixture(), selected: true); try disk.pin(fixture("route-b"))
        let store = graph(disk), snap = try snapshot(store)
        #expect(store.record(.delivered, packageIDs: [snap.packages[0].id], stopID: snap.stops[0].id, in: snap, label: "Delivered").count == 1)
        #expect(store.executionSession == nil && store.current?.workSummary.isHandled == true)
        #expect(store.startExecution(try snapshot(store), useCurrentOrder: true).isCommitted)
        let session = try #require(store.executionSession)
        store.currentRouteID = "route-b"
        #expect(store.executionSession == session)
        #expect(!store.startExecution(try snapshot(store)).isCommitted)
        #expect(try disk.selectedRouteID() == "route-b")
        let restored = try reopened(store)
        #expect(restored.currentRouteID == "route-a")
        #expect(restored.executionSession == session)
        #expect(try restored.operationalPersistence?.selectedRouteID() == "route-b")
        restored.currentRouteID = "route-b"; restored.returnToExecutionRoute()
        #expect(restored.currentRouteID == "route-a")
        #expect(restored.executionSession == session)
        restored.currentRouteID = "uncached-route"
        #expect(restored.current == nil && restored.activeExecutionRouteID == "route-a")
        #expect(try restored.operationalPersistence?.selectedRouteID() == "route-a")
        restored.returnToExecutionRoute()
        #expect(restored.currentRouteID == "route-a" && restored.current?.route.id == "route-a")
        #expect(restored.executionSession == session)
    }

    @Test("No unaccepted or stale proposal is silently accepted by Start; explicit current order is allowed")
    func orderAcceptance() throws {
        let disk = try disk(); var snap = fixture(accepted: false); try disk.pin(snap, selected: true)
        let store = graph(disk)
        #expect(!store.startExecution(try snapshot(store)).isCommitted)
        #expect(store.executionSession == nil)
        #expect(try disk.commands().isEmpty)
        snap.route.appliedRequestID = "stale"; snap.route.appliedRevision = 0
        try disk.pin(snap)
        #expect(!store.startExecution(snap).isCommitted)
        #expect(store.startExecution(snap, useCurrentOrder: true).isCommitted)
        #expect(try disk.snapshot(snap.route.id)?.route.appliedRequestID == "stale")
    }

    @Test("Current-order Start rejects a stale screen even when a manual reorder retained the legacy input revision")
    func staleCurrentOrderStart() throws {
        let disk = try disk(); let old = fixture(accepted: false); try disk.pin(old, selected: true)
        let store = graph(disk)
        var changed = old; changed.stops[0].sequence = 2
        try disk.pin(changed)
        #expect(!store.startExecution(old, useCurrentOrder: true).isCommitted)
        #expect(try disk.executionSession() == nil && disk.commands().isEmpty)
        #expect(store.startExecution(changed, useCurrentOrder: true).isCommitted)
    }

    @Test("Local commit failure cannot display Start/Pause/Resume/Finish success", arguments: [0, 1, 2, 3])
    func atomicFailures(_ action: Int) throws {
        let disk = try disk(); try disk.pin(fixture(), selected: true)
        let store = graph(disk)
        if action > 0 { #expect(store.startExecution(try snapshot(store)).isCommitted) }
        if action == 2 { #expect(store.pauseExecution(try snapshot(store)).isCommitted) }
        let previous = try disk.executionSession(), count = try disk.commands().count, snap = try snapshot(store)
        disk.injectFailure = { point in if case .beforeCommit = point { throw LocalPersistenceFailure.storage("Injected full disk") } }
        let result: LocalCommitResult
        switch action {
        case 0: result = store.startExecution(snap)
        case 1: result = store.pauseExecution(snap)
        case 2: result = store.resumeExecution(snap)
        default: result = store.finish(snap, confirmOutstandingWork: true)
        }
        #expect(!result.isCommitted && store.executionSession == previous)
        #expect(try disk.commands().count == count && disk.snapshot(snap.route.id)?.route.isOpen == true)
        disk.injectFailure = nil
        let restored = try reopened(store)
        #expect(restored.executionSession == previous && restored.current?.route.isOpen == true)
    }

    @Test("Paused explicit work and final successful outcome preserve the unfinished paused session")
    func pausedWork() throws {
        let disk = try disk(); try disk.pin(fixture(), selected: true)
        let store = graph(disk), snap = try snapshot(store)
        #expect(store.startExecution(snap).isCommitted && store.pauseExecution(snap).isCommitted)
        let session = store.executionSession
        #expect(store.record(.delivered, packageIDs: [snap.packages[0].id], stopID: snap.stops[0].id, in: snap, label: "Delivered").count == 1)
        #expect(store.executionSession == session && store.current?.workSummary.isHandled == true)
        #expect(store.finish(try snapshot(store)).isCommitted)
        #expect(store.executionSession?.state == .finished && store.currentRouteID == nil)
    }

    @Test("Finish uses required WorkLedger dispositions, preserving failed and deferred work and optional items")
    func workCloseout() throws {
        let disk = try disk(); var snap = fixture()
        snap.tasks = [LocationTask(id: "required-pickup", stopID: snap.stops[0].id, kind: .pickup, now: epoch),
                      LocationTask(id: "optional-check", stopID: snap.stops[0].id, kind: .checklist, required: false, now: epoch)]
        try disk.pin(snap, selected: true)
        let store = graph(disk)
        #expect(store.startExecution(snap).isCommitted)
        store.record(.failed, packageIDs: [snap.packages[0].id], stopID: snap.stops[0].id, reason: .accessIssue, in: snap, label: "Failed")
        store.record(.skipped, taskIDs: ["required-pickup"], in: try snapshot(store), label: "Deferred")
        let review = store.finishReview(try snapshot(store))
        #expect(review.summary.failed == 1 && review.summary.deferred == 1 && review.summary.optional == 1)
        #expect(review.remaining.map(\.taskID) == ["required-pickup"] && review.requiresOutstandingConfirmation)
        #expect(!store.finish(try snapshot(store)).isCommitted)
        #expect(store.finish(try snapshot(store), confirmOutstandingWork: true).isCommitted)
        let saved = try #require(try disk.snapshot(snap.route.id))
        #expect(saved.workSummary.failed == 1 && saved.workSummary.deferred == 1 && saved.outcomes.count == 2)
        #expect(saved.workLedger.status(of: "optional-check") == .pending)
    }

    @Test("Optional-only work does not block Finish; required unsupported work cannot be confirmed away")
    func optionalAndUnsupported() throws {
        let disk = try disk(); var snap = fixture(); snap.packages = []
        snap.tasks = [LocationTask(stopID: snap.stops[0].id, kind: .checklist, required: false, now: epoch)]
        try disk.pin(snap, selected: true)
        let store = graph(disk)
        #expect(store.startExecution(snap).isCommitted)
        #expect(!store.finishReview(snap).requiresOutstandingConfirmation && store.finish(snap).isCommitted)
        var other = fixture("other"); other.tasks = [LocationTask(stopID: other.stops[0].id, kind: .init(rawValue: "future"), now: epoch)]
        try disk.pin(other)
        store.currentRouteID = other.route.id
        #expect(!store.startExecution(other).isCommitted && !store.finish(other, confirmOutstandingWork: true).isCommitted)
        #expect(store.finishReview(other).summary.unsupported == 1)
    }

    @Test("Archive cannot orphan an unfinished session; reopen does not resurrect a finished session")
    func archiveReopen() throws {
        let disk = try disk(); try disk.pin(fixture(), selected: true)
        let store = graph(disk), snap = try snapshot(store)
        #expect(store.startExecution(snap).isCommitted && !store.archive(snap.route).isCommitted)
        #expect(store.pauseExecution(snap).isCommitted && !store.archive(snap.route).isCommitted)
        #expect(store.finish(snap, confirmOutstandingWork: true).isCommitted)
        let sessionID = store.executionSession?.id
        let closed = try #require(try disk.snapshot(snap.route.id))
        #expect(store.resume(closed.route).isCommitted)
        #expect(store.executionSession?.state == .finished && store.activeExecutionRouteID == nil)
        #expect(store.startExecution(try snapshot(store)).isCommitted)
        #expect(store.executionSession?.id != sessionID && store.executionSession?.transitionCount == 0)
    }

    @Test("Proposal acceptance during execution and work edits do not replace or alter the session")
    func proposalDuringExecution() throws {
        let disk = try disk(); let snap = fixture(); try disk.pin(snap, selected: true)
        let store = graph(disk)
        #expect(store.startExecution(snap).isCommitted)
        let session = store.executionSession
        let proposal = try DemoOptimizer().optimize(snapshot: snap, options: OptimizationOptions(), requestID: "new-proposal", now: epoch)
        #expect(store.apply(proposal, to: snap).isCommitted)
        #expect(store.executionSession == session && store.current?.route.appliedRequestID == "new-proposal")
        var route = try snapshot(store).route; route.name = "Driver edit"
        #expect(store.rename(route, to: "Driver edit").isCommitted && store.executionSession == session)
    }

    @Test("Wrong account, logout and same-account reauthentication preserve owner-bound intent")
    func accountRestoration() throws {
        let disk = try disk(); try disk.pin(fixture(), selected: true)
        let identity = ExecutionIdentity()
        let store = graph(disk, owner: { identity.owner })
        #expect(store.startExecution(try snapshot(store)).isCommitted)
        let saved = try disk.executionSession()
        identity.owner = "other"
        #expect(store.executionSession == nil && !store.pauseExecution(fixture()).isCommitted)
        #expect(try disk.executionSession() == saved)
        (store.backend as? DurableRouteBackend)?.suspend()
        let other = try ActiveRoutePersistence(ownerID: "other", databaseURL: disk.databaseURL.deletingLastPathComponent().appendingPathComponent("other.sqlite"))
        #expect(try other.executionSession() == nil)
        #expect(throws: LocalPersistenceFailure.ownership) { try ActiveRoutePersistence(ownerID: "other", databaseURL: disk.databaseURL) }
        identity.owner = "driver"
        let restored = graph(try ActiveRoutePersistence(ownerID: "driver", databaseURL: disk.databaseURL), owner: { identity.owner })
        #expect(restored.executionSession == saved && restored.currentRouteID == saved?.routeID)
    }

    @Test("Retryable Firebase state never blocks locally acknowledged execution transitions")
    func retryableOffline() async throws {
        let disk = try disk(); let snap = fixture(); try disk.pin(snap, selected: true)
        let transport = ExecutionOfflineTransport()
        let store = graph(disk, transport: transport)
        #expect(store.startExecution(snap).isCommitted)
        let backend = try #require(store.backend as? DurableRouteBackend)
        backend.networkAvailable = true; await backend.synchronize(); backend.networkAvailable = false
        #expect(try disk.commands().first?.state == .retryable)
        #expect(store.pauseExecution(snap).isCommitted && store.resumeExecution(snap).isCommitted)
        #expect(store.finish(snap, confirmOutstandingWork: true).isCommitted)
        #expect(try disk.commands().count == 4 && store.executionSession?.state == .finished)
        #expect(try reopened(store).executionSession?.state == .finished)
    }

    @Test("Telemetry follows acknowledgement and carries only state/counters, never route content")
    func telemetryBoundary() throws {
        let disk = try disk(); try disk.pin(fixture(), selected: true)
        var events: [ExecutionPilotEvent] = []
        let store = graph(disk, telemetry: { events.append($0) })
        disk.injectFailure = { _ in throw LocalPersistenceFailure.storage("Fault with private address") }
        #expect(!store.startExecution(try snapshot(store)).isCommitted)
        #expect(events.map(\.name) == [.startRequested])
        disk.injectFailure = nil
        #expect(store.startExecution(try snapshot(store)).isCommitted)
        #expect(events.map(\.name) == [.startRequested, .startRequested, .startedLocally])
        #expect(!store.finish(try snapshot(store)).isCommitted)
        #expect(events.suffix(2).map(\.name) == [.finishRequested, .finishBlockedByWork])
        #expect(events.last?.pending == 1)
    }
}

@MainActor private final class ExecutionIdentity { var owner: String? = "driver" }
@MainActor private final class ExecutionOfflineTransport: DurableCommandTransport {
    func replay(_ command: DurableCommand) async -> RemoteReplayResult { .retryable("Offline") }
    func fetchVerifiedRoute(_ id: RouteID) async throws -> RouteSnapshot? { throw URLError(.notConnectedToInternet) }
}
