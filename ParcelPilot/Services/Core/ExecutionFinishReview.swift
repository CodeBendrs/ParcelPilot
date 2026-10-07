import ParcelPilotKit

/// Presentation of the existing canonical work reducer, never another completion calculation.
struct ExecutionFinishReview {
    var summary: WorkSummary
    var canFinish: Bool
    var remaining: [ExecutionRemainingWork]
    var requiresOutstandingConfirmation: Bool { summary.outstanding > 0 }
}

struct ExecutionRemainingWork: Identifiable {
    var taskID: TaskID
    var stopID: StopID
    var title: String
    var kind: WorkKind
    var state: WorkState
    var id: TaskID { taskID }
}
