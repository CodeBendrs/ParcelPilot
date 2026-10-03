import Foundation

/// Where a newly scanned/typed package should go.
public enum IntakePlacement: Hashable, Sendable {
    /// No stop has this exact destination yet.
    case newStop
    /// A stop with the identical destination (including unit) exists — add the package to it.
    case existingStop(StopID)
    /// The tracking ID is already on this route.
    case duplicateTracking(packageID: PackageID, stopID: StopID)
}

/// Lookup over the current route used to place new packages.
public struct RouteIntakeIndex: Sendable {
    public private(set) var stopsByKey: [String: StopID]
    public private(set) var stopsByBuilding: [String: [StopID]]
    public private(set) var packagesByTracking: [String: (packageID: PackageID, stopID: StopID)]

    public init(stops: [Stop], packages: [Package]) {
        stopsByKey = [:]
        stopsByBuilding = [:]
        packagesByTracking = [:]
        for stop in stops {
            stopsByKey[stop.destinationKey] = stop.id
            if let b = DestinationKey.buildingKey(stop.address) { stopsByBuilding[b, default: []].append(stop.id) }
        }
        for package in packages {
            if let key = package.trackingKey { packagesByTracking[key] = (package.id, package.stopID) }
        }
    }

    public func placement(for address: PostalAddress, trackingID: String?) -> IntakePlacement {
        if let trackingID, let key = BarcodeClassifier.normalizedTrackingID(trackingID) ?? Package.looseKey(trackingID),
           let existing = packagesByTracking[key] {
            return .duplicateTracking(packageID: existing.packageID, stopID: existing.stopID)
        }
        if let key = DestinationKey.make(address), let stopID = stopsByKey[key] {
            return .existingStop(stopID)
        }
        return .newStop
    }

    /// Other stops in the same building with a *different* unit (informational only).
    public func otherUnitsInBuilding(for address: PostalAddress) -> [StopID] {
        guard let building = DestinationKey.buildingKey(address) else { return [] }
        let own = DestinationKey.make(address)
        return (stopsByBuilding[building] ?? []).filter { stopsByKey[own ?? ""] != $0 }
    }

    public mutating func register(stop: Stop) {
        stopsByKey[stop.destinationKey] = stop.id
        if let b = DestinationKey.buildingKey(stop.address) { stopsByBuilding[b, default: []].append(stop.id) }
    }

    public mutating func register(package: Package) {
        if let key = package.trackingKey { packagesByTracking[key] = (package.id, package.stopID) }
    }

    public mutating func unregister(package: Package) {
        if let key = package.trackingKey, packagesByTracking[key]?.packageID == package.id { packagesByTracking[key] = nil }
    }
}

/// Suppresses repeated processing of the same physical label while it stays in front of the camera.
///
/// A label is identified by its fingerprint (tracking IDs, or the recipient text when there is no
/// barcode). The same fingerprint is ignored for `cooldown` seconds after it was last *seen*, so a
/// label held in view does not re-trigger even if the camera keeps producing frames.
public struct ScanDeduplicator: Sendable {
    public var cooldown: TimeInterval
    private var lastSeen: [String: Date] = [:]
    private var processed: Set<String> = []

    public init(cooldown: TimeInterval = 4) { self.cooldown = cooldown }

    public enum Verdict: Equatable, Sendable {
        /// New label — process it.
        case process
        /// Same label still in view — ignore silently.
        case ignoreRepeatedFrame
        /// Same label presented again after the cooldown — warn, don't add automatically.
        case seenEarlierThisSession
    }

    public mutating func check(fingerprint: String, at now: Date) -> Verdict {
        defer { lastSeen[fingerprint] = now }
        if let last = lastSeen[fingerprint], now.timeIntervalSince(last) < cooldown { return .ignoreRepeatedFrame }
        if processed.contains(fingerprint) { return .seenEarlierThisSession }
        return .process
    }

    public mutating func markProcessed(_ fingerprint: String) { processed.insert(fingerprint) }
    public mutating func forget(_ fingerprint: String) { processed.remove(fingerprint); lastSeen[fingerprint] = nil }
}

/// How the driver's confirmation affects eligibility. A postal-area or city-level match cannot become
/// a destination without a driver-placed pin.
public enum ConfirmationPolicy {
    public static func statusAfterDriverConfirmation(match: MatchQuality?, hasDriverPin: Bool, demoMode: Bool) -> AddressStatus {
        if hasDriverPin { return .driverConfirmed }
        guard let match else { return .pendingVerification }
        switch match {
        case .building: return .verified
        case .buildingWithDifferences: return .driverConfirmed
        case .synthetic: return demoMode ? .demoSynthetic : .needsReview
        case .driverPin: return .driverConfirmed
        case .street, .postalArea, .municipality, .conflict: return .needsReview
        case .notFound: return .unresolvable
        }
    }

    /// Whether a resolver location may be stored for this match. Postal-area and city centroids are
    /// never stored as the stop location.
    public static func mayUseResolvedLocation(_ match: MatchQuality) -> Bool {
        switch match {
        case .building, .buildingWithDifferences, .synthetic: return true
        default: return false
        }
    }
}
