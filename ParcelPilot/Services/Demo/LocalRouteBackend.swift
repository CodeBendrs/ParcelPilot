import Foundation
import ParcelPilotKit

/// On-device store used by demo mode (no account, no network). Data is one JSON file in Application
/// Support with complete file protection until first unlock. Every commit is saved before the
/// listeners are notified, so work survives the app being terminated.
@MainActor
final class LocalRouteBackend: RouteBackend {
    struct RouteData: Codable {
        var route: Route
        var stops: [StopID: Stop] = [:]
        var packages: [PackageID: Package] = [:]
        var outcomes: [OutcomeID: DeliveryOutcome] = [:]
        var photos: [PhotoID: DeliveryPhoto] = [:]
    }

    struct Database: Codable {
        var schemaVersion = 1
        var routes: [RouteID: RouteData] = [:]
        var settings: UserSettings?
    }

    let kind = BackendKind.onDevice
    private(set) var db: Database
    private let fileURL: URL
    private var routeListeners: [UUID: ([Route], Set<String>) -> Void] = [:]
    private var routeDetailListeners: [UUID: (RouteID, (RouteSnapshotEnvelope?) -> Void)] = [:]

    init(fileURL: URL = LocalRouteBackend.defaultURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder.appStorage.decode(Database.self, from: data) {
            db = decoded
        } else {
            db = Database()
        }
    }

    static var defaultURL: URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("demo-routes.json")
    }

    func observeRoutes(_ onChange: @escaping ([Route], Set<String>) -> Void) -> ListenerToken {
        let id = UUID()
        routeListeners[id] = onChange
        onChange(db.routes.values.map(\.route), [])
        return ListenerToken { [weak self] in Task { @MainActor in self?.routeListeners[id] = nil } }
    }

    func observeRoute(_ routeID: RouteID, _ onChange: @escaping (RouteSnapshotEnvelope?) -> Void) -> ListenerToken {
        let id = UUID()
        routeDetailListeners[id] = (routeID, onChange)
        onChange(envelope(routeID))
        return ListenerToken { [weak self] in Task { @MainActor in self?.routeDetailListeners[id] = nil } }
    }

    func fetchRoute(_ id: RouteID) async throws -> RouteSnapshot? { envelope(id)?.snapshot }

    private func envelope(_ id: RouteID) -> RouteSnapshotEnvelope? {
        guard let d = db.routes[id] else { return nil }
        return RouteSnapshotEnvelope(
            snapshot: RouteSnapshot(route: d.route, stops: Array(d.stops.values), packages: Array(d.packages.values), outcomes: Array(d.outcomes.values), photos: Array(d.photos.values)),
            pendingKeys: [],
            fromCache: false
        )
    }

    func commit(_ change: ChangeSet) {
        var next = db
        for op in change.ops { Self.apply(op, to: &next) }
        db = next
        save()
        notify(changed: Set(change.ops.map(Self.routeID(of:))))
    }

    static func routeID(of op: ChangeOp) -> RouteID {
        switch op {
        case let .createRoute(r), let .updateRoute(r, _): return r.id
        case let .putStop(id, _), let .deleteStop(id, _), let .putPackage(id, _), let .deletePackage(id, _),
             let .createOutcome(id, _), let .voidOutcome(id, _, _), let .putPhoto(id, _), let .deletePhoto(id, _): return id
        }
    }

    /// Same semantics as the Firestore rules: outcomes are create-once and void-once.
    static func apply(_ op: ChangeOp, to db: inout Database) {
        switch op {
        case let .createRoute(route):
            if db.routes[route.id] == nil { db.routes[route.id] = RouteData(route: route) }
        case let .updateRoute(route, bump):
            guard var data = db.routes[route.id] else { return }
            var r = route
            r.inputRevision = data.route.inputRevision + (bump ? 1 : 0)
            data.route = r
            db.routes[route.id] = data
        case let .putStop(rid, stop): db.routes[rid]?.stops[stop.id] = stop
        case let .deleteStop(rid, id): db.routes[rid]?.stops[id] = nil
        case let .putPackage(rid, p): db.routes[rid]?.packages[p.id] = p
        case let .deletePackage(rid, id): db.routes[rid]?.packages[id] = nil
        case let .createOutcome(rid, o):
            if db.routes[rid]?.outcomes[o.id] == nil { db.routes[rid]?.outcomes[o.id] = o }
        case let .voidOutcome(rid, id, at):
            if var o = db.routes[rid]?.outcomes[id], o.voidedAt == nil { o.voidedAt = at; db.routes[rid]?.outcomes[id] = o }
        case let .putPhoto(rid, p): db.routes[rid]?.photos[p.id] = p
        case let .deletePhoto(rid, id): db.routes[rid]?.photos[id] = nil
        }
    }

    private func notify(changed: Set<RouteID>) {
        let routes = db.routes.values.map(\.route)
        for listener in routeListeners.values { listener(routes, []) }
        for (routeID, listener) in routeDetailListeners.values where changed.contains(routeID) { listener(envelope(routeID)) }
    }

    private func save() {
        do {
            let data = try JSONEncoder.appStorage.encode(db)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            AppLog.storage.error("Demo store save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func loadSettings() async -> UserSettings? { db.settings }

    func saveSettings(_ settings: UserSettings) {
        db.settings = settings
        save()
    }

    /// Erases all demo data (Settings → Erase demo data).
    func eraseAll() {
        db = Database()
        save()
        notify(changed: [])
        for (routeID, listener) in routeDetailListeners.values { listener(envelope(routeID)) }
    }
}

extension JSONEncoder {
    static let appStorage: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
}

extension JSONDecoder {
    static let appStorage: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}
