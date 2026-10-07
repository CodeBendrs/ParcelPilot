import FirebaseAuth
import FirebaseFirestore
import Foundation
import ParcelPilotKit

/// Firebase transport under users/{uid}. Production driver acknowledgement belongs to the protected
/// local backend. The legacy batch API remains for compatibility; it is not a local durability proof.
@MainActor
final class FirestoreRouteBackend: RouteBackend, ExecutionSessionTransport {
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
    private var executionRef: DocumentReference { user.collection("execution").document("current") }

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
            let route: Route?
            do { route = snap.exists ? try snap.data(as: Route.self, decoder: decoder) : nil }
            catch {
                AppLog.sync.error("Route decoding failed; keeping the previous route snapshot.")
                MainActor.assumeIsolated { state.failReading("route"); state.emit() }
                return
            }
            MainActor.assumeIsolated {
                state.route = route
                state.routeExists = snap.exists
                state.readIssues["route"] = nil
                state.setPending("routes/\(id)", snap.metadata.hasPendingWrites)
                state.setCache("route", snap.metadata.isFromCache)
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
                let items: [T]
                do { items = try snap.documents.map { try $0.data(as: T.self, decoder: decoder) } }
                catch {
                    AppLog.sync.error("\(name, privacy: .public) decoding failed; keeping the previous collection.")
                    MainActor.assumeIsolated { state.failReading(name); state.emit() }
                    return
                }
                var pending: [String] = []
                for doc in snap.documents {
                    if doc.metadata.hasPendingWrites { pending.append("routes/\(id)/\(name)/\(doc.documentID)") }
                }
                MainActor.assumeIsolated {
                    assign(state, items)
                    state.readIssues[name] = nil
                    state.replacePending(prefix: "routes/\(id)/\(name)/", with: pending)
                    state.setCache(name, snap.metadata.isFromCache)
                    state.loaded.insert(name)
                    state.emit()
                }
            })
        }
        listen("stops", Stop.self) { $0.stops = $1 }
        listen("packages", Package.self) { $0.packages = $1 }
        listen("tasks", LocationTask.self) { $0.tasks = $1 }
        listen("outcomes", DeliveryOutcome.self) { $0.outcomes = $1 }
        listen("photos", DeliveryPhoto.self) { $0.photos = $1 }
        return ListenerToken { registrations.forEach { $0.remove() } }
    }

    func fetchRoute(_ id: RouteID) async throws -> RouteSnapshot? {
        let ref = routeRef(id)
        let routeDoc = try await ref.getDocument()
        guard routeDoc.exists else { return nil }
        let route = try routeDoc.data(as: Route.self, decoder: decoder)
        async let stops = ref.collection("stops").getDocuments()
        async let packages = ref.collection("packages").getDocuments()
        async let outcomes = ref.collection("outcomes").getDocuments()
        async let tasks = ref.collection("tasks").getDocuments()
        async let photos = ref.collection("photos").getDocuments()
        let (s, p, o, t, f) = try await (stops, packages, outcomes, tasks, photos)
        return RouteSnapshot(
            route: route,
            stops: try s.documents.map { try $0.data(as: Stop.self, decoder: decoder) },
            packages: try p.documents.map { try $0.data(as: Package.self, decoder: decoder) },
            outcomes: try o.documents.map { try $0.data(as: DeliveryOutcome.self, decoder: decoder) },
            photos: try f.documents.map { try $0.data(as: DeliveryPhoto.self, decoder: decoder) },
            tasks: try t.documents.map { try $0.data(as: LocationTask.self, decoder: decoder) }
        )
    }

    /// A network-confirmed, completely decoded operational read. A cached collection, pending SDK
    /// write or revision changing while collections load cannot replace the protected snapshot.
    func fetchVerifiedRoute(_ id: RouteID) async throws -> RouteSnapshot? {
        guard Auth.auth(app: db.app).currentUser?.uid == uid else { throw ReplayFailure.authentication }
        let ref = routeRef(id)
        let before = try await ref.getDocument(source: .server)
        guard !before.metadata.isFromCache, !before.metadata.hasPendingWrites else { throw ReplayFailure.unavailable }
        guard before.exists else { return nil }
        let route = try before.data(as: Route.self, decoder: decoder)
        async let stops = ref.collection("stops").getDocuments(source: .server)
        async let packages = ref.collection("packages").getDocuments(source: .server)
        async let tasks = ref.collection("tasks").getDocuments(source: .server)
        async let outcomes = ref.collection("outcomes").getDocuments(source: .server)
        async let photos = ref.collection("photos").getDocuments(source: .server)
        let (s, p, t, o, f) = try await (stops, packages, tasks, outcomes, photos)
        guard [s, p, t, o, f].allSatisfy({ !$0.metadata.isFromCache && !$0.metadata.hasPendingWrites }) else {
            throw ReplayFailure.unavailable
        }
        let result = RouteSnapshot(route: route,
            stops: try s.documents.map { try $0.data(as: Stop.self, decoder: decoder) },
            packages: try p.documents.map { try $0.data(as: Package.self, decoder: decoder) },
            outcomes: try o.documents.map { try $0.data(as: TaskOutcome.self, decoder: decoder) },
            photos: try f.documents.map { try $0.data(as: DeliveryPhoto.self, decoder: decoder) },
            tasks: try t.documents.map { try $0.data(as: LocationTask.self, decoder: decoder) })
        let after = try await ref.getDocument(source: .server)
        guard !after.metadata.isFromCache, !after.metadata.hasPendingWrites, after.exists,
              try after.data(as: Route.self, decoder: decoder) == route,
              Auth.auth(app: db.app).currentUser?.uid == uid else { throw ReplayFailure.unavailable }
        return result
    }

    // MARK: Durable command transport

    /// Absence is returned only by an authenticated server read. Cache/unavailability or a malformed
    /// singleton can never erase the protected execution context or make another route safe to start.
    func fetchVerifiedExecutionSession() async throws -> RouteExecutionSession? {
        guard Auth.auth(app: db.app).currentUser?.uid == uid else { throw ReplayFailure.authentication }
        let snapshot = try await executionRef.getDocument(source: .server)
        guard !snapshot.metadata.isFromCache, !snapshot.metadata.hasPendingWrites else { throw ReplayFailure.unavailable }
        guard Auth.auth(app: db.app).currentUser?.uid == uid else { throw ReplayFailure.authentication }
        guard let data = snapshot.data() else { return nil }
        if let schema = data["schemaVersion"] as? Int, schema != 1 { throw LocalPersistenceFailure.unsupportedSchema(schema) }
        guard Set(data.keys) == FirestoreReplayPlan.executionKeys else {
            throw LocalPersistenceFailure.corrupt("Server route execution has unsupported or missing fields.")
        }
        let value: RouteExecutionSession
        do { value = try snapshot.data(as: RouteExecutionSession.self, decoder: decoder) }
        catch { throw LocalPersistenceFailure.corrupt("Server route execution couldn't be decoded.") }
        guard value.isValid,
              value.id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil,
              value.routeID.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil,
              value.transitionCount != 0 || abs(value.changedAt.timeIntervalSince(value.startedAt)) < 0.000_002 else {
            throw LocalPersistenceFailure.corrupt("Server route execution is invalid.")
        }
        return value
    }

    /// Effects and their receipt are one server transaction. The source-server receipt read after
    /// commit is the acknowledgement evidence; callback success alone is deliberately insufficient.
    func replay(_ command: DurableCommand) async -> RemoteReplayResult {
        guard command.accountID == uid, Auth.auth(app: db.app).currentUser?.uid == uid else {
            return .authentication("Sign in with the account that recorded this route's work.")
        }
        guard command.schemaVersion == 1, command.sequence > 0, command.baseRevision >= 0,
              !command.ops.isEmpty, command.ops.allSatisfy({ op in
                  if case let .transitionExecution(routeID, _, session) = op { return routeID == command.routeID && session.routeID == routeID }
                  return op.documentKey == "routes/\(command.routeID)" || op.documentKey.hasPrefix("routes/\(command.routeID)/")
              }),
              command.payloadDigest.count == 64 else {
            return .blocked("A saved command is invalid or belongs to another route. Its intent has been preserved.")
        }
        do {
            guard command.payloadDigest == (try ActiveRoutePersistence.commandDigest(command)) else {
                return .blocked("A saved command's checksum doesn't match. Its original data has been preserved.")
            }
            let plan = try FirestoreReplayPlan(command: command, route: routeRef(command.routeID), encoder: encoder)
            // Transactions can execute their callback against SDK-held reads. Require a server
            // receipt read first so an offline cache cannot turn validation into a rejection.
            let existing = try await plan.receipt.getDocument(source: .server)
            guard !existing.metadata.isFromCache, !existing.metadata.hasPendingWrites else {
                return .retryable("Waiting for a server connection before replay.")
            }
            if let data = existing.data() {
                return plan.matchesReceipt(data) ? .verified : .blocked("A command receipt has conflicting intent. Saved work has been preserved.")
            }
            try await plan.execute(on: db)
            guard Auth.auth(app: db.app).currentUser?.uid == uid else {
                return .authentication("Sign in with the original account to verify this saved command.")
            }
            let receipt = try await plan.receipt.getDocument(source: .server)
            guard !receipt.metadata.isFromCache, !receipt.metadata.hasPendingWrites,
                  let data = receipt.data(), plan.matchesReceipt(data) else {
                return .retryable("Waiting to verify the server's acknowledgement.")
            }
            return .verified
        } catch let failure as ReplayFailure {
            return await confirmReplayFailure(failure, routeID: command.routeID)
        } catch let failure as LocalPersistenceFailure {
            return .blocked(failure.localizedDescription)
        } catch {
            let ns = error as NSError
            if ns.domain == ReplayFailure.domain { return await confirmReplayFailure(ReplayFailure.from(ns), routeID: command.routeID) }
            switch FirestoreErrorCode.Code(rawValue: ns.code) {
            case .unauthenticated: return .authentication("Sign in again to synchronize saved work.")
            case .permissionDenied: return .blocked("The server rejected this saved change. Your local work has been preserved for recovery.")
            case .notFound: return .blocked("The route or work no longer exists on the server. Your local work has been preserved.")
            case .invalidArgument, .failedPrecondition, .dataLoss:
                return .blocked("The server couldn't apply this saved change safely. Your local work has been preserved.")
            default: return .retryable("Saved on this iPhone. Synchronization will retry when the server is available.")
            }
        }
    }
    private func confirmReplayFailure(_ failure: ReplayFailure, routeID: RouteID) async -> RemoteReplayResult {
        guard Auth.auth(app: db.app).currentUser?.uid == uid else { return .authentication("Sign in with the original account.") }
        do {
            let server = try await routeRef(routeID).getDocument(source: .server)
            guard !server.metadata.isFromCache, !server.metadata.hasPendingWrites else { return .retryable("Server reconciliation is unavailable.") }
            return failure.result
        } catch {
            guard Auth.auth(app: db.app).currentUser?.uid == uid else { return .authentication("Sign in with the original account.") }
            return .retryable("Server reconciliation is unavailable. Saved work remains pending.")
        }
    }

    // MARK: Writes

    nonisolated static let routeOptionalKeys = ["start", "end", "latestArrivalMinute", "breakRule", "appliedRequestID", "appliedRevision", "nextStopOverrideID", "startedAt", "completedAt", "archivedAt", "summary", "plannedDistance"]

    @discardableResult
    func commit(_ change: ChangeSet) -> LocalCommitResult {
        let batch = db.batch()
        do {
            for op in change.ops { try add(op, to: batch) }
        } catch {
            AppLog.sync.error("Encoding failed: \(error.localizedDescription, privacy: .public)")
            return .failed(.storage(error.localizedDescription))
        }
        let journalID = change.critical ? journal.begin(change) : nil
        if change.critical, let failure = journal.lastPersistenceFailure { return .failed(failure) }
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
        // This compatibility path only acknowledges SDK queueing. Production wraps this transport
        // with the transactional protected backend and never uses this as its driver boundary.
        return .committed(LocalCommitAck(commandIDs: journalID.map { [$0] } ?? [], syncPending: true))
    }

    func retry(_ entry: SyncJournal.Entry) {
        var operations = entry.ops.map(\.changeOp)
        var versionedRoutes = Set(entry.ops.compactMap { op -> RouteID? in
            if case let .bumpRouteRevision(routeID, _) = op { return routeID }
            return nil
        })
        // Pre-WP1 journal payloads omitted route writes. Explicitly retrying them must invalidate
        // proposals too, without reconstructing or replaying the route's old settings. The minimum
        // of 1 is only the valid route lower bound; this payload has no historical baseline/receipt.
        for op in entry.ops where versionedRoutes.insert(op.routeID).inserted {
            operations.append(.bumpRouteRevision(op.routeID, expectedMinimum: 1))
        }
        // Keep the original intent until its replacement has at least reached the compatibility
        // journal. A failed local encode must never erase the only retry payload.
        if commit(ChangeSet(operations, label: entry.label, critical: true)).isCommitted {
            journal.discard(entry.id)
        }
    }

    private func add(_ op: ChangeOp, to batch: WriteBatch) throws {
        switch op {
        case let .createRoute(route):
            batch.setData(try Self.routeData(route), forDocument: routeRef(route.id))
        case let .updateRoute(route, bump):
            var data = try Self.routeData(route)
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
        case let .bumpRouteRevision(rid, _):
            batch.updateData(["inputRevision": FieldValue.increment(Int64(1))], forDocument: routeRef(rid))
        case let .putStop(rid, stop):
            try batch.setData(from: stop, forDocument: routeRef(rid).collection("stops").document(stop.id), encoder: encoder)
        case let .deleteStop(rid, id):
            batch.deleteDocument(routeRef(rid).collection("stops").document(id))
        case let .putPackage(rid, p):
            try batch.setData(from: p, forDocument: routeRef(rid).collection("packages").document(p.id), encoder: encoder)
        case let .deletePackage(rid, id):
            batch.deleteDocument(routeRef(rid).collection("packages").document(id))
        case let .putTask(rid, task):
            try batch.setData(from: task, forDocument: routeRef(rid).collection("tasks").document(task.id), encoder: encoder)
        case let .deleteTask(rid, id):
            batch.deleteDocument(routeRef(rid).collection("tasks").document(id))
        case let .createOutcome(rid, o):
            try batch.setData(from: o, forDocument: routeRef(rid).collection("outcomes").document(o.id), encoder: encoder)
        case let .voidOutcome(rid, id, at):
            batch.updateData(["voidedAt": Timestamp(date: at)], forDocument: routeRef(rid).collection("outcomes").document(id))
        case let .putPhoto(rid, p):
            try batch.setData(from: p, forDocument: routeRef(rid).collection("photos").document(p.id), encoder: encoder)
        case let .deletePhoto(rid, id):
            batch.deleteDocument(routeRef(rid).collection("photos").document(id))
        case .transitionExecution:
            // A batch cannot perform the account-wide compare-and-set. Never offer SDK queueing
            // as acknowledgement of a lifecycle action; production uses the durable transport.
            throw LocalPersistenceFailure.conflict("Route execution requires protected local persistence.")
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

    /// Work progress is derived from task definitions/outcomes. Persisting its redundant summary
    /// here exceeds the rules expression budget on otherwise valid warehouse close-out records.
    static func routeData(_ route: Route) throws -> [String: Any] {
        var persisted = route
        persisted.summary?.work = nil
        return try Firestore.Encoder().encode(persisted)
    }

    /// After relaunch, entries whose acknowledgement was never received are checked against the server
    /// once all queued writes have been sent. Anything not present is marked failed for Retry.
    func reconcileJournal() async {
        let pendingEntries = journal.pending
        guard !pendingEntries.isEmpty else { return }
        do { try await db.waitForPendingWrites() } catch { return }
        for entry in pendingEntries {
            var verified: Bool? = true
            for op in entry.ops {
                let result = await verify(op)
                if result != true { verified = result; break }
            }
            if verified == true { journal.succeeded(entry.id) }
            else if verified == false { journal.failed(entry.id, message: "This change didn't reach the server.") }
        }
    }

    private func verify(_ op: JournalOp) async -> Bool? {
        do {
            switch op {
            case let .createOutcome(rid, o):
                let document = try await routeRef(rid).collection("outcomes").document(o.id).getDocument(source: .server)
                guard document.exists else { return false }
                var stored = try document.data(as: TaskOutcome.self, decoder: decoder)
                guard abs(stored.recordedAt.timeIntervalSince(o.recordedAt)) < 0.000_002 else { return false }
                // A later Undo is independent of the original immutable event's acknowledgement.
                // Existence alone cannot acknowledge a different event payload at the same ID.
                var intended = o
                stored.voidedAt = nil; intended.voidedAt = nil
                stored.recordedAt = intended.recordedAt
                return stored == intended
            case let .voidOutcome(rid, id, at):
                let document = try await routeRef(rid).collection("outcomes").document(id).getDocument(source: .server)
                guard let stored = document.data()?["voidedAt"] as? Timestamp else { return false }
                return abs(stored.dateValue().timeIntervalSince(at)) < 0.000_002
            case let .putStop(rid, s):
                let document = try await routeRef(rid).collection("stops").document(s.id).getDocument(source: .server)
                guard let stored = document.data() else { return false }
                return FirestoreReplayPlan.equal(stored, try encoder.encode(s))
            case let .putPackage(rid, p):
                let document = try await routeRef(rid).collection("packages").document(p.id).getDocument(source: .server)
                guard let stored = document.data() else { return false }
                return FirestoreReplayPlan.equal(stored, try encoder.encode(p))
            case let .putTask(rid, task):
                let document = try await routeRef(rid).collection("tasks").document(task.id).getDocument(source: .server)
                guard document.exists else { return false }
                // An older definition at the same ID is not acknowledgement of an edited task.
                var stored = try document.data(as: LocationTask.self, decoder: decoder)
                guard abs(stored.createdAt.timeIntervalSince(task.createdAt)) < 0.000_002,
                      abs(stored.updatedAt.timeIntervalSince(task.updatedAt)) < 0.000_002 else { return false }
                // Date's binary representation can change slightly through journal JSON/Timestamp.
                stored.createdAt = task.createdAt; stored.updatedAt = task.updatedAt
                return stored == task
            case let .bumpRouteRevision(rid, minimum):
                let value = try await routeRef(rid).getDocument(source: .server).get("inputRevision") as? Int
                return value.map { $0 >= minimum } ?? false
            case let .deleteStop(rid, id):
                return try await !routeRef(rid).collection("stops").document(id).getDocument(source: .server).exists
            case let .deletePackage(rid, id):
                return try await !routeRef(rid).collection("packages").document(id).getDocument(source: .server).exists
            case let .deleteTask(rid, id):
                return try await !routeRef(rid).collection("tasks").document(id).getDocument(source: .server).exists
            }
        } catch {
            return nil // Unknown (offline/auth/read error): retain the journal entry.
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

/// Accumulates the route and its five collections into a single snapshot.
@MainActor
private final class RouteListenerState {
    let routeID: RouteID
    let onChange: (RouteSnapshotEnvelope?) -> Void
    var route: Route?
    var routeExists = true
    var stops: [Stop] = []
    var packages: [Package] = []
    var tasks: [LocationTask] = []
    var outcomes: [DeliveryOutcome] = []
    var photos: [DeliveryPhoto] = []
    var pending = Set<String>()
    var fromCache = true
    var cachedCollections = Set<String>()
    var loaded = Set<String>()
    var readIssues: [String: String] = [:]

    init(routeID: RouteID, onChange: @escaping (RouteSnapshotEnvelope?) -> Void) {
        self.routeID = routeID
        self.onChange = onChange
    }

    func setPending(_ key: String, _ isPending: Bool) {
        if isPending { pending.insert(key) } else { pending.remove(key) }
    }

    func setCache(_ key: String, _ isCached: Bool) {
        if isCached { cachedCollections.insert(key) } else { cachedCollections.remove(key) }
        fromCache = !cachedCollections.isEmpty
    }

    func replacePending(prefix: String, with keys: [String]) {
        pending = pending.filter { !$0.hasPrefix(prefix) }.union(keys)
    }

    func failReading(_ name: String) {
        readIssues[name] = "Some route \(name) couldn't be read. Retry or update ParcelPilot before continuing."
        loaded.insert(name)
    }

    func emit() {
        guard loaded.contains("route") else { return }
        guard routeExists, let route else {
            // An absent cached root is not evidence of remote deletion. The protected backend must
            // retain its loaded route until a server-confirmed complete read says otherwise.
            if !fromCache { onChange(nil) }
            return
        }
        guard loaded.isSuperset(of: ["stops", "packages", "tasks", "outcomes", "photos"]) else { return }
        onChange(RouteSnapshotEnvelope(snapshot: RouteSnapshot(route: route, stops: stops, packages: packages, outcomes: outcomes, photos: photos, tasks: tasks), pendingKeys: pending, fromCache: fromCache, readIssues: readIssues.keys.sorted().compactMap { readIssues[$0] }))
    }
}

/// The transaction closure runs on Firebase's queue and may run more than once. All values here are
/// prepared before entry; it performs no local writes, UI effects or command lifecycle mutations.
nonisolated private struct FirestoreReplayPlan: @unchecked Sendable {
    static let executionKeys = Set(["id", "routeID", "schemaVersion", "state", "startedAt", "changedAt", "transitionCount"])
    struct Mutation {
        var op: ChangeOp
        var ref: DocumentReference
        var data: [String: Any]?
    }
    struct Baseline {
        var ref: DocumentReference
        var data: [String: Any]?
    }
    let command: DurableCommand
    let route: DocumentReference
    let receipt: DocumentReference
    let mutations: [Mutation]
    let reads: [DocumentReference]
    let baselines: [Baseline]
    let targetRevision: Int
    let createsRoute: Bool
    let changesWork: Bool
    let execution: DocumentReference
    let expectedExecution: [String: Any]?
    let changesExecution: Bool
    let closesRoute: Bool

    @MainActor init(command: DurableCommand, route: DocumentReference, encoder: Firestore.Encoder) throws {
        self.command = command; self.route = route
        receipt = route.collection("mutationReceipts").document(command.id)
        execution = route.parent.parent!.collection("execution").document("current")
        var mutations: [Mutation] = []
        var targets: [String: DocumentReference] = [route.path: route]
        var bump = false
        var minimum = command.baseRevision
        var creates = false
        var work = false
        var executionChanges = false
        var executionExpected: [String: Any]?
        var closing = false
        for op in command.ops {
            let ref: DocumentReference
            let data: [String: Any]?
            switch op {
            case let .createRoute(value):
                ref = route; data = try Self.routeFields(value, encoder: encoder)
                creates = true; minimum = max(minimum, value.inputRevision)
            case let .updateRoute(value, versioned):
                ref = route; data = try Self.routeFields(value, encoder: encoder)
                bump = bump || versioned
                closing = closing || value.status == .completed || value.status == .archived
            case let .bumpRouteRevision(_, expected):
                ref = route; data = nil; bump = true; minimum = max(minimum, expected)
            case let .putStop(_, value):
                ref = route.collection("stops").document(value.id); data = try encoder.encode(value); work = true
            case let .deleteStop(_, id):
                ref = route.collection("stops").document(id); data = nil; work = true
            case let .putPackage(_, value):
                ref = route.collection("packages").document(value.id); data = try encoder.encode(value); work = true
                let target = route.collection("stops").document(value.stopID); targets[target.path] = target
            case let .deletePackage(_, id):
                ref = route.collection("packages").document(id); data = nil; work = true
            case let .putTask(_, value):
                ref = route.collection("tasks").document(value.id); data = try encoder.encode(value); work = true
                let target = route.collection("stops").document(value.stopID); targets[target.path] = target
                if let id = value.packageID {
                    let target = route.collection("packages").document(id); targets[target.path] = target
                }
            case let .deleteTask(_, id):
                ref = route.collection("tasks").document(id); data = nil; work = true
            case let .createOutcome(_, value):
                ref = route.collection("outcomes").document(value.id); data = try encoder.encode(value); work = true
                let stop = route.collection("stops").document(value.stopID); targets[stop.path] = stop
                let target = value.packageID.map { route.collection("packages").document($0) }
                    ?? route.collection("tasks").document(value.targetTaskID)
                targets[target.path] = target
            case let .voidOutcome(_, id, at):
                ref = route.collection("outcomes").document(id); data = ["voidedAt": Timestamp(date: at)]; work = true
            case let .putPhoto(_, value):
                ref = route.collection("photos").document(value.id); data = try encoder.encode(value)
                let stop = route.collection("stops").document(value.stopID); targets[stop.path] = stop
            case let .deletePhoto(_, id):
                ref = route.collection("photos").document(id); data = nil
            case let .transitionExecution(routeID, expected, session):
                guard !executionChanges, routeID == command.routeID, session.routeID == routeID else { throw ReplayFailure.executionConflict }
                do { try RouteExecutionSession.validateTransition(from: expected, to: session) }
                catch { throw ReplayFailure.executionConflict }
                ref = execution; data = try encoder.encode(session)
                executionExpected = try expected.map { try encoder.encode($0) }
                executionChanges = true
            }
            mutations.append(Mutation(op: op, ref: ref, data: data))
            targets[ref.path] = ref
        }
        if closing { targets[execution.path] = execution }
        var baselines: [Baseline] = []
        if let recorded = command.baselines {
            let required = Set(command.ops.compactMap { op -> String? in
                switch op {
                case .putStop, .deleteStop, .putPackage, .deletePackage, .putTask, .deleteTask: return op.documentKey
                default: return nil
                }
            })
            guard Set(recorded.map(\.documentKey)) == required else { throw ReplayFailure.payloadConflict }
            let prefix = "routes/\(command.routeID)/"
            for baseline in recorded {
                guard baseline.documentKey.hasPrefix(prefix) else { throw ReplayFailure.payloadConflict }
                let components = baseline.documentKey.dropFirst(prefix.count).split(separator: "/").map(String.init)
                guard components.count == 2 else { throw ReplayFailure.payloadConflict }
                let data: [String: Any]?
                if let payload = baseline.payload {
                    switch components[0] {
                    case "stops": data = try encoder.encode(ActiveRoutePersistence.decode(Stop.self, payload))
                    case "packages": data = try encoder.encode(ActiveRoutePersistence.decode(Package.self, payload))
                    case "tasks": data = try encoder.encode(ActiveRoutePersistence.decode(LocationTask.self, payload))
                    default: throw ReplayFailure.payloadConflict
                    }
                } else {
                    guard ["stops", "packages", "tasks"].contains(components[0]) else { throw ReplayFailure.payloadConflict }
                    data = nil
                }
                let ref = route.collection(components[0]).document(components[1])
                targets[ref.path] = ref
                baselines.append(Baseline(ref: ref, data: data))
            }
        }
        self.mutations = mutations
        self.baselines = baselines
        reads = targets.values.sorted { $0.path < $1.path }
        targetRevision = max(1, minimum, command.baseRevision + (bump ? 1 : 0))
        createsRoute = creates; changesWork = work
        changesExecution = executionChanges; expectedExecution = executionExpected; closesRoute = closing
    }

    static func routeFields(_ value: Route, encoder: Firestore.Encoder) throws -> [String: Any] {
        var route = value; route.summary?.work = nil
        return try encoder.encode(route)
    }

    /// These Objective-C SDK callbacks execute on Firebase's queue. Construct them outside a
    /// MainActor lexical context so Swift 6 never attaches the UI executor assertion to them.
    func execute(on db: Firestore) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            db.runTransaction({ transaction, errorPointer in
                do { try self.apply(to: transaction); return true }
                catch { errorPointer?.pointee = error as NSError; return nil }
            }, completion: { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    func matchesReceipt(_ data: [String: Any]) -> Bool {
        Set(data.keys) == Set(["id", "schemaVersion", "accountID", "routeID", "sequence", "payloadDigest", "baseRevision", "appliedRevision", "appliedAt"])
            && data["appliedAt"] is Timestamp
            && data["schemaVersion"] as? Int == 1 && data["id"] as? String == command.id
            && data["accountID"] as? String == command.accountID && data["routeID"] as? String == command.routeID
            && (data["sequence"] as? NSNumber)?.int64Value == command.sequence
            && data["payloadDigest"] as? String == command.payloadDigest
            && data["baseRevision"] as? Int == command.baseRevision
            && data["appliedRevision"] as? Int == targetRevision
    }

    func apply(to transaction: Transaction) throws {
        let existingReceipt = try transaction.getDocument(receipt)
        if existingReceipt.exists {
            guard let data = existingReceipt.data(), matchesReceipt(data) else { throw ReplayFailure.receiptConflict }
            return
        }
        var documents: [String: [String: Any]] = [:]
        for ref in reads {
            let snapshot = try transaction.getDocument(ref)
            if let data = snapshot.data() { documents[ref.path] = data }
        }
        let root = documents[route.path]
        if let root {
            guard !createsRoute, root["id"] as? String == command.routeID,
                  root["inputRevision"] as? Int == command.baseRevision else { throw ReplayFailure.revisionConflict }
            if let identity = command.baseRouteCreatedAt {
                guard let actual = root["createdAt"] as? Timestamp,
                      abs(actual.dateValue().timeIntervalSince(identity)) < 0.000_002 else { throw ReplayFailure.routeReplaced }
            }
            if let updatedAt = command.baseRouteUpdatedAt {
                guard let actual = root["updatedAt"] as? Timestamp,
                      abs(actual.dateValue().timeIntervalSince(updatedAt)) < 0.000_002 else { throw ReplayFailure.revisionConflict }
            }
            if changesWork, let status = root["status"] as? String, ["completed", "archived"].contains(status) {
                throw ReplayFailure.closedRoute
            }
        } else {
            guard createsRoute, command.baseRevision == 0 else { throw ReplayFailure.missingRoute }
        }
        if changesExecution {
            switch (expectedExecution, documents[execution.path]) {
            case (nil, nil): break
            case let (expected?, actual?):
                guard Self.equal(expected, actual) else { throw ReplayFailure.executionConflict }
            default: throw ReplayFailure.executionConflict
            }
        }
        for baseline in baselines {
            switch (baseline.data, documents[baseline.ref.path]) {
            case (nil, nil): break
            case let (expected?, actual?):
                guard Self.equal(expected, actual) else { throw ReplayFailure.payloadConflict }
            default: throw ReplayFailure.payloadConflict
            }
        }
        // Validate references against the final command image, including stop/package definitions
        // created in this transaction. Read everything before issuing the first server write.
        var final = documents
        for mutation in mutations where mutation.ref != route {
            switch mutation.op {
            case .deleteStop, .deletePackage, .deleteTask, .deletePhoto: final[mutation.ref.path] = nil
            case .voidOutcome: break
            default: if let data = mutation.data { final[mutation.ref.path] = data }
            }
        }
        let finalRoot = mutations.last(where: { $0.ref == route && $0.data != nil })?.data ?? root
        let finalExecution = final[execution.path]
        if changesExecution {
            guard let state = finalExecution?["state"] as? String,
                  let status = finalRoot?["status"] as? String else { throw ReplayFailure.executionConflict }
            // Finish and route close-out are one logical action. Pausing/resuming never closes or
            // changes the route, while Start cannot revive a closed historical record.
            if state == "finished" {
                guard ["completed", "archived"].contains(status) else { throw ReplayFailure.executionConflict }
            } else {
                guard ["planning", "active"].contains(status) else { throw ReplayFailure.closedRoute }
            }
        }
        if closesRoute, finalExecution?["routeID"] as? String == command.routeID,
           finalExecution?["state"] as? String != "finished" { throw ReplayFailure.executionConflict }
        var writes: [Mutation] = []
        for mutation in mutations where mutation.ref != route {
            let current = documents[mutation.ref.path]
            switch mutation.op {
            case let .createOutcome(_, value):
                if let current {
                    var stored = current; var intended = mutation.data ?? [:]
                    stored["voidedAt"] = nil; intended["voidedAt"] = nil
                    guard Self.equal(stored, intended) else { throw ReplayFailure.payloadConflict }
                    continue
                }
                let target = value.packageID.map { route.collection("packages").document($0) }
                    ?? route.collection("tasks").document(value.targetTaskID)
                guard final[target.path]?["stopID"] as? String == value.stopID,
                      final[route.collection("stops").document(value.stopID).path] != nil else { throw ReplayFailure.missingTarget }
            case .voidOutcome:
                guard let current else { throw ReplayFailure.missingTarget }
                if let voided = current["voidedAt"] {
                    guard let expected = mutation.data?["voidedAt"], Self.equalValue(voided, expected) else { throw ReplayFailure.payloadConflict }
                    continue
                }
            case let .putPackage(_, value):
                guard final[route.collection("stops").document(value.stopID).path] != nil else { throw ReplayFailure.missingTarget }
            case let .putTask(_, value):
                guard final[route.collection("stops").document(value.stopID).path] != nil else { throw ReplayFailure.missingTarget }
                if let id = value.packageID {
                    guard final[route.collection("packages").document(id).path]?["stopID"] as? String == value.stopID else { throw ReplayFailure.missingTarget }
                }
                if let current {
                    guard current["stopID"] as? String == value.stopID, current["kind"] as? String == value.kind.rawValue,
                          current["packageID"] as? String == value.packageID else { throw ReplayFailure.payloadConflict }
                }
            case let .putPhoto(_, value):
                guard final[route.collection("stops").document(value.stopID).path] != nil else { throw ReplayFailure.missingTarget }
                if let current {
                    guard Self.equal(current, mutation.data ?? [:]) else { throw ReplayFailure.payloadConflict }
                    continue
                }
            case .transitionExecution:
                var normalized = mutation
                if let current, var data = mutation.data {
                    if current["id"] as? String == data["id"] as? String {
                        // Preserve the actual immutable server timestamp, including its exact
                        // microsecond wire form, rather than re-encoding the local Date.
                        data["startedAt"] = current["startedAt"]
                    }
                    if let before = current["changedAt"] as? Timestamp,
                       let after = data["changedAt"] as? Timestamp,
                       after.dateValue() < before.dateValue() {
                        guard abs(after.dateValue().timeIntervalSince(before.dateValue())) < 0.000_002 else {
                            throw ReplayFailure.executionConflict
                        }
                        data["changedAt"] = before
                        if data["transitionCount"] as? Int == 0 { data["startedAt"] = before }
                    }
                    normalized.data = data
                }
                writes.append(normalized)
                continue
            default: break
            }
            writes.append(mutation)
        }
        var routeData: [String: Any]?
        for mutation in mutations where mutation.ref == route {
            if let data = mutation.data { routeData = data }
        }
        if var data = routeData {
            data["inputRevision"] = targetRevision
            if createsRoute { transaction.setData(data, forDocument: route) }
            else {
                data["createdAt"] = nil
                for key in FirestoreRouteBackend.routeOptionalKeys where data[key] == nil { data[key] = FieldValue.delete() }
                transaction.setData(data, forDocument: route, mergeFields: Array(data.keys))
            }
        } else if targetRevision != command.baseRevision {
            transaction.updateData(["inputRevision": targetRevision], forDocument: route)
        }
        for mutation in writes {
            switch mutation.op {
            case .deleteStop, .deletePackage, .deleteTask, .deletePhoto: transaction.deleteDocument(mutation.ref)
            case .voidOutcome: transaction.updateData(mutation.data ?? [:], forDocument: mutation.ref)
            default: transaction.setData(mutation.data ?? [:], forDocument: mutation.ref)
            }
        }
        transaction.setData([
            "id": command.id, "schemaVersion": 1, "accountID": command.accountID, "routeID": command.routeID,
            "sequence": command.sequence, "payloadDigest": command.payloadDigest, "baseRevision": command.baseRevision,
            "appliedRevision": targetRevision, "appliedAt": FieldValue.serverTimestamp()
        ], forDocument: receipt)
    }

    static func equal(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        guard Set(lhs.keys) == Set(rhs.keys) else { return false }
        return lhs.allSatisfy { key, value in rhs[key].map { equalValue(value, $0) } ?? false }
    }
    static func equalValue(_ lhs: Any, _ rhs: Any) -> Bool {
        if let lhs = lhs as? Timestamp, let rhs = rhs as? Timestamp {
            // Firestore truncates to microseconds. Date/JSON/Timestamp binary conversions can add
            // a fraction of a microsecond; allow only this bounded wire error, not clock drift.
            return abs(lhs.dateValue().timeIntervalSince(rhs.dateValue())) < 0.000_002
        }
        if let lhs = lhs as? [String: Any], let rhs = rhs as? [String: Any] { return equal(lhs, rhs) }
        if let lhs = lhs as? [Any], let rhs = rhs as? [Any] {
            return lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { equalValue($0, $1) }
        }
        guard let lhs = lhs as? NSObject, let rhs = rhs as? NSObject else { return false }
        return lhs.isEqual(rhs)
    }
}

nonisolated private enum ReplayFailure: Int, Error, CustomNSError {
    case authentication = 1, unavailable, receiptConflict, revisionConflict, routeReplaced, closedRoute, missingRoute, payloadConflict, missingTarget, executionConflict
    static let domain = "ParcelPilot.DurableReplay"
    static var errorDomain: String { domain }
    var errorCode: Int { rawValue }
    static func from(_ error: NSError) -> ReplayFailure { ReplayFailure(rawValue: error.code) ?? .unavailable }
    var result: RemoteReplayResult {
        switch self {
        case .authentication: return .authentication("Sign in with the original account to synchronize saved work.")
        case .unavailable: return .retryable("Waiting for a complete server acknowledgement.")
        case .receiptConflict, .payloadConflict: return .blocked("A saved event identity conflicts with different server data. Your intent has been preserved.")
        case .revisionConflict: return .blocked("This route changed on the server. Saved work needs recovery before further replay.")
        case .routeReplaced: return .blocked("The server route has been replaced. Saved work has been preserved for recovery.")
        case .closedRoute: return .blocked("This route was closed on the server. Saved work has been preserved for recovery.")
        case .missingRoute: return .blocked("The route was removed from the server. Saved work has been preserved for recovery.")
        case .missingTarget: return .blocked("A saved work target was removed or moved. Your recorded intent has been preserved.")
        case .executionConflict: return .blocked("Route execution changed on the server or conflicts with another unfinished route. Your local intent has been preserved.")
        }
    }
}
