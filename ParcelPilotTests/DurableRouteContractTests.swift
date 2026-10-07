import Foundation
import ParcelPilotKit
import SQLite3
import Testing
import UIKit
@testable import ParcelPilot

@MainActor
@Suite("Protected route durability contract", .serialized)
struct DurableRouteContractTests {
    private let epoch = Date(timeIntervalSince1970: 1_790_000_000)

    private func fixture() -> RouteSnapshot {
        var route = Route(id: "protected-route", name: "Accepted work", serviceDate: "2026-10-05", timeZoneID: "America/Vancouver", now: epoch)
        route.status = .active; route.startedAt = epoch
        route.appliedRequestID = "accepted-plan"; route.appliedRevision = 1
        route.start = RoutePlace(label: "Depot", located: LocatedPoint(point: GeoPoint(latitude: 48.4, longitude: -123.3), source: .driverPin))
        var stops: [Stop] = []
        for index in 1...5 {
            var address = PostalAddress.e1(); address.unit = "\(200 + index)"
            let resolution = StopResolution(provider: nil, placeID: nil, located: LocatedPoint(point: GeoPoint(latitude: 48.4 + Double(index) * 0.001, longitude: -123.3), source: .driverPin), match: .driverPin, resolvedAt: epoch)
            var stop = Stop(id: "stop-\(index)", address: address, addressStatus: .driverConfirmed, resolution: resolution, sequence: Double(index), now: epoch)
            stop.notes = "Buzzer \(200 + index)"; stops.append(stop)
        }
        let packages = (1...3).map { Package(id: "package-\($0)", stopID: "stop-\($0)", trackingID: "TRACK\($0)", notes: "Shelf \($0)", source: .manual, now: epoch) }
        let tasks = [LocationTask(id: "pickup", stopID: "stop-4", kind: .pickup, title: "Collect return", instructions: "Ask reception", now: epoch),
                     LocationTask(id: "checklist", stopID: "stop-5", kind: .checklist, title: "Check access", now: epoch)]
        return RouteSnapshot(route: route, stops: stops, packages: packages, outcomes: [], tasks: tasks)
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("protected-contract-\(UUID().uuidString)/operations.sqlite")
    }

    @Test("Three deliveries, pickup and deferral survive offline restart, then replay without lost or duplicated outcomes")
    func offlineWorkflow() async throws {
        let snapshot = fixture(), url = temporaryURL()
        let disk = try ActiveRoutePersistence(ownerID: "driver", databaseURL: url)
        try disk.pin(snapshot, selected: true)
        let remote = ControlledRouteBackend(snapshot)
        let transport = ControlledCommandTransport(snapshot)
        let backend = DurableRouteBackend(remote: remote, ownerID: "driver", persistence: disk, transport: transport, authenticatedOwner: { "driver" })
        let store = RouteStore(backend: backend, clock: { self.epoch })
        for package in snapshot.packages {
            #expect(store.record(.delivered, packageIDs: [package.id], stopID: package.stopID, in: try #require(store.current), label: "Delivered").count == 1)
        }
        #expect(store.record(.completed, taskIDs: ["pickup"], in: try #require(store.current), label: "Pickup complete").count == 1)
        #expect(store.record(.skipped, taskIDs: ["checklist"], in: try #require(store.current), label: "Deferred").count == 1)
        backend.suspend() // Simulates termination after local acknowledgement, before sending.
        #expect(try disk.commands().count == 5)

        let reopened = try ActiveRoutePersistence(ownerID: "driver", databaseURL: url)
        let offline = DurableRouteBackend(remote: ControlledRouteBackend(), ownerID: "driver", persistence: reopened, transport: transport, authenticatedOwner: { "driver" })
        let restored = RouteStore(backend: offline, clock: { self.epoch.addingTimeInterval(-3_600) })
        let recovered = try #require(restored.current)
        #expect(restored.currentRouteID == snapshot.route.id)
        #expect(recovered.orderedStops.map(\.id) == snapshot.orderedStops.map(\.id))
        #expect(recovered.stops.map(\.notes).sorted() == snapshot.stops.map(\.notes).sorted())
        #expect(recovered.packages.map(\.trackingID).sorted { ($0 ?? "") < ($1 ?? "") } == snapshot.packages.map(\.trackingID).sorted { ($0 ?? "") < ($1 ?? "") })
        #expect(recovered.tasks.first { $0.id == "pickup" }?.instructions == "Ask reception")
        #expect(NavigationLauncher.canNavigate(to: try #require(recovered.stops.first)))
        #expect(recovered.workSummary.completed == 4 && recovered.workSummary.deferred == 1)
        #expect(recovered.outcomes.count == 5)
        #expect(restored.record(.requeued, taskIDs: ["checklist"], in: recovered, label: "Retry").count == 1)
        #expect(restored.record(.completed, taskIDs: ["checklist"], in: try #require(restored.current), label: "Checklist complete").count == 1)
        offline.suspend()

        transport.online = true
        let syncing = DurableRouteBackend(remote: ControlledRouteBackend(), ownerID: "driver", persistence: reopened, transport: transport, authenticatedOwner: { "driver" })
        await syncing.synchronize()
        let commands = try reopened.commands()
        #expect(commands.count == 7 && commands.allSatisfy { $0.state == .verified })
        #expect(transport.sequences == Array(1...7).map(Int64.init))
        #expect(transport.serverSnapshot?.outcomes.count == 7)
        #expect(transport.serverSnapshot?.workSummary.completed == 5)
        try reopened.compact()
        #expect(try reopened.commands().isEmpty)
        let finalDisk = try ActiveRoutePersistence(ownerID: "driver", databaseURL: url)
        let final = try #require(try finalDisk.snapshot(snapshot.route.id))
        #expect(final.outcomes.count == 7 && final.workSummary.completed == 5)
        #expect(Set(final.outcomes.map(\.id)).count == 7)
    }

    @Test("Failed local transactions acknowledge no work and atomically preserve snapshot, outbox and revision")
    func transactionFailures() throws {
        for failurePoint in [ActiveRoutePersistence.FaultPoint.beforeTransaction, .duringTransaction, .beforeCommit] {
            let snapshot = fixture(), url = temporaryURL()
            let disk = try ActiveRoutePersistence(ownerID: "driver", databaseURL: url)
            try disk.pin(snapshot, selected: true)
            let backend = DurableRouteBackend(remote: ControlledRouteBackend(), ownerID: "driver", persistence: disk, transport: ControlledCommandTransport(snapshot), authenticatedOwner: { "driver" })
            let store = RouteStore(backend: backend, clock: { self.epoch })
            disk.injectFailure = { point in
                switch (point, failurePoint) {
                case (.beforeTransaction, .beforeTransaction), (.duringTransaction, .duringTransaction), (.beforeCommit, .beforeCommit):
                    throw LocalPersistenceFailure.storage("Injected disk-full failure")
                default: break
                }
            }
            let events = store.record(.delivered, packageIDs: ["package-1"], stopID: "stop-1", in: try #require(store.current), label: "Delivered")
            #expect(events.isEmpty && !store.lastCommitResult.isCommitted)
            #expect(store.persistenceIssue != nil)
            disk.injectFailure = nil
            #expect(try disk.commands().isEmpty)
            let unchanged = try #require(try disk.snapshot(snapshot.route.id))
            #expect(unchanged.outcomes.isEmpty && unchanged.route.inputRevision == snapshot.route.inputRevision)
            #expect(store.current?.workLedger.status(of: "delivery_package-1") == .pending)
            #expect(store.record(.delivered, packageIDs: ["package-1"], stopID: "stop-1", in: unchanged, label: "Retry save").count == 1)
            backend.suspend()
        }
    }

    @Test("A sending command recovers after restart and recognizes server application before local receipt")
    func appliedBeforeReceipt() async throws {
        let snapshot = fixture(), url = temporaryURL()
        let disk = try ActiveRoutePersistence(ownerID: "driver", databaseURL: url)
        try disk.pin(snapshot, selected: true)
        let outcome = TaskOutcome(id: "stable-event", packageID: "package-1", stopID: "stop-1", kind: .delivered, recordedAt: epoch)
        _ = try disk.commit([ChangeSet([.createOutcome(snapshot.route.id, outcome), .updateRoute(snapshot.route, bumpRevision: true)], label: "Delivered")], synchronize: true)
        var command = try #require(try disk.commands().first)
        command.state = .sending; try disk.update(command)
        let transport = ControlledCommandTransport(snapshot); transport.online = true
        #expect(await transport.replay(command).isVerified)
        let reopened = try ActiveRoutePersistence(ownerID: "driver", databaseURL: url)
        #expect(try reopened.commands().first?.state == .pending)
        let backend = DurableRouteBackend(remote: ControlledRouteBackend(), ownerID: "driver", persistence: reopened, transport: transport, authenticatedOwner: { "driver" })
        await backend.synchronize()
        #expect(try reopened.commands().first?.state == .verified)
        #expect(transport.serverSnapshot?.outcomes.map(\.id) == [outcome.id])
        #expect(transport.serverSnapshot?.route.inputRevision == snapshot.route.inputRevision + 1)
        #expect(transport.appliedCommandIDs.count == 1)
        try reopened.compact()
        #expect(try reopened.commands().isEmpty)
        #expect(try reopened.snapshot(snapshot.route.id)?.outcomes.map(\.id) == [outcome.id])
    }

    @Test("Wrong accounts cannot mutate or replay the original driver's pending work")
    func ownershipIsolation() async throws {
        let snapshot = fixture(), url = temporaryURL()
        let disk = try ActiveRoutePersistence(ownerID: "driver-A", databaseURL: url)
        try disk.pin(snapshot, selected: true)
        let identity = ControlledIdentity("driver-A")
        let transport = ControlledCommandTransport(snapshot)
        let backend = DurableRouteBackend(remote: ControlledRouteBackend(), ownerID: "driver-A", persistence: disk, transport: transport, authenticatedOwner: { identity.value })
        let store = RouteStore(backend: backend, clock: { self.epoch })
        #expect(store.record(.delivered, packageIDs: ["package-1"], stopID: "stop-1", in: try #require(store.current), label: "Delivered").count == 1)
        identity.value = "driver-B"; transport.online = true
        await backend.synchronize()
        #expect(transport.sequences.isEmpty)
        #expect(store.record(.delivered, packageIDs: ["package-2"], stopID: "stop-2", in: try #require(store.current), label: "Wrong owner").isEmpty)
        #expect(try disk.commands().count == 1)
        #expect(throws: LocalPersistenceFailure.ownership) { try ActiveRoutePersistence(ownerID: "driver-B", databaseURL: url) }
        backend.suspend()
        identity.value = "driver-A"
        let recovered = try ActiveRoutePersistence(ownerID: "driver-A", databaseURL: url)
        #expect(try recovered.commands().count == 1)
        #expect(try recovered.snapshot(snapshot.route.id)?.outcomes.count == 1)
    }

    @Test("Protected route selection wins over a newer remote route and incomplete reads preserve local work")
    func selectionAndMalformedListener() throws {
        let snapshot = fixture(), disk = try ActiveRoutePersistence(ownerID: "driver", databaseURL: temporaryURL())
        try disk.pin(snapshot, selected: true)
        var other = snapshot; other.route.id = "newest-remote-route"; other.route.updatedAt = epoch.addingTimeInterval(600)
        let remote = ControlledRouteBackend(other)
        let backend = DurableRouteBackend(remote: remote, ownerID: "driver", persistence: disk, transport: ControlledCommandTransport(snapshot), authenticatedOwner: { "driver" })
        let store = RouteStore(backend: backend)
        #expect(store.currentRouteID == snapshot.route.id)
        var partial = snapshot; partial.packages = []
        remote.emit(.init(snapshot: partial, pendingKeys: [], fromCache: false, readIssues: ["Packages could not be decoded"]))
        #expect(store.current?.packages.count == 3)
        #expect(!store.currentReadIssues.isEmpty)
        #expect(store.record(.delivered, packageIDs: ["package-1"], stopID: "stop-1", in: try #require(store.current), label: "Blocked").isEmpty)
        #expect(try disk.commands().isEmpty)
        backend.suspend()
    }

    @Test("Selecting or editing an uncached remote route cannot invalidate the last completely protected selection")
    func incompleteSelection() throws {
        let snapshot = fixture(), disk = try ActiveRoutePersistence(ownerID: "driver", databaseURL: temporaryURL())
        try disk.pin(snapshot, selected: true)
        let backend = DurableRouteBackend(remote: ControlledRouteBackend(), ownerID: "driver", persistence: disk, transport: ControlledCommandTransport(snapshot), authenticatedOwner: { "driver" })
        var uncached = snapshot.route; uncached.id = "uncached-remote-route"
        #expect(backend.select(uncached.id).isCommitted)
        #expect(try disk.selectedRouteID() == snapshot.route.id)
        #expect(!backend.commit(ChangeSet([.updateRoute(uncached, bumpRevision: false)], label: "Rename uncached")).isCommitted)
        #expect(backend.issue == nil)
        #expect(try disk.commands().isEmpty)
        let relaunched = try ActiveRoutePersistence(ownerID: "driver", databaseURL: disk.databaseURL)
        #expect(try relaunched.selectedRouteID() == snapshot.route.id)
        #expect(try relaunched.snapshot(snapshot.route.id)?.packages.count == 3)
        backend.suspend()
    }

    @Test("Network retry cannot overtake earlier work, and a server conflict preserves blocked intent")
    func orderingAndConflicts() async throws {
        let snapshot = fixture(), disk = try ActiveRoutePersistence(ownerID: "driver", databaseURL: temporaryURL())
        try disk.pin(snapshot, selected: true)
        for index in 1...2 {
            let before = try #require(try disk.snapshot(snapshot.route.id))
            let outcome = TaskOutcome(id: "event-\(index)", packageID: "package-\(index)", stopID: "stop-\(index)", kind: .delivered, recordedAt: epoch.addingTimeInterval(Double(index)))
            _ = try disk.commit([ChangeSet([.createOutcome(snapshot.route.id, outcome), .updateRoute(before.route, bumpRevision: true)], label: "Delivered")], synchronize: true)
        }
        let transport = ControlledCommandTransport(snapshot)
        let backend = DurableRouteBackend(remote: ControlledRouteBackend(), ownerID: "driver", persistence: disk, transport: transport, authenticatedOwner: { "driver" })
        await backend.synchronize()
        #expect(transport.sequences == [1])
        #expect(try disk.commands().map(\.state) == [.retryable, .pending])
        transport.online = true; transport.blockNext = true
        await backend.synchronize()
        #expect(try disk.commands().map(\.state) == [.blocked, .pending])
        #expect(transport.sequences == [1, 1])
        #expect(try disk.snapshot(snapshot.route.id)?.outcomes.count == 2)
        #expect(!backend.commit(ChangeSet([.bumpRouteRevision(snapshot.route.id, expectedMinimum: 1)], label: "Blocked change")).isCommitted)
    }

    @Test("Same-account authentication recovery resumes FIFO replay without discarding the saved intent")
    func authenticationRecovery() async throws {
        let snapshot = fixture(), disk = try ActiveRoutePersistence(ownerID: "driver", databaseURL: temporaryURL())
        try disk.pin(snapshot, selected: true)
        _ = try disk.commit([ChangeSet([.bumpRouteRevision(snapshot.route.id, expectedMinimum: 1)], label: "Edit")], synchronize: true)
        var command = try #require(try disk.commands().first)
        command.state = .authentication; command.lastError = "Token expired"; try disk.update(command)
        let transport = ControlledCommandTransport(snapshot); transport.online = true
        let backend = DurableRouteBackend(remote: ControlledRouteBackend(), ownerID: "driver", persistence: disk, transport: transport, authenticatedOwner: { "driver" })
        await backend.synchronize()
        #expect(try disk.commands().first?.state == .verified)
        #expect(transport.sequences == [1])
        backend.suspend()
    }

    @Test("A failed sync-status transaction surfaces recovery while already acknowledged work remains intact")
    func syncStatusWriteFailure() async throws {
        let snapshot = fixture(), disk = try ActiveRoutePersistence(ownerID: "driver", databaseURL: temporaryURL())
        try disk.pin(snapshot, selected: true)
        let event = TaskOutcome(packageID: "package-1", stopID: "stop-1", kind: .delivered, recordedAt: epoch)
        _ = try disk.commit([ChangeSet([.createOutcome(snapshot.route.id, event), .bumpRouteRevision(snapshot.route.id, expectedMinimum: 1)], label: "Delivered")], synchronize: true)
        let transport = ControlledCommandTransport(snapshot); transport.online = true
        let backend = DurableRouteBackend(remote: ControlledRouteBackend(), ownerID: "driver", persistence: disk, transport: transport, authenticatedOwner: { "driver" })
        disk.injectFailure = { if case .beforeCommit = $0 { throw LocalPersistenceFailure.storage("Receipt storage failed") } }
        await backend.synchronize()
        #expect(backend.recoveryMessage?.contains("Saved work is preserved") == true)
        disk.injectFailure = nil
        #expect(try disk.snapshot(snapshot.route.id)?.outcomes.map(\.id) == [event.id])
        #expect(try disk.commands().first?.state == .pending)
        await backend.synchronize()
        #expect(try disk.commands().first?.state == .verified)
        #expect(backend.recoveryMessage == nil)
        backend.suspend()
    }

    @Test("Pinning remote state cannot erase or alter already protected work history")
    func reconciliationHistoryGuard() throws {
        var snapshot = fixture()
        let event = TaskOutcome(packageID: "package-1", stopID: "stop-1", kind: .delivered, recordedAt: epoch)
        snapshot.outcomes = [event]
        let disk = try ActiveRoutePersistence(ownerID: "driver", databaseURL: temporaryURL())
        try disk.pin(snapshot, selected: true)
        var absent = snapshot; absent.outcomes = []
        #expect(throws: (any Error).self) { try disk.pin(absent) }
        var changed = snapshot; changed.outcomes[0].note = "Different intent"
        #expect(throws: (any Error).self) { try disk.pin(changed) }
        #expect(try disk.snapshot(snapshot.route.id)?.outcomes == [event])
        #expect(try disk.selectedRouteID() == snapshot.route.id)
    }

    @Test("A migrated demo route never treats its frozen JSON source as a newer operational replica")
    func migratedDemoSource() throws {
        let snapshot = fixture(), disk = try ActiveRoutePersistence(ownerID: "demo", databaseURL: temporaryURL())
        try disk.pin(snapshot, selected: true)
        let backend = DurableRouteBackend(remote: ControlledRouteBackend(snapshot), ownerID: "demo", persistence: disk, authenticatedOwner: { "demo" })
        let store = RouteStore(backend: backend, clock: { self.epoch })
        #expect(store.record(.delivered, packageIDs: ["package-1"], stopID: "stop-1", in: try #require(store.current), label: "Delivered").count == 1)
        store.currentRouteID = nil
        store.currentRouteID = snapshot.route.id
        #expect(store.current?.outcomes.count == 1)
        #expect(store.currentReadIssues.isEmpty)
        #expect(backend.issue == nil)
        #expect(store.record(.delivered, packageIDs: ["package-2"], stopID: "stop-2", in: try #require(store.current), label: "Delivered").count == 1)
        backend.suspend()
    }

    @Test("Leaving demo retains data; only explicit erase invokes its cleanup")
    func demoLogoutRetention() async throws {
        var erases = 0
        let account = DemoAccountService { erases += 1 }
        try account.signOut()
        #expect(erases == 0)
        try await account.deleteAccount(appleAuthorizationCode: nil)
        #expect(erases == 1)
    }

    @Test("Interrupted and repeated legacy journal migration preserve intent and never fabricate a revision baseline")
    func legacyMigration() throws {
        let disk = try ActiveRoutePersistence(ownerID: "driver", databaseURL: temporaryURL())
        let frozen = Data("""
        [{"id":"legacy-entry","label":"Delivered","createdAt":1700000000,"state":"pending","ops":[{"createOutcome":{"_0":"legacy-route","_1":{"id":"legacy-event","schemaVersion":1,"packageID":"legacy-package","stopID":"legacy-stop","kind":"delivered","recordedAt":1700000000,"photoIDs":[]}}}]}]
        """.utf8)
        let entries = try JSONDecoder.appStorage.decode([SyncJournal.Entry].self, from: frozen)
        disk.injectFailure = { point in if case .beforeCommit = point { throw LocalPersistenceFailure.storage("Interrupted migration") } }
        #expect(throws: (any Error).self) { try disk.importLegacyJournal(entries, sourceKey: "frozen-v1") }
        disk.injectFailure = nil
        #expect(try disk.commands().isEmpty)
        try disk.importLegacyJournal(entries, sourceKey: "frozen-v1")
        try disk.importLegacyJournal(entries, sourceKey: "frozen-v1")
        let command = try #require(try disk.commands().first)
        #expect(try disk.commands().count == 1)
        #expect(command.baseRevision == -1 && command.state == .blocked)
        guard case let .createOutcome(routeID, outcome) = try #require(command.ops.first) else {
            Issue.record("Legacy intent was not preserved"); return
        }
        #expect(routeID == "legacy-route" && outcome.id == "legacy-event")
        #expect(outcome.packageID == "legacy-package" && outcome.taskID == nil)
    }

    @Test("Several legacy changes recover in original order and an interrupted reconciliation preserves every intent")
    func orderedLegacyRecovery() async throws {
        let snapshot = fixture(), disk = try ActiveRoutePersistence(ownerID: "driver", databaseURL: temporaryURL())
        try disk.pin(snapshot, selected: true)
        let events = (1...2).map { TaskOutcome(id: "legacy-\($0)", packageID: "package-\($0)", stopID: "stop-\($0)", kind: .delivered, recordedAt: epoch.addingTimeInterval(Double($0))) }
        let entries = events.enumerated().map { index, event in
            SyncJournal.Entry(id: "entry-\(index)", label: "Delivered", createdAt: event.recordedAt, state: .pending, ops: [.createOutcome(snapshot.route.id, event)])
        }
        try disk.importLegacyJournal(entries, sourceKey: "two-legacy-changes")
        let original = try disk.commands()
        #expect(throws: (any Error).self) { try disk.recoverLegacy(commandID: original[1].id, serverSnapshot: snapshot) }
        disk.injectFailure = { if case .beforeCommit = $0 { throw LocalPersistenceFailure.storage("Interrupted recovery") } }
        #expect(throws: (any Error).self) { try disk.recoverLegacy(commandID: original[0].id, serverSnapshot: snapshot) }
        disk.injectFailure = nil
        #expect(try disk.commands() == original)
        #expect(try disk.snapshot(snapshot.route.id)?.outcomes.isEmpty == true)
        let ack = try disk.recoverLegacy(commandID: original[0].id, serverSnapshot: snapshot)
        #expect(ack.commandIDs == [original[0].id])
        #expect(try disk.commands().map(\.sequence) == [1, 2])
        let transport = ControlledCommandTransport(snapshot); transport.online = true
        let backend = DurableRouteBackend(remote: ControlledRouteBackend(), ownerID: "driver", persistence: disk, transport: transport, authenticatedOwner: { "driver" })
        await backend.synchronize()
        #expect(transport.sequences == [1])
        let server = try #require(transport.serverSnapshot)
        _ = try disk.recoverLegacy(commandID: original[1].id, serverSnapshot: server)
        await backend.synchronize()
        #expect(transport.sequences == [1, 2])
        #expect(transport.serverSnapshot?.outcomes.count == 2)
        #expect(try disk.commands().allSatisfy { $0.state == .verified })
        backend.suspend()
    }

    @Test("Closed protected routes reject new work until an explicit reopen")
    func closedRouteGuard() throws {
        var snapshot = fixture(); snapshot.route.status = .completed; snapshot.route.completedAt = epoch
        let disk = try ActiveRoutePersistence(ownerID: "driver", databaseURL: temporaryURL())
        try disk.pin(snapshot)
        let event = TaskOutcome(packageID: "package-1", stopID: "stop-1", kind: .delivered)
        #expect(throws: (any Error).self) { try disk.commit([ChangeSet([.createOutcome(snapshot.route.id, event)], label: "Closed work")], synchronize: true) }
        #expect(try disk.commands().isEmpty)
        var reopened = snapshot.route; reopened.status = .planning; reopened.completedAt = nil
        _ = try disk.commit([ChangeSet([.updateRoute(reopened, bumpRevision: true)], label: "Reopen")], synchronize: true)
        _ = try disk.commit([ChangeSet([.createOutcome(snapshot.route.id, event), .bumpRouteRevision(snapshot.route.id, expectedMinimum: 1)], label: "Delivered")], synchronize: true)
        #expect(try disk.snapshot(snapshot.route.id)?.outcomes.count == 1)
    }

    @Test("Protected SQL keys cannot silently alter decoded document identity or command ordering")
    func indexedIdentityCorruption() throws {
        for target in ["document", "command"] {
            let url = temporaryURL(), disk = try ActiveRoutePersistence(ownerID: "driver", databaseURL: url), snapshot = fixture()
            try disk.pin(snapshot)
            if target == "document" {
                try rawSQL("UPDATE documents SET id='different-id' WHERE kind='packages' AND id='package-1'", at: url)
                #expect(throws: (any Error).self) { try disk.snapshot(snapshot.route.id) }
            } else {
                _ = try disk.commit([ChangeSet([.bumpRouteRevision(snapshot.route.id, expectedMinimum: 1)], label: "Revise")], synchronize: true)
                try rawSQL("UPDATE commands SET sequence=99", at: url)
                #expect(throws: (any Error).self) { try disk.commands() }
            }
            #expect(throws: (any Error).self) { try ActiveRoutePersistence(ownerID: "driver", databaseURL: url) }
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("Checksum corruption and unsupported commands are retained and require recovery rather than reset")
    func corruptionPreservesStore() throws {
        let snapshot = fixture(), url = temporaryURL()
        let disk = try ActiveRoutePersistence(ownerID: "driver", databaseURL: url)
        try disk.pin(snapshot, selected: true)
        try rawSQL("UPDATE documents SET digest='broken' WHERE kind='route'", at: url)
        #expect(throws: (any Error).self) { try disk.snapshot(snapshot.route.id) }
        #expect(throws: (any Error).self) { try ActiveRoutePersistence(ownerID: "driver", databaseURL: url) }
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try rawCount("SELECT COUNT(*) FROM documents", at: url) == 11)

        let secondURL = temporaryURL(), outbox = try ActiveRoutePersistence(ownerID: "driver", databaseURL: secondURL)
        try outbox.pin(snapshot, selected: true)
        _ = try outbox.commit([ChangeSet([.bumpRouteRevision(snapshot.route.id, expectedMinimum: 1)], label: "Revise")], synchronize: true)
        var command = try #require(try outbox.commands().first); command.schemaVersion = 99
        try outbox.update(command)
        #expect(throws: LocalPersistenceFailure.unsupportedSchema(99)) { try outbox.commands() }
        #expect(throws: LocalPersistenceFailure.unsupportedSchema(99)) { try ActiveRoutePersistence(ownerID: "driver", databaseURL: secondURL) }
        #expect(try rawCount("SELECT COUNT(*) FROM commands", at: secondURL) == 1)
    }

    @Test("Frozen pre-WP1 local route JSON and WP1 task history remain readable in the protected store")
    func frozenRouteCompatibility() async throws {
        for includesTasks in [false, true] {
            let url = temporaryURL(), legacyURL = url.deletingLastPathComponent().appendingPathComponent("legacy-routes.json")
            try FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = frozenLocalRouteJSON(includesTasks: includesTasks)
            try bytes.write(to: legacyURL)
            let legacy = LocalRouteBackend(fileURL: legacyURL)
            #expect(legacy.loadFailure == nil)
            let snapshot = try #require(try await legacy.fetchRoute("legacy-route"))
            #expect(snapshot.route.inputRevision == 7 && snapshot.route.appliedRequestID == nil)
            #expect(snapshot.stops.first?.address.unit == "204")
            #expect(snapshot.packages.first?.trackingID == "TRACK-123")
            #expect(snapshot.workLedger.status(of: "delivery_legacy-parcel").isSuccessful)
            #expect(snapshot.tasks.count == (includesTasks ? 1 : 0))
            #expect(snapshot.outcomes.count == (includesTasks ? 2 : 1))
            if includesTasks {
                #expect(snapshot.tasks.first?.instructions == "Ask reception")
                #expect(snapshot.workLedger.status(of: "legacy-pickup").isSuccessful)
            }
            let protected = try ActiveRoutePersistence(ownerID: "driver", databaseURL: url)
            try protected.pin(snapshot, selected: true)
            let reopened = try ActiveRoutePersistence(ownerID: "driver", databaseURL: url)
            let restored = try #require(try reopened.snapshot("legacy-route"))
            #expect(try reopened.selectedRouteID() == "legacy-route")
            #expect(restored.stops == snapshot.stops && restored.packages == snapshot.packages)
            #expect(Set(restored.tasks) == Set(snapshot.tasks) && Set(restored.outcomes) == Set(snapshot.outcomes))
            #expect(restored.workSummary == snapshot.workSummary)
            #expect(try Data(contentsOf: legacyURL) == bytes) // Migration does not rewrite the source history.
        }
    }

    @Test("Corrupt SQLite bytes and future schemas are preserved; an empty schema-zero database upgrades safely")
    func databaseFileCompatibility() throws {
        let corruptURL = temporaryURL()
        try FileManager.default.createDirectory(at: corruptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("corrupt protected operational database; preserve these bytes".utf8)
        try corrupt.write(to: corruptURL)
        #expect(throws: (any Error).self) { try ActiveRoutePersistence(ownerID: "driver", databaseURL: corruptURL) }
        #expect(try Data(contentsOf: corruptURL) == corrupt)

        let futureURL = temporaryURL(), future = try ActiveRoutePersistence(ownerID: "driver", databaseURL: futureURL)
        try future.pin(fixture(), selected: true)
        try rawSQL("PRAGMA user_version=99", at: futureURL)
        #expect(throws: LocalPersistenceFailure.unsupportedSchema(99)) { try ActiveRoutePersistence(ownerID: "driver", databaseURL: futureURL) }
        #expect(try rawCount("PRAGMA user_version", at: futureURL) == 99)
        #expect(try rawCount("SELECT COUNT(*) FROM documents", at: futureURL) == 11)

        let versionZeroURL = temporaryURL()
        try FileManager.default.createDirectory(at: versionZeroURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rawSQL("PRAGMA user_version=0", at: versionZeroURL)
        let upgraded = try ActiveRoutePersistence(ownerID: "driver", databaseURL: versionZeroURL)
        #expect(try rawCount("PRAGMA user_version", at: versionZeroURL) == 2)
        #expect(try upgraded.allSnapshots().isEmpty && upgraded.commands().isEmpty)
        try upgraded.pin(fixture(), selected: true)
        #expect(try upgraded.snapshot("protected-route")?.packages.count == 3)
    }

    @Test("A failed batch scan returns to idle without success and the same label remains immediately retryable")
    func scanFailureAcknowledgement() async throws {
        _ = VisionLabelReader.warmUpOnce
        let url = temporaryURL(), disk = try ActiveRoutePersistence(ownerID: "driver", databaseURL: url)
        let snapshot = fixture(); try disk.pin(snapshot, selected: true)
        let remote = ControlledRouteBackend()
        let backend = DurableRouteBackend(remote: remote, ownerID: "driver", persistence: disk, authenticatedOwner: { "driver" })
        let store = RouteStore(backend: backend)
        let directory = url.deletingLastPathComponent()
        let services = AppServices(
            mode: .demo, store: store,
            settings: SettingsStore(backend: remote, defaults: UserDefaults(suiteName: "durable-scan-\(UUID().uuidString)")!),
            drafts: DraftStore(fileURL: directory.appendingPathComponent("drafts.json")),
            resolver: DemoAddressResolver(), optimizer: LocalRouteOptimizer(), photos: LocalPhotoStore(store: store),
            account: DemoAccountService {}, connectivity: ConnectivityMonitor(), location: LocationService(), journal: nil,
            mapStyle: .apple, firestoreBackend: nil, localBackend: nil, userLabel: "Test driver"
        )
        let toasts = ToastCenter(), model = ScanModel(services: services, toasts: toasts)
        model.batchMode = true
        disk.injectFailure = { point in if case .beforeCommit = point { throw LocalPersistenceFailure.storage("Injected scan storage failure") } }
        let image = try #require(AppFixtures.label("e1_victoria_unit204")?.cgImage)
        await model.process(image: image, orientation: .up, automatic: true)
        #expect(model.phase == .idle && !model.isBusy)
        #expect(model.addedThisSession == 0 && toasts.current == nil)
        #expect(model.statusMessage?.contains("Couldn't save on this iPhone") == true)
        #expect(store.current?.packages.count == snapshot.packages.count)
        #expect(try disk.commands().isEmpty)
        disk.injectFailure = nil
        await model.process(image: image, orientation: .up, automatic: true)
        #expect(model.phase == .idle && model.addedThisSession == 1)
        #expect(toasts.current?.tone == .success && store.lastCommitResult.isCommitted)
        #expect(store.current?.packages.count == snapshot.packages.count + 1)
        #expect(try disk.snapshot(snapshot.route.id)?.packages.count == snapshot.packages.count + 1)
        backend.suspend()
    }

    @Test("Failed operational Undo keeps its retry toast and original outcome until a durable retry succeeds")
    func failedUndoKeepsAffordance() async throws {
        let snapshot = fixture(), disk = try ActiveRoutePersistence(ownerID: "driver", databaseURL: temporaryURL())
        try disk.pin(snapshot, selected: true)
        let backend = DurableRouteBackend(remote: ControlledRouteBackend(), ownerID: "driver", persistence: disk, authenticatedOwner: { "driver" })
        let store = RouteStore(backend: backend, clock: { self.epoch })
        let ids = store.record(.delivered, packageIDs: ["package-1"], stopID: "stop-1", in: try #require(store.current), label: "Delivered")
        #expect(ids.count == 1)
        let toasts = ToastCenter()
        toasts.show("Delivered", symbol: "checkmark.circle.fill", tone: .success, undoAcknowledged: {
            guard let current = store.current else { return false }
            return store.undo(outcomeIDs: ids, in: current).isCommitted
        })
        let toast = try #require(toasts.current)
        disk.injectFailure = { point in if case .beforeCommit = point { throw LocalPersistenceFailure.storage("Injected Undo failure") } }
        #expect(!toasts.performUndo(for: toast))
        await Task.yield()
        try await Task.sleep(nanoseconds: 10_000_000) // Let the cancelled expiry task unwind.
        #expect(toasts.current?.id == toast.id && store.persistenceIssue != nil)
        #expect(store.current?.workLedger.status(of: "delivery_package-1").isSuccessful == true)
        #expect(try disk.snapshot(snapshot.route.id)?.outcomes.first?.voidedAt == nil)
        #expect(try disk.commands().count == 1)
        disk.injectFailure = nil
        #expect(toasts.performUndo(for: toast))
        #expect(toasts.current == nil && store.current?.workLedger.status(of: "delivery_package-1") == .pending)
        #expect(try disk.snapshot(snapshot.route.id)?.outcomes.first?.voidedAt != nil)
        #expect(try disk.commands().count == 2)
        // Existing non-operational Void callers keep their original behavior.
        var legacyInvocations = 0
        toasts.show("Legacy", symbol: "arrow.uturn.backward", tone: .neutral, undo: { legacyInvocations += 1 })
        #expect(toasts.performUndo(for: try #require(toasts.current)))
        #expect(legacyInvocations == 1 && toasts.current == nil)
        backend.suspend()
    }

    @Test("Measured large route: 500 stops, 750 packages, 50 pickups, 100 commits, restore and deterministic mock replay")
    func measuredLargeRoute() async throws {
        let snapshot = largeFixture(), url = temporaryURL()
        let disk = try ActiveRoutePersistence(ownerID: "driver", databaseURL: url)
        let pinStarted = Date(); try disk.pin(snapshot, selected: true)
        let pinSeconds = Date().timeIntervalSince(pinStarted), initialBytes = try storageBytes(at: url)
        let transport = ControlledCommandTransport(snapshot)
        let backend = DurableRouteBackend(remote: ControlledRouteBackend(), ownerID: "driver", persistence: disk, transport: transport, authenticatedOwner: { "driver" })
        let store = RouteStore(backend: backend, clock: { self.epoch })
        var latencies: [Double] = []
        for package in snapshot.packages.prefix(100) {
            let before = try #require(store.current), started = Date()
            let ids = store.record(.delivered, packageIDs: [package.id], stopID: package.stopID, in: before, label: "Delivered")
            latencies.append(Date().timeIntervalSince(started))
            #expect(ids.count == 1)
        }
        backend.suspend()
        let pending = try disk.commands()
        #expect(pending.count == 100 && pending.map(\.sequence) == Array(1...100).map(Int64.init))
        let commandBytes = try pending.reduce(0) { try $0 + ActiveRoutePersistence.encode($1).count }
        let afterCommitBytes = try storageBytes(at: url)
        let restoreStarted = Date(), restoredDisk = try ActiveRoutePersistence(ownerID: "driver", databaseURL: url)
        let restored = try #require(try restoredDisk.snapshot(snapshot.route.id))
        let restoreSeconds = Date().timeIntervalSince(restoreStarted)
        #expect(restored.stops.count == 500 && restored.packages.count == 750 && restored.tasks.count == 50)
        #expect(restored.outcomes.count == 100 && restored.workSummary.completed == 100)
        #expect(restored.route.inputRevision == snapshot.route.inputRevision + 100)
        transport.online = true
        let replay = DurableRouteBackend(remote: ControlledRouteBackend(), ownerID: "driver", persistence: restoredDisk, transport: transport, authenticatedOwner: { "driver" })
        let replayStarted = Date(); await replay.synchronize()
        let replaySeconds = Date().timeIntervalSince(replayStarted)
        #expect(transport.sequences == Array(1...100).map(Int64.init))
        #expect(transport.appliedCommandIDs.count == 100 && transport.serverSnapshot?.outcomes.count == 100)
        #expect(try restoredDisk.commands().allSatisfy { $0.state == .verified })
        try restoredDisk.compact()
        #expect(try restoredDisk.commands().isEmpty)
        #expect(try restoredDisk.snapshot(snapshot.route.id)?.outcomes.count == 100)
        let afterCompactionBytes = try storageBytes(at: url), sorted = latencies.sorted()
        let meanMilliseconds = latencies.reduce(0, +) / Double(latencies.count) * 1_000
        let p95Milliseconds = sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1] * 1_000
        let maxMilliseconds = (sorted.last ?? 0) * 1_000
        // Environment observations, not product SLOs. Mock transport includes local receipt writes,
        // but excludes real Firestore latency, authentication, radios and device flash behavior.
        print("DURABILITY_SCALE stops=500 packages=750 pickups=50 commits=100 pin_ms=\(pinSeconds * 1_000) commit_mean_ms=\(meanMilliseconds) commit_p95_ms=\(p95Milliseconds) commit_max_ms=\(maxMilliseconds) restore_ms=\(restoreSeconds * 1_000) mock_replay_seconds=\(replaySeconds) mock_commands_per_second=\(100 / max(replaySeconds, 0.000_001)) initial_bytes_including_wal_shm=\(initialBytes) after_commits_bytes_including_wal_shm=\(afterCommitBytes) after_compaction_bytes_including_wal_shm=\(afterCompactionBytes) pending_command_json_bytes=\(commandBytes)")
    }

    private func largeFixture() -> RouteSnapshot {
        var route = fixture().route; route.id = "large-protected-route"
        var stops: [Stop] = []
        for index in 0..<500 {
            let address = PostalAddress(civicNumber: "\(100 + index)", streetName: "EXAMPLE ST", municipality: "VICTORIA", province: .BC, postalCode: "V8W 1A1")
            let point = GeoPoint(latitude: 48.4 + Double(index % 25) * 0.001, longitude: -123.3 - Double(index / 25) * 0.001)
            let resolution = StopResolution(provider: nil, placeID: nil, located: LocatedPoint(point: point, source: .driverPin), match: .driverPin, resolvedAt: epoch)
            var stop = Stop(id: "large-stop-\(index)", address: address, addressStatus: .driverConfirmed, resolution: resolution, sequence: Double(index), now: epoch)
            stop.notes = "Access instructions for location \(index)"; stops.append(stop)
        }
        let packages = (0..<750).map { Package(id: "large-package-\($0)", stopID: "large-stop-\($0 % 500)", trackingID: "LARGE\($0)", notes: "Shelf \($0 % 8)", source: .manual, now: epoch) }
        let tasks = (0..<50).map { LocationTask(id: "large-pickup-\($0)", stopID: "large-stop-\($0)", kind: .pickup, title: "Collect return \($0)", instructions: "Ask reception", now: epoch) }
        return RouteSnapshot(route: route, stops: stops, packages: packages, outcomes: [], tasks: tasks)
    }

    private func storageBytes(at url: URL) throws -> Int {
        try ["", "-wal", "-shm"].reduce(0) { total, suffix in
            let path = url.path + suffix
            guard FileManager.default.fileExists(atPath: path) else { return total }
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            return total + ((attributes[.size] as? NSNumber)?.intValue ?? 0)
        }
    }

    /// Literal legacy bytes are intentionally independent of the current Codable encoders.
    private func frozenLocalRouteJSON(includesTasks: Bool) -> Data {
        let tasks = includesTasks ? #", "tasks":{"legacy-pickup":{"id":"legacy-pickup","schemaVersion":1,"stopID":"legacy-stop","kind":"pickup","required":true,"title":"Collect return","instructions":"Ask reception","orderRank":0,"createdAt":1790000000,"updatedAt":1790000000}}"# : ""
        let pickupOutcome = includesTasks ? #", "legacy-pickup-event":{"id":"legacy-pickup-event","schemaVersion":2,"taskID":"legacy-pickup","stopID":"legacy-stop","kind":"completed","recordedAt":1790000001,"photoIDs":[]}"# : ""
        return Data("""
        {"schemaVersion":1,"routes":{"legacy-route":{
          "route":{"id":"legacy-route","schemaVersion":1,"name":"Legacy","status":"active","createdAt":1790000000,"updatedAt":1790000000,"serviceDate":"2026-10-05","timeZoneID":"America/Vancouver","departureMinute":480,"returnToStart":false,"defaultServiceSeconds":120,"objective":"balanced","considerTraffic":true,"inputRevision":7,"summary":{"delivered":1,"failed":0,"skipped":0,"excluded":0,"pending":0,"stopCount":1,"packageCount":1}},
          "stops":{"legacy-stop":{"id":"legacy-stop","schemaVersion":1,"createdAt":1790000000,"updatedAt":1790000000,"address":{"unit":"204","civicNumber":"123","streetName":"EXAMPLE ST","municipality":"VICTORIA","province":"BC","postalCode":"V8W 1A1","country":"CA","additionalLines":[]},"destinationKey":"legacy-unit-204","addressStatus":"needsReview","reviewReasons":[],"sequence":1,"pin":"none","notes":"Buzzer 204"}},
          "packages":{"legacy-parcel":{"id":"legacy-parcel","schemaVersion":1,"stopID":"legacy-stop","createdAt":1790000000,"updatedAt":1790000000,"trackingID":"TRACK-123","trackingKey":"TRACK123","recipientName":"A Driver","storageLocation":"Shelf B","notes":"Signature","source":"scan"}},
          "outcomes":{"legacy-outcome":{"id":"legacy-outcome","schemaVersion":1,"packageID":"legacy-parcel","stopID":"legacy-stop","kind":"delivered","recordedAt":1790000000,"photoIDs":[]}\(pickupOutcome)},
          "photos":{}\(tasks)
        }}}
        """.utf8)
    }

    private func rawSQL(_ sql: String, at url: URL) throws {
        var connection: OpaquePointer?
        guard sqlite3_open(url.path, &connection) == SQLITE_OK else { throw LocalPersistenceFailure.storage("Test database open failed") }
        defer { sqlite3_close(connection) }
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw LocalPersistenceFailure.storage("Test SQL failed") }
    }
    private func rawCount(_ sql: String, at url: URL) throws -> Int {
        var connection: OpaquePointer?, statement: OpaquePointer?
        guard sqlite3_open(url.path, &connection) == SQLITE_OK else { throw LocalPersistenceFailure.storage("Test database open failed") }
        defer { sqlite3_finalize(statement); sqlite3_close(connection) }
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else { throw LocalPersistenceFailure.storage("Test count failed") }
        return Int(sqlite3_column_int64(statement, 0))
    }
}

@MainActor
private final class ControlledIdentity {
    var value: String?
    init(_ value: String) { self.value = value }
}

/// A cache/listener source deliberately independent of the protected database.
@MainActor
private final class ControlledRouteBackend: RouteBackend {
    let kind = BackendKind.firestore
    var routes: [Route]
    private var observers: [(RouteSnapshotEnvelope?) -> Void] = []
    init(_ snapshot: RouteSnapshot? = nil) { routes = snapshot.map { [$0.route] } ?? [] }
    func observeRoutes(_ onChange: @escaping ([Route], Set<String>) -> Void) -> ListenerToken { onChange(routes, []); return ListenerToken {} }
    func observeRoute(_ id: RouteID, _ onChange: @escaping (RouteSnapshotEnvelope?) -> Void) -> ListenerToken { observers.append(onChange); return ListenerToken {} }
    func emit(_ envelope: RouteSnapshotEnvelope?) { observers.forEach { $0(envelope) } }
    func commit(_ change: ChangeSet) -> LocalCommitResult { .failed(.storage("Remote cache is not the local acknowledgement boundary")) }
    func fetchRoute(_ id: RouteID) async throws -> RouteSnapshot? { nil }
    func loadSettings() async -> UserSettings? { nil }
    func saveSettings(_ settings: UserSettings) {}
}

/// Models persistent remote command receipts, rather than trusting a callback or client memory.
@MainActor
private final class ControlledCommandTransport: DurableCommandTransport {
    var online = false
    var blockNext = false
    var sequences: [Int64] = []
    var appliedCommandIDs = Set<String>()
    private var database: LocalRouteBackend.Database
    var serverSnapshot: RouteSnapshot? {
        guard let data = database.routes.values.first else { return nil }
        return RouteSnapshot(route: data.route, stops: Array(data.stops.values), packages: Array(data.packages.values), outcomes: Array(data.outcomes.values), photos: Array(data.photos.values), tasks: Array(data.tasks.values))
    }
    init(_ snapshot: RouteSnapshot) {
        var data = LocalRouteBackend.RouteData(route: snapshot.route)
        data.stops = Dictionary(uniqueKeysWithValues: snapshot.stops.map { ($0.id, $0) })
        data.packages = Dictionary(uniqueKeysWithValues: snapshot.packages.map { ($0.id, $0) })
        data.tasks = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0) })
        data.outcomes = Dictionary(uniqueKeysWithValues: snapshot.outcomes.map { ($0.id, $0) })
        database = LocalRouteBackend.Database(); database.routes[snapshot.route.id] = data
    }
    func replay(_ command: DurableCommand) async -> RemoteReplayResult {
        sequences.append(command.sequence)
        guard online else { return .retryable("Network unavailable") }
        if blockNext { blockNext = false; return .blocked("Server revision moved ahead; saved intent needs review") }
        if appliedCommandIDs.contains(command.id) { return .verified }
        for operation in command.ops { LocalRouteBackend.apply(operation, to: &database) }
        appliedCommandIDs.insert(command.id)
        return .verified
    }
    func fetchVerifiedRoute(_ id: RouteID) async throws -> RouteSnapshot? { online && serverSnapshot?.route.id == id ? serverSnapshot : nil }
}

private extension RemoteReplayResult {
    var isVerified: Bool { if case .verified = self { true } else { false } }
}
