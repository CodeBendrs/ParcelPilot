import Foundation

/// Build/launch configuration, read once at startup. Missing values produce an actionable
/// configuration state in the UI — never a fake success.
struct AppConfiguration: Sendable {
    /// GoogleService-Info.plist is bundled (production Firebase project).
    var hasFirebaseConfig: Bool
    /// Maps SDK for iOS key from Config/Secrets.xcconfig (public, app-restricted client value).
    var mapsAPIKey: String?
    /// Firebase Emulator Suite host when launched with `-PPUseFirebaseEmulators YES`.
    var emulatorHost: String?
    /// UI tests / screenshots: start directly in demo mode with a clean store.
    var forceDemo: Bool
    var resetDemoData: Bool
    var seedDemoRoute: Bool
    var disableAnimations: Bool
    var simulateOffline: Bool

    static let firebaseRegion = "northamerica-northeast1"
    static let emulatorProjectID = "demo-parcelpilot"

    static func load(bundle: Bundle = .main, defaults: UserDefaults = .standard) -> AppConfiguration {
        let plist = bundle.path(forResource: "GoogleService-Info", ofType: "plist")
        let rawKey = (bundle.object(forInfoDictionaryKey: "PPGoogleMapsAPIKey") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let key = rawKey.isEmpty || rawKey.hasPrefix("$(") ? nil : rawKey
        let useEmulators = defaults.bool(forKey: "PPUseFirebaseEmulators") || ProcessInfo.processInfo.environment["PP_EMULATOR"] == "1"
        return AppConfiguration(
            hasFirebaseConfig: plist != nil,
            mapsAPIKey: key,
            emulatorHost: useEmulators ? (defaults.string(forKey: "PPFirebaseEmulatorHost") ?? "127.0.0.1") : nil,
            forceDemo: defaults.bool(forKey: "PPDemoMode"),
            resetDemoData: defaults.bool(forKey: "PPResetDemoData"),
            seedDemoRoute: defaults.bool(forKey: "PPSeedDemoRoute"),
            disableAnimations: defaults.bool(forKey: "PPDisableAnimations"),
            simulateOffline: defaults.bool(forKey: "PPSimulateOffline")
        )
    }

    var canUseFirebase: Bool { hasFirebaseConfig || emulatorHost != nil }
}

enum AppMode: Equatable, Sendable {
    case production
    case emulator(host: String)
    case demo

    var isDemo: Bool { self == .demo }
    /// Generalized work writers stay disabled against production until compatible-client rollout
    /// review. This is a service-graph choice, never a user-default or pilot-logging override.
    var generalizedWorkAvailability: GeneralizedWorkAvailability {
        switch self { case .production: .compatibilityReviewRequired; case .demo, .emulator: .development }
    }
    var label: String {
        switch self {
        case .production: return "Account"
        case .emulator: return "Local emulator"
        case .demo: return "Demo mode"
        }
    }
}

enum GeneralizedWorkAvailability: Equatable, Sendable {
    case compatibilityReviewRequired
    case development
}
