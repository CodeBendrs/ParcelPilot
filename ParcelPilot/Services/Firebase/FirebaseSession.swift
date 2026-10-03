import AuthenticationServices
import CryptoKit
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseFunctions
import Foundation
import GoogleSignIn
import Observation
import UIKit

/// Firebase Auth session. Drivers sign in with Google or with an email and password; Sign in with
/// Apple is available when the build has the Apple Developer Program capabilities
/// (`PP_APPLE_DEVELOPER_PROGRAM`). The emulator build also offers an explicitly labelled anonymous
/// "emulator test account" so the local stack can be exercised.
@MainActor
@Observable
final class FirebaseSession {
    enum State: Equatable { case loading, signedOut, signedIn(uid: String) }

    enum Method: Equatable { case google, email, apple, emulator }

    /// What the UI needs to know about the signed-in account.
    struct Account: Equatable {
        var method: Method
        var email: String?
        var emailVerified: Bool

        var label: String {
            switch method {
            case .google: return "Google" + (email.map { " · \($0)" } ?? "")
            case .email: return email ?? "Email"
            case .apple: return "Signed in with Apple"
            case .emulator: return "Emulator test account"
            }
        }

        /// Email/password accounts must confirm their address before using address checks and
        /// optimization (the server enforces this too).
        var needsEmailVerification: Bool { method == .email && !emailVerified }
    }

    private(set) var state: State = .loading
    private(set) var account: Account?
    /// The saved sign-in was rejected (account deleted or disabled elsewhere, sign-in revoked or
    /// expired). Nothing syncs until the driver signs in again; local data is kept until they decide.
    private(set) var needsSignInAgain = false
    /// Explains a sign-out the app didn't ask for (Firebase signs out an account that was deleted or
    /// disabled elsewhere). Shown on the sign-in screen.
    private(set) var signedOutNotice: String?
    /// Set just before the app itself signs out, so only unexpected sign-outs get a notice.
    static var signOutRequested = false
    let auth: Auth
    @ObservationIgnored private var handle: AuthStateDidChangeListenerHandle?
    @ObservationIgnored private var checkObserver: NSObjectProtocol?

    init(auth: Auth = Auth.auth()) {
        self.auth = auth
        handle = auth.addStateDidChangeListener { [weak self] _, user in
            MainActor.assumeIsolated {
                guard let self else { return }
                let wasSignedIn = if case .signedIn = self.state { true } else { false }
                self.state = user.map { .signedIn(uid: $0.uid) } ?? .signedOut
                self.refreshAccount()
                if user == nil {
                    self.needsSignInAgain = false
                    if wasSignedIn && !Self.signOutRequested {
                        self.signedOutNotice = "You were signed out because this account's sign-in is no longer valid — it may have been deleted or disabled on another device. Sign in the same way as before to sync changes saved on this iPhone."
                    }
                } else {
                    self.signedOutNotice = nil
                    Task { await self.validate() }
                }
                Self.signOutRequested = false
            }
        }
        checkObserver = NotificationCenter.default.addObserver(forName: .ppSessionCheckNeeded, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.validate() } }
        }
    }

    var isAnonymous: Bool { auth.currentUser?.isAnonymous == true }

    private func refreshAccount() {
        guard let user = auth.currentUser else {
            account = nil
            return
        }
        let providers = Set(user.providerData.map(\.providerID))
        let method: Method
        if user.isAnonymous { method = .emulator }
        else if providers.contains(GoogleAuthProviderID) { method = .google }
        else if providers.contains("apple.com") { method = .apple }
        else { method = .email }
        account = Account(method: method, email: user.email, emailVerified: user.isEmailVerified)
    }

    // MARK: Session health

    /// Checks that the saved sign-in still works (refreshing the ID token if it has expired). Being
    /// offline is not a problem — work continues from the cache and syncs later.
    func validate(forceRefresh: Bool = false) async {
        guard let user = auth.currentUser else {
            needsSignInAgain = false
            return
        }
        do {
            try await Self.refreshToken(of: user, force: forceRefresh)
            needsSignInAgain = false
        } catch {
            if Self.isInvalidSession(error) {
                AppLog.sync.error("Saved sign-in rejected: \((error as NSError).code, privacy: .public)")
                needsSignInAgain = true
            }
        }
    }

    nonisolated private static func refreshToken(of user: User, force: Bool) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            user.getIDTokenForcingRefresh(force) { _, error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    /// Errors that mean the saved sign-in can never work again (as opposed to being offline or a
    /// temporary server problem). Firebase reports an unknown refresh token as an internal error
    /// carrying the server's message, so that message is checked too.
    nonisolated static func isInvalidSession(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == AuthErrorDomain else { return false }
        switch AuthErrorCode(rawValue: ns.code) {
        case .userNotFound, .userDisabled, .invalidUserToken, .userTokenExpired:
            return true
        case .internalError:
            let text = String(describing: ns.userInfo)
            return ["INVALID_REFRESH_TOKEN", "USER_NOT_FOUND", "USER_DISABLED", "TOKEN_EXPIRED", "INVALID_ID_TOKEN"].contains { text.contains($0) }
        default:
            return false
        }
    }

    // MARK: Google

    enum GoogleSetup: Equatable {
        case ready(clientID: String)
        case unavailable(String)
    }

    /// Google sign-in needs the OAuth client ID from GoogleService-Info.plist (present once Google is
    /// enabled in Firebase Authentication before the file is downloaded) and its reversed form
    /// registered as the app's URL scheme, so Google can hand the result back to the app.
    nonisolated static func googleSetup(clientID: String?, registeredScheme: String?) -> GoogleSetup {
        guard let clientID, !clientID.isEmpty else {
            return .unavailable("Google sign-in isn't set up in this build: enable Google in Firebase Authentication, then download GoogleService-Info.plist again (it then contains CLIENT_ID).")
        }
        let expected = clientID.split(separator: ".").reversed().joined(separator: ".")
        guard registeredScheme == expected else {
            return .unavailable("Google sign-in needs GOOGLE_REVERSED_CLIENT_ID = \(expected) in Config/Secrets.xcconfig.")
        }
        return .ready(clientID: clientID)
    }

    var googleSetup: GoogleSetup {
        let scheme = (Bundle.main.object(forInfoDictionaryKey: "PPGoogleReversedClientID") as? String).flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
        return Self.googleSetup(clientID: auth.app?.options.clientID, registeredScheme: scheme)
    }

    func signInWithGoogle() async throws {
        let credential = try await googleCredential()
        do {
            _ = try await auth.signIn(with: credential)
        } catch {
            throw Self.describe(error)
        }
    }

    private func googleCredential() async throws -> AuthCredential {
        guard case let .ready(clientID) = googleSetup else {
            if case let .unavailable(message) = googleSetup { throw ServiceError.notConfigured(message) }
            throw ServiceError.notConfigured("Google sign-in isn't set up in this build.")
        }
        guard let presenter = UIApplication.shared.topViewController else {
            throw ServiceError.unavailable("Google sign-in couldn't open. Try again.")
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        let tokens: (idToken: String, accessToken: String) = try await withCheckedThrowingContinuation { c in
            GIDSignIn.sharedInstance.signIn(withPresenting: presenter) { result, error in
                if let error {
                    if (error as NSError).code == GIDSignInError.canceled.rawValue {
                        c.resume(throwing: CancellationError())
                    } else {
                        c.resume(throwing: ServiceError.unavailable("Google sign-in didn't finish: \(error.localizedDescription)"))
                    }
                } else if let user = result?.user, let idToken = user.idToken?.tokenString {
                    c.resume(returning: (idToken, user.accessToken.tokenString))
                } else {
                    c.resume(throwing: ServiceError.invalid("Google didn't return a sign-in token. Try again."))
                }
            }
        }
        return GoogleAuthProvider.credential(withIDToken: tokens.idToken, accessToken: tokens.accessToken)
    }

    // MARK: Email and password

    nonisolated static let minimumPasswordLength = 8

    /// Creates the account and sends the verification email.
    func createAccount(email: String, password: String) async throws {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard password.count >= Self.minimumPasswordLength else {
            throw ServiceError.invalid("Use at least \(Self.minimumPasswordLength) characters for your password.")
        }
        do {
            let result = try await auth.createUser(withEmail: email, password: password)
            try? await result.user.sendEmailVerification()
        } catch {
            throw Self.describeEmail(error)
        }
        refreshAccount()
    }

    func signIn(email: String, password: String) async throws {
        do {
            _ = try await auth.signIn(withEmail: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
        } catch {
            throw Self.describeEmail(error)
        }
    }

    /// Sends a reset link. The result never reveals whether an account exists for the address.
    func sendPasswordReset(email: String) async throws {
        do {
            try await auth.sendPasswordReset(withEmail: email.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            let code = AuthErrorCode(rawValue: (error as NSError).code)
            if code == .userNotFound { return }
            throw Self.describeEmail(error)
        }
    }

    func resendVerificationEmail() async throws {
        guard let user = auth.currentUser else { throw ServiceError.signedOut }
        do {
            try await user.sendEmailVerification()
        } catch {
            throw Self.describeEmail(error)
        }
    }

    /// Re-reads the account after the driver opened the verification link, and refreshes the ID
    /// token so the server sees the verified address.
    func refreshEmailVerification() async {
        guard let user = auth.currentUser else { return }
        try? await user.reload()
        try? await Self.refreshToken(of: user, force: true)
        refreshAccount()
    }

    // MARK: Re-authentication

    /// Signs the same account in again (before deleting it, or when the saved sign-in stopped
    /// working), so changes queued on this iPhone can sync. `password` is used for email accounts and
    /// `apple` for Apple accounts; Google accounts open Google sign-in.
    func reauthenticate(password: String? = nil, apple: AppleCredential? = nil, rawNonce: String? = nil) async throws {
        guard let user = auth.currentUser, let account else { throw ServiceError.signedOut }
        let credential: AuthCredential
        switch account.method {
        case .email:
            guard let email = user.email, let password, !password.isEmpty else { throw ServiceError.invalid("Enter your password.") }
            credential = EmailAuthProvider.credential(withEmail: email, password: password)
        case .google:
            credential = try await googleCredential()
        case .apple:
            guard let apple, let rawNonce else { throw ServiceError.invalid("Continue with Apple to confirm.") }
            credential = OAuthProvider.appleCredential(withIDToken: apple.idToken, rawNonce: rawNonce, fullName: nil)
        case .emulator:
            needsSignInAgain = false
            return
        }
        do {
            try await Self.reauthenticate(user, with: credential)
            needsSignInAgain = false
        } catch {
            switch AuthErrorCode(rawValue: (error as NSError).code) {
            case .userMismatch:
                throw ServiceError.invalid("That's a different account. Sign in with the account you used before, or sign out.")
            case .userNotFound, .userDisabled:
                throw ServiceError.invalid("This account no longer exists or has been disabled. Sign out to continue.")
            default:
                throw account.method == .email ? Self.describeEmail(error) : Self.describe(error)
            }
        }
    }

    nonisolated private static func reauthenticate(_ user: User, with credential: AuthCredential) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            user.reauthenticate(with: credential) { _, error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    // MARK: Sign in with Apple (Apple Developer Program builds only)

    /// True when the build includes the Sign in with Apple and App Attest capabilities.
    static var appleDeveloperProgram: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "PPAppleDeveloperProgram") as? String)?.uppercased() == "YES"
    }

    /// Cryptographically random nonce; its SHA-256 is sent to Apple and the raw value to Firebase.
    static func makeNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var bytes = [UInt8](repeating: 0, count: length)
        precondition(SecRandomCopyBytes(kSecRandomDefault, length, &bytes) == errSecSuccess)
        return String(bytes.map { charset[Int($0) % charset.count] })
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    struct AppleCredential {
        var idToken: String
        var authorizationCode: String?
        var fullName: PersonNameComponents?
    }

    static func appleCredential(from authorization: ASAuthorization) throws -> AppleCredential {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken, let token = String(data: tokenData, encoding: .utf8) else {
            throw ServiceError.invalid("Sign in with Apple didn't return a valid credential. Try again.")
        }
        return AppleCredential(idToken: token, authorizationCode: credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }, fullName: credential.fullName)
    }

    func signIn(with apple: AppleCredential, rawNonce: String) async throws {
        let credential = OAuthProvider.appleCredential(withIDToken: apple.idToken, rawNonce: rawNonce, fullName: apple.fullName)
        do {
            _ = try await auth.signIn(with: credential)
        } catch {
            throw Self.describe(error)
        }
    }

    // MARK: Emulator

    func signInForEmulator() async throws {
        do {
            _ = try await auth.signInAnonymously()
        } catch {
            throw Self.describe(error)
        }
    }

    // MARK: Errors

    static func describe(_ error: Error) -> ServiceError {
        if let error = error as? ServiceError { return error }
        let ns = error as NSError
        switch AuthErrorCode(rawValue: ns.code) {
        case .keychainError:
            return .notConfigured("This build can't save your sign-in on this device (keychain unavailable). Use a signed build — unsigned Simulator builds have no keychain access.")
        case .networkError:
            return .offline
        case .tooManyRequests:
            return .quotaExceeded("Too many sign-in attempts. Wait a moment and try again.")
        case .operationNotAllowed:
            return .notConfigured("This sign-in method isn't enabled for the app yet (Firebase Authentication → Sign-in method).")
        case .accountExistsWithDifferentCredential, .credentialAlreadyInUse:
            return .invalid("This email address already has a ParcelPilot account that signs in another way. Use that method instead.")
        default:
            return .unavailable("Sign-in failed: \(ns.localizedDescription)")
        }
    }

    /// Email/password errors, worded so they never reveal whether an account exists for an address.
    nonisolated static func describeEmail(_ error: Error) -> ServiceError {
        if let error = error as? ServiceError { return error }
        let ns = error as NSError
        switch AuthErrorCode(rawValue: ns.code) {
        case .emailAlreadyInUse:
            return .invalid("An account with this email already exists. Sign in instead, or reset the password.")
        case .invalidEmail, .missingEmail:
            return .invalid("That email address doesn't look right.")
        case .weakPassword:
            return .invalid("Choose a stronger password (at least \(minimumPasswordLength) characters).")
        case .wrongPassword, .invalidCredential, .userNotFound:
            return .invalid("Email or password is incorrect.")
        case .userDisabled:
            return .invalid("This account has been disabled.")
        case .networkError:
            return .offline
        case .tooManyRequests:
            return .quotaExceeded("Too many attempts. Wait a moment and try again.")
        case .operationNotAllowed:
            return .notConfigured("Email sign-in isn't enabled for the app yet (Firebase Authentication → Sign-in method → Email/Password).")
        case .keychainError:
            return .notConfigured("This build can't save your sign-in on this device (keychain unavailable). Use a signed build.")
        default:
            return .unavailable("Something went wrong: \(ns.localizedDescription)")
        }
    }
}

extension UIApplication {
    /// The front-most view controller, for presenting Google sign-in.
    var topViewController: UIViewController? {
        let root = connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.rootViewController
        var top = root
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

/// Sign out and account deletion for Firebase accounts.
@MainActor
final class FirebaseAccountService: AccountService {
    private let functions: Functions
    private let cleanup: () async -> Void

    init(functions: Functions = FirebaseBootstrap.functions(), cleanup: @escaping () async -> Void) {
        self.functions = functions
        self.cleanup = cleanup
    }

    nonisolated private struct Empty: Codable {}
    nonisolated private struct DeleteResponse: Decodable { var deleted: Bool }

    /// The caller re-authenticates first (the server requires a sign-in within the last 10 minutes).
    func deleteAccount(appleAuthorizationCode: String?) async throws {
        guard Auth.auth().currentUser != nil else { throw ServiceError.signedOut }
        do {
            if let appleAuthorizationCode {
                // Apple requires revoking Sign in with Apple tokens when an account is deleted.
                try await Auth.auth().revokeToken(withAuthorizationCode: appleAuthorizationCode)
            }
            var callable = functions.httpsCallable("deleteAccount", requestAs: Empty.self, responseAs: DeleteResponse.self)
            callable.timeoutInterval = 120
            _ = try await callable.call(Empty())
        } catch let error as ServiceError {
            throw error
        } catch {
            throw CallableErrorMapper.map(error, connectivity: nil)
        }
        await cleanup()
        FirebaseSession.signOutRequested = true
        GIDSignIn.sharedInstance.signOut()
        try? Auth.auth().signOut()
    }

    func signOut() throws {
        FirebaseSession.signOutRequested = true
        GIDSignIn.sharedInstance.signOut()
        try Auth.auth().signOut()
        Task { await cleanup() }
    }

    /// Clears this device's Firestore cache (including any unsynced writes) — used after sign-out and
    /// account deletion so the next person using the phone can't see the previous driver's data.
    static func clearFirestoreCache() async {
        let db = Firestore.firestore()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            db.terminate { _ in
                db.clearPersistence { _ in c.resume() }
            }
        }
    }
}

extension Notification.Name {
    /// Posted when a server call was refused as unauthenticated: the session re-checks its sign-in.
    static let ppSessionCheckNeeded = Notification.Name("pp.sessionCheckNeeded")
}
