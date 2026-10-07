import Foundation
import ParcelPilotKit

/// On-device store used by demo mode (no account, no network). Data is one JSON file in Application
/// Support with complete file protection until first unlock. Legacy JSON mutations acknowledge
/// checked atomic replacement; app sessions wrap this reader with the WP2 SQLite backend.
@MainActor
final class LocalRouteBackend: RouteBackend {
    struct RouteData: Codable {
        var route: Route
        var stops: [StopID: Stop] = [:]
        var packages: [PackageID: Package] = [:]
        var tasks: [TaskID: LocationTask] = [:]
        var outcomes: [OutcomeID: DeliveryOutcome] = [:]
        var photos: [PhotoID: DeliveryPhoto] = [:]

        init(route: Route) { self.route = route }

        private enum CodingKeys: String, CodingKey { case route, stops, packages, tasks, outcomes, photos }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            route = try values.decode(Route.self, forKey: .route)
            stops = try values.decode([StopID: Stop].self, forKey: .stops)
            packages = try values.decode([PackageID: Package].self, forKey: .packages)
            tasks = try values.decodeIfPresent([TaskID: LocationTask].self, forKey: .tasks) ?? [:]
            outcomes = try values.decode([OutcomeID: DeliveryOutcome].self, forKey: .outcomes)
            photos = try values.decode([PhotoID: DeliveryPhoto].self, forKey: .photos)
        }
    }

    struct Database: Codable {
        var schemaVersion = 1
        var routes: [RouteID: RouteData] = [:]
        var settings: UserSettings?
    }

    let kind = BackendKind.onDevice
    private(set) var db: Database
    private let fileURL: URL
    private(set) var loadFailure: LocalPersistenceFailure?
    /// Compatibility fixtures only. Production demo sessions use the protected SQLite singleton.
    private(set) var currentExecutionSession: RouteExecutionSession?
    private var routeListeners: [UUID: ([Route], Set<String>) -> Void] = [:]
    private var routeDetailListeners: [UUID: (RouteID, (RouteSnapshotEnvelope?) -> Void)] = [:]

    init(fileURL: URL = LocalRouteBackend.defaultURL) {
        self.fileURL = fileURL
        db = Database()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                let decoded = try JSONDecoder.appStorage.decode(Database.self, from: data)
                guard decoded.schemaVersion == 1 else { throw LocalPersistenceFailure.unsupportedSchema(decoded.schemaVersion) }
                db = decoded
            } catch { loadFailure = error as? LocalPersistenceFailure ?? .corrupt("Legacy local route data couldn't be read. Original bytes were preserved.") }
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
            snapshot: RouteSnapshot(route: d.route, stops: Array(d.stops.values), packages: Array(d.packages.values), outcomes: Array(d.outcomes.values), photos: Array(d.photos.values), tasks: Array(d.tasks.values)),
            pendingKeys: [],
            fromCache: false
        )
    }

    @discardableResult func commit(_ change: ChangeSet) -> LocalCommitResult {
        if let loadFailure { return .failed(loadFailure) }
        var next = db
        do {
            var execution = currentExecutionSession
            for op in change.ops {
                if case let .transitionExecution(routeID, expected, session) = op {
                    guard session.routeID == routeID,
                          (execution == nil && expected == nil) || (execution != nil && expected != nil && execution!.matches(expected!)) else {
                        throw LocalPersistenceFailure.conflict("Route execution changed. Reload before retrying.")
                    }
                    do { try RouteExecutionSession.validateTransition(from: execution, to: session) }
                    catch { throw LocalPersistenceFailure.conflict(error.localizedDescription) }
                    if session.state == .finished, !change.ops.contains(where: { if case let .updateRoute(route, _) = $0 { route.id == routeID && !route.isOpen } else { false } }) {
                        throw LocalPersistenceFailure.conflict("Finish execution and close the route in the same saved action.")
                    }
                    guard next.routes[routeID]?.route.isOpen == true || session.state == .finished else {
                        throw LocalPersistenceFailure.conflict("Start route execution from an open loaded route.")
                    }
                    execution = session
                }
                Self.apply(op, to: &next)
            }
            if let execution, execution.isUnfinished, next.routes[execution.routeID]?.route.isOpen != true {
                throw LocalPersistenceFailure.conflict("Finish route execution explicitly before closing this route.")
            }
            try JSONEncoder.appStorage.encode(next).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            db = next; currentExecutionSession = execution
            notify(changed: Set(change.ops.map(Self.routeID(of:))))
            return .committed(.init(commandIDs: [], syncPending: false))
        } catch { return .failed(error as? LocalPersistenceFailure ?? .storage(error.localizedDescription)) }
    }

    static func routeID(of op: ChangeOp) -> RouteID {
        switch op {
        case let .createRoute(r), let .updateRoute(r, _): return r.id
        case let .bumpRouteRevision(id, _): return id
        case let .putStop(id, _), let .deleteStop(id, _), let .putPackage(id, _), let .deletePackage(id, _),
             let .putTask(id, _), let .deleteTask(id, _), let .createOutcome(id, _), let .voidOutcome(id, _, _), let .putPhoto(id, _), let .deletePhoto(id, _), let .transitionExecution(id, _, _): return id
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
        case let .bumpRouteRevision(rid, _): db.routes[rid]?.route.inputRevision += 1
        case let .putStop(rid, stop): db.routes[rid]?.stops[stop.id] = stop
        case let .deleteStop(rid, id): db.routes[rid]?.stops[id] = nil
        case let .putPackage(rid, p): db.routes[rid]?.packages[p.id] = p
        case let .deletePackage(rid, id): db.routes[rid]?.packages[id] = nil
        case let .putTask(rid, task): db.routes[rid]?.tasks[task.id] = task
        case let .deleteTask(rid, id): db.routes[rid]?.tasks[id] = nil
        case let .createOutcome(rid, o):
            if db.routes[rid]?.outcomes[o.id] == nil { db.routes[rid]?.outcomes[o.id] = o }
        case let .voidOutcome(rid, id, at):
            if var o = db.routes[rid]?.outcomes[id], o.voidedAt == nil { o.voidedAt = at; db.routes[rid]?.outcomes[id] = o }
        case let .putPhoto(rid, p): db.routes[rid]?.photos[p.id] = p
        case let .deletePhoto(rid, id): db.routes[rid]?.photos[id] = nil
        case .transitionExecution: break // handled by compatibility instance, never legacy JSON
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
    @discardableResult func eraseAll() -> LocalCommitResult {
        do {
            try JSONEncoder.appStorage.encode(Database()).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { return .failed(.storage(error.localizedDescription)) }
        db = Database(); loadFailure = nil; currentExecutionSession = nil
        notify(changed: [])
        for (routeID, listener) in routeDetailListeners.values { listener(envelope(routeID)) }
        return .committed(.init(commandIDs: [], syncPending: false))
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
