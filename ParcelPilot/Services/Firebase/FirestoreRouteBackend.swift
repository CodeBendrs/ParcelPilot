import FirebaseFirestore
import Foundation
import ParcelPilotKit

/// Firestore-backed storage under users/{uid}. Uses the persistent cache: writes apply locally at
/// once, survive termination, and sync when online. Pending/synced state comes from snapshot metadata;
/// rejected writes are reported through the `SyncJournal`.
@MainActor
final class FirestoreRouteBackend: RouteBackend {
    let kind = BackendKind.firestore
    let uid: String
    let db: Firestore
    let journal: SyncJournal
    private let encoder = Firestore.Encoder()
    private let decoder = Firestore.Decoder()

    init(uid: String, db: Firestore = Firestore.firestore(), journal: SyncJournal) {
        self.uid = uid
        self.db = db
        self.journal = journal
    }

    private var user: DocumentReference { db.collection("users").document(uid) }
    private func routeRef(_ id: RouteID) -> DocumentReference { user.collection("routes").document(id) }

    // MARK: Reads

    func observeRoutes(_ onChange: @escaping ([Route], Set<String>) -> Void) -> ListenerToken {
        let registration = user.collection("routes").order(by: "updatedAt", descending: true).limit(to: 300)
            .addSnapshotListener(includeMetadataChanges: true) { [decoder] snapshot, error in
                guard let snapshot else {
                    if let error { AppLog.sync.error("Routes listener: \(error.localizedDescription, privacy: .public)") }
                    return
                }
                var routes: [Route] = []
                var pending = Set<String>()
                for doc in snapshot.documents {
                    if let route = try? doc.data(as: Route.self, decoder: decoder) { routes.append(route) }
                    if doc.metadata.hasPendingWrites { pending.insert("routes/\(doc.documentID)") }
                }
                MainActor.assumeIsolated { onChange(routes, pending) }
            }
        return ListenerToken { registration.remove() }
    }

    func observeRoute(_ id: RouteID, _ onChange: @escaping (RouteSnapshotEnvelope?) -> Void) -> ListenerToken {
        let state = RouteListenerState(routeID: id, onChange: onChange)
        let ref = routeRef(id)
        let decoder = self.decoder
        var registrations: [ListenerRegistration] = []
        registrations.append(ref.addSnapshotListener(includeMetadataChanges: true) { snap, _ in
            guard let snap else { return }
            let route = snap.exists ? try? snap.data(as: Route.self, decoder: decoder) : nil
            MainActor.assumeIsolated {
                state.route = route
                state.routeExists = snap.exists
                state.setPending("routes/\(id)", snap.metadata.hasPendingWrites)
                state.fromCache = snap.metadata.isFromCache
                state.loaded.insert("route")
                state.emit()
            }
        })
        func listen<T: Decodable & Identifiable>(_ name: String, _ type: T.Type, assign: @escaping @MainActor (RouteListenerState, [T]) -> Void) where T.ID == String {
            registrations.append(ref.collection(name).addSnapshotListener(includeMetadataChanges: true) { snap, error in
                guard let snap else {
                    if let error { AppLog.sync.error("\(name, privacy: .public) listener: \(error.localizedDescription, privacy: .public)") }
                    return
                }
                var items: [T] = []
                var pending: [String] = []
                for doc in snap.documents {
                    if let item = try? doc.data(as: T.self, decoder: decoder) { items.append(item) }
                    if doc.metadata.hasPendingWrites { pending.append("routes/\(id)/\(name)/\(doc.documentID)") }
                }
                MainActor.assumeIsolated {
                    assign(state, items)
                    state.replacePending(prefix: "routes/\(id)/\(name)/", with: pending)
                    state.loaded.insert(name)
                    state.emit()
                }
            })
        }
        listen("stops", Stop.self) { $0.stops = $1 }
        listen("packages", Package.self) { $0.packages = $1 }
        listen("outcomes", DeliveryOutcome.self) { $0.outcomes = $1 }
        listen("photos", DeliveryPhoto.self) { $0.photos = $1 }
        return ListenerToken { registrations.forEach { $0.remove() } }
    }

    func fetchRoute(_ id: RouteID) async throws -> RouteSnapshot? {
        let ref = routeRef(id)
        let routeDoc = try await ref.getDocument()
        guard routeDoc.exists, let route = try? routeDoc.data(as: Route.self, decoder: decoder) else { return nil }
        async let stops = ref.collection("stops").getDocuments()
        async let packages = ref.collection("packages").getDocuments()
        async let outcomes = ref.collection("outcomes").getDocuments()
        let (s, p, o) = try await (stops, packages, outcomes)
        return RouteSnapshot(
            route: route,
            stops: s.documents.compactMap { try? $0.data(as: Stop.self, decoder: decoder) },
            packages: p.documents.compactMap { try? $0.data(as: Package.self, decoder: decoder) },
            outcomes: o.documents.compactMap { try? $0.data(as: DeliveryOutcome.self, decoder: decoder) }
        )
    }

    // MARK: Writes

    static let routeOptionalKeys = ["start", "end", "breakRule", "appliedRequestID", "appliedRevision", "nextStopOverrideID", "startedAt", "completedAt", "archivedAt", "summary", "plannedDistance"]

    func commit(_ change: ChangeSet) {
        let batch = db.batch()
        do {
            for op in change.ops { try add(op, to: batch) }
        } catch {
            AppLog.sync.error("Encoding failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let journalID = change.critical ? journal.begin(change) : nil
        let journal = self.journal
        let label = change.label
        batch.commit { error in
            MainActor.assumeIsolated {
                if let error {
                    AppLog.sync.error("Write rejected (\(label, privacy: .private)): \((error as NSError).code, privacy: .public)")
                    if let journalID {
                        journal.failed(journalID, message: Self.describe(error))
                    } else {
                        // Non-critical changes are not retried automatically, but the driver is told that
                        // the change was undone instead of it silently disappearing.
                        journal.reportRejected(label: label, message: Self.describe(error) + " The change was undone on this iPhone.")
                    }
                } else if let journalID {
                    journal.succeeded(journalID)
                }
            }
        }
    }

    func retry(_ entry: SyncJournal.Entry) {
        journal.discard(entry.id)
        commit(ChangeSet(entry.ops.map(\.changeOp), label: entry.label, critical: true))
    }

    private func add(_ op: ChangeOp, to batch: WriteBatch) throws {
        switch op {
        case let .createRoute(route):
            try batch.setData(from: route, forDocument: routeRef(route.id), encoder: encoder)
        case let .updateRoute(route, bump):
            var data = try encoder.encode(route)
            data["inputRevision"] = nil
            // createdAt is immutable (rules compare it); re-encoding a decoded Date can change the
            // Timestamp's nanoseconds, so it is never sent with updates.
            data["createdAt"] = nil
            for key in Self.routeOptionalKeys where data[key] == nil { data[key] = FieldValue.delete() }
            // mergeFields replaces whole top-level fields (no deep merge of nested maps) and never
            // touches the revision counter.
            batch.setData(data, forDocument: routeRef(route.id), mergeFields: Array(data.keys))
            // The increment is its own write in the same atomic batch: a transform inside a
            // mergeFields set has the masked field cleared first, which resets the counter to 1.
            if bump { batch.updateData(["inputRevision": FieldValue.increment(Int64(1))], forDocument: routeRef(route.id)) }
        case let .putStop(rid, stop):
            try batch.setData(from: stop, forDocument: routeRef(rid).collection("stops").document(stop.id), encoder: encoder)
        case let .deleteStop(rid, id):
            batch.deleteDocument(routeRef(rid).collection("stops").document(id))
        case let .putPackage(rid, p):
            try batch.setData(from: p, forDocument: routeRef(rid).collection("packages").document(p.id), encoder: encoder)
        case let .deletePackage(rid, id):
            batch.deleteDocument(routeRef(rid).collection("packages").document(id))
        case let .createOutcome(rid, o):
            try batch.setData(from: o, forDocument: routeRef(rid).collection("outcomes").document(o.id), encoder: encoder)
        case let .voidOutcome(rid, id, at):
            batch.updateData(["voidedAt": Timestamp(date: at)], forDocument: routeRef(rid).collection("outcomes").document(id))
        case let .putPhoto(rid, p):
            try batch.setData(from: p, forDocument: routeRef(rid).collection("photos").document(p.id), encoder: encoder)
        case let .deletePhoto(rid, id):
            batch.deleteDocument(routeRef(rid).collection("photos").document(id))
        }
    }

    static func describe(_ error: Error) -> String {
        let code = FirestoreErrorCode.Code(rawValue: (error as NSError).code)
        switch code {
        case .permissionDenied: return "The server rejected this change (it didn't pass validation or you're signed in as a different user)."
        case .notFound: return "The item no longer exists on the server (it may have been removed on another device)."
        case .unauthenticated: return "You're signed out. Sign in again to sync this change."
        default: return "The change couldn't be saved to the server."
        }
    }

    /// After relaunch, entries whose acknowledgement was never received are checked against the server
    /// once all queued writes have been sent. Anything not present is marked failed for Retry.
    func reconcileJournal() async {
        let pendingEntries = journal.pending
        guard !pendingEntries.isEmpty else { return }
        do { try await db.waitForPendingWrites() } catch { return }
        for entry in pendingEntries {
            var verified = true
            for op in entry.ops {
                if !(await verify(op)) { verified = false; break }
            }
            if verified { journal.succeeded(entry.id) } else { journal.failed(entry.id, message: "This change didn't reach the server.") }
        }
    }

    private func verify(_ op: JournalOp) async -> Bool {
        do {
            switch op {
            case let .createOutcome(rid, o):
                return try await routeRef(rid).collection("outcomes").document(o.id).getDocument(source: .server).exists
            case let .voidOutcome(rid, id, _):
                return try await routeRef(rid).collection("outcomes").document(id).getDocument(source: .server).get("voidedAt") != nil
            case let .putStop(rid, s):
                return try await routeRef(rid).collection("stops").document(s.id).getDocument(source: .server).exists
            case let .putPackage(rid, p):
                return try await routeRef(rid).collection("packages").document(p.id).getDocument(source: .server).exists
            case let .deleteStop(rid, id):
                return try await !routeRef(rid).collection("stops").document(id).getDocument(source: .server).exists
            case let .deletePackage(rid, id):
                return try await !routeRef(rid).collection("packages").document(id).getDocument(source: .server).exists
            }
        } catch {
            return true // Can't tell (offline): keep trusting the persistent queue.
        }
    }

    // MARK: Settings

    func loadSettings() async -> UserSettings? {
        guard let snap = try? await user.getDocument(), let data = snap.data()?["settings"] else { return nil }
        return try? decoder.decode(UserSettings.self, from: data)
    }

    func saveSettings(_ settings: UserSettings) {
        guard let encoded = try? encoder.encode(settings) else { return }
        let ref = user
        ref.getDocument { snap, _ in
            if snap?.exists == true {
                ref.setData(["settings": encoded, "updatedAt": FieldValue.serverTimestamp()], merge: true)
            } else {
                ref.setData(["schemaVersion": 1, "settings": encoded, "createdAt": FieldValue.serverTimestamp(), "updatedAt": FieldValue.serverTimestamp()])
            }
        }
    }

    // MARK: Jobs

    func observeJob(_ id: String, _ onChange: @escaping (OptimizationJob?) -> Void) -> ListenerToken {
        let registration = user.collection("optimizationRequests").document(id).addSnapshotListener { snap, _ in
            let job = snap.flatMap { $0.exists ? JobDecoder.decode(id: id, data: $0.data() ?? [:]) : nil }
            MainActor.assumeIsolated { onChange(job) }
        }
        return ListenerToken { registration.remove() }
    }
}

/// Accumulates the five listeners of one route into a single snapshot.
@MainActor
private final class RouteListenerState {
    let routeID: RouteID
    let onChange: (RouteSnapshotEnvelope?) -> Void
    var route: Route?
    var routeExists = true
    var stops: [Stop] = []
    var packages: [Package] = []
    var outcomes: [DeliveryOutcome] = []
    var photos: [DeliveryPhoto] = []
    var pending = Set<String>()
    var fromCache = true
    var loaded = Set<String>()

    init(routeID: RouteID, onChange: @escaping (RouteSnapshotEnvelope?) -> Void) {
        self.routeID = routeID
        self.onChange = onChange
    }

    func setPending(_ key: String, _ isPending: Bool) {
        if isPending { pending.insert(key) } else { pending.remove(key) }
    }

    func replacePending(prefix: String, with keys: [String]) {
        pending = pending.filter { !$0.hasPrefix(prefix) }.union(keys)
    }

    func emit() {
        guard loaded.contains("route") else { return }
        guard routeExists, let route else { onChange(nil); return }
        guard loaded.isSuperset(of: ["stops", "packages", "outcomes"]) else { return }
        onChange(RouteSnapshotEnvelope(snapshot: RouteSnapshot(route: route, stops: stops, packages: packages, outcomes: outcomes, photos: photos), pendingKeys: pending, fromCache: fromCache))
    }
}
