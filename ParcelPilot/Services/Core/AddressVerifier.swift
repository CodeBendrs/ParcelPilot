import Foundation
import Observation
import ParcelPilotKit

/// Online address verification: resolver → match assessment → review policy. Also re-verifies stops
/// that were saved offline ("Needs address verification") once the device is back online.
@MainActor
@Observable
final class AddressVerifier {
    struct Result: Sendable {
        var response: ResolveResponse?
        var assessment: MatchAssessment?
        var resolution: ResolutionState
        var error: ServiceError?
    }

    private let resolver: AddressResolver
    private let connectivity: ConnectivityMonitor
    let demoMode: Bool
    private(set) var verifyingStopIDs = Set<StopID>()

    init(resolver: AddressResolver, connectivity: ConnectivityMonitor, demoMode: Bool) {
        self.resolver = resolver
        self.connectivity = connectivity
        self.demoMode = demoMode
    }

    /// Synthetic results may be accepted (labelled) only in demo / emulator builds.
    var allowsSynthetic: Bool { demoMode || resolver.provider == .emulatorFake }

    func verify(_ address: PostalAddress) async -> Result {
        guard connectivity.isOnline else { return Result(response: nil, assessment: nil, resolution: .offline, error: .offline) }
        guard address.validPostalCode != nil || (address.civicNumber != nil && address.streetName != nil && address.municipality != nil) else {
            return Result(response: nil, assessment: MatchAssessment(quality: .notFound, differences: [], candidate: nil), resolution: .resolved(MatchAssessment(quality: .notFound, differences: [], candidate: nil)), error: nil)
        }
        do {
            let response = try await resolver.resolve(.address(address))
            let assessment = MatchAssessor.assess(address: address, candidates: response.candidates)
            return Result(response: response, assessment: assessment, resolution: .resolved(assessment), error: nil)
        } catch let error as ServiceError {
            return Result(response: nil, assessment: nil, resolution: error.isOffline ? .offline : .unavailable(error.localizedDescription), error: error)
        } catch {
            return Result(response: nil, assessment: nil, resolution: .unavailable(error.localizedDescription), error: .unavailable(error.localizedDescription))
        }
    }

    /// Resolution data to store on a stop for a given assessment. Postal-area / city centroids are
    /// never stored as a stop location.
    func stopResolution(for assessment: MatchAssessment, response: ResolveResponse?) -> StopResolution {
        let candidate = assessment.candidate
        var located: LocatedPoint?
        if let c = candidate, ConfirmationPolicy.mayUseResolvedLocation(assessment.quality) {
            let source: PointSource = c.provider == .google ? .providerGeocode : c.provider == .demo ? .demoSynthetic : .emulatorFake
            located = LocatedPoint(point: c.location, source: source, expiresAt: source == .providerGeocode ? response?.coordinatesExpireAt ?? Date().addingTimeInterval(ProviderContentPolicy.geocodeCoordinateLifetime) : nil)
        }
        return StopResolution(provider: candidate?.provider ?? response?.provider, placeID: candidate?.placeID, located: located, match: assessment.quality, resolvedAt: response?.resolvedAt ?? Date())
    }

    /// Re-verifies stops saved without verification. Stops that verify cleanly become `verified`;
    /// others move to `needsReview` with reasons — they are never added to an optimized route silently.
    func verifyPendingStops(in snapshot: RouteSnapshot, store: RouteStore) async {
        guard connectivity.isOnline else { return }
        let pending = snapshot.stops.filter { $0.addressStatus == .pendingVerification && !verifyingStopIDs.contains($0.id) }
        for stop in pending {
            verifyingStopIDs.insert(stop.id)
            defer { verifyingStopIDs.remove(stop.id) }
            let result = await verify(stop.address)
            guard case let .resolved(assessment) = result.resolution else { continue }
            let decision = ReviewPolicy.evaluate(parsed: ParsedAddress(validating: stop.address), recognition: nil, resolution: .resolved(assessment), allowSyntheticAcceptance: allowsSynthetic)
            var updated = stop
            updated.resolution = stopResolution(for: assessment, response: result.response)
            updated.addressStatus = decision.autoAcceptable ? decision.statusIfAdded : (assessment.quality == .notFound ? .unresolvable : .needsReview)
            updated.reviewReasons = decision.reasons
            store.update(stop: updated, in: snapshot.route, invalidatesPlan: true)
        }
    }

    /// Refreshes expired provider coordinates using the stored place ID (Google only).
    func refreshExpiredCoordinates(in snapshot: RouteSnapshot, store: RouteStore, now: Date = Date()) async {
        guard connectivity.isOnline, resolver.provider == .google else { return }
        for stop in snapshot.stops where stop.resolution?.located == nil || stop.resolution?.located?.isUsable(at: now) == false {
            guard let placeID = stop.resolution?.placeID, stop.addressStatus == .verified || stop.addressStatus == .driverConfirmed else { continue }
            guard let response = try? await resolver.resolve(.placeID(placeID)), let c = response.candidates.first else { continue }
            var updated = stop
            updated.resolution?.located = LocatedPoint(point: c.location, source: .providerGeocode, expiresAt: response.coordinatesExpireAt)
            store.update(stop: updated, in: snapshot.route, invalidatesPlan: false)
        }
    }
}
