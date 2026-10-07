import Foundation

/// **Demo/test baseline only.** Orders stops with straight-line distances at an assumed speed
/// (nearest-neighbour construction + 2-opt). It is used in demo mode and tests, is labelled
/// "Demo estimate (straight-line)" everywhere, and is never the production optimizer.
///
/// It mirrors the production semantics that matter to the driver: mandatory stops, hard windows
/// (wait if early, never late — late stops are reported unassigned with suggestions), soft deadlines,
/// service durations, a required break, first/last pins and a fixed next stop.
public struct DemoOptimizer: Sendable {
    public var averageSpeedMetersPerSecond: Double
    public var detourFactor: Double
    public var maxImprovementPasses: Int
    /// Upper bound on time spent improving a route with time constraints (each candidate needs a
    /// schedule simulation); the constructed order is always valid, so stopping early is safe.
    public var improvementBudget: Duration

    public init(averageSpeedKmh: Double = 30, detourFactor: Double = 1.35, maxImprovementPasses: Int = 4, improvementBudget: Duration = .seconds(1.5)) {
        self.averageSpeedMetersPerSecond = averageSpeedKmh * 1000 / 3600
        self.detourFactor = detourFactor
        self.maxImprovementPasses = maxImprovementPasses
        self.improvementBudget = improvementBudget
    }

    public enum Failure: Error, Equatable, Sendable {
        case missingStart
        case missingEnd
        case arrivalDeadlineConflict
        case noEligibleStops
        case unsupportedWork
        case tooManyStops(limit: Int)

        public var issue: PlanIssue {
            switch self {
            case .missingStart: return PlanIssue(code: "missing-origin", message: "Set a start location (or use your current location) before optimizing.", suggestions: ["Add a start location in route settings.", "Optimize from your current location."])
            case .missingEnd: return PlanIssue(code: "missing-end", message: "Set a verified warehouse location before planning a latest arrival time.", suggestions: ["Set Start to your warehouse and enable Return to start, or choose an End location."])
            case .arrivalDeadlineConflict: return PlanIssue(code: "arrival-deadline-conflict", message: "The estimated route finishes after your latest arrival time, including the drive back and required break.", suggestions: ["Leave earlier.", "Set a later arrival time.", "Move some stops to another route."])
            case .noEligibleStops: return PlanIssue(code: "no-eligible-stops", message: "There are no verified stops left to plan.", suggestions: ["Review stops that need address verification."])
            case .unsupportedWork: return PlanIssue(code: "unsupported-work", message: "Some required work cannot be interpreted safely.", suggestions: ["Review the route with a compatible app before planning."])
            case let .tooManyStops(limit): return PlanIssue(code: "too-many-stops", message: "Routes can optimize up to \(limit) stops at once.", suggestions: ["Split the route into two routes."])
            }
        }
    }

    struct Node {
        let stop: Stop
        let point: GeoPoint
        let service: TimeInterval
        let hardStart: Date?
        let hardEnd: Date?
        let softEnd: Date?
    }

    public func optimize(snapshot: RouteSnapshot, options: OptimizationOptions, requestID: String, now: Date) throws -> OptimizationProposal {
        let route = snapshot.route
        let eligibility = Eligibility.evaluate(snapshot, now: now, demoMode: true)
        guard !snapshot.hasUnsupportedRequiredWork else { throw Failure.unsupportedWork }
        guard !eligibility.eligible.isEmpty else { throw Failure.noEligibleStops }
        guard eligibility.eligible.count <= RouteLimits.maxEligibleStopsPerOptimization else {
            throw Failure.tooManyStops(limit: RouteLimits.maxEligibleStopsPerOptimization)
        }

        let origin: GeoPoint
        switch options.origin {
        case .routeStart:
            guard let p = route.start?.located, p.isUsable(at: now) else { throw Failure.missingStart }
            origin = p.point
        case let .currentLocation(p): origin = p
        case let .stop(id):
            guard let p = snapshot.stops.first(where: { $0.id == id })?.usableLocation(at: now) else { throw Failure.missingStart }
            origin = p.point
        }
        var end: GeoPoint?
        if route.returnToStart, let p = route.start?.located, p.isUsable(at: now) { end = p.point }
        if !route.returnToStart, let p = route.end?.located, p.isUsable(at: now) { end = p.point }
        let latestArrival = route.latestArrivalMinute.flatMap { WallClock.instant(route: route, minute: $0) }
        if route.latestArrivalMinute != nil, end == nil { throw Failure.missingEnd }

        let plannedDeparture = WallClock.instant(route: route, minute: route.departureMinute) ?? now
        let departure = options.departNow ? max(now, plannedDeparture) : plannedDeparture
        if let latestArrival, latestArrival <= departure { throw Failure.arrivalDeadlineConflict }

        let nodes: [Node] = eligibility.eligible.map { stop in
            let w = stop.timeWindow
            func at(_ m: Int?) -> Date? { m.flatMap { WallClock.instant(route: route, minute: $0) } }
            return Node(
                stop: stop,
                point: stop.usableLocation(at: now)!.point,
                service: TimeInterval(stop.serviceSeconds ?? route.defaultServiceSeconds),
                hardStart: w?.kind == .hard ? at(w?.startMinute) : nil,
                hardEnd: w?.kind == .hard ? at(w?.endMinute) : nil,
                softEnd: w?.kind == .softDeadline ? at(w?.endMinute) : nil
            )
        }

        let firstID = options.fixedNextStopID.flatMap { id in nodes.contains { $0.stop.id == id } ? id : nil }
            ?? nodes.first(where: { $0.stop.pin == .first })?.stop.id
        let lastID = nodes.first(where: { $0.stop.pin == .last && $0.stop.id != firstID })?.stop.id
        let breakWindow: (Date, Date, TimeInterval)? = route.breakRule.flatMap { b in
            guard let s = WallClock.instant(route: route, minute: b.earliestStartMinute),
                  let e = WallClock.instant(route: route, minute: b.latestStartMinute) else { return nil }
            return (s, e, TimeInterval(b.durationSeconds))
        }

        var middle = nodes.indices.filter { nodes[$0].stop.id != firstID && nodes[$0].stop.id != lastID }
        let head = nodes.indices.filter { nodes[$0].stop.id == firstID }
        let tail = nodes.indices.filter { nodes[$0].stop.id == lastID }

        // Construction: nearest feasible neighbour by time (travel + wait), preferring urgent windows.
        var order: [Int] = []
        var position = head.first.map { nodes[$0].point } ?? origin
        var clock = departure
        if let h = head.first { clock = simulate(order: [h], nodes: nodes, origin: origin, departure: departure, breakWindow: nil).end }
        while !middle.isEmpty {
            var best: (index: Int, score: Double)?
            for (k, i) in middle.enumerated() {
                let n = nodes[i]
                let arrive = clock.addingTimeInterval(travelSeconds(position, n.point))
                if let hardEnd = n.hardEnd, arrive > hardEnd { continue }
                let startAt = max(arrive, n.hardStart ?? arrive)
                var score = startAt.timeIntervalSince(clock)
                if let hardEnd = n.hardEnd { score -= max(0, 3600 - hardEnd.timeIntervalSince(startAt)) * 0.5 }
                if let soft = n.softEnd, startAt > soft { score += startAt.timeIntervalSince(soft) * 2 }
                if best == nil || score < best!.score { best = (k, score) }
            }
            guard let chosen = best else { order.append(contentsOf: middle); break }
            let i = middle.remove(at: chosen.index)
            let n = nodes[i]
            let arrive = clock.addingTimeInterval(travelSeconds(position, n.point))
            clock = max(arrive, n.hardStart ?? arrive).addingTimeInterval(n.service)
            position = n.point
            order.append(i)
        }

        // Improvement: 2-opt on the middle section, accepting moves that lower total cost.
        if order.count > 3 {
            let matrix = DistanceMatrix(points: nodes.map(\.point) + [origin] + (end.map { [$0] } ?? []), detourFactor: detourFactor, hasEnd: end != nil)
            let timeConstrained = latestArrival != nil || breakWindow != nil || nodes.contains { $0.hardStart != nil || $0.hardEnd != nil || $0.softEnd != nil }
            if timeConstrained {
                order = improveBySimulation(order, head: head, tail: tail, nodes: nodes, matrix: matrix, end: end != nil, departure: departure, breakWindow: breakWindow, latestArrival: latestArrival)
            } else {
                // Without windows or breaks the cost is linear in distance, so a reversal's effect is
                // exact from the four edges it changes.
                let before = head.last ?? matrix.originIndex
                let after = tail.first ?? (end != nil ? matrix.endIndex : nil)
                order = improveByDistance(order, before: before, after: after, matrix: matrix)
            }
        }

        // Final schedule; hard-window violations become unassigned stops (never silently dropped).
        var full = head + order + tail
        var unassigned: [UnassignedStop] = []
        var sim = simulate(order: full, nodes: nodes, origin: origin, departure: departure, breakWindow: breakWindow, end: end)
        while let late = sim.firstHardViolation {
            let node = nodes[full[late]]
            unassigned.append(UnassignedStop(stopID: node.stop.id, issue: lateIssue(node, arrival: sim.visits[late].arrival, timeZone: route.timeZone)))
            full.remove(at: late)
            sim = simulate(order: full, nodes: nodes, origin: origin, departure: departure, breakWindow: breakWindow, end: end)
        }

        let visits = sim.visits
        if let latestArrival, sim.end > latestArrival { throw Failure.arrivalDeadlineConflict }
        return OptimizationProposal(
            requestID: requestID,
            routeID: route.id,
            inputRevision: route.inputRevision,
            provider: .demo,
            status: unassigned.isEmpty ? .feasible : .infeasible,
            calculatedAt: now,
            expiresAt: now.addingTimeInterval(ProviderContentPolicy.proposalLifetime),
            trafficConsidered: false,
            origin: options.origin,
            fixedNextStopID: options.fixedNextStopID,
            visits: visits,
            unassigned: unassigned,
            excluded: eligibility.excluded,
            breaks: sim.breaks,
            metrics: sim.metrics,
            baseline: options.computeBaseline ? baselineMetrics(snapshot: snapshot, nodes: nodes, origin: origin, departure: departure, breakWindow: breakWindow, end: end) : nil,
            polylines: [],
            completedStopIDsAtRequest: eligibility.completedStopIDs
        )
    }

    // MARK: Improvement

    struct DistanceMatrix {
        let count: Int
        let meters: [Double]
        var originIndex: Int { count - (hasEnd ? 2 : 1) }
        var endIndex: Int { count - 1 }
        let hasEnd: Bool

        init(points: [GeoPoint], detourFactor: Double, hasEnd: Bool? = nil) {
            count = points.count
            var m = [Double](repeating: 0, count: points.count * points.count)
            for i in points.indices {
                for j in points.indices where j > i {
                    let d = points[i].haversineMeters(to: points[j]) * detourFactor
                    m[i * points.count + j] = d
                    m[j * points.count + i] = d
                }
            }
            meters = m
            self.hasEnd = hasEnd ?? false
        }

        @inline(__always) func callAsFunction(_ a: Int, _ b: Int) -> Double { meters[a * count + b] }
    }

    func improveByDistance(_ start: [Int], before: Int, after: Int?, matrix: DistanceMatrix) -> [Int] {
        var order = start
        let n = order.count
        for _ in 0..<max(maxImprovementPasses, 8) {
            var improved = false
            for i in 0..<(n - 1) {
                let a = i == 0 ? before : order[i - 1]
                for j in (i + 1)..<n {
                    let b = order[i], c = order[j]
                    let removed = matrix(a, b) + (j + 1 < n ? matrix(c, order[j + 1]) : after.map { matrix(c, $0) } ?? 0)
                    let added = matrix(a, c) + (j + 1 < n ? matrix(b, order[j + 1]) : after.map { matrix(b, $0) } ?? 0)
                    if added + 1e-6 < removed {
                        order[i...j].reverse()
                        improved = true
                    }
                }
            }
            if !improved { break }
        }
        return order
    }

    func improveBySimulation(_ start: [Int], head: [Int], tail: [Int], nodes: [Node], matrix: DistanceMatrix, end: Bool, departure: Date, breakWindow: (Date, Date, TimeInterval)?, latestArrival: Date?) -> [Int] {
        var order = start
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: improvementBudget)
        var full = head + order + tail
        var bestCost = scheduleCost(full, nodes: nodes, matrix: matrix, end: end, departure: departure, breakWindow: breakWindow, latestArrival: latestArrival)
        let offset = head.count
        passes: for _ in 0..<maxImprovementPasses {
            var improved = false
            for i in 0..<(order.count - 1) {
                if clock.now > deadline { break passes }
                for j in (i + 1)..<order.count {
                    full[(offset + i)...(offset + j)].reverse()
                    let c = scheduleCost(full, nodes: nodes, matrix: matrix, end: end, departure: departure, breakWindow: breakWindow, latestArrival: latestArrival)
                    if c + 1e-6 < bestCost {
                        bestCost = c
                        improved = true
                    } else {
                        full[(offset + i)...(offset + j)].reverse()
                    }
                }
            }
            if !improved { break }
        }
        order = Array(full[offset..<(offset + order.count)])
        return order
    }

    /// Allocation-free equivalent of `simulate(...).cost`, used inside the improvement loop.
    func scheduleCost(_ order: [Int], nodes: [Node], matrix: DistanceMatrix, end: Bool, departure: Date, breakWindow: (Date, Date, TimeInterval)?, latestArrival: Date? = nil) -> Double {
        let t0 = departure.timeIntervalSinceReferenceDate
        var clock = t0
        var position = matrix.originIndex
        var meters = 0.0, penalty = 0.0
        var violation = false
        var breakTaken = breakWindow == nil
        let breakEarliest = breakWindow?.0.timeIntervalSinceReferenceDate ?? 0
        let breakLatest = breakWindow?.1.timeIntervalSinceReferenceDate ?? 0
        let breakDuration = breakWindow?.2 ?? 0
        func maybeBreak() {
            guard !breakTaken, clock >= breakEarliest else { return }
            let start = min(max(clock, breakEarliest), max(clock, breakLatest))
            if start > breakLatest { penalty += 1_000_000 }
            clock = start + breakDuration
            breakTaken = true
        }
        for i in order {
            let n = nodes[i]
            maybeBreak()
            let d = matrix(position, i)
            meters += d
            var start = clock + d / averageSpeedMetersPerSecond
            if let hs = n.hardStart?.timeIntervalSinceReferenceDate, start < hs { start = hs }
            if let he = n.hardEnd?.timeIntervalSinceReferenceDate, start > he { violation = true }
            if let se = n.softEnd?.timeIntervalSinceReferenceDate, start > se { penalty += (start - se) * 2 }
            clock = start + n.service
            position = i
        }
        maybeBreak()
        if end {
            let d = matrix(position, matrix.endIndex)
            meters += d
            clock += d / averageSpeedMetersPerSecond
        }
        if !breakTaken, breakWindow != nil {
            let start = max(clock, breakEarliest)
            if start > breakLatest { penalty += 1_000_000 }
            clock = start + breakDuration
        }
        if let latestArrival, clock > latestArrival.timeIntervalSinceReferenceDate { penalty += 10_000_000 + (clock - latestArrival.timeIntervalSinceReferenceDate) * 100 }
        return (clock - t0) + meters * 0.05 + penalty + (violation ? 10_000_000 : 0)
    }

    // MARK: Simulation

    struct Simulation {
        var visits: [PlannedVisit]
        var breaks: [PlannedBreak]
        var metrics: PlanMetrics
        var cost: Double
        var firstHardViolation: Int?
        var end: Date
    }

    func travelSeconds(_ a: GeoPoint, _ b: GeoPoint) -> TimeInterval {
        a.haversineMeters(to: b) * detourFactor / averageSpeedMetersPerSecond
    }

    func simulate(order: [Int], nodes: [Node], origin: GeoPoint, departure: Date, breakWindow: (Date, Date, TimeInterval)?, end: GeoPoint? = nil) -> Simulation {
        var clock = departure
        var position = origin
        var visits: [PlannedVisit] = []
        var breaks: [PlannedBreak] = []
        var travel: TimeInterval = 0, meters: Double = 0, service: TimeInterval = 0, wait: TimeInterval = 0, breakTime: TimeInterval = 0
        var penalty: Double = 0
        var violation: Int?
        var breakTaken = breakWindow == nil

        func maybeBreak() {
            guard !breakTaken, let (earliest, latest, duration) = breakWindow else { return }
            if clock >= earliest {
                let start = min(max(clock, earliest), max(clock, latest))
                if start > latest { penalty += 1_000_000 }
                breaks.append(PlannedBreak(start: start, durationSeconds: Int(duration)))
                clock = start.addingTimeInterval(duration)
                breakTime += duration
                breakTaken = true
            }
        }

        for (k, i) in order.enumerated() {
            let n = nodes[i]
            maybeBreak()
            let d = position.haversineMeters(to: n.point) * detourFactor
            let t = d / averageSpeedMetersPerSecond
            let arrival = clock.addingTimeInterval(t)
            travel += t; meters += d
            var start = arrival
            if let hs = n.hardStart, arrival < hs { wait += hs.timeIntervalSince(arrival); start = hs }
            var late: Int?
            if let he = n.hardEnd, start > he, violation == nil { violation = k }
            if let se = n.softEnd, start > se {
                late = Int(start.timeIntervalSince(se))
                penalty += start.timeIntervalSince(se) * 2
            }
            let departure = start.addingTimeInterval(n.service)
            service += n.service
            visits.append(PlannedVisit(stopID: n.stop.id, arrival: arrival, start: start, departure: departure, lateBySeconds: late))
            clock = departure
            position = n.point
        }
        maybeBreak()
        if let end {
            let d = position.haversineMeters(to: end) * detourFactor
            travel += d / averageSpeedMetersPerSecond
            meters += d
            clock = clock.addingTimeInterval(d / averageSpeedMetersPerSecond)
        }
        if !breakTaken, let (earliest, latest, duration) = breakWindow {
            // Wait for the required break window even when deliveries finish before it opens.
            let start = max(clock, earliest)
            if start > latest { penalty += 1_000_000 }
            wait += max(0, start.timeIntervalSince(clock))
            breaks.append(PlannedBreak(start: start, durationSeconds: Int(duration)))
            breakTime += duration
            clock = start.addingTimeInterval(duration)
        }
        let total = clock.timeIntervalSince(departure)
        let metrics = PlanMetrics(routeStart: departure, routeEnd: clock, travelSeconds: Int(travel), travelMeters: meters, serviceSeconds: Int(service), waitSeconds: Int(wait), breakSeconds: Int(breakTime))
        return Simulation(visits: visits, breaks: breaks, metrics: metrics, cost: total + meters * 0.05 + penalty + (violation != nil ? 10_000_000 : 0), firstHardViolation: violation, end: clock)
    }

    func baselineMetrics(snapshot: RouteSnapshot, nodes: [Node], origin: GeoPoint, departure: Date, breakWindow: (Date, Date, TimeInterval)?, end: GeoPoint?) -> PlanMetrics {
        let ordered = snapshot.orderedStops.map(\.id)
        let indices = ordered.compactMap { id in nodes.firstIndex { $0.stop.id == id } }
        return simulate(order: indices, nodes: nodes, origin: origin, departure: departure, breakWindow: breakWindow, end: end).metrics
    }

    func lateIssue(_ node: Node, arrival: Date, timeZone: TimeZone) -> PlanIssue {
        let f = DateFormatter()
        f.timeZone = timeZone
        f.dateFormat = "h:mm a"
        let window = node.hardEnd.map { f.string(from: $0) } ?? "the window"
        return PlanIssue(
            code: "time-window-conflict",
            message: "Can't arrive before \(window) — the earliest estimated arrival is \(f.string(from: arrival)) given the other stops and constraints.",
            suggestions: [
                "Widen this stop's time window.",
                "Change it to “Prefer to arrive by” (soft deadline).",
                "Leave earlier or pin this stop first.",
                "Remove another conflicting window, or move this stop to another route.",
            ]
        )
    }
}
