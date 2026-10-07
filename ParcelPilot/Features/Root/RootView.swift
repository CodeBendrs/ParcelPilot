import AuthenticationServices
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
                .foregroundStyle(Theme.brand, Theme.brand)
                .accessibilityHidden(true)
            Text("ParcelPilot").font(.largeTitle.bold())
            Text("Scan labels, plan the route, deliver with fewer taps.")
                .font(.title3)
                .foregroundStyle(Theme.neutral)
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var welcomeTitleSize: CGFloat = 40

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    brandLockup

                    if !dynamicTypeSize.isAccessibilitySize {
                        Image("SignInRoute")
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .frame(height: min(232, geometry.size.height * 0.28))
                            .padding(.top, geometry.size.height < 650 ? 16 : 32)
                            .accessibilityHidden(true)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        Text("Ready for your\nnext route?")
                            .font(.system(size: welcomeTitleSize, weight: .bold))
                            .tracking(-0.8)
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text("Sign in to scan, plan, and deliver.")
                            .font(.body)
                            .foregroundStyle(Theme.neutral)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, geometry.size.height < 650 || dynamicTypeSize.isAccessibilitySize ? 24 : 40)

                    Spacer(minLength: geometry.size.height < 650 ? 24 : 32)
                    signInActions

                    if working {
                        ProgressView("Signing in…")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 16)
                    }
                    if let notice = coordinator.session?.signedOutNotice {
                        Banner(symbol: "person.crop.circle.badge.exclamationmark", text: notice, tone: .warning)
                            .accessibilityIdentifier("signedOutNotice")
                            .padding(.top, 16)
                    }
                    if let error {
                        Banner(symbol: "exclamationmark.triangle.fill", text: error, tone: .danger)
                            .accessibilityIdentifier("signInError")
                            .padding(.top, 16)
                    }

                    Spacer(minLength: 32)
                    Text("Delete your account and data anytime\nin Settings.")
                        .font(.footnote)
                        .foregroundStyle(Theme.neutral)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 28)
                .padding(.top, 16)
                .padding(.bottom, 16)
                .frame(maxWidth: 460)
                .frame(minHeight: geometry.size.height)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.panel)
        .sheet(isPresented: $showEmail) { EmailSignInView() }
    }

    private var brandLockup: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox.and.arrow.backward.fill")
                .font(.system(size: 28))
                .foregroundStyle(Theme.brand)
                .accessibilityHidden(true)
            Text("ParcelPilot")
                .font(.title3.weight(.semibold))
                .tracking(-0.5)
                .foregroundStyle(Theme.ink)
        }
        .accessibilityElement(children: .combine)
    }

    private var signInActions: some View {
        VStack(spacing: 12) {
            googleButton
            Button { showEmail = true } label: {
                Label("Continue with email", systemImage: "envelope")
                    .font(.body.weight(.medium))
            }
            .buttonStyle(SignInActionButtonStyle(filled: true))
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
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(working)
                .accessibilityIdentifier("signInWithApple")
            }

            if case .emulator = FirebaseBootstrap.mode {
                Button {
                    Task { await run { try await coordinator.session?.signInForEmulator() } }
                } label: {
                    Label("Sign in with emulator test account", systemImage: "hammer")
                }
                .buttonStyle(SignInActionButtonStyle(filled: false))
                .disabled(working)
                .accessibilityIdentifier("emulatorSignIn")
                Text("Local Firebase Emulator Suite — test data only.")
                    .font(.caption)
                    .foregroundStyle(Theme.neutral)
            }

            Text("Keep your routes in sync.")
                .font(.subheadline)
                .foregroundStyle(Theme.neutral)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
        }
    }

    @ViewBuilder private var googleButton: some View {
        switch coordinator.session?.googleSetup {
        case .ready:
            Button {
                Task { await run { try await coordinator.session?.signInWithGoogle() } }
            } label: {
                googleLabel
            }
            .buttonStyle(SignInActionButtonStyle(filled: false, google: true))
            .disabled(working)
            .accessibilityIdentifier("continueWithGoogle")
        case let .unavailable(message):
            VStack(spacing: 8) {
                Button {} label: { googleLabel }
                    .buttonStyle(SignInActionButtonStyle(filled: false, google: true))
                    .disabled(true)
                    .accessibilityIdentifier("continueWithGoogle")
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.neutral)
                    .multilineTextAlignment(.center)
            }
        case nil:
            EmptyView()
        }
    }

    private var googleLabel: some View {
        Text("Sign in with Google")
            .font(.custom("GoogleSans-Medium", size: 16, relativeTo: .body))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .overlay(alignment: .leading) {
                Image("GoogleSignInMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
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

/// Equal, flexible-height authentication controls; labels grow rather than clip at larger text sizes.
private struct SignInActionButtonStyle: ButtonStyle {
    var filled: Bool
    var google = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(filled ? Theme.onBrand : Theme.ink)
            .background(filled ? Theme.brand : Theme.panel,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                if !filled {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(google ? Theme.dynamic(light: 0x747775, dark: 0x8E918F) : Theme.hairline, lineWidth: 1)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.5)
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
