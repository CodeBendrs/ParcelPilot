import ParcelPilotKit
import SwiftUI

enum WorkspaceMode: String, CaseIterable, Identifiable {
    case plan, deliver
    var id: String { rawValue }
    var label: String { self == .plan ? "Plan" : "Deliver" }
}

enum WorkspaceSheet: Identifiable {
    case addStops, optimize, stop(StopID), work(StopID), settings, finder, reviewQueue, manualAdd, paste, csv, stops
    var id: String {
        switch self {
        case let .stop(id): return "stop-\(id)"
        case let .work(id): return "work-\(id)"
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
    @State private var selectedStopID: StopID?
    @State private var tracker: PlanTracker?
    @State private var sheet: WorkspaceSheet?
    @State private var renaming = false
    @State private var newName = ""
    @State private var error: String?
    @State private var scanner = false
    @State private var finishFromStops = false
    @State private var confirmCurrentOrderStart = false
    @State private var planningHeaderHeight: CGFloat = 80
    @GestureState private var panelDragOffset: CGFloat = 0
    @SceneStorage("atlas.planList") private var listMode = false
    @SceneStorage("atlas.keptOrderRoute") private var keptRoute = ""
    @SceneStorage("atlas.keptOrderRevision") private var keptRevision = -1

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var execution: RouteExecutionSession? { services.store.executionSession(for: snapshot.route.id) }
    private var effectiveMode: WorkspaceMode {
        mode ?? ((execution?.state == .active || execution?.state == .paused) ? .deliver : .plan)
    }

    var body: some View {
        let planState = tracker?.state(for: snapshot) ?? .none
        Group {
            switch effectiveMode {
            case .plan:
                GeometryReader { geometry in
                    let availableHeight = max(0, geometry.size.height - planningHeaderHeight)
                    let collapsedHeight = min(availableHeight, max(320, geometry.size.height * 0.46))
                    let restingHeight = listMode ? availableHeight : collapsedHeight
                    let panelHeight = dynamicTypeSize.isAccessibilitySize ? availableHeight
                        : min(availableHeight, max(collapsedHeight, restingHeight - panelDragOffset))
                    let mapHeight = max(0, availableHeight - panelHeight)
                    VStack(spacing: 0) {
                        planningHeader
                            .fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { planningHeaderHeight = $0 }
                        if !dynamicTypeSize.isAccessibilitySize {
                            RouteMapView(snapshot: snapshot, planState: planState, selectedStopID: $selectedStopID, bottomInset: 0)
                                .frame(height: mapHeight)
                                .clipped()
                                .allowsHitTesting(mapHeight > 1)
                                .accessibilityHidden(mapHeight <= 1)
                        }
                        VStack(spacing: 0) {
                            if !dynamicTypeSize.isAccessibilitySize {
                                planningPanelHandle(restingHeight: restingHeight, collapsedHeight: collapsedHeight, expandedHeight: availableHeight)
                            }
                            PlanPanel(snapshot: snapshot, planState: planState, selectedStopID: $selectedStopID, sheet: $sheet, listMode: $listMode, keptOrder: keptRoute == snapshot.route.id && keptRevision == snapshot.route.inputRevision, scan: { scanner = true }, startDelivering: requestStart)
                        }
                        .background(Theme.panel)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22))
                        .toasts(toasts)
                        .frame(height: panelHeight)
                    }
                    .background(Theme.panel)
                    .coordinateSpace(name: "planningWorkspace")
                    .animation(reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.08), value: listMode)
                }
            case .deliver:
                DeliveryPanel(snapshot: snapshot, planState: planState, sheet: $sheet, selectedStopID: $selectedStopID, backToPlanning: { mode = .plan }, startRoute: requestStart)
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityHidden(sheet != nil || scanner || finishFromStops)
        .sheet(item: $sheet) { item in
            switch item {
            case .stops, .stop, .work: sheetContent(item)
            default: sheetContent(item).toasts(toasts)
            }
        }
        .fullScreenCover(isPresented: $scanner) {
            NavigationStack {
                ScanScreen(snapshot: snapshot, selectTab: selectTab)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { scanner = false } } }
            }
        }
        .sheet(isPresented: $finishFromStops) {
            ExecutionFinishSheet(snapshot: snapshot) {
                guard services.store.finish(snapshot, confirmOutstandingWork: true).isCommitted else { return false }
                toasts.show("Route finished. Find it in History.", symbol: "flag.checkered", tone: .success)
                return true
            }
        }
        .confirmationDialog("Start with your current stop order?", isPresented: $confirmCurrentOrderStart, titleVisibility: .visible) {
            Button("Use current order and start") { commitStart(useCurrentOrder: true) }
                .accessibilityIdentifier("confirmStartCurrentOrder")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("No current optimized order has been accepted. Your stop order will be used. Starting records your decision to run this route.")
        }
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
            if dynamicTypeSize.isAccessibilitySize { listMode = true }
            Task { await services.verifier.verifyPendingStops(in: snapshot, store: services.store) }
        }
        .onChange(of: snapshot.route.appliedRequestID) { _, _ in tracker?.track(snapshot.route) }
    }

    private func planningPanelHandle(restingHeight: CGFloat, collapsedHeight: CGFloat, expandedHeight: CGFloat) -> some View {
        Button { settlePlanningPanel(expanded: !listMode) } label: {
            Capsule()
                .fill(Theme.neutral.opacity(0.45))
                .frame(width: 40, height: 5)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("planningPanelHandle")
        .accessibilityLabel("Stops list")
        .accessibilityValue(listMode ? "Expanded" : "Collapsed")
        .accessibilityHint("Swipe up to show the full list, or down to show the map. Double tap to switch.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: settlePlanningPanel(expanded: true)
            case .decrement: settlePlanningPanel(expanded: false)
            @unknown default: break
            }
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .named("planningWorkspace"))
                .updating($panelDragOffset) { value, offset, _ in offset = value.translation.height }
                .onEnded { value in
                    let projectedOffset = value.predictedEndTranslation.height
                    let expanded: Bool
                    if value.translation.height < -44 || projectedOffset < -80 {
                        expanded = true
                    } else if value.translation.height > 44 || projectedOffset > 80 {
                        expanded = false
                    } else {
                        expanded = restingHeight - value.translation.height > (collapsedHeight + expandedHeight) / 2
                    }
                    settlePlanningPanel(expanded: expanded)
                }
        )
    }

    private func settlePlanningPanel(expanded: Bool) {
        withAnimation(reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.08)) {
            listMode = expanded
        }
    }

    private var planningHeader: some View {
        VStack(spacing: 0) {
        HStack(spacing: 8) {
            Button { services.store.currentRouteID = nil } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .accessibilityLabel("All routes").accessibilityIdentifier("allRoutes")
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.route.name).font(.system(.headline, design: .rounded, weight: .bold)).lineLimit(1)
                Text((services.mode.isDemo ? "Demo · " : "") + "Planning · \(snapshot.stops.count) stops · \(snapshot.packages.count) packages" + (services.connectivity.isOnline ? "" : " · Offline"))
                    .font(.subheadline).foregroundStyle(Theme.neutral).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { sheet = .finder } label: { Label("Find", systemImage: "magnifyingglass").lineLimit(1) }
                .buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("findPackage")
            routeMenu
        }
        .padding(.trailing, 8).padding(.vertical, 8)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .background(Theme.panel)
            ExecutionControls(snapshot: snapshot, showStartAction: false, start: requestStart)
                .padding(.horizontal, 16)
        }
    }

    private var routeMenu: some View {
        Menu {
            Button("Route settings", systemImage: "slider.horizontal.3") { sheet = .settings }
            Button("Rename", systemImage: "pencil") { newName = snapshot.route.name; renaming = true }
            Button("Duplicate", systemImage: "plus.square.on.square") {
                Task { do { _ = try await services.store.duplicate(snapshot.route) } catch { self.error = error.localizedDescription } }
            }
            Button("Archive", systemImage: "archivebox") { services.store.archive(snapshot.route) }
            if execution?.state == .active {
                Button("Pause route", systemImage: "pause.circle") { services.store.pauseExecution(snapshot) }
            } else if execution?.state == .paused {
                Button("Resume route", systemImage: "play.circle") {
                    if services.store.resumeExecution(snapshot).isCommitted { mode = .deliver }
                }
            } else {
                Button("Start route", systemImage: "steeringwheel", action: requestStart).accessibilityIdentifier("startDelivering")
            }
            if execution?.state == .active || execution?.state == .paused {
                Button("Finish route…", systemImage: "flag.checkered") { finishFromStops = true }
            }
            Button("Back to planning", systemImage: "pencil") { mode = .plan }.accessibilityIdentifier("backToPlanning")
            if snapshot.route.appliedRequestID != nil { Button("Re-optimize") { sheet = .optimize } }
        } label: {
            Image(systemName: "ellipsis").frame(width: 44, height: 44).background(Theme.fill, in: Circle())
        }
        .accessibilityLabel("Route options").accessibilityIdentifier("routeMenu")
    }

    private func requestStart() {
        if execution?.state == .paused {
            if services.store.resumeExecution(snapshot).isCommitted { mode = .deliver }
            return
        }
        if execution?.state == .active { mode = .deliver; return }
        let acceptedProposal = snapshot.route.appliedRequestID != nil && snapshot.route.appliedRevision == snapshot.route.inputRevision
        let explicitlyKeptOrder = keptRoute == snapshot.route.id && keptRevision == snapshot.route.inputRevision
        if acceptedProposal || explicitlyKeptOrder { commitStart(useCurrentOrder: explicitlyKeptOrder && !acceptedProposal) }
        else { confirmCurrentOrderStart = true }
    }

    private func commitStart(useCurrentOrder: Bool) {
        guard services.store.startExecution(snapshot, useCurrentOrder: useCurrentOrder).isCommitted else { return }
        mode = .deliver
    }

    @ViewBuilder private func sheetContent(_ item: WorkspaceSheet) -> some View {
        switch item {
        case .addStops: AddStopsMenu(snapshot: snapshot, sheet: $sheet, selectTab: selectTab).presentationDetents([.medium, .large])
        case .optimize: OptimizeSheet(snapshot: snapshot, defaultOrigin: effectiveMode == .deliver ? .currentLocation : .routeStart, keepOrder: { keptRoute = snapshot.route.id; keptRevision = snapshot.route.inputRevision })
        case let .stop(id): StopDetailView(stopID: id)
        case let .work(id): StopWorkView(routeID: snapshot.route.id, stopID: id)
        case .settings: RouteEditorView(route: snapshot.route)
        case .finder: PackageFinderView(snapshot: snapshot) { stopID in selectedStopID = stopID; sheet = .stop(stopID) }
        case .reviewQueue: ReviewQueueView(routeID: snapshot.route.id)
        case .manualAdd: ManualAddView(routeID: snapshot.route.id)
        case .paste: PasteImportView(routeID: snapshot.route.id)
        case .csv: CSVImportView(routeID: snapshot.route.id)
        case .stops: StopsSheet(snapshot: snapshot, detail: { sheet = .stop($0) }, replan: { sheet = .optimize }, finish: { sheet = nil; finishFromStops = true }, backToPlanning: { mode = .plan; sheet = nil })
        }
    }
}

// MARK: - Plan panel

struct PlanPanel: View {
    let snapshot: RouteSnapshot
    let planState: PlanTracker.PlanState
    @Binding var selectedStopID: StopID?
    @Binding var sheet: WorkspaceSheet?
    @Binding var listMode: Bool
    var keptOrder: Bool
    var scan: () -> Void
    var startDelivering: () -> Void
    @Environment(AppServices.self) private var services
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editMode: EditMode = .inactive
    private var ready: Bool { if case .current = planState { true } else { keptOrder } }

    var body: some View {
        VStack(spacing: 0) {
            if listMode || typeSize.isAccessibilitySize {
                PlanSummaryCard(snapshot: snapshot, planState: planState) { sheet = .optimize }.dynamicTypeSize(...DynamicTypeSize.xxxLarge).padding(16)
            }
            if !listMode && !typeSize.isAccessibilitySize, case let .current(proposal) = planState {
                ProvenanceText(text: proposal.provider == .demo ? "Straight-line demo estimate · not road travel times" : "Road travel estimate · not a guarantee").padding(.horizontal, 16)
            }
            ReviewAlertRow(snapshot: snapshot, sheet: $sheet).dynamicTypeSize(...DynamicTypeSize.xxxLarge).padding(.horizontal, 16)
            ViewThatFits(in: .horizontal) {
                HStack { sectionTitle; Spacer(); listControls }
                VStack(alignment: .leading, spacing: 0) { sectionTitle; HStack { listControls } }
            }
            .padding(.horizontal, 16)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            ScrollViewReader { proxy in
                List {
                    if snapshot.route.start == nil {
                        Banner(symbol: "mappin.slash", text: "Set a start, or optimize from your location.", tone: .warning, actionTitle: "Set start") { sheet = .settings }
                    }
                    if !snapshot.orphanPackages.isEmpty {
                        Banner(symbol: "questionmark.square.dashed", text: "\(snapshot.orphanPackages.count) packages need reassignment.", tone: .warning, actionTitle: "Find") { sheet = .finder }
                    }
                    if snapshot.stops.isEmpty {
                        StateMessageView(symbol: "shippingbox", title: "No stops yet", message: "Scan labels or add an address to begin.")
                    }
                    ForEach(Array(snapshot.orderedStops.enumerated()), id: \.element.id) { index, stop in
                        Button { sheet = .stop(stop.id) } label: {
                            StopRow(number: index + 1, stop: stop, packages: snapshot.packages(for: stop.id), status: snapshot.ledger.stopStatus(stop, packages: snapshot.packages), visit: visit(stop.id), timeZone: snapshot.route.timeZone, sync: services.store.syncState(forKey: "routes/\(snapshot.route.id)/stops/\(stop.id)"), selected: selectedStopID == stop.id, badge: .make(stop: stop, snapshot: snapshot), workCount: snapshot.tasks.filter { $0.stopID == stop.id }.count)
                        }
                        .buttonStyle(.row).id(stop.id)
                        .accessibilityIdentifier("stopRow.\(index + 1)")
                        .listRowBackground(selectedStopID == stop.id ? Theme.brandSoft : Theme.panel)
                        .swipeActions(edge: .trailing) {
                            Button("Remove", role: .destructive) {
                                guard services.store.delete(stop: stop, from: snapshot).isCommitted else { return }
                                toasts.show("Stop removed", symbol: "trash", tone: .neutral, undoAcknowledged: { services.store.restore(stop: stop, packages: snapshot.packages(for: stop.id), tasks: snapshot.tasks.filter { $0.stopID == stop.id }, in: snapshot.route.id).isCommitted })
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button("Deliver next") {
                                guard services.store.setNextStop(stop.id, in: snapshot.route).isCommitted else { return }
                                toasts.show("Set as next stop", symbol: "arrow.right.circle", tone: .info)
                            }
                        }
                    }
                    .onMove { from, to in
                        var ids = snapshot.orderedStops.map(\.id); ids.move(fromOffsets: from, toOffset: to)
                        guard services.store.reorder(ids, in: snapshot).isCommitted else { return }
                        Haptics.selection()
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .environment(\.editMode, $editMode)
                .onChange(of: selectedStopID) { _, id in
                    if let id { if reduceMotion { proxy.scrollTo(id, anchor: .center) } else { withAnimation { proxy.scrollTo(id, anchor: .center) } } }
                }
            }
            VStack(spacing: 4) {
                if !ready && !snapshot.stops.isEmpty {
                    Button("Optimize…") { sheet = .optimize }
                        .frame(minHeight: 44).disabled(!services.connectivity.isOnline).accessibilityIdentifier("optimize")
                }
                if typeSize.isAccessibilitySize {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) { scanButton; addButton }
                        primaryButton
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { footerButtons }
                        VStack(spacing: 8) { footerButtons }
                    }
                }
                if !ready && !snapshot.stops.isEmpty && !services.connectivity.isOnline {
                    Text("Optimizing needs a connection").font(.footnote).foregroundStyle(Theme.warning)
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .padding(.horizontal, 16).padding(.vertical, 8).background(Theme.panel)
        }
        .background(Theme.panel)
    }
    private var sectionTitle: some View { Text("STOPS · YOUR ORDER").font(.footnote.bold()).tracking(0.4).foregroundStyle(Theme.neutral) }
    private var listControls: some View {
        Group {
            Button(editMode.isEditing ? "Done" : "Edit order") { editMode = editMode.isEditing ? .inactive : .active; if editMode.isEditing { listMode = true } }
                .font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize().frame(minHeight: 44).accessibilityIdentifier("reorder")
            Button { listMode.toggle() } label: { Label(listMode ? "Map" : "Full list", systemImage: listMode ? "map" : "list.bullet").lineLimit(1).fixedSize() }
                .font(.subheadline.weight(.semibold)).frame(minHeight: 44).accessibilityIdentifier("planListToggle")
        }
    }
    private var scanButton: some View {
        Button(action: scan) { Label("Scan", systemImage: "barcode.viewfinder").lineLimit(1).fixedSize() }.buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("scanRoute")
    }
    private var addButton: some View {
        Button { sheet = .addStops } label: { Label("Add", systemImage: "plus").lineLimit(1).fixedSize() }.buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("addStops")
    }
    @ViewBuilder private var footerButtons: some View { scanButton; addButton; primaryButton }
    @ViewBuilder private var primaryButton: some View {
        if snapshot.stops.isEmpty {
            Button("Add stops") { sheet = .addStops }.buttonStyle(PrimaryButtonStyle())
        } else {
            if let session = services.store.executionSession, session.routeID != snapshot.route.id,
               session.state == .active || session.state == .paused {
                Button("Return to \(session.state == .paused ? "paused" : "running") route") { services.store.returnToExecutionRoute() }
                    .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("returnToExecutionRoute")
            } else {
                let state = services.store.executionSession(for: snapshot.route.id)?.state
                Button(state == .paused ? "Resume route" : state == .active ? "Continue route" : "Start route", action: startDelivering)
                    .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier(state == .paused ? "resumeExecution" : "startDelivering")
            }
        }
    }
    private func visit(_ id: StopID) -> PlannedVisit? { if case let .current(p) = planState { p.visits.first { $0.stopID == id } } else { nil } }
}

struct ReviewAlertRow: View {
    var snapshot: RouteSnapshot
    @Binding var sheet: WorkspaceSheet?
    @Environment(AppServices.self) private var services
    var body: some View {
        let stops = snapshot.orderedStops.filter { [.needsReview, .unresolvable, .pendingVerification].contains($0.addressStatus) }
        let drafts = services.drafts.drafts(for: snapshot.route.id)
        let count = stops.count + drafts.count
        if count > 0 {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(count > 1 ? "\(count) addresses need review" : stops.first?.address.streetLine ?? "Scanned label needs review").font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text(stops.first?.reviewReasons.first?.explanation ?? stops.first?.addressStatus.label ?? "Open the review queue").font(.subheadline).foregroundStyle(Theme.warning).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button("Review") { if !drafts.isEmpty { sheet = .reviewQueue } else if let first = stops.first { sheet = .stop(first.id) } }
                    .buttonStyle(ActionButtonStyle(tint: Theme.onBrand, fill: Theme.warning)).frame(width: 96)
            }
            .padding(12).background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.warning, lineWidth: 1))
            .accessibilityIdentifier("reviewQueueBanner")
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
    var badge: StopBadgeState? = nil
    var workCount = 0
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            StopBadge(number: number, state: badge ?? (status == .completed ? .delivered : status == .partial ? .partial : status == .skipped ? .skipped : .pending))
            VStack(alignment: .leading, spacing: 4) {
                let addressLayout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
                addressLayout {
                    Text(stop.address.streetLine ?? stop.address.singleLine)
                        .font(.addressCompact)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let unit = stop.address.unitLabel { Text(unit).font(.subheadline).foregroundStyle(Theme.neutral) }
                }
                Text([stop.address.municipality, stop.address.postalCode].compactMap { $0 }.joined(separator: " "))
                    .font(.subheadline).foregroundStyle(Theme.neutral)
                FlowRow {
                    StatusBadge(text: "\(packages.count) pkg", symbol: "shippingbox", tone: .neutral, compact: true)
                    if workCount > 0 { StatusBadge(text: "\(workCount) pickup/checklist", symbol: "checklist", tone: .neutral, compact: true) }
                    if status != .pending {
                        StatusBadge(text: workStatusLabel,
                            symbol: badge?.symbol ?? status.symbol,
                            tone: badge == .failed ? .danger : status == .completed && badge != .delivered ? .neutral : status.tone, compact: true)
                    }
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
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = ["Stop \(number)", stop.address.streetLine ?? stop.address.singleLine]
        if let unit = stop.address.unitLabel { parts.append(unit) }
        parts.append("\(packages.count) package\(packages.count == 1 ? "" : "s")")
        if workCount > 0 { parts.append("\(workCount) pickup/checklist items") }
        parts.append(workStatusLabel)
        if stop.addressStatus != .verified { parts.append(stop.addressStatus.label) }
        if let window = stop.timeWindow { parts.append(window.explanation) }
        if let visit { parts.append("estimated arrival \(DisplayFormat.time(visit.arrival, timeZone: timeZone))") }
        return parts.joined(separator: ", ")
    }

    private var workStatusLabel: String {
        if badge == .failed { return "Failed — unsuccessful" }
        if badge == .excluded { return "Excluded" }
        if status == .completed { return "Required work handled" }
        if status == .skipped { return "Deferred — unfinished" }
        if status == .empty, workCount > 0 { return "Optional work" }
        return status.label
    }
}

/// Wrapping row of small badges.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
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
            let size = view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
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
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch planState {
            case .none:
                Text("Not optimized").font(.headline)
                Text("Your order · No travel estimate calculated").font(.subheadline).foregroundStyle(Theme.neutral)
            case let .outdated(reason):
                Text("Order changed since optimizing — times outdated").font(.headline).foregroundStyle(Theme.warning)
                Text(reason).font(.footnote).foregroundStyle(Theme.neutral)
                Button("Re-optimize", action: optimize).frame(minHeight: 44)
            case let .current(proposal):
                Text("Optimized").font(.headline)
                if let metrics = proposal.metrics {
                    FlowRow(spacing: 12) {
                        Metric(title: "Duration", value: DisplayFormat.duration(seconds: metrics.totalSeconds))
                        Metric(title: "Distance", value: DisplayFormat.distance(meters: metrics.travelMeters, unit: services.settings.settings.distanceUnit))
                        Metric(title: "Finish", value: DisplayFormat.time(metrics.routeEnd, timeZone: snapshot.route.timeZone))
                    }
                }
                ProvenanceText(text: proposal.provider == .demo ? "Straight-line demo estimate · not road travel times · calculated \(DisplayFormat.time(proposal.calculatedAt, timeZone: snapshot.route.timeZone))" : "\(proposal.provider.displayName) · \(proposal.trafficLabel) · calculated \(DisplayFormat.time(proposal.calculatedAt, timeZone: snapshot.route.timeZone)) · not a guarantee")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Metric: View {
    var title: String
    var value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(Theme.neutral)
            Text(value).font(.metric)
        }
        .accessibilityElement(children: .combine)
    }
}
