import Foundation

public enum PackageStatus: Hashable, Sendable {
    case pending
    case delivered(at: Date)
    case failed(FailureReason?, at: Date)
    case skipped(at: Date)
    case excluded(at: Date)

    /// Delivered, failed and excluded packages are handled. Skipped packages are not — they stay
    /// visible for a deliberate retry or exclusion.
    public var isHandled: Bool {
        switch self {
        case .delivered, .failed, .excluded: return true
        case .pending, .skipped: return false
        }
    }

    public var label: String {
        switch self {
        case .pending: return "To deliver"
        case .delivered: return "Delivered"
        case let .failed(reason, _): return "Failed" + (reason.map { " · \($0.label)" } ?? "")
        case .skipped: return "Skipped"
        case .excluded: return "Excluded"
        }
    }

    public var symbolName: String {
        switch self {
        case .pending: return "shippingbox"
        case .delivered: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .skipped: return "arrow.uturn.forward.circle"
        case .excluded: return "minus.circle"
        }
    }
}

public enum StopStatus: Hashable, Sendable {
    case pending
    /// Some required work handled, some remains.
    case partial
    /// Every required work item handled (completed, failed or excluded).
    case completed
    /// Remaining required work was all deferred.
    case skipped
    /// The stop has no required work.
    case empty

    public var label: String {
        switch self {
        case .pending: return "To do"
        case .partial: return "Partly done"
        case .completed: return "Done"
        case .skipped: return "Skipped"
        case .empty: return "No packages"
        }
    }
}

/// Compatibility view of the canonical WorkLedger. Package labels remain unchanged; stop progress
/// includes all required work. No independent delivery-state reduction lives here.
public struct DeliveryLedger: Sendable {
    public let packageStatus: [PackageID: PackageStatus]
    public let activeOutcomes: [PackageID: DeliveryOutcome]
    public let work: WorkLedger

    public init(packages: [Package], outcomes: [DeliveryOutcome], tasks: [LocationTask] = []) {
        let work = WorkLedger(packages: packages, tasks: tasks, outcomes: outcomes)
        self.work = work
        var status: [PackageID: PackageStatus] = [:]
        var active: [PackageID: DeliveryOutcome] = [:]
        for package in packages {
            let id = LocationTask.deliveryID(for: package.id)
            switch work.status(of: id) {
            case .pending, .unsupported: status[package.id] = .pending
            case .completed(let at): status[package.id] = .delivered(at: at)
            case .failed(let reason, let at): status[package.id] = .failed(reason, at: at)
            case .deferred(let at): status[package.id] = .skipped(at: at)
            case .excluded(let at): status[package.id] = .excluded(at: at)
            }
            active[package.id] = work.activeOutcomes[id]
        }
        packageStatus = status; activeOutcomes = active
    }
    public func status(of packageID: PackageID) -> PackageStatus { packageStatus[packageID] ?? .pending }
    public func stopStatus(_ stop: Stop, packages: [Package]) -> StopStatus { work.stopStatus(stop) }
}

/// Read-only view of everything on a route, used by planning, delivery and the optimizer.
public struct RouteSnapshot: Sendable {
    public var route: Route
    public var stops: [Stop]
    public var packages: [Package]
    public var outcomes: [DeliveryOutcome]
    public var photos: [DeliveryPhoto]
    public var tasks: [LocationTask]

    public init(route: Route, stops: [Stop], packages: [Package], outcomes: [DeliveryOutcome], photos: [DeliveryPhoto] = [], tasks: [LocationTask] = []) {
        self.route = route; self.stops = stops; self.packages = packages; self.outcomes = outcomes; self.photos = photos; self.tasks = tasks
    }

    public var ledger: DeliveryLedger { DeliveryLedger(packages: packages, outcomes: outcomes, tasks: tasks) }
    public var workLedger: WorkLedger { ledger.work }
    public var workSummary: WorkSummary { workLedger.summary }
    public var orphanTasks: [LocationTask] {
        let ids = Set(stops.map(\.id)); return tasks.filter { !ids.contains($0.stopID) }
    }
    public var hasUnsupportedRequiredWork: Bool {
        let ledger = workLedger
        return ledger.allTasks.contains { $0.required && ledger.status(of: $0.id) == .unsupported }
            || orphanTasks.contains(where: \.required)
    }
    public var orderedStops: [Stop] { stops.sorted { ($0.sequence, $0.createdAt, $0.id) < ($1.sequence, $1.createdAt, $1.id) } }
    public func packages(for stopID: StopID) -> [Package] {
        packages.filter { $0.stopID == stopID }.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }
    /// Packages whose stop no longer exists (e.g. a stop deleted on another device).
    public var orphanPackages: [Package] {
        let ids = Set(stops.map(\.id))
        return packages.filter { !ids.contains($0.stopID) }
    }

    public func summary() -> RouteSummary {
        let ledger = self.ledger
        var s = RouteSummary(stopCount: stops.count, packageCount: packages.count, work: ledger.work.summary)
        for p in packages {
            switch ledger.status(of: p.id) {
            case .pending: s.pending += 1
            case .delivered: s.delivered += 1
            case .failed: s.failed += 1
            case .skipped: s.skipped += 1
            case .excluded: s.excluded += 1
            }
        }
        let active = outcomes.filter { $0.voidedAt == nil }
        s.firstOutcomeAt = active.map(\.recordedAt).min()
        s.lastOutcomeAt = active.map(\.recordedAt).max()
        return s
    }

    /// Next stop to work on: the driver's explicit choice if still open, else the first stop in order
    /// with pending required work, else the first stop with only deferred required work.
    public func nextStop() -> Stop? {
        let ledger = self.ledger
        let ordered = orderedStops
        if let overrideID = route.nextStopOverrideID, let s = ordered.first(where: { $0.id == overrideID }) {
            let st = ledger.stopStatus(s, packages: packages)
            if st == .pending || st == .partial || st == .skipped { return s }
        }
        if let s = ordered.first(where: { let st = ledger.stopStatus($0, packages: packages); return st == .pending || st == .partial }) { return s }
        return ordered.first { ledger.stopStatus($0, packages: packages) == .skipped }
    }
}

/// Decides which stops can be sent to the optimizer and explains the rest.
public enum Eligibility {
    public struct Result: Sendable {
        public var eligible: [Stop]
        public var excluded: [ExcludedStop]
        public var completedStopIDs: [StopID]
    }

    public static func evaluate(_ snapshot: RouteSnapshot, now: Date, demoMode: Bool) -> Result {
        let ledger = snapshot.ledger
        var eligible: [Stop] = []
        var excluded: [ExcludedStop] = []
        var completed: [StopID] = []
        for stop in snapshot.orderedStops {
            if ledger.work.hasUnsupportedRequiredWork(at: stop.id) {
                excluded.append(ExcludedStop(stopID: stop.id, reason: .unsupportedTasks)); continue
            }
            let status = ledger.stopStatus(stop, packages: snapshot.packages)
            switch status {
            case .completed:
                completed.append(stop.id)
                excluded.append(ExcludedStop(stopID: stop.id, reason: .completed))
                continue
            case .empty:
                excluded.append(ExcludedStop(stopID: stop.id, reason: .noPendingPackages))
                continue
            case .skipped:
                excluded.append(ExcludedStop(stopID: stop.id, reason: .onlySkippedPackages))
                continue
            case .pending, .partial:
                break
            }
            let statusOK: Bool
            switch stop.addressStatus {
            case .verified, .driverConfirmed: statusOK = true
            case .demoSynthetic: statusOK = demoMode
            case .pendingVerification, .needsReview, .unresolvable: statusOK = false
            }
            guard statusOK else { excluded.append(ExcludedStop(stopID: stop.id, reason: .addressNotVerified)); continue }
            let hasLocation = stop.usableLocation(at: now) != nil || (stop.resolution?.placeID != nil && !demoMode)
            guard hasLocation else { excluded.append(ExcludedStop(stopID: stop.id, reason: .noUsableLocation)); continue }
            eligible.append(stop)
        }
        return Result(eligible: eligible, excluded: excluded, completedStopIDs: completed)
    }
}

/// Checks a proposal against the *current* route before it is shown or applied.
public enum ProposalValidator {
    public enum Verdict: Equatable, Sendable {
        case valid
        /// The route changed since the request (edit, new stop, recorded delivery). Recalculate.
        case stale(String)
        /// The proposal violates an invariant. Never applied.
        case invalid(String)
    }

    public static func validate(_ proposal: OptimizationProposal, against snapshot: RouteSnapshot, now: Date, demoMode: Bool) -> Verdict {
        if proposal.routeID != snapshot.route.id { return .invalid("The plan belongs to a different route.") }
        if proposal.inputRevision != snapshot.route.inputRevision {
            return .stale("The route changed after this plan was requested. Your edits were kept; recalculate to include them.")
        }
        if proposal.isExpired(at: now) { return .stale("This plan has expired. Recalculate for current estimates.") }
        if let minute = snapshot.route.latestArrivalMinute {
            guard let latest = WallClock.instant(route: snapshot.route, minute: minute),
                  let metrics = proposal.metrics else {
                return .invalid("The plan has no arrival estimate to check against your latest arrival time.")
            }
            if metrics.routeEnd > latest { return .invalid("The plan arrives after your latest arrival time. Leave earlier, allow a later return, or move stops to another route.") }
        }

        var seen = Set<StopID>()
        for visit in proposal.visits {
            if !seen.insert(visit.stopID).inserted { return .invalid("A stop appears twice in the plan.") }
        }
        for u in proposal.unassigned where seen.contains(u.stopID) {
            return .invalid("A stop is both scheduled and unassigned.")
        }
        let unassignedIDs = Set(proposal.unassigned.map(\.stopID))

        let current = Eligibility.evaluate(snapshot, now: now, demoMode: demoMode)
        if current.excluded.contains(where: { $0.reason == .unsupportedTasks }) || !snapshot.orphanTasks.filter(\.required).isEmpty {
            return .invalid("Some required work cannot be interpreted safely. Review it before accepting a plan.")
        }
        let ledger = snapshot.ledger
        let stopIDs = Set(snapshot.stops.map(\.id))
        for id in seen where !stopIDs.contains(id) { return .stale("A stop in this plan was removed from the route.") }
        for id in seen {
            if let stop = snapshot.stops.first(where: { $0.id == id }), ledger.stopStatus(stop, packages: snapshot.packages) == .completed {
                return .stale("Deliveries were recorded after this plan was requested. Recalculate the remaining stops.")
            }
        }
        for stop in current.eligible where !seen.contains(stop.id) && !unassignedIDs.contains(stop.id) {
            return .stale("A stop that needs delivering is missing from the plan. Recalculate.")
        }
        // Pins and fixed next stop must hold.
        if let first = proposal.visits.first?.stopID {
            if let fixed = proposal.fixedNextStopID, seen.contains(fixed), first != fixed {
                return .invalid("The plan does not start with your chosen next stop.")
            }
            if proposal.fixedNextStopID == nil,
               let pinned = current.eligible.first(where: { $0.pin == .first }), seen.contains(pinned.id), first != pinned.id {
                return .invalid("The plan does not start with the stop pinned first.")
            }
        }
        if let last = proposal.visits.last?.stopID,
           let pinned = current.eligible.first(where: { $0.pin == .last }), seen.contains(pinned.id), last != pinned.id {
            return .invalid("The plan does not end with the stop pinned last.")
        }
        // Visit times must be non-decreasing.
        for (a, b) in zip(proposal.visits, proposal.visits.dropFirst()) where b.arrival < a.departure.addingTimeInterval(-1) {
            return .invalid("Visit times in the plan overlap.")
        }
        return .valid
    }

    /// New sequence values: completed stops keep their relative order first, then the planned order,
    /// then everything else (unassigned/ineligible) in its existing order. Outcomes are untouched.
    public static func sequencesAfterApplying(_ proposal: OptimizationProposal, to snapshot: RouteSnapshot) -> [StopID: Double] {
        let ledger = snapshot.ledger
        let ordered = snapshot.orderedStops
        let planned = proposal.visits.map(\.stopID)
        let plannedSet = Set(planned)
        let done = ordered.filter { !plannedSet.contains($0.id) && ledger.stopStatus($0, packages: snapshot.packages) == .completed }.map(\.id)
        let rest = ordered.filter { !plannedSet.contains($0.id) && !done.contains($0.id) }.map(\.id)
        var result: [StopID: Double] = [:]
        for (i, id) in (done + planned + rest).enumerated() { result[id] = Double(i + 1) }
        return result
    }

    /// Positions that change, for the preview ("Stop 7 → 2").
    public static func positionChanges(_ proposal: OptimizationProposal, snapshot: RouteSnapshot) -> [(stopID: StopID, from: Int, to: Int)] {
        let before = snapshot.orderedStops.map(\.id)
        let afterSeq = sequencesAfterApplying(proposal, to: snapshot)
        let after = afterSeq.sorted { $0.value < $1.value }.map(\.key)
        var changes: [(StopID, Int, Int)] = []
        for (newIndex, id) in after.enumerated() {
            if let oldIndex = before.firstIndex(of: id), oldIndex != newIndex { changes.append((id, oldIndex + 1, newIndex + 1)) }
        }
        return changes
    }
}
