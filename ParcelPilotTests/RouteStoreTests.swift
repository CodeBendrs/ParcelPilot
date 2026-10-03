import FirebaseFirestore
import Foundation
import ImageIO
import ParcelPilotKit
import Testing
@testable import ParcelPilot

@MainActor
@Suite("Route store (on-device backend)", .serialized)
struct RouteStoreTests {
    @Test("E3: same destination → one stop with two packages; other unit → separate stop; repeated tracking → no new package")
    func intakePlacement() {
        let env = TestEnvironment()
        env.makeRoute()
        let e1 = PostalAddress.e1()
        let first = env.store.addDelivery(to: env.snapshot, address: e1, status: .demoSynthetic, resolution: nil, reviewReasons: [], packages: [PackageDraft(trackingID: "1Z999AA10123456784")], source: .scan)
        #expect(first.placement == .newStop)
        let second = env.store.addDelivery(to: env.snapshot, address: e1, status: .demoSynthetic, resolution: nil, reviewReasons: [], packages: [PackageDraft(trackingID: "1Z999AA10123456795")], source: .scan)
        #expect(second.placement == .existingStop(first.stopID))
        let repeated = env.store.addDelivery(to: env.snapshot, address: e1, status: .demoSynthetic, resolution: nil, reviewReasons: [], packages: [PackageDraft(trackingID: "1Z999AA10123456784")], source: .scan)
        #expect(repeated.placement == .duplicateTracking(packageID: first.packageIDs[0], stopID: first.stopID))
        #expect(repeated.packageIDs.isEmpty)
        var other = e1
        other.unit = "305"
        let otherUnit = env.store.addDelivery(to: env.snapshot, address: other, status: .demoSynthetic, resolution: nil, reviewReasons: [], packages: [PackageDraft(trackingID: "1Z999AA10123456806")], source: .scan)
        #expect(otherUnit.placement == .newStop)
        #expect(env.snapshot.stops.count == 2)
        #expect(env.snapshot.packages.count == 3)
        #expect(env.snapshot.packages(for: first.stopID).count == 2)
    }

    @Test("Edits to addresses, constraints and the stop set bump the input revision; reorder and notes do not")
    func revisions() throws {
        let env = TestEnvironment()
        env.makeRoute()
        let r0 = env.snapshot.route.inputRevision
        let add = env.store.addDelivery(to: env.snapshot, address: .e1(), status: .demoSynthetic, resolution: nil, reviewReasons: [], packages: [PackageDraft()], source: .manual)
        #expect(env.snapshot.route.inputRevision == r0 + 1)
        var stop = try #require(env.snapshot.stops.first { $0.id == add.stopID })
        stop.notes = "Buzzer 204"
        env.store.update(stop: stop, in: env.snapshot.route, invalidatesPlan: false)
        #expect(env.snapshot.route.inputRevision == r0 + 1)
        stop.timeWindow = TimeWindowConstraint(kind: .hard, startMinute: 540, endMinute: 600)
        env.store.update(stop: stop, in: env.snapshot.route, invalidatesPlan: true)
        #expect(env.snapshot.route.inputRevision == r0 + 2)
        env.store.reorder(env.snapshot.orderedStops.map(\.id).reversed(), in: env.snapshot)
        #expect(env.snapshot.route.inputRevision == r0 + 2)
    }

    @Test("E6: an offline delivery outcome survives app termination, appears once, and Undo voids it")
    func outcomesSurviveRelaunch() throws {
        let env = TestEnvironment(online: false)
        env.makeRoute()
        let add = env.store.addDelivery(to: env.snapshot, address: .e1(), status: .demoSynthetic, resolution: nil, reviewReasons: [], packages: [PackageDraft(trackingID: "1Z999AA10123456784")], source: .scan)
        let ids = env.store.record(.delivered, packageIDs: add.packageIDs, stopID: add.stopID, in: env.snapshot, label: "Delivered")
        #expect(ids.count == 1)

        let relaunched = env.relaunch(online: true)
        relaunched.store.currentRouteID = env.snapshot.route.id
        let snap = try #require(relaunched.store.current)
        #expect(snap.outcomes.count == 1)
        #expect(snap.ledger.status(of: add.packageIDs[0]) == .delivered(at: snap.outcomes[0].recordedAt))
        #expect(snap.route.status == .active)

        // Replaying the same outcome (e.g. a retried sync) does not duplicate it.
        relaunched.store.commitPrepared([.createOutcome(snap.route.id, snap.outcomes[0])], label: "Replay", critical: true)
        #expect(relaunched.store.current!.outcomes.count == 1)

        relaunched.store.undo(outcomeIDs: ids, in: relaunched.store.current!)
        let after = relaunched.store.current!
        #expect(after.ledger.status(of: add.packageIDs[0]) == .pending)
        #expect(after.outcomes.first?.voidedAt != nil)
        // Void is once-only (append-only semantics, same as the Firestore rules).
        let voidedAt = after.outcomes.first!.voidedAt
        relaunched.store.undo(outcomeIDs: ids, in: after)
        #expect(relaunched.store.current!.outcomes.first!.voidedAt == voidedAt)
    }

    @Test("E6/E8: applying a late proposal never changes outcomes; stale proposals are rejected")
    func lateProposal() async throws {
        let env = TestEnvironment()
        env.makeRoute()
        for i in 0..<4 {
            var a = PostalAddress.e1()
            a.civicNumber = "\(100 + i)"
            a.unit = nil
            let r = try await DemoAddressResolver().resolve(.address(a))
            let assessment = MatchAssessor.assess(address: a, candidates: r.candidates)
            env.store.addDelivery(to: env.snapshot, address: a, status: .demoSynthetic, resolution: env.services.verifier.stopResolution(for: assessment, response: r), reviewReasons: [], packages: [PackageDraft()], source: .manual)
        }
        let proposal = try DemoOptimizer().optimize(snapshot: env.snapshot, options: OptimizationOptions(), requestID: "req", now: Date(timeIntervalSince1970: 1_790_000_000))
        // A delivery is recorded after the request was made…
        let firstStop = env.snapshot.orderedStops[0]
        env.store.record(.delivered, packageIDs: env.snapshot.packages(for: firstStop.id).map(\.id), stopID: firstStop.id, in: env.snapshot, label: "Delivered")
        let verdict = ProposalValidator.validate(proposal, against: env.snapshot, now: Date(timeIntervalSince1970: 1_790_000_100), demoMode: true)
        if case .stale = verdict {} else { Issue.record("expected stale, got \(verdict)") }
        // …and even if applied, the delivered stop stays delivered.
        env.store.apply(proposal, to: env.snapshot)
        #expect(env.snapshot.ledger.stopStatus(env.snapshot.stops.first { $0.id == firstStop.id }!, packages: env.snapshot.packages) == .completed)

        // An edit while optimizing (revision bump) makes the result stale (E8).
        let fresh = try DemoOptimizer().optimize(snapshot: env.snapshot, options: OptimizationOptions(), requestID: "req2", now: Date(timeIntervalSince1970: 1_790_000_200))
        var stop = env.snapshot.orderedStops.last!
        stop.serviceSeconds = 300
        env.store.update(stop: stop, in: env.snapshot.route, invalidatesPlan: true)
        if case .stale = ProposalValidator.validate(fresh, against: env.snapshot, now: Date(timeIntervalSince1970: 1_790_000_300), demoMode: true) {} else { Issue.record("expected stale after edit") }
        #expect(env.snapshot.stops.first { $0.id == stop.id }?.serviceSeconds == 300)
    }

    @Test("Duplicate route copies stops and packages with new IDs and no outcomes")
    func duplicate() async throws {
        let env = TestEnvironment()
        let route = env.makeRoute()
        let add = env.store.addDelivery(to: env.snapshot, address: .e1(), status: .demoSynthetic, resolution: nil, reviewReasons: [], packages: [PackageDraft(), PackageDraft()], source: .manual)
        env.store.record(.delivered, packageIDs: add.packageIDs, stopID: add.stopID, in: env.snapshot, label: "Delivered")
        let copy = try await env.store.duplicate(route)
        #expect(copy.id != route.id)
        let snap = try #require(env.store.current)
        #expect(snap.route.id == copy.id)
        #expect(snap.stops.count == 1)
        #expect(snap.packages.count == 2)
        #expect(snap.outcomes.isEmpty)
        #expect(snap.stops[0].id != add.stopID)
    }

    @Test("Archive and resume")
    func archiveResume() {
        let env = TestEnvironment()
        let route = env.makeRoute()
        env.store.archive(env.snapshot.route)
        #expect(env.store.routes.first { $0.id == route.id }?.status == .archived)
        #expect(env.store.finishedRoutes.count == 1)
        env.store.resume(env.store.routes.first { $0.id == route.id }!)
        #expect(env.store.openRoutes.count == 1)
    }
}

@MainActor
@Suite("Server contract decoding")
struct ContractTests {
    @Test("Job documents written by Cloud Functions decode into proposals")
    func jobDecoding() throws {
        let ts = { (s: Double) in Timestamp(seconds: Int64(s), nanoseconds: 0) }
        let data: [String: Any] = [
            "routeId": "r1", "inputRevision": 3, "status": "infeasible", "provider": "google",
            "createdAt": ts(1_790_000_000), "updatedAt": ts(1_790_000_010),
            "proposal": [
                "requestId": "req", "routeId": "r1", "inputRevision": 3, "provider": "google", "status": "infeasible",
                "calculatedAt": ts(1_790_000_005), "expiresAt": ts(1_790_086_405), "trafficConsidered": true,
                "origin": ["kind": "currentLocation", "latitude": 48.4, "longitude": -123.3], "fixedNextStopId": "s2",
                "visits": [["stopId": "s2", "arrival": ts(1_790_000_600), "start": ts(1_790_000_700), "departure": ts(1_790_000_820)]],
                "unassigned": [["stopId": "s1", "code": "CANNOT_BE_PERFORMED_WITHIN_VEHICLE_TIME_WINDOWS", "message": "Can't be reached.", "suggestions": ["Widen the window."]]],
                "excluded": [["stopId": "s3", "reason": "completed"]],
                "breaks": [], "metrics": ["routeStart": ts(1_790_000_000), "routeEnd": ts(1_790_003_600), "travelSeconds": 1800, "travelMeters": 12000, "serviceSeconds": 120, "waitSeconds": 100, "breakSeconds": 0],
                "baseline": NSNull(), "baselineNote": "Comparison unavailable.", "polylines": ["abc", "def"], "completedStopIdsAtRequest": ["s3"], "warnings": ["Note"],
            ],
        ]
        let job = try #require(JobDecoder.decode(id: "req", data: data))
        #expect(job.status == .infeasible)
        let p = try #require(job.proposal)
        #expect(p.provider == .google)
        #expect(p.trafficConsidered)
        #expect(p.origin == .currentLocation(GeoPoint(latitude: 48.4, longitude: -123.3)))
        #expect(p.visits.count == 1 && p.visits[0].waitSeconds == 100)
        #expect(p.unassigned[0].issue.suggestions == ["Widen the window."])
        #expect(p.excluded == [ExcludedStop(stopID: "s3", reason: .completed)])
        #expect(p.metrics?.totalSeconds == 3600)
        #expect(p.baseline == nil)
        #expect(p.savings == nil)
        #expect(p.polylines == ["abc", "def"])
        #expect(p.warnings == ["Note", "Comparison unavailable."])
        #expect(p.trafficLabel.contains("not live traffic"))
    }

    @Test("Timeline sent to the server uses the device's wall-clock conversion")
    func timeline() throws {
        var route = Route(name: "T", serviceDate: "2026-11-01", timeZoneID: "America/Toronto", departureMinute: 90)
        route.breakRule = BreakRequirement(earliestStartMinute: 720, latestStartMinute: 780, durationSeconds: 1800)
        var stop = Stop(address: .e1(), addressStatus: .verified, sequence: 1)
        stop.timeWindow = TimeWindowConstraint(kind: .hard, startMinute: 1380, endMinute: 1500)
        let t = try #require(TimelineBuilder.build(RouteSnapshot(route: route, stops: [stop], packages: [], outcomes: [])))
        #expect(t.departure == "2026-11-01T05:30:00Z") // ambiguous 01:30 → earlier instant (EDT)
        #expect(t.windows[stop.id]?.start == "2026-11-02T04:00:00Z")
        #expect(t.windows[stop.id]?.end == "2026-11-02T06:00:00Z") // crosses midnight
        #expect(t.breakWindow?.earliest == "2026-11-01T17:00:00Z")
        #expect(t.tzdataVersion?.isEmpty == false)
    }
}

@MainActor
@Suite("Proof-of-delivery photos")
struct PhotoTests {
    @Test("Re-encoded photos are bounded and carry no EXIF/GPS metadata")
    func stripsMetadata() throws {
        let image = try #require(AppFixtures.label("e1_victoria_unit204"))
        let jpeg = try #require(PhotoEncoder.jpeg(from: image, maxDimension: 800))
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        #expect(props[kCGImagePropertyGPSDictionary] == nil)
        #expect((props[kCGImagePropertyPixelWidth] as? Int ?? 0) <= 800)
        #expect(jpeg.count < 5 * 1024 * 1024)
    }

    @Test("Demo photo store saves and deletes photos with their records")
    func demoStore() async throws {
        let env = TestEnvironment()
        env.makeRoute()
        let add = env.store.addDelivery(to: env.snapshot, address: .e1(), status: .demoSynthetic, resolution: nil, reviewReasons: [], packages: [PackageDraft()], source: .manual)
        let image = try #require(AppFixtures.label("e1_victoria_unit204"))
        let id = try env.services.photos.add(jpeg: PhotoEncoder.jpeg(from: image)!, routeID: env.snapshot.route.id, stopID: add.stopID, packageIDs: add.packageIDs)
        let photo = try #require(env.snapshot.photos.first { $0.id == id })
        _ = try await env.services.photos.image(for: photo, routeID: env.snapshot.route.id)
        try await env.services.photos.delete(photo: photo, routeID: env.snapshot.route.id)
        #expect(env.snapshot.photos.isEmpty)
    }
}
