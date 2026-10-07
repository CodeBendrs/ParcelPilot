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
    private(set) var currentReadIssues: [String] = []
    var currentRouteID: RouteID? {
        didSet {
            guard oldValue != currentRouteID else { return }
            if !restoringSelection, let protected = backend as? DurableRouteBackend {
                let result = protected.select(currentRouteID)
                if !result.isCommitted { lastCommitResult = result; currentRouteID = oldValue; return }
            }
            attachCurrent()
        }
    }
    private(set) var lastCommitResult: LocalCommitResult = .committed(.init(commandIDs: [], syncPending: false))
    var operationalPersistence: ActiveRoutePersistence? { (backend as? DurableRouteBackend)?.persistence }
    var persistenceIssue: String? {
        if case let .failed(error) = lastCommitResult { return error.localizedDescription }
        return (backend as? DurableRouteBackend)?.recoveryMessage
    }
    private var attemptedAutomaticSelection = false
    private var restoringSelection = false
    private let executionTelemetry: @MainActor (ExecutionPilotEvent) -> Void
    let generalizedWorkAvailability: GeneralizedWorkAvailability
    var canCreateLocationTasks: Bool { generalizedWorkAvailability == .development }
    var taskCreationUnavailableReason: String? {
        canCreateLocationTasks ? nil : "Adding pickups and checklist items is unavailable for this account until compatible-client rollout is approved. Existing work remains available."
    }

    /// Execution is independent of the selected route, legacy route status, and work progress.
    /// Reading the observable protected backend gives both the UI and future arrival services one
    /// persisted intent gate. Authorization and arrival-assistance consent remain separate gates.
    var executionSession: RouteExecutionSession? { (backend as? DurableRouteBackend)?.currentExecutionSession }
    var activeExecutionRouteID: RouteID? {
        guard let session = executionSession, session.state != .finished else { return nil }
        return session.routeID
    }
    func executionSession(for routeID: RouteID) -> RouteExecutionSession? {
        executionSession.flatMap { $0.routeID == routeID ? $0 : nil }
    }
    func returnToExecutionRoute() { if let id = activeExecutionRouteID { currentRouteID = id } }

    @discardableResult private func executionFailure(_ message: String) -> LocalCommitResult {
        let result = LocalCommitResult.failed(.conflict(message)); lastCommitResult = result; return result
    }

    @discardableResult
    func startExecution(_ provided: RouteSnapshot, useCurrentOrder: Bool = false) -> LocalCommitResult {
        executionTelemetry(.init(name: .startRequested))
        guard let protected = backend as? DurableRouteBackend,
              let snapshot = try? protected.persistence?.snapshot(provided.route.id) else {
            return executionFailure("Open this route completely before starting it. Reconnect if it isn't saved on this iPhone yet.")
        }
        if let session = executionSession, session.state != .finished {
            guard session.routeID == snapshot.route.id else {
                return executionFailure("Another route is running or paused. Return to it and Finish explicitly before starting this route.")
            }
            if session.state == .active { return executionNoOp() }
            return executionFailure("This route is paused. Use Resume route to continue the same session.")
        }
        guard snapshot.route.isOpen, !snapshot.stops.isEmpty, currentReadIssues.isEmpty,
              !snapshot.hasUnsupportedRequiredWork, snapshot.orphanPackages.isEmpty else {
            return executionFailure("Review the route and its work before starting. Closed or unreadable routes cannot start.")
        }
        let eligibility = Eligibility.evaluate(snapshot, now: clock(), demoMode: backend.kind == .onDevice)
        guard snapshot.workSummary.pending == 0 || !eligibility.eligible.isEmpty else {
            return executionFailure("Resolve a usable destination before starting this route. Questionable destinations remain in review.")
        }
        guard useCurrentOrder || (snapshot.route.appliedRequestID != nil && snapshot.route.appliedRevision == snapshot.route.inputRevision) else {
            return executionFailure("Accept a current proposal or explicitly choose the current stop order before starting.")
        }
        guard provided.route.inputRevision == snapshot.route.inputRevision,
              provided.orderedStops.map(\.id) == snapshot.orderedStops.map(\.id),
              provided.orderedStops.map(\.sequence) == snapshot.orderedStops.map(\.sequence) else {
            return executionFailure("The route changed while Start was open. Review the current order before starting.")
        }
        let session = RouteExecutionSession(routeID: snapshot.route.id,
            now: max(clock(), (executionSession?.changedAt ?? .distantPast).addingTimeInterval(0.000_01)))
        let result = commitChange(ChangeSet([.transitionExecution(snapshot.route.id, expected: executionSession, session: session)], label: "Start route", critical: true))
        if result.isCommitted { executionTelemetry(.init(name: .startedLocally, state: .active)) }
        return result
    }

    @discardableResult func pauseExecution(_ provided: RouteSnapshot) -> LocalCommitResult {
        transitionExecution(provided, to: .paused, event: .pausedLocally)
    }
    @discardableResult func resumeExecution(_ provided: RouteSnapshot) -> LocalCommitResult {
        transitionExecution(provided, to: .active, event: .resumedLocally)
    }
    private func executionNoOp() -> LocalCommitResult {
        let result = LocalCommitResult.committed(.init(commandIDs: [], syncPending: false)); lastCommitResult = result; return result
    }
    private func transitionExecution(_ provided: RouteSnapshot, to state: RouteExecutionSession.State, event: ExecutionPilotEvent.Name) -> LocalCommitResult {
        guard let session = executionSession(for: provided.route.id), session.state != .finished else {
            return executionFailure("This route has no unfinished execution session. Start it explicitly to begin.")
        }
        guard session.state != state else { return executionNoOp() }
        guard session.transitionCount < Int.max else { return executionFailure("Route execution needs a compatible recovery update before another transition.") }
        guard currentReadIssues.isEmpty else { return executionFailure("Route data couldn't be read safely. Resolve the sync issue before changing execution.") }
        var changed = session; changed.state = state
        changed.changedAt = max(clock(), session.changedAt.addingTimeInterval(0.000_01)); changed.transitionCount += 1
        let result = commitChange(ChangeSet([.transitionExecution(session.routeID, expected: session, session: changed)], label: state == .paused ? "Pause route" : "Resume route", critical: true))
        if result.isCommitted { executionTelemetry(.init(name: event, state: state)) }
        return result
    }

    func finishReview(_ provided: RouteSnapshot) -> ExecutionFinishReview {
        let snapshot = liveSnapshot(for: provided)
        let ledger = snapshot.workLedger
        let remaining = ledger.allTasks.filter { $0.required && !ledger.status(of: $0.id).isHandled }.map {
            ExecutionRemainingWork(taskID: $0.id, stopID: $0.stopID, title: $0.title, kind: $0.kind, state: ledger.status(of: $0.id))
        }
        return ExecutionFinishReview(summary: ledger.summary, canFinish: currentReadIssues.isEmpty && !snapshot.hasUnsupportedRequiredWork && snapshot.orphanPackages.isEmpty,
            remaining: remaining)
    }
    @discardableResult func commitPhotoChange(_ record: DurablePhotoRecord, ops: [ChangeOp], label: String) -> LocalCommitResult {
        guard let protected = backend as? DurableRouteBackend else { return .failed(.storage("Protected photo persistence unavailable.")) }
        let result = protected.commitPhotoChange(record, change: ChangeSet(ops, label: label, critical: true))
        lastCommitResult = result; return result
    }
    @discardableResult func retrySavedCommand(_ id: String) async -> LocalCommitResult {
        guard let protected = backend as? DurableRouteBackend else { return .failed(.conflict("Protected replay is unavailable.")) }
        let result = await protected.retrySavedCommand(id); lastCommitResult = result; return result
    }
    func commandStatus(id: String) -> DurableCommand.State? { (backend as? DurableRouteBackend)?.commandStatus(id: id) }
    @discardableResult private func commitChange(_ change: ChangeSet) -> LocalCommitResult {
        if let failure = generalizedCreationFailure([change]) { lastCommitResult = failure; return failure }
        let result = backend.commit(change); lastCommitResult = result; return result
    }
    @discardableResult private func commitChanges(_ changes: [ChangeSet]) -> LocalCommitResult {
        if let failure = generalizedCreationFailure(changes) { lastCommitResult = failure; return failure }
        if let protected = backend as? DurableRouteBackend {
            let result = protected.commitAtomically(changes); lastCommitResult = result; return result
        }
        var ids: [String] = []; var pending = false
        for change in changes {
            let result = commitChange(change)
            guard case let .committed(ack) = result else { return result }
            ids += ack.commandIDs; pending = pending || ack.syncPending
        }
        let result = LocalCommitResult.committed(.init(commandIDs: ids, syncPending: pending)); lastCommitResult = result; return result
    }

    let backend: RouteBackend
    private let clock: () -> Date
    private var routesToken: ListenerToken?
    private var currentToken: ListenerToken?

    init(backend: RouteBackend, clock: @escaping () -> Date = Date.init, executionTelemetry: @escaping @MainActor (ExecutionPilotEvent) -> Void = PilotTelemetry.record, generalizedWorkAvailability: GeneralizedWorkAvailability? = nil) {
        self.backend = backend
        self.clock = clock
        self.executionTelemetry = executionTelemetry
        self.generalizedWorkAvailability = generalizedWorkAvailability ?? (backend.kind == .onDevice ? .development : .compatibilityReviewRequired)
        restoringSelection = true
        currentRouteID = (backend as? DurableRouteBackend)?.restoredRouteID
        restoringSelection = false
        attemptedAutomaticSelection = currentRouteID != nil || (backend as? DurableRouteBackend)?.issue != nil
        routesToken = backend.observeRoutes { [weak self] routes, pending in
            guard let self else { return }
            self.routes = routes.sorted { $0.updatedAt > $1.updatedAt }
            self.pendingRouteKeys = pending
            self.routesLoaded = true
            if !self.attemptedAutomaticSelection, self.currentRouteID == nil, let active = self.routes.first(where: { $0.isOpen }) {
                self.attemptedAutomaticSelection = true
                self.currentRouteID = active.id
            }
        }
        if currentRouteID != nil && currentToken == nil { attachCurrent() }
        if let session = executionSession, session.state != .finished {
            executionTelemetry(.init(name: .restored, state: session.state))
        }
    }

    var openRoutes: [Route] { routes.filter(\.isOpen) }
    var finishedRoutes: [Route] { routes.filter { !$0.isOpen } }

    private func attachCurrent() {
        currentToken?.remove()
        current = nil
        currentPendingKeys = []
        currentLoaded = false
        currentReadIssues = []
        guard let id = currentRouteID else { return }
        currentToken = backend.observeRoute(id) { [weak self] envelope in
            guard let self, self.currentRouteID == id else { return }
            self.current = envelope?.snapshot
            self.currentPendingKeys = envelope?.pendingKeys ?? []
            self.currentReadIssues = envelope?.readIssues ?? []
            self.currentLoaded = true
        }
    }

    func syncState(forKey key: String) -> DocumentSyncState {
        currentPendingKeys.contains(key) || pendingRouteKeys.contains(key) ? .pending : .synced
    }
    /// Route-list actions need a complete protected generation before a local acknowledgement.
    /// This returns immediately for loaded routes; an uncached route requires a verified online read.
    func loadRouteForMutation(_ id: RouteID) async throws -> Route {
        do {
            guard let snapshot = try await backend.fetchRoute(id) else { throw ServiceError.unavailable("This route isn't available. Reconnect and try again.") }
            return snapshot.route
        } catch {
            let failure = (error as? LocalPersistenceFailure) ?? .conflict("This route couldn't be loaded completely. Reconnect and try again. \(error.localizedDescription)")
            lastCommitResult = .failed(failure); throw failure
        }
    }

    // MARK: Routes

    @discardableResult
    func createRoute(name: String, serviceDate: String, timeZoneID: String, departureMinute: Int, defaultServiceSeconds: Int, start: RoutePlace?, returnToStart: Bool) -> Route {
        var route = Route(name: name, serviceDate: serviceDate, timeZoneID: timeZoneID, departureMinute: departureMinute, now: clock(), defaultServiceSeconds: defaultServiceSeconds)
        route.start = start
        route.returnToStart = returnToStart
        if commitChange(ChangeSet([.createRoute(route)], label: "Create route \(name)")).isCommitted { currentRouteID = route.id }
        return route
    }

    @discardableResult func rename(_ route: Route, to name: String) -> LocalCommitResult {
        var r = route
        r.name = String(name.prefix(80))
        r.updatedAt = clock()
        return commitChange(ChangeSet([.updateRoute(r, bumpRevision: false)], label: "Rename route"))
    }

    /// Route settings that change optimization inputs (start/end, times, break…) bump the revision.
    @discardableResult func updateSettings(_ route: Route) -> LocalCommitResult {
        var r = route
        r.updatedAt = clock()
        r.appliedRequestID = nil
        r.appliedRevision = nil
        return commitChange(ChangeSet([.updateRoute(r, bumpRevision: true)], label: "Update route settings"))
    }

    @discardableResult func archive(_ route: Route) -> LocalCommitResult {
        if activeExecutionRouteID == route.id { return executionFailure("Finish this route's running or paused session before archiving it.") }
        var r = route
        r.status = .archived
        r.archivedAt = clock()
        r.updatedAt = clock()
        if let snap = current, snap.route.id == route.id { r.summary = snap.summary() }
        let result = commitChange(ChangeSet([.updateRoute(r, bumpRevision: false)], label: "Archive route"))
        if result.isCommitted, currentRouteID == route.id { currentRouteID = nil }
        return result
    }

    @discardableResult func resume(_ route: Route) -> LocalCommitResult {
        var r = route
        r.status = r.startedAt == nil ? .planning : .active
        r.archivedAt = nil
        r.completedAt = nil
        r.updatedAt = clock()
        let result = commitChange(ChangeSet([.updateRoute(r, bumpRevision: false)], label: "Resume route"))
        if result.isCommitted { currentRouteID = r.id }
        return result
    }

    /// Copies work definitions with new IDs, but no outcomes or photos, into a planning route.
    func duplicate(_ route: Route) async throws -> Route {
        guard let snapshot = try await backend.fetchRoute(route.id) else { throw ServiceError.invalid("The route could not be loaded.") }
        let now = clock()
        var copy = Route(name: String("\(route.name) copy".prefix(80)), serviceDate: WallClock.ServiceDate.today(in: route.timeZone, now: now).iso, timeZoneID: route.timeZoneID, departureMinute: route.departureMinute, now: now, defaultServiceSeconds: route.defaultServiceSeconds)
        copy.start = route.start
        copy.end = route.end
        copy.returnToStart = route.returnToStart
        copy.latestArrivalMinute = route.latestArrivalMinute
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
        var packageMap: [PackageID: PackageID] = [:]
        for package in snapshot.packages {
            guard let newStop = stopMap[package.stopID] else { continue }
            var p = package
            p.id = StableID.make()
            packageMap[package.id] = p.id
            p.stopID = newStop
            p.createdAt = now
            p.updatedAt = now
            ops.append(.putPackage(copy.id, p))
        }
        var copiedTasks: [LocationTask] = []
        for task in snapshot.tasks {
            guard let newStop = stopMap[task.stopID] else { throw ServiceError.invalid("A work item has no stop. Repair the route before copying it.") }
            var copyTask = task
            copyTask.id = StableID.make(); copyTask.stopID = newStop
            copyTask.packageID = task.packageID.flatMap { packageMap[$0] }
            copyTask.createdAt = now; copyTask.updatedAt = now
            copiedTasks.append(copyTask)
        }
        var changes = ops.chunked(into: 440).map { ChangeSet($0, label: "Duplicate route") }
        for chunk in copiedTasks.chunked(into: 5) {
            changes.append(ChangeSet(chunk.map { .putTask(copy.id, $0) } + [.bumpRouteRevision(copy.id, expectedMinimum: 1)], label: "Copy work items", critical: true))
        }
        let result = commitChanges(changes)
        if case let .failed(error) = result { throw error }
        currentRouteID = copy.id
        return copy
    }

    @discardableResult func finish(_ provided: RouteSnapshot, confirmOutstandingWork: Bool = false) -> LocalCommitResult {
        let snapshot = liveSnapshot(for: provided)
        let review = finishReview(snapshot)
        executionTelemetry(.init(name: .finishRequested, state: executionSession(for: snapshot.route.id)?.state, summary: review.summary))
        guard review.canFinish else { return executionFailure("Route work couldn't be read safely. Review unsupported or unassigned work before finishing.") }
        guard confirmOutstandingWork || !review.requiresOutstandingConfirmation else {
            executionTelemetry(.init(name: .finishBlockedByWork, summary: review.summary))
            return executionFailure("\(review.summary.pending) pending and \(review.summary.deferred) deferred required work item(s) remain. Review them and explicitly confirm Finish; their dispositions will stay unchanged.")
        }
        if !snapshot.route.isOpen {
            if executionSession(for: snapshot.route.id)?.state == .finished { return executionNoOp() }
            return executionFailure("This route is already closed.")
        }
        var r = snapshot.route
        r.status = .completed
        r.completedAt = clock()
        r.updatedAt = clock()
        r.summary = snapshot.summary()
        var ops: [ChangeOp] = [.updateRoute(r, bumpRevision: false)]
        if let session = executionSession(for: r.id), session.state != .finished {
            guard session.transitionCount < Int.max else { return executionFailure("Route execution needs a compatible recovery update before finishing.") }
            var finished = session; finished.state = .finished
            finished.changedAt = max(clock(), session.changedAt.addingTimeInterval(0.000_01)); finished.transitionCount += 1
            ops.append(.transitionExecution(r.id, expected: session, session: finished))
        }
        let result = commitChange(ChangeSet(ops, label: "Finish route", critical: true))
        if result.isCommitted { executionTelemetry(.init(name: .finishedLocally, state: executionSession(for: r.id)?.state, summary: review.summary)) }
        if result.isCommitted, currentRouteID == r.id { currentRouteID = nil }
        return result
    }

    // MARK: Stops & packages

    struct AddResult {
        var stopID: StopID
        var packageIDs: [PackageID]
        var placement: IntakePlacement
        var ops: [ChangeOp]
        var acknowledgement: LocalCommitResult = .committed(.init(commandIDs: [], syncPending: false))
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
        let acknowledgement = commit && !ops.isEmpty ? commitChange(ChangeSet(ops, label: "Add \(address.streetLine ?? "stop")", critical: source == .scan)) : .committed(.init(commandIDs: [], syncPending: false))
        return AddResult(stopID: stopID, packageIDs: packageIDs, placement: placement, ops: ops, acknowledgement: acknowledgement)
    }

    /// Undo for an add: removes the packages, and the stop if it was created by the add.
    @discardableResult func undoAdd(_ result: AddResult, in snapshot: RouteSnapshot) -> LocalCommitResult {
        var ops: [ChangeOp] = result.packageIDs.map { .deletePackage(snapshot.route.id, $0) }
        if result.placement == .newStop { ops.append(.deleteStop(snapshot.route.id, result.stopID)) }
        ops.append(.updateRoute(touched(snapshot.route), bumpRevision: true))
        return commitChange(ChangeSet(ops, label: "Undo add"))
    }

    @discardableResult func commitPrepared(_ ops: [ChangeOp], label: String, critical: Bool = false) -> LocalCommitResult {
        guard !ops.isEmpty else { return .committed(.init(commandIDs: [], syncPending: false)) }
        return commitChanges(ops.chunked(into: 440).map { ChangeSet($0, label: label, critical: critical) })
    }

    /// Saves a stop. `invalidatesPlan` must be true for address, location, window, pin or service changes.
    @discardableResult func update(stop: Stop, in route: Route, invalidatesPlan: Bool) -> LocalCommitResult {
        var s = stop
        s.updatedAt = clock()
        s.destinationKey = DestinationKey.make(s.address) ?? "id:\(s.id)"
        var ops: [ChangeOp] = [.putStop(route.id, s)]
        if invalidatesPlan { ops.append(.updateRoute(touched(route), bumpRevision: true)) }
        return commitChange(ChangeSet(ops, label: "Update \(s.address.streetLine ?? "stop")"))
    }

    @discardableResult func delete(stop: Stop, from snapshot: RouteSnapshot) -> LocalCommitResult {
        var ops: [ChangeOp] = snapshot.packages(for: stop.id).map { .deletePackage(snapshot.route.id, $0.id) }
        ops += snapshot.tasks.filter { $0.stopID == stop.id }.map { .deleteTask(snapshot.route.id, $0.id) }
        ops.append(.deleteStop(snapshot.route.id, stop.id))
        ops.append(.updateRoute(touched(snapshot.route), bumpRevision: true))
        return commitChange(ChangeSet(ops, label: "Remove stop"))
    }

    /// Restore a removal using the current route so Undo never overwrites newer route settings.
    @discardableResult func restore(stop: Stop, packages: [Package], tasks: [LocationTask] = [], in routeID: RouteID) -> LocalCommitResult {
        guard let route = routes.first(where: { $0.id == routeID }) else { return .failed(.conflict("Load the route before restoring work.")) }
        let ops: [ChangeOp] = [.putStop(routeID, stop)]
            + packages.map { .putPackage(routeID, $0) }
            + tasks.map { .putTask(routeID, $0) }
            + [.updateRoute(touched(route), bumpRevision: true)]
        return commitPrepared(ops, label: "Undo remove stop")
    }

    @discardableResult func update(package: Package, in route: Route) -> LocalCommitResult {
        var p = package
        p.updatedAt = clock()
        p.trackingKey = p.trackingID.flatMap { BarcodeClassifier.normalizedTrackingID($0) ?? $0.uppercased().filter { $0.isLetter || $0.isNumber }.nilIfEmptyString }
        return commitChange(ChangeSet([.putPackage(route.id, p)], label: "Update package"))
    }

    @discardableResult func delete(package: Package, in snapshot: RouteSnapshot) -> LocalCommitResult {
        return commitChange(ChangeSet([.deletePackage(snapshot.route.id, package.id), .updateRoute(touched(snapshot.route), bumpRevision: true)], label: "Remove package"))
    }

    @discardableResult func restore(package: Package, in routeID: RouteID) -> LocalCommitResult {
        guard let snapshot = current, snapshot.route.id == routeID,
              snapshot.stops.contains(where: { $0.id == package.stopID }),
              !snapshot.packages.contains(where: { $0.id == package.id }) else { return .failed(.conflict("Package cannot be restored at this stop.")) }
        return commitChange(ChangeSet([.putPackage(routeID, package), .updateRoute(touched(snapshot.route), bumpRevision: true)], label: "Undo remove package"))
    }

    /// Manual reorder. Changes the order only — not an optimization input — so the revision is
    /// unchanged, but the applied plan's times no longer describe the order.
    @discardableResult func reorder(_ orderedIDs: [StopID], in snapshot: RouteSnapshot) -> LocalCommitResult {
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
        return commitPrepared(ops, label: "Reorder stops")
    }

    /// Applies a validated proposal: rewrites only the sequence of stops. Outcomes are never touched.
    @discardableResult func apply(_ proposal: OptimizationProposal, to provided: RouteSnapshot) -> LocalCommitResult {
        let snapshot = liveSnapshot(for: provided)
        guard currentReadIssues.isEmpty, !snapshot.hasUnsupportedRequiredWork, proposal.routeID == snapshot.route.id,
              proposal.inputRevision == snapshot.route.inputRevision else { return .failed(.conflict("This proposal is stale. Calculate a new order.")) }
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
        return commitPrepared(ops, label: "Apply optimized order")
    }

    @discardableResult func setNextStop(_ stopID: StopID?, in route: Route) -> LocalCommitResult {
        var r = touched(route)
        r.nextStopOverrideID = stopID
        return commitChange(ChangeSet([.updateRoute(r, bumpRevision: false)], label: "Choose next stop"))
    }

    // MARK: Unified location work

    /// Compatibility API uses the same validation and rollout gate. Production entry uses saveTask
    /// so a transport adapter's acknowledgement cannot be mistaken for protected local durability.
    func put(task: LocationTask, in provided: RouteSnapshot) throws {
        let snapshot = liveSnapshot(for: provided)
        guard currentReadIssues.isEmpty, !task.id.isEmpty,
              snapshot.stops.contains(where: { $0.id == task.stopID }),
              task.schemaVersion == 1, task.kind == .pickup || task.kind == .checklist,
              !task.id.hasPrefix("delivery_"), task.orderRank >= 0,
              task.title.count <= 120, task.instructions.count <= 2000,
              task.packageID == nil || snapshot.packages.contains(where: { $0.id == task.packageID && $0.stopID == task.stopID }) else {
            throw ServiceError.invalid("This work item isn't a supported pickup/checklist at this stop.")
        }
        if let existing = snapshot.tasks.first(where: { $0.id == task.id }),
           existing.stopID != task.stopID || existing.kind != task.kind || existing.packageID != task.packageID || existing.createdAt != task.createdAt {
            throw ServiceError.invalid("A work item's identity and target cannot change. Add a new item instead.")
        }
        let result = saveTaskDefinition(task, in: provided, protectedOnly: false, requireTitle: false)
        if case let .failed(error) = result { throw error }
    }

    @discardableResult
    func saveTask(_ task: LocationTask, in provided: RouteSnapshot) -> LocalCommitResult {
        saveTaskDefinition(task, in: provided, protectedOnly: true, requireTitle: true)
    }

    private func saveTaskDefinition(_ task: LocationTask, in provided: RouteSnapshot, protectedOnly: Bool, requireTitle: Bool) -> LocalCommitResult {
        let snapshot = liveSnapshot(for: provided)
        if let failure = workMutationFailure(in: snapshot, protectedOnly: protectedOnly) {
            executionTelemetry(.init(name: .taskSaveFailedLocally, workType: .init(task.kind)))
            return failure
        }
        var edited = task
        edited.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.instructions = task.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.id.isEmpty, !task.id.hasPrefix("delivery_"), task.schemaVersion == 1,
              task.kind == .pickup || task.kind == .checklist, task.orderRank >= 0, task.orderRank <= 1_000_000_000,
              snapshot.stops.contains(where: { $0.id == task.stopID }),
              (!requireTitle || !edited.title.isEmpty), edited.title.count <= 120, edited.instructions.count <= 2000,
              task.packageID == nil || snapshot.packages.contains(where: { $0.id == task.packageID && $0.stopID == task.stopID }) else {
            return workFailure("Enter a short pickup or checklist description at an existing stop. Instructions may contain up to 2,000 characters.")
        }
        let existing = snapshot.tasks.first { $0.id == task.id }
        if let existing {
            guard existing.schemaVersion == edited.schemaVersion, existing.stopID == edited.stopID,
                  existing.kind == edited.kind, existing.packageID == edited.packageID, existing.createdAt == edited.createdAt else {
                return workFailure("A work item's identity and target cannot change. Add a new item instead.")
            }
            guard let displayed = provided.tasks.first(where: { $0.id == task.id }), displayed == existing else {
                // Repeating an already-acknowledged create is harmless; a different existing item
                // cannot be silently overwritten by an old editor.
                if provided.tasks.allSatisfy({ $0.id != task.id }), sameTaskDetails(edited, existing) {
                    return noWorkChange()
                }
                return workFailure("This work item changed while you were editing. Reopen it and review the current details.")
            }
            if sameTaskDetails(edited, existing) { return noWorkChange() }
            edited.updatedAt = max(clock(), existing.updatedAt.addingTimeInterval(0.000_01))
        } else {
            guard provided.tasks.allSatisfy({ $0.id != task.id }) else {
                return workFailure("This work item was removed. Reopen the stop before adding new work.")
            }
            guard canCreateLocationTasks else { return workFailure(taskCreationUnavailableReason!) }
            edited.updatedAt = max(clock(), edited.createdAt)
        }
        let result = commitChange(ChangeSet([.putTask(snapshot.route.id, edited), .updateRoute(touched(snapshot.route), bumpRevision: true)], label: existing == nil ? "Add work item" : "Edit work item", critical: true))
        executionTelemetry(.init(name: result.isCommitted ? (existing == nil ? .taskCreatedLocally : .taskEditedLocally) : .taskSaveFailedLocally, summary: snapshot.workSummary, workType: .init(task.kind)))
        return result
    }

    func taskHasOutcomeHistory(_ task: LocationTask, in provided: RouteSnapshot) -> Bool {
        liveSnapshot(for: provided).outcomes.contains { $0.targetTaskID == task.id }
    }

    @discardableResult
    func deleteTask(_ task: LocationTask, in provided: RouteSnapshot) -> LocalCommitResult {
        let snapshot = liveSnapshot(for: provided)
        if let failure = workMutationFailure(in: snapshot, protectedOnly: true) { return failure }
        guard task.kind == .pickup || task.kind == .checklist,
              let existing = snapshot.tasks.first(where: { $0.id == task.id }),
              let displayed = provided.tasks.first(where: { $0.id == task.id }), displayed == existing,
              task == existing else { return workFailure("This work item changed or was removed. Reopen it before deleting.") }
        guard !taskHasOutcomeHistory(existing, in: snapshot) else {
            return workFailure("This item has outcome history and can't be deleted. Keep its history; exclude pending or unsuccessful work if it is no longer required.")
        }
        let result = commitChange(ChangeSet([.deleteTask(snapshot.route.id, task.id), .updateRoute(touched(snapshot.route), bumpRevision: true)], label: "Delete work item", critical: true))
        if result.isCommitted { executionTelemetry(.init(name: .taskDeletedLocally, workType: .init(task.kind))) }
        return result
    }

    /// One typed acknowledgement and the identities committed by the existing recorder. An empty
    /// identity list is a no-op, never a newly successful action or a second completion state.
    @discardableResult
    func recordWorkAction(_ kind: OutcomeKind, taskIDs: [TaskID], reason: FailureReason? = nil, note: String? = nil, in provided: RouteSnapshot, label: String) -> WorkActionResult {
        let snapshot = liveSnapshot(for: provided)
        if let failure = workMutationFailure(in: snapshot, protectedOnly: true) { return .init(acknowledgement: failure, outcomeIDs: []) }
        guard kind != .failed || reason != nil, (note?.count ?? 0) <= 500 else {
            return .init(acknowledgement: workFailure("Choose a failure reason and keep the optional note to 500 characters or fewer."), outcomeIDs: [])
        }
        let ledger = snapshot.workLedger
        for id in Set(taskIDs) {
            guard let task = ledger.allTasks.first(where: { $0.id == id }), ledger.status(of: id) != .unsupported else {
                return .init(acknowledgement: workFailure("This work item can't be read safely. Review the stop before recording an outcome."), outcomeIDs: [])
            }
            if task.kind != .delivery, provided.tasks.first(where: { $0.id == id }) != task {
                return .init(acknowledgement: workFailure("This work item changed. Review its current instructions before recording an outcome."), outcomeIDs: [])
            }
        }
        return recordWork(kind, taskIDs: taskIDs, reason: reason, note: note, photoIDs: [], in: snapshot, label: label)
    }

    /// Existing delivery API delegates to the same recorder/reducer as standalone work.
    @discardableResult
    func record(_ kind: OutcomeKind, packageIDs: [PackageID], stopID: StopID, reason: FailureReason? = nil, note: String? = nil, photoIDs: [PhotoID] = [], in provided: RouteSnapshot, label: String) -> [OutcomeID] {
        let snapshot = liveSnapshot(for: provided)
        let valid = Set(snapshot.packages.filter { $0.stopID == stopID }.map(\.id))
        let ids = packageIDs.filter { valid.contains($0) }.map(LocationTask.deliveryID(for:))
        return recordWork(kind, taskIDs: ids, reason: reason, note: note, photoIDs: photoIDs, in: snapshot, label: label).outcomeIDs
    }

    @discardableResult
    func record(_ kind: OutcomeKind, taskIDs: [TaskID], reason: FailureReason? = nil, note: String? = nil, in snapshot: RouteSnapshot, label: String) -> [OutcomeID] {
        recordWork(kind, taskIDs: taskIDs, reason: reason, note: note, photoIDs: [], in: snapshot, label: label).outcomeIDs
    }

    private func recordWork(_ kind: OutcomeKind, taskIDs: [TaskID], reason: FailureReason?, note: String?, photoIDs: [PhotoID], in provided: RouteSnapshot, label: String) -> WorkActionResult {
        let snapshot = liveSnapshot(for: provided)
        if let failure = workMutationFailure(in: snapshot, protectedOnly: false) { return .init(acknowledgement: failure, outcomeIDs: []) }
        let ledger = snapshot.workLedger
        var selected = Set<TaskID>()
        let work = ledger.allTasks.filter { taskIDs.contains($0.id) && selected.insert($0.id).inserted }
        let now = max(clock(), (snapshot.outcomes.map(\.recordedAt).max() ?? .distantPast).addingTimeInterval(0.000_01))
        let events: [TaskOutcome] = work.compactMap { task in
            guard snapshot.stops.contains(where: { $0.id == task.stopID }),
                  ledger.status(of: task.id) != .unsupported,
                  (kind != .completed || task.kind != .delivery),
                  (kind != .delivered || task.kind == .delivery) else { return nil }
            let state = ledger.status(of: task.id)
            if kind == .requeued {
                switch state { case .failed, .deferred: break; default: return nil }
            } else if kind != .excluded {
                switch state { case .pending, .deferred: break; default: return nil }
            } else if case .completed = state { return nil }
            else if case .excluded = state { return nil }
            if task.kind == .delivery, let packageID = task.packageID {
                return TaskOutcome(packageID: packageID, stopID: task.stopID, kind: kind, reason: reason,
                                   note: note?.trimmedNonEmpty, recordedAt: now, photoIDs: photoIDs)
            }
            return TaskOutcome(taskID: task.id, stopID: task.stopID, kind: kind, reason: reason,
                               note: note?.trimmedNonEmpty, recordedAt: now)
        }
        guard !events.isEmpty else { return .init(acknowledgement: noWorkChange(), outcomeIDs: []) }
        var r = touched(snapshot.route)
        if r.status == .planning { r.status = .active; r.startedAt = r.startedAt ?? now }
        var after = snapshot; after.outcomes += events
        if let next = r.nextStopOverrideID, let stop = snapshot.stops.first(where: { $0.id == next }),
           after.workLedger.stopStatus(stop) == .completed { r.nextStopOverrideID = nil }
        let chunks = events.chunked(into: events.contains { $0.schemaVersion == 2 } ? 5 : 440)
        let changes = chunks.enumerated().map { index, chunk in
            var changedRoute = r
            if index < chunks.count - 1 { changedRoute.nextStopOverrideID = snapshot.route.nextStopOverrideID }
            return ChangeSet(chunk.map { ChangeOp.createOutcome(snapshot.route.id, $0) } + [.updateRoute(changedRoute, bumpRevision: true)], label: label, critical: true)
        }
        let result = commitChanges(changes)
        if result.isCommitted {
            for event in events {
                let task = ledger.allTasks.first { $0.id == event.targetTaskID }
                executionTelemetry(.init(name: .workAction(kind), summary: after.workSummary, workType: task.flatMap { .init($0.kind) }))
            }
        }
        return .init(acknowledgement: result, outcomeIDs: result.isCommitted ? events.map(\.id) : [])
    }

    @discardableResult func undo(outcomeIDs: [OutcomeID], in provided: RouteSnapshot) -> LocalCommitResult {
        // Toast Undo closures retain the pre-write view snapshot. Always reduce current data.
        let snapshot = liveSnapshot(for: provided)
        if let failure = workMutationFailure(in: snapshot, protectedOnly: false) { return failure }
        let active = Set(snapshot.workLedger.activeOutcomes.values.map(\.id))
        let ids = Set(outcomeIDs).intersection(active).sorted()
        guard !ids.isEmpty, currentReadIssues.isEmpty else { return .failed(.conflict("Undo target is no longer active or cannot be read.")) }
        let now = clock()
        let ops = ids.map { ChangeOp.voidOutcome(snapshot.route.id, $0, at: now) }
            + [.updateRoute(touched(snapshot.route), bumpRevision: true)]
        let result = commitChange(ChangeSet(ops, label: "Undo", critical: true))
        if result.isCommitted { executionTelemetry(.init(name: .taskUndoneLocally, summary: snapshot.workSummary)) }
        return result
    }

    func recordWorkPresentation(in snapshot: RouteSnapshot, stopID: StopID) {
        let tasks = snapshot.workLedger.tasks(at: stopID)
        executionTelemetry(.init(name: .stopWorkOpened, summary: snapshot.workSummary, mixed: Set(tasks.map(\.kind)).count > 1))
        if Set(tasks.map(\.kind)).count > 1 { executionTelemetry(.init(name: .mixedWorkPresented, summary: snapshot.workSummary, mixed: true)) }
    }
    func recordPendingWorkReminder(in snapshot: RouteSnapshot, stopID: StopID, bypassed: Bool = false) {
        guard snapshot.workLedger.hasOutstandingRequiredWork(at: stopID) else { return }
        executionTelemetry(.init(name: bypassed ? .pendingWorkReminderBypassed : .pendingWorkReminderShown, summary: snapshot.workSummary))
    }

    private func sameTaskDetails(_ a: LocationTask, _ b: LocationTask) -> Bool {
        var left = a; var right = b; left.updatedAt = .distantPast; right.updatedAt = .distantPast
        return left == right
    }
    private func noWorkChange() -> LocalCommitResult {
        let result = LocalCommitResult.committed(.init(commandIDs: [], syncPending: false)); lastCommitResult = result; return result
    }
    private func workFailure(_ message: String) -> LocalCommitResult {
        let result = LocalCommitResult.failed(.conflict(message)); lastCommitResult = result; return result
    }
    private func workMutationFailure(in snapshot: RouteSnapshot, protectedOnly: Bool) -> LocalCommitResult? {
        guard !protectedOnly || backend is DurableRouteBackend else { return workFailure("Protected local storage is required before recording this action.") }
        guard snapshot.route.isOpen else { return workFailure("This route is finished. Explicitly reopen it before changing work.") }
        guard currentReadIssues.isEmpty else { return workFailure("Route data couldn't be read safely. Retry before changing work.") }
        return nil
    }

    /// Central gate also covers prepared changes and copying. Restoring the identical protected
    /// baseline of a prior deletion is Undo of known work; an arbitrary new definition is not.
    private func generalizedCreationFailure(_ changes: [ChangeSet]) -> LocalCommitResult? {
        guard !canCreateLocationTasks else { return nil }
        for op in changes.flatMap(\.ops) {
            guard case let .putTask(routeID, task) = op else { continue }
            let saved = (backend as? DurableRouteBackend)?.persistence
            let snapshot = (try? saved?.snapshot(routeID)) ?? (current?.route.id == routeID ? current : nil)
            if snapshot?.tasks.contains(where: { $0.id == task.id }) == true { continue }
            let commands = (try? saved?.commands(routeID: routeID)) ?? []
            let isRestoration = commands.contains { command in
                guard command.ops.contains(where: { if case let .deleteTask(_, id) = $0 { id == task.id } else { false } }) else { return false }
                guard let payload = command.baselines?.first(where: { $0.documentKey == "routes/\(routeID)/tasks/\(task.id)" })?.payload,
                      let original = try? ActiveRoutePersistence.decode(LocationTask.self, payload) else { return false }
                return original == task
            }
            if !isRestoration { return .failed(.conflict(taskCreationUnavailableReason!)) }
        }
        return nil
    }

    private func touched(_ route: Route) -> Route {
        var r = route
        r.updatedAt = clock()
        return r
    }

    private func liveSnapshot(for provided: RouteSnapshot) -> RouteSnapshot {
        if let current, current.route.id == provided.route.id { return current }
        if let protected = backend as? DurableRouteBackend, let saved = try? protected.persistence?.snapshot(provided.route.id) { return saved }
        return provided
    }
}

struct WorkActionResult: Equatable, Sendable {
    var acknowledgement: LocalCommitResult
    var outcomeIDs: [OutcomeID]
    var isCommitted: Bool { acknowledgement.isCommitted }
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
