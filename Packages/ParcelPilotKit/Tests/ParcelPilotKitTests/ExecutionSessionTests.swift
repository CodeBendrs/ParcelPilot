import Foundation
import Testing
@testable import ParcelPilotKit

@Suite("Explicit route execution model")
struct ExecutionSessionTests {
    let epoch = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("Execution is explicit, round-trips independently, and starts without work state")
    func initialRecord() throws {
        let session = RouteExecutionSession(routeID: "route", now: epoch)
        try RouteExecutionSession.validateTransition(from: nil, to: session)
        #expect(session.state == .active && session.transitionCount == 0 && session.isUnfinished)
        #expect(session.startedAt == epoch && session.changedAt == epoch)
        #expect(try JSONDecoder().decode(RouteExecutionSession.self, from: JSONEncoder().encode(session)) == session)
    }

    @Test("Pause, resume and finish preserve identity with ordered explicit transitions")
    func completeLifecycle() throws {
        let initial = RouteExecutionSession(routeID: "route", now: epoch)
        var previous = initial
        for (index, state) in [RouteExecutionSession.State.paused, .active, .finished].enumerated() {
            var next = previous; next.state = state; next.changedAt = epoch.addingTimeInterval(Double(index + 1)); next.transitionCount += 1
            try RouteExecutionSession.validateTransition(from: previous, to: next)
            #expect(next.id == initial.id && next.startedAt == initial.startedAt)
            previous = next
        }
        #expect(!previous.isUnfinished)
        let restart = RouteExecutionSession(routeID: "other-route", now: epoch.addingTimeInterval(4))
        try RouteExecutionSession.validateTransition(from: previous, to: restart)
        #expect(restart.id != previous.id && restart.transitionCount == 0)
    }

    @Test("An unfinished execution cannot silently switch route, identity, count, or state")
    func invalidTransitions() throws {
        let session = RouteExecutionSession(routeID: "route", now: epoch)
        #expect(throws: RouteExecutionSession.TransitionError.self) { try RouteExecutionSession.validateTransition(from: session, to: session) }
        var next = session; next.state = .paused; next.transitionCount = 1; next.changedAt = epoch.addingTimeInterval(1)
        var wrong = next; wrong.routeID = "other"
        #expect(throws: RouteExecutionSession.TransitionError.self) { try RouteExecutionSession.validateTransition(from: session, to: wrong) }
        wrong = next; wrong.id = "replacement"
        #expect(throws: RouteExecutionSession.TransitionError.self) { try RouteExecutionSession.validateTransition(from: session, to: wrong) }
        wrong = next; wrong.transitionCount = 2
        #expect(throws: RouteExecutionSession.TransitionError.self) { try RouteExecutionSession.validateTransition(from: session, to: wrong) }
        wrong = next; wrong.startedAt = epoch.addingTimeInterval(1)
        #expect(throws: RouteExecutionSession.TransitionError.self) { try RouteExecutionSession.validateTransition(from: session, to: wrong) }
        wrong = next; wrong.changedAt = epoch.addingTimeInterval(-1)
        #expect(throws: RouteExecutionSession.TransitionError.self) { try RouteExecutionSession.validateTransition(from: session, to: wrong) }
    }

    @Test("Finish is allowed directly from either active or paused", arguments: [RouteExecutionSession.State.active, .paused])
    func directFinish(state: RouteExecutionSession.State) throws {
        var session = RouteExecutionSession(routeID: "route", now: epoch)
        session.state = state; session.transitionCount = state == .paused ? 1 : 0
        var finished = session; finished.state = .finished; finished.transitionCount += 1; finished.changedAt = epoch.addingTimeInterval(2)
        try RouteExecutionSession.validateTransition(from: session, to: finished)
    }

    @Test("Wire timestamp tolerance never masks identity, lifecycle count, or material time differences")
    func precision() {
        let session = RouteExecutionSession(routeID: "route", now: epoch)
        var wire = session; wire.startedAt = epoch.addingTimeInterval(-0.000_001); wire.changedAt = wire.startedAt
        #expect(session.matches(wire))
        wire.transitionCount = 1; #expect(!session.matches(wire))
        wire = session; wire.changedAt = epoch.addingTimeInterval(0.001); #expect(!session.matches(wire))
        wire = session; wire.schemaVersion = 2; #expect(!wire.isValid)
        wire = session; wire.transitionCount = -1; #expect(!wire.isValid)
    }
}
