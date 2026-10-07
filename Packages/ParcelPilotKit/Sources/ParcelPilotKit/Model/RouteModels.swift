import Foundation

// MARK: - Route

public enum RouteStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case planning, active, completed, archived

    public var label: String {
        switch self {
        case .planning: return "Planning"
        case .active: return "In progress"
        case .completed: return "Completed"
        case .archived: return "Archived"
        }
    }
}

/// A route start or end. The label is the driver-confirmed text; the point may be provider content
/// (with an expiry) or driver data (device location / pin).
public struct RoutePlace: Codable, Hashable, Sendable {
    public var label: String
    public var address: PostalAddress?
    public var located: LocatedPoint?
    public var placeID: String?

    public init(label: String, address: PostalAddress? = nil, located: LocatedPoint? = nil, placeID: String? = nil) {
        self.label = label; self.address = address; self.located = located; self.placeID = placeID
    }
}

/// A required driver break. Times are wall-clock minutes on the route's service date.
public struct BreakRequirement: Codable, Hashable, Sendable {
    public var earliestStartMinute: Int
    public var latestStartMinute: Int
    public var durationSeconds: Int

    public init(earliestStartMinute: Int, latestStartMinute: Int, durationSeconds: Int) {
        self.earliestStartMinute = earliestStartMinute
        self.latestStartMinute = latestStartMinute
        self.durationSeconds = durationSeconds
    }
}

public enum OptimizationObjective: String, Codable, Hashable, Sendable, CaseIterable {
    /// Minimise total time with a small distance cost.
    case balanced
    /// Minimise total time only (distance cost kept small but non-zero).
    case fastest

    public var label: String {
        switch self {
        case .balanced: return "Balance time and distance"
        case .fastest: return "Shortest total time"
        }
    }
}

public struct RouteSummary: Codable, Hashable, Sendable {
    public var delivered: Int
    public var failed: Int
    public var skipped: Int
    public var excluded: Int
    public var pending: Int
    public var stopCount: Int
    public var packageCount: Int
    public var firstOutcomeAt: Date?
    public var lastOutcomeAt: Date?
    /// Required generalized work counts. Absent on legacy saved summaries; package counters above
    /// retain their original meaning and are never used as pickup/checklist completion records.
    public var work: WorkSummary?

    public init(delivered: Int = 0, failed: Int = 0, skipped: Int = 0, excluded: Int = 0, pending: Int = 0, stopCount: Int = 0, packageCount: Int = 0, firstOutcomeAt: Date? = nil, lastOutcomeAt: Date? = nil, work: WorkSummary? = nil) {
        self.delivered = delivered; self.failed = failed; self.skipped = skipped; self.excluded = excluded
        self.pending = pending; self.stopCount = stopCount; self.packageCount = packageCount
        self.firstOutcomeAt = firstOutcomeAt; self.lastOutcomeAt = lastOutcomeAt
        self.work = work
    }
}

/// Planned road distance retained with its source and expiry (provider content).
public struct PlannedDistance: Codable, Hashable, Sendable {
    public var meters: Double
    public var provider: ProviderKind
    public var calculatedAt: Date
    public var expiresAt: Date

    public init(meters: Double, provider: ProviderKind, calculatedAt: Date, expiresAt: Date) {
        self.meters = meters; self.provider = provider; self.calculatedAt = calculatedAt; self.expiresAt = expiresAt
    }
}

public struct Route: Codable, Hashable, Sendable, Identifiable {
    public var id: RouteID
    public var schemaVersion: Int
    public var name: String
    public var status: RouteStatus
    public var createdAt: Date
    public var updatedAt: Date

    /// Service date in the route's time zone, "YYYY-MM-DD".
    public var serviceDate: String
    /// IANA time zone used for every wall-clock time on this route.
    public var timeZoneID: String
    /// Departure, wall-clock minutes from local midnight of the service date.
    public var departureMinute: Int
    /// Hard latest arrival at the route end, including the return drive. Nil means no limit.
    /// Wall-clock minutes from the service date's midnight (>= 1440 means next day).
    public var latestArrivalMinute: Int?

    public var start: RoutePlace?
    public var end: RoutePlace?
    public var returnToStart: Bool
    public var defaultServiceSeconds: Int
    public var breakRule: BreakRequirement?
    public var objective: OptimizationObjective
    public var considerTraffic: Bool

    /// Incremented whenever an optimization input changes. Server-checked before results are stored.
    public var inputRevision: Int
    /// The optimization request whose order is currently applied, if any.
    public var appliedRequestID: String?
    /// The input revision the applied order was computed for.
    public var appliedRevision: Int?
    /// Driver's explicit choice for the next stop while delivering.
    public var nextStopOverrideID: StopID?

    public var startedAt: Date?
    public var completedAt: Date?
    public var archivedAt: Date?
    public var summary: RouteSummary?
    public var plannedDistance: PlannedDistance?

    public static let currentSchemaVersion = 1

    public init(
        id: RouteID = StableID.make(),
        name: String,
        serviceDate: String,
        timeZoneID: String,
        departureMinute: Int = 8 * 60,
        now: Date = Date(),
        defaultServiceSeconds: Int = 120
    ) {
        self.id = id
        self.schemaVersion = Self.currentSchemaVersion
        self.name = name
        self.status = .planning
        self.createdAt = now
        self.updatedAt = now
        self.serviceDate = serviceDate
        self.timeZoneID = timeZoneID
        self.departureMinute = departureMinute
        self.latestArrivalMinute = nil
        self.start = nil
        self.end = nil
        self.returnToStart = false
        self.defaultServiceSeconds = defaultServiceSeconds
        self.breakRule = nil
        self.objective = .balanced
        self.considerTraffic = true
        self.inputRevision = 1
        self.appliedRequestID = nil
        self.appliedRevision = nil
        self.nextStopOverrideID = nil
        self.startedAt = nil
        self.completedAt = nil
        self.archivedAt = nil
        self.summary = nil
        self.plannedDistance = nil
    }

    public var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? TimeZone(identifier: "America/Toronto")! }
    public var isOpen: Bool { status == .planning || status == .active }
}

// MARK: - Stop

/// Verification state of a stop's destination. Only `verified`, `driverConfirmed` and
/// `demoSynthetic` (demo mode only) can be optimized, and only with a usable location.
public enum AddressStatus: String, Codable, Hashable, Sendable {
    /// Matched at building level by the production geocoder with no conflicts.
    case verified
    /// The driver confirmed the location (e.g. placed a pin or accepted a partial match deliberately).
    case driverConfirmed
    /// Saved without online resolution (offline or provider unavailable) — "Needs address verification".
    case pendingVerification
    /// Resolution ran but needs the driver's review (partial match, postal centroid, conflicts…).
    case needsReview
    /// Resolution found nothing usable.
    case unresolvable
    /// Synthetic demo location — never a real verification.
    case demoSynthetic

    public var label: String {
        switch self {
        case .verified: return "Address verified"
        case .driverConfirmed: return "Location confirmed by you"
        case .pendingVerification: return "Needs address verification"
        case .needsReview: return "Needs review"
        case .unresolvable: return "Address not found"
        case .demoSynthetic: return "Demo location (not verified)"
        }
    }
}

public enum StopPin: String, Codable, Hashable, Sendable, CaseIterable {
    case none, first, last

    public var label: String {
        switch self {
        case .none: return "Optimizer decides"
        case .first: return "Must be first"
        case .last: return "Must be last"
        }
    }
}

/// A delivery-time constraint with precise semantics.
public struct TimeWindowConstraint: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        /// Arrival must be between start and end. The optimizer may wait if early; it will report the
        /// stop as unschedulable rather than arrive late.
        case hard
        /// Arrive by `endMinute` if possible. Later arrival is allowed but penalised per hour late.
        case softDeadline
    }

    public var kind: Kind
    /// Wall-clock minutes from local midnight of the service date (≥ 1440 = next day). Required for
    /// hard windows; ignored for soft deadlines.
    public var startMinute: Int?
    public var endMinute: Int

    public init(kind: Kind, startMinute: Int?, endMinute: Int) {
        self.kind = kind; self.startMinute = startMinute; self.endMinute = endMinute
    }

    public var explanation: String {
        switch kind {
        case .hard:
            return "Must arrive between \(WallClock.label(startMinute ?? 0)) and \(WallClock.label(endMinute)). The plan waits if early and reports a conflict instead of arriving late."
        case .softDeadline:
            return "Prefer to arrive by \(WallClock.label(endMinute)). Arriving later is allowed but discouraged."
        }
    }

    public var isValid: Bool {
        guard endMinute >= 0, endMinute < 2 * 1440 else { return false }
        if kind == .hard {
            guard let s = startMinute, s >= 0, s < endMinute else { return false }
        }
        return true
    }
}

/// Resolution data attached to a stop. Provider coordinates expire; the place ID may be kept.
public struct StopResolution: Codable, Hashable, Sendable {
    public var provider: ProviderKind?
    public var placeID: String?
    public var located: LocatedPoint?
    public var match: MatchQuality
    public var resolvedAt: Date

    public init(provider: ProviderKind?, placeID: String?, located: LocatedPoint?, match: MatchQuality, resolvedAt: Date) {
        self.provider = provider; self.placeID = placeID; self.located = located; self.match = match; self.resolvedAt = resolvedAt
    }
}

public struct Stop: Codable, Hashable, Sendable, Identifiable {
    public var id: StopID
    public var schemaVersion: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var address: PostalAddress
    /// Normalized destination identity (see `DestinationKey`). Same key → same stop.
    public var destinationKey: String
    public var addressStatus: AddressStatus
    public var resolution: StopResolution?
    /// Review reasons recorded at confirmation time (codes, for display).
    public var reviewReasons: [ReviewReason]
    /// Manual / applied order. Lower comes first.
    public var sequence: Double
    public var pin: StopPin
    public var timeWindow: TimeWindowConstraint?
    /// Overrides the route default when set.
    public var serviceSeconds: Int?
    public var notes: String

    public init(
        id: StopID = StableID.make(),
        address: PostalAddress,
        addressStatus: AddressStatus,
        resolution: StopResolution? = nil,
        reviewReasons: [ReviewReason] = [],
        sequence: Double,
        now: Date = Date()
    ) {
        self.id = id
        self.schemaVersion = 1
        self.createdAt = now
        self.updatedAt = now
        self.address = address
        self.destinationKey = DestinationKey.make(address) ?? "id:\(id)"
        self.addressStatus = addressStatus
        self.resolution = resolution
        self.reviewReasons = reviewReasons
        self.sequence = sequence
        self.pin = .none
        self.timeWindow = nil
        self.serviceSeconds = nil
        self.notes = ""
    }

    /// Location usable for planning right now (expired provider coordinates are not usable).
    public func usableLocation(at now: Date) -> LocatedPoint? {
        guard let located = resolution?.located, located.isUsable(at: now) else { return nil }
        return located
    }
}

// MARK: - Package

public enum PackageSize: String, Codable, Hashable, Sendable, CaseIterable {
    case envelope, small, medium, large, oversize

    public var label: String {
        switch self {
        case .envelope: return "Envelope"
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .oversize: return "Oversize"
        }
    }
}

public enum PackageSource: String, Codable, Hashable, Sendable {
    case scan, manual, paste, csv, duplicate
}

public struct Package: Codable, Hashable, Sendable, Identifiable {
    public var id: PackageID
    public var schemaVersion: Int
    public var stopID: StopID
    public var createdAt: Date
    public var updatedAt: Date
    /// As printed/scanned (display).
    public var trackingID: String?
    /// Uppercase alphanumerics only (lookup and duplicate detection).
    public var trackingKey: String?
    public var recipientName: String?
    public var size: PackageSize?
    /// Where the package is in the vehicle, e.g. "Shelf B3", "Tote 4", "Front seat".
    public var storageLocation: String?
    public var notes: String
    public var source: PackageSource

    public init(
        id: PackageID = StableID.make(),
        stopID: StopID,
        trackingID: String? = nil,
        recipientName: String? = nil,
        size: PackageSize? = nil,
        storageLocation: String? = nil,
        notes: String = "",
        source: PackageSource,
        now: Date = Date()
    ) {
        self.id = id
        self.schemaVersion = 1
        self.stopID = stopID
        self.createdAt = now
        self.updatedAt = now
        self.trackingID = trackingID
        self.trackingKey = trackingID.flatMap { BarcodeClassifier.normalizedTrackingID($0) ?? Package.looseKey($0) }
        self.recipientName = recipientName
        self.size = size
        self.storageLocation = storageLocation
        self.notes = notes
        self.source = source
    }

    static func looseKey(_ s: String) -> String? {
        let k = s.uppercased().filter { $0.isASCIIDigit || $0.isASCIILetter }
        return k.isEmpty ? nil : k
    }
}

// MARK: - Delivery outcomes

public enum OutcomeKind: String, Codable, Hashable, Sendable {
    case delivered
    /// Explicit pickup/checklist success. Deliveries keep the legacy `delivered` wire value.
    case completed
    case failed
    case skipped
    /// Driver chose to retry a failed/skipped package: it returns to remaining work.
    case requeued
    /// Driver chose to stop trying (e.g. returning to depot). Counts as handled.
    case excluded
}

public enum FailureReason: String, Codable, Hashable, Sendable, CaseIterable {
    case noOneHome, accessIssue, addressNotFound, refused, damaged, businessClosed, unsafe, needsSignature, other

    public var label: String {
        switch self {
        case .noOneHome: return "No one home"
        case .accessIssue: return "Couldn't get access"
        case .addressNotFound: return "Address not found"
        case .refused: return "Refused by recipient"
        case .damaged: return "Package damaged"
        case .businessClosed: return "Business closed"
        case .unsafe: return "Unsafe to deliver"
        case .needsSignature: return "Signature required, not available"
        case .other: return "Other"
        }
    }

    public var symbolName: String {
        switch self {
        case .noOneHome: return "house"
        case .accessIssue: return "lock"
        case .addressNotFound: return "mappin.slash"
        case .refused: return "hand.raised"
        case .damaged: return "shippingbox.and.arrow.backward"
        case .businessClosed: return "building.2"
        case .unsafe: return "exclamationmark.shield"
        case .needsSignature: return "signature"
        case .other: return "ellipsis.circle"
        }
    }
}

/// The one persisted outcome family for deliveries, pickups and checklist work. Legacy schema-1
/// package outcomes remain readable and retain their wire representation. May be voided once.
public struct TaskOutcome: Codable, Hashable, Sendable, Identifiable {
    public var id: OutcomeID
    public var schemaVersion: Int
    public var packageID: PackageID?
    public var taskID: TaskID?
    public var stopID: StopID
    public var kind: OutcomeKind
    public var reason: FailureReason?
    public var note: String?
    /// Device time when the driver recorded the outcome (actual, not planned).
    public var recordedAt: Date
    /// Set when the driver taps Undo. A voided outcome no longer affects package status.
    public var voidedAt: Date?
    public var photoIDs: [PhotoID]

    public init(id: OutcomeID = StableID.make(), packageID: PackageID, stopID: StopID, kind: OutcomeKind, reason: FailureReason? = nil, note: String? = nil, recordedAt: Date = Date(), photoIDs: [PhotoID] = []) {
        self.id = id
        self.schemaVersion = 1
        self.packageID = packageID
        self.taskID = nil
        self.stopID = stopID
        self.kind = kind
        self.reason = reason
        self.note = note
        self.recordedAt = recordedAt
        self.voidedAt = nil
        self.photoIDs = photoIDs
    }

    public init(id: OutcomeID = StableID.make(), taskID: TaskID, stopID: StopID, kind: OutcomeKind, packageID: PackageID? = nil, reason: FailureReason? = nil, note: String? = nil, recordedAt: Date = Date(), photoIDs: [PhotoID] = []) {
        self.id = id; self.schemaVersion = 2; self.taskID = taskID; self.packageID = packageID
        self.stopID = stopID; self.kind = kind; self.reason = reason; self.note = note
        self.recordedAt = recordedAt; self.voidedAt = nil; self.photoIDs = photoIDs
    }

    public var targetTaskID: TaskID {
        taskID ?? packageID.map(LocationTask.deliveryID(for:)) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, packageID, taskID, stopID, kind, reason, note, recordedAt, voidedAt, photoIDs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(OutcomeID.self, forKey: .id)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        packageID = try c.decodeIfPresent(PackageID.self, forKey: .packageID)
        taskID = try c.decodeIfPresent(TaskID.self, forKey: .taskID)
        stopID = try c.decode(StopID.self, forKey: .stopID)
        kind = try c.decode(OutcomeKind.self, forKey: .kind)
        reason = try c.decodeIfPresent(FailureReason.self, forKey: .reason)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        recordedAt = try c.decode(Date.self, forKey: .recordedAt)
        voidedAt = try c.decodeIfPresent(Date.self, forKey: .voidedAt)
        photoIDs = try c.decode([PhotoID].self, forKey: .photoIDs)
        guard (schemaVersion == 1 && packageID != nil && taskID == nil && kind != .completed)
            || (schemaVersion == 2 && taskID?.isEmpty == false) else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: c, debugDescription: "Unsupported or malformed work outcome.")
        }
    }
}

/// Compatibility spelling; not another ledger or persistent collection.
public typealias DeliveryOutcome = TaskOutcome

// MARK: - Proof of delivery

public struct DeliveryPhoto: Codable, Hashable, Sendable, Identifiable {
    public var id: PhotoID
    public var schemaVersion: Int
    public var stopID: StopID
    public var packageIDs: [PackageID]
    public var storagePath: String
    public var contentType: String
    public var byteSize: Int
    public var capturedAt: Date

    public init(id: PhotoID = StableID.make(), stopID: StopID, packageIDs: [PackageID], storagePath: String, contentType: String = "image/jpeg", byteSize: Int, capturedAt: Date) {
        self.id = id
        self.schemaVersion = 1
        self.stopID = stopID
        self.packageIDs = packageIDs
        self.storagePath = storagePath
        self.contentType = contentType
        self.byteSize = byteSize
        self.capturedAt = capturedAt
    }
}

// MARK: - User settings

public enum NavigationApp: String, Codable, Hashable, Sendable, CaseIterable {
    case appleMaps, googleMaps, ask

    public var label: String {
        switch self {
        case .appleMaps: return "Apple Maps"
        case .googleMaps: return "Google Maps"
        case .ask: return "Ask each time"
        }
    }
}

public enum DistanceUnit: String, Codable, Hashable, Sendable, CaseIterable {
    case kilometres, miles

    public var label: String { self == .kilometres ? "Kilometres" : "Miles" }
}

public struct UserSettings: Codable, Hashable, Sendable {
    public var navigationApp: NavigationApp
    public var distanceUnit: DistanceUnit
    public var defaultServiceSeconds: Int
    public var batchScanDefault: Bool

    public init(navigationApp: NavigationApp = .ask, distanceUnit: DistanceUnit = .kilometres, defaultServiceSeconds: Int = 120, batchScanDefault: Bool = false) {
        self.navigationApp = navigationApp
        self.distanceUnit = distanceUnit
        self.defaultServiceSeconds = defaultServiceSeconds
        self.batchScanDefault = batchScanDefault
    }
}
