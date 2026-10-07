import ParcelPilotKit
import SwiftUI

struct DeliveryPanel: View {
    let snapshot: RouteSnapshot
    let planState: PlanTracker.PlanState
    @Binding var sheet: WorkspaceSheet?
    @Binding var selectedStopID: StopID?
    var backToPlanning: () -> Void
    var startRoute: () -> Void

    @Environment(AppServices.self) private var services
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.scenePhase) private var scenePhase
    @State private var outcomeSheet: OutcomeSheet?
    @State private var choosingNavApp: Stop?
    @State private var photoFor: PhotoTarget?
    @State private var navError: String?
    @State private var confirmFinish = false
    @State private var returnedFromNavigation: StopID?
    @State private var deselected: Set<PackageID> = []
    @State private var showMap = false
    @State private var showStops = false

    enum OutcomeSheet: Identifiable {
        case packages(Stop, OutcomeKind)
        case failure(Stop, [PackageID])
        var id: String {
            switch self {
            case let .packages(s, k): return "pk-\(s.id)-\(k.rawValue)"
            case let .failure(s, _): return "fail-\(s.id)"
            }
        }
    }

    struct PhotoTarget: Identifiable { var stopID: StopID; var packageIDs: [PackageID]; var id: String { stopID } }

    var body: some View {
        let next = snapshot.nextStop()
        let open = next.map { stop in snapshot.packages(for: stop.id).filter { !snapshot.ledger.status(of: $0.id).isHandled } } ?? []
        let chosen = open.map(\.id).filter { !deselected.contains($0) }
        let mixedWork = next.map { stop in snapshot.tasks.contains { $0.stopID == stop.id } } ?? false
        FocusLayout { collapsed in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(next.map { stop in "Stop \((snapshot.orderedStops.firstIndex { $0.id == stop.id } ?? 0) + 1) of \(snapshot.stops.count)" } ?? "Required work review")
                        .font(.stopProgress)
                    Spacer(minLength: 0)
                    Button { sheet = .finder } label: { Image(systemName: "magnifyingglass").frame(width: 44, height: 44).background(Theme.fill, in: Circle()) }
                        .accessibilityLabel("Find package").accessibilityIdentifier("findPackage")
                    Button { showStops = true } label: { Label("Stops", systemImage: "list.bullet").lineLimit(1) }
                        .buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("stopsSheet")
                }
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                ExecutionControls(snapshot: snapshot, start: startRoute)
                StatusLine(snapshot: snapshot)
                SyncStateRow()
                if services.mode.isDemo { DemoBadge() }
                Divider().overlay(Theme.hairline)
                if let next {
                    DeliveryDestination(stop: next, timeZone: snapshot.route.timeZone, collapsed: collapsed, details: { sheet = .stop(next.id) }, showMap: { showMap = true }, showFullNotes: mixedWork)
                    Button { sheet = .work(next.id) } label: {
                        Label("View stop work", systemImage: "checklist").frame(minHeight: 44)
                    }.accessibilityIdentifier("viewStopWork")
                }
            }
            .padding(16)
            .background(Theme.panel, in: UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22))
        } map: {
            RouteMapView(snapshot: snapshot, planState: planState, selectedStopID: $selectedStopID, bottomInset: 0, delivering: true)
                .overlay(alignment: .trailing) {
                    StopStrip(snapshot: snapshot, selectedStopID: $selectedStopID, all: { showStops = true }, details: { sheet = .stop($0) })
                        .padding(.trailing, 8)
                }
        } bottom: {
            VStack(alignment: .leading, spacing: 8) {
                if let toast = toasts.current, !showStops, outcomeSheet == nil, photoFor == nil {
                    UndoToast(message: toast.message, symbol: toast.symbol, tone: toast.tone, undo: toasts.undoAction(for: toast), extra: toast.extraTitle.flatMap { title in toast.extra.map { (title, $0) } })
                }
                if let id = returnedFromNavigation, let stop = snapshot.stops.first(where: { $0.id == id }), snapshot.ledger.stopStatus(stop, packages: snapshot.packages) != .completed {
                    Banner(symbol: "arrow.uturn.backward.circle", text: "Back from navigation. Record what happened at \(stop.address.streetLine ?? "this stop") — nothing was marked automatically.", tone: .info)
                        .accessibilityIdentifier("returnBanner")
                    if next?.id != id {
                        Button { sheet = .work(id) } label: {
                            Text("View unfinished stop work").frame(minHeight: 44)
                        }.accessibilityIdentifier("returnedStopWork")
                    }
                }
                if let next, mixedWork {
                    StopWorkContent(snapshot: snapshot, stop: next)
                } else if next != nil {
                    PackageSelectionList(packages: open, deselected: $deselected)
                } else if snapshot.stops.isEmpty {
                    StateMessageView(symbol: "shippingbox", title: "No stops on this route", message: "Add stops to begin delivering.", actions: [.init(title: "Add stops", symbol: "plus") { sheet = .addStops }])
                } else {
                    AllDoneCard(snapshot: snapshot) { confirmFinish = true }
                }
            }
            .padding(16)
            .background(Theme.panel, in: UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22))
        } actions: { collapsed in
            if let next {
                if mixedWork {
                    Button { navigate(to: next) } label: { Label("Navigate", systemImage: "location").frame(maxWidth: .infinity, minHeight: 44) }
                        .buttonStyle(SecondaryButtonStyle()).disabled(!NavigationLauncher.canNavigate(to: next))
                        .accessibilityIdentifier("navigate").padding(.horizontal, 16).padding(.bottom, 8)
                } else {
                ActionDeck(destination: [next.address.streetLine ?? next.address.singleLine, next.address.unitLabel].compactMap { $0 }.joined(separator: " · "), collapsed: collapsed, selectedCount: chosen.count, totalCount: open.count,
                    canNavigate: NavigationLauncher.canNavigate(to: next), navigate: { navigate(to: next) },
                    delivered: { record(.delivered, at: next, packageIDs: chosen) },
                    failed: { if !chosen.isEmpty { outcomeSheet = .failure(next, chosen) } },
                    skip: { act(.skipped, at: next) })
                }
            }
        }
        .fullScreenCover(isPresented: $showMap) {
            NavigationStack {
                RouteMapView(snapshot: snapshot, planState: planState, selectedStopID: $selectedStopID, bottomInset: 0, delivering: true)
                    .navigationTitle("Route map")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { showMap = false } } }
            }
        }
        .sheet(isPresented: $showStops) {
            StopsSheet(snapshot: snapshot, detail: { id in showStops = false; sheet = .stop(id) }, replan: { showStops = false; sheet = .optimize }, finish: { showStops = false; confirmFinish = true }, backToPlanning: { showStops = false; backToPlanning() })
        }
        .sheet(item: $outcomeSheet) { item in
            switch item {
            case let .packages(stop, kind):
                PackageOutcomeSheet(stop: stop, packages: snapshot.packages(for: stop.id).filter { !snapshot.ledger.status(of: $0.id).isHandled }, kind: kind) { chosen, reason in
                    record(kind, at: stop, packageIDs: chosen, reason: reason)
                }
            case let .failure(stop, ids):
                FailureReasonSheet { reason, note in record(.failed, at: stop, packageIDs: ids, reason: reason, note: note) }
            }
        }
        .sheet(item: $photoFor) { target in
            PODCaptureView(routeID: snapshot.route.id, stopID: target.stopID, packageIDs: target.packageIDs)
        }
        .confirmationDialog("Navigate with", isPresented: Binding(get: { choosingNavApp != nil }, set: { if !$0 { choosingNavApp = nil } }), titleVisibility: .visible) {
            Button("Apple Maps") { if let s = choosingNavApp { launch(s, .appleMaps) } }
            Button("Google Maps") { if let s = choosingNavApp { launch(s, .googleMaps) } }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $confirmFinish) {
            ExecutionFinishSheet(snapshot: snapshot) {
                guard services.store.finish(snapshot, confirmOutstandingWork: true).isCommitted else { return false }
                toasts.show("Route finished. Find it in History.", symbol: "flag.checkered", tone: .success)
                return true
            }
        }
        .alert("Couldn't open navigation", isPresented: Binding(get: { navError != nil }, set: { if !$0 { navError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(navError ?? "") }
        .onChange(of: snapshot.nextStop()?.id, initial: true) { _, id in selectedStopID = id; deselected = [] }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, let handoff = services.navigation.lastHandoff, handoff.routeID == snapshot.route.id else { return }
            if Date().timeIntervalSince(handoff.at) < 6 * 3600 { returnedFromNavigation = handoff.stopID; selectedStopID = handoff.stopID }
        }
    }

    private func visit(for id: StopID) -> PlannedVisit? {
        if case let .current(p) = planState { return p.visits.first { $0.stopID == id } }
        return nil
    }

    private func navigate(to stop: Stop) {
        switch services.settings.settings.navigationApp {
        case .ask: choosingNavApp = stop
        case let app: launch(stop, app)
        }
    }

    private func launch(_ stop: Stop, _ app: NavigationApp) {
        Task {
            do { try await services.navigation.open(stop: stop, routeID: snapshot.route.id, using: app) } catch { navError = error.localizedDescription }
        }
    }

    private func act(_ kind: OutcomeKind, at stop: Stop) {
        let open = snapshot.packages(for: stop.id).filter { !snapshot.ledger.status(of: $0.id).isHandled }
        guard !open.isEmpty else { return }
        if open.count > 1 && kind != .skipped {
            outcomeSheet = .packages(stop, kind)
        } else if kind == .failed {
            outcomeSheet = .failure(stop, open.map(\.id))
        } else {
            record(kind, at: stop, packageIDs: open.map(\.id))
        }
    }

    @discardableResult
    private func record(_ kind: OutcomeKind, at stop: Stop, packageIDs: [PackageID], reason: FailureReason? = nil, note: String? = nil) -> Bool {
        guard !packageIDs.isEmpty else { return false }
        let label = "\(kind == .delivered ? "Delivered" : kind == .failed ? "Failed" : "Skipped") \(stop.address.streetLine ?? "stop")"
        let ids = services.store.record(kind, packageIDs: packageIDs, stopID: stop.id, reason: reason, note: note, in: snapshot, label: label)
        guard !ids.isEmpty else {
            toasts.show(services.store.persistenceIssue ?? "No new outcome was recorded. Review the current work and sync status.", symbol: "exclamationmark.triangle", tone: .warning)
            return false
        }
        deselected = []
        if returnedFromNavigation == stop.id { returnedFromNavigation = nil; services.navigation.clearHandoff() }
        switch kind {
        case .delivered: Haptics.success()
        case .failed: Haptics.warning()
        default: Haptics.tap()
        }
        let openCount = snapshot.packages(for: stop.id).filter { !snapshot.ledger.status(of: $0.id).isHandled }.count
        let message = kind == .delivered && packageIDs.count < openCount ? "Delivered \(packageIDs.count) of \(openCount) at \(stop.address.streetLine ?? "stop")" : packageIDs.count > 1 ? "\(label) · \(packageIDs.count) packages" : label
        toasts.show(message, symbol: kind == .delivered ? "checkmark.circle.fill" : kind == .failed ? "xmark.octagon.fill" : "arrow.uturn.forward.circle.fill", tone: kind == .delivered ? .success : kind == .failed ? .danger : .warning, undoAcknowledged: {
            guard services.store.undo(outcomeIDs: ids, in: snapshot).isCommitted else { return false }
            Haptics.tap()
            return true
        }, extraTitle: kind == .delivered ? "Photo" : nil, extra: kind == .delivered ? { photoFor = PhotoTarget(stopID: stop.id, packageIDs: packageIDs) } : nil)
        return true
    }
}

struct AllDoneCard: View {
    var snapshot: RouteSnapshot
    var finish: () -> Void
    @Environment(AppServices.self) private var services

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            let summary = snapshot.workSummary
            Label(summary.outstanding > 0 ? "Required work remains" : "All required work handled", systemImage: summary.outstanding > 0 ? "arrow.uturn.forward.circle" : "flag.checkered")
                .font(.title3.weight(.semibold))
            Text("Completed \(summary.completed) · Failed \(summary.failed) · Deferred \(summary.deferred) · Excluded \(summary.excluded)")
                .font(.subheadline).foregroundStyle(Theme.neutral)
            if summary.pending > 0 { Text("\(summary.pending) required item(s) pending.").font(.subheadline) }
            if summary.unsupported > 0 { Text("\(summary.unsupported) required item(s) cannot be read safely. Resolve these before finishing.").font(.subheadline).foregroundStyle(Theme.danger) }
            if summary.deferred > 0 {
                Text("Open Stops to review deferred work, or explicitly finish with it on record.").font(.subheadline)
            }
            Button(action: finish) { Label("Finish route", systemImage: "flag.checkered") }
                .buttonStyle(PrimaryActionButtonStyle())
                .accessibilityIdentifier("finishRoute")
                .disabled(!services.store.finishReview(snapshot).canFinish)
        }
        .card()
    }
}

/// The presentation observes persisted driver intent. It never derives execution from the scene,
/// route status, navigation handoff, or the work reducer.
struct ExecutionControls: View {
    let snapshot: RouteSnapshot
    var showStartAction = true
    var start: () -> Void
    @Environment(AppServices.self) private var services

    var body: some View {
        let session = services.store.executionSession(for: snapshot.route.id)
        if let session, session.state == .active || session.state == .paused {
            HStack(spacing: 12) {
                Label {
                    Text(session.state == .paused ? "Route paused" : "Route running")
                        .accessibilityIdentifier("executionStatus")
                } icon: {
                    Image(systemName: session.state == .paused ? "pause.circle.fill" : "steeringwheel")
                        .accessibilityHidden(true)
                }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(session.state == .paused ? Theme.warning : Theme.brand)
                Spacer(minLength: 0)
                if session.state == .active {
                    Button("Pause") { services.store.pauseExecution(snapshot) }
                        .frame(minHeight: 44).accessibilityIdentifier("pauseExecution")
                } else {
                    Button("Resume route") { services.store.resumeExecution(snapshot) }
                        .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("resumeExecution")
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        } else if let current = services.store.executionSession,
                  current.state == .active || current.state == .paused,
                  current.routeID != snapshot.route.id {
            Button("Return to \(current.state == .paused ? "paused" : "running") route") { services.store.returnToExecutionRoute() }
                .frame(minHeight: 44).accessibilityIdentifier("returnToExecutionRoute")
        } else if showStartAction {
            VStack(alignment: .leading, spacing: 4) {
                Text("Route not started").font(.subheadline).foregroundStyle(Theme.neutral)
                    .accessibilityIdentifier("executionStatus")
                Button("Start route", action: start)
                    .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("startDelivering")
            }
        }
    }
}

/// One explicit close-out review, including the exact required obligations that stay unfinished.
/// It records no work outcomes and uses the same WorkLedger-derived review as the store guard.
struct ExecutionFinishSheet: View {
    let snapshot: RouteSnapshot
    var finish: () -> Bool
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    private var live: RouteSnapshot { services.store.current?.route.id == snapshot.route.id ? services.store.current! : snapshot }

    var body: some View {
        let review = services.store.finishReview(live)
        NavigationStack {
            List {
                if let issue = services.store.persistenceIssue {
                    Section { Banner(symbol: "exclamationmark.triangle", text: issue, tone: .danger) }
                }
                Section("Required work") {
                    LabeledContent("Completed", value: "\(review.summary.completed)")
                    LabeledContent("Failed (unsuccessful)", value: "\(review.summary.failed)")
                    LabeledContent("Excluded", value: "\(review.summary.excluded)")
                    LabeledContent("Pending", value: "\(review.summary.pending)")
                    LabeledContent("Deferred", value: "\(review.summary.deferred)")
                    if review.summary.unsupported > 0 { LabeledContent("Unsupported", value: "\(review.summary.unsupported)") }
                }
                if !review.remaining.isEmpty {
                    Section {
                        ForEach(review.remaining) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                if let stop = live.stops.first(where: { $0.id == item.stopID }) {
                                    Text([stop.address.streetLine ?? stop.address.singleLine, stop.address.unitLabel].compactMap { $0 }.joined(separator: " · "))
                                        .font(.headline)
                                }
                                Text(workTitle(item)).font(.subheadline)
                                Text(stateLabel(item.state)).font(.subheadline.weight(.semibold)).foregroundStyle(item.state == .unsupported ? Theme.danger : Theme.warning)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } header: { Text("Unfinished required work") }
                    footer: { Text("These items stay unfinished on record. Finishing records no successful outcomes for them.") }
                } else {
                    Section { Text("All required work has an outcome. Failed work remains unsuccessful.") }
                }
                if review.summary.optional > 0 {
                    Section { Text("\(review.summary.optional) optional item(s) do not block Finish.") }
                }
                if !review.canFinish {
                    Section { Text("This route cannot finish until unreadable or unsupported required work is resolved.").foregroundStyle(Theme.danger) }
                }
            }
            .navigationTitle("Finish this route?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                Button("Finish route") { if finish() { dismiss() } }
                    .buttonStyle(PrimaryButtonStyle()).disabled(!review.canFinish)
                    .accessibilityIdentifier("confirmFinishRoute")
                    .padding(16).background(Theme.panel)
            }
        }
        .presentationDetents(review.remaining.isEmpty ? [.medium, .large] : [.large])
    }

    private func workTitle(_ item: ExecutionRemainingWork) -> String {
        if !item.title.isEmpty { return item.title }
        if item.kind == .delivery {
            let task = live.workLedger.allTasks.first { $0.id == item.taskID }
            let package = live.packages.first { $0.id == task?.packageID }
            return ["Delivery", package?.trackingID, package?.storageLocation].compactMap { $0 }.joined(separator: " · ")
        }
        if item.kind == .pickup { return "Pickup" }
        if item.kind == .checklist { return "Checklist item" }
        return "Unsupported work"
    }
    private func stateLabel(_ state: WorkState) -> String {
        switch state {
        case .pending: return "Pending"
        case .deferred: return "Deferred"
        case .unsupported: return "Unsupported — review required"
        case .completed: return "Completed"
        case .failed: return "Failed (unsuccessful)"
        case .excluded: return "Excluded"
        }
    }
}

/// Skipped and failed packages stay visible until the driver deliberately retries or excludes them.
struct NeedsDecisionSection: View {
    let snapshot: RouteSnapshot
    var openWork: ((StopID) -> Void)? = nil
    @Environment(AppServices.self) private var services
    @Environment(ToastCenter.self) private var toasts
    private func needsDecision(_ package: Package) -> Bool {
        switch snapshot.ledger.status(of: package.id) { case .skipped, .failed: true; default: false }
    }
    var body: some View {
        let stops = snapshot.orderedStops.filter { snapshot.packages(for: $0.id).contains(where: needsDecision) }
        if !stops.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Needs a decision").font(.footnote.bold()).tracking(0.4).foregroundStyle(Theme.neutral)
                ForEach(stops) { stop in
                    let packages = snapshot.packages(for: stop.id).filter(needsDecision)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 12) {
                            StopBadge(number: (snapshot.orderedStops.firstIndex { $0.id == stop.id } ?? 0) + 1, state: .make(stop: stop, snapshot: snapshot))
                            VStack(alignment: .leading, spacing: 4) {
                                Text([stop.address.streetLine, stop.address.unitLabel].compactMap { $0 }.joined(separator: " · ")).font(.headline)
                                Text(Array(Set(packages.map { snapshot.ledger.status(of: $0.id).label })).sorted().joined(separator: " · ") + " · \(packages.count) packages").font(.subheadline).foregroundStyle(Theme.danger)
                            }
                        }
                        HStack(spacing: 8) {
                            Button("Retry later") { decide(.requeued, packages, stop, "Back on the route") }.buttonStyle(ActionButtonStyle(tint: Theme.brand, fill: Theme.brandSoft))
                            Button("Exclude") { decide(.excluded, packages, stop, "Excluded from this route") }.buttonStyle(ActionButtonStyle())
                        }
                    }
                }
            }
        }
        let independent = snapshot.workLedger.allTasks.filter { task in
            task.kind != .delivery && { switch snapshot.workLedger.status(of: task.id) { case .failed, .deferred, .unsupported: true; default: false } }()
        }
        if !independent.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Pickup & checklist work to review").font(.headline)
                ForEach(snapshot.orderedStops.filter { stop in independent.contains { $0.stopID == stop.id } }) { stop in
                    Button {
                        openWork?(stop.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text([stop.address.streetLine, stop.address.unitLabel].compactMap { $0 }.joined(separator: " · ")).font(.headline)
                            ForEach(independent.filter { $0.stopID == stop.id }) { task in
                                let state = snapshot.workLedger.status(of: task.id)
                                Text(task.title + " · " + (state == .unsupported ? "Unsupported — review required" : { if case .deferred = state { "Deferred — unfinished" } else { "Failed — unsuccessful" } }()))
                                    .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                            }
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.buttonStyle(.row).accessibilityIdentifier("reviewStopWork.\(stop.id)")
                }
            }
        }
    }
    private func decide(_ kind: OutcomeKind, _ packages: [Package], _ stop: Stop, _ message: String) {
        let ids = services.store.record(kind, packageIDs: packages.map(\.id), stopID: stop.id, in: snapshot, label: message)
        guard !ids.isEmpty else {
            toasts.show(services.store.persistenceIssue ?? "No new outcome was recorded. Review the current work.", symbol: "exclamationmark.triangle", tone: .warning)
            return
        }
        toasts.show(message, symbol: kind == .requeued ? "arrow.counterclockwise" : "minus.circle", tone: .neutral, undoAcknowledged: { services.store.undo(outcomeIDs: ids, in: snapshot).isCommitted })
    }
}

/// Choose which packages at a multi-package stop get the outcome.
struct PackageOutcomeSheet: View {
    var stop: Stop
    var packages: [Package]
    var kind: OutcomeKind
    var onDone: ([PackageID], FailureReason?) -> Bool
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<PackageID> = []
    @State private var reason: FailureReason?

    var body: some View {
        NavigationStack {
            List {
                if let issue = services.store.persistenceIssue {
                    Section { Banner(symbol: "exclamationmark.triangle", text: issue, tone: .danger) }
                }
                Section {
                    Button(kind == .delivered ? "Deliver all \(packages.count)" : "All \(packages.count) failed") {
                        chosen = Set(packages.map(\.id))
                    }
                    .font(.headline)
                }
                Section("Packages") {
                    ForEach(Array(packages.enumerated()), id: \.element.id) { index, p in
                        Button {
                            if chosen.contains(p.id) { chosen.remove(p.id) } else { chosen.insert(p.id) }
                        } label: {
                            HStack {
                                Image(systemName: chosen.contains(p.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(Theme.brand)
                                VStack(alignment: .leading) {
                                    Text(p.storageLocation ?? "Package").font(.body.weight(.semibold))
                                    Text([p.trackingID, p.size?.label, p.recipientName].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.neutral)
                                }
                            }
                            .frame(minHeight: Theme.minTouch)
                        }
                        .accessibilityIdentifier("outcomePackage.\(index)")
                        .accessibilityAddTraits(chosen.contains(p.id) ? .isSelected : [])
                    }
                }
                if kind == .failed {
                    Section("Reason") {
                        ReasonGrid(selection: $reason)
                    }
                }
            }
            .navigationTitle(kind == .delivered ? "Mark delivered" : "Mark failed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { if onDone(Array(chosen), reason) { dismiss() } }
                        .disabled(chosen.isEmpty || (kind == .failed && reason == nil))
                        .accessibilityIdentifier("savePackageOutcome")
                }
            }
            .onAppear { chosen = Set(packages.map(\.id)) }
        }
        .presentationDetents(kind == .failed ? [.large] : [.medium, .large])
    }
}

struct FailureReasonSheet: View {
    var title = "Delivery failed"
    var prompt = "Why couldn't it be delivered?"
    var onDone: (FailureReason, String?) -> Bool
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var reason: FailureReason?
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                if let issue = services.store.persistenceIssue {
                    Section { Banner(symbol: "exclamationmark.triangle", text: issue, tone: .danger) }
                }
                Section(prompt) { ReasonGrid(selection: $reason) }
                Section("Note (optional)") { TextField("e.g. Gate code not working", text: $note, axis: .vertical) }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { if let reason, onDone(reason, note) { dismiss() } }
                        .disabled(reason == nil || note.count > 500)
                        .accessibilityIdentifier("saveFailure")
                }
            }
        }
        .presentationDetents([.large])
    }
}

struct ReasonGrid: View {
    @Binding var selection: FailureReason?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.Space.s)], spacing: Theme.Space.s) {
            ForEach(FailureReason.allCases, id: \.self) { r in
                Button {
                    selection = r
                    Haptics.selection()
                } label: {
                    Label(r.label, systemImage: r.symbolName)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: Theme.minTouch + 8, alignment: .leading)
                        .padding(.horizontal, Theme.Space.s)
                        .foregroundStyle(selection == r ? Theme.onBrand : Theme.danger)
                        .background(selection == r ? Theme.danger : Theme.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.m))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == r ? .isSelected : [])
                .accessibilityIdentifier("reason.\(r.rawValue)")
            }
        }
        .padding(.vertical, Theme.Space.xs)
    }
}
