import ParcelPilotKit
import SwiftUI

/// Definition-only editing. Work state stays in outcomes/WorkLedger, and Save/Delete dismiss
/// only after the existing protected store has acknowledged its local transaction.
struct TaskEditorView: View {
    let snapshot: RouteSnapshot
    let stop: Stop
    let kind: WorkKind
    let existing: LocationTask?
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var task: LocationTask
    @State private var submitting = false
    @State private var errorMessage: String?
    @State private var confirmDelete = false

    init(snapshot: RouteSnapshot, stop: Stop, kind: WorkKind, existing: LocationTask? = nil) {
        self.snapshot = snapshot; self.stop = stop; self.kind = kind; self.existing = existing
        let lastRank = snapshot.tasks.filter { $0.stopID == stop.id }.map(\.orderRank).max() ?? -1
        let nextRank = lastRank >= 1_000_000_000 ? 1_000_000_000 : max(0, lastRank + 1)
        _task = State(initialValue: existing ?? LocationTask(stopID: stop.id, kind: kind, orderRank: nextRank))
    }

    private var title: String {
        (existing == nil ? "Add " : "Edit ") + (kind == .pickup ? "pickup" : "checklist item")
    }
    private var live: RouteSnapshot {
        services.store.current?.route.id == snapshot.route.id ? services.store.current! : snapshot
    }
    private var hasHistory: Bool {
        existing.map { services.store.taskHasOutcomeHistory($0, in: live) } ?? false
    }
    private var unavailableReason: String? {
        if !live.route.isOpen { return "Reopen this route explicitly before changing its work." }
        if existing == nil, !services.store.canCreateLocationTasks {
            return services.store.taskCreationUnavailableReason ?? "Task creation is unavailable in this build."
        }
        return nil
    }
    private var validationMessage: String? {
        if task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a short description." }
        if task.title.count > 120 { return "Keep the description to 120 characters or fewer." }
        if task.instructions.count > 2_000 { return "Keep instructions to 2,000 characters or fewer." }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if let message = errorMessage ?? unavailableReason {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("taskEditorError")
                    }
                }
                Section {
                    TextField(kind == .pickup ? "Pickup description" : "Checklist item", text: $task.title, axis: .vertical)
                        .lineLimit(1...4)
                        .accessibilityIdentifier("taskTitle")
                    TextField("Instructions (optional)", text: $task.instructions, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("taskInstructions")
                    if task.title.count > 120 || task.instructions.count > 2_000, let message = validationMessage {
                        Text(message)
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("taskValidationError")
                    }
                } header: {
                    Text("What needs to happen")
                } footer: {
                    Text([stop.address.streetLine ?? stop.address.singleLine, stop.address.unitLabel].compactMap { $0 }.joined(separator: " · "))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    Toggle("Required work", isOn: $task.required)
                        .accessibilityIdentifier("taskRequired")
                } footer: {
                    Text(task.required
                        ? "This item stays outstanding until you explicitly record an outcome."
                        : "Optional work stays visible, but does not create a route visit or block required-work completion.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let existing {
                    Section {
                        if hasHistory {
                            Label("Recorded history is protected", systemImage: "clock.arrow.circlepath")
                                .font(.headline)
                            Text("This item has recorded outcomes, including any undone actions. Edit its details here, or use Retry and Undo in stop work to change its disposition.")
                                .foregroundStyle(Theme.neutral)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("taskDeletionProtected")
                        } else {
                            Button("Delete \(existing.kind == .pickup ? "pickup" : "checklist item")", role: .destructive) {
                                confirmDelete = true
                            }
                            .frame(minHeight: Theme.minTouch)
                            .disabled(submitting || unavailableReason != nil)
                            .accessibilityIdentifier("deleteTask")
                        }
                    }
                }
            }
            .disabled(submitting)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(submitting).accessibilityIdentifier("cancelTaskEditor")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(submitting || unavailableReason != nil || validationMessage != nil)
                        .accessibilityIdentifier("saveTask")
                }
            }
            .confirmationDialog("Delete this \(kind == .pickup ? "pickup" : "checklist item")?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete item", role: .destructive, action: delete)
                    .accessibilityIdentifier("confirmDeleteTask")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It has no recorded outcomes. Its definition will be removed from this stop.")
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(submitting)
    }

    private func save() {
        guard !submitting else { return }
        if let message = unavailableReason ?? validationMessage { errorMessage = message; return }
        submitting = true
        defer { submitting = false }
        var edited = task
        edited.title = edited.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = services.store.saveTask(edited, in: snapshot)
        if case let .failed(error) = result { errorMessage = error.localizedDescription; return }
        guard result.isCommitted else { return }
        dismiss()
    }

    private func delete() {
        guard !submitting, let existing else { return }
        submitting = true
        defer { submitting = false }
        let result = services.store.deleteTask(existing, in: snapshot)
        if case let .failed(error) = result { errorMessage = error.localizedDescription; return }
        guard result.isCommitted else { return }
        dismiss()
    }
}
