import FirebaseAuth
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
        (store.backend as? DurableRouteBackend)?.networkAvailable = connectivity.isOnline
        connectivity.onChange { [weak self] online in
            guard let self else { return }
            (self.store.backend as? DurableRouteBackend)?.networkAvailable = online
            if online { Task { await self.backgroundSync() } }
        }
        Task { await backgroundSync() }
    }

    /// Work that runs when the session starts and whenever the device comes back online.
    func backgroundSync() async {
        guard connectivity.isOnline else { return }
        photos.resumeUploads()
        if let protected = store.backend as? DurableRouteBackend { await protected.synchronize() }
        photos.resumeUploads() // Settle attachment metadata whose outbox receipt has just arrived.
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

    private static func protectedBackend(remote: RouteBackend, ownerID: String, namespace: String, transport: DurableCommandTransport?, authenticatedOwner: @escaping () -> String?, reset: Bool = false) -> DurableRouteBackend {
        do {
            let persistence = try ActiveRoutePersistence(ownerID: ownerID, databaseURL: ActiveRoutePersistence.defaultURL(ownerID: ownerID, namespace: namespace))
            if reset { try persistence.eraseOperationalData() }
            try persistence.compact()
            return DurableRouteBackend(remote: remote, ownerID: ownerID, persistence: persistence, transport: transport, authenticatedOwner: authenticatedOwner)
        } catch {
            return DurableRouteBackend(remote: remote, ownerID: ownerID, persistence: nil, transport: transport, authenticatedOwner: authenticatedOwner,
                initializationFailure: error as? LocalPersistenceFailure ?? .storage(error.localizedDescription))
        }
    }
    func suspendOperationalSync() {
        (store.backend as? DurableRouteBackend)?.suspend()
        (photos as? FirebasePhotoStore)?.eraseLocal()
    }

    static func demo(config: AppConfiguration) -> AppServices {
        let backend = LocalRouteBackend()
        let resetResult = config.resetDemoData ? backend.eraseAll() : nil
        let protected = protectedBackend(remote: backend, ownerID: "demo", namespace: "demo", transport: nil, authenticatedOwner: { "demo" }, reset: config.resetDemoData)
        if let persistence = protected.persistence, protected.issue == nil {
            do {
                for data in backend.db.routes.values where try persistence.snapshot(data.route.id) == nil {
                    try persistence.pin(RouteSnapshot(route: data.route, stops: Array(data.stops.values), packages: Array(data.packages.values), outcomes: Array(data.outcomes.values), photos: Array(data.photos.values), tasks: Array(data.tasks.values)))
                }
            } catch { protected.quarantine(error) }
        }
        if let failure = backend.loadFailure { protected.quarantine(failure) }
        if let resetResult, case let .failed(error) = resetResult { protected.quarantine(error) }
        let store = RouteStore(backend: protected, generalizedWorkAvailability: AppMode.demo.generalizedWorkAvailability)
        let drafts = DraftStore(fileURL: DraftStore.defaultURL.deletingLastPathComponent().appendingPathComponent("demo-scan-drafts.json"))
        if config.resetDemoData { drafts.removeAll() }
        let photos = LocalPhotoStore(store: store)
        let connectivity = ConnectivityMonitor(forceOffline: config.simulateOffline)
        let services = AppServices(
            mode: .demo, store: store, settings: SettingsStore(backend: backend), drafts: drafts,
            resolver: DemoAddressResolver(), optimizer: LocalRouteOptimizer(), photos: photos,
            account: DemoAccountService {
                if case let .failed(error) = backend.eraseAll() { throw error }
                guard let persistence = protected.persistence else { throw protected.issue ?? .storage("Protected data couldn't be erased.") }
                try persistence.eraseOperationalData(); drafts.removeAll(); try photos.eraseAll()
            },
            connectivity: connectivity, location: LocationService(), journal: nil, mapStyle: .apple,
            firestoreBackend: nil, localBackend: backend, userLabel: "Demo driver (this iPhone only)"
        )
        if config.seedDemoRoute, store.routes.isEmpty { DemoSeed.createSampleRoute(in: store) }
        return services
    }

    static func firebase(uid: String, mode: AppMode, config: AppConfiguration, userLabel: String) -> AppServices {
        let journal = SyncJournal(fileURL: SyncJournal.defaultURL.deletingLastPathComponent().appendingPathComponent("sync-journal-\(uid).json"))
        let backend = FirestoreRouteBackend(uid: uid, db: FirebaseBootstrap.firestore(), journal: journal)
        let protected = protectedBackend(remote: backend, ownerID: uid, namespace: mode == .production ? "firebase-production" : "firebase-emulator", transport: backend,
            authenticatedOwner: { Auth.auth(app: backend.db.app).currentUser?.uid })
        if let failure = journal.lastPersistenceFailure { protected.quarantine(failure) }
        if let persistence = protected.persistence, protected.issue == nil {
            do { try persistence.importLegacyJournal(journal.entries, sourceKey: "wp1-journal") }
            catch { protected.quarantine(error) }
        }
        journal.bind(to: protected)
        let store = RouteStore(backend: protected, generalizedWorkAvailability: mode.generalizedWorkAvailability)
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
            account: FirebaseAccountService(deletionCleanup: {
                protected.suspend(); photos.eraseLocal()
                // The existing account-deletion confirmation explicitly includes local/unsynced data.
                guard let persistence = protected.persistence else { throw protected.issue ?? .storage("Protected data couldn't be erased.") }
                try persistence.eraseOperationalData()
                drafts.removeAll()
                try photos.eraseLegacyFilesAfterAccountDeletion()
                journal.unbindForAccountDeletion()
                journal.clear()
                await FirebaseAccountService.clearFirestoreCache()
            }, cleanup: {
                protected.suspend()
                photos.eraseLocal() // Pauses uploads; owner-bound operational bytes remain recoverable.
                // Keep drafts and protected commands. Another UID receives a different store graph.
                await FirebaseAccountService.clearFirestoreCache()
            }),
            connectivity: connectivity, location: LocationService(), journal: journal, mapStyle: mapStyle,
            firestoreBackend: backend, localBackend: nil, userLabel: userLabel
        )
    }
}
