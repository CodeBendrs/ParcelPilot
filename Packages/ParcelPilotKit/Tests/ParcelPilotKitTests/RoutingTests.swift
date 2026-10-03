import Foundation
import Testing
@testable import ParcelPilotKit

@Suite("Wall clock and time zones")
struct WallClockTests {
    struct Case: Decodable { let name, timeZone, serviceDate: String; let minute: Int; let expectedUTC, resolution: String }
    struct File: Decodable { let cases: [Case] }

    @Test("Shared DST / midnight fixture (also used by Cloud Functions tests)")
    func sharedFixture() throws {
        let file = try JSONDecoder().decode(File.self, from: try Fixtures.sharedJSON("timezone-cases.json"))
        #expect(file.cases.count >= 10)
        for c in file.cases {
            let date = try #require(WallClock.ServiceDate(iso: c.serviceDate))
            let tz = try #require(TimeZone(identifier: c.timeZone))
            let result = WallClock.instant(serviceDate: date, minute: c.minute, timeZone: tz)
            #expect(WallClock.rfc3339(result.date) == c.expectedUTC, "\(c.name)")
            #expect(result.resolution.rawValue == c.resolution, "\(c.name)")
        }
    }

    @Test func rejectsImpossibleDates() {
        #expect(WallClock.ServiceDate(iso: "2026-02-30") == nil)
        #expect(WallClock.ServiceDate(iso: "2026-13-01") == nil)
        #expect(WallClock.ServiceDate(iso: "2026-10-03")?.iso == "2026-10-03")
    }

    @Test func minuteRoundTripAcrossMidnight() {
        let date = WallClock.ServiceDate(iso: "2026-10-03")!
        let tz = TimeZone(identifier: "America/Vancouver")!
        let instant = WallClock.instant(serviceDate: date, minute: 1530, timeZone: tz).date
        #expect(WallClock.minute(of: instant, serviceDate: date, timeZone: tz) == 1530)
        #expect(WallClock.label(1530) == "1:30 AM (+1 day)")
    }

    @Test func windowValidation() {
        #expect(TimeWindowConstraint(kind: .hard, startMinute: 540, endMinute: 600).isValid)
        #expect(!TimeWindowConstraint(kind: .hard, startMinute: 600, endMinute: 540).isValid)
        #expect(TimeWindowConstraint(kind: .hard, startMinute: 1380, endMinute: 1500).isValid) // 23:00–01:00
        #expect(TimeWindowConstraint(kind: .softDeadline, startMinute: nil, endMinute: 630).isValid)
    }
}

@Suite("Delivery ledger")
struct DeliveryLedgerTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func snapshot(outcomes: [DeliveryOutcome]) -> RouteSnapshot {
        let route = makeRoute()
        let s1 = makeStop(1, lat: 48.43, lng: -123.36)
        let s2 = makeStop(2, lat: 48.44, lng: -123.35)
        let packages = [
            Package(id: "a", stopID: s1.id, source: .manual, now: t0),
            Package(id: "b", stopID: s1.id, source: .manual, now: t0),
            Package(id: "c", stopID: s2.id, source: .manual, now: t0),
        ]
        return RouteSnapshot(route: route, stops: [s1, s2], packages: packages, outcomes: outcomes)
    }

    @Test("A stop is complete only when all its packages are handled")
    func packageLevel() {
        var snap = snapshot(outcomes: [DeliveryOutcome(id: "o1", packageID: "a", stopID: "stop-1", kind: .delivered, recordedAt: t0)])
        #expect(snap.ledger.stopStatus(snap.stops[0], packages: snap.packages) == .partial)
        #expect(snap.nextStop()?.id == "stop-1")
        snap.outcomes.append(DeliveryOutcome(id: "o2", packageID: "b", stopID: "stop-1", kind: .failed, reason: .noOneHome, recordedAt: t0.addingTimeInterval(5)))
        #expect(snap.ledger.stopStatus(snap.stops[0], packages: snap.packages) == .completed)
        #expect(snap.nextStop()?.id == "stop-2")
    }

    @Test("Undo voids the outcome; requeue returns a skipped package to remaining work")
    func undoAndRequeue() {
        var skipped = DeliveryOutcome(id: "o1", packageID: "c", stopID: "stop-2", kind: .skipped, recordedAt: t0)
        var snap = snapshot(outcomes: [skipped])
        #expect(snap.ledger.stopStatus(snap.stops[1], packages: snap.packages) == .skipped)
        skipped.voidedAt = t0.addingTimeInterval(3)
        snap.outcomes = [skipped]
        #expect(snap.ledger.status(of: "c") == .pending)
        snap.outcomes = [DeliveryOutcome(id: "o1", packageID: "c", stopID: "stop-2", kind: .skipped, recordedAt: t0), DeliveryOutcome(id: "o2", packageID: "c", stopID: "stop-2", kind: .requeued, recordedAt: t0.addingTimeInterval(60))]
        #expect(snap.ledger.status(of: "c") == .pending)
    }

    @Test("E6: outcome state is independent of arrival order and duplicates (offline replay)")
    func orderIndependent() {
        let o1 = DeliveryOutcome(id: "o1", packageID: "a", stopID: "stop-1", kind: .failed, reason: .accessIssue, recordedAt: t0)
        let o2 = DeliveryOutcome(id: "o2", packageID: "a", stopID: "stop-1", kind: .delivered, recordedAt: t0.addingTimeInterval(120))
        let forward = snapshot(outcomes: [o1, o2]).ledger.status(of: "a")
        let reversed = snapshot(outcomes: [o2, o1, o2]).ledger.status(of: "a")
        #expect(forward == reversed)
        #expect(forward == .delivered(at: t0.addingTimeInterval(120)))
        let summary = snapshot(outcomes: [o1, o2, o2]).summary()
        #expect(summary.delivered == 1)
        #expect(summary.pending == 2)
    }

    @Test("Driver's chosen next stop wins while it still has work")
    func nextOverride() {
        var snap = snapshot(outcomes: [])
        snap.route.nextStopOverrideID = "stop-2"
        #expect(snap.nextStop()?.id == "stop-2")
    }
}

@Suite("Proposals")
struct ProposalTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func snapshot() -> RouteSnapshot {
        let stops = (1...4).map { makeStop($0, lat: 48.42 + Double($0) * 0.01, lng: -123.36) }
        let packages = stops.map { Package(id: "p-\($0.id)", stopID: $0.id, source: .manual, now: now) }
        return RouteSnapshot(route: makeRoute(), stops: stops, packages: packages, outcomes: [])
    }

    func proposal(_ snap: RouteSnapshot, order: [String]) -> OptimizationProposal {
        let visits = order.enumerated().map { i, id in PlannedVisit(stopID: id, arrival: now.addingTimeInterval(Double(i) * 600), start: now.addingTimeInterval(Double(i) * 600), departure: now.addingTimeInterval(Double(i) * 600 + 120)) }
        return OptimizationProposal(requestID: "r1", routeID: snap.route.id, inputRevision: snap.route.inputRevision, provider: .demo, status: .feasible, calculatedAt: now, expiresAt: now.addingTimeInterval(3600), trafficConsidered: false, origin: .routeStart, fixedNextStopID: nil, visits: visits, unassigned: [], excluded: [], breaks: [], metrics: nil, baseline: nil, polylines: [], completedStopIDsAtRequest: [])
    }

    @Test func validProposalApplies() {
        let snap = snapshot()
        let p = proposal(snap, order: ["stop-3", "stop-1", "stop-4", "stop-2"])
        #expect(ProposalValidator.validate(p, against: snap, now: now, demoMode: true) == .valid)
        let seq = ProposalValidator.sequencesAfterApplying(p, to: snap)
        #expect(seq["stop-3"] == 1 && seq["stop-2"] == 4)
        #expect(!ProposalValidator.positionChanges(p, snapshot: snap).isEmpty)
    }

    @Test("E8: an edit during optimization makes the result stale")
    func staleRevision() {
        var snap = snapshot()
        let p = proposal(snap, order: ["stop-1", "stop-2", "stop-3", "stop-4"])
        snap.route.inputRevision += 1
        if case .stale = ProposalValidator.validate(p, against: snap, now: now, demoMode: true) {} else { Issue.record("expected stale") }
    }

    @Test("E6: a late proposal cannot undo a recorded delivery")
    func lateProposalAfterDelivery() {
        var snap = snapshot()
        let p = proposal(snap, order: ["stop-1", "stop-2", "stop-3", "stop-4"])
        snap.outcomes.append(DeliveryOutcome(packageID: "p-stop-1", stopID: "stop-1", kind: .delivered, recordedAt: now))
        if case .stale = ProposalValidator.validate(p, against: snap, now: now, demoMode: true) {} else { Issue.record("expected stale") }
        // Even if applied, sequences never touch outcomes and the stop stays delivered.
        _ = ProposalValidator.sequencesAfterApplying(p, to: snap)
        #expect(snap.ledger.stopStatus(snap.stops[0], packages: snap.packages) == .completed)
    }

    @Test("Missing or duplicated stops are rejected")
    func invariants() {
        let snap = snapshot()
        if case .stale = ProposalValidator.validate(proposal(snap, order: ["stop-1", "stop-2", "stop-3"]), against: snap, now: now, demoMode: true) {} else { Issue.record("expected stale for missing stop") }
        if case .invalid = ProposalValidator.validate(proposal(snap, order: ["stop-1", "stop-1", "stop-2", "stop-3", "stop-4"]), against: snap, now: now, demoMode: true) {} else { Issue.record("expected invalid for duplicate") }
        var expired = proposal(snap, order: ["stop-1", "stop-2", "stop-3", "stop-4"])
        expired.expiresAt = now.addingTimeInterval(-1)
        if case .stale = ProposalValidator.validate(expired, against: snap, now: now, demoMode: true) {} else { Issue.record("expected stale for expiry") }
    }

    @Test("Pins are enforced by validation")
    func pins() {
        var snap = snapshot()
        snap.stops[3].pin = .first
        if case .invalid = ProposalValidator.validate(proposal(snap, order: ["stop-1", "stop-2", "stop-3", "stop-4"]), against: snap, now: now, demoMode: true) {} else { Issue.record("expected invalid") }
        #expect(ProposalValidator.validate(proposal(snap, order: ["stop-4", "stop-2", "stop-3", "stop-1"]), against: snap, now: now, demoMode: true) == .valid)
    }

    @Test("Savings only exist when a baseline was computed")
    func savings() {
        let snap = snapshot()
        var p = proposal(snap, order: ["stop-1", "stop-2", "stop-3", "stop-4"])
        #expect(p.savings == nil)
        p.metrics = PlanMetrics(routeStart: now, routeEnd: now.addingTimeInterval(3000), travelSeconds: 2000, travelMeters: 10_000, serviceSeconds: 1000, waitSeconds: 0, breakSeconds: 0)
        #expect(p.savings == nil)
        p.baseline = PlanMetrics(routeStart: now, routeEnd: now.addingTimeInterval(3600), travelSeconds: 2600, travelMeters: 12_000, serviceSeconds: 1000, waitSeconds: 0, breakSeconds: 0)
        #expect(p.savings?.seconds == 600)
    }
}

@Suite("Demo optimizer (straight-line baseline)")
struct DemoOptimizerTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func snapshot(count: Int, seed: UInt64 = 7) -> RouteSnapshot {
        var rng = SeededRandom(seed: seed)
        let stops = (1...count).map { i in makeStop(i, lat: 48.40 + rng.next() * 0.1, lng: -123.42 + rng.next() * 0.12) }
        let packages = stops.map { Package(id: "p-\($0.id)", stopID: $0.id, source: .manual, now: now) }
        var route = makeRoute()
        route.returnToStart = true
        return RouteSnapshot(route: route, stops: stops, packages: packages, outcomes: [])
    }

    @Test("Every eligible stop appears exactly once")
    func exactlyOnce() throws {
        let snap = snapshot(count: 25)
        let p = try DemoOptimizer().optimize(snapshot: snap, options: OptimizationOptions(), requestID: "r", now: now)
        #expect(p.provider == .demo)
        #expect(Set(p.visits.map(\.stopID)).count == 25)
        #expect(p.visits.count + p.unassigned.count == 25)
        #expect(ProposalValidator.validate(p, against: snap, now: now, demoMode: true) == .valid)
        #expect(p.trafficLabel.contains("Straight-line"))
    }

    @Test("E11: 10/50/200-stop timings for the on-device demo heuristic (not the production optimizer)", arguments: [10, 50, 200])
    func timings(count: Int) throws {
        let snap = snapshot(count: count)
        let clock = ContinuousClock()
        var proposal: OptimizationProposal?
        let elapsed = try clock.measure {
            proposal = try DemoOptimizer().optimize(snapshot: snap, options: OptimizationOptions(), requestID: "r", now: now)
        }
        let p = try #require(proposal)
        #expect(p.visits.count == count)
        #expect(ProposalValidator.validate(p, against: snap, now: now, demoMode: true) == .valid)
        let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        print("E11 demo-heuristic stops=\(count) optimize+validate-input ms=\(String(format: "%.1f", ms)) (on-device, straight-line, synthetic)")
        #expect(elapsed < .seconds(5))
    }

    @Test("Improvement never makes the plan longer than the input order, and 200 stops with deadlines stay within budget")
    func qualityAndBudget() throws {
        let snap = snapshot(count: 80, seed: 11)
        let p = try DemoOptimizer().optimize(snapshot: snap, options: OptimizationOptions(computeBaseline: true), requestID: "r", now: now)
        let baseline = try #require(p.baseline)
        let metrics = try #require(p.metrics)
        #expect(metrics.travelMeters < baseline.travelMeters * 0.6) // random input order vs optimized

        var constrained = snapshot(count: 200, seed: 5)
        for k in stride(from: 0, to: 200, by: 7) {
            constrained.stops[k].timeWindow = TimeWindowConstraint(kind: .softDeadline, startMinute: nil, endMinute: 600 + k)
        }
        let clock = ContinuousClock()
        var proposal: OptimizationProposal?
        let elapsed = try clock.measure {
            proposal = try DemoOptimizer().optimize(snapshot: constrained, options: OptimizationOptions(), requestID: "r", now: now)
        }
        let q = try #require(proposal)
        #expect(q.visits.count + q.unassigned.count == 200)
        #expect(ProposalValidator.validate(q, against: constrained, now: now, demoMode: true) == .valid)
        print("E11 demo-heuristic stops=200 with soft deadlines ms=\(elapsed)")
        #expect(elapsed < .seconds(4))
    }

    @Test("First/last pins and a fixed next stop are honoured with consistent times")
    func pins() throws {
        var snap = snapshot(count: 12)
        snap.stops[5].pin = .first
        snap.stops[2].pin = .last
        let p = try DemoOptimizer().optimize(snapshot: snap, options: OptimizationOptions(), requestID: "r", now: now)
        #expect(p.visits.first?.stopID == snap.stops[5].id)
        #expect(p.visits.last?.stopID == snap.stops[2].id)
        for (a, b) in zip(p.visits, p.visits.dropFirst()) { #expect(b.arrival >= a.departure) }
        let fixed = try DemoOptimizer().optimize(snapshot: snap, options: OptimizationOptions(fixedNextStopID: snap.stops[8].id), requestID: "r2", now: now)
        #expect(fixed.visits.first?.stopID == snap.stops[8].id)
    }

    @Test("E7: incompatible hard windows are reported, nothing is dropped")
    func infeasibleWindows() throws {
        var snap = snapshot(count: 6)
        // Two far-apart stops that both must be visited within the same 10 minutes right at departure.
        snap.stops[0].resolution?.located?.point = GeoPoint(latitude: 48.40, longitude: -123.50)
        snap.stops[1].resolution?.located?.point = GeoPoint(latitude: 48.60, longitude: -123.30)
        snap.stops[0].timeWindow = TimeWindowConstraint(kind: .hard, startMinute: 8 * 60, endMinute: 8 * 60 + 40)
        snap.stops[1].timeWindow = TimeWindowConstraint(kind: .hard, startMinute: 8 * 60, endMinute: 8 * 60 + 40)
        let p = try DemoOptimizer().optimize(snapshot: snap, options: OptimizationOptions(), requestID: "r", now: now)
        #expect(p.status == .infeasible)
        #expect(!p.unassigned.isEmpty)
        #expect(p.unassigned.allSatisfy { $0.issue.code == "time-window-conflict" && !$0.issue.suggestions.isEmpty })
        #expect(p.visits.count + p.unassigned.count == 6) // every stop accounted for
        #expect(snap.packages.count == 6) // packages untouched
    }

    @Test("Hard windows wait when early; soft deadlines report lateness")
    func windows() throws {
        var snap = snapshot(count: 3)
        snap.stops[0].timeWindow = TimeWindowConstraint(kind: .hard, startMinute: 10 * 60, endMinute: 11 * 60)
        let p = try DemoOptimizer().optimize(snapshot: snap, options: OptimizationOptions(), requestID: "r", now: now)
        let visit = try #require(p.visits.first { $0.stopID == snap.stops[0].id })
        let opens = WallClock.instant(route: snap.route, minute: 600)!
        #expect(visit.start >= opens)
    }

    @Test("Break is scheduled within its window")
    func breakRule() throws {
        var snap = snapshot(count: 20)
        snap.route.breakRule = BreakRequirement(earliestStartMinute: 8 * 60 + 30, latestStartMinute: 13 * 60, durationSeconds: 1800)
        let p = try DemoOptimizer().optimize(snapshot: snap, options: OptimizationOptions(), requestID: "r", now: now)
        #expect(p.breaks.count == 1)
        #expect(p.metrics?.breakSeconds == 1800)
    }

    @Test("Ineligible stops are explained, not silently dropped")
    func ineligible() throws {
        var snap = snapshot(count: 5)
        snap.stops[0].addressStatus = .needsReview
        snap.outcomes.append(DeliveryOutcome(packageID: "p-stop-2", stopID: "stop-2", kind: .delivered, recordedAt: now))
        let p = try DemoOptimizer().optimize(snapshot: snap, options: OptimizationOptions(), requestID: "r", now: now)
        #expect(p.visits.count == 3)
        #expect(p.excluded.contains(ExcludedStop(stopID: "stop-1", reason: .addressNotVerified)))
        #expect(p.excluded.contains(ExcludedStop(stopID: "stop-2", reason: .completed)))
        #expect(p.completedStopIDsAtRequest == ["stop-2"])
    }

    @Test("Missing origin is an actionable error")
    func missingOrigin() {
        var snap = snapshot(count: 3)
        snap.route.start = nil
        #expect(throws: DemoOptimizer.Failure.missingStart) { try DemoOptimizer().optimize(snapshot: snap, options: OptimizationOptions(), requestID: "r", now: now) }
        #expect((try? DemoOptimizer().optimize(snapshot: snap, options: OptimizationOptions(origin: .currentLocation(GeoPoint(latitude: 48.4, longitude: -123.3))), requestID: "r", now: now)) != nil)
    }

    @Test("Benchmark (demo baseline, local, NOT the production optimizer): 10 / 50 / 200 stops", arguments: [10, 50, 200])
    func benchmark(count: Int) throws {
        let snap = snapshot(count: count)
        let clock = ContinuousClock()
        var proposal: OptimizationProposal?
        let elapsed = try clock.measure { proposal = try DemoOptimizer(maxImprovementPasses: count > 100 ? 2 : 4).optimize(snapshot: snap, options: OptimizationOptions(), requestID: "b", now: now) }
        let p = try #require(proposal)
        #expect(p.visits.count == count)
        print("[benchmark][demo-baseline][local-mac] stops=\(count) elapsed=\(elapsed)")
        #expect(elapsed < .seconds(60))
    }
}

struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
}

@Suite("Bulk import")
struct ImportTests {
    let empty = RouteIntakeIndex(stops: [], packages: [])

    @Test func csvQuotesAndDelimiters() {
        let rows = CSVReader.parse("Name,Address,Notes\r\n\"Test, Alex\",\"123 Example St, Victoria BC V8W 1A1\",\"Say \"\"hi\"\"\"\r\n")
        #expect(rows.count == 2)
        #expect(rows[1][0] == "Test, Alex")
        #expect(rows[1][2] == "Say \"hi\"")
        let semi = CSVReader.parse("a;b\n1;2\n")
        #expect(semi == [["a", "b"], ["1", "2"]])
    }

    @Test func csvColumnMappingRowErrorsAndDuplicates() {
        let csv = """
        Recipient,Street,Unit,City,Province,Postal Code,Tracking,Qty
        Alex Test,123 Example St,204,Victoria,BC,V8W 1A1,1Z999AA10123456784,2
        Sam Test,123 Example St,204,Victoria,BC,V8W1A1,1Z999AA10123456795,1
        Riley Test,,,,,,,1
        Jordan Test,9 Mock Cres,,Halifax,NS,B3H 1A1,1Z999AA10123456784,x
        """
        let rows = CSVReader.parse(csv)
        let mapping = rows[0].map(ImportColumnRole.guess)
        #expect(mapping == [.recipientName, .street, .unit, .municipality, .province, .postalCode, .trackingID, .packageCount])
        let candidates = BulkImportPlanner.fromCSV(rows: rows, hasHeader: true, mapping: mapping, index: empty)
        #expect(candidates.count == 4)
        #expect(candidates[0].rowNumber == 2)
        #expect(candidates[0].parsed.address.unit == "204")
        #expect(candidates[0].packageCount == 2)
        #expect(candidates[1].duplicateOfRow == 2)
        #expect(!candidates[2].isImportable)
        #expect(candidates[3].duplicateTracking)
        #expect(candidates[3].errors.contains { $0.contains("Package count") })
    }

    @Test func pasteOnePerLineAndBlocks() {
        let lines = BulkImportPlanner.fromPaste("123 Example St, Victoria BC V8W 1A1\n9 Mock Cres, Halifax NS B3H 1A1\n", index: empty)
        #expect(lines.count == 2)
        let blocks = BulkImportPlanner.fromPaste("ALEX TEST\nUNIT 204\n123 EXAMPLE ST\nVICTORIA BC V8W 1A1\n\nCAMILLE TEST\n1234, rue Sainte-Catherine Ouest\nMontréal QC H3G 1P1", index: empty)
        #expect(blocks.count == 2)
        #expect(blocks[0].parsed.address.unit == "204")
        #expect(blocks[1].parsed.address.municipality == "Montréal")
        let single = BulkImportPlanner.fromPaste("ALEX TEST\nUNIT 204\n123 EXAMPLE ST\nVICTORIA BC V8W 1A1", index: empty)
        #expect(single.count == 1)
    }
}

@Suite("Navigation hand-off")
struct NavigationTests {
    let address = CanadianAddressParser.parse(singleLine: "ALEX TEST, UNIT 204, 123 EXAMPLE ST, VICTORIA BC V8W 1A1").address

    @Test("E9: Apple Maps gets the confirmed building address text only")
    func apple() throws {
        let request = try NavigationHandoff.appleMaps(address: address).get()
        #expect(request.query == "123 EXAMPLE ST, VICTORIA, BC V8W 1A1, Canada")
        let s = request.url.absoluteString
        #expect(s.hasPrefix("https://maps.apple.com/?daddr="))
        #expect(!s.contains("204")) // unit stays on the card
        #expect(!s.contains("place")) // no Google identifiers
    }

    @Test("E9: Google Maps app / web URLs")
    func google() throws {
        let app = try NavigationHandoff.googleMaps(address: address, placeID: "abc", appInstalled: true).get()
        #expect(app.url.scheme == "comgooglemaps")
        let web = try NavigationHandoff.googleMaps(address: address, placeID: "abc", appInstalled: false).get()
        #expect(web.url.absoluteString.contains("destination_place_id=abc"))
        #expect(web.url.absoluteString.contains("travelmode=driving"))
    }

    @Test func poBoxCannotNavigate() {
        let po = CanadianAddressParser.parse(lines: ["PO BOX 123", "VICTORIA BC V8W 1A1"]).address
        if case .failure(.noStreetAddress) = NavigationHandoff.appleMaps(address: po) {} else { Issue.record("expected failure") }
    }

    @Test func formatting() {
        #expect(DisplayFormat.distance(meters: 950, unit: .kilometres) == "950 m")
        #expect(DisplayFormat.distance(meters: 12_400, unit: .kilometres) == "12 km")
        #expect(DisplayFormat.distance(meters: 1609.344 * 3.2, unit: .miles) == "3.2 mi")
        #expect(DisplayFormat.duration(seconds: 3600 + 25 * 60) == "1 h 25 min")
        #expect(DisplayFormat.duration(seconds: 40) == "1 min")
    }
}
