import Foundation

/// Where the remaining route starts from.
public enum OptimizationOrigin: Codable, Hashable, Sendable {
    /// The route's configured start place.
    case routeStart
    /// Device location captured in the foreground now (driver data, not persisted beyond the job).
    case currentLocation(GeoPoint)
    /// The location of a specific stop (e.g. "I'm at stop 12").
    case stop(StopID)

    public var label: String {
        switch self {
        case .routeStart: return "Route start"
        case .currentLocation: return "Your current location"
        case .stop: return "Selected stop"
        }
    }
}

public struct OptimizationOptions: Codable, Hashable, Sendable {
    public var origin: OptimizationOrigin
    /// The driver's explicitly fixed next stop (kept first among remaining work).
    public var fixedNextStopID: StopID?
    /// Also evaluate the current order so savings can be shown (costs an extra billed request).
    public var computeBaseline: Bool
    public var considerTraffic: Bool
    /// When re-optimizing during delivery, departure is "now" instead of the planned departure.
    public var departNow: Bool

    public init(origin: OptimizationOrigin = .routeStart, fixedNextStopID: StopID? = nil, computeBaseline: Bool = false, considerTraffic: Bool = true, departNow: Bool = false) {
        self.origin = origin; self.fixedNextStopID = fixedNextStopID; self.computeBaseline = computeBaseline
        self.considerTraffic = considerTraffic; self.departNow = departNow
    }
}

public struct PlannedVisit: Codable, Hashable, Sendable {
    public var stopID: StopID
    public var arrival: Date
    /// Service start (later than arrival when waiting for a window to open).
    public var start: Date
    public var departure: Date
    /// Seconds after the soft deadline, if one was missed.
    public var lateBySeconds: Int?

    public init(stopID: StopID, arrival: Date, start: Date, departure: Date, lateBySeconds: Int? = nil) {
        self.stopID = stopID; self.arrival = arrival; self.start = start; self.departure = departure; self.lateBySeconds = lateBySeconds
    }

    public var waitSeconds: Int { max(0, Int(start.timeIntervalSince(arrival))) }
}

public struct PlannedBreak: Codable, Hashable, Sendable {
    public var start: Date
    public var durationSeconds: Int
    public init(start: Date, durationSeconds: Int) { self.start = start; self.durationSeconds = durationSeconds }
}

public struct PlanMetrics: Codable, Hashable, Sendable {
    public var routeStart: Date
    public var routeEnd: Date
    public var travelSeconds: Int
    public var travelMeters: Double
    public var serviceSeconds: Int
    public var waitSeconds: Int
    public var breakSeconds: Int

    public init(routeStart: Date, routeEnd: Date, travelSeconds: Int, travelMeters: Double, serviceSeconds: Int, waitSeconds: Int, breakSeconds: Int) {
        self.routeStart = routeStart; self.routeEnd = routeEnd; self.travelSeconds = travelSeconds
        self.travelMeters = travelMeters; self.serviceSeconds = serviceSeconds; self.waitSeconds = waitSeconds; self.breakSeconds = breakSeconds
    }

    public var totalSeconds: Int { Int(routeEnd.timeIntervalSince(routeStart)) }
}

/// Machine code + explanation + suggested driver actions. Used for unassigned stops and job errors.
public struct PlanIssue: Codable, Hashable, Sendable {
    public var code: String
    public var message: String
    public var suggestions: [String]

    public init(code: String, message: String, suggestions: [String] = []) {
        self.code = code; self.message = message; self.suggestions = suggestions
    }
}

public struct UnassignedStop: Codable, Hashable, Sendable {
    public var stopID: StopID
    public var issue: PlanIssue
    public init(stopID: StopID, issue: PlanIssue) { self.stopID = stopID; self.issue = issue }
}

/// Stop that was not sent to the optimizer, with the reason.
public struct ExcludedStop: Codable, Hashable, Sendable {
    public enum Reason: String, Codable, Hashable, Sendable {
        case completed, addressNotVerified, noUsableLocation, noPendingPackages, onlySkippedPackages, unsupportedTasks
    }
    public var stopID: StopID
    public var reason: Reason
    public init(stopID: StopID, reason: Reason) { self.stopID = stopID; self.reason = reason }

    public var explanation: String {
        switch reason {
        case .unsupportedTasks: return "Required work needs a compatible app or correction before planning."
        case .completed: return "Already handled."
        case .addressNotVerified: return "Address not verified — review it to include this stop."
        case .noUsableLocation: return "No usable location. Refresh the address or place a pin."
        case .noPendingPackages: return "No packages left to deliver."
        case .onlySkippedPackages: return "Skipped — retry or exclude its packages to include it."
        }
    }
}

public enum ProposalStatus: String, Codable, Hashable, Sendable {
    /// Every eligible stop is scheduled.
    case feasible
    /// Some eligible stops could not be scheduled without breaking a hard constraint.
    case infeasible
}

/// Result of an optimization. Provider content (times, distances, polyline) expires.
public struct OptimizationProposal: Codable, Hashable, Sendable {
    public var requestID: String
    public var routeID: RouteID
    public var inputRevision: Int
    public var provider: ProviderKind
    public var status: ProposalStatus
    public var calculatedAt: Date
    public var expiresAt: Date
    /// True only when the request asked the provider to consider traffic for the departure time.
    public var trafficConsidered: Bool
    public var origin: OptimizationOrigin
    public var fixedNextStopID: StopID?
    /// Ordered visits for eligible remaining stops.
    public var visits: [PlannedVisit]
    public var unassigned: [UnassignedStop]
    public var excluded: [ExcludedStop]
    public var breaks: [PlannedBreak]
    public var metrics: PlanMetrics?
    /// Metrics for the current order evaluated under identical conditions, when requested.
    public var baseline: PlanMetrics?
    /// Encoded polylines, one per solved segment (Google only, display on a Google map only).
    public var polylines: [String]
    /// Plain-language notes from the optimizer (e.g. a preferred time already passed).
    public var warnings: [String] = []
    /// Stop IDs that had already been completed when the request was made.
    public var completedStopIDsAtRequest: [StopID]

    public init(requestID: String, routeID: RouteID, inputRevision: Int, provider: ProviderKind, status: ProposalStatus, calculatedAt: Date, expiresAt: Date, trafficConsidered: Bool, origin: OptimizationOrigin, fixedNextStopID: StopID?, visits: [PlannedVisit], unassigned: [UnassignedStop], excluded: [ExcludedStop], breaks: [PlannedBreak], metrics: PlanMetrics?, baseline: PlanMetrics?, polylines: [String], completedStopIDsAtRequest: [StopID]) {
        self.requestID = requestID; self.routeID = routeID; self.inputRevision = inputRevision; self.provider = provider
        self.status = status; self.calculatedAt = calculatedAt; self.expiresAt = expiresAt; self.trafficConsidered = trafficConsidered
        self.origin = origin; self.fixedNextStopID = fixedNextStopID; self.visits = visits; self.unassigned = unassigned
        self.excluded = excluded; self.breaks = breaks; self.metrics = metrics; self.baseline = baseline
        self.polylines = polylines; self.completedStopIDsAtRequest = completedStopIDsAtRequest
    }

    public func isExpired(at now: Date) -> Bool { expiresAt <= now }

    /// Savings are only claimed when a baseline was computed by the same provider in the same request.
    public var savings: (seconds: Int, meters: Double)? {
        guard let baseline, let metrics else { return nil }
        return (baseline.totalSeconds - metrics.totalSeconds, baseline.travelMeters - metrics.travelMeters)
    }

    public var trafficLabel: String {
        switch provider {
        case .google: return trafficConsidered ? "Traffic-aware estimate for the departure time (not live traffic)" : "Typical travel times (traffic not considered)"
        case .demo: return "Straight-line estimate at an assumed average speed — not road travel times"
        case .emulatorFake: return "Emulator test provider — not real travel times"
        }
    }
}

public enum OptimizationJobStatus: String, Codable, Hashable, Sendable {
    case queued, running, succeeded, infeasible, failed, stale, cancelled

    public var isTerminal: Bool { ![.queued, .running].contains(self) }
}

/// Server-owned job document (`users/{uid}/optimizationRequests/{requestID}`).
public struct OptimizationJob: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var routeID: RouteID
    public var inputRevision: Int
    public var status: OptimizationJobStatus
    public var createdAt: Date
    public var updatedAt: Date
    public var provider: ProviderKind?
    public var proposal: OptimizationProposal?
    public var error: PlanIssue?

    public init(id: String, routeID: RouteID, inputRevision: Int, status: OptimizationJobStatus, createdAt: Date, updatedAt: Date, provider: ProviderKind?, proposal: OptimizationProposal?, error: PlanIssue?) {
        self.id = id; self.routeID = routeID; self.inputRevision = inputRevision; self.status = status
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.provider = provider; self.proposal = proposal; self.error = error
    }
}

/// Product limits. Mirrored by server params; the server is authoritative.
public enum RouteLimits {
    public static let maxEligibleStopsPerOptimization = 200
    public static let maxStopsPerRoute = 300
    public static let maxPackagesPerRoute = 600
}
