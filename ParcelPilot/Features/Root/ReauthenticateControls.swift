import AuthenticationServices
import SwiftUI

/// Confirms the signed-in account again, the way it signs in: password for email accounts, Google
/// sign-in for Google accounts, Sign in with Apple for Apple accounts. Used before deleting the
/// account and when the saved sign-in stopped working. Rows for a `Form` section.
struct ReauthenticateControls: View {
    @Environment(AppCoordinator.self) private var coordinator
    var actionTitle: String
    var role: ButtonRole?
    var enabled: Bool = true
    /// Runs after the account is confirmed. Receives Apple's authorization code for Apple accounts
    /// (needed to revoke the Apple sign-in when deleting the account).
    var onConfirmed: (_ appleAuthorizationCode: String?) async throws -> Void

    @State private var password = ""
    @State private var nonce = FirebaseSession.makeNonce()
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Group {
            switch coordinator.session?.account?.method {
            case .email:
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .accessibilityIdentifier("reauthPassword")
                Button(actionTitle, role: role) {
                    Task { await confirm { try await coordinator.session?.reauthenticate(password: password); return nil } }
                }
                .disabled(!enabled || password.isEmpty || working)
                .accessibilityIdentifier("reauthConfirm")
            case .google:
                Button(role: role) {
                    Task { await confirm { try await coordinator.session?.reauthenticate(); return nil } }
                } label: {
                    Label("\(actionTitle) — confirm with Google", systemImage: "person.badge.key")
                }
                .disabled(!enabled || working)
                .accessibilityIdentifier("reauthConfirm")
            case .apple:
                SignInWithAppleButton(.continue) { request in
                    nonce = FirebaseSession.makeNonce()
                    request.requestedScopes = []
                    request.nonce = FirebaseSession.sha256(nonce)
                } onCompletion: { result in
                    switch result {
                    case let .success(authorization):
                        Task {
                            await confirm {
                                let credential = try FirebaseSession.appleCredential(from: authorization)
                                try await coordinator.session?.reauthenticate(apple: credential, rawNonce: nonce)
                                return credential.authorizationCode
                            }
                        }
                    case let .failure(e):
                        if (e as? ASAuthorizationError)?.code != .canceled { error = e.localizedDescription }
                    }
                }
                .frame(height: Theme.primaryActionHeight)
                .disabled(!enabled || working)
            case .emulator, nil:
                Button(actionTitle, role: role) {
                    Task { await confirm { nil } }
                }
                .disabled(!enabled || working)
                .accessibilityIdentifier("reauthConfirm")
            }
            if working { ProgressView() }
            if let error {
                Banner(symbol: "exclamationmark.triangle.fill", text: error, tone: .danger)
                    .accessibilityIdentifier("reauthError")
            }
        }
    }

    private func confirm(_ reauthenticate: () async throws -> String?) async {
        working = true
        error = nil
        defer { working = false }
        do {
            let appleCode = try await reauthenticate()
            try await onConfirmed(appleCode)
        } catch is CancellationError {
            // The driver closed the Google or Apple sheet.
        } catch {
            self.error = error.localizedDescription
        }
    }
}
