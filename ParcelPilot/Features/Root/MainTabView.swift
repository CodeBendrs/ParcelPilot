import ParcelPilotKit
import SwiftUI

enum AppTab: Hashable { case route, scan, history, settings }

/// Route, Scan and History are one tap away; Settings is the fourth tab.
struct MainTabView: View {
    @Environment(AppServices.self) private var services
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSessionProblem = false
    @State private var tab: AppTab = {
        // Screenshot/UI-test hook: -PPInitialTab scan|history|settings
        switch UserDefaults.standard.string(forKey: "PPInitialTab") {
        case "scan": return .scan
        case "history": return .history
        case "settings": return .settings
        default: return .route
        }
    }()
    @State private var toasts = ToastCenter()

    var body: some View {
        TabView(selection: $tab) {
            RouteTab(selectTab: { tab = $0 })
                .tabItem { Label("Route", systemImage: "map") }
                .tag(AppTab.route)
                .accessibilityIdentifier("tab.route")
            ScanTab(selectTab: { tab = $0 })
                .tabItem { Label("Scan", systemImage: "barcode.viewfinder") }
                .tag(AppTab.scan)
            HistoryView(selectTab: { tab = $0 })
                .toasts(toasts)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(AppTab.history)
            SettingsView()
                .toasts(toasts)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let issue = services.store.persistenceIssue ?? services.photos.storageIssue {
                Banner(symbol: "exclamationmark.triangle", text: issue, tone: .danger)
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.bottom, Theme.Space.xs)
                    .accessibilityIdentifier("localPersistenceBanner")
            }
            if coordinator.session?.needsSignInAgain == true {
                Banner(symbol: "person.crop.circle.badge.exclamationmark", text: "Sign in again — changes on this iPhone aren't syncing.", tone: .danger, actionTitle: "Fix") { showSessionProblem = true }
                    .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.bottom, Theme.Space.xs)
                    .accessibilityIdentifier("sessionProblemBanner")
            } else if coordinator.session?.account?.needsEmailVerification == true {
                VerifyEmailBanner()
                    .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.bottom, Theme.Space.xs)
                    .accessibilityIdentifier("verifyEmailBanner")
            }
        }
        .sheet(isPresented: $showSessionProblem) { SessionProblemView() }
        // Last, so the banners above the tabs and the sheets can show toasts too.
        .environment(toasts)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await coordinator.session?.validate()
                    await services.backgroundSync()
                }
            }
        }
    }
}

/// The saved sign-in no longer works. The driver chooses: sign in again with the same account (queued
/// changes then sync) or sign out while protected work remains bound to its original account.
struct SessionProblemView: View {
    @Environment(AppServices.self) private var services
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var confirmSignOut = false

    var body: some View {
        let pendingChanges = services.store.currentPendingKeys.union(services.store.pendingRouteKeys).count
        let pendingPhotos = services.photos.pending.count
        NavigationStack {
            Form {
                Section {
                    Text("This iPhone's saved sign-in was refused. The account may have been deleted or disabled on another device, or its password or sign-in changed.")
                    if pendingChanges + pendingPhotos > 0 {
                        Label("\(pendingChanges) change\(pendingChanges == 1 ? "" : "s") and \(pendingPhotos) photo\(pendingPhotos == 1 ? "" : "s") are saved on this iPhone and waiting to sync.", systemImage: "iphone")
                    }
                }
                if coordinator.session?.account?.method == .emulator {
                    Section {
                        Text("Emulator test accounts can't sign in again. Sign out to start a new test session.").foregroundStyle(Theme.neutral)
                    }
                } else {
                    Section {
                        ReauthenticateControls(actionTitle: "Sign in again") { _ in
                            dismiss()
                            await services.backgroundSync()
                        }
                    } footer: {
                        Text("Use the same account as before. Your queued changes then sync to it.")
                    }
                }
                Section {
                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                        .accessibilityIdentifier("sessionSignOut")
                } footer: {
                    Text("Saved work and queued photos stay on this iPhone for this account. Sign in with the same account to recover and sync them.")
                }
                if let error { Banner(symbol: "exclamationmark.triangle.fill", text: error, tone: .danger) }
            }
            .navigationTitle("Sign in again")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } } }
            .confirmationDialog("Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    do {
                        try services.account.signOut()
                        dismiss()
                        coordinator.didEndSession()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
        }
    }
}

/// Email accounts confirm their address before address checks and route planning (paid Google
/// services) work. Both actions are on the banner: refresh after opening the link, or resend it.
struct VerifyEmailBanner: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var working = false

    var body: some View {
        let email = coordinator.session?.account?.email ?? "your email"
        let buttons = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.s)) : AnyLayout(HStackLayout(spacing: Theme.Space.l))
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Image(systemName: "envelope.badge").foregroundStyle(Theme.warning).font(.body.weight(.semibold)).accessibilityHidden(true)
                Text("Confirm \(email) to check addresses and plan routes — open the link we sent.")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons {
                Button("I've confirmed it") { Task { await refresh() } }
                    .accessibilityIdentifier("emailVerifiedRefresh")
                Button("Resend link") { Task { await resend(email) } }
                    .accessibilityIdentifier("emailResend")
                if working { ProgressView() }
            }
            .font(.subheadline.weight(.semibold))
            .disabled(working)
            .frame(minHeight: Theme.minTouch)
        }
        .padding(Theme.Space.m)
        .background(Theme.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func refresh() async {
        working = true
        defer { working = false }
        await coordinator.session?.refreshEmailVerification()
        if coordinator.session?.account?.needsEmailVerification == true {
            toasts.show("Not confirmed yet. Open the link in the email, then try again.", symbol: "envelope", tone: .warning)
        } else {
            toasts.show("Email confirmed", symbol: "checkmark.circle.fill", tone: .success)
        }
    }

    private func resend(_ email: String) async {
        working = true
        defer { working = false }
        do {
            try await coordinator.session?.resendVerificationEmail()
            toasts.show("Link sent to \(email)", symbol: "paperplane", tone: .success)
        } catch {
            toasts.show(error.localizedDescription, symbol: "exclamationmark.triangle", tone: .warning)
        }
    }
}

/// Small toolbar indicator: synced / saving / offline / rejected changes.
struct SyncStatusIndicator: View {
    @Environment(AppServices.self) private var services
    @State private var showDetails = false

    var body: some View {
        Button { showDetails = true } label: { label }
            .accessibilityIdentifier("syncStatus")
            .sheet(isPresented: $showDetails) { SyncStatusView().presentationDetents([.medium, .large]) }
    }

    @ViewBuilder private var label: some View {
        let failed = services.journal?.failed.count ?? 0
        let pendingDocs = services.store.currentPendingKeys.union(services.store.pendingRouteKeys).count
        let pendingPhotos = services.photos.pending.count
        if services.store.persistenceIssue != nil || services.photos.storageIssue != nil {
            Label("Saved work needs attention", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
        } else if services.mode.isDemo {
            Label("On this iPhone", systemImage: "iphone").labelStyle(.iconOnly).accessibilityLabel("Demo data is stored on this iPhone")
        } else if failed > 0 {
            Label("\(failed) need sync recovery", systemImage: "exclamationmark.icloud.fill").foregroundStyle(Theme.danger)
        } else if !services.connectivity.isOnline {
            Label("Offline", systemImage: "icloud.slash").foregroundStyle(Theme.warning)
        } else if pendingDocs + pendingPhotos > 0 {
            Label("Syncing", systemImage: "arrow.triangle.2.circlepath.icloud").foregroundStyle(Theme.brand)
        } else {
            Label("Synced", systemImage: "checkmark.icloud").foregroundStyle(Theme.success).labelStyle(.iconOnly).accessibilityLabel("All changes synced")
        }
    }
}

struct SyncStatusView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let issue = services.store.persistenceIssue ?? services.photos.storageIssue ?? error {
                        Banner(symbol: "exclamationmark.triangle", text: issue, tone: .danger)
                    }
                    if services.mode.isDemo {
                        Label("Demo mode stores everything on this iPhone. Nothing is uploaded.", systemImage: "iphone")
                    } else {
                        LabeledContent("Connection", value: services.connectivity.isOnline ? "Online" : "Offline — changes are saved on this iPhone")
                        LabeledContent("Changes waiting to sync", value: "\(services.store.currentPendingKeys.union(services.store.pendingRouteKeys).count)")
                        LabeledContent("Photos waiting to upload", value: "\(services.photos.pending.count)")
                    }
                }
                if let journal = services.journal, !journal.failed.isEmpty {
                    Section("Saved work needs sync recovery") {
                        ForEach(journal.failed) { entry in
                            VStack(alignment: .leading, spacing: Theme.Space.s) {
                                Text(entry.label).font(.headline)
                                Text(entry.lastError ?? "").font(.subheadline).foregroundStyle(Theme.neutral)
                                HStack {
                                    if !entry.ops.isEmpty || journal.isProtectedCommand(entry.id) {
                                        Button("Retry") {
                                            Task {
                                                guard await services.store.retrySavedCommand(entry.id).isCommitted else {
                                                    error = services.store.persistenceIssue ?? "This saved change still needs recovery. Its intent has been preserved."
                                                    return
                                                }
                                                error = nil
                                            }
                                        }.buttonStyle(SecondaryButtonStyle())
                                    }
                                }
                                Text("Saved intent stays on this iPhone until it is verified or recovered.").font(.footnote).foregroundStyle(Theme.neutral)
                            }
                            .padding(.vertical, Theme.Space.xs)
                        }
                    }
                }
                if !services.photos.pending.isEmpty {
                    Section("Photo uploads") {
                        ForEach(services.photos.pending) { photo in
                            LabeledContent("Photo (\(ByteCountFormatter.string(fromByteCount: Int64(photo.byteSize), countStyle: .file)))", value: photo.lastError ?? "Waiting to upload")
                        }
                        Button("Retry uploads now") { services.photos.resumeUploads() }
                    }
                }
            }
            .navigationTitle("Sync status")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
