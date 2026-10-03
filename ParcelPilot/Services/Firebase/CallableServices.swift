import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseFunctions
import Foundation
import ParcelPilotKit

/// Maps Cloud Functions errors to messages the driver can act on.
enum CallableErrorMapper {
    static func map(_ error: Error, connectivity: ConnectivityMonitor?) -> ServiceError {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain || connectivity?.isOnline == false { return .offline }
        if ns.domain == AuthErrorDomain || (ns.domain == FunctionsErrorDomain && ns.code == FunctionsErrorCode.unauthenticated.rawValue) {
            // The ID token couldn't be obtained or was refused: let the session find out why.
            NotificationCenter.default.post(name: .ppSessionCheckNeeded, object: nil)
            if FirebaseSession.isInvalidSession(error) || ns.domain == FunctionsErrorDomain { return .signedOut }
        }
        guard ns.domain == FunctionsErrorDomain, let code = FunctionsErrorCode(rawValue: ns.code) else {
            return .unavailable("The service couldn't be reached. Try again.")
        }
        let message = ns.localizedDescription
        switch code {
        case .unauthenticated: return .signedOut
        case .resourceExhausted: return .quotaExceeded(message)
        case .failedPrecondition: return .rejected(message)
        case .invalidArgument: return .invalid(message)
        case .unavailable, .deadlineExceeded: return .unavailable(message)
        case .permissionDenied: return .permission("This build isn't allowed to use the service (App Check). Use an official build, or register this device's App Check debug token.")
        case .notFound: return .invalid(message)
        default: return .unavailable(message)
        }
    }

    static func reason(of error: Error) -> String? {
        ((error as NSError).userInfo[FunctionsErrorDetailsKey] as? [String: Any])?["reason"] as? String
    }
}

// MARK: - Address resolution

nonisolated private struct ResolveAddressRequest: Encodable {
    struct Address: Encodable { var addressLines: [String]; var locality: String?; var province: String?; var postalCode: String? }
    var address: Address?
    var query: String?
    var placeId: String?
    var languageCode: String?
}

nonisolated private struct ResolveAddressResponse: Decodable {
    var provider: String
    var candidates: [GeocodeCandidate]
    var resolvedAt: String
    var coordinatesExpireAt: String
}

nonisolated private struct SuggestAddressesRequest: Encodable {
    struct Near: Encodable { var latitude: Double; var longitude: Double }
    var input: String
    var sessionToken: String
    var languageCode: String?
    var near: Near?
}

nonisolated private struct SuggestAddressesResponse: Decodable {
    struct Suggestion: Decodable { var placeId: String; var primaryText: String; var secondaryText: String? }
    var suggestions: [Suggestion]
}

@MainActor
final class CallableAddressResolver: AddressResolver {
    let provider: ProviderKind
    private let functions: Functions
    private let connectivity: ConnectivityMonitor

    init(functions: Functions = FirebaseBootstrap.functions(), connectivity: ConnectivityMonitor, provider: ProviderKind) {
        self.functions = functions
        self.connectivity = connectivity
        self.provider = provider
    }

    func resolve(_ request: ResolveRequest) async throws -> ResolveResponse {
        guard connectivity.isOnline else { throw ServiceError.offline }
        var body = ResolveAddressRequest()
        switch request {
        case let .address(a):
            let lines = [a.streetLine ?? a.deliveryInstallation].compactMap { $0 }
            guard !lines.isEmpty || a.validPostalCode != nil else { throw ServiceError.invalid("Add a street address or postal code first.") }
            body.address = .init(addressLines: lines.isEmpty ? [a.validPostalCode!.value] : lines, locality: a.municipality, province: a.province?.rawValue, postalCode: a.validPostalCode?.value)
            body.languageCode = a.province == .QC ? "fr" : "en"
        case let .query(q): body.query = q
        case let .placeID(id): body.placeId = id
        }
        var callable = functions.httpsCallable("resolveAddress", requestAs: ResolveAddressRequest.self, responseAs: ResolveAddressResponse.self)
        callable.timeoutInterval = 20
        do {
            let response = try await callable.call(body)
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return ResolveResponse(
                candidates: response.candidates,
                provider: ProviderKind(rawValue: response.provider) ?? provider,
                resolvedAt: iso.date(from: response.resolvedAt) ?? Date(),
                coordinatesExpireAt: iso.date(from: response.coordinatesExpireAt) ?? Date().addingTimeInterval(ProviderContentPolicy.geocodeCoordinateLifetime)
            )
        } catch {
            throw CallableErrorMapper.map(error, connectivity: connectivity)
        }
    }
}

extension CallableAddressResolver {
    func suggest(_ input: String, sessionToken: String, near: ParcelPilotKit.GeoPoint?) async throws -> [AddressSuggestion] {
        guard connectivity.isOnline else { throw ServiceError.offline }
        let body = SuggestAddressesRequest(
            input: input,
            sessionToken: sessionToken,
            languageCode: Locale.current.language.languageCode?.identifier == "fr" ? "fr" : "en",
            near: near.map { .init(latitude: $0.latitude, longitude: $0.longitude) }
        )
        var callable = functions.httpsCallable("suggestAddresses", requestAs: SuggestAddressesRequest.self, responseAs: SuggestAddressesResponse.self)
        callable.timeoutInterval = 8
        do {
            return try await callable.call(body).suggestions.map { AddressSuggestion(placeID: $0.placeId, primaryText: $0.primaryText, secondaryText: $0.secondaryText) }
        } catch {
            throw CallableErrorMapper.map(error, connectivity: connectivity)
        }
    }
}

// MARK: - Optimization

nonisolated struct TimelineDTO: Encodable, Equatable {
    struct Window: Encodable, Equatable { var start: String?; var end: String }
    struct BreakWindow: Encodable, Equatable { var earliest: String; var latest: String }
    var departure: String
    var windows: [String: Window]
    var breakWindow: BreakWindow?
    var tzdataVersion: String?
}

/// The device converts every route-local wall-clock time to UTC with its own time-zone database (the
/// one the driver sees); the server re-checks plausibility. See docs/ARCHITECTURE.md.
enum TimelineBuilder {
    static func build(_ snapshot: RouteSnapshot) -> TimelineDTO? {
        let route = snapshot.route
        guard let date = WallClock.ServiceDate(iso: route.serviceDate) else { return nil }
        func at(_ m: Int) -> String { WallClock.rfc3339(WallClock.instant(serviceDate: date, minute: m, timeZone: route.timeZone).date) }
        var windows: [String: TimelineDTO.Window] = [:]
        for stop in snapshot.stops {
            guard let w = stop.timeWindow, w.isValid else { continue }
            windows[stop.id] = .init(start: w.kind == .hard ? w.startMinute.map(at) : nil, end: at(w.endMinute))
        }
        let breakWindow = route.breakRule.map { TimelineDTO.BreakWindow(earliest: at($0.earliestStartMinute), latest: at($0.latestStartMinute)) }
        return TimelineDTO(departure: at(route.departureMinute), windows: windows, breakWindow: breakWindow, tzdataVersion: TimeZone.timeZoneDataVersion)
    }
}

nonisolated private struct OptimizeRequestDTO: Encodable {
    struct Origin: Encodable { var kind: String; var latitude: Double?; var longitude: Double?; var stopId: String? }
    var requestId: String
    var routeId: String
    var inputRevision: Int
    var origin: Origin
    var fixedNextStopId: String?
    var computeBaseline: Bool
    var considerTraffic: Bool
    var departNow: Bool
    var timeline: TimelineDTO
}

nonisolated private struct OptimizeResponseDTO: Decodable {
    struct ErrorDTO: Decodable { var reason: String; var message: String; var suggestions: [String] }
    var requestId: String
    var status: String
    var reused: Bool
    var error: ErrorDTO?
}

@MainActor
final class CallableRouteOptimizer: RouteOptimizer {
    let provider: ProviderKind
    private let functions: Functions
    private let backend: FirestoreRouteBackend
    private let connectivity: ConnectivityMonitor

    init(functions: Functions = FirebaseBootstrap.functions(), backend: FirestoreRouteBackend, connectivity: ConnectivityMonitor, provider: ProviderKind) {
        self.functions = functions
        self.backend = backend
        self.connectivity = connectivity
        self.provider = provider
    }

    func start(snapshot: RouteSnapshot, options: OptimizationOptions, requestID: String) async throws -> OptimizationJob {
        guard connectivity.isOnline else { throw ServiceError.offline }
        guard let timeline = TimelineBuilder.build(snapshot) else { throw ServiceError.invalid("The route's date or time zone is invalid.") }
        let origin: OptimizeRequestDTO.Origin
        switch options.origin {
        case .routeStart: origin = .init(kind: "routeStart")
        case let .currentLocation(p): origin = .init(kind: "currentLocation", latitude: p.latitude, longitude: p.longitude)
        case let .stop(id): origin = .init(kind: "stop", stopId: id)
        }
        let body = OptimizeRequestDTO(requestId: requestID, routeId: snapshot.route.id, inputRevision: snapshot.route.inputRevision, origin: origin, fixedNextStopId: options.fixedNextStopID, computeBaseline: options.computeBaseline, considerTraffic: options.considerTraffic, departNow: options.departNow, timeline: timeline)
        var callable = functions.httpsCallable("requestOptimization", requestAs: OptimizeRequestDTO.self, responseAs: OptimizeResponseDTO.self)
        callable.timeoutInterval = 150
        let now = Date()
        do {
            let response = try await callable.call(body)
            let status = OptimizationJobStatus(rawValue: response.status) ?? .running
            return OptimizationJob(id: response.requestId, routeID: snapshot.route.id, inputRevision: snapshot.route.inputRevision, status: status, createdAt: now, updatedAt: now, provider: provider, proposal: nil, error: response.error.map { PlanIssue(code: $0.reason, message: $0.message, suggestions: $0.suggestions) })
        } catch {
            let mapped = CallableErrorMapper.map(error, connectivity: connectivity)
            if case .unavailable = mapped, (error as NSError).code == FunctionsErrorCode.deadlineExceeded.rawValue {
                // The call timed out but the job continues on the server; keep observing it.
                return OptimizationJob(id: requestID, routeID: snapshot.route.id, inputRevision: snapshot.route.inputRevision, status: .running, createdAt: now, updatedAt: now, provider: provider, proposal: nil, error: nil)
            }
            throw mapped
        }
    }

    func observe(jobID: String, _ onChange: @escaping (OptimizationJob?) -> Void) -> ListenerToken {
        backend.observeJob(jobID, onChange)
    }
}

/// Decodes the server-written job document (schema in docs/DATA_MODEL.md).
enum JobDecoder {
    static func decode(id: String, data: [String: Any]) -> OptimizationJob? {
        guard let routeID = data["routeId"] as? String, let revision = (data["inputRevision"] as? NSNumber)?.intValue,
              let status = (data["status"] as? String).flatMap(OptimizationJobStatus.init) else { return nil }
        let provider = (data["provider"] as? String).flatMap(ProviderKind.init)
        let error = (data["error"] as? [String: Any]).map { PlanIssue(code: $0["reason"] as? String ?? "error", message: $0["message"] as? String ?? "Optimization failed.", suggestions: $0["suggestions"] as? [String] ?? []) }
        let proposal = (data["proposal"] as? [String: Any]).flatMap { decodeProposal($0) }
        return OptimizationJob(id: id, routeID: routeID, inputRevision: revision, status: status, createdAt: date(data["createdAt"]) ?? Date(), updatedAt: date(data["updatedAt"]) ?? Date(), provider: provider, proposal: proposal, error: error)
    }

    static func date(_ v: Any?) -> Date? { (v as? Timestamp)?.dateValue() ?? (v as? Date) }

    static func metrics(_ v: Any?) -> PlanMetrics? {
        guard let m = v as? [String: Any], let start = date(m["routeStart"]), let end = date(m["routeEnd"]) else { return nil }
        func n(_ k: String) -> Double { (m[k] as? NSNumber)?.doubleValue ?? 0 }
        return PlanMetrics(routeStart: start, routeEnd: end, travelSeconds: Int(n("travelSeconds")), travelMeters: n("travelMeters"), serviceSeconds: Int(n("serviceSeconds")), waitSeconds: Int(n("waitSeconds")), breakSeconds: Int(n("breakSeconds")))
    }

    static func decodeProposal(_ p: [String: Any]) -> OptimizationProposal? {
        guard let requestID = p["requestId"] as? String, let routeID = p["routeId"] as? String,
              let revision = (p["inputRevision"] as? NSNumber)?.intValue,
              let calculatedAt = date(p["calculatedAt"]), let expiresAt = date(p["expiresAt"]) else { return nil }
        let visits: [PlannedVisit] = (p["visits"] as? [[String: Any]] ?? []).compactMap { v in
            guard let stopID = v["stopId"] as? String, let arrival = date(v["arrival"]), let start = date(v["start"]), let departure = date(v["departure"]) else { return nil }
            return PlannedVisit(stopID: stopID, arrival: arrival, start: start, departure: departure, lateBySeconds: (v["lateBySeconds"] as? NSNumber)?.intValue)
        }
        let unassigned: [UnassignedStop] = (p["unassigned"] as? [[String: Any]] ?? []).compactMap { u in
            guard let stopID = u["stopId"] as? String else { return nil }
            return UnassignedStop(stopID: stopID, issue: PlanIssue(code: u["code"] as? String ?? "unassigned", message: u["message"] as? String ?? "Couldn't be scheduled.", suggestions: u["suggestions"] as? [String] ?? []))
        }
        let excluded: [ExcludedStop] = (p["excluded"] as? [[String: Any]] ?? []).compactMap { e in
            guard let stopID = e["stopId"] as? String, let reason = (e["reason"] as? String).flatMap(ExcludedStop.Reason.init) else { return nil }
            return ExcludedStop(stopID: stopID, reason: reason)
        }
        let breaks: [PlannedBreak] = (p["breaks"] as? [[String: Any]] ?? []).compactMap { b in
            guard let start = date(b["start"]) else { return nil }
            return PlannedBreak(start: start, durationSeconds: (b["durationSeconds"] as? NSNumber)?.intValue ?? 0)
        }
        let origin: OptimizationOrigin
        let o = p["origin"] as? [String: Any] ?? [:]
        switch o["kind"] as? String {
        case "currentLocation": origin = .currentLocation(GeoPoint(latitude: (o["latitude"] as? NSNumber)?.doubleValue ?? 0, longitude: (o["longitude"] as? NSNumber)?.doubleValue ?? 0))
        case "stop": origin = .stop(o["stopId"] as? String ?? "")
        default: origin = .routeStart
        }
        let polylines = p["polylines"] as? [String] ?? []
        var proposal = OptimizationProposal(
            requestID: requestID, routeID: routeID, inputRevision: revision,
            provider: (p["provider"] as? String).flatMap(ProviderKind.init) ?? .google,
            status: (p["status"] as? String) == "infeasible" ? .infeasible : .feasible,
            calculatedAt: calculatedAt, expiresAt: expiresAt,
            trafficConsidered: p["trafficConsidered"] as? Bool ?? false,
            origin: origin, fixedNextStopID: p["fixedNextStopId"] as? String,
            visits: visits, unassigned: unassigned, excluded: excluded, breaks: breaks,
            metrics: metrics(p["metrics"]), baseline: metrics(p["baseline"]),
            polylines: polylines,
            completedStopIDsAtRequest: p["completedStopIdsAtRequest"] as? [String] ?? []
        )
        proposal.warnings = (p["warnings"] as? [String] ?? []) + ((p["baselineNote"] as? String).map { [$0] } ?? [])
        return proposal
    }
}
