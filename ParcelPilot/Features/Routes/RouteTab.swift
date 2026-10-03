import ParcelPilotKit
import SwiftUI

struct RouteTab: View {
    @Environment(AppServices.self) private var services
    var selectTab: (AppTab) -> Void

    var body: some View {
        NavigationStack {
            content
        }
    }

    @ViewBuilder private var content: some View {
        let store = services.store
        if !store.routesLoaded {
            ProgressView("Loading routes…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.currentRouteID != nil {
            if let snapshot = store.current {
                RouteWorkspaceView(snapshot: snapshot, selectTab: selectTab)
            } else if store.currentLoaded {
                StateMessageView(symbol: "questionmark.folder", title: "Route unavailable", message: "This route was removed or isn't available on this device.", actions: [
                    .init(title: "Show all routes", symbol: "list.bullet") { store.currentRouteID = nil },
                ])
            } else {
                ProgressView("Opening route…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            RoutesHomeView()
        }
    }
}

/// List of open routes with create / resume / duplicate / archive.
struct RoutesHomeView: View {
    @Environment(AppServices.self) private var services
    @State private var showEditor = false
    @State private var renaming: Route?
    @State private var newName = ""
    @State private var error: String?

    var body: some View {
        let store = services.store
        List {
            if store.openRoutes.isEmpty {
                Section {
                    StateMessageView(symbol: "map", title: "No routes yet", message: "Create a route, then add stops by scanning labels, searching, pasting or importing a CSV.", actions: [
                        .init(title: "New route", symbol: "plus") { showEditor = true },
                    ] + (services.mode.isDemo ? [.init(title: "Load sample demo route", symbol: "sparkles") { DemoSeed.createSampleRoute(in: store) }] : []))
                    .frame(maxWidth: .infinity)
                }
                .listRowBackground(Color.clear)
            } else {
                Section("Open routes") {
                    ForEach(store.openRoutes) { route in
                        Button { store.currentRouteID = route.id } label: { RouteRow(route: route) }
                            .buttonStyle(.row)
                            .accessibilityIdentifier("route.\(route.name)")
                            .swipeActions {
                                Button("Archive") { store.archive(route) }.tint(Theme.neutral)
                            }
                            .contextMenu {
                                Button("Rename", systemImage: "pencil") { renaming = route; newName = route.name }
                                Button("Duplicate", systemImage: "plus.square.on.square") { duplicate(route) }
                                Button("Archive", systemImage: "archivebox") { store.archive(route) }
                            }
                    }
                }
            }
            if let error { Banner(symbol: "exclamationmark.triangle", text: error, tone: .danger) }
        }
        .navigationTitle("Routes")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { if services.mode.isDemo { DemoBadge() } }
            ToolbarItem(placement: .topBarTrailing) { SyncStatusIndicator() }
            ToolbarItem(placement: .primaryAction) {
                Button { showEditor = true } label: { Label("New route", systemImage: "plus") }
                    .accessibilityIdentifier("newRoute")
            }
        }
        .sheet(isPresented: $showEditor) { RouteEditorView(route: nil) }
        .alert("Rename route", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { if let r = renaming, !newName.trimmingCharacters(in: .whitespaces).isEmpty { store.rename(r, to: newName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func duplicate(_ route: Route) {
        Task {
            do { _ = try await services.store.duplicate(route) } catch { self.error = error.localizedDescription }
        }
    }
}

struct RouteRow: View {
    var route: Route

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: route.status == .active ? "steeringwheel" : "map")
                .font(.title3)
                .foregroundStyle(Theme.brand)
                .frame(width: Theme.minTouch, height: Theme.minTouch)
                .background(Theme.brandSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(route.name).font(.headline).foregroundStyle(.primary)
                Text("\(route.serviceDate) · \(route.status.label)").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .frame(minHeight: Theme.minTouch)
        .accessibilityElement(children: .combine)
    }
}
