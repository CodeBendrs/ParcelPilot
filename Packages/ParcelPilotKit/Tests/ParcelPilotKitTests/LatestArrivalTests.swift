import Foundation
import Testing
@testable import ParcelPilotKit

@Suite("Latest warehouse arrival")
struct LatestArrivalTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func snapshot() -> RouteSnapshot {
        var route = makeRoute()
        route.returnToStart = true
        let stop = makeStop(1, lat: 48.45, lng: -123.40)
        return RouteSnapshot(route: route, stops: [stop], packages: [Package(stopID: stop.id, source: .manual)], outcomes: [])
    }

    @Test("Older saved routes decode without an arrival limit; a set limit survives encoding")
    func backwardsCompatible() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        var route = makeRoute()
        let oldData = try encoder.encode(route)
        #expect(!String(decoding: oldData, as: UTF8.self).contains("latestArrivalMinute"))
        #expect(try decoder.decode(Route.self, from: oldData).latestArrivalMinute == nil)
        route.latestArrivalMinute = 1500
        #expect(try decoder.decode(Route.self, from: encoder.encode(route)).latestArrivalMinute == 1500)
    }

    @Test("Return travel is included: a deadline after the delivery but before depot arrival fails")
    func returnTravel() throws {
        var snap = snapshot()
        let optimizer = DemoOptimizer()
        let unrestricted = try optimizer.optimize(snapshot: snap, options: .init(), requestID: "r", now: now)
        let lastDeparture = try #require(unrestricted.visits.last?.departure)
        let finish = try #require(unrestricted.metrics?.routeEnd)
        #expect(finish > lastDeparture.addingTimeInterval(120))
        let start = try #require(WallClock.instant(route: snap.route, minute: 0))
        snap.route.latestArrivalMinute = Int(ceil(lastDeparture.timeIntervalSince(start) / 60))
        #expect(throws: DemoOptimizer.Failure.arrivalDeadlineConflict) {
            try optimizer.optimize(snapshot: snap, options: .init(), requestID: "r", now: now)
        }
        snap.route.latestArrivalMinute = 17 * 60
        let feasible = try optimizer.optimize(snapshot: snap, options: .init(), requestID: "r", now: now)
        #expect(feasible.status == .feasible)
        #expect(feasible.metrics?.routeEnd == finish)
        #expect(ProposalValidator.validate(feasible, against: snap, now: now, demoMode: true) == .valid)
        var late = feasible
        late.metrics?.routeEnd = try #require(WallClock.instant(route: snap.route, minute: 17 * 60 + 1))
        if case .invalid = ProposalValidator.validate(late, against: snap, now: now, demoMode: true) {} else { Issue.record("A late return must not be applied") }
    }

    @Test("Required break and its waiting time count toward the latest arrival")
    func requiredBreak() throws {
        var snap = snapshot()
        snap.route.breakRule = BreakRequirement(earliestStartMinute: 720, latestStartMinute: 780, durationSeconds: 1800)
        snap.route.latestArrivalMinute = 720
        #expect(throws: DemoOptimizer.Failure.arrivalDeadlineConflict) {
            try DemoOptimizer().optimize(snapshot: snap, options: .init(), requestID: "r", now: now)
        }
        snap.route.latestArrivalMinute = 780
        let p = try DemoOptimizer().optimize(snapshot: snap, options: .init(), requestID: "r", now: now)
        #expect(p.breaks.first?.start == WallClock.instant(route: snap.route, minute: 720))
        #expect(p.metrics?.breakSeconds == 1800)
        #expect((p.metrics?.waitSeconds ?? 0) > 0)
    }

    @Test("Overnight deadline works, while depart-now after the deadline and an absent warehouse fail")
    func overnightAndReplanning() throws {
        var snap = snapshot()
        snap.route.departureMinute = 23 * 60
        snap.route.latestArrivalMinute = 1500
        let p = try DemoOptimizer().optimize(snapshot: snap, options: .init(), requestID: "r", now: now)
        #expect(p.status == .feasible)
        let afterDeadline = try #require(WallClock.instant(route: snap.route, minute: 1501))
        #expect(throws: DemoOptimizer.Failure.arrivalDeadlineConflict) {
            try DemoOptimizer().optimize(snapshot: snap, options: .init(departNow: true), requestID: "r", now: afterDeadline)
        }
        snap.route.start = nil
        #expect(throws: DemoOptimizer.Failure.missingEnd) {
            try DemoOptimizer().optimize(snapshot: snap, options: .init(origin: .currentLocation(.init(latitude: 48.4, longitude: -123.3))), requestID: "r", now: now)
        }
    }
}
