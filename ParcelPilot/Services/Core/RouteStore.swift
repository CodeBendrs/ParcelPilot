import Foundation
import Observation
import ParcelPilotKit

/// The single observable source of route data for the UI. Reads come from the backend's live
/// listeners (Firestore cache or the on-device store); every edit is a `ChangeSet` committed to the
/// backend, which updates the local copy immediately and syncs later.
@MainActor
@Observable
final class RouteStore {
    private(set) var routes: [Route] = []
    private(set) var routesLoaded = false
    private(set) var pendingRouteKeys: Set<String> = []
    private(set) var current: RouteSnapshot?
    private(set) var currentPendingKeys: Set<String> = []
    private(set) var currentLoaded = false
    var currentRouteID: RouteID? {
        didSet { if oldValue != currentRouteID { attachCurrent() } }
    }

    let backend: RouteBackend
    private let clock: () -> Date
    private var routesToken: ListenerToken?
    private var currentToken: ListenerToken?

    init(backend: RouteBackend, clock: @escaping () -> Date = Date.init) {
        self.backend = backend
        self.clock = clock
        routesToken = backend.observeRoutes { [weak self] routes, pending in
            guard let self else { return }
            self.routes = routes.sorted { $0.updatedAt > $1.updatedAt }
            self.pendingRouteKeys = pending
            self.routesLoaded = true
            if self.currentRouteID == nil, let active = self.routes.first(where: { $0.isOpen }) {
                self.currentRouteID = active.id
            }
        }
    }

    var openRoutes: [Route] { routes.filter(\.isOpen) }
    var finishedRoutes: [Route] { routes.filter { !$0.isOpen } }

    private func attachCurrent() {
        currentToken?.remove()
        current = nil
        currentPendingKeys = []
        currentLoaded = false
        guard let id = currentRouteID else { return }
        currentToken = backend.observeRoute(id) { [weak self] envelope in
            guard let self, self.currentRouteID == id else { return }
            self.current = envelope?.snapshot
            self.currentPendingKeys = envelope?.pendingKeys ?? []
            self.currentLoaded = true
        }
    }

    func syncState(forKey key: String) -> DocumentSyncState {
        currentPendingKeys.contains(key) || pendingRouteKeys.contains(key) ? .pending : .synced
    }

    // MARK: Routes

    @discardableResult
    func createRoute(name: String, serviceDate: String, timeZoneID: String, departureMinute: Int, defaultServiceSeconds: Int, start: RoutePlace?, returnToStart: Bool) -> Route {
        var route = Route(name: name, serviceDate: serviceDate, timeZoneID: timeZoneID, departureMinute: departureMinute, now: clock(), defaultServiceSeconds: defaultServiceSeconds)
        route.start = start
        route.returnToStart = returnToStart
        backend.commit(ChangeSet([.createRoute(route)], label: "Create route \(name)"))
        currentRouteID = route.id
        return route
    }

    func rename(_ route: Route, to name: String) {
        var r = route
        r.name = String(name.prefix(80))
        r.updatedAt = clock()
        backend.commit(ChangeSet([.updateRoute(r, bumpRevision: false)], label: "Rename route"))
    }

    /// Route settings that change optimization inputs (start/end, times, break…) bump the revision.
    func updateSettings(_ route: Route) {
        var r = route
        r.updatedAt = clock()
        r.appliedRequestID = nil
        r.appliedRevision = nil
        backend.commit(ChangeSet([.updateRoute(r, bumpRevision: true)], label: "Update route settings"))
    }

    func archive(_ route: Route) {
        var r = route
        r.status = .archived
        r.archivedAt = clock()
        r.updatedAt = clock()
        if let snap = current, snap.route.id == route.id { r.summary = snap.summary() }
        backend.commit(ChangeSet([.updateRoute(r, bumpRevision: false)], label: "Archive route"))
        if currentRouteID == route.id { currentRouteID = nil }
    }

    func resume(_ route: Route) {
        var r = route
        r.status = r.startedAt == nil ? .planning : .active
        r.archivedAt = nil
        r.completedAt = nil
        r.updatedAt = clock()
        backend.commit(ChangeSet([.updateRoute(r, bumpRevision: false)], label: "Resume route"))
        currentRouteID = r.id
    }

    /// Copies stops and packages (new IDs, no outcomes, no photos) into a new planning route.
    func duplicate(_ route: Route) async throws -> Route {
        guard let snapshot = try await backend.fetchRoute(route.id) else { throw ServiceError.invalid("The route could not be loaded.") }
        let now = clock()
        var copy = Route(name: String("\(route.name) copy".prefix(80)), serviceDate: WallClock.ServiceDate.today(in: route.timeZone, now: now).iso, timeZoneID: route.timeZoneID, departureMinute: route.departureMinute, now: now, defaultServiceSeconds: route.defaultServiceSeconds)
        copy.start = route.start
        copy.end = route.end
        copy.returnToStart = route.returnToStart
        copy.breakRule = route.breakRule
        copy.objective = route.objective
        copy.considerTraffic = route.considerTraffic
        var ops: [ChangeOp] = [.createRoute(copy)]
        var stopMap: [StopID: StopID] = [:]
        for stop in snapshot.orderedStops {
            var s = stop
            s.id = StableID.make()
            s.createdAt = now
            s.updatedAt = now
            stopMap[stop.id] = s.id
            ops.append(.putStop(copy.id, s))
        }
        for package in snapshot.packages {
            guard let newStop = stopMap[package.stopID] else { continue }
            var p = package
            p.id = StableID.make()
            p.stopID = newStop
            p.createdAt = now
            p.updatedAt = now
            ops.append(.putPackage(copy.id, p))
        }
        for chunk in ops.chunked(into: 450) {
            backend.commit(ChangeSet(chunk, label: "Duplicate route"))
        }
        currentRouteID = copy.id
        return copy
    }

    func finish(_ snapshot: RouteSnapshot) {
        var r = snapshot.route
        r.status = .completed
        r.completedAt = clock()
        r.updatedAt = clock()
        r.summary = snapshot.summary()
        backend.commit(ChangeSet([.updateRoute(r, bumpRevision: false)], label: "Finish route"))
        if currentRouteID == r.id { currentRouteID = nil }
    }

    // MARK: Stops & packages

    struct AddResult {
        var stopID: StopID
        var packageIDs: [PackageID]
        var placement: IntakePlacement
        var ops: [ChangeOp]
    }

    /// Adds packages for an address: to the existing stop with the identical destination, or to a new
    /// stop. Tracking IDs already on the route are not added again (the caller shows a warning).
    @discardableResult
    func addDelivery(
        to snapshot: RouteSnapshot,
        address: PostalAddress,
        status: AddressStatus,
        resolution: StopResolution?,
        reviewReasons: [ReviewReason],
        packages: [PackageDraft],
        source: PackageSource,
        notes: String = "",
        commit: Bool = true
    ) -> AddResult {
        let index = RouteIntakeIndex(stops: snapshot.stops, packages: snapshot.packages)
        let now = clock()
        let routeID = snapshot.route.id
        var ops: [ChangeOp] = []
        let firstTracking = packages.first?.trackingID
        let placement = index.placement(for: address, trackingID: firstTracking)
        var stopID: StopID
        var invalidates = false
        switch placement {
        case let .duplicateTracking(_, existingStop):
            return AddResult(stopID: existingStop, packageIDs: [], placement: placement, ops: [])
        case let .existingStop(id):
            stopID = id
        case .newStop:
            let nextSequence = (snapshot.stops.map(\.sequence).max() ?? 0) + 1
            var stop = Stop(address: address, addressStatus: status, resolution: resolution, reviewReasons: reviewReasons, sequence: nextSequence, now: now)
            stop.notes = notes
            stopID = stop.id
            ops.append(.putStop(routeID, stop))
            invalidates = true
        }
        var packageIDs: [PackageID] = []
        var seenKeys = Set(snapshot.packages.compactMap(\.trackingKey))
        for draft in packages {
            let p = Package(stopID: stopID, trackingID: draft.trackingID?.trimmedNonEmpty, recipientName: draft.recipientName?.trimmedNonEmpty ?? address.recipientName, size: draft.size, storageLocation: draft.storageLocation?.trimmedNonEmpty, notes: draft.notes, source: source, now: now)
            if let key = p.trackingKey, !seenKeys.insert(key).inserted { continue }
            packageIDs.append(p.id)
            ops.append(.putPackage(routeID, p))
        }
        if invalidates || placement != .newStop {
            // The stop set (or package count at a stop) changed → plan inputs changed.
            ops.append(.updateRoute(touched(snapshot.route), bumpRevision: true))
        }
        if commit, !ops.isEmpty {
            backend.commit(ChangeSet(ops, label: "Add \(address.streetLine ?? "stop")", critical: source == .scan))
        }
        return AddResult(stopID: stopID, packageIDs: packageIDs, placement: placement, ops: ops)
    }

    /// Undo for an add: removes the packages, and the stop if it was created by the add.
    func undoAdd(_ result: AddResult, in snapshot: RouteSnapshot) {
        var ops: [ChangeOp] = result.packageIDs.map { .deletePackage(snapshot.route.id, $0) }
        if result.placement == .newStop { ops.append(.deleteStop(snapshot.route.id, result.stopID)) }
        ops.append(.updateRoute(touched(snapshot.route), bumpRevision: true))
        backend.commit(ChangeSet(ops, label: "Undo add"))
    }

    func commitPrepared(_ ops: [ChangeOp], label: String, critical: Bool = false) {
        guard !ops.isEmpty else { return }
        for chunk in ops.chunked(into: 450) { backend.commit(ChangeSet(chunk, label: label, critical: critical)) }
    }

    /// Saves a stop. `invalidatesPlan` must be true for address, location, window, pin or service changes.
    func update(stop: Stop, in route: Route, invalidatesPlan: Bool) {
        var s = stop
        s.updatedAt = clock()
        s.destinationKey = DestinationKey.make(s.address) ?? "id:\(s.id)"
        var ops: [ChangeOp] = [.putStop(route.id, s)]
        if invalidatesPlan { ops.append(.updateRoute(touched(route), bumpRevision: true)) }
        backend.commit(ChangeSet(ops, label: "Update \(s.address.streetLine ?? "stop")"))
    }

    func delete(stop: Stop, from snapshot: RouteSnapshot) {
        var ops: [ChangeOp] = snapshot.packages(for: stop.id).map { .deletePackage(snapshot.route.id, $0.id) }
        ops.append(.deleteStop(snapshot.route.id, stop.id))
        ops.append(.updateRoute(touched(snapshot.route), bumpRevision: true))
        backend.commit(ChangeSet(ops, label: "Remove stop"))
    }

    /// Restore a removal using the current route so Undo never overwrites newer route settings.
    func restore(stop: Stop, packages: [Package], in routeID: RouteID) {
        guard let route = routes.first(where: { $0.id == routeID }) else { return }
        let ops: [ChangeOp] = [.putStop(routeID, stop)]
            + packages.map { .putPackage(routeID, $0) }
            + [.updateRoute(touched(route), bumpRevision: true)]
        commitPrepared(ops, label: "Undo remove stop")
    }

    func update(package: Package, in route: Route) {
        var p = package
        p.updatedAt = clock()
        p.trackingKey = p.trackingID.flatMap { BarcodeClassifier.normalizedTrackingID($0) ?? $0.uppercased().filter { $0.isLetter || $0.isNumber }.nilIfEmptyString }
        backend.commit(ChangeSet([.putPackage(route.id, p)], label: "Update package"))
    }

    func delete(package: Package, in snapshot: RouteSnapshot) {
        backend.commit(ChangeSet([.deletePackage(snapshot.route.id, package.id), .updateRoute(touched(snapshot.route), bumpRevision: true)], label: "Remove package"))
    }

    /// Manual reorder. Changes the order only — not an optimization input — so the revision is
    /// unchanged, but the applied plan's times no longer describe the order.
    func reorder(_ orderedIDs: [StopID], in snapshot: RouteSnapshot) {
        var ops: [ChangeOp] = []
        for (i, id) in orderedIDs.enumerated() {
            guard var stop = snapshot.stops.first(where: { $0.id == id }), stop.sequence != Double(i + 1) else { continue }
            stop.sequence = Double(i + 1)
            stop.updatedAt = clock()
            ops.append(.putStop(snapshot.route.id, stop))
        }
        var r = touched(snapshot.route)
        r.appliedRequestID = nil
        r.appliedRevision = nil
        ops.append(.updateRoute(r, bumpRevision: false))
        commitPrepared(ops, label: "Reorder stops")
    }

    /// Applies a validated proposal: rewrites only the sequence of stops. Outcomes are never touched.
    func apply(_ proposal: OptimizationProposal, to snapshot: RouteSnapshot) {
        let sequences = ProposalValidator.sequencesAfterApplying(proposal, to: snapshot)
        var ops: [ChangeOp] = []
        for stop in snapshot.stops {
            guard let seq = sequences[stop.id], seq != stop.sequence else { continue }
            var s = stop
            s.sequence = seq
            s.updatedAt = clock()
            ops.append(.putStop(snapshot.route.id, s))
        }
        var r = touched(snapshot.route)
        r.appliedRequestID = proposal.requestID
        r.appliedRevision = proposal.inputRevision
        r.nextStopOverrideID = nil
        if let metrics = proposal.metrics {
            r.plannedDistance = PlannedDistance(meters: metrics.travelMeters, provider: proposal.provider, calculatedAt: proposal.calculatedAt, expiresAt: proposal.expiresAt)
        }
        ops.append(.updateRoute(r, bumpRevision: false))
        commitPrepared(ops, label: "Apply optimized order")
    }

    func setNextStop(_ stopID: StopID?, in route: Route) {
        var r = touched(route)
        r.nextStopOverrideID = stopID
        backend.commit(ChangeSet([.updateRoute(r, bumpRevision: false)], label: "Choose next stop"))
    }

    // MARK: Delivery outcomes

    /// Records outcomes for packages (one append-only document each). Returns the IDs for Undo.
    @discardableResult
    func record(_ kind: OutcomeKind, packageIDs: [PackageID], stopID: StopID, reason: FailureReason? = nil, note: String? = nil, photoIDs: [PhotoID] = [], in snapshot: RouteSnapshot, label: String) -> [OutcomeID] {
        let now = clock()
        var ops: [ChangeOp] = []
        var ids: [OutcomeID] = []
        for packageID in packageIDs {
            let outcome = DeliveryOutcome(packageID: packageID, stopID: stopID, kind: kind, reason: reason, note: note?.trimmedNonEmpty, recordedAt: now, photoIDs: photoIDs)
            ids.append(outcome.id)
            ops.append(.createOutcome(snapshot.route.id, outcome))
        }
        if snapshot.route.status == .planning {
            var r = touched(snapshot.route)
            r.status = .active
            r.startedAt = r.startedAt ?? now
            ops.append(.updateRoute(r, bumpRevision: false))
        } else if snapshot.route.nextStopOverrideID == stopID {
            var r = touched(snapshot.route)
            r.nextStopOverrideID = nil
            ops.append(.updateRoute(r, bumpRevision: false))
        }
        backend.commit(ChangeSet(ops, label: label, critical: true))
        return ids
    }

    func undo(outcomeIDs: [OutcomeID], in snapshot: RouteSnapshot) {
        let now = clock()
        backend.commit(ChangeSet(outcomeIDs.map { .voidOutcome(snapshot.route.id, $0, at: now) }, label: "Undo", critical: true))
    }

    private func touched(_ route: Route) -> Route {
        var r = route
        r.updatedAt = clock()
        return r
    }
}

/// Package fields captured at intake.
struct PackageDraft: Hashable, Sendable, Codable {
    var trackingID: String?
    var recipientName: String?
    var size: PackageSize?
    var storageLocation: String?
    var notes: String = ""
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    var nilIfEmptyString: String? { isEmpty ? nil : self }
}

extension Optional where Wrapped == String {
    var trimmedNonEmpty: String? { self?.trimmedNonEmpty }
}
