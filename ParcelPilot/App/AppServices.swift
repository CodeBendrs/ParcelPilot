import Foundation
import Observation
import ParcelPilotKit

/// Everything a signed-in (or demo) session needs. Built once per session by `AppCoordinator`; demo
/// adapters and production adapters are never mixed.
@MainActor
@Observable
final class AppServices {
    enum MapStyle: Equatable {
        /// Google map (production): required for any Google content.
        case google
        /// Google content exists but no Maps SDK key is configured — the list still works.
        case googleUnavailable(String)
        /// Apple map for synthetic demo/emulator content (no Google content exists in these modes).
        case apple
    }

    let mode: AppMode
    let store: RouteStore
    let settings: SettingsStore
    let drafts: DraftStore
    let resolver: AddressResolver
    let optimizer: RouteOptimizer
    let photos: PhotoStore
    let account: AccountService
    let connectivity: ConnectivityMonitor
    let location: LocationService
    let verifier: AddressVerifier
    let navigation: NavigationLauncher
    let journal: SyncJournal?
    let mapStyle: MapStyle
    let firestoreBackend: FirestoreRouteBackend?
    let localBackend: LocalRouteBackend?

    var userLabel: String

    init(mode: AppMode, store: RouteStore, settings: SettingsStore, drafts: DraftStore, resolver: AddressResolver, optimizer: RouteOptimizer, photos: PhotoStore, account: AccountService, connectivity: ConnectivityMonitor, location: LocationService, journal: SyncJournal?, mapStyle: MapStyle, firestoreBackend: FirestoreRouteBackend?, localBackend: LocalRouteBackend?, userLabel: String) {
        self.mode = mode
        self.store = store
        self.settings = settings
        self.drafts = drafts
        self.resolver = resolver
        self.optimizer = optimizer
        self.photos = photos
        self.account = account
        self.connectivity = connectivity
        self.location = location
        self.verifier = AddressVerifier(resolver: resolver, connectivity: connectivity, demoMode: mode.isDemo)
        self.navigation = NavigationLauncher()
        self.journal = journal
        self.mapStyle = mapStyle
        self.firestoreBackend = firestoreBackend
        self.localBackend = localBackend
        self.userLabel = userLabel
        connectivity.onChange { [weak self] online in
            guard online, let self else { return }
            Task { await self.backgroundSync() }
        }
        Task { await backgroundSync() }
    }

    /// Work that runs when the session starts and whenever the device comes back online.
    func backgroundSync() async {
        photos.resumeUploads()
        if let backend = firestoreBackend { await backend.reconcileJournal() }
        if let snapshot = store.current {
            await verifier.verifyPendingStops(in: snapshot, store: store)
            await verifier.refreshExpiredCoordinates(in: snapshot, store: store)
        }
        await verifyOfflineDrafts()
    }

    /// Scans saved offline ("Needs address verification") are checked as soon as the device is online.
    /// They stay in the review queue — the driver still confirms them — but now with a map result.
    func verifyOfflineDrafts() async {
        guard connectivity.isOnline else { return }
        for draft in drafts.drafts where draft.state == .needsVerification {
            var candidate = IntakeCandidate.fromDraft(draft)
            candidate.verification = await verifier.verify(candidate.address)
            guard candidate.verification?.assessment != nil else { continue }
            drafts.upsert(candidate.asDraft(id: draft.id, now: draft.createdAt, allowSynthetic: verifier.allowsSynthetic))
        }
    }

    static func demo(config: AppConfiguration) -> AppServices {
        let backend = LocalRouteBackend()
        if config.resetDemoData { backend.eraseAll() }
        let store = RouteStore(backend: backend)
        let drafts = DraftStore(fileURL: DraftStore.defaultURL.deletingLastPathComponent().appendingPathComponent("demo-scan-drafts.json"))
        if config.resetDemoData { drafts.removeAll() }
        let photos = LocalPhotoStore(store: store)
        let connectivity = ConnectivityMonitor(forceOffline: config.simulateOffline)
        let services = AppServices(
            mode: .demo, store: store, settings: SettingsStore(backend: backend), drafts: drafts,
            resolver: DemoAddressResolver(), optimizer: LocalRouteOptimizer(), photos: photos,
            account: DemoAccountService { backend.eraseAll(); drafts.removeAll(); photos.eraseAll() },
            connectivity: connectivity, location: LocationService(), journal: nil, mapStyle: .apple,
            firestoreBackend: nil, localBackend: backend, userLabel: "Demo driver (this iPhone only)"
        )
        if config.seedDemoRoute, store.routes.isEmpty { DemoSeed.createSampleRoute(in: store) }
        return services
    }

    static func firebase(uid: String, mode: AppMode, config: AppConfiguration, userLabel: String) -> AppServices {
        let journal = SyncJournal(fileURL: SyncJournal.defaultURL.deletingLastPathComponent().appendingPathComponent("sync-journal-\(uid).json"))
        let backend = FirestoreRouteBackend(uid: uid, db: FirebaseBootstrap.firestore(), journal: journal)
        let store = RouteStore(backend: backend)
        let connectivity = ConnectivityMonitor(forceOffline: config.simulateOffline)
        let providerKind: ProviderKind = mode == .production ? .google : .emulatorFake
        let drafts = DraftStore(fileURL: DraftStore.defaultURL.deletingLastPathComponent().appendingPathComponent("scan-drafts-\(uid).json"))
        let photos = FirebasePhotoStore(uid: uid, store: store, connectivity: connectivity)
        let mapStyle: MapStyle
        if mode == .production {
            mapStyle = config.mapsAPIKey != nil ? .google : .googleUnavailable("The map needs a Maps SDK for iOS key (Config/Secrets.xcconfig → GOOGLE_MAPS_IOS_API_KEY). Stops, scanning and delivery work without it.")
        } else {
            mapStyle = .apple
        }
        return AppServices(
            mode: mode, store: store, settings: SettingsStore(backend: backend), drafts: drafts,
            resolver: CallableAddressResolver(connectivity: connectivity, provider: providerKind),
            optimizer: CallableRouteOptimizer(backend: backend, connectivity: connectivity, provider: providerKind),
            photos: photos,
            account: FirebaseAccountService(cleanup: {
                drafts.removeAll()
                photos.eraseLocal()
                journal.clear()
                await FirebaseAccountService.clearFirestoreCache()
            }),
            connectivity: connectivity, location: LocationService(), journal: journal, mapStyle: mapStyle,
            firestoreBackend: backend, localBackend: nil, userLabel: userLabel
        )
    }
}
