import Foundation

/// Explicit route execution intent. Route selection, accepted ordering, and WorkLedger remain
/// independent; this account-wide singleton says only which route the driver is executing.
public struct RouteExecutionSession: Codable, Hashable, Sendable, Identifiable {
    public enum State: String, Codable, Hashable, Sendable { case active, paused, finished }
    public var id: String
    public var routeID: RouteID
    public var schemaVersion: Int
    public var state: State
    public var startedAt: Date
    public var changedAt: Date
    public var transitionCount: Int

    public init(id: String = StableID.make(), routeID: RouteID, state: State = .active,
                startedAt: Date, changedAt: Date? = nil, transitionCount: Int = 0, schemaVersion: Int = 1) {
        self.id = id; self.routeID = routeID; self.schemaVersion = schemaVersion; self.state = state
        self.startedAt = startedAt; self.changedAt = changedAt ?? startedAt; self.transitionCount = transitionCount
    }
    public init(routeID: RouteID, now: Date) { self.init(routeID: routeID, startedAt: now) }

    public var isUnfinished: Bool { state != .finished }
    public var isValid: Bool {
        schemaVersion == 1 && !id.isEmpty && !routeID.isEmpty && transitionCount >= 0 &&
        startedAt.timeIntervalSince1970.isFinite && changedAt.timeIntervalSince1970.isFinite &&
        changedAt.timeIntervalSince(startedAt) > -0.000_002 && (state == .active || transitionCount > 0) &&
        (transitionCount > 0 || abs(changedAt.timeIntervalSince(startedAt)) < 0.000_002)
    }

    /// Firestore truncates timestamps to microseconds; identity and every non-date field are exact.
    public func matches(_ other: Self, dateTolerance: TimeInterval = 0.000_002) -> Bool {
        id == other.id && routeID == other.routeID && schemaVersion == other.schemaVersion &&
        state == other.state && transitionCount == other.transitionCount &&
        abs(startedAt.timeIntervalSince(other.startedAt)) < dateTolerance &&
        abs(changedAt.timeIntervalSince(other.changedAt)) < dateTolerance
    }

    public static func validateTransition(from previous: Self?, to next: Self) throws {
        guard next.isValid, previous?.isValid != false else { throw TransitionError.invalidRecord }
        if previous == nil || previous?.state == .finished {
            guard next.state == .active, next.transitionCount == 0,
                  abs(next.changedAt.timeIntervalSince(next.startedAt)) < 0.000_002,
                  previous?.id != next.id else { throw TransitionError.invalidStart }
            if let previous, next.changedAt.timeIntervalSince(previous.changedAt) <= -0.000_002 {
                throw TransitionError.nonMonotonicTime
            }
            return
        }
        guard let previous, previous.id == next.id, previous.routeID == next.routeID,
              abs(previous.startedAt.timeIntervalSince(next.startedAt)) < 0.000_002,
              previous.transitionCount < Int.max, next.transitionCount == previous.transitionCount + 1 else { throw TransitionError.identityChanged }
        guard next.changedAt.timeIntervalSince(previous.changedAt) > -0.000_002 else { throw TransitionError.nonMonotonicTime }
        switch (previous.state, next.state) {
        case (.active, .paused), (.active, .finished), (.paused, .active), (.paused, .finished): break
        default: throw TransitionError.invalidState
        }
    }

    public enum TransitionError: Error, LocalizedError, Sendable {
        case invalidRecord, invalidStart, identityChanged, nonMonotonicTime, invalidState
        public var errorDescription: String? {
            switch self {
            case .invalidRecord: "Route execution data is invalid. Saved intent has been preserved."
            case .invalidStart: "Finish the current route execution before starting another."
            case .identityChanged: "Route execution identity changed. Saved intent has been preserved."
            case .nonMonotonicTime: "Route execution timestamps must preserve the driver's action order."
            case .invalidState: "This route execution transition isn't allowed."
            }
        }
    }
}
