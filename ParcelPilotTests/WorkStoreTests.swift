import Foundation
import ParcelPilotKit
import Testing
@testable import ParcelPilot

@MainActor
@Suite("Unified work store", .serialized)
struct WorkStoreTests {
    private func addStop(_ env: TestEnvironment, number: String = "123", packages: Int = 1) -> RouteStore.AddResult {
        var address = PostalAddress.e1()
        address.civicNumber = number
        let stopResolution = StopResolution(provider: .demo, placeID: nil,
            located: LocatedPoint(point: GeoPoint(latitude: 48.43, longitude: -123.36), source: .demoSynthetic),
            match: .synthetic, resolvedAt: Date())
        return env.store.addDelivery(to: env.snapshot, address: address, status: .demoSynthetic,
            resolution: stopResolution, reviewReasons: [], packages: (0..<packages).map { _ in PackageDraft() }, source: .manual)
    }

    private func checkRevision(_ env: TestEnvironment, mutation: () throws -> Void) throws {
        let before = env.snapshot
        let now = Date()
        let proposal = try DemoOptimizer().optimize(snapshot: before, options: OptimizationOptions(departNow: true), requestID: StableID.make(), now: now)
        try mutation()
        #expect(env.snapshot.route.inputRevision == before.route.inputRevision + 1)
        if case .stale = ProposalValidator.validate(proposal, against: env.snapshot, now: now, demoMode: true) {}
        else { Issue.record("Every remaining-work mutation must stale the prior proposal") }
        env.store.apply(proposal, to: env.snapshot)
        #expect(env.snapshot.route.appliedRequestID != proposal.requestID)
    }

    @Test("Delivery, failure, defer, Retry, pickup/checklist outcomes and Undo each invalidate proposals")
    func allOutcomeRevisions() throws {
        let env = TestEnvironment()
        env.makeRoute()
        let added = addStop(env, packages: 2)
        _ = addStop(env, number: "456") // A pending location keeps the optimizer available.
        let pickup = LocationTask(stopID: added.stopID, kind: .pickup, title: "Return parcel")
        let checklist = LocationTask(stopID: added.stopID, kind: .checklist, title: "Close gate")
        try env.store.put(task: pickup, in: env.snapshot)
        try env.store.put(task: checklist, in: env.snapshot)

        var delivered: [OutcomeID] = []
        try checkRevision(env) { delivered = env.store.record(.delivered, packageIDs: [added.packageIDs[0]], stopID: added.stopID, in: env.snapshot, label: "Delivered") }
        try checkRevision(env) { env.store.undo(outcomeIDs: delivered, in: env.snapshot) }
        try checkRevision(env) { _ = env.store.record(.failed, packageIDs: [added.packageIDs[0]], stopID: added.stopID, reason: .noOneHome, in: env.snapshot, label: "Failed") }
        try checkRevision(env) { _ = env.store.record(.requeued, packageIDs: [added.packageIDs[0]], stopID: added.stopID, in: env.snapshot, label: "Retry") }
        try checkRevision(env) { _ = env.store.record(.skipped, packageIDs: [added.packageIDs[0]], stopID: added.stopID, in: env.snapshot, label: "Deferred") }
        try checkRevision(env) { _ = env.store.record(.requeued, packageIDs: [added.packageIDs[0]], stopID: added.stopID, in: env.snapshot, label: "Retry") }
        var pickupOutcome: [OutcomeID] = []
        try checkRevision(env) { pickupOutcome = env.store.record(.completed, taskIDs: [pickup.id], in: env.snapshot, label: "Pickup complete") }
        try checkRevision(env) { env.store.undo(outcomeIDs: pickupOutcome, in: env.snapshot) }
        try checkRevision(env) { _ = env.store.record(.completed, taskIDs: [checklist.id], in: env.snapshot, label: "Checklist complete") }
        #expect(env.snapshot.summary().delivered == 0)
        #expect(env.snapshot.workSummary.completed == 1)
    }

    @Test("A bulk outcome bumps once; invalid targets and repeated completion/Undo/Retry do not write")
    func guardedMutations() throws {
        let env = TestEnvironment()
        env.makeRoute()
        let added = addStop(env, packages: 2)
        let beforeDelivery = env.snapshot
        let revision = env.snapshot.route.inputRevision
        let ids = env.store.record(.delivered, packageIDs: added.packageIDs + added.packageIDs, stopID: added.stopID, in: env.snapshot, label: "Delivered")
        #expect(ids.count == 2)
        #expect(env.snapshot.route.inputRevision == revision + 1)
        #expect(env.store.record(.delivered, packageIDs: added.packageIDs, stopID: added.stopID, in: env.snapshot, label: "Repeat").isEmpty)
        #expect(env.store.record(.delivered, packageIDs: added.packageIDs, stopID: added.stopID, in: beforeDelivery, label: "Stale view repeat").isEmpty)
        #expect(env.store.record(.failed, packageIDs: added.packageIDs, stopID: "wrong-stop", in: env.snapshot, label: "Wrong").isEmpty)
        #expect(env.store.record(.requeued, packageIDs: added.packageIDs, stopID: added.stopID, in: env.snapshot, label: "Invalid retry").isEmpty)
        #expect(env.snapshot.route.inputRevision == revision + 1)
        // This is the pre-outcome snapshot captured by the existing toast Undo closure.
        env.store.undo(outcomeIDs: ids + ids, in: beforeDelivery)
        #expect(env.snapshot.route.inputRevision == revision + 2)
        env.store.undo(outcomeIDs: ids, in: env.snapshot)
        #expect(env.snapshot.route.inputRevision == revision + 2)
        #expect(env.snapshot.workSummary.pending == 2)
    }

    @Test("Mixed work keeps a fixed next stop through partial delivery, then clears it only when handled")
    func partialFixedNext() throws {
        let env = TestEnvironment()
        env.makeRoute()
        let added = addStop(env)
        let pickup = LocationTask(stopID: added.stopID, kind: .pickup)
        try env.store.put(task: pickup, in: env.snapshot)
        env.store.setNextStop(added.stopID, in: env.snapshot.route)
        env.store.record(.delivered, packageIDs: added.packageIDs, stopID: added.stopID, in: env.snapshot, label: "Delivered")
        #expect(env.snapshot.route.nextStopOverrideID == added.stopID)
        #expect(env.snapshot.nextStop()?.id == added.stopID)
        #expect(env.snapshot.workLedger.stopStatus(env.snapshot.stops[0]) == .partial)
        let ids = env.store.record(.completed, taskIDs: [pickup.id], in: env.snapshot, label: "Pickup complete")
        #expect(env.snapshot.route.nextStopOverrideID == nil)
        #expect(env.snapshot.nextStop() == nil)
        env.store.undo(outcomeIDs: ids, in: env.snapshot)
        #expect(env.snapshot.nextStop()?.id == added.stopID)
    }

    @Test("Task-only and mixed work persist across relaunch; optional work never creates a route visit")
    func tasksSurviveRelaunch() throws {
        let env = TestEnvironment(online: false)
        env.makeRoute()
        let added = addStop(env, packages: 0)
        let pickup = LocationTask(stopID: added.stopID, kind: .pickup, title: "Collect return", instructions: "Ask at reception")
        let optional = LocationTask(stopID: added.stopID, kind: .checklist, required: false, title: "Optional note")
        try env.store.put(task: pickup, in: env.snapshot)
        try env.store.put(task: optional, in: env.snapshot)
        #expect(env.snapshot.nextStop()?.id == added.stopID)
        env.store.record(.skipped, taskIDs: [pickup.id], in: env.snapshot, label: "Deferred pickup")
        let routeID = env.snapshot.route.id
        let relaunched = env.relaunch(online: false)
        relaunched.store.currentRouteID = routeID
        #expect(relaunched.snapshot.tasks.count == 2)
        #expect(relaunched.snapshot.tasks.first { $0.id == pickup.id }?.instructions == "Ask at reception")
        #expect(relaunched.snapshot.workSummary.deferred == 1)
        #expect(Eligibility.evaluate(relaunched.snapshot, now: Date(), demoMode: true).eligible.isEmpty)
        relaunched.store.record(.requeued, taskIDs: [pickup.id], in: relaunched.snapshot, label: "Retry")
        relaunched.store.record(.completed, taskIDs: [pickup.id], in: relaunched.snapshot, label: "Pickup complete")
        #expect(relaunched.snapshot.workSummary.outstanding == 0)
        #expect(relaunched.snapshot.workLedger.status(of: optional.id) == .pending)
        #expect(relaunched.snapshot.nextStop() == nil)
        #expect(relaunched.snapshot.outcomes.allSatisfy { $0.schemaVersion == 2 && $0.packageID == nil })
    }

    @Test("Stop-removal Undo preserves tasks and their outcomes, and duplicate starts all work fresh")
    func removalAndDuplicate() async throws {
        let env = TestEnvironment()
        env.makeRoute()
        let added = addStop(env)
        let pickup = LocationTask(stopID: added.stopID, kind: .pickup, packageID: added.packageIDs[0])
        try env.store.put(task: pickup, in: env.snapshot)
        env.store.record(.completed, taskIDs: [pickup.id], in: env.snapshot, label: "Pickup complete")
        let before = env.snapshot
        env.store.delete(stop: before.stops[0], from: before)
        #expect(env.snapshot.tasks.isEmpty)
        env.store.restore(stop: before.stops[0], packages: before.packages, tasks: before.tasks, in: before.route.id)
        #expect(env.snapshot.workLedger.status(of: pickup.id).isSuccessful)
        _ = try await env.store.duplicate(env.snapshot.route)
        #expect(env.snapshot.tasks.count == 1)
        let copyTask = try #require(env.snapshot.tasks.first)
        #expect(copyTask.id != pickup.id && copyTask.stopID != pickup.stopID)
        #expect(copyTask.packageID == env.snapshot.packages[0].id)
        #expect(copyTask.packageID != pickup.packageID)
        #expect(env.snapshot.outcomes.isEmpty)
        #expect(env.snapshot.workSummary.pending == 2)
    }

    @Test("Task edits bump revisions while stable target/kind changes are rejected")
    func definitionEdits() throws {
        let env = TestEnvironment()
        env.makeRoute()
        let added = addStop(env)
        let task = LocationTask(stopID: added.stopID, kind: .checklist)
        try checkRevision(env) { try env.store.put(task: task, in: env.snapshot) }
        var edited = task
        edited.required = false
        edited.instructions = "Only if requested"
        try checkRevision(env) { try env.store.put(task: edited, in: env.snapshot) }
        var invalid = edited
        invalid.kind = .pickup
        #expect(throws: ServiceError.self) { try env.store.put(task: invalid, in: env.snapshot) }
        #expect(env.snapshot.tasks[0].kind == .checklist)
        #expect(env.snapshot.workSummary.required == 1)
    }

    @Test("Large standalone outcome groups retain every event while versioning each bounded batch")
    func boundedTaskBatch() throws {
        let env = TestEnvironment()
        env.makeRoute()
        let added = addStop(env, packages: 0)
        let tasks = (0..<8).map { LocationTask(stopID: added.stopID, kind: .checklist, title: "Item \($0)") }
        for task in tasks { try env.store.put(task: task, in: env.snapshot) }
        env.store.setNextStop(added.stopID, in: env.snapshot.route)
        let revision = env.snapshot.route.inputRevision
        let ids = env.store.record(.completed, taskIDs: tasks.map(\.id), in: env.snapshot, label: "Checklist complete")
        #expect(Set(ids).count == 8 && env.snapshot.outcomes.count == 8)
        #expect(env.snapshot.route.inputRevision == revision + 2)
        #expect(env.snapshot.workSummary.completed == 8 && env.snapshot.workSummary.outstanding == 0)
        #expect(env.snapshot.route.nextStopOverrideID == nil)
    }

    @Test("Unknown required work blocks proposal generation and close-out without hiding it")
    func unknownWork() throws {
        let env = TestEnvironment()
        env.makeRoute()
        let added = addStop(env)
        let unknown = LocationTask(stopID: added.stopID, kind: WorkKind(rawValue: "future-kind"))
        env.backend.commit(ChangeSet([.putTask(env.snapshot.route.id, unknown)], label: "Future data fixture"))
        #expect(env.snapshot.hasUnsupportedRequiredWork)
        #expect(env.snapshot.workSummary.unsupported == 1)
        #expect(throws: DemoOptimizer.Failure.unsupportedWork) {
            try DemoOptimizer().optimize(snapshot: env.snapshot, options: OptimizationOptions(), requestID: "unknown", now: Date())
        }
        env.store.finish(env.snapshot)
        #expect(env.snapshot.route.status == .planning)
    }

    @Test("Generalized failures are handled without being shown as successful badges")
    func failureBadge() throws {
        let env = TestEnvironment()
        env.makeRoute()
        let added = addStop(env, packages: 0)
        let pickup = LocationTask(stopID: added.stopID, kind: .pickup)
        try env.store.put(task: pickup, in: env.snapshot)
        env.store.record(.failed, taskIDs: [pickup.id], in: env.snapshot, label: "Pickup failed")
        #expect(env.snapshot.workSummary.failed == 1 && env.snapshot.workSummary.completed == 0)
        #expect(env.snapshot.workLedger.stopStatus(env.snapshot.stops[0]) == .completed)
        #expect(StopBadgeState.make(stop: env.snapshot.stops[0], snapshot: env.snapshot) == .failed)
    }
}
