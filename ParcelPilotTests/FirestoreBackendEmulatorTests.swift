import FirebaseAppCheck
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseFunctions
import FirebaseStorage
import Foundation
import ParcelPilotKit
import Testing
import UIKit
@testable import ParcelPilot

/// The real Firebase iOS SDK against the Auth + Firestore emulators *with the production security
/// rules*. Runs only when the emulators are up:
///   cd firebase && npm run emulators
///   TEST_RUNNER_PP_EMULATOR=1 xcodebuild test ... -only-testing:ParcelPilotTests/FirestoreBackendEmulatorTests \
///     CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
@MainActor
@Suite("Firestore backend against emulators", .serialized, .enabled(if: ProcessInfo.processInfo.environment["PP_EMULATOR"] == "1"))
struct FirestoreBackendEmulatorTests {
    /// The Firebase app of the most recent `environment()`.
    static var current: FirebaseApp?

    /// Each environment gets its own Firebase app (own Auth and Firestore), so switching users can
    /// never send a request with the previous user's credentials.
    static func makeApp(name: String) throws -> FirebaseApp {
        // As in the app's emulator mode: no App Check, so nothing contacts the real App Check service.
        AppCheck.setAppCheckProviderFactory(NoAppCheckProviderFactory())
        let options = FirebaseOptions(googleAppID: "1:123456789012:ios:0123456789abcdef", gcmSenderID: "123456789012")
        options.projectID = AppConfiguration.emulatorProjectID
        options.apiKey = "AIzaSyEmulatorOnlyNotARealKey0000000000"
        options.storageBucket = "\(AppConfiguration.emulatorProjectID).appspot.com"
        FirebaseApp.configure(name: name, options: options)
        let app = try #require(FirebaseApp.app(name: name))
        Auth.auth(app: app).useEmulator(withHost: "127.0.0.1", port: 9099)
        Storage.storage(app: app).useEmulator(withHost: "127.0.0.1", port: 9199)
        Functions.functions(app: app, region: AppConfiguration.firebaseRegion).useEmulator(withHost: "127.0.0.1", port: 5001)
        let db = Firestore.firestore(app: app)
        let settings = FirestoreSettings()
        settings.host = "127.0.0.1:8180"
        settings.isSSLEnabled = false
        settings.cacheSettings = MemoryCacheSettings()
        db.settings = settings
        return app
    }

    func environment() async throws -> (FirestoreRouteBackend, RouteStore, SyncJournal, Firestore, String) {
        let app = try Self.makeApp(name: "pp-emulator-\(UUID().uuidString.prefix(8))")
        Self.current = app
        let auth = Auth.auth(app: app)
        let result = try await auth.signInAnonymously()
        let db = Firestore.firestore(app: app)
        let journal = SyncJournal(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString).json"))
        let backend = FirestoreRouteBackend(uid: result.user.uid, db: db, journal: journal)
        return (backend, RouteStore(backend: backend, generalizedWorkAvailability: .development), journal, db, result.user.uid)
    }

    func waitUntil(_ timeout: TimeInterval = 10, _ condition: () async throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return true }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    func serverRoute(_ db: Firestore, _ uid: String, _ id: RouteID) async throws -> [String: Any] {
        try await db.document("users/\(uid)/routes/\(id)").getDocument(source: .server).data() ?? [:]
    }

    @Test("Warehouse deadline round trips through Firestore and disabling it deletes the optional field")
    func latestArrival() async throws {
        let (_, store, journal, db, uid) = try await environment()
        let warehouse = RoutePlace(label: "Warehouse", located: LocatedPoint(point: GeoPoint(latitude: 48.42, longitude: -123.36), source: .driverPin))
        let route = store.createRoute(name: "Return by", serviceDate: "2026-10-05", timeZoneID: "America/Vancouver", departureMinute: 480, defaultServiceSeconds: 120, start: warehouse, returnToStart: true)
        try await db.waitForPendingWrites()
        #expect(try await waitUntil { store.current?.route.id == route.id })
        var edited = try #require(store.current?.route)
        edited.latestArrivalMinute = 1020
        edited.end = RoutePlace(label: "Unused end")
        store.updateSettings(edited)
        try await db.waitForPendingWrites()
        #expect(try await waitUntil { (try await serverRoute(db, uid, route.id)["latestArrivalMinute"] as? Int) == 1020 })
        #expect(try await waitUntil { store.current?.route.inputRevision == 2 })
        #expect(store.current?.route.latestArrivalMinute == 1020)
        edited = try #require(store.current?.route)
        edited.latestArrivalMinute = nil
        edited.end = nil
        store.updateSettings(edited)
        try await db.waitForPendingWrites()
        #expect(try await waitUntil { (try await serverRoute(db, uid, route.id)["inputRevision"] as? Int) == 3 })
        let saved = try await serverRoute(db, uid, route.id)
        #expect(saved["latestArrivalMinute"] == nil, "Unexpected saved deadline: \(String(describing: saved["latestArrivalMinute"]))")
        #expect(saved["end"] == nil)
        #expect(try await waitUntil { store.current?.route.latestArrivalMinute == nil && store.current?.route.inputRevision == 3 })
        #expect(journal.failed.isEmpty)
    }

    @Test("Route edits that change plan inputs increment inputRevision on the server; decoded routes update cleanly")
    func revisionIncrements() async throws {
        let (_, store, journal, db, uid) = try await environment()
        let route = store.createRoute(name: "Emulator", serviceDate: "2026-10-05", timeZoneID: "America/Vancouver", departureMinute: 480, defaultServiceSeconds: 120, start: nil, returnToStart: false)
        #expect(try await waitUntil { store.current?.route.id == route.id })
        #expect(try await waitUntil { (try await serverRoute(db, uid, route.id)["inputRevision"] as? Int) == 1 })

        // Update using the route as decoded back from Firestore (Timestamp → Date round trip).
        let decoded = try #require(store.current?.route)
        var edited = decoded
        edited.departureMinute = 540
        store.updateSettings(edited)
        #expect(try await waitUntil { (try await serverRoute(db, uid, route.id)["inputRevision"] as? Int) == 2 })
        #expect(try await waitUntil { store.current?.route.inputRevision == 2 })

        // Adding a stop bumps again; renaming does not.
        store.addDelivery(to: store.current!, address: .e1(), status: .pendingVerification, resolution: nil, reviewReasons: [], packages: [PackageDraft()], source: .manual)
        #expect(try await waitUntil { (try await serverRoute(db, uid, route.id)["inputRevision"] as? Int) == 3 })
        store.rename(store.current!.route, to: "Renamed")
        #expect(try await waitUntil { (try await serverRoute(db, uid, route.id)["name"] as? String) == "Renamed" })
        #expect((try await serverRoute(db, uid, route.id)["inputRevision"] as? Int) == 3)
        #expect(journal.failed.isEmpty)
    }

    @Test("Outcomes are append-only on the server: create, void once, journal records success")
    func outcomes() async throws {
        let (backend, store, journal, db, uid) = try await environment()
        let route = store.createRoute(name: "Outcomes", serviceDate: "2026-10-05", timeZoneID: "America/Vancouver", departureMinute: 480, defaultServiceSeconds: 120, start: nil, returnToStart: false)
        #expect(try await waitUntil { store.current?.route.id == route.id })
        let add = store.addDelivery(to: store.current!, address: .e1(), status: .pendingVerification, resolution: nil, reviewReasons: [], packages: [PackageDraft()], source: .scan)
        #expect(try await waitUntil { store.current?.packages.count == 1 })
        let ids = store.record(.delivered, packageIDs: add.packageIDs, stopID: add.stopID, in: store.current!, label: "Delivered")
        let path = "users/\(uid)/routes/\(route.id)/outcomes/\(ids[0])"
        #expect(try await waitUntil { try await db.document(path).getDocument(source: .server).exists })
        #expect(try await waitUntil { journal.entries.isEmpty })
        let intended = try #require(store.current?.outcomes.first { $0.id == ids[0] })
        store.undo(outcomeIDs: ids, in: store.current!)
        #expect(try await waitUntil { try await db.document(path).getDocument(source: .server).get("voidedAt") != nil })
        #expect(try await waitUntil { store.current?.outcomes.first?.voidedAt != nil })
        let revision = try #require(store.current?.route.inputRevision)
        // A stale Undo from the UI is harmless and does not invalidate another proposal.
        store.undo(outcomeIDs: ids, in: store.current!)
        #expect(store.current?.route.inputRevision == revision)
        #expect(journal.failed.isEmpty)

        #expect(try await waitUntil { journal.entries.isEmpty })
        let originalID = journal.begin(ChangeSet([.createOutcome(route.id, intended)], label: "Original event", critical: true))
        var conflicting = intended
        conflicting.note = "A different immutable payload"
        let collisionID = journal.begin(ChangeSet([.createOutcome(route.id, conflicting)], label: "Conflicting event", critical: true))
        await backend.reconcileJournal()
        #expect(!journal.entries.contains { $0.id == originalID }, "The identical original event is acknowledged even after Undo")
        #expect(journal.failed.contains { $0.id == collisionID }, "An existing event ID cannot acknowledge a different immutable payload")
        journal.discard(collisionID)
        // A direct repeated void is still rejected by the append-only server rules.
        backend.commit(ChangeSet([.voidOutcome(route.id, ids[0], at: Date())], label: "Repeated void", critical: true))
        #expect(try await waitUntil { !journal.failed.isEmpty })
    }

    @Test("Task definitions, generalized outcomes and Undo round trip through the real SDK with revision coverage")
    func taskOutcomes() async throws {
        let (backend, store, journal, db, uid) = try await environment()
        let route = store.createRoute(name: "Mixed work", serviceDate: "2026-10-05", timeZoneID: "America/Vancouver", departureMinute: 480, defaultServiceSeconds: 120, start: nil, returnToStart: false)
        #expect(try await waitUntil { store.current?.route.id == route.id })
        let add = store.addDelivery(to: store.current!, address: .e1(), status: .pendingVerification, resolution: nil, reviewReasons: [], packages: [PackageDraft()], source: .manual)
        #expect(try await waitUntil { store.current?.packages.count == 1 })
        let task = LocationTask(stopID: add.stopID, kind: .pickup, title: "Collect return", packageID: add.packageIDs[0])
        let beforeTask = try #require(store.current?.route.inputRevision)
        try store.put(task: task, in: store.current!)
        #expect(try await waitUntil { store.current?.tasks.count == 1 && store.current?.route.inputRevision == beforeTask + 1 })
        let taskPath = "users/\(uid)/routes/\(route.id)/tasks/\(task.id)"
        #expect(try await waitUntil { try await db.document(taskPath).getDocument(source: .server).exists })

        let beforeCompletion = try #require(store.current?.route.inputRevision)
        let ids = store.record(.completed, taskIDs: [task.id], in: store.current!, label: "Pickup complete")
        #expect(ids.count == 1)
        #expect(try await waitUntil { store.current?.route.inputRevision == beforeCompletion + 1 && store.current?.workLedger.status(of: task.id).isSuccessful == true })
        let outcomePath = "users/\(uid)/routes/\(route.id)/outcomes/\(ids[0])"
        let encoded = try #require(try await db.document(outcomePath).getDocument(source: .server).data())
        #expect(encoded["schemaVersion"] as? Int == 2)
        #expect(encoded["taskID"] as? String == task.id)
        #expect(encoded["packageID"] == nil, "The definition's optional association must not change the outcome's target")
        #expect(encoded["kind"] as? String == "completed")
        let fetched = try #require(try await backend.fetchRoute(route.id))
        #expect(fetched.tasks.count == 1)
        #expect(fetched.tasks[0].packageID == add.packageIDs[0])
        #expect(fetched.workLedger.status(of: task.id).isSuccessful)
        #expect(fetched.ledger.status(of: add.packageIDs[0]) == .pending)

        store.undo(outcomeIDs: ids, in: store.current!)
        #expect(try await waitUntil { store.current?.route.inputRevision == beforeCompletion + 2 && store.current?.workLedger.status(of: task.id) == .pending })
        #expect(try await waitUntil { journal.entries.isEmpty })
        #expect((try await serverRoute(db, uid, route.id)["inputRevision"] as? Int) == beforeCompletion + 2)

        var unsaved = task
        unsaved.title = "An unacknowledged edit"
        let pendingID = journal.begin(ChangeSet([.putTask(route.id, unsaved)], label: "Edit pickup", critical: true))
        await backend.reconcileJournal()
        #expect(journal.failed.contains { $0.id == pendingID }, "An existing definition is not acknowledgement of a different edit")
    }

    @Test("Warehouse close-out retains all work while omitting the redundant summary that exceeds the rules budget")
    func warehouseCloseOut() async throws {
        let (backend, store, journal, db, uid) = try await environment()
        let warehouse = RoutePlace(label: "Warehouse", address: .e1(), located: LocatedPoint(point: GeoPoint(latitude: 48.42, longitude: -123.36), source: .driverPin))
        let route = store.createRoute(name: "Warehouse close-out", serviceDate: "2026-10-05", timeZoneID: "America/Vancouver", departureMinute: 480, defaultServiceSeconds: 120, start: warehouse, returnToStart: true)
        try await db.waitForPendingWrites()
        #expect(try await waitUntil { store.current?.route.id == route.id })
        let add = store.addDelivery(to: store.current!, address: .e1(), status: .pendingVerification, resolution: nil, reviewReasons: [], packages: [PackageDraft()], source: .manual)
        try await db.waitForPendingWrites()
        #expect(try await waitUntil { store.current?.packages.count == 1 })
        let task = LocationTask(stopID: add.stopID, kind: .checklist, title: "Close gate")
        try store.put(task: task, in: store.current!)
        try await db.waitForPendingWrites()
        #expect(try await waitUntil { store.current?.tasks.count == 1 })
        store.record(.delivered, packageIDs: add.packageIDs, stopID: add.stopID, in: store.current!, label: "Delivered")
        store.record(.completed, taskIDs: [task.id], in: store.current!, label: "Checklist complete")
        try await db.waitForPendingWrites()
        #expect(try await waitUntil { store.current?.workSummary.completed == 2 })
        var accepted = try #require(store.current?.route)
        accepted.appliedRequestID = "accepted-proposal"
        accepted.appliedRevision = accepted.inputRevision
        accepted.latestArrivalMinute = 1020
        accepted.plannedDistance = PlannedDistance(meters: 1200, provider: .google, calculatedAt: Date(), expiresAt: Date().addingTimeInterval(3600))
        backend.commit(ChangeSet([.updateRoute(accepted, bumpRevision: false)], label: "Accepted proposal fixture"))
        try await db.waitForPendingWrites()
        #expect(try await waitUntil { store.current?.route.appliedRequestID == accepted.appliedRequestID })
        store.finish(try #require(store.current))
        try await db.waitForPendingWrites()
        let saved = try await serverRoute(db, uid, route.id)
        #expect(saved["status"] as? String == "completed")
        #expect((saved["summary"] as? [String: Any])?["work"] == nil)
        let full = try #require(try await backend.fetchRoute(route.id))
        #expect(full.tasks.count == 1 && full.outcomes.count == 2)
        #expect(full.workSummary.completed == 2 && full.workSummary.outstanding == 0)
        #expect(journal.failed.isEmpty)
    }

    @Test("A malformed work document preserves the last complete collection, surfaces a read issue, and blocks outcomes")
    func malformedWorkRead() async throws {
        let (backend, store, _, _, uid) = try await environment()
        let route = store.createRoute(name: "Unreadable work", serviceDate: "2026-10-05", timeZoneID: "America/Vancouver", departureMinute: 480, defaultServiceSeconds: 120, start: nil, returnToStart: false)
        #expect(try await waitUntil { store.current?.route.id == route.id })
        let add = store.addDelivery(to: store.current!, address: .e1(), status: .pendingVerification, resolution: nil, reviewReasons: [], packages: [PackageDraft()], source: .manual)
        #expect(try await waitUntil { store.current?.packages.count == 1 })
        let task = LocationTask(id: "known-task", stopID: add.stopID, kind: .checklist, title: "Known instruction")
        try store.put(task: task, in: store.current!)
        #expect(try await waitUntil { store.current?.tasks.map(\.id) == [task.id] })

        // Emulator-only administrator request models an old/corrupt record that current rules would reject.
        let path = "http://127.0.0.1:8180/v1/projects/\(AppConfiguration.emulatorProjectID)/databases/(default)/documents/users/\(uid)/routes/\(route.id)/tasks/malformed"
        var request = URLRequest(url: try #require(URL(string: path)))
        request.httpMethod = "PATCH"
        request.setValue("Bearer owner", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["fields": ["id": ["stringValue": "malformed"]]])
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try await waitUntil { !store.currentReadIssues.isEmpty })
        #expect(store.current?.tasks.map(\.id) == [task.id], "A partial collection must never replace known work")
        let snapshot = try #require(store.current)
        #expect(store.record(.delivered, packageIDs: add.packageIDs, stopID: add.stopID, in: snapshot, label: "Blocked").isEmpty)
        await #expect(throws: (any Error).self) { try await backend.fetchRoute(route.id) }
    }

    @Test("Explicit Retry upgrades a legacy outcome-only journal payload with a narrow proposal invalidation")
    func legacyJournalRetry() async throws {
        let (backend, store, journal, db, uid) = try await environment()
        let route = store.createRoute(name: "Legacy retry", serviceDate: "2026-10-05", timeZoneID: "America/Vancouver", departureMinute: 480, defaultServiceSeconds: 120, start: nil, returnToStart: false)
        #expect(try await waitUntil { store.current?.route.id == route.id })
        let add = store.addDelivery(to: store.current!, address: .e1(), status: .pendingVerification, resolution: nil, reviewReasons: [], packages: [PackageDraft()], source: .manual)
        #expect(try await waitUntil { store.current?.packages.count == 1 })
        try await db.waitForPendingWrites()
        #expect(try await waitUntil { journal.entries.isEmpty })
        let before = try #require(store.current?.route.inputRevision)
        let outcome = TaskOutcome(id: "legacy-retry-event", packageID: add.packageIDs[0], stopID: add.stopID, kind: .delivered)
        let id = journal.begin(ChangeSet([.createOutcome(route.id, outcome)], label: "Legacy delivered", critical: true))
        journal.failed(id, message: "Previous app did not receive acknowledgement")
        backend.retry(try #require(journal.failed.first))
        #expect(try await waitUntil { journal.entries.isEmpty })
        #expect(try await waitUntil { store.current?.route.inputRevision == before + 1 && store.current?.ledger.status(of: add.packageIDs[0]).isHandled == true })
        #expect((try await serverRoute(db, uid, route.id)["inputRevision"] as? Int) == before + 1)
    }

    @Test("Bulk associated pickups fit rules budgets and copied work has fresh identities without completion history")
    func bulkAssociatedPickupsAndCopy() async throws {
        let (backend, store, journal, db, uid) = try await environment()
        let route = store.createRoute(name: "Bulk work", serviceDate: "2026-10-05", timeZoneID: "America/Vancouver", departureMinute: 480, defaultServiceSeconds: 120, start: nil, returnToStart: false)
        #expect(try await waitUntil { store.current?.route.id == route.id })
        var tasks: [LocationTask] = []
        for index in 0..<8 {
            var address = PostalAddress.e1()
            address.unit = "\(200 + index)"
            let add = store.addDelivery(to: store.current!, address: address, status: .pendingVerification, resolution: nil, reviewReasons: [], packages: [PackageDraft()], source: .manual)
            #expect(try await waitUntil { store.current?.packages.count == index + 1 })
            let task = LocationTask(stopID: add.stopID, kind: .pickup, title: "Return \(index + 1)", packageID: add.packageIDs[0])
            try store.put(task: task, in: store.current!)
            tasks.append(task)
            #expect(try await waitUntil { store.current?.tasks.count == index + 1 })
        }
        try await db.waitForPendingWrites()
        #expect(try await waitUntil { journal.entries.isEmpty })
        let source = try #require(store.current)
        let revision = source.route.inputRevision
        let events = store.record(.completed, taskIDs: tasks.map(\.id), in: source, label: "Eight pickups complete")
        #expect(events.count == 8)
        try await db.waitForPendingWrites()
        #expect(try await waitUntil { journal.entries.isEmpty })
        #expect(try await waitUntil { store.current?.workSummary.completed == 8 && store.current?.route.inputRevision == revision + 2 })
        #expect((try await serverRoute(db, uid, route.id)["inputRevision"] as? Int) == revision + 2)
        let handled = try #require(try await backend.fetchRoute(route.id))
        #expect(handled.outcomes.count == 8)
        #expect(handled.workSummary.pending == 8, "Completing associated pickups must not complete deliveries")

        let copy = try await store.duplicate(handled.route)
        try await db.waitForPendingWrites()
        #expect(try await waitUntil { journal.entries.isEmpty })
        let copied = try #require(try await backend.fetchRoute(copy.id))
        #expect(copied.stops.count == 8)
        #expect(copied.packages.count == 8)
        #expect(copied.tasks.count == 8)
        #expect(copied.outcomes.isEmpty)
        #expect(copied.workSummary.pending == 16)
        #expect(Set(copied.tasks.map(\.id)).isDisjoint(with: Set(tasks.map(\.id))))
        #expect(Set(copied.packages.map(\.id)).isDisjoint(with: Set(handled.packages.map(\.id))))
        for task in copied.tasks {
            #expect(copied.workLedger.status(of: task.id) == .pending)
            #expect(copied.packages.contains { $0.id == task.packageID && $0.stopID == task.stopID })
        }
        #expect(journal.failed.isEmpty)
    }

    @Test("A write the rules reject is undone locally and reported in the sync journal")
    func rejectedWriteIsReported() async throws {
        let (_, store, journal, _, _) = try await environment()
        _ = store.createRoute(name: "Rejected", serviceDate: "2026-10-05", timeZoneID: "America/Vancouver", departureMinute: 480, defaultServiceSeconds: 120, start: nil, returnToStart: false)
        #expect(try await waitUntil { store.current != nil })
        // 'verified' requires a Google building-level resolution; a synthetic one must be refused.
        let synthetic = StopResolution(provider: .emulatorFake, placeID: nil, located: LocatedPoint(point: GeoPoint(latitude: 48.4, longitude: -123.3), source: .emulatorFake), match: .synthetic, resolvedAt: Date())
        store.addDelivery(to: store.current!, address: .e1(), status: .verified, resolution: synthetic, reviewReasons: [], packages: [PackageDraft()], source: .scan)
        #expect(try await waitUntil { !journal.failed.isEmpty })
        #expect(try await waitUntil { store.current?.stops.isEmpty == true })
    }

    @Test("Proof-of-delivery photo: saved offline, survives a relaunch, uploads under the rules, downloads, deletes")
    func photoUpload() async throws {
        let (remote, legacyStore, journal, db, uid) = try await environment()
        let storage = Storage.storage(app: try #require(Self.current))
        let route = legacyStore.createRoute(name: "Photos", serviceDate: "2026-10-05", timeZoneID: "America/Vancouver", departureMinute: 480, defaultServiceSeconds: 120, start: nil, returnToStart: false)
        #expect(try await waitUntil { legacyStore.current?.route.id == route.id })
        let add = legacyStore.addDelivery(to: legacyStore.current!, address: .e1(), status: .pendingVerification, resolution: nil, reviewReasons: [], packages: [PackageDraft()], source: .scan)
        #expect(try await waitUntil { legacyStore.current?.packages.count == 1 })

        let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 480)).image { ctx in
            UIColor.systemTeal.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        }
        let jpeg = try #require(PhotoEncoder.jpeg(from: image))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pp-photos-\(UUID().uuidString)")
        try await db.waitForPendingWrites()
        let complete = try #require(try await remote.fetchVerifiedRoute(route.id))
        let persistence = try ActiveRoutePersistence(ownerID: uid, databaseURL: dir.appendingPathComponent("operations.sqlite"))
        try persistence.pin(complete, selected: true)
        let auth = Auth.auth(app: try #require(Self.current))
        let durable = DurableRouteBackend(remote: remote, ownerID: uid, persistence: persistence, transport: remote, authenticatedOwner: { auth.currentUser?.uid })
        let store = RouteStore(backend: durable)
        store.currentRouteID = route.id

        // Taken while offline: kept on the device, nothing uploaded.
        let offline = FirebasePhotoStore(uid: uid, store: store, connectivity: ConnectivityMonitor(forceOffline: true), storage: storage, baseDirectory: dir)
        let id = try offline.add(jpeg: jpeg, routeID: route.id, stopID: add.stopID, packageIDs: add.packageIDs)
        #expect(offline.pending.map(\.id) == [id])
        let path = FirebasePhotoStore.storagePath(uid: uid, routeID: route.id, photoID: id)

        // "Relaunch" online: the pending photo is recovered from disk and uploaded once.
        let online = FirebasePhotoStore(uid: uid, store: store, connectivity: ConnectivityMonitor(), storage: storage, baseDirectory: dir)
        #expect(online.pending.map(\.id) == [id])
        online.resumeUploads()
        #expect(try await waitUntil(20) { online.pending.isEmpty })
        let ops = StorageOps(storage: storage)
        #expect(await ops.contentType(path: path) == "image/jpeg")
        #expect(try await waitUntil { try await db.document("users/\(uid)/routes/\(route.id)/photos/\(id)").getDocument(source: .server).exists })
        #expect(try await waitUntil { store.current?.photos.contains { $0.id == id } == true })

        // A fresh store (no local copy) downloads it, then deletes file and record.
        let viewer = FirebasePhotoStore(uid: uid, store: store, connectivity: ConnectivityMonitor(), storage: storage, baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("pp-photos-\(UUID().uuidString)"))
        let photo = try #require(store.current?.photos.first { $0.id == id })
        let downloaded = try await viewer.image(for: photo, routeID: route.id)
        #expect(downloaded.size.width == 640)
        try await viewer.delete(photo: photo, routeID: route.id)
        #expect(try await waitUntil { await !ops.exists(path: path) })
        #expect(try await waitUntil { try await !db.document("users/\(uid)/routes/\(route.id)/photos/\(id)").getDocument(source: .server).exists })
        #expect(journal.failed.isEmpty)
    }

    @Test("A sign-in whose account was deleted elsewhere is detected instead of silently not syncing")
    func deletedAccountDetected() async throws {
        let (_, _, _, _, uid) = try await environment()
        let session = FirebaseSession(auth: Auth.auth(app: try #require(Self.current)))
        await session.validate()
        #expect(!session.needsSignInAgain)

        // Delete the account on the server (Auth emulator admin API), as another device would.
        var request = URLRequest(url: URL(string: "http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1/projects/\(AppConfiguration.emulatorProjectID)/accounts:delete")!)
        request.httpMethod = "POST"
        request.setValue("Bearer owner", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["localId": uid])
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        await session.validate(forceRefresh: true)
        // Either the app is told to sign in again, or Firebase itself signed the user out (which shows
        // the sign-in screen) — never a session that looks fine while nothing syncs.
        #expect(session.needsSignInAgain || (session.state == .signedOut && session.signedOutNotice != nil))
    }

    @Test("Email account: create, paid features wait for the confirmed address, confirm, sign in, reset, re-authenticate")
    func emailAccount() async throws {
        let app = try Self.makeApp(name: "pp-emulator-\(UUID().uuidString.prefix(8))")
        Self.current = app
        let session = FirebaseSession(auth: Auth.auth(app: app))
        let email = "driver-\(UUID().uuidString.prefix(8).lowercased())@example.com"
        let password = "correct-horse-1"

        try await session.createAccount(email: email, password: password)
        #expect(try await waitUntil { session.account?.method == .email })
        #expect(session.account?.needsEmailVerification == true)
        let sent = try await Self.oobCodes(for: email)
        let verifyLink = try #require(sent.first { $0.requestType == "VERIFY_EMAIL" }?.oobLink, "verification email sent")

        // The server refuses paid features until the address is confirmed.
        let resolve = Functions.functions(app: app, region: AppConfiguration.firebaseRegion)
            .httpsCallable("resolveAddress", requestAs: ResolveQuery.self, responseAs: ResolveReply.self)
        let query = ResolveQuery(query: "123 Example St, Victoria BC V8W 1A1")
        do {
            _ = try await resolve.call(query)
            Issue.record("An unconfirmed email account was allowed to use address checks")
        } catch {
            let ns = error as NSError
            #expect(ns.code == FunctionsErrorCode.failedPrecondition.rawValue)
            #expect((ns.userInfo[FunctionsErrorDetailsKey] as? [String: Any])?["reason"] as? String == "email-not-verified")
        }

        // Open the link from the email, then refresh in the app.
        _ = try await URLSession.shared.data(from: try #require(URL(string: verifyLink)))
        await session.refreshEmailVerification()
        #expect(session.account?.needsEmailVerification == false)
        #expect(try await resolve.call(query).provider == "emulatorFake")

        // Sign out; a wrong password gets a message that doesn't reveal whether the account exists.
        try Auth.auth(app: app).signOut()
        #expect(try await waitUntil { session.state == .signedOut })
        await #expect(throws: ServiceError.invalid("Email or password is incorrect.")) {
            try await session.signIn(email: email, password: "wrong-password")
        }
        try await session.signIn(email: email, password: password)
        #expect(try await waitUntil { session.state == .signedIn(uid: Auth.auth(app: app).currentUser?.uid ?? "") })

        // Password reset: sent for the account; an unknown address looks exactly the same to the driver.
        try await session.sendPasswordReset(email: email)
        try await session.sendPasswordReset(email: "nobody-\(UUID().uuidString.prefix(6).lowercased())@example.com")
        #expect(try await Self.oobCodes(for: email).contains { $0.requestType == "PASSWORD_RESET" })

        // Re-authentication (before deleting the account, or when the sign-in stopped working).
        await #expect(throws: ServiceError.self) { try await session.reauthenticate(password: "wrong-password") }
        try await session.reauthenticate(password: password)
    }

    nonisolated struct ResolveQuery: Encodable { var query: String }
    nonisolated struct ResolveReply: Decodable { var provider: String }
    nonisolated struct OobCode: Decodable { var email: String; var requestType: String; var oobLink: String }

    /// Emails the Auth emulator "sent" (verification and password-reset links).
    static func oobCodes(for email: String) async throws -> [OobCode] {
        nonisolated struct Reply: Decodable { var oobCodes: [OobCode] }
        let url = try #require(URL(string: "http://127.0.0.1:9099/emulator/v1/projects/\(AppConfiguration.emulatorProjectID)/oobCodes"))
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(Reply.self, from: data).oobCodes.filter { $0.email == email }
    }

    @Test("Another user's route is invisible and unwritable")
    func crossUser() async throws {
        let (_, storeA, _, db, uidA) = try await environment()
        let route = storeA.createRoute(name: "Private", serviceDate: "2026-10-05", timeZoneID: "America/Vancouver", departureMinute: 480, defaultServiceSeconds: 120, start: nil, returnToStart: false)
        #expect(try await waitUntil { (try? await db.document("users/\(uidA)/routes/\(route.id)").getDocument(source: .server).exists) == true })
        // Sign in as a different anonymous user and try to read/write user A's route.
        let (_, _, _, dbB, uidB) = try await environment()
        #expect(uidA != uidB)
        await #expect(throws: (any Error).self) { try await dbB.document("users/\(uidA)/routes/\(route.id)").getDocument(source: .server) }
        await #expect(throws: (any Error).self) { try await dbB.document("users/\(uidA)/routes/\(route.id)").updateData(["name": "Hijacked"]) }
    }
}

nonisolated extension StorageOps {
    func contentType(path: String) async -> String? {
        try? await storage.reference(withPath: path).getMetadata().contentType
    }
}

@Suite("Session error classification")
struct SessionErrorTests {
    @Test("Account gone / token refused → sign in again; offline or throttled → keep working")
    func classification() {
        func authError(_ code: AuthErrorCode, _ info: [String: Any] = [:]) -> NSError {
            NSError(domain: AuthErrorDomain, code: code.rawValue, userInfo: info)
        }
        #expect(FirebaseSession.isInvalidSession(authError(.userNotFound)))
        #expect(FirebaseSession.isInvalidSession(authError(.userDisabled)))
        #expect(FirebaseSession.isInvalidSession(authError(.userTokenExpired)))
        #expect(FirebaseSession.isInvalidSession(authError(.invalidUserToken)))
        #expect(FirebaseSession.isInvalidSession(authError(.internalError, ["FIRAuthErrorUserInfoDeserializedResponseKey": ["message": "INVALID_REFRESH_TOKEN"]])))
        #expect(!FirebaseSession.isInvalidSession(authError(.internalError, ["FIRAuthErrorUserInfoDeserializedResponseKey": ["message": "BACKEND_ERROR"]])))
        #expect(!FirebaseSession.isInvalidSession(authError(.networkError)))
        #expect(!FirebaseSession.isInvalidSession(authError(.tooManyRequests)))
        #expect(!FirebaseSession.isInvalidSession(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)))
    }
}

@MainActor
@Suite("Work persistence compatibility", .serialized)
struct WorkPersistenceCodecTests {
    @Test("Firestore route writes omit only the redundant work-summary cache, preserving legacy summary fields")
    func cloudSummaryCache() throws {
        var route = Route(name: "Close-out", serviceDate: "2026-10-05", timeZoneID: "America/Vancouver")
        var work = WorkSummary(); work.required = 2; work.completed = 1; work.failed = 1
        route.summary = RouteSummary(delivered: 1, failed: 1, stopCount: 1, packageCount: 2, work: work)
        let encoded = try FirestoreRouteBackend.routeData(route)
        let summary = try #require(encoded["summary"] as? [String: Any])
        #expect(summary["work"] == nil)
        #expect(summary["delivered"] as? Int == 1 && summary["failed"] as? Int == 1)
        #expect(summary["packageCount"] as? Int == 2 && summary["stopCount"] as? Int == 1)
        #expect(route.summary?.work == work, "Serialization must not change the local derived summary")
    }
    @Test("Firestore schema-1 delivery wire records decode without task fields, and retain their wire shape")
    func legacyFirestoreOutcome() throws {
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let legacy: [String: Any] = [
            "id": "legacy-event", "schemaVersion": 1, "packageID": "legacy-package",
            "stopID": "legacy-stop", "kind": "delivered", "recordedAt": Timestamp(date: instant), "photoIDs": [String](),
        ]
        let decoded = try Firestore.Decoder().decode(TaskOutcome.self, from: legacy)
        #expect(decoded.taskID == nil)
        #expect(decoded.targetTaskID == LocationTask.deliveryID(for: "legacy-package"))
        let encoded = try Firestore.Encoder().encode(decoded)
        #expect(encoded["schemaVersion"] as? Int == 1)
        #expect(encoded["packageID"] as? String == "legacy-package")
        #expect(encoded["taskID"] == nil)
        #expect(encoded["kind"] as? String == "delivered")
    }

    @Test("Task definitions preserve their association; standalone outcomes only target the task")
    func generalizedFirestoreWire() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let task = LocationTask(id: "pickup", stopID: "stop", kind: .pickup, title: "Collect return", instructions: "Ask reception", packageID: "package", now: now)
        let definition = try Firestore.Encoder().encode(task)
        #expect(definition["kind"] as? String == "pickup")
        #expect(definition["packageID"] as? String == "package")
        #expect(try Firestore.Decoder().decode(LocationTask.self, from: definition) == task)
        let outcome = TaskOutcome(id: "pickup-event", taskID: task.id, stopID: task.stopID, kind: .completed, recordedAt: now)
        let encoded = try Firestore.Encoder().encode(outcome)
        #expect(encoded["schemaVersion"] as? Int == 2)
        #expect(encoded["taskID"] as? String == task.id)
        #expect(encoded["packageID"] == nil)
        #expect(try Firestore.Decoder().decode(TaskOutcome.self, from: encoded) == outcome)
    }

    @Test("Malformed outcome versions fail decoding; future task kinds remain readable and block required work")
    func unsupportedWork() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var definition = try Firestore.Encoder().encode(LocationTask(id: "future", stopID: "stop", kind: .pickup, now: now))
        definition["kind"] = "future-kind"
        let task = try Firestore.Decoder().decode(LocationTask.self, from: definition)
        #expect(task.kind.rawValue == "future-kind")
        #expect(WorkLedger(packages: [], tasks: [task], outcomes: []).hasOutstandingRequiredWork(at: "stop"))
        var outcome = try Firestore.Encoder().encode(TaskOutcome(taskID: "future", stopID: "stop", kind: .completed, recordedAt: now))
        outcome["schemaVersion"] = 99
        #expect(throws: (any Error).self) { try Firestore.Decoder().decode(TaskOutcome.self, from: outcome) }
        outcome["schemaVersion"] = 1
        #expect(throws: (any Error).self) { try Firestore.Decoder().decode(TaskOutcome.self, from: outcome) }
    }

    @Test("Pre-task on-device routes load with an empty task collection instead of discarding the database")
    func legacyLocalDatabase() async throws {
        let env = TestEnvironment()
        let route = env.makeRoute()
        let add = env.store.addDelivery(to: env.snapshot, address: .e1(), status: .demoSynthetic, resolution: nil, reviewReasons: [], packages: [PackageDraft()], source: .manual)
        _ = env.store.record(.delivered, packageIDs: add.packageIDs, stopID: add.stopID, in: env.snapshot, label: "Delivered")
        var encoded = try #require(try JSONSerialization.jsonObject(with: JSONEncoder.appStorage.encode(env.backend.db)) as? [String: Any])
        var routes = try #require(encoded["routes"] as? [String: [String: Any]])
        var oldRoute = try #require(routes[route.id])
        oldRoute["tasks"] = nil // This field did not exist in the pre-WP1 local format.
        routes[route.id] = oldRoute
        encoded["routes"] = routes
        let url = env.directory.appendingPathComponent("legacy-routes.json")
        try JSONSerialization.data(withJSONObject: encoded).write(to: url)
        let backend = LocalRouteBackend(fileURL: url)
        let recovered = try #require(try await backend.fetchRoute(route.id))
        #expect(recovered.tasks.isEmpty)
        #expect(recovered.packages.map(\.id) == add.packageIDs)
        #expect(recovered.ledger.status(of: add.packageIDs[0]).isHandled)
    }

    @Test("Critical work retries retain event identity and one narrow revision bump without replaying route settings")
    func journalRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("work-journal-\(UUID().uuidString).json")
        let journal = SyncJournal(fileURL: url)
        var route = Route(id: "route", name: "Original name", serviceDate: "2026-10-05", timeZoneID: "America/Vancouver")
        route.inputRevision = 8
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let task = LocationTask(id: "pickup", stopID: "stop", kind: .pickup, now: now)
        let outcome = TaskOutcome(id: "stable-event", taskID: task.id, stopID: task.stopID, kind: .completed, recordedAt: now)
        let id = journal.begin(ChangeSet([
            .putTask(route.id, task), .createOutcome(route.id, outcome),
            .updateRoute(route, bumpRevision: true), .bumpRouteRevision(route.id, expectedMinimum: 9),
        ], label: "Pickup complete", critical: true))
        journal.failed(id, message: "Not acknowledged")
        let recovered = SyncJournal(fileURL: url)
        let entry = try #require(recovered.failed.first)
        #expect(entry.ops == [.putTask(route.id, task), .createOutcome(route.id, outcome), .bumpRouteRevision(route.id, expectedMinimum: 9)])
        var database = LocalRouteBackend.Database()
        route.name = "Edited elsewhere"
        route.inputRevision = 12
        database.routes[route.id] = LocalRouteBackend.RouteData(route: route)
        for op in entry.ops { LocalRouteBackend.apply(op.changeOp, to: &database) }
        #expect(database.routes[route.id]?.route.inputRevision == 13)
        #expect(database.routes[route.id]?.route.name == "Edited elsewhere")
        #expect(database.routes[route.id]?.outcomes[outcome.id]?.taskID == task.id)
        #expect(database.routes[route.id]?.tasks[task.id] == task)
    }

    @Test("Legacy journal operations remain decodable without a generalized task target")
    func legacyJournal() throws {
        let frozen = Data("""
        [{"id":"legacy-entry","label":"Delivered","createdAt":1700000000,"state":"pending","ops":[{"createOutcome":{"_0":"legacy-route","_1":{"id":"legacy-event","schemaVersion":1,"packageID":"legacy-package","stopID":"legacy-stop","kind":"delivered","recordedAt":1700000000,"photoIDs":[]}}}]}]
        """.utf8)
        let entries = try JSONDecoder.appStorage.decode([SyncJournal.Entry].self, from: frozen)
        let entry = try #require(entries.first)
        guard case let .createOutcome(routeID, outcome) = try #require(entry.ops.first) else {
            Issue.record("Legacy delivery event was not retained")
            return
        }
        #expect(routeID == "legacy-route")
        #expect(outcome.packageID == "legacy-package")
        #expect(outcome.taskID == nil)
        #expect(outcome.kind == .delivered)
    }
}

@MainActor
@Suite("Durable Firebase replay", .serialized, .enabled(if: ProcessInfo.processInfo.environment["PP_EMULATOR"] == "1"))
struct FirestoreDurableReplayTests {
    struct Environment {
        var backend: FirestoreRouteBackend
        var db: Firestore
        var uid: String
        var route: Route
        var stop: Stop
        var package: Package
        var task: LocationTask
    }

    func environment() async throws -> Environment {
        let app = try FirestoreBackendEmulatorTests.makeApp(name: "pp-replay-\(UUID().uuidString.prefix(8))")
        let result = try await Auth.auth(app: app).signInAnonymously()
        let db = Firestore.firestore(app: app)
        let journal = SyncJournal(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("replay-journal-\(UUID().uuidString).json"))
        let backend = FirestoreRouteBackend(uid: result.user.uid, db: db, journal: journal)
        // Exercise the fractional boundary where microsecond truncation plus binary Date
        // conversion can exceed a strict one-microsecond comparison.
        let wireBoundary = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) + 0.000_000_95)
        var route = Route(name: "Protected replay", serviceDate: "2026-10-06", timeZoneID: "America/Vancouver", now: wireBoundary)
        route.inputRevision = 2
        let stop = Stop(address: .e1(), addressStatus: .pendingVerification, sequence: 1)
        let package = Package(stopID: stop.id, source: .manual)
        let task = LocationTask(stopID: stop.id, kind: .pickup, title: "Collect return")
        // One SDK batch seeds a complete shape; task rules require the root to exist afterward.
        let batch = db.batch()
        let root = db.document("users/\(result.user.uid)/routes/\(route.id)")
        batch.setData(try FirestoreRouteBackend.routeData(route), forDocument: root)
        try batch.setData(from: stop, forDocument: root.collection("stops").document(stop.id))
        try batch.setData(from: package, forDocument: root.collection("packages").document(package.id))
        try batch.setData(from: task, forDocument: root.collection("tasks").document(task.id))
        try await batch.commit()
        return Environment(backend: backend, db: db, uid: result.user.uid, route: route, stop: stop, package: package, task: task)
    }

    func command(_ env: Environment, ops: [ChangeOp], revision: Int? = nil, sequence: Int64 = 1) -> DurableCommand {
        var value = DurableCommand(id: StableID.make(), accountID: env.uid, routeID: env.route.id, sequence: sequence,
            createdAt: Date(), label: "Recorded work", ops: ops, baseRevision: revision ?? env.route.inputRevision,
            baseRouteCreatedAt: env.route.createdAt, baseRouteUpdatedAt: env.route.updatedAt, payloadDigest: "")
        value.payloadDigest = try! ActiveRoutePersistence.commandDigest(value)
        return value
    }
    func root(_ env: Environment) -> DocumentReference { env.db.document("users/\(env.uid)/routes/\(env.route.id)") }
    func requireVerified(_ value: RemoteReplayResult) {
        guard case .verified = value else { Issue.record("Expected a verified command, got \(String(describing: value))"); return }
    }
    func requireBlocked(_ value: RemoteReplayResult) {
        guard case .blocked = value else { Issue.record("Expected preserved blocked intent, got \(String(describing: value))"); return }
    }

    @Test("Atomic receipts make outcome, revision and Undo replay safe after lost local acknowledgement")
    func duplicateOutcomeAndUndo() async throws {
        let env = try await environment()
        let event = TaskOutcome(packageID: env.package.id, stopID: env.stop.id, kind: .delivered)
        let delivered = command(env, ops: [.createOutcome(env.route.id, event), .bumpRouteRevision(env.route.id, expectedMinimum: 3)])
        requireVerified(await env.backend.replay(delivered))
        requireVerified(await env.backend.replay(delivered))
        #expect(try await root(env).getDocument(source: .server).get("inputRevision") as? Int == 3)
        #expect(try await root(env).collection("outcomes").getDocuments(source: .server).count == 1)
        let at = Date()
        let undo = command(env, ops: [.voidOutcome(env.route.id, event.id, at: at), .bumpRouteRevision(env.route.id, expectedMinimum: 4)], revision: 3, sequence: 2)
        requireVerified(await env.backend.replay(undo))
        requireVerified(await env.backend.replay(undo))
        #expect(try await root(env).getDocument(source: .server).get("inputRevision") as? Int == 4)
        #expect(try await root(env).collection("mutationReceipts").getDocuments(source: .server).count == 2)
        let snapshot = try #require(try await env.backend.fetchVerifiedRoute(env.route.id))
        #expect(snapshot.outcomes.count == 1 && snapshot.outcomes[0].voidedAt != nil)
        #expect(snapshot.workLedger.status(of: LocationTask.deliveryID(for: env.package.id)) == .pending)
    }

    @Test("A reused command identity with different intent cannot acknowledge or replace its original receipt")
    func commandIdentityCollision() async throws {
        let env = try await environment()
        let event = TaskOutcome(packageID: env.package.id, stopID: env.stop.id, kind: .delivered)
        var original = command(env, ops: [.createOutcome(env.route.id, event), .bumpRouteRevision(env.route.id, expectedMinimum: 3)])
        requireVerified(await env.backend.replay(original))
        var changed = event; changed.note = "Incompatible replay"
        original.ops = [.createOutcome(env.route.id, changed), .bumpRouteRevision(env.route.id, expectedMinimum: 3)]
        original.payloadDigest = try ActiveRoutePersistence.commandDigest(original)
        requireBlocked(await env.backend.replay(original))
        #expect(try await root(env).getDocument(source: .server).get("inputRevision") as? Int == 3)
        #expect(try await root(env).collection("mutationReceipts").getDocuments(source: .server).count == 1)
    }

    @Test("Generalized completion, defer, Retry and completion replay in route sequence")
    func retryOrdering() async throws {
        let env = try await environment()
        let deferred = TaskOutcome(taskID: env.task.id, stopID: env.stop.id, kind: .skipped)
        let retry = TaskOutcome(taskID: env.task.id, stopID: env.stop.id, kind: .requeued, recordedAt: deferred.recordedAt.addingTimeInterval(0.001))
        let completed = TaskOutcome(taskID: env.task.id, stopID: env.stop.id, kind: .completed, recordedAt: deferred.recordedAt.addingTimeInterval(0.002))
        for (offset, event) in [deferred, retry, completed].enumerated() {
            let op = command(env, ops: [.createOutcome(env.route.id, event), .bumpRouteRevision(env.route.id, expectedMinimum: 3 + offset)], revision: 2 + offset, sequence: Int64(offset + 1))
            requireVerified(await env.backend.replay(op))
            requireVerified(await env.backend.replay(op))
        }
        let snapshot = try #require(try await env.backend.fetchVerifiedRoute(env.route.id))
        #expect(snapshot.outcomes.count == 3)
        #expect(snapshot.workSummary.completed == 1 && snapshot.workSummary.pending == 1)
        #expect(snapshot.route.inputRevision == 5)
    }

    @Test("Revision advance, replaced routes, missing targets and immutable payload collisions preserve blocked intent")
    func conflicts() async throws {
        let env = try await environment()
        let event = TaskOutcome(id: "conflicting-event", packageID: env.package.id, stopID: env.stop.id, kind: .delivered)
        let op = command(env, ops: [.createOutcome(env.route.id, event), .bumpRouteRevision(env.route.id, expectedMinimum: 3)])
        var collision = event; collision.note = "Different driver intent"
        try await root(env).collection("outcomes").document(event.id).setData(from: collision)
        requireBlocked(await env.backend.replay(op))
        #expect(try await root(env).getDocument(source: .server).get("inputRevision") as? Int == 2)
        var ahead = op; ahead.id = StableID.make()
        ahead.payloadDigest = try ActiveRoutePersistence.commandDigest(ahead)
        try await root(env).updateData(["inputRevision": 3])
        requireBlocked(await env.backend.replay(ahead))
        var replaced = op; replaced.id = StableID.make(); replaced.baseRevision = 3; replaced.baseRouteCreatedAt = Date(timeIntervalSince1970: 0)
        replaced.payloadDigest = try ActiveRoutePersistence.commandDigest(replaced)
        requireBlocked(await env.backend.replay(replaced))
        try await root(env).collection("packages").document(env.package.id).delete()
        var missing = command(env, ops: [.createOutcome(env.route.id, TaskOutcome(packageID: env.package.id, stopID: env.stop.id, kind: .failed)), .bumpRouteRevision(env.route.id, expectedMinimum: 4)], revision: 3)
        missing.sequence = 2
        missing.payloadDigest = try ActiveRoutePersistence.commandDigest(missing)
        requireBlocked(await env.backend.replay(missing))
        #expect(try await root(env).collection("mutationReceipts").getDocuments(source: .server).isEmpty)
    }

    @Test("A same-revision remote route edit cannot be silently overwritten by a stale close-out")
    func sameRevisionMetadataConflict() async throws {
        let env = try await environment()
        var closing = env.route; closing.status = .completed; closing.completedAt = Date(); closing.updatedAt = Date()
        let op = command(env, ops: [.updateRoute(closing, bumpRevision: false)])
        try await root(env).updateData(["name": "Changed on another device", "updatedAt": Timestamp(date: env.route.updatedAt.addingTimeInterval(1))])
        requireBlocked(await env.backend.replay(op))
        let route = try await root(env).getDocument(source: .server)
        #expect(route.get("status") as? String == "planning")
        #expect(route.get("inputRevision") as? Int == 2)
        #expect(try await root(env).collection("mutationReceipts").getDocuments(source: .server).isEmpty)
    }

    @Test("A same-revision package edit or removal cannot overwrite a differing server definition")
    func definitionBaselineConflict() async throws {
        let env = try await environment()
        var edited = env.package; edited.notes = "Driver local note"
        var op = command(env, ops: [.putPackage(env.route.id, edited), .bumpRouteRevision(env.route.id, expectedMinimum: 3)])
        op.baselines = [CommandDocumentBaseline(documentKey: "routes/\(env.route.id)/packages/\(env.package.id)", payload: try ActiveRoutePersistence.encode(env.package))]
        op.payloadDigest = try ActiveRoutePersistence.commandDigest(op)
        try await root(env).collection("packages").document(env.package.id).updateData(["notes": "Remote note without revision"])
        requireBlocked(await env.backend.replay(op))
        #expect(try await root(env).collection("packages").document(env.package.id).getDocument(source: .server).get("notes") as? String == "Remote note without revision")
        #expect(try await root(env).getDocument(source: .server).get("inputRevision") as? Int == 2)
        #expect(try await root(env).collection("mutationReceipts").getDocuments(source: .server).isEmpty)
    }

    @Test("Wrong account and server validation rejection remain distinct; neither creates a receipt")
    func authAndRulesFailure() async throws {
        let env = try await environment()
        var invalid = env.package; invalid.notes = String(repeating: "x", count: 1001)
        let rejected = command(env, ops: [.putPackage(env.route.id, invalid), .bumpRouteRevision(env.route.id, expectedMinimum: 3)])
        requireBlocked(await env.backend.replay(rejected))
        var foreign = rejected; foreign.accountID = "someone-else"
        let result = await env.backend.replay(foreign)
        guard case .authentication = result else { Issue.record("Wrong account was allowed to replay"); return }
        #expect(try await root(env).collection("mutationReceipts").getDocuments(source: .server).isEmpty)
        #expect(try await root(env).getDocument(source: .server).get("inputRevision") as? Int == 2)
    }

    @Test("Network loss does not become receipt acknowledgement and a later retry verifies once")
    func unknownVerification() async throws {
        let env = try await environment()
        let event = TaskOutcome(packageID: env.package.id, stopID: env.stop.id, kind: .delivered)
        let op = command(env, ops: [.createOutcome(env.route.id, event), .bumpRouteRevision(env.route.id, expectedMinimum: 3)])
        try await env.db.disableNetwork()
        let offline = await env.backend.replay(op)
        guard case .retryable = offline else { Issue.record("Offline replay was acknowledged or rejected permanently: \(String(describing: offline))"); return }
        await #expect(throws: (any Error).self) { try await env.backend.fetchVerifiedRoute(env.route.id) }
        try await env.db.enableNetwork()
        requireVerified(await env.backend.replay(op))
        requireVerified(await env.backend.replay(op))
        #expect(try await root(env).collection("outcomes").getDocuments(source: .server).count == 1)
    }

    @Test("Creating a route and its operational definitions is one receipt-protected transaction")
    func routeCreation() async throws {
        let env = try await environment()
        var route = env.route; route.id = StableID.make(); route.inputRevision = 1
        var create = DurableCommand(id: StableID.make(), accountID: env.uid, routeID: route.id, sequence: 1, createdAt: Date(), label: "Create route",
            ops: [.createRoute(route), .putStop(route.id, env.stop), .putPackage(route.id, env.package)], baseRevision: 0, baseRouteCreatedAt: nil,
            payloadDigest: "")
        create.payloadDigest = try ActiveRoutePersistence.commandDigest(create)
        requireVerified(await env.backend.replay(create))
        requireVerified(await env.backend.replay(create))
        let snapshot = try #require(try await env.backend.fetchVerifiedRoute(route.id))
        #expect(snapshot.route.inputRevision == 1 && snapshot.stops.count == 1 && snapshot.packages.count == 1)
    }

    @Test("Server route deletion and malformed server collection cannot replace protected state")
    func deletedAndMalformedServer() async throws {
        let env = try await environment()
        let badPath = "users/\(env.uid)/routes/\(env.route.id)/tasks/malformed"
        try await administrator(path: badPath, method: "PATCH", fields: ["id": ["stringValue": "malformed"]])
        await #expect(throws: (any Error).self) { try await env.backend.fetchVerifiedRoute(env.route.id) }
        try await administrator(path: "users/\(env.uid)/routes/\(env.route.id)", method: "DELETE")
        #expect(try await env.backend.fetchVerifiedRoute(env.route.id) == nil)
        let event = TaskOutcome(packageID: env.package.id, stopID: env.stop.id, kind: .delivered)
        requireBlocked(await env.backend.replay(command(env, ops: [.createOutcome(env.route.id, event), .bumpRouteRevision(env.route.id, expectedMinimum: 3)])))
    }

    @Test("Protected route acknowledgements survive offline termination, empty SDK cache and verified Firebase replay")
    func protectedWorkflowOfflineRestart() async throws {
        let env = try await environment()
        let second = Package(stopID: env.stop.id, source: .manual)
        let third = Package(stopID: env.stop.id, source: .manual)
        let checklist = LocationTask(stopID: env.stop.id, kind: .checklist, title: "Confirm container")
        let seed = env.db.batch()
        try seed.setData(from: second, forDocument: root(env).collection("packages").document(second.id))
        try seed.setData(from: third, forDocument: root(env).collection("packages").document(third.id))
        try seed.setData(from: checklist, forDocument: root(env).collection("tasks").document(checklist.id))
        seed.updateData(["inputRevision": 3], forDocument: root(env))
        try await seed.commit()
        let online = try #require(try await env.backend.fetchVerifiedRoute(env.route.id))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("protected-sdk-\(UUID().uuidString)/operations.sqlite")
        var persistence: ActiveRoutePersistence? = try ActiveRoutePersistence(ownerID: env.uid, databaseURL: url)
        try persistence!.pin(online, selected: true)
        try await env.db.disableNetwork()
        var protected: DurableRouteBackend? = DurableRouteBackend(remote: env.backend, ownerID: env.uid, persistence: persistence,
            transport: env.backend, authenticatedOwner: { env.uid })
        protected!.networkAvailable = false
        var store: RouteStore? = RouteStore(backend: protected!)
        #expect(store!.currentRouteID == env.route.id)
        var eventIDs: [OutcomeID] = []
        for id in [env.package.id, second.id, third.id] {
            eventIDs += store!.record(.delivered, packageIDs: [id], stopID: env.stop.id, in: try #require(store!.current), label: "Delivered offline")
            #expect(store!.lastCommitResult.isCommitted)
        }
        eventIDs += store!.record(.completed, taskIDs: [env.task.id], in: try #require(store!.current), label: "Pickup complete offline")
        eventIDs += store!.record(.skipped, taskIDs: [checklist.id], in: try #require(store!.current), label: "Deferred offline")
        #expect(eventIDs.count == 5)
        #expect(store!.current?.workSummary.completed == 4 && store!.current?.workSummary.deferred == 1)
        #expect(try persistence!.commands().filter { $0.state != .verified }.count == 5)
        // These releases close SQLite and remove live listeners, reproducing process-owned state
        // loss. The remote adapter on relaunch deliberately reports an entirely absent cache.
        protected!.suspend(); store = nil; protected = nil; persistence = nil
        persistence = try ActiveRoutePersistence(ownerID: env.uid, databaseURL: url)
        protected = DurableRouteBackend(remote: EmulatorEmptyCacheBackend(), ownerID: env.uid, persistence: persistence,
            transport: env.backend, authenticatedOwner: { env.uid })
        protected!.networkAvailable = false
        store = RouteStore(backend: protected!)
        #expect(store!.currentRouteID == env.route.id)
        #expect(Set(try #require(store!.current).outcomes.map(\.id)) == Set(eventIDs))
        #expect(store!.current?.orderedStops.map(\.id) == online.orderedStops.map(\.id))
        #expect(store!.current?.packages.count == 3 && store!.current?.tasks.count == 2)
        #expect(store!.current?.workSummary.completed == 4 && store!.current?.workSummary.deferred == 1)
        eventIDs += store!.record(.requeued, taskIDs: [checklist.id], in: try #require(store!.current), label: "Retry offline")
        eventIDs += store!.record(.completed, taskIDs: [checklist.id], in: try #require(store!.current), label: "Checklist complete offline")
        #expect(store!.lastCommitResult.isCommitted && eventIDs.count == 7)
        let commands = try persistence!.commands()
        #expect(commands.count == 7 && commands.map(\.sequence) == [1, 2, 3, 4, 5, 6, 7])
        try await env.db.enableNetwork()
        protected!.networkAvailable = true
        await protected!.synchronize()
        let acknowledged = try persistence!.commands()
        #expect(acknowledged.count == 7 && acknowledged.allSatisfy { $0.state == .verified }, "Every local command must obtain its receipt: \(acknowledged.map { ($0.sequence, $0.state, $0.lastError) })")
        #expect(try await root(env).collection("mutationReceipts").getDocuments(source: .server).count == 7)
        requireVerified(await env.backend.replay(try #require(commands.first)))
        let server = try #require(try await env.backend.fetchVerifiedRoute(env.route.id))
        #expect(Set(server.outcomes.map(\.id)) == Set(eventIDs) && server.outcomes.count == 7)
        #expect(server.workSummary.completed == 5 && server.workSummary.pending == 0 && server.workSummary.deferred == 0)
        #expect(server.route.inputRevision == 10)
        protected!.suspend(); store = nil; protected = nil; persistence = nil
        persistence = try ActiveRoutePersistence(ownerID: env.uid, databaseURL: url)
        let final = try #require(try persistence!.snapshot(env.route.id))
        #expect(Set(final.outcomes.map(\.id)) == Set(eventIDs))
        #expect(final.workSummary.completed == 5 && final.route.inputRevision == 10)
        #expect(try persistence!.commands().allSatisfy { $0.state == .verified })
    }

    func administrator(path: String, method: String, fields: [String: Any]? = nil) async throws {
        let url = try #require(URL(string: "http://127.0.0.1:8180/v1/projects/\(AppConfiguration.emulatorProjectID)/databases/(default)/documents/\(path)"))
        var request = URLRequest(url: url); request.httpMethod = method
        request.setValue("Bearer owner", forHTTPHeaderField: "Authorization")
        if let fields {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["fields": fields])
        }
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }
}

@MainActor
@Suite("Legacy journal failure boundaries", .serialized)
struct LegacyJournalFailureTests {
    @Test("Corrupt legacy journal bytes are preserved and never silently become an empty saved journal")
    func corruptLegacy() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("sync-journal.json")
        let original = Data("{unfinished legacy bytes".utf8)
        try original.write(to: file)
        let journal = SyncJournal(fileURL: file)
        guard case .corrupt = journal.lastPersistenceFailure else { Issue.record("Corruption was hidden"); return }
        _ = journal.begin(ChangeSet([.deleteStop("route", "stop")], label: "Remove stop", critical: true))
        journal.clear()
        #expect(journal.entries.isEmpty)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test("A failed atomic legacy save cannot acknowledge or remove an in-memory retry intent")
    func failedLegacySave() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let parentFile = folder.appendingPathComponent("not-a-directory")
        try Data("occupied".utf8).write(to: parentFile)
        let journal = SyncJournal(fileURL: parentFile.appendingPathComponent("sync-journal.json"))
        _ = journal.begin(ChangeSet([.deleteStop("route", "stop")], label: "Remove stop", critical: true))
        guard case .storage = journal.lastPersistenceFailure else { Issue.record("Failed storage was hidden"); return }
        #expect(journal.entries.isEmpty, "Uncommitted intent cannot appear as locally saved")
        #expect(try Data(contentsOf: parentFile) == Data("occupied".utf8))
    }
}

/// Test-only empty SDK cache: every route/listener read is absent, while the separately supplied
/// real Firebase transport remains available once connectivity is restored.
@MainActor
private final class EmulatorEmptyCacheBackend: RouteBackend {
    let kind = BackendKind.firestore
    func observeRoutes(_ onChange: @escaping ([Route], Set<String>) -> Void) -> ListenerToken { onChange([], []); return ListenerToken {} }
    func observeRoute(_ id: RouteID, _ onChange: @escaping (RouteSnapshotEnvelope?) -> Void) -> ListenerToken { onChange(nil); return ListenerToken {} }
    func commit(_ change: ChangeSet) -> LocalCommitResult { .failed(.storage("Unexpected SDK cache write")) }
    func loadSettings() async -> UserSettings? { nil }
    func saveSettings(_ settings: UserSettings) {}
    func fetchRoute(_ id: RouteID) async throws -> RouteSnapshot? { nil }
}
