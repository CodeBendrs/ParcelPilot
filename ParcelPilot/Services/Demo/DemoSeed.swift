import Foundation
import ParcelPilotKit

/// **Demo only.** A sample route with fictional addresses (synthetic locations) so the app can be
/// explored without scanning.
@MainActor
enum DemoSeed {
    static let addresses: [(String, Int, String?)] = [
        // (address, packages, storage location)
        ("ALEX TEST, UNIT 204, 123 EXAMPLE ST, VICTORIA BC V8W 1A1", 2, "Shelf A1"),
        ("SAM TEST, 45 SAMPLE AVE, VICTORIA BC V8V 2B2", 1, "Shelf A2"),
        ("RILEY TEST, 9 MOCK CRES, VICTORIA BC V8R 3C3", 1, "Shelf B1"),
        ("JORDAN TEST, 77 PLACEHOLDER RD, VICTORIA BC V8T 4B4", 3, "Floor"),
        ("CASEY TEST, APT 5, 310 DEMO WAY, VICTORIA BC V8W 2E5", 1, "Shelf B2"),
        ("MORGAN TEST, 18 FICTIONAL LANE, VICTORIA BC V9A 6E6", 1, "Shelf C1"),
        ("TAYLOR TEST, 501 EXAMPLE ST, VICTORIA BC V8W 1A9", 1, "Tote 1"),
        ("QUINN TEST, 66 TRIAL DR, VICTORIA BC V8S 7G7", 2, "Tote 2"),
        ("AVERY TEST, SUITE 300, 1000 SANDBOX BLVD, VICTORIA BC V8W 3H8", 1, "Front"),
        ("DREW TEST, 12 PROTOTYPE PL, VICTORIA BC V8P 4J9", 1, "Back"),
    ]

    static func createSampleRoute(in store: RouteStore, now: Date = Date()) {
        let tz = TimeZone(identifier: "America/Vancouver")!
        var route = Route(name: "Sample route (demo)", serviceDate: WallClock.ServiceDate.today(in: tz, now: now).iso, timeZoneID: tz.identifier, departureMinute: 8 * 60, now: now)
        route.start = RoutePlace(label: "Demo depot", located: LocatedPoint(point: GeoPoint(latitude: 48.4500, longitude: -123.3800), source: .demoSynthetic))
        route.returnToStart = true
        var ops: [ChangeOp] = [.createRoute(route)]
        for (i, entry) in addresses.enumerated() {
            let parsed = CanadianAddressParser.parse(singleLine: entry.0)
            let candidates = DemoAddressResolver.candidates(for: parsed.address)
            let assessment = MatchAssessor.assess(address: parsed.address, candidates: candidates)
            var stop = Stop(address: parsed.address, addressStatus: .demoSynthetic, sequence: Double(i + 1), now: now)
            stop.resolution = StopResolution(provider: .demo, placeID: nil, located: candidates.first.map { LocatedPoint(point: $0.location, source: .demoSynthetic) }, match: assessment.quality, resolvedAt: now)
            if i == 2 { stop.timeWindow = TimeWindowConstraint(kind: .hard, startMinute: 9 * 60, endMinute: 11 * 60) }
            if i == 5 { stop.timeWindow = TimeWindowConstraint(kind: .softDeadline, startMinute: nil, endMinute: 10 * 60 + 30) }
            if i == 0 { stop.notes = "Buzzer 204. Leave with concierge if no answer." }
            ops.append(.putStop(route.id, stop))
            for k in 0..<entry.1 {
                let p = Package(stopID: stop.id, trackingID: String(format: "DEMO%08d%02d", i + 1, k), recipientName: parsed.address.recipientName, size: k == 0 ? .medium : .small, storageLocation: entry.2, source: .manual, now: now)
                ops.append(.putPackage(route.id, p))
            }
        }
        // One address that needs review: civic number missing (postal code only).
        let incomplete = CanadianAddressParser.parse(singleLine: "PAT TEST, EXAMPLE ST, VICTORIA BC V8W 1B2")
        var review = Stop(address: incomplete.address, addressStatus: .needsReview, reviewReasons: [.missingCivicNumber, .postalAreaOnly], sequence: Double(addresses.count + 1), now: now)
        review.resolution = StopResolution(provider: .demo, placeID: nil, located: nil, match: .postalArea, resolvedAt: now)
        ops.append(.putStop(route.id, review))
        ops.append(.putPackage(route.id, Package(stopID: review.id, trackingID: "DEMO0000009900", recipientName: "PAT TEST", source: .manual, now: now)))
        store.commitPrepared(ops, label: "Sample route")
        store.currentRouteID = route.id
    }
}
