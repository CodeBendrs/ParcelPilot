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
        return (backend, RouteStore(backend: backend), journal, db, result.user.uid)
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
        let (_, store, journal, db, uid) = try await environment()
        let route = store.createRoute(name: "Outcomes", serviceDate: "2026-10-05", timeZoneID: "America/Vancouver", departureMinute: 480, defaultServiceSeconds: 120, start: nil, returnToStart: false)
        #expect(try await waitUntil { store.current?.route.id == route.id })
        let add = store.addDelivery(to: store.current!, address: .e1(), status: .pendingVerification, resolution: nil, reviewReasons: [], packages: [PackageDraft()], source: .scan)
        #expect(try await waitUntil { store.current?.packages.count == 1 })
        let ids = store.record(.delivered, packageIDs: add.packageIDs, stopID: add.stopID, in: store.current!, label: "Delivered")
        let path = "users/\(uid)/routes/\(route.id)/outcomes/\(ids[0])"
        #expect(try await waitUntil { try await db.document(path).getDocument(source: .server).exists })
        #expect(try await waitUntil { journal.entries.isEmpty })
        store.undo(outcomeIDs: ids, in: store.current!)
        #expect(try await waitUntil { try await db.document(path).getDocument(source: .server).get("voidedAt") != nil })
        // A second void (e.g. a stale replay) is rejected by the rules and reported, not silently lost.
        store.undo(outcomeIDs: ids, in: store.current!)
        #expect(try await waitUntil { !journal.failed.isEmpty })
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
        let (_, store, journal, db, uid) = try await environment()
        let storage = Storage.storage(app: try #require(Self.current))
        let route = store.createRoute(name: "Photos", serviceDate: "2026-10-05", timeZoneID: "America/Vancouver", departureMinute: 480, defaultServiceSeconds: 120, start: nil, returnToStart: false)
        #expect(try await waitUntil { store.current?.route.id == route.id })
        let add = store.addDelivery(to: store.current!, address: .e1(), status: .pendingVerification, resolution: nil, reviewReasons: [], packages: [PackageDraft()], source: .scan)
        #expect(try await waitUntil { store.current?.packages.count == 1 })

        let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 480)).image { ctx in
            UIColor.systemTeal.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        }
        let jpeg = try #require(PhotoEncoder.jpeg(from: image))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pp-photos-\(UUID().uuidString)")

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
        #expect(await !ops.exists(path: path))
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
