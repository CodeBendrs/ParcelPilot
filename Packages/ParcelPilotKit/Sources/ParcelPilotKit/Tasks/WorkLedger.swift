import Foundation

/// The canonical reducer for all location work. Timestamps/IDs retain legacy ordering in WP1;
/// durable command ordering and receipt-based replay belong to the later persistence packages.
public struct WorkLedger: Sendable {
    public let allTasks: [LocationTask]
    public let taskStates: [TaskID: WorkState]
    public let activeOutcomes: [TaskID: TaskOutcome]
    public let invalidTaskIDs: Set<TaskID>

    public init(packages: [Package], tasks: [LocationTask] = [], outcomes: [TaskOutcome]) {
        let projected = packages.map(LocationTask.projection(for:))
        let all = projected + tasks
        var definitions: [TaskID: LocationTask] = [:]
        var blocked = Set<TaskID>()
        for task in all {
            if var existing = definitions[task.id] {
                if existing != task {
                    blocked.insert(task.id)
                    // Preserve the package projection, and never downgrade required work through
                    // a conflicting definition. Duplicate identical input is still one work item.
                    existing.required = existing.required || task.required
                    definitions[task.id] = existing
                }
            } else { definitions[task.id] = task }
            if !task.kind.isSupported || task.schemaVersion != 1 { blocked.insert(task.id) }
            if task.id.isEmpty || task.stopID.isEmpty || task.orderRank < 0 { blocked.insert(task.id) }
        }
        for task in tasks where task.kind == .delivery || task.id.hasPrefix("delivery_") {
            blocked.insert(task.id) // Persisted delivery definitions must never shadow packages.
        }

        // A voided copy wins over an earlier active copy of the SAME immutable event. Different
        // immutable payloads sharing an ID are a conflict, never an arrival-order-dependent winner.
        var unique: [OutcomeID: TaskOutcome] = [:]
        for event in outcomes {
            if let previous = unique[event.id] {
                var a = previous, b = event
                a.voidedAt = nil; b.voidedAt = nil
                if a != b {
                    blocked.insert(previous.targetTaskID); blocked.insert(event.targetTaskID)
                    if let p = previous.packageID { blocked.insert(LocationTask.deliveryID(for: p)) }
                    if let p = event.packageID { blocked.insert(LocationTask.deliveryID(for: p)) }
                    continue
                }
                var merged = previous
                merged.voidedAt = [previous.voidedAt, event.voidedAt].compactMap { $0 }.min()
                unique[event.id] = merged
            } else { unique[event.id] = event }
        }

        var latest: [TaskID: TaskOutcome] = [:]
        for event in unique.values {
            let id = event.targetTaskID
            guard let task = definitions[id] else {
                // Removed work keeps its history, but a forged task target must not hide a known
                // package association in a malformed generalized delivery event.
                if event.schemaVersion == 2, let p = event.packageID,
                   definitions[LocationTask.deliveryID(for: p)] != nil {
                    blocked.insert(LocationTask.deliveryID(for: p))
                }
                continue
            }
            let identityOK: Bool
            if task.kind == .delivery {
                identityOK = event.packageID == task.packageID && event.kind != .completed
                    && ((event.schemaVersion == 1 && event.taskID == nil)
                        || (event.schemaVersion == 2 && event.taskID == task.id))
            } else {
                identityOK = event.schemaVersion == 2 && event.taskID == task.id
                    && event.packageID == nil && event.kind != .delivered
            }
            guard identityOK && event.stopID == task.stopID else {
                blocked.insert(id)
                if let p = event.packageID, definitions[LocationTask.deliveryID(for: p)] != nil {
                    blocked.insert(LocationTask.deliveryID(for: p))
                }
                continue
            }
            guard event.voidedAt == nil else { continue }
            if let previous = latest[id], (previous.recordedAt, previous.id) >= (event.recordedAt, event.id) { continue }
            latest[id] = event
        }

        var states: [TaskID: WorkState] = [:]
        for task in definitions.values {
            if blocked.contains(task.id) { states[task.id] = .unsupported; continue }
            guard let event = latest[task.id] else { states[task.id] = .pending; continue }
            switch event.kind {
            case .delivered, .completed: states[task.id] = .completed(at: event.recordedAt)
            case .failed: states[task.id] = .failed(event.reason, at: event.recordedAt)
            case .skipped: states[task.id] = .deferred(at: event.recordedAt)
            case .excluded: states[task.id] = .excluded(at: event.recordedAt)
            case .requeued: states[task.id] = .pending
            }
        }
        allTasks = definitions.values.sorted(by: Self.presentationOrder)
        taskStates = states
        activeOutcomes = latest.filter { !blocked.contains($0.key) }
        invalidTaskIDs = blocked.intersection(Set(all.map(\.id)))
    }

    public func status(of taskID: TaskID) -> WorkState { taskStates[taskID] ?? .unsupported }
    public func tasks(at stopID: StopID) -> [LocationTask] { allTasks.filter { $0.stopID == stopID } }
    public func actionableTasks(at stopID: StopID) -> [LocationTask] {
        tasks(at: stopID).filter { status(of: $0.id).isActionable }
    }
    public func presentableTasks(at stopID: StopID) -> [LocationTask] {
        tasks(at: stopID).filter {
            switch status(of: $0.id) { case .completed, .excluded: false; default: true }
        }
    }
    public func hasOutstandingRequiredWork(at stopID: StopID) -> Bool {
        tasks(at: stopID).contains { $0.required && !status(of: $0.id).isHandled }
    }
    public func hasUnsupportedRequiredWork(at stopID: StopID) -> Bool {
        tasks(at: stopID).contains { $0.required && status(of: $0.id) == .unsupported }
    }
    public func hasActionableRequiredWork(at stopID: StopID) -> Bool {
        actionableTasks(at: stopID).contains(where: \.required)
    }
    public func stopStatus(_ stop: Stop) -> StopStatus {
        let required = tasks(at: stop.id).filter(\.required)
        guard !required.isEmpty else { return .empty }
        let states = required.map { status(of: $0.id) }
        let handled = states.filter(\.isHandled).count
        if handled == states.count { return .completed }
        let remaining = states.filter { !$0.isHandled }
        if remaining.allSatisfy({ if case .deferred = $0 { true } else { false } }) { return .skipped }
        return handled > 0 ? .partial : .pending
    }
    public var summary: WorkSummary {
        var result = WorkSummary()
        for task in allTasks {
            guard task.required else { result.optional += 1; continue }
            result.required += 1
            switch status(of: task.id) {
            case .pending: result.pending += 1
            case .completed: result.completed += 1
            case .failed: result.failed += 1
            case .deferred: result.deferred += 1
            case .excluded: result.excluded += 1
            case .unsupported: result.unsupported += 1
            }
        }
        return result
    }
    private static func presentationOrder(_ a: LocationTask, _ b: LocationTask) -> Bool {
        func kindRank(_ k: WorkKind) -> Int { k == .checklist ? 0 : k == .pickup ? 1 : 2 }
        return (a.required ? 0 : 1, a.orderRank, kindRank(a.kind), a.createdAt, a.id)
            < (b.required ? 0 : 1, b.orderRank, kindRank(b.kind), b.createdAt, b.id)
    }
}
