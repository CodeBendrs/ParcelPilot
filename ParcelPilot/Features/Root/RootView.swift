import AuthenticationServices
import GoogleSignInSwift
import SwiftUI

struct RootView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        switch coordinator.phase {
        case .launching:
            ProgressView("Starting…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
        case let .welcome(unconfigured):
            WelcomeView(unconfigured: unconfigured)
        case .signIn:
            SignInView()
        case let .ready(services):
            MainTabView()
                .environment(services)
                .id(ObjectIdentifier(services))
        }
    }
}

/// Shown when this build has no Firebase configuration, so accounts cannot be used yet.
struct WelcomeView: View {
    var unconfigured: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.xl) {
                BrandHeader()
                if unconfigured {
                    Banner(symbol: "gearshape.2", text: "Accounts aren't set up in this build. Add GoogleService-Info.plist to the ParcelPilot folder (README → Firebase setup) to enable Sign in with Apple and cloud sync.", tone: .warning)
                }
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
    }
}

struct BrandHeader: View {
    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "shippingbox.and.arrow.backward.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.brand, Theme.teal)
                .accessibilityHidden(true)
            Text("ParcelPilot").font(.largeTitle.bold())
            Text("Scan labels, plan the route, deliver with fewer taps.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, Theme.Space.xxl)
    }
}

struct SignInView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var nonce = FirebaseSession.makeNonce()
    @State private var error: String?
    @State private var working = false
    @State private var showEmail = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.xl) {
                BrandHeader()
                VStack(spacing: Theme.Space.m) {
                    googleButton

                    Button {
                        showEmail = true
                    } label: {
                        Label("Continue with email", systemImage: "envelope")
                    }
                    .buttonStyle(PrimaryActionButtonStyle(filled: false))
                    .disabled(working)
                    .accessibilityIdentifier("continueWithEmail")

                    if FirebaseSession.appleDeveloperProgram {
                        SignInWithAppleButton(.signIn) { request in
                            nonce = FirebaseSession.makeNonce()
                            request.requestedScopes = []
                            request.nonce = FirebaseSession.sha256(nonce)
                        } onCompletion: { result in
                            handleApple(result)
                        }
                        .signInWithAppleButtonStyle(.black)
                        .frame(height: Theme.primaryActionHeight)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
                        .disabled(working)
                        .accessibilityIdentifier("signInWithApple")
                    }

                    if case .emulator = FirebaseBootstrap.mode {
                        Button {
                            Task { await run { try await coordinator.session?.signInForEmulator() } }
                        } label: {
                            Label("Sign in with emulator test account", systemImage: "hammer")
                        }
                        .buttonStyle(PrimaryActionButtonStyle(tint: Theme.teal, filled: false))
                        .accessibilityIdentifier("emulatorSignIn")
                        Text("Local Firebase Emulator Suite — test data only.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if working { ProgressView("Signing in…") }
                if let notice = coordinator.session?.signedOutNotice {
                    Banner(symbol: "person.crop.circle.badge.exclamationmark", text: notice, tone: .warning)
                        .accessibilityIdentifier("signedOutNotice")
                }
                if let error {
                    Banner(symbol: "exclamationmark.triangle.fill", text: error, tone: .danger)
                }
                Text("ParcelPilot uses your sign-in only to keep your routes in sync across your devices. Delete your account and data any time in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .sheet(isPresented: $showEmail) { EmailSignInView() }
    }

    @ViewBuilder private var googleButton: some View {
        switch coordinator.session?.googleSetup {
        case .ready:
            // Google's own button, as its sign-in branding guidelines require.
            GoogleSignInButton(scheme: colorScheme == .dark ? .dark : .light, style: .wide, state: working ? .disabled : .normal) {
                Task { await run { try await coordinator.session?.signInWithGoogle() } }
            }
            .disabled(working)
            .accessibilityIdentifier("continueWithGoogle")
        case let .unavailable(message):
            VStack(spacing: Theme.Space.xs) {
                GoogleSignInButton(scheme: colorScheme == .dark ? .dark : .light, style: .wide, state: .disabled) {}
                    .disabled(true)
                    .accessibilityIdentifier("continueWithGoogle")
                Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        case nil:
            EmptyView()
        }
    }

    private func run(_ action: @escaping () async throws -> Void) async {
        working = true
        error = nil
        defer { working = false }
        do {
            try await action()
        } catch is CancellationError {
            // The driver closed the Google sheet.
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case let .failure(e):
            if (e as? ASAuthorizationError)?.code == .canceled { return }
            error = "Sign in with Apple didn't finish: \(e.localizedDescription)"
        case let .success(authorization):
            Task {
                await run {
                    let credential = try FirebaseSession.appleCredential(from: authorization)
                    try await coordinator.session?.signIn(with: credential, rawNonce: nonce)
                }
            }
        }
    }
}

/// Email sign-in, account creation and password reset.
struct EmailSignInView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case signIn = "Sign in", create = "Create account"
        var id: String { rawValue }
    }

    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var working = false
    @State private var error: String?
    @State private var notice: String?
    @FocusState private var focused: Field?

    enum Field { case email, password }

    private var emailLooksValid: Bool {
        let e = email.trimmingCharacters(in: .whitespaces)
        guard let at = e.firstIndex(of: "@") else { return false }
        return e[e.index(after: at)...].contains(".") && !e.contains(" ")
    }

    private var canSubmit: Bool {
        emailLooksValid && password.count >= (mode == .create ? FirebaseSession.minimumPasswordLength : 1) && !working
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("emailMode")
                }
                Section {
                    TextField("Email address", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focused = .password }
                        .accessibilityIdentifier("emailField")
                    SecureField(mode == .create ? "New password (at least \(FirebaseSession.minimumPasswordLength) characters)" : "Password", text: $password)
                        .textContentType(mode == .create ? .newPassword : .password)
                        .focused($focused, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { if canSubmit { Task { await submit() } } }
                        .accessibilityIdentifier("passwordField")
                } footer: {
                    if mode == .create {
                        Text("We'll email you a link to confirm your address. Checking addresses and planning routes work once it's confirmed.")
                    }
                }
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        Text(mode == .create ? "Create account" : "Sign in").frame(maxWidth: .infinity)
                    }
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("emailSubmit")
                    if mode == .signIn {
                        Button("Forgot password?") { Task { await resetPassword() } }
                            .disabled(!emailLooksValid || working)
                            .accessibilityIdentifier("forgotPassword")
                    }
                }
                if working { ProgressView(mode == .create ? "Creating account…" : "Signing in…") }
                if let notice { Banner(symbol: "envelope.badge", text: notice, tone: .info) }
                if let error { Banner(symbol: "exclamationmark.triangle.fill", text: error, tone: .danger).accessibilityIdentifier("emailError") }
            }
            .navigationTitle(mode == .create ? "Create account" : "Sign in with email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onChange(of: mode) { _, _ in error = nil; notice = nil }
            .onAppear { focused = .email }
        }
    }

    private func submit() async {
        guard let session = coordinator.session else { return }
        working = true
        error = nil
        notice = nil
        defer { working = false }
        do {
            if mode == .create {
                try await session.createAccount(email: email, password: password)
            } else {
                try await session.signIn(email: email, password: password)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
            if mode == .signIn {
                password = ""
                focused = .password
            }
        }
    }

    private func resetPassword() async {
        guard let session = coordinator.session else { return }
        working = true
        error = nil
        defer { working = false }
        do {
            try await session.sendPasswordReset(email: email)
            notice = "If there's an account for \(email.trimmingCharacters(in: .whitespaces)), a link to reset the password is on its way."
        } catch {
            self.error = error.localizedDescription
        }
    }
}
