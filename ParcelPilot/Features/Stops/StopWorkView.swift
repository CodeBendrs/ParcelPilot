import ParcelPilotKit
import SwiftUI

/// The identified-stop presentation seam used now by manual access and later by arrival assistance.
/// Opening this screen records no arrival, execution transition, or work outcome.
struct StopWorkView: View {
    let routeID: RouteID
    let stopID: StopID
    @Environment(AppServices.self) private var services
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            if let snapshot = services.store.current, snapshot.route.id == routeID,
               let stop = snapshot.stops.first(where: { $0.id == stopID }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        DeliveryDestination(stop: stop, timeZone: snapshot.route.timeZone, showFullNotes: true)
                        StopWorkContent(snapshot: snapshot, stop: stop, allowsEditing: true)
                    }.padding(16)
                }
                .toasts(toasts)
                .navigationTitle("Stop work")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() }.accessibilityIdentifier("closeStopWork") } }
                .onAppear { services.store.recordWorkPresentation(in: snapshot, stopID: stopID) }
            } else {
                StateMessageView(symbol: "questionmark.folder", title: "Stop unavailable", message: "Return to the selected route to review its work.", actions: [.init(title: "Close", symbol: nil) { dismiss() }])
            }
        }
        .presentationDetents([.large])
    }
}

/// Definition and state always come from one WorkLedger, including package delivery projections.
/// This content is shared by the current-stop workspace, stop details, and StopWorkView.
struct StopWorkContent: View {
    let snapshot: RouteSnapshot
    let stop: Stop
    var allowsEditing = false
    private let ledger: WorkLedger
    @Environment(AppServices.self) private var services
    @Environment(ToastCenter.self) private var toasts
    @State private var editor: WorkEditorTarget?
    @State private var failing: LocationTask?
    @State private var showHandled = false
    @State private var submitting = false
    @State private var error: String?
    @AccessibilityFocusState private var focusedStatus: TaskID?

    init(snapshot: RouteSnapshot, stop: Stop, allowsEditing: Bool = false) {
        self.snapshot = snapshot
        self.stop = stop
        self.allowsEditing = allowsEditing
        ledger = snapshot.workLedger
    }
    private var tasks: [LocationTask] { ledger.tasks(at: stop.id) }
    private var isOpen: Bool { snapshot.route.status == .planning || snapshot.route.status == .active }
    private var requiredOutstanding: [LocationTask] { tasks.filter { $0.required && !ledger.status(of: $0.id).isHandled } }
    private var needsReview: [LocationTask] {
        tasks.filter { task in
            guard task.required else { return false }
            if case .failed = ledger.status(of: task.id) { return true }
            return false
        }
    }
    private var optional: [LocationTask] { tasks.filter { !$0.required && !ledger.status(of: $0.id).isHandled } }
    private var handled: [LocationTask] { tasks.filter { ledger.status(of: $0.id).isHandled && !needsReview.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let issue = services.store.persistenceIssue {
                Banner(symbol: "exclamationmark.triangle", text: issue, tone: .danger)
            }
            if let error { Banner(symbol: "exclamationmark.triangle", text: error, tone: .danger).accessibilityIdentifier("stopWorkError") }
            if tasks.isEmpty { Text("No work at this stop.").foregroundStyle(Theme.neutral) }
            if !requiredOutstanding.isEmpty {
                workGroup("Required work · \(requiredOutstanding.count) unfinished", tasks: requiredOutstanding)
            }
            if !needsReview.isEmpty { workGroup("Failed · unsuccessful", tasks: needsReview) }
            if !optional.isEmpty { workGroup("Optional work", tasks: optional) }
            if !handled.isEmpty {
                DisclosureGroup(isExpanded: $showHandled) {
                    ForEach(presentationOrder(handled)) { task in row(task) }
                } label: {
                    Text("Handled work · \(handled.count)").font(.headline).frame(minHeight: 44)
                        .accessibilityIdentifier("handledStopWork")
                }
            }
            if allowsEditing, isOpen {
                VStack(alignment: .leading, spacing: 8) {
                    Button { editor = .init(kind: .pickup) } label: {
                        Label("Add pickup", systemImage: "tray.and.arrow.up").frame(minHeight: 44).contentShape(Rectangle())
                    }.accessibilityIdentifier("addPickup")
                        .disabled(!services.store.canCreateLocationTasks)
                    Button { editor = .init(kind: .checklist) } label: {
                        Label("Add checklist item", systemImage: "checklist").frame(minHeight: 44).contentShape(Rectangle())
                    }.accessibilityIdentifier("addChecklist")
                        .disabled(!services.store.canCreateLocationTasks)
                    if let reason = services.store.taskCreationUnavailableReason {
                        Text(reason).font(.footnote).foregroundStyle(Theme.neutral)
                    }
                }
            }
            if !isOpen { Text("This route is closed. Reopen it explicitly to record more work.").font(.subheadline).foregroundStyle(Theme.neutral) }
        }
        // List's automatic button style can activate every button in one row. This shared
        // content also lives inside StopDetail's List, so each secondary action must be scoped.
        .buttonStyle(.borderless)
        .accessibilityElement(children: .contain)
        .accessibilityHidden(editor != nil || failing != nil)
        .sheet(item: $editor) { target in TaskEditorView(snapshot: snapshot, stop: stop, kind: target.kind, existing: target.task) }
        .sheet(item: $failing) { task in
            FailureReasonSheet(title: task.kind == .delivery ? "Delivery failed" : task.kind == .pickup ? "Pickup failed" : "Checklist failed", prompt: "Why couldn't this work be completed?") { reason, note in
                act(.failed, task: task, reason: reason, note: note)
            }
        }
    }

    private func presentationOrder(_ list: [LocationTask]) -> [LocationTask] {
        // Pickups/checklists stay ahead of long package lists; existing stop identity keeps units separate.
        list.sorted {
            let a = $0.kind == .delivery ? 1 : 0, b = $1.kind == .delivery ? 1 : 0
            return (a, $0.orderRank, $0.createdAt, $0.id) < (b, $1.orderRank, $1.createdAt, $1.id)
        }
    }

    private func workGroup(_ title: String, tasks: [LocationTask]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(presentationOrder(tasks)) { task in row(task) }
        }
    }

    private func row(_ task: LocationTask) -> some View {
        let state = ledger.status(of: task.id)
        let package = snapshot.packages.first { $0.id == task.packageID }
        let title = task.kind == .delivery ? ["Delivery", package?.trackingID, package?.storageLocation].compactMap { $0 }.joined(separator: " · ") : task.title.isEmpty ? kindLabel(task.kind) : task.title
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("workTitle.\(task.id)")
                    Text([kindLabel(task.kind), task.required ? "Required" : "Optional"].joined(separator: " · ")).font(.footnote).foregroundStyle(Theme.neutral)
                }
                Spacer(minLength: 4)
                if isOpen { actionMenu(task, title: title) }
            }
            if let name = package?.recipientName { Text(name).font(.subheadline) }
            let instructions = task.kind == .delivery ? package?.notes ?? "" : task.instructions
            if !instructions.isEmpty { Label(instructions, systemImage: "note.text").font(.subheadline).fixedSize(horizontal: false, vertical: true) }
            Label {
                Text(stateLabel(state, kind: task.kind))
                    .accessibilityIdentifier("workStatus.\(task.id)")
                    .accessibilityFocused($focusedStatus, equals: task.id)
            } icon: { Image(systemName: stateSymbol(state)).accessibilityHidden(true) }
                .font(.subheadline.weight(.semibold)).foregroundStyle(stateTone(state))
            if case .failed = state, let note = ledger.activeOutcomes[task.id]?.note, !note.isEmpty {
                Text(note).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
            if isOpen {
                if state == .pending {
                    Button { _ = act(task.kind == .delivery ? .delivered : .completed, task: task) } label: {
                        Label(successLabel(task.kind), systemImage: task.kind == .pickup ? "tray.and.arrow.up.fill" : "checkmark")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(PrimaryButtonStyle())
                        .accessibilityLabel("\(task.kind == .pickup ? "Pick up" : task.kind == .checklist ? "Done:" : "Delivered:") \(title)")
                        .accessibilityIdentifier("completeWork.\(task.id)").disabled(submitting)
                } else if canRetry(state) {
                    Button { _ = act(.requeued, task: task) } label: {
                        Text("Retry").frame(minHeight: 44).contentShape(Rectangle())
                    }.accessibilityLabel("Retry \(title)")
                        .accessibilityIdentifier("retryWork.\(task.id)").disabled(submitting)
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 14))
    }

    private func actionMenu(_ task: LocationTask, title: String) -> some View {
        let state = ledger.status(of: task.id)
        return Menu {
            if state == .pending {
                Button("Failed", systemImage: "xmark.circle") { failing = task }.accessibilityIdentifier("failWork.\(task.id)")
                Button("Defer", systemImage: "arrow.uturn.forward") { _ = act(.skipped, task: task) }.accessibilityIdentifier("deferWork.\(task.id)")
            }
            if state == .pending || canRetry(state) {
                Button("Exclude from this route", systemImage: "minus.circle") { _ = act(.excluded, task: task) }
                    .accessibilityIdentifier("excludeWork.\(task.id)")
            }
            if let outcome = ledger.activeOutcomes[task.id] {
                Button("Undo last action", systemImage: "arrow.uturn.backward") { undo(outcome, task: task) }
                    .accessibilityIdentifier("undoWork.\(task.id)")
            }
            if task.kind == .pickup || task.kind == .checklist {
                Button("Edit item", systemImage: "pencil") { editor = .init(kind: task.kind, task: task) }.accessibilityIdentifier("editTask.\(task.id)")
            }
        } label: {
            Image(systemName: "ellipsis").frame(width: 44, height: 44)
        }.accessibilityLabel("Actions for \(title)").accessibilityIdentifier("workActions.\(task.id)")
            .disabled(submitting || state == .unsupported)
    }

    @discardableResult private func act(_ kind: OutcomeKind, task: LocationTask, reason: FailureReason? = nil, note: String? = nil) -> Bool {
        guard !submitting else { return false }; submitting = true; defer { submitting = false }
        let result = services.store.recordWorkAction(kind, taskIDs: [task.id], reason: reason, note: note, in: snapshot, label: "Record stop work")
        guard result.acknowledgement.isCommitted else {
            if case let .failed(failure) = result.acknowledgement { error = failure.localizedDescription }
            else { error = "This work could not be saved. Review its current state and try again." }
            return false
        }
        // A repeated tap is a reducer no-op, not a new success or an operational failure.
        guard !result.outcomeIDs.isEmpty else { return false }
        error = nil; showHandled = true; focusedStatus = task.id
        if kind == .failed { Haptics.warning() } else { Haptics.tap() }
        toasts.show(kind == .requeued ? "Ready to retry" : kind == .skipped ? "Deferred — still unfinished" : kind == .failed ? "Failed — unsuccessful" : kind == .excluded ? "Excluded" : successLabel(task.kind), symbol: stateSymbolForOutcome(kind), tone: kind == .failed ? .danger : kind == .skipped ? .warning : .neutral, undoAcknowledged: { services.store.undo(outcomeIDs: result.outcomeIDs, in: snapshot).isCommitted })
        return true
    }

    private func undo(_ outcome: TaskOutcome, task: LocationTask) {
        guard !submitting else { return }; submitting = true; defer { submitting = false }
        guard services.store.undo(outcomeIDs: [outcome.id], in: snapshot).isCommitted else {
            error = services.store.persistenceIssue ?? "Undo could not be saved. Review the current work."; return
        }
        error = nil; showHandled = true; focusedStatus = task.id; Haptics.tap()
    }

    private func canRetry(_ state: WorkState) -> Bool { switch state { case .failed, .deferred: true; default: false } }
    private func kindLabel(_ kind: WorkKind) -> String { kind == .pickup ? "Pickup" : kind == .checklist ? "Checklist" : kind == .delivery ? "Delivery" : "Unsupported work" }
    private func successLabel(_ kind: WorkKind) -> String { kind == .pickup ? "Picked up" : kind == .checklist ? "Done" : "Delivered" }
    private func stateLabel(_ state: WorkState, kind: WorkKind) -> String {
        switch state {
        case .pending: "Pending"
        case .completed: successLabel(kind)
        case let .failed(reason, _): "Failed — unsuccessful" + (reason.map { " · \($0.label)" } ?? "")
        case .deferred: "Deferred — unfinished"
        case .excluded: "Excluded from this route"
        case .unsupported: "Unsupported — review required"
        }
    }
    private func stateSymbol(_ state: WorkState) -> String { switch state { case .pending: "circle"; case .completed: "checkmark.circle"; case .failed: "xmark.circle"; case .deferred: "arrow.uturn.forward.circle"; case .excluded: "minus.circle"; case .unsupported: "exclamationmark.triangle" } }
    private func stateTone(_ state: WorkState) -> Color { switch state { case .completed: Theme.success; case .failed, .unsupported: Theme.danger; case .deferred: Theme.warning; case .pending, .excluded: Theme.neutral } }
    private func stateSymbolForOutcome(_ kind: OutcomeKind) -> String { kind == .failed ? "xmark.circle" : kind == .skipped ? "arrow.uturn.forward" : kind == .requeued ? "arrow.counterclockwise" : "checkmark.circle" }
}

private struct WorkEditorTarget: Identifiable {
    var kind: WorkKind
    var task: LocationTask? = nil
    var id: String { task?.id ?? kind.rawValue }
}
