import FirebaseAppCheck
import FirebaseAuth
import FirebaseCore
import FirebaseCrashlytics
import FirebaseFirestore
import FirebaseFunctions
import FirebaseStorage
import Foundation
import GoogleMaps

/// Configures Firebase once per process.
///
/// * Production: GoogleService-Info.plist, App Check (App Attest, DeviceCheck fallback; debug provider in
///   Debug builds), Crashlytics enabled with no user content.
/// * Emulator: a `demo-` project that never touches real Google services; App Check is not used.
enum FirebaseBootstrap {
    @MainActor private static var configured = false
    @MainActor private(set) static var mode: AppMode?

    @MainActor
    static func configureIfPossible(_ config: AppConfiguration) {
        guard !configured else { return }
        if let key = config.mapsAPIKey { GMSServices.provideAPIKey(key) }
        if let host = config.emulatorHost {
            // No App Check provider: the emulators don't enforce it, and the default/debug providers
            // would otherwise call the real App Check service for a demo- project.
            AppCheck.setAppCheckProviderFactory(NoAppCheckProviderFactory())
            let options = FirebaseOptions(googleAppID: "1:123456789012:ios:0123456789abcdef", gcmSenderID: "123456789012")
            options.projectID = AppConfiguration.emulatorProjectID
            options.apiKey = "AIzaSyEmulatorOnlyNotARealKey0000000000" // placeholder; Firebase requires a 39-character key shape
            options.storageBucket = "\(AppConfiguration.emulatorProjectID).appspot.com"
            options.bundleID = Bundle.main.bundleIdentifier ?? "com.example.parcelpilot"
            FirebaseApp.configure(options: options)
            Auth.auth().useEmulator(withHost: host, port: 9099)
            mode = .emulator(host: host)
            _ = firestore()
            Functions.functions(region: AppConfiguration.firebaseRegion).useEmulator(withHost: host, port: 5001)
            Storage.storage().useEmulator(withHost: host, port: 9199)
            Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(false)
            configured = true
            return
        }
        guard config.hasFirebaseConfig else { return }
        #if DEBUG
        AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        #else
        AppCheck.setAppCheckProviderFactory(ParcelPilotAppCheckFactory())
        #endif
        FirebaseApp.configure()
        mode = .production
        _ = firestore()
        // Crash reports contain stack traces and device state only; the app never sets custom keys or
        // logs with addresses, names, tracking numbers or OCR text.
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(true)
        configured = true
    }

    @MainActor static var isConfigured: Bool { configured }

    @MainActor private static weak var configuredFirestore: Firestore?

    /// The Firestore instance with ParcelPilot settings (persistent cache, emulator host). After
    /// `terminate()` (sign-out clears the cache) a fresh instance is configured again.
    @MainActor
    static func firestore() -> Firestore {
        let db = Firestore.firestore()
        if configuredFirestore !== db {
            // One settings object for everything: re-assigning settings after useEmulator(withHost:)
            // drops the emulator's plain-text connection setting.
            let settings = FirestoreSettings()
            if case let .emulator(host) = mode {
                settings.host = "\(host):8180"
                settings.isSSLEnabled = false
            }
            settings.cacheSettings = PersistentCacheSettings(sizeBytes: NSNumber(value: 200 * 1024 * 1024))
            db.settings = settings
            configuredFirestore = db
        }
        return db
    }

    static func functions() -> Functions { Functions.functions(region: AppConfiguration.firebaseRegion) }
}

/// App Attest where available (needs the Apple Developer Program capability), DeviceCheck otherwise.
final class ParcelPilotAppCheckFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        if FirebaseSession.appleDeveloperProgram, let attest = AppAttestProvider(app: app) { return attest }
        return DeviceCheckProvider(app: app)
    }
}

/// Emulator builds only: App Check is not used, so no token requests leave the machine.
final class NoAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? { nil }
}
