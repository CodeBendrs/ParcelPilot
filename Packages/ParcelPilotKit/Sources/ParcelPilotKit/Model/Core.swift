import Foundation

public typealias RouteID = String
public typealias StopID = String
public typealias PackageID = String
public typealias OutcomeID = String
public typealias PhotoID = String

/// Stable identifiers are generated on the device that creates a record so that offline writes,
/// retries and replays are idempotent.
public enum StableID {
    public static func make() -> String { UUID().uuidString.lowercased() }
}

public struct GeoPoint: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public var isValid: Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude) && !(latitude == 0 && longitude == 0)
    }

    /// Great-circle distance in metres. Only used for demo estimates and sanity checks — never presented
    /// as road distance.
    public func haversineMeters(to other: GeoPoint) -> Double {
        let r = 6_371_000.0
        let dLat = (other.latitude - latitude) * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }
}

/// Where a coordinate came from. Provider content carries an expiry; driver data does not.
public enum PointSource: String, Codable, Hashable, Sendable {
    /// Device location captured in the foreground with permission (driver data).
    case deviceLocation
    /// Pin the driver placed on the map (driver data).
    case driverPin
    /// Google Geocoding result — Google Maps Content, cache ≤ 30 days, Google map only.
    case providerGeocode
    /// Synthetic coordinate produced by the on-device demo resolver.
    case demoSynthetic
    /// Coordinate produced by the emulator-only test provider.
    case emulatorFake

    public var isGoogleContent: Bool { self == .providerGeocode }
    public var isSynthetic: Bool { self == .demoSynthetic || self == .emulatorFake }
}

public struct LocatedPoint: Codable, Hashable, Sendable {
    public var point: GeoPoint
    public var source: PointSource
    /// Required for provider content; nil for driver-owned points.
    public var expiresAt: Date?

    public init(point: GeoPoint, source: PointSource, expiresAt: Date? = nil) {
        self.point = point
        self.source = source
        self.expiresAt = expiresAt
    }

    public func isUsable(at now: Date) -> Bool {
        guard point.isValid else { return false }
        if let expiresAt { return expiresAt > now }
        return !source.isGoogleContent // provider content without an expiry is treated as unusable
    }
}

/// Retention rules for provider content. Centralised so the policy can change in one place.
public enum ProviderContentPolicy {
    /// Google Maps Platform Service Specific Terms permit caching Geocoding / Route Optimization
    /// latitude/longitude for up to 30 consecutive calendar days.
    public static let geocodeCoordinateLifetime: TimeInterval = 30 * 24 * 3600
    /// Optimization proposals (ETAs, distances, polylines) are kept only for the working day.
    public static let proposalLifetime: TimeInterval = 24 * 3600
}

public enum ProviderKind: String, Codable, Hashable, Sendable {
    case google
    case demo
    case emulatorFake

    public var isRealRoadNetwork: Bool { self == .google }

    public var displayName: String {
        switch self {
        case .google: return "Google Route Optimization"
        case .demo: return "Demo estimate (straight-line)"
        case .emulatorFake: return "Emulator test provider"
        }
    }
}
