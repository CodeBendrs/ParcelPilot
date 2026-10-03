import ParcelPilotKit
import SwiftUI

enum WorkspaceMode: String, CaseIterable, Identifiable {
    case plan, deliver
    var id: String { rawValue }
    var label: String { self == .plan ? "Plan" : "Deliver" }
}

enum WorkspaceSheet: Identifiable {
    case addStops, optimize, stop(StopID), settings, finder, reviewQueue, manualAdd, paste, csv
    var id: String {
        switch self {
        case let .stop(id): return "stop-\(id)"
        default: return String(describing: self)
        }
    }
}

/// The main experience: route map + ordered stop list (Plan) or next-stop card (Deliver).
struct RouteWorkspaceView: View {
    let snapshot: RouteSnapshot
    var selectTab: (AppTab) -> Void

    @Environment(AppServices.self) private var services
    @Environment(ToastCenter.self) private var toasts
    // Screenshot/UI-test hook: -PPInitialMode deliver
    @State private var mode: WorkspaceMode? = UserDefaults.standard.string(forKey: "PPInitialMode").flatMap(WorkspaceMode.init(rawValue:))
    @State private var detent: SheetDetent = .medium
    @State private var selectedStopID: StopID?
    @State private var tracker: PlanTracker?
    @State private var sheet: WorkspaceSheet?
    @State private var renaming = false
    @State private var newName = ""
    @State private var error: String?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var effectiveMode: WorkspaceMode { mode ?? (snapshot.route.status == .active ? .deliver : .plan) }

    /// Half-height panel share: Deliver needs the next stop and the actions visible together, and
    /// accessibility text sizes need room more than map area.
    private var mediumFraction: CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return 0.72 }
        return effectiveMode == .deliver ? 0.64 : 0.55
    }

    var body: some View {
        let planState = tracker?.state(for: snapshot) ?? .none
        MapSheetLayout(detent: $detent, mediumFraction: mediumFraction) { inset in
            RouteMapView(snapshot: snapshot, planState: planState, selectedStopID: $selectedStopID, bottomInset: inset)
                .ignoresSafeArea(edges: .bottom)
        } sheet: {
            VStack(spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.m) {
                    Picker("Mode", selection: Binding(get: { effectiveMode }, set: { mode = $0; if $0 == .deliver && detent == .collapsed { detent = .medium } })) {
                        ForEach(WorkspaceMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("workspaceMode")
                    SyncStatusIndicator()
                        .frame(minWidth: Theme.minTouch, minHeight: Theme.minTouch)
                }
                .padding(.horizontal, Theme.Space.l)
                switch effectiveMode {
                case .plan:
                    PlanPanel(snapshot: snapshot, planState: planState, selectedStopID: $selectedStopID, sheet: $sheet, selectTab: selectTab)
                case .deliver:
                    DeliveryPanel(snapshot: snapshot, planState: planState, sheet: $sheet, selectedStopID: $selectedStopID)
                }
            }
        }
        .navigationTitle(snapshot.route.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(item: $sheet) { item in sheetContent(item) }
        .alert("Rename route", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { if !newName.trimmingCharacters(in: .whitespaces).isEmpty { services.store.rename(snapshot.route, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Something went wrong", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
        .onAppear {
            if tracker == nil { tracker = PlanTracker(optimizer: services.optimizer) }
            tracker?.track(snapshot.route)
            Task { await services.verifier.verifyPendingStops(in: snapshot, store: services.store) }
        }
        .onChange(of: snapshot.route.appliedRequestID) { _, _ in tracker?.track(snapshot.route) }
        .onChange(of: selectedStopID) { _, id in if id != nil, detent == .collapsed { detent = .medium } }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { services.store.currentRouteID = nil } label: { Label("Routes", systemImage: "list.bullet") }
                .accessibilityIdentifier("allRoutes")
        }
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text(snapshot.route.name).font(.headline).lineLimit(1)
                HStack(spacing: 4) {
                    if services.mode.isDemo { Image(systemName: "theatermasks.fill").foregroundStyle(Theme.demo) }
                    Text((services.mode.isDemo ? "Demo · " : "") + "\(snapshot.stops.count) stops · \(snapshot.route.status.label)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { sheet = .finder } label: { Label("Find package", systemImage: "shippingbox.and.arrow.backward") }
                .accessibilityIdentifier("findPackage")
            Menu {
                Button("Route settings", systemImage: "slider.horizontal.3") { sheet = .settings }
                Button("Rename", systemImage: "pencil") { newName = snapshot.route.name; renaming = true }
                Button("Duplicate", systemImage: "plus.square.on.square") {
                    Task { do { _ = try await services.store.duplicate(snapshot.route) } catch { self.error = error.localizedDescription } }
                }
                Button("Archive", systemImage: "archivebox") { services.store.archive(snapshot.route) }
            } label: {
                Label("Route options", systemImage: "ellipsis.circle")
            }
            .accessibilityIdentifier("routeMenu")
        }
    }

    @ViewBuilder private func sheetContent(_ item: WorkspaceSheet) -> some View {
        switch item {
        case .addStops: AddStopsMenu(snapshot: snapshot, sheet: $sheet, selectTab: selectTab).presentationDetents([.medium])
        case .optimize: OptimizeSheet(snapshot: snapshot, defaultOrigin: effectiveMode == .deliver ? .currentLocation : .routeStart)
        case let .stop(id): StopDetailView(stopID: id)
        case .settings: RouteEditorView(route: snapshot.route)
        case .finder: PackageFinderView(snapshot: snapshot) { stopID in selectedStopID = stopID; sheet = .stop(stopID) }
        case .reviewQueue: ReviewQueueView(routeID: snapshot.route.id)
        case .manualAdd: ManualAddView(routeID: snapshot.route.id)
        case .paste: PasteImportView(routeID: snapshot.route.id)
        case .csv: CSVImportView(routeID: snapshot.route.id)
        }
    }
}

// MARK: - Plan panel

struct PlanPanel: View {
    let snapshot: RouteSnapshot
    let planState: PlanTracker.PlanState
    @Binding var selectedStopID: StopID?
    @Binding var sheet: WorkspaceSheet?
    var selectTab: (AppTab) -> Void
    @Environment(AppServices.self) private var services
    @State private var editMode: EditMode = .inactive

    @ViewBuilder private var addButtons: some View {
        Button { sheet = .addStops } label: { Label("Add stops", systemImage: "plus").labelStyle(.titleAndIcon).lineLimit(1) }
            .buttonStyle(SecondaryButtonStyle())
            .fixedSize()
            .accessibilityIdentifier("addStops")
        Button { selectTab(.scan) } label: { Label("Scan", systemImage: "barcode.viewfinder").labelStyle(.titleAndIcon).lineLimit(1) }
            .buttonStyle(SecondaryButtonStyle())
            .fixedSize()
    }

    @ViewBuilder private func reorderButton(hasStops: Bool) -> some View {
        if hasStops {
            Button(editMode.isEditing ? "Done" : "Reorder") { withAnimation { editMode = editMode.isEditing ? .inactive : .active } }
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
                .frame(minHeight: Theme.minTouch)
                .accessibilityIdentifier("reorder")
        }
    }

    var body: some View {
        let ordered = snapshot.orderedStops
        let ledger = snapshot.ledger
        let visitByStop: [StopID: PlannedVisit] = {
            if case let .current(p) = planState { return Dictionary(uniqueKeysWithValues: p.visits.map { ($0.stopID, $0) }) }
            return [:]
        }()
        ScrollViewReader { proxy in
            List {
                Section {
                    PlanSummaryCard(snapshot: snapshot, planState: planState) { sheet = .optimize }
                    PlanWarnings(snapshot: snapshot, sheet: $sheet)
                }
                .listRowSeparator(.hidden)
                Section {
                    // One row when it fits; otherwise wrap rather than truncate button titles.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Theme.Space.s) {
                            addButtons
                            Spacer()
                            reorderButton(hasStops: !ordered.isEmpty)
                        }
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            HStack(spacing: Theme.Space.s) { addButtons }
                            reorderButton(hasStops: !ordered.isEmpty)
                        }
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            addButtons
                            reorderButton(hasStops: !ordered.isEmpty)
                        }
                    }
                }
                .listRowSeparator(.hidden)

                if ordered.isEmpty {
                    Section {
                        StateMessageView(symbol: "shippingbox", title: "No stops yet", message: "Scan package labels, search for an address, paste a list or import a CSV.", actions: [
                            .init(title: "Scan labels", symbol: "barcode.viewfinder") { selectTab(.scan) },
                            .init(title: "Add stops another way", symbol: "plus") { sheet = .addStops },
                        ])
                        .frame(maxWidth: .infinity)
                    }
                    .listRowBackground(Color.clear)
                } else {
                    Section("\(ordered.count) stops · \(snapshot.packages.count) packages") {
                        ForEach(Array(ordered.enumerated()), id: \.element.id) { index, stop in
                            Button { sheet = .stop(stop.id) } label: {
                                StopRow(number: index + 1, stop: stop, packages: snapshot.packages(for: stop.id), status: ledger.stopStatus(stop, packages: snapshot.packages), visit: visitByStop[stop.id], timeZone: snapshot.route.timeZone, sync: services.store.syncState(forKey: "routes/\(snapshot.route.id)/stops/\(stop.id)"), selected: selectedStopID == stop.id)
                            }
                            .buttonStyle(.row)
                            .id(stop.id)
                            .listRowBackground(selectedStopID == stop.id ? Theme.brandSoft : nil)
                            .accessibilityIdentifier("stopRow.\(index + 1)")
                            .swipeActions(edge: .trailing) {
                                Button("Remove", role: .destructive) { services.store.delete(stop: stop, from: snapshot) }
                            }
                            .swipeActions(edge: .leading) {
                                Button("Deliver next") { services.store.setNextStop(stop.id, in: snapshot.route) }.tint(Theme.teal)
                            }
                        }
                        .onMove { from, to in
                            var ids = ordered.map(\.id)
                            ids.move(fromOffsets: from, toOffset: to)
                            services.store.reorder(ids, in: snapshot)
                            Haptics.selection()
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(Theme.Space.s)
            .contentMargins(.top, 0, for: .scrollContent)
            .environment(\.editMode, $editMode)
            .onChange(of: selectedStopID) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } } }
        }
    }
}

struct StopRow: View {
    var number: Int
    var stop: Stop
    var packages: [Package]
    var status: StopStatus
    var visit: PlannedVisit?
    var timeZone: TimeZone
    var sync: DocumentSyncState
    var selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            StopNumberView(number: number, status: status)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(stop.address.streetLine ?? stop.address.singleLine)
                        .font(.addressCompact)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let unit = stop.address.unitLabel { UnitBadge(label: unit) }
                }
                Text([stop.address.municipality, stop.address.postalCode].compactMap { $0 }.joined(separator: " "))
                    .font(.subheadline).foregroundStyle(.secondary)
                FlowRow {
                    StatusBadge(text: "\(packages.count) pkg", symbol: "shippingbox", tone: .neutral, compact: true)
                    if status != .pending { StatusBadge(text: status.label, symbol: status.symbol, tone: status.tone, compact: true) }
                    if stop.addressStatus != .verified { StatusBadge(text: stop.addressStatus.label, symbol: stop.addressStatus.symbol, tone: stop.addressStatus.tone, compact: true) }
                    if let w = stop.timeWindow { StatusBadge(text: w.kind == .hard ? "\(WallClock.label(w.startMinute ?? 0))–\(WallClock.label(w.endMinute))" : "By \(WallClock.label(w.endMinute))", symbol: w.kind == .hard ? "clock.badge.exclamationmark" : "clock", tone: .info, compact: true) }
                    if stop.pin != .none { StatusBadge(text: stop.pin == .first ? "First" : "Last", symbol: "pin.fill", tone: .info, compact: true) }
                    if let visit { StatusBadge(text: "ETA \(DisplayFormat.time(visit.arrival, timeZone: timeZone))", symbol: "clock.arrow.circlepath", tone: (visit.lateBySeconds ?? 0) > 0 ? .warning : .neutral, compact: true) }
                    if sync == .pending { StatusBadge(text: "Saving", symbol: "arrow.triangle.2.circlepath", tone: .neutral, compact: true) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = ["Stop \(number)", stop.address.streetLine ?? stop.address.singleLine]
        if let unit = stop.address.unitLabel { parts.append(unit) }
        parts.append("\(packages.count) package\(packages.count == 1 ? "" : "s")")
        parts.append(status.label)
        if stop.addressStatus != .verified { parts.append(stop.addressStatus.label) }
        if let visit { parts.append("estimated arrival \(DisplayFormat.time(visit.arrival, timeZone: timeZone))") }
        return parts.joined(separator: ", ")
    }
}

/// Wrapping row of small badges.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Summary & warnings

struct PlanSummaryCard: View {
    let snapshot: RouteSnapshot
    let planState: PlanTracker.PlanState
    var optimize: () -> Void
    @Environment(AppServices.self) private var services
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At accessibility text sizes the Optimize button goes below the status so neither wraps mid-word.
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.m)) : AnyLayout(HStackLayout(alignment: .center, spacing: Theme.Space.m))
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            layout {
                VStack(alignment: .leading, spacing: 2) {
                    switch planState {
                    case let .current(p):
                        if let m = p.metrics {
                            HStack(spacing: Theme.Space.l) {
                                Metric(title: "Duration", value: DisplayFormat.duration(seconds: m.totalSeconds))
                                Metric(title: "Distance", value: DisplayFormat.distance(meters: m.travelMeters, unit: services.settings.settings.distanceUnit))
                                Metric(title: "Finish", value: DisplayFormat.time(m.routeEnd, timeZone: snapshot.route.timeZone))
                            }
                        }
                    case .outdated:
                        Label("Times outdated", systemImage: "clock.badge.exclamationmark").font(.headline).foregroundStyle(Theme.warning)
                    case .none:
                        Label("Not optimized", systemImage: "point.topleft.down.to.point.bottomright.curvepath").font(.headline)
                        Text("Stops are in the order you arranged them.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                Button(action: optimize) {
                    Label(planStateIsCurrent ? "Re-optimize" : "Optimize", systemImage: "wand.and.stars")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, Theme.Space.m)
                        .frame(minHeight: Theme.minTouch)
                        .foregroundStyle(.white)
                        .background(Theme.brand, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(snapshot.stops.isEmpty)
                .opacity(snapshot.stops.isEmpty ? 0.5 : 1)
                .accessibilityIdentifier("optimize")
            }
            switch planState {
            case let .current(p):
                ProvenanceText(text: "\(p.provider.displayName). \(p.trafficLabel). Calculated \(DisplayFormat.dateTime(p.calculatedAt, timeZone: snapshot.route.timeZone)).")
                if !p.unassigned.isEmpty {
                    Banner(symbol: "exclamationmark.triangle.fill", text: "\(p.unassigned.count) stop\(p.unassigned.count == 1 ? "" : "s") couldn't be scheduled. Optimize again to see why.", tone: .danger)
                }
            case let .outdated(reason):
                Text(reason).font(.caption).foregroundStyle(.secondary)
            case .none:
                EmptyView()
            }
        }
    }

    private var planStateIsCurrent: Bool { if case .current = planState { return true }; return false }
}

struct Metric: View {
    var title: String
    var value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.metric)
        }
        .accessibilityElement(children: .combine)
    }
}

struct PlanWarnings: View {
    let snapshot: RouteSnapshot
    @Binding var sheet: WorkspaceSheet?
    @Environment(AppServices.self) private var services

    var body: some View {
        let needsReview = snapshot.stops.filter { [.needsReview, .unresolvable].contains($0.addressStatus) }
        let pending = snapshot.stops.filter { $0.addressStatus == .pendingVerification }
        let drafts = services.drafts.drafts(for: snapshot.route.id)
        let orphans = snapshot.orphanPackages
        VStack(spacing: Theme.Space.s) {
            if snapshot.route.start == nil {
                Banner(symbol: "mappin.slash", text: "Add a start location (or plan from your current location) before optimizing.", tone: .warning, actionTitle: "Set start") { sheet = .settings }
            }
            if !drafts.isEmpty {
                Banner(symbol: "tray.full", text: "\(drafts.count) scanned label\(drafts.count == 1 ? "" : "s") waiting for review.", tone: .warning, actionTitle: "Review") { sheet = .reviewQueue }
                    .accessibilityIdentifier("reviewQueueBanner")
            }
            if !needsReview.isEmpty {
                Banner(symbol: "exclamationmark.triangle", text: needsReview.count == 1 ? "1 stop needs address review and won't be optimized until it's fixed." : "\(needsReview.count) stops need address review and won't be optimized until they're fixed.", tone: .warning, actionTitle: "Review") { sheet = .stop(needsReview[0].id) }
            }
            if !pending.isEmpty {
                Banner(symbol: "icloud.slash", text: pending.count == 1 ? "1 stop needs address verification. It will be checked when you're online and isn't included in optimization yet." : "\(pending.count) stops need address verification. They'll be checked when you're online and aren't included in optimization yet.", tone: .warning)
            }
            if !orphans.isEmpty {
                Banner(symbol: "questionmark.square.dashed", text: "\(orphans.count) package\(orphans.count == 1 ? "" : "s") belong to a stop that was removed on another device. Open Find package to reassign or remove them.", tone: .warning, actionTitle: "Find") { sheet = .finder }
            }
        }
    }
}
