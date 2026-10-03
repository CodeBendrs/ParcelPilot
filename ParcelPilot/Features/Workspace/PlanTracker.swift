import Foundation
import Observation
import ParcelPilotKit

/// Tracks the optimization job whose order is applied to the route, so planned arrival times can be
/// shown while they are still valid. Times are hidden (and explained) when the route changed, the
/// order was edited by hand, or the provider content expired.
@MainActor
@Observable
final class PlanTracker {
    enum PlanState {
        case none
        case current(OptimizationProposal)
        case outdated(String)
    }

    private(set) var appliedJob: OptimizationJob?
    private var token: ListenerToken?
    private var trackedID: String?
    private let optimizer: RouteOptimizer

    init(optimizer: RouteOptimizer) { self.optimizer = optimizer }

    func track(_ route: Route) {
        guard route.appliedRequestID != trackedID else { return }
        trackedID = route.appliedRequestID
        token?.remove()
        appliedJob = nil
        guard let id = route.appliedRequestID else { return }
        token = optimizer.observe(jobID: id) { [weak self] job in self?.appliedJob = job }
    }

    func state(for snapshot: RouteSnapshot, now: Date = Date()) -> PlanState {
        guard let requestID = snapshot.route.appliedRequestID else { return .none }
        guard let proposal = appliedJob?.proposal, proposal.requestID == requestID else {
            return .outdated("Planned times aren't available on this device any more. Recalculate to see arrival estimates.")
        }
        if proposal.isExpired(at: now) { return .outdated("Planned times expired (estimates are kept for 24 hours). Recalculate for fresh estimates.") }
        if snapshot.route.appliedRevision != snapshot.route.inputRevision { return .outdated("Stops or constraints changed since the route was optimized. Recalculate to update times.") }
        return .current(proposal)
    }
}
