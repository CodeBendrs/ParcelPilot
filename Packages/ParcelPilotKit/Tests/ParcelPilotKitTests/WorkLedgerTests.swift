import Foundation
import Testing
@testable import ParcelPilotKit

@Suite("Unified location work")
struct WorkLedgerTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    var stop: Stop { makeStop(1, lat: 48.43, lng: -123.36) }

    func package(_ id: String = "parcel", stopID: String = "stop-1") -> Package {
        Package(id: id, stopID: stopID, trackingID: "TRACK-\(id)", recipientName: "Recipient", notes: "Keep dry", source: .manual, now: t0)
    }

    func task(_ id: String = "pickup", kind: WorkKind = .pickup, required: Bool = true, stopID: String = "stop-1") -> LocationTask {
        LocationTask(id: id, stopID: stopID, kind: kind, required: required, title: "Return tote", instructions: "Ask at reception", now: t0)
    }

    func snapshot(packages: [Package] = [], tasks: [LocationTask] = [], outcomes: [TaskOutcome] = [], stops: [Stop]? = nil) -> RouteSnapshot {
        RouteSnapshot(route: makeRoute(), stops: stops ?? [stop], packages: packages, outcomes: outcomes, tasks: tasks)
    }

    func delivery(_ id: String, packageID: String = "parcel", kind: OutcomeKind, seconds: Double = 0) -> TaskOutcome {
        TaskOutcome(id: id, packageID: packageID, stopID: "stop-1", kind: kind, reason: kind == .failed ? .accessIssue : nil, recordedAt: t0.addingTimeInterval(seconds))
    }

    func outcome(_ id: String, taskID: String = "pickup", kind: OutcomeKind, seconds: Double = 0) -> TaskOutcome {
        TaskOutcome(id: id, taskID: taskID, stopID: "stop-1", kind: kind, reason: kind == .failed ? .businessClosed : nil, recordedAt: t0.addingTimeInterval(seconds))
    }

    @Test("Frozen schema-1 route, package, summary and outcome decode without new fields")
    func frozenLegacyWireData() throws {
        // These literals predate taskID, LocationTask and RouteSummary.work. Using the current
        // encoder to create them would hide a backwards-compatibility regression.
        let routeJSON = #"{"id":"legacy-route","schemaVersion":1,"name":"Legacy","status":"active","createdAt":1790000000,"updatedAt":1790000000,"serviceDate":"2026-10-05","timeZoneID":"America/Vancouver","departureMinute":480,"returnToStart":false,"defaultServiceSeconds":120,"objective":"balanced","considerTraffic":true,"inputRevision":7,"summary":{"delivered":1,"failed":0,"skipped":0,"excluded":0,"pending":0,"stopCount":1,"packageCount":1}}"#
        let packageJSON = #"{"id":"legacy-parcel","schemaVersion":1,"stopID":"stop-1","createdAt":1790000000,"updatedAt":1790000000,"trackingID":"TRACK-123","trackingKey":"TRACK123","recipientName":"A Driver","storageLocation":"Shelf B","notes":"Signature","source":"scan"}"#
        let eventJSON = #"{"id":"legacy-outcome","schemaVersion":1,"packageID":"legacy-parcel","stopID":"stop-1","kind":"delivered","recordedAt":1790000000,"photoIDs":["photo-1"]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let route = try decoder.decode(Route.self, from: Data(routeJSON.utf8))
        let parcel = try decoder.decode(Package.self, from: Data(packageJSON.utf8))
        let event = try decoder.decode(DeliveryOutcome.self, from: Data(eventJSON.utf8))
        let snap = RouteSnapshot(route: route, stops: [stop], packages: [parcel], outcomes: [event])
        #expect(route.inputRevision == 7 && route.summary?.work == nil)
        #expect(parcel.trackingID == "TRACK-123" && parcel.storageLocation == "Shelf B")
        #expect(snap.tasks.isEmpty && snap.workSummary.required == 1)
        #expect(snap.workLedger.status(of: LocationTask.deliveryID(for: parcel.id)) == .completed(at: t0))
        #expect(snap.ledger.status(of: parcel.id) == .delivered(at: t0))
        #expect(snap.nextStop() == nil && snap.summary().delivered == 1)
        #expect(event.taskID == nil && event.photoIDs == ["photo-1"])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let encoded = try #require(JSONSerialization.jsonObject(with: encoder.encode(event)) as? [String: Any])
        #expect(encoded["taskID"] == nil)
        #expect(encoded["schemaVersion"] as? Int == 1 && encoded["packageID"] as? String == "legacy-parcel")
    }

    @Test("Multiple packages stay independently actionable through partial delivery")
    func multiplePackagesAndPartialDelivery() {
        let parcels = [package("a"), package("b"), package("c")]
        var snap = snapshot(packages: parcels)
        #expect(snap.workLedger.actionableTasks(at: stop.id).count == 3)
        #expect(snap.workLedger.stopStatus(stop) == .pending)
        snap.outcomes = [delivery("done-a", packageID: "a", kind: .delivered)]
        #expect(snap.workLedger.stopStatus(stop) == .partial)
        #expect(Set(snap.workLedger.actionableTasks(at: stop.id).map(\.id)) == Set(["delivery_b", "delivery_c"]))
        #expect(snap.workSummary.completed == 1 && snap.workSummary.outstanding == 2)
        #expect(snap.nextStop()?.id == stop.id)
        #expect(Eligibility.evaluate(snap, now: t0, demoMode: true).eligible.map(\.id) == [stop.id])
    }

    @Test("Delivery success is projected once, preserving package details and old counters")
    func successfulDeliveryUsesCanonicalLedger() {
        let parcel = package()
        let snap = snapshot(packages: [parcel], outcomes: [delivery("done", kind: .delivered)])
        #expect(snap.workLedger.allTasks.count == 1 && snap.tasks.isEmpty)
        #expect(snap.workLedger.allTasks[0].packageID == parcel.id)
        #expect(snap.workLedger.allTasks[0].title.isEmpty && snap.workLedger.allTasks[0].instructions.isEmpty)
        #expect(snap.packages[0].notes == "Keep dry" && snap.packages[0].trackingID == "TRACK-parcel")
        #expect(snap.workSummary.completed == 1 && snap.summary().delivered == 1)
        #expect(snap.ledger.work.taskStates == snap.workLedger.taskStates)
        #expect(snap.workLedger.presentableTasks(at: stop.id).isEmpty)
        #expect(snap.nextStop() == nil)
    }

    @Test("Failed delivery is handled but never successful")
    func failedDeliveryDisposition() {
        let snap = snapshot(packages: [package()], outcomes: [delivery("failed", kind: .failed)])
        let state = snap.workLedger.status(of: "delivery_parcel")
        #expect(state == .failed(.accessIssue, at: t0))
        #expect(state.isHandled && !state.isSuccessful)
        #expect(snap.workLedger.stopStatus(stop) == .completed)
        #expect(snap.workSummary.failed == 1 && snap.workSummary.completed == 0 && snap.workSummary.isHandled)
        #expect(snap.summary().delivered == 0 && snap.summary().failed == 1)
        #expect(snap.workLedger.presentableTasks(at: stop.id).map(\.id) == ["delivery_parcel"])
        #expect(Eligibility.evaluate(snap, now: t0, demoMode: true).completedStopIDs == [stop.id])
    }

    @Test("Retry reopens failed/deferred delivery; Undo Retry restores its prior disposition", arguments: [OutcomeKind.failed, .skipped])
    func deliveryRetryAndUndo(kind: OutcomeKind) {
        let initial = delivery("prior", kind: kind)
        var retry = delivery("retry", kind: .requeued, seconds: 10)
        var snap = snapshot(packages: [package()], outcomes: [initial, retry])
        #expect(snap.workLedger.status(of: "delivery_parcel") == .pending)
        #expect(snap.workSummary.pending == 1 && snap.workSummary.outstanding == 1)
        #expect(Eligibility.evaluate(snap, now: t0, demoMode: true).eligible.map(\.id) == [stop.id])
        retry.voidedAt = t0.addingTimeInterval(20)
        snap.outcomes = [retry, initial]
        #expect(snap.workLedger.status(of: "delivery_parcel") == (kind == .failed ? .failed(.accessIssue, at: t0) : .deferred(at: t0)))
        #expect(snap.workLedger.stopStatus(stop) == (kind == .failed ? .completed : .skipped))
    }

    @Test("Undo latest outcome reveals previous work; Undo sole outcome returns pending")
    func undoOutcome() {
        let failed = delivery("failed", kind: .failed)
        var completed = delivery("done", kind: .delivered, seconds: 30)
        completed.voidedAt = t0.addingTimeInterval(40)
        let snap = snapshot(packages: [package()], outcomes: [completed, failed])
        #expect(snap.workLedger.status(of: "delivery_parcel") == .failed(.accessIssue, at: t0))
        let undone = snapshot(packages: [package()], outcomes: [completed])
        #expect(undone.workLedger.status(of: "delivery_parcel") == .pending)
        #expect(undone.nextStop()?.id == stop.id)
    }

    @Test("A required pickup creates a visit without a synthetic package")
    func pickupOnly() {
        let snap = snapshot(tasks: [task()])
        #expect(snap.packages.isEmpty && snap.ledger.packageStatus.isEmpty)
        #expect(snap.workLedger.stopStatus(stop) == .pending && snap.workSummary.outstanding == 1)
        #expect(snap.nextStop()?.id == stop.id)
        #expect(Eligibility.evaluate(snap, now: t0, demoMode: true).eligible.map(\.id) == [stop.id])
        #expect(snap.workLedger.presentableTasks(at: stop.id).map(\.id) == ["pickup"])
    }

    @Test("Pickup success finishes required work without increasing delivery counters")
    func completedPickup() {
        let snap = snapshot(tasks: [task()], outcomes: [outcome("done", kind: .completed)])
        #expect(snap.workSummary.completed == 1 && snap.workSummary.required == 1)
        #expect(snap.workLedger.stopStatus(stop) == .completed && snap.nextStop() == nil)
        #expect(snap.summary().delivered == 0 && snap.summary().packageCount == 0)
        #expect(snap.summary().work?.completed == 1)
        #expect(Eligibility.evaluate(snap, now: t0, demoMode: true).completedStopIDs == [stop.id])
    }

    @Test("Pickup failure/defer remain presentable; Retry restores actionability", arguments: [OutcomeKind.failed, .skipped])
    func pickupFailureDeferralAndRetry(kind: OutcomeKind) {
        let initial = outcome("prior", kind: kind)
        var snap = snapshot(tasks: [task()], outcomes: [initial])
        #expect(snap.workLedger.actionableTasks(at: stop.id).isEmpty)
        #expect(snap.workLedger.presentableTasks(at: stop.id).map(\.id) == ["pickup"])
        #expect(snap.workSummary.completed == 0)
        if kind == .skipped {
            #expect(snap.workSummary.outstanding == 1 && snap.workLedger.stopStatus(stop) == .skipped)
            #expect(Eligibility.evaluate(snap, now: t0, demoMode: true).excluded.first?.reason == .onlySkippedPackages)
        } else {
            #expect(snap.workSummary.outstanding == 0 && snap.workSummary.failed == 1)
        }
        snap.outcomes.append(outcome("retry", kind: .requeued, seconds: 20))
        #expect(snap.workLedger.actionableTasks(at: stop.id).map(\.id) == ["pickup"])
        #expect(Eligibility.evaluate(snap, now: t0, demoMode: true).eligible.map(\.id) == [stop.id])
    }

    @Test("Required checklist must be handled; deferring does not finish the route")
    func requiredChecklist() {
        let check = task("check", kind: .checklist)
        var snap = snapshot(tasks: [check])
        #expect(snap.nextStop()?.id == stop.id && snap.workSummary.outstanding == 1)
        snap.outcomes = [outcome("defer", taskID: check.id, kind: .skipped)]
        #expect(snap.workSummary.deferred == 1 && !snap.workSummary.isHandled)
        #expect(snap.workLedger.hasOutstandingRequiredWork(at: stop.id))
        #expect(Eligibility.evaluate(snap, now: t0, demoMode: true).eligible.isEmpty)
        snap.outcomes.append(outcome("done", taskID: check.id, kind: .completed, seconds: 10))
        #expect(snap.workSummary.isHandled && snap.workSummary.completed == 1)
        #expect(snap.nextStop() == nil)
    }

    @Test("Optional-only work is visible on a visit but creates no route visit or completion blocker")
    func optionalChecklistOnly() {
        let snap = snapshot(tasks: [task("optional", kind: .checklist, required: false)])
        #expect(snap.workLedger.actionableTasks(at: stop.id).map(\.id) == ["optional"])
        #expect(snap.workLedger.presentableTasks(at: stop.id).map(\.id) == ["optional"])
        #expect(snap.workLedger.stopStatus(stop) == .empty && snap.nextStop() == nil)
        #expect(snap.workSummary.required == 0 && snap.workSummary.optional == 1 && snap.workSummary.isHandled)
        #expect(Eligibility.evaluate(snap, now: t0, demoMode: true).excluded.first?.reason == .noPendingPackages)
    }

    @Test("Delivery plus pickup remains partial until all required work is handled")
    func deliveryAndPickupAtSameStop() {
        var snap = snapshot(packages: [package()], tasks: [task()], outcomes: [delivery("delivered", kind: .delivered)])
        #expect(snap.ledger.status(of: "parcel") == .delivered(at: t0))
        #expect(snap.ledger.stopStatus(stop, packages: snap.packages) == .partial)
        #expect(snap.workSummary.required == 2 && snap.workSummary.completed == 1 && snap.workSummary.outstanding == 1)
        #expect(snap.workLedger.presentableTasks(at: stop.id).map(\.id) == ["pickup"])
        #expect(Eligibility.evaluate(snap, now: t0, demoMode: true).eligible.map(\.id) == [stop.id])
        snap.outcomes.append(outcome("picked-up", kind: .completed, seconds: 15))
        #expect(snap.workLedger.stopStatus(stop) == .completed && snap.nextStop() == nil)
        #expect(snap.workSummary.completed == 2 && snap.summary().delivered == 1)
    }

    @Test("Outstanding optional work does not reopen handled required work", arguments: [OutcomeKind.skipped, .failed])
    func optionalWorkDoesNotBlock(kind: OutcomeKind) {
        let optional = task("optional", kind: .checklist, required: false)
        let snap = snapshot(packages: [package()], tasks: [optional], outcomes: [delivery("delivered", kind: .delivered), outcome("optional-event", taskID: optional.id, kind: kind)])
        #expect(snap.workSummary.required == 1 && snap.workSummary.optional == 1)
        #expect(snap.workSummary.completed == 1 && snap.workSummary.failed == 0 && snap.workSummary.deferred == 0)
        #expect(!snap.workLedger.hasOutstandingRequiredWork(at: stop.id))
        #expect(snap.workLedger.presentableTasks(at: stop.id).map(\.id) == [optional.id])
        #expect(snap.nextStop() == nil && snap.workLedger.stopStatus(stop) == .completed)
    }

    @Test("Units at one building retain destination and work identity separation")
    func apartmentUnitSeparation() {
        var address = stop.address
        address.unit = "101"
        let unit101 = Stop(id: "unit-101", address: address, addressStatus: .driverConfirmed, resolution: stop.resolution, sequence: 1, now: t0)
        address.unit = "202"
        let unit202 = Stop(id: "unit-202", address: address, addressStatus: .driverConfirmed, resolution: stop.resolution, sequence: 2, now: t0)
        let delivered = TaskOutcome(id: "unit101-done", packageID: "a", stopID: unit101.id, kind: .delivered, recordedAt: t0)
        let snap = snapshot(packages: [package("a", stopID: unit101.id), package("b", stopID: unit202.id)], tasks: [task("unit202-check", kind: .checklist, stopID: unit202.id)], outcomes: [delivered], stops: [unit101, unit202])
        #expect(unit101.destinationKey != unit202.destinationKey)
        #expect(snap.workLedger.stopStatus(unit101) == .completed && snap.workLedger.stopStatus(unit202) == .pending)
        #expect(snap.workLedger.tasks(at: unit101.id).map(\.id) == ["delivery_a"])
        #expect(Set(snap.workLedger.tasks(at: unit202.id).map(\.id)) == Set(["delivery_b", "unit202-check"]))
        #expect(snap.nextStop()?.id == unit202.id)
        #expect(Eligibility.evaluate(snap, now: t0, demoMode: true).eligible.map(\.id) == [unit202.id])
    }

    @Test("Deferred pickup survives a completed delivery and is omitted until Retry")
    func partiallyHandledDeferredLocation() {
        var snap = snapshot(packages: [package()], tasks: [task()], outcomes: [delivery("done", kind: .delivered), outcome("defer", kind: .skipped, seconds: 10)])
        #expect(snap.workLedger.stopStatus(stop) == .skipped)
        #expect(snap.workSummary.completed == 1 && snap.workSummary.deferred == 1 && !snap.workSummary.isHandled)
        #expect(snap.nextStop()?.id == stop.id)
        #expect(Eligibility.evaluate(snap, now: t0, demoMode: true).eligible.isEmpty)
        snap.outcomes.append(outcome("retry", kind: .requeued, seconds: 20))
        #expect(snap.workLedger.stopStatus(stop) == .partial)
        #expect(Eligibility.evaluate(snap, now: t0, demoMode: true).eligible.map(\.id) == [stop.id])
    }

    @Test("Equal timestamps have deterministic lexical event identity tie-breaking")
    func equalTimestampOrdering() {
        let a = outcome("a", kind: .failed)
        let z = outcome("z", kind: .completed)
        let forward = snapshot(tasks: [task()], outcomes: [a, z]).workLedger
        let reverse = snapshot(tasks: [task()], outcomes: [z, a]).workLedger
        #expect(forward.taskStates == reverse.taskStates)
        #expect(forward.status(of: "pickup") == .completed(at: t0))
        #expect(forward.activeOutcomes["pickup"]?.id == "z")
    }

    @Test("Replaying the same mixed-work events in different orders and with duplicates is deterministic")
    func mixedReplayDeterminism() {
        let definitions = [task(), task("check", kind: .checklist)]
        let events = [delivery("delivery-fail", kind: .failed), delivery("delivery-retry", kind: .requeued, seconds: 5), delivery("delivery-done", kind: .delivered, seconds: 10), outcome("pickup-defer", kind: .skipped), outcome("pickup-retry", kind: .requeued, seconds: 5), outcome("check-done", taskID: "check", kind: .completed, seconds: 20)]
        let expected = snapshot(packages: [package()], tasks: definitions, outcomes: events)
        for replay in [Array(events.reversed()), events + events, [events[4], events[2], events[0], events[5], events[1], events[3], events[2]]] {
            let actual = snapshot(packages: [package()], tasks: definitions.reversed(), outcomes: replay)
            #expect(actual.workLedger.taskStates == expected.workLedger.taskStates)
            #expect(actual.workLedger.activeOutcomes == expected.workLedger.activeOutcomes)
            #expect(actual.workSummary == expected.workSummary)
            #expect(actual.ledger.packageStatus == expected.ledger.packageStatus)
            #expect(actual.workLedger.allTasks.map(\.id) == expected.workLedger.allTasks.map(\.id))
        }
    }

    @Test("A voided replay of an immutable event wins over its earlier active copy")
    func duplicateUndoReplay() {
        let active = outcome("event", kind: .completed)
        var undone = active
        undone.voidedAt = t0.addingTimeInterval(10)
        for events in [[active, undone], [undone, active], [active, active, undone, active]] {
            let ledger = snapshot(tasks: [task()], outcomes: events).workLedger
            #expect(ledger.status(of: "pickup") == .pending)
            #expect(ledger.activeOutcomes.isEmpty && ledger.summary.completed == 0)
            #expect(ledger.hasOutstandingRequiredWork(at: stop.id))
        }
    }

    @Test("Conflicting immutable payloads sharing an event ID block both targets")
    func conflictingEventIdentity() {
        let a = outcome("conflict", kind: .completed)
        let b = outcome("conflict", taskID: "check", kind: .completed)
        for events in [[a, b], [b, a], [a, b, a]] {
            let snap = snapshot(tasks: [task(), task("check", kind: .checklist)], outcomes: events)
            #expect(snap.workLedger.status(of: "pickup") == .unsupported)
            #expect(snap.workLedger.status(of: "check") == .unsupported)
            #expect(snap.workSummary.unsupported == 2 && snap.workSummary.completed == 0)
            #expect(Eligibility.evaluate(snap, now: t0, demoMode: true).excluded.first?.reason == .unsupportedTasks)
        }
    }

    @Test("An outcome at the wrong stop cannot mark known work complete")
    func wrongStopOutcome() {
        var misplaced = outcome("misplaced", kind: .completed)
        misplaced.stopID = "other-stop"
        let snap = snapshot(tasks: [task()], outcomes: [misplaced])
        #expect(snap.workLedger.status(of: "pickup") == .unsupported)
        #expect(snap.workSummary.completed == 0 && snap.workSummary.outstanding == 1)
        #expect(snap.workLedger.actionableTasks(at: stop.id).isEmpty)
    }

    @Test("Standalone task associations do not make an event target a delivery")
    func associatedPackageIsNotSecondCompletionSource() {
        var pickup = task()
        pickup.packageID = "parcel"
        let valid = outcome("pickup-done", kind: .completed)
        let snap = snapshot(packages: [package()], tasks: [pickup], outcomes: [valid])
        #expect(snap.workLedger.status(of: pickup.id) == .completed(at: t0))
        #expect(snap.workLedger.status(of: "delivery_parcel") == .pending)
        #expect(snap.workSummary.completed == 1 && snap.summary().delivered == 0)
        var invalid = valid
        invalid.packageID = "parcel"
        let unsafe = snapshot(packages: [package()], tasks: [pickup], outcomes: [invalid])
        #expect(unsafe.workLedger.status(of: pickup.id) == .unsupported)
        #expect(unsafe.workLedger.status(of: "delivery_parcel") == .unsupported)
        #expect(unsafe.workSummary.completed == 0)
    }

    @Test("Generalized delivery targeting keeps the legacy delivered disposition")
    func generalizedDeliveryIdentity() {
        let completed = TaskOutcome(id: "wrong-kind", taskID: "delivery_parcel", stopID: stop.id, kind: .completed, packageID: "parcel", recordedAt: t0)
        let invalid = snapshot(packages: [package()], outcomes: [completed])
        #expect(invalid.workLedger.status(of: "delivery_parcel") == .unsupported)
        #expect(invalid.summary().delivered == 0)
        let delivered = TaskOutcome(id: "delivered", taskID: "delivery_parcel", stopID: stop.id, kind: .delivered, packageID: "parcel", recordedAt: t0)
        let valid = snapshot(packages: [package()], outcomes: [delivered])
        #expect(valid.workLedger.status(of: "delivery_parcel") == .completed(at: t0))
        #expect(valid.ledger.status(of: "parcel") == .delivered(at: t0))
    }

    @Test("Orphaned outcome history cannot complete unrelated current work")
    func removedTargetHistory() {
        let old = outcome("old", taskID: "removed", kind: .completed)
        let historical = snapshot(packages: [package()], tasks: [task()], outcomes: [old])
        #expect(historical.workLedger.status(of: "delivery_parcel") == .pending)
        #expect(historical.workLedger.status(of: "pickup") == .pending)
        #expect(historical.workSummary.completed == 0 && historical.workSummary.outstanding == 2)

        let wrong = TaskOutcome(id: "wrong", taskID: "missing-task", stopID: stop.id, kind: .delivered, packageID: "parcel", recordedAt: t0)
        let snap = snapshot(packages: [package()], tasks: [task()], outcomes: [old, wrong])
        #expect(snap.workLedger.status(of: "delivery_parcel") == .unsupported)
        #expect(snap.workLedger.status(of: "pickup") == .pending)
        #expect(snap.workSummary.completed == 0 && snap.workSummary.outstanding == 2)
    }

    @Test("Unknown task kinds remain decodable and required unknown work blocks optimization")
    func unknownWorkKind() throws {
        let json = #"{"id":"future","schemaVersion":1,"stopID":"stop-1","kind":"inspection-v2","required":true,"title":"Inspect","instructions":"","orderRank":0,"createdAt":1790000000,"updatedAt":1790000000}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let future = try decoder.decode(LocationTask.self, from: Data(json.utf8))
        let snap = snapshot(tasks: [future])
        #expect(future.kind.rawValue == "inspection-v2")
        #expect(snap.workLedger.status(of: future.id) == .unsupported)
        #expect(snap.workSummary.unsupported == 1 && !snap.workSummary.isHandled)
        #expect(snap.workLedger.presentableTasks(at: stop.id).map(\.id) == [future.id])
        #expect(Eligibility.evaluate(snap, now: t0, demoMode: true).excluded.first?.reason == .unsupportedTasks)
        var optional = future
        optional.required = false
        let nonBlocking = snapshot(packages: [package()], tasks: [optional], outcomes: [delivery("done", kind: .delivered)])
        #expect(nonBlocking.workSummary.isHandled && nonBlocking.nextStop() == nil)
        #expect(Eligibility.evaluate(nonBlocking, now: t0, demoMode: true).completedStopIDs == [stop.id])
    }

    @Test("Persisted delivery definitions cannot shadow a package's projected identity")
    func duplicateDeliveryDefinition() {
        let shadow = task("delivery_parcel", kind: .delivery, required: false, stopID: "wrong-stop")
        let snap = snapshot(packages: [package()], tasks: [shadow], outcomes: [delivery("done", kind: .delivered)])
        #expect(snap.workLedger.status(of: "delivery_parcel") == .unsupported)
        #expect(snap.workLedger.allTasks.count == 1)
        #expect(snap.workLedger.allTasks[0].stopID == stop.id && snap.workLedger.allTasks[0].required)
        #expect(snap.workSummary.required == 1 && snap.workSummary.optional == 0 && snap.workSummary.unsupported == 1)
        #expect(snap.summary().delivered == 0)
        #expect(Eligibility.evaluate(snap, now: t0, demoMode: true).excluded.first?.reason == .unsupportedTasks)
    }

    @Test("Repeated identical task definitions are one obligation, not duplicate progress")
    func identicalDefinitionReplay() {
        let pickup = task()
        let done = outcome("done", kind: .completed)
        let snap = snapshot(tasks: [pickup, pickup, pickup], outcomes: [done, done])
        #expect(snap.workLedger.allTasks.map(\.id) == [pickup.id])
        #expect(snap.workSummary.required == 1 && snap.workSummary.completed == 1)
        #expect(snap.workLedger.stopStatus(stop) == .completed)
    }

    @Test("Conflicting optional and required definitions cannot downgrade required work")
    func conflictingDefinitionRequiredSafety() {
        let required = task()
        var optional = required
        optional.required = false
        for definitions in [[required, optional], [optional, required]] {
            let snap = snapshot(tasks: definitions, outcomes: [outcome("done", kind: .completed)])
            #expect(snap.workSummary.required == 1 && snap.workSummary.optional == 0)
            #expect(snap.workSummary.unsupported == 1 && snap.workSummary.completed == 0)
            #expect(snap.workLedger.hasOutstandingRequiredWork(at: stop.id))
            #expect(Eligibility.evaluate(snap, now: t0, demoMode: true).excluded.first?.reason == .unsupportedTasks)
        }
    }

    @Test("Required orphan tasks invalidate a proposal even if known stops are planned")
    func orphanRequiredTaskProposal() {
        let snap = snapshot(packages: [package()], tasks: [task("orphan", stopID: "removed-stop")])
        let proposal = ProposalTests().proposal(snap, order: [stop.id])
        if case .invalid = ProposalValidator.validate(proposal, against: snap, now: t0, demoMode: true) {} else {
            Issue.record("A proposal must not silently omit required orphan work")
        }
    }

    @Test("Required presentation order is stable and keeps all mixed obligations visible")
    func mixedPresentationOrder() {
        var pickup = task("pickup")
        pickup.orderRank = 2
        var checklist = task("check", kind: .checklist)
        checklist.orderRank = 1
        let optional = task("optional", kind: .checklist, required: false)
        let snap = snapshot(packages: [package()], tasks: [optional, pickup, checklist])
        #expect(snap.workLedger.tasks(at: stop.id).map(\.id) == ["delivery_parcel", "check", "pickup", "optional"])
        #expect(snap.workSummary.required == 3 && snap.workSummary.optional == 1 && snap.workSummary.outstanding == 3)
        let reversed = snapshot(packages: [package()], tasks: [checklist, pickup, optional])
        #expect(reversed.workLedger.presentableTasks(at: stop.id).map(\.id) == snap.workLedger.presentableTasks(at: stop.id).map(\.id))
    }

    @Test("Malformed/unknown outcome schemas fail decoding instead of becoming lost work")
    func unsupportedOutcomeSchema() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        for json in [
            #"{"id":"bad","schemaVersion":3,"taskID":"pickup","stopID":"stop-1","kind":"completed","recordedAt":1790000000,"photoIDs":[]}"#,
            #"{"id":"bad","schemaVersion":1,"stopID":"stop-1","kind":"delivered","recordedAt":1790000000,"photoIDs":[]}"#,
            #"{"id":"bad","schemaVersion":1,"packageID":"parcel","stopID":"stop-1","kind":"completed","recordedAt":1790000000,"photoIDs":[]}"#,
            #"{"id":"bad","schemaVersion":2,"taskID":"pickup","stopID":"stop-1","kind":"future-success","recordedAt":1790000000,"photoIDs":[]}"#
        ] {
            #expect(throws: DecodingError.self) { try decoder.decode(TaskOutcome.self, from: Data(json.utf8)) }
        }
    }
}
