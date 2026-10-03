import Foundation
import ParcelPilotKit
import UIKit
@testable import ParcelPilot

/// Builds a demo-mode service graph whose files live in a fresh temporary directory, so tests can
/// also simulate an app relaunch by building a second graph over the same directory.
@MainActor
struct TestEnvironment {
    let directory: URL
    let backend: LocalRouteBackend
    let store: RouteStore
    let drafts: DraftStore
    let services: AppServices

    init(directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("pp-tests-\(UUID().uuidString)"), online: Bool = true) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        backend = LocalRouteBackend(fileURL: directory.appendingPathComponent("routes.json"))
        store = RouteStore(backend: backend)
        drafts = DraftStore(fileURL: directory.appendingPathComponent("drafts.json"))
        let connectivity = ConnectivityMonitor(forceOffline: !online)
        services = AppServices(
            mode: .demo, store: store, settings: SettingsStore(backend: backend, defaults: UserDefaults(suiteName: "pp-tests-\(UUID().uuidString)")!), drafts: drafts,
            resolver: DemoAddressResolver(), optimizer: LocalRouteOptimizer(), photos: LocalPhotoStore(store: store),
            account: DemoAccountService {}, connectivity: connectivity, location: LocationService(), journal: nil, mapStyle: .apple,
            firestoreBackend: nil, localBackend: backend, userLabel: "Test"
        )
    }

    /// Simulates terminating and relaunching the app over the same on-device files.
    func relaunch(online: Bool = true) -> TestEnvironment { TestEnvironment(directory: directory, online: online) }

    @discardableResult
    func makeRoute(name: String = "Test route") -> Route {
        let route = store.createRoute(name: name, serviceDate: "2026-10-05", timeZoneID: "America/Vancouver", departureMinute: 8 * 60, defaultServiceSeconds: 120, start: RoutePlace(label: "Depot", located: LocatedPoint(point: GeoPoint(latitude: 48.45, longitude: -123.38), source: .driverPin)), returnToStart: true)
        store.currentRouteID = route.id
        return route
    }

    var snapshot: RouteSnapshot { store.current! }
}

enum AppFixtures {
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    static func label(_ name: String) -> UIImage? {
        if let url = Bundle(for: BundleToken.self).url(forResource: name, withExtension: "png") { return UIImage(contentsOfFile: url.path) }
        return UIImage(contentsOfFile: repoRoot.appendingPathComponent("fixtures/labels/\(name).png").path)
    }

    final class BundleToken {}
}

extension PostalAddress {
    static func e1() -> PostalAddress { CanadianAddressParser.parse(singleLine: "ALEX TEST, UNIT 204, 123 EXAMPLE ST, VICTORIA BC V8W 1A1").address }
}
