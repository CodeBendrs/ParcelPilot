import FirebaseAuth
import Foundation
import Observation

/// Decides what the app shows: demo session, sign-in, a signed-in session, or a configuration notice.
@MainActor
@Observable
final class AppCoordinator {
    enum Phase {
        case launching
        /// No usable Firebase configuration in this build (demo mode is still available).
        case welcome(unconfigured: Bool)
        case signIn
        case ready(AppServices)
    }

    private(set) var phase: Phase = .launching
    let config: AppConfiguration
    private(set) var session: FirebaseSession?
    private let defaults: UserDefaults
    private static let demoKey = "pp.demoSelected"
    private var observation: Task<Void, Never>?

    init(config: AppConfiguration = .load(), defaults: UserDefaults = .standard) {
        self.config = config
        self.defaults = defaults
        FirebaseBootstrap.configureIfPossible(config)
        if config.forceDemo || defaults.bool(forKey: Self.demoKey) {
            phase = .ready(.demo(config: config))
        } else if FirebaseBootstrap.isConfigured {
            // UI-test hook, emulator builds only: start at the sign-in screen.
            if case .emulator = FirebaseBootstrap.mode, defaults.bool(forKey: "PPSignOutOnLaunch") {
                FirebaseSession.signOutRequested = true
                try? Auth.auth().signOut()
            }
            session = FirebaseSession()
            observeSession()
        } else {
            phase = .welcome(unconfigured: true)
        }
    }

    var services: AppServices? {
        if case let .ready(s) = phase { return s }
        return nil
    }

    var canUseAccounts: Bool { FirebaseBootstrap.isConfigured }

    func startDemo() {
        defaults.set(true, forKey: Self.demoKey)
        phase = .ready(.demo(config: config))
    }

    func exitDemo() {
        defaults.set(false, forKey: Self.demoKey)
        if FirebaseBootstrap.isConfigured {
            if session == nil { session = FirebaseSession(); observeSession() }
            apply(session?.state ?? .signedOut)
        } else {
            phase = .welcome(unconfigured: true)
        }
    }

    private func observeSession() {
        observation?.cancel()
        observation = Task { [weak self] in
            var last: FirebaseSession.State?
            while !Task.isCancelled {
                guard let self, let session = self.session else { return }
                let state = session.state
                if state != last { self.apply(state); last = state }
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    withObservationTracking { _ = session.state } onChange: { c.resume() }
                }
            }
        }
    }

    private func apply(_ state: FirebaseSession.State) {
        if defaults.bool(forKey: Self.demoKey) || config.forceDemo { return }
        switch state {
        case .loading: phase = .launching
        case .signedOut: phase = .signIn
        case let .signedIn(uid):
            if case let .ready(existing) = phase, existing.mode != .demo, existing.firestoreBackend?.uid == uid { return }
            let mode = FirebaseBootstrap.mode ?? .production
            let label = session?.account?.label ?? "Account"
            phase = .ready(.firebase(uid: uid, mode: mode, config: config, userLabel: label))
        }
    }

    /// Called after sign-out or account deletion.
    func didEndSession() {
        if services?.mode == .demo {
            exitDemo()
        } else {
            phase = .signIn
        }
    }
}
