import Foundation
import os
import ParcelPilotKit

/// Finite, content-free pilot vocabulary. No account, route, task, or command identifiers,
/// destination text, images, audio, coordinates, or free-form errors can enter these records.
struct ExecutionPilotEvent: Equatable {
    enum Name: String {
        case startRequested = "execution_start_requested"
        case startedLocally = "execution_started_locally"
        case pausedLocally = "execution_paused_locally"
        case resumedLocally = "execution_resumed_locally"
        case finishRequested = "execution_finish_requested"
        case finishedLocally = "execution_finished_locally"
        case finishBlockedByWork = "execution_finish_blocked_work"
        case restored = "execution_restored"
        case syncFailure = "execution_sync_failure"
        case syncRecovered = "execution_sync_recovered"
        case taskCreatedLocally = "task_created_locally"
        case taskEditedLocally = "task_edited_locally"
        case taskDeletedLocally = "task_deleted_locally"
        case taskSaveFailedLocally = "task_save_failed_locally"
        case stopWorkOpened = "stop_work_opened"
        case mixedWorkPresented = "mixed_work_presented"
        case taskCompletedLocally = "task_completed_locally"
        case taskFailedLocally = "task_failed_locally"
        case taskDeferredLocally = "task_deferred_locally"
        case taskRetriedLocally = "task_retried_locally"
        case taskExcludedLocally = "task_excluded_locally"
        case taskUndoneLocally = "task_undone_locally"
        case pendingWorkReminderShown = "pending_work_reminder_shown"
        case pendingWorkReminderBypassed = "pending_work_reminder_bypassed"
        case taskOutcomeSyncFailure = "task_outcome_sync_failure"

        static func workAction(_ kind: OutcomeKind) -> Self {
            switch kind {
            case .completed, .delivered: .taskCompletedLocally
            case .failed: .taskFailedLocally
            case .skipped: .taskDeferredLocally
            case .requeued: .taskRetriedLocally
            case .excluded: .taskExcludedLocally
            }
        }
    }
    enum WorkType: String {
        case delivery, pickup, checklist
        init?(_ kind: WorkKind) {
            switch kind { case .delivery: self = .delivery; case .pickup: self = .pickup; case .checklist: self = .checklist; default: return nil }
        }
    }
    var name: Name
    var state: RouteExecutionSession.State?
    var pending: Int
    var deferred: Int
    var failed: Int
    var failure: DurableCommand.State?
    var workType: WorkType?
    var mixed: Bool

    init(name: Name, state: RouteExecutionSession.State? = nil, summary: WorkSummary = WorkSummary(), failure: DurableCommand.State? = nil, workType: WorkType? = nil, mixed: Bool = false) {
        self.name = name; self.state = state
        pending = summary.pending; deferred = summary.deferred; failed = summary.failed
        self.failure = failure
        self.workType = workType; self.mixed = mixed
    }
}

/// Opt-in, on-device pilot logging only. Unified logging supplies bounded system retention; it is
/// deliberately separate from operational outbox/history. WP11 owns remote collection/retention.
/// Logging is never an acknowledgement prerequisite and never changes execution or work state.
@MainActor
enum PilotTelemetry {
    static let consentKey = "pp.pilotExecutionLogging"
    private static let logger = Logger(subsystem: AppLog.subsystem, category: "pilot.execution")
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: consentKey) }
        set { UserDefaults.standard.set(newValue, forKey: consentKey) }
    }
    static func record(_ event: ExecutionPilotEvent) {
        guard enabled else { return }
        logger.notice("event=\(event.name.rawValue, privacy: .public) state=\(event.state?.rawValue ?? "none", privacy: .public) pending=\(event.pending) deferred=\(event.deferred) failed=\(event.failed) sync=\(event.failure?.rawValue ?? "none", privacy: .public) kind=\(event.workType?.rawValue ?? "none", privacy: .public) mixed=\(event.mixed)")
    }
}
