import ParcelPilotKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppServices.self) private var services
    @Environment(AppCoordinator.self) private var coordinator
    @State private var confirmSignOut = false
    @State private var deleting = false
    @State private var confirmErase = false
    @State private var error: String?
    @AppStorage(PilotTelemetry.consentKey) private var pilotExecutionLogging = false

    var body: some View {
        NavigationStack {
            let settings = services.settings.settings
            Form {
                Section("Delivering") {
                    Picker("Navigation app", selection: Binding(get: { settings.navigationApp }, set: { v in services.settings.update { $0.navigationApp = v } })) {
                        ForEach(NavigationApp.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .accessibilityIdentifier("navigationAppPicker")
                    Picker("Distance units", selection: Binding(get: { settings.distanceUnit }, set: { v in services.settings.update { $0.distanceUnit = v } })) {
                        ForEach(DistanceUnit.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Stepper("Default time at stop: \(DisplayFormat.serviceDuration(seconds: settings.defaultServiceSeconds))", value: Binding(get: { settings.defaultServiceSeconds }, set: { v in services.settings.update { $0.defaultServiceSeconds = v } }), in: 0...1800, step: 30)
                    Toggle("Start scanning in batch mode", isOn: Binding(get: { settings.batchScanDefault }, set: { v in services.settings.update { $0.batchScanDefault = v } }))
                }

                Section {
                    LabeledContent("Mode", value: services.mode.label)
                    LabeledContent("Account", value: coordinator.session?.account?.label ?? services.userLabel)
                        .accessibilityIdentifier("accountLabel")
                    if services.mode.isDemo {
                        Button("Leave demo mode") { coordinator.exitDemo() }
                        Button("Erase demo data", role: .destructive) { confirmErase = true }
                    } else {
                        Button("Sign out") { confirmSignOut = true }
                            .accessibilityIdentifier("signOut")
                        Button("Delete account and data", role: .destructive) { deleting = true }
                            .accessibilityIdentifier("deleteAccount")
                    }
                } header: {
                    Text("Account")
                } footer: {
                    if services.mode.isDemo { Text("Demo data stays on this iPhone. Locations are synthetic and route order is a straight-line estimate.") }
                }

                Section("Data and privacy") {
                    NavigationLink("What ParcelPilot stores") { PrivacyView() }
                    NavigationLink("Sync status") { SyncStatusView() }
                    NavigationLink("Configuration") { ConfigurationView() }
                    Toggle("Pilot work and session logging on this iPhone", isOn: $pilotExecutionLogging)
                        .accessibilityIdentifier("pilotSessionLogging")
                    Text("Optional work-action and route-session counts are logged on this iPhone. No addresses, notes, tracking numbers, locations or account identifiers are included. Nothing is uploaded.")
                        .font(.footnote).foregroundStyle(Theme.neutral)
                }

                if let error { Section { Banner(symbol: "exclamationmark.triangle", text: error, tone: .danger) } }

                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                    if services.mapStyle == .google || services.mode == .production {
                        Text("Maps and routing by Google Maps Platform.").font(.footnote).foregroundStyle(Theme.neutral)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Settings")
            .confirmationDialog("Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { signOut() }
            } message: {
                let pending = services.store.currentPendingKeys.union(services.store.pendingRouteKeys).count + services.photos.pending.count
                Text(pending > 0 ? "\(pending) change(s) or photo(s) haven't synced yet. Saved work stays on this iPhone for this account. Sign in with the same account to recover and sync it." : "Your routes stay in your account. Protected work on this iPhone remains bound to the same account.")
            }
            .confirmationDialog("Erase all demo data?", isPresented: $confirmErase, titleVisibility: .visible) {
                Button("Erase", role: .destructive) { try? services.account.signOut() }
            }
            .sheet(isPresented: $deleting) { AccountDeletionView() }
        }
    }

    private func signOut() {
        do {
            try services.account.signOut()
            coordinator.didEndSession()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Account deletion: confirm, sign in again (the server requires a recent sign-in; Apple accounts also
/// revoke the Apple sign-in), delete server data, then clear this device.
struct AccountDeletionView: View {
    @Environment(AppServices.self) private var services
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledged = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("All routes, stops, packages, delivery outcomes and photos in your account", systemImage: "trash")
                    Label(coordinator.session?.account?.method == .apple ? "Your ParcelPilot account (Sign in with Apple is disconnected)" : "Your ParcelPilot account and sign-in", systemImage: "person.crop.circle.badge.xmark")
                    Label("Data stored on this iPhone, including unsynced changes", systemImage: "iphone")
                } header: {
                    Text("This permanently deletes")
                } footer: {
                    Text("This can't be undone.")
                }
                Section {
                    Toggle("I understand this can't be undone", isOn: $acknowledged)
                        .accessibilityIdentifier("deleteAcknowledge")
                }
                Section {
                    ReauthenticateControls(actionTitle: "Delete account", role: .destructive, enabled: acknowledged) { appleCode in
                        try await services.account.deleteAccount(appleAuthorizationCode: appleCode)
                        dismiss()
                        coordinator.didEndSession()
                    }
                } footer: {
                    Text("For your security, confirm it's you before deleting.")
                }
            }
            .navigationTitle("Delete account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct PrivacyView: View {
    var body: some View {
        List {
            Section("Kept in your account") {
                Text("Routes, stops (the delivery address you confirmed), packages (tracking number, size, vehicle location, notes), delivery outcomes with their actual times, and optional proof-of-delivery photos.")
            }
            Section("Never stored or uploaded") {
                Text("Label photos and the full text read from labels. OCR runs on this iPhone and only the address you confirm is kept.")
                Text("Your location history. Location is read only when you ask to plan from where you are.")
            }
            Section("Map provider data") {
                Text("Coordinates from Google are kept for up to 30 days and refreshed as needed; route estimates (times, distances, lines) for 24 hours. Google place IDs are kept to refresh locations.")
                Text("Navigation hands the confirmed street address to Apple Maps or Google Maps. Apple Maps never receives Google data.")
            }
            Section("Logs and crash reports") {
                Text("Crash reports contain technical details only — never addresses, names, tracking numbers, notes or label text.")
            }
            Section("Where data is processed") {
                Text("Your account data is stored in Google Cloud's Montréal region (northamerica-northeast1). Address lookup and route optimization are Google Maps Platform services that may process requests outside Canada.")
            }
        }
        .navigationTitle("What ParcelPilot stores")
    }
}

struct ConfigurationView: View {
    @Environment(AppServices.self) private var services
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        List {
            LabeledContent("Mode", value: services.mode.label)
            LabeledContent("Firebase config", value: coordinator.config.hasFirebaseConfig ? "Present" : "Missing (GoogleService-Info.plist)")
            LabeledContent("Maps SDK key", value: coordinator.config.mapsAPIKey != nil ? "Present" : "Missing (GOOGLE_MAPS_IOS_API_KEY)")
            LabeledContent("Address lookup", value: services.resolver.provider.displayName)
            LabeledContent("Route optimizer", value: services.optimizer.provider.displayName)
            LabeledContent("Map", value: services.mapStyle == .google ? "Google Maps" : services.mapStyle == .apple ? "Apple Maps (synthetic data only)" : "Not configured")
            LabeledContent("Time-zone data", value: TimeZone.timeZoneDataVersion)
            if case let .emulator(host) = services.mode { LabeledContent("Emulator host", value: host) }
        }
        .navigationTitle("Configuration")
    }
}
