import CoreLocation
import Foundation
import Network
import Observation
import os
import ParcelPilotKit

/// Logging policy: never log addresses, names, tracking numbers, notes, access codes or OCR text.
/// Dynamic values are `.private` unless they are enum-like states.
enum AppLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "ParcelPilot"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let scan = Logger(subsystem: subsystem, category: "scan")
    static let routing = Logger(subsystem: subsystem, category: "routing")
}

/// Online/offline state from the system network path monitor.
@MainActor
@Observable
final class ConnectivityMonitor {
    private(set) var isOnline = true
    private(set) var isExpensive = false
    private let monitor = NWPathMonitor()
    private var observers: [UUID: (Bool) -> Void] = [:]

    init(forceOffline: Bool = false) {
        if forceOffline { isOnline = false; return }
        // The handler runs on the monitor's queue, so it is built outside the main actor.
        monitor.pathUpdateHandler = Self.makeHandler { [weak self] online, expensive in
            guard let self else { return }
            let changed = online != self.isOnline
            self.isOnline = online
            self.isExpensive = expensive
            if changed { for o in self.observers.values { o(online) } }
        }
        monitor.start(queue: DispatchQueue(label: "connectivity"))
    }

    nonisolated private static func makeHandler(_ apply: @escaping @MainActor (Bool, Bool) -> Void) -> @Sendable (NWPath) -> Void {
        { path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive
            Task { @MainActor in apply(online, expensive) }
        }
    }

    @discardableResult
    func onChange(_ handler: @escaping (Bool) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }
}

/// Foreground location, requested only at the point of use (planning from "my location").
@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var authorization: CLAuthorizationStatus
    private var continuation: CheckedContinuation<CLLocationCoordinate2D, Error>?
    private var authContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    enum LocationError: LocalizedError {
        case denied, restricted, unavailable
        var errorDescription: String? {
            switch self {
            case .denied: return "Location access is off for ParcelPilot. You can choose a starting stop or address instead, or allow location in Settings."
            case .restricted: return "Location is restricted on this iPhone. Choose a starting stop or address instead."
            case .unavailable: return "Your location isn't available right now. Choose a starting stop or address instead."
            }
        }
    }

    func currentLocation() async throws -> CLLocationCoordinate2D {
        if authorization == .notDetermined {
            authorization = await withCheckedContinuation { c in
                authContinuation = c
                manager.requestWhenInUseAuthorization()
            }
        }
        switch authorization {
        case .denied: throw LocationError.denied
        case .restricted: throw LocationError.restricted
        default: break
        }
        return try await withCheckedThrowingContinuation { c in
            continuation?.resume(throwing: LocationError.unavailable)
            continuation = c
            manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if status != .notDetermined, let c = self.authContinuation { self.authContinuation = nil; c.resume(returning: status) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        Task { @MainActor in
            self.continuation?.resume(returning: coordinate)
            self.continuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.continuation?.resume(throwing: LocationError.unavailable)
            self.continuation = nil
        }
    }
}

/// User preferences. Cached locally for instant reads and saved to the backend (users/{uid}).
@MainActor
@Observable
final class SettingsStore {
    private(set) var settings: UserSettings
    private let backend: RouteBackend
    private let defaults: UserDefaults
    private static let key = "pp.settings"

    init(backend: RouteBackend, defaults: UserDefaults = .standard) {
        self.backend = backend
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let s = try? JSONDecoder().decode(UserSettings.self, from: data) {
            settings = s
        } else {
            settings = UserSettings()
        }
        Task { @MainActor in
            if let remote = await backend.loadSettings() { self.apply(remote, persistRemote: false) }
        }
    }

    func update(_ change: (inout UserSettings) -> Void) {
        var s = settings
        change(&s)
        apply(s, persistRemote: true)
    }

    private func apply(_ s: UserSettings, persistRemote: Bool) {
        settings = s
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: Self.key) }
        if persistRemote { backend.saveSettings(s) }
    }
}
