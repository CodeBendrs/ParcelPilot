import CryptoKit
import Foundation
import ParcelPilotKit
import SQLite3

/// One checked SQLite transaction is the device acknowledgement boundary. Only changed documents
/// are written for a command; no task statuses are persisted. WorkLedger reconstructs those.
@MainActor
final class ActiveRoutePersistence {
    enum FaultPoint { case beforeTransaction, duringTransaction, beforeCommit }
    let ownerID: String
    let databaseURL: URL
    var injectFailure: ((FaultPoint) throws -> Void)?
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func defaultURL(ownerID: String, namespace: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let key = digest(Data((namespace + ":" + ownerID).utf8))
        return base.appendingPathComponent("ProtectedRoutes/\(key)", isDirectory: true).appendingPathComponent("operations.sqlite")
    }

    init(ownerID: String, databaseURL: URL, migrationFailure: (() throws -> Void)? = nil) throws {
        self.ownerID = ownerID; self.databaseURL = databaseURL
        do {
            let directory = databaseURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var protectedDirectory = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try protectedDirectory.setResourceValues(values)
            guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw storageError() }
            try execute("PRAGMA busy_timeout=3000")
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA fullfsync=ON")
            try execute("PRAGMA foreign_keys=ON")
            let version = Int(try scalar("PRAGMA user_version") ?? "0") ?? 0
            guard version <= 2 else { throw LocalPersistenceFailure.unsupportedSchema(version) }
            guard try scalar("PRAGMA quick_check") == "ok" else { throw LocalPersistenceFailure.corrupt("SQLite integrity check failed.") }
            try transaction {
                try execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value BLOB NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS documents (route TEXT NOT NULL, kind TEXT NOT NULL, id TEXT NOT NULL, payload BLOB NOT NULL, digest TEXT NOT NULL, PRIMARY KEY(route,kind,id))")
                try execute("CREATE TABLE IF NOT EXISTS route_state (route TEXT PRIMARY KEY, next_sequence INTEGER NOT NULL DEFAULT 1)")
                try execute("CREATE TABLE IF NOT EXISTS commands (id TEXT PRIMARY KEY, route TEXT NOT NULL, sequence INTEGER NOT NULL, payload BLOB NOT NULL, UNIQUE(route,sequence))")
                try execute("CREATE TABLE IF NOT EXISTS photos (id TEXT PRIMARY KEY, payload BLOB NOT NULL, digest TEXT NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS execution (key TEXT PRIMARY KEY CHECK(key='current'), payload BLOB NOT NULL, digest TEXT NOT NULL)")
                if let owner = try metadata("owner") {
                    guard owner == ownerID else { throw LocalPersistenceFailure.ownership }
                } else { try setMetadata("owner", ownerID) }
                if version < 2 { try migrationFailure?() }
                try execute("PRAGMA user_version=2")
                // A terminated sending attempt becomes replayable; receipts make reapplication safe.
                for var command in try commands() where command.state == .sending {
                    command.state = .pending; try writeCommand(command)
                }
            }
            _ = try allSnapshots(); _ = try commands(); _ = try loadPhotos()
            if let execution = try executionSession(), execution.isUnfinished {
                guard let route = try snapshot(execution.routeID), route.route.isOpen else {
                    throw LocalPersistenceFailure.conflict("The executing route is missing or closed. Saved route execution has been preserved.")
                }
            }
            if let selected = try selectedRouteID(), try snapshot(selected) == nil {
                throw LocalPersistenceFailure.corrupt("The selected protected route is missing.")
            }
            guard try rows("SELECT route FROM route_state WHERE next_sequence < 1 OR next_sequence <= (SELECT COALESCE(MAX(sequence),0) FROM commands WHERE commands.route=route_state.route)").isEmpty else {
                throw LocalPersistenceFailure.corrupt("Protected command sequence is inconsistent.")
            }
            for suffix in ["", "-wal", "-shm"] {
                let path = databaseURL.path + suffix
                if FileManager.default.fileExists(atPath: path) {
                    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: path)
                }
            }
        } catch {
            sqlite3_close_v2(db); db = nil
            if let failure = error as? LocalPersistenceFailure { throw failure }
            throw LocalPersistenceFailure.storage(error.localizedDescription)
        }
    }

    isolated deinit { sqlite3_close_v2(db) }

    static func digest(_ data: Data) -> String {
        let alphabet = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []; bytes.reserveCapacity(64)
        for byte in SHA256.hash(data: data) {
            bytes.append(alphabet[Int(byte >> 4)]); bytes.append(alphabet[Int(byte & 15)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
    static func commandDigest(_ command: DurableCommand) throws -> String {
        var identity = command; identity.payloadDigest = ""; identity.state = .pending; identity.lastError = nil
        return digest(try encode(identity))
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970; encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        do { return try decoder.decode(type, from: data) }
        catch { throw LocalPersistenceFailure.corrupt("A protected record couldn't be decoded.") }
    }

    func selectedRouteID() throws -> RouteID? { try metadata("selected")?.nilIfEmptyString }
    func containsRoute(_ routeID: RouteID) throws -> Bool {
        try scalar("SELECT 1 FROM documents WHERE route=? AND kind='route' AND id=?", [routeID, routeID]) != nil
    }
    func select(_ routeID: RouteID?) throws {
        try transaction { try setMetadata("selected", routeID ?? "") }
    }
    func executionSession() throws -> RouteExecutionSession? {
        let records = try rows("SELECT key,payload,digest FROM execution")
        guard records.count <= 1 else { throw LocalPersistenceFailure.corrupt("Multiple current route executions were found.") }
        guard let row = records.first else { return nil }
        guard string(row[0]) == "current", Self.digest(row[1]) == string(row[2]) else {
            throw LocalPersistenceFailure.corrupt("Route execution checksum or key failed.")
        }
        let session = try Self.decode(RouteExecutionSession.self, row[1])
        guard session.schemaVersion == 1 else { throw LocalPersistenceFailure.unsupportedSchema(session.schemaVersion) }
        guard session.isValid else { throw LocalPersistenceFailure.corrupt("Route execution is invalid.") }
        return session
    }
    private func writeExecutionSession(_ session: RouteExecutionSession) throws {
        let data = try Self.encode(session)
        try execute("INSERT INTO execution(key,payload,digest) VALUES('current',?,?) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload,digest=excluded.digest", [data, Data(Self.digest(data).utf8)])
    }
    /// Verified server advancement may be adopted only after account-wide execution intent is
    /// acknowledged. A missing/replaced server record never erases accepted local execution.
    func pinExecutionSession(_ session: RouteExecutionSession?) throws {
        guard try commands().filter({ $0.ops.contains { if case .transitionExecution = $0 { true } else { false } } }).allSatisfy({ $0.state == .verified }) else {
            throw LocalPersistenceFailure.conflict("Saved route execution is still synchronizing.")
        }
        let local = try executionSession()
        guard let session else {
            guard local == nil else { throw LocalPersistenceFailure.conflict("Route execution was removed remotely. Saved intent has been preserved.") }
            return
        }
        guard session.schemaVersion == 1 else { throw LocalPersistenceFailure.unsupportedSchema(session.schemaVersion) }
        guard session.isValid else { throw LocalPersistenceFailure.corrupt("Server route execution is invalid.") }
        if let local {
            if local.matches(session) { return }
            if local.id == session.id {
                guard local.routeID == session.routeID,
                      abs(local.startedAt.timeIntervalSince(session.startedAt)) < 0.000_002,
                      session.transitionCount > local.transitionCount,
                      session.changedAt.timeIntervalSince(local.changedAt) > -0.000_002,
                      local.state != .finished else { throw LocalPersistenceFailure.conflict("Server route execution conflicts with saved intent.") }
            } else {
                guard !local.isUnfinished, session.startedAt.timeIntervalSince(local.changedAt) > -0.000_002 else {
                    throw LocalPersistenceFailure.conflict("Another route execution conflicts with this iPhone's current execution.")
                }
            }
        }
        if session.isUnfinished {
            guard let route = try snapshot(session.routeID), route.route.isOpen else {
                throw LocalPersistenceFailure.conflict("The executing route must be completely loaded and open before accepting its execution.")
            }
        }
        try transaction { try writeExecutionSession(session) }
    }
    func snapshot(_ routeID: RouteID) throws -> RouteSnapshot? {
        let records = try rows("SELECT kind,id,payload,digest FROM documents WHERE route=? ORDER BY kind,id", [routeID])
        var route: Route?; var stops: [Stop] = []; var packages: [Package] = []; var tasks: [LocationTask] = []; var outcomes: [TaskOutcome] = []; var photos: [DeliveryPhoto] = []
        for row in records {
            let data = row[2]; guard Self.digest(data) == string(row[3]) else { throw LocalPersistenceFailure.corrupt("Protected record checksum failed.") }
            let identity = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if ["stops", "packages", "photos"].contains(string(row[0])), let version = identity?["schemaVersion"] as? Int, version != 1 {
                throw LocalPersistenceFailure.unsupportedSchema(version)
            }
            guard identity?["id"] as? String == string(row[1]) else { throw LocalPersistenceFailure.corrupt("Protected document key mismatch.") }
            switch string(row[0]) {
            case "route": route = try Self.decode(Route.self, data)
            case "stops": stops.append(try Self.decode(Stop.self, data))
            case "packages": packages.append(try Self.decode(Package.self, data))
            case "tasks": tasks.append(try Self.decode(LocationTask.self, data))
            case "outcomes": outcomes.append(try Self.decode(TaskOutcome.self, data))
            case "photos": photos.append(try Self.decode(DeliveryPhoto.self, data))
            default: throw LocalPersistenceFailure.corrupt("Unknown protected record kind.")
            }
        }
        guard let route else {
            if !records.isEmpty { throw LocalPersistenceFailure.corrupt("Route identity is missing.") }
            return nil
        }
        guard route.id == routeID else { throw LocalPersistenceFailure.corrupt("Route identity mismatch.") }
        guard route.schemaVersion == 1 else { throw LocalPersistenceFailure.unsupportedSchema(route.schemaVersion) }
        let snapshot = RouteSnapshot(route: route, stops: stops, packages: packages, outcomes: outcomes, photos: photos, tasks: tasks)
        let stopIDs = Set(stops.map(\.id))
        guard stopIDs.count == stops.count, packages.allSatisfy({ stopIDs.contains($0.stopID) }), snapshot.orphanTasks.isEmpty else {
            throw LocalPersistenceFailure.corrupt("Protected work definitions have missing targets.")
        }
        return snapshot
    }
    func allSnapshots() throws -> [RouteSnapshot] {
        try rows("SELECT DISTINCT route FROM documents ORDER BY route").compactMap { try snapshot(string($0[0])) }
    }

    /// Only complete operational generations are pinned. Pending intent is never overwritten.
    func pin(_ snapshot: RouteSnapshot, selected: Bool = false) throws {
        if let execution = try executionSession(), execution.isUnfinished, execution.routeID == snapshot.route.id, !snapshot.route.isOpen {
            throw LocalPersistenceFailure.conflict("The executing route was closed remotely. Saved execution has been preserved.")
        }
        guard try commands(routeID: snapshot.route.id).allSatisfy({ $0.state == .verified }) else {
            throw LocalPersistenceFailure.conflict("Saved work is still synchronizing. Keep this iPhone's route until it is verified.")
        }
        if let local = try self.snapshot(snapshot.route.id) {
            guard abs(local.route.createdAt.timeIntervalSince(snapshot.route.createdAt)) < 0.000_002,
                  Self.preservesHistory(local.outcomes, in: snapshot.outcomes) else {
                throw LocalPersistenceFailure.conflict("Remote route identity or work history changed. Saved data has been preserved.")
            }
        }
        let stopIDs = Set(snapshot.stops.map(\.id))
        guard snapshot.route.schemaVersion == 1, stopIDs.count == snapshot.stops.count, snapshot.orphanTasks.isEmpty,
              Set(snapshot.packages.map(\.id)).count == snapshot.packages.count,
              Set(snapshot.tasks.map(\.id)).count == snapshot.tasks.count,
              Set(snapshot.outcomes.map(\.id)).count == snapshot.outcomes.count,
              Set(snapshot.photos.map(\.id)).count == snapshot.photos.count,
              snapshot.packages.allSatisfy({ stopIDs.contains($0.stopID) }) else {
            throw LocalPersistenceFailure.corrupt("The complete route has invalid identities or missing work targets.")
        }
        try transaction {
            try execute("DELETE FROM documents WHERE route=?", [snapshot.route.id])
            try put(snapshot.route, route: snapshot.route.id, kind: "route", id: snapshot.route.id)
            for stop in snapshot.stops { try put(stop, route: snapshot.route.id, kind: "stops", id: stop.id) }
            for package in snapshot.packages { try put(package, route: snapshot.route.id, kind: "packages", id: package.id) }
            for task in snapshot.tasks { try put(task, route: snapshot.route.id, kind: "tasks", id: task.id) }
            for outcome in snapshot.outcomes { try put(outcome, route: snapshot.route.id, kind: "outcomes", id: outcome.id) }
            for photo in snapshot.photos { try put(photo, route: snapshot.route.id, kind: "photos", id: photo.id) }
            try execute("INSERT OR IGNORE INTO route_state(route,next_sequence) VALUES(?,1)", [snapshot.route.id])
            if selected { try setMetadata("selected", snapshot.route.id) }
            _ = try self.snapshot(snapshot.route.id)
        }
    }
    static func preservesHistory(_ local: [TaskOutcome], in remote: [TaskOutcome]) -> Bool {
        local.allSatisfy { outcome in
            guard var stored = remote.first(where: { $0.id == outcome.id }),
                  abs(stored.recordedAt.timeIntervalSince(outcome.recordedAt)) < 0.000_002 else { return false }
            if let voided = outcome.voidedAt {
                guard let actual = stored.voidedAt, abs(actual.timeIntervalSince(voided)) < 0.000_002 else { return false }
            }
            var intended = outcome; stored.voidedAt = nil; intended.voidedAt = nil
            stored.recordedAt = intended.recordedAt
            return stored == intended
        }
    }

    /// A logical action may contain multiple bounded remote batches. All batches and local effects
    /// commit together; failure cannot acknowledge a partial delivery group or route copy.
    func commit(_ changes: [ChangeSet], synchronize: Bool) throws -> LocalCommitAck {
        var ids: [String] = []
        // Stop removal deliberately retains its outcome history for Undo. A standalone task
        // deletion has no restoration contract and must never remove a historical obligation.
        let removedStops = Set(changes.flatMap(\.ops).compactMap { op -> String? in
            if case let .deleteStop(routeID, stopID) = op { return "\(routeID)/\(stopID)" }
            return nil
        })
        try transaction {
            for change in changes where !change.ops.isEmpty {
                let routeIDs = Set(change.ops.map(LocalRouteBackend.routeID(of:)))
                guard routeIDs.count == 1, let routeID = routeIDs.first else { throw LocalPersistenceFailure.conflict("A command must target one route.") }
                if try commands(routeID: routeID).contains(where: { $0.state == .blocked || $0.state == .authentication }) {
                    throw LocalPersistenceFailure.conflict("Resolve this route's sync problem before recording more work. Saved intent has been preserved.")
                }
                let before = try snapshot(routeID)
                for op in change.ops {
                    guard case let .deleteTask(_, taskID) = op,
                          let task = before?.tasks.first(where: { $0.id == taskID }),
                          !removedStops.contains("\(routeID)/\(task.stopID)") else { continue }
                    let hasHistory = before?.outcomes.contains { $0.targetTaskID == taskID } == true
                        || change.ops.contains { if case let .createOutcome(_, event) = $0 { event.targetTaskID == taskID } else { false } }
                    guard !hasHistory else {
                        throw LocalPersistenceFailure.conflict("This work item has outcome history. Keep it for review or use Retry/Undo; it cannot be deleted.")
                    }
                }
                let executionOps = change.ops.filter { if case .transitionExecution = $0 { true } else { false } }
                guard executionOps.count <= 1 else { throw LocalPersistenceFailure.conflict("One command may contain only one execution transition.") }
                if !executionOps.isEmpty, try commands().contains(where: { command in
                    (command.state == .blocked || command.state == .authentication) && command.ops.contains { if case .transitionExecution = $0 { true } else { false } }
                }) {
                    throw LocalPersistenceFailure.conflict("Resolve the saved route execution sync problem before changing execution. Saved intent has been preserved.")
                }
                if executionOps.contains(where: { if case let .transitionExecution(_, _, session) = $0 { session.state == .finished } else { false } }) {
                    guard change.ops.contains(where: { if case let .updateRoute(route, _) = $0 { route.id == routeID && !route.isOpen } else { false } }) else {
                        throw LocalPersistenceFailure.conflict("Finish execution and close the route in the same saved action.")
                    }
                }
                if let current = try executionSession(), current.isUnfinished, current.routeID == routeID,
                   change.ops.contains(where: { if case let .updateRoute(route, _) = $0 { !route.isOpen } else { false } }) {
                    guard executionOps.contains(where: { if case let .transitionExecution(_, expected, session) = $0 {
                        expected?.matches(current) == true && session.id == current.id && session.state == .finished
                    } else { false } }) else { throw LocalPersistenceFailure.conflict("Finish route execution explicitly before closing or archiving this route.") }
                }
                let changesWork = change.ops.contains { op in
                    switch op {
                    case .putStop, .deleteStop, .putPackage, .deletePackage, .putTask, .deleteTask, .createOutcome, .voidOutcome: true
                    default: false
                    }
                }
                let reopens = change.ops.contains { if case let .updateRoute(route, _) = $0 { route.isOpen } else { false } }
                if let before, !before.route.isOpen, changesWork, !reopens {
                    throw LocalPersistenceFailure.conflict("This route is closed. Reopen it explicitly before recording or editing work.")
                }
                let sequence = Int64(try scalar("SELECT next_sequence FROM route_state WHERE route=?", [routeID]) ?? "1") ?? 1
                var command = DurableCommand(id: StableID.make(), accountID: ownerID, routeID: routeID, sequence: sequence, createdAt: Date(), label: change.label, ops: change.ops,
                    baseRevision: before?.route.inputRevision ?? 0, baseRouteCreatedAt: before?.route.createdAt, baseRouteUpdatedAt: before?.route.updatedAt, payloadDigest: "")
                command.baselines = try baselines(for: change.ops, routeID: routeID)
                command.payloadDigest = try Self.commandDigest(command)
                command.state = synchronize ? .pending : .verified
                let updated = try apply(change.ops, routeID: routeID, route: before?.route)
                try writeCommand(command)
                try execute("INSERT INTO route_state(route,next_sequence) VALUES(?,?) ON CONFLICT(route) DO UPDATE SET next_sequence=excluded.next_sequence", [routeID, String(sequence + 1)])
                ids.append(command.id)
                if change.ops.contains(where: { if case .createRoute = $0 { true } else { false } }) { try setMetadata("selected", routeID) }
                if !updated.isOpen, try metadata("selected") == routeID { try setMetadata("selected", "") }
            }
            try injectFailure?(.duringTransaction)
        }
        return LocalCommitAck(commandIDs: ids, syncPending: synchronize && !ids.isEmpty)
    }

    private func apply(_ operations: [ChangeOp], routeID: RouteID, route initial: Route?) throws -> Route {
        var route = initial
        let baseRevision = route?.inputRevision ?? 0
        var bumpsRevision = false; var revisionFloor = 0
        for operation in operations {
            switch operation {
            case let .createRoute(value):
                guard route == nil else { throw LocalPersistenceFailure.conflict("The route already exists.") }
                route = value; try put(value, route: routeID, kind: "route", id: routeID)
            case let .updateRoute(value, bump):
                guard let previous = route else { throw LocalPersistenceFailure.conflict("The route is missing from protected storage.") }
                guard previous.createdAt == value.createdAt else { throw LocalPersistenceFailure.conflict("Route identity changed.") }
                bumpsRevision = bumpsRevision || bump
                var changed = value; changed.inputRevision = previous.inputRevision
                route = changed; try put(changed, route: routeID, kind: "route", id: routeID)
            case let .bumpRouteRevision(_, minimum):
                guard var changed = route else { throw LocalPersistenceFailure.conflict("The route is missing.") }
                bumpsRevision = true; revisionFloor = max(revisionFloor, minimum)
                changed.inputRevision = max(baseRevision + 1, revisionFloor); route = changed
                try put(changed, route: routeID, kind: "route", id: routeID)
            case let .putStop(_, value): try put(value, route: routeID, kind: "stops", id: value.id)
            case let .putPackage(_, value): try put(value, route: routeID, kind: "packages", id: value.id)
            case let .putTask(_, value):
                if let previous: LocationTask = try document(route: routeID, kind: "tasks", id: value.id) {
                    guard previous.schemaVersion == value.schemaVersion, previous.stopID == value.stopID,
                          previous.kind == value.kind, previous.packageID == value.packageID,
                          previous.createdAt == value.createdAt else {
                        throw LocalPersistenceFailure.conflict("A work item's identity and target cannot change. Add a new item instead.")
                    }
                }
                try put(value, route: routeID, kind: "tasks", id: value.id)
            case let .createOutcome(_, value):
                if let previous: TaskOutcome = try document(route: routeID, kind: "outcomes", id: value.id) {
                    var immutable = previous; immutable.voidedAt = nil
                    guard immutable == value else { throw LocalPersistenceFailure.conflict("An event ID has conflicting intent.") }
                } else { try put(value, route: routeID, kind: "outcomes", id: value.id) }
            case let .voidOutcome(_, id, at):
                guard var outcome: TaskOutcome = try document(route: routeID, kind: "outcomes", id: id) else { throw LocalPersistenceFailure.conflict("Undo target is missing.") }
                if outcome.voidedAt == nil { outcome.voidedAt = at; try put(outcome, route: routeID, kind: "outcomes", id: id) }
            case let .putPhoto(_, value): try put(value, route: routeID, kind: "photos", id: value.id)
            case let .deleteStop(_, id): try delete(routeID, "stops", id)
            case let .deletePackage(_, id): try delete(routeID, "packages", id)
            case let .deleteTask(_, id): try delete(routeID, "tasks", id)
            case let .deletePhoto(_, id): try delete(routeID, "photos", id)
            case let .transitionExecution(_, expected, session):
                let current = try executionSession()
                guard session.routeID == routeID,
                      (current == nil && expected == nil) || (current != nil && expected != nil && current!.matches(expected!)) else {
                    throw LocalPersistenceFailure.conflict("Route execution changed. Saved intent has been preserved; reload before retrying.")
                }
                do { try RouteExecutionSession.validateTransition(from: current, to: session) }
                catch { throw LocalPersistenceFailure.conflict(error.localizedDescription) }
                guard initial?.isOpen == true || (session.state == .finished && initial != nil) else {
                    throw LocalPersistenceFailure.conflict("Load an open route before starting or resuming route execution.")
                }
                try writeExecutionSession(session)
            }
        }
        guard var finalRoute = route else { throw LocalPersistenceFailure.conflict("A route must be loaded before recording work.") }
        finalRoute.inputRevision = max(1, revisionFloor, baseRevision + (bumpsRevision ? 1 : 0))
        try put(finalRoute, route: routeID, kind: "route", id: routeID)
        if let execution = try executionSession(), execution.isUnfinished, execution.routeID == routeID, !finalRoute.isOpen {
            throw LocalPersistenceFailure.conflict("Unfinished route execution cannot be closed implicitly.")
        }
        _ = try snapshot(routeID)
        return finalRoute
    }

    func commands(routeID: RouteID? = nil) throws -> [DurableCommand] {
        let result = try rows("SELECT id,route,sequence,payload FROM commands" + (routeID == nil ? "" : " WHERE route=?") + " ORDER BY route,sequence", routeID.map { [$0] } ?? [])
        return try result.map { row in
            let command = try Self.decode(DurableCommand.self, row[3])
            guard command.id == string(row[0]), command.routeID == string(row[1]), command.sequence == Int64(string(row[2])) else {
                throw LocalPersistenceFailure.corrupt("Protected command identity or ordering mismatch.")
            }
            guard command.schemaVersion == 1 else { throw LocalPersistenceFailure.unsupportedSchema(command.schemaVersion) }
            guard command.accountID == ownerID else { throw LocalPersistenceFailure.ownership }
            guard command.payloadDigest == (try Self.commandDigest(command)) else { throw LocalPersistenceFailure.corrupt("Command checksum failed.") }
            return command
        }
    }
    func update(_ command: DurableCommand) throws { try transaction { try writeCommand(command) } }
    private func writeCommand(_ command: DurableCommand) throws {
        try execute("INSERT INTO commands(id,route,sequence,payload) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
            [Data(command.id.utf8), Data(command.routeID.utf8), Data(String(command.sequence).utf8), try Self.encode(command)])
    }
    /// Verified command transport history can compact; immutable domain outcomes stay in documents.
    /// Photo receipt references survive until the attachment is removed.
    func compact() throws {
        let retained = Set(try loadPhotos().compactMap(\.metadataCommandID))
        try transaction {
            for command in try commands() where command.state == .verified && !retained.contains(command.id) {
                try execute("DELETE FROM commands WHERE id=?", [command.id])
            }
        }
        try execute("PRAGMA wal_checkpoint(PASSIVE)")
    }
    func commitPhotoChange(_ record: DurablePhotoRecord, changes: [ChangeSet], synchronize: Bool) throws -> LocalCommitAck {
        try transaction {
            let acknowledgement = try commit(changes, synchronize: synchronize)
            var saved = record; saved.metadataCommandID = acknowledgement.commandIDs.last
            try savePhoto(saved)
            return acknowledgement
        }
    }
    func loadPhotos() throws -> [DurablePhotoRecord] {
        try rows("SELECT id,payload,digest FROM photos ORDER BY id").map {
            guard Self.digest($0[1]) == string($0[2]) else { throw LocalPersistenceFailure.corrupt("Photo queue checksum failed.") }
            let record = try Self.decode(DurablePhotoRecord.self, $0[1])
            guard record.item.id == string($0[0]) else { throw LocalPersistenceFailure.corrupt("Protected photo key mismatch.") }
            return record
        }
    }
    func savePhoto(_ record: DurablePhotoRecord) throws {
        let data = try Self.encode(record)
        try transaction { try execute("INSERT INTO photos(id,payload,digest) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,digest=excluded.digest",
            [Data(record.item.id.utf8), data, Data(Self.digest(data).utf8)]) }
    }
    func removePhoto(id: String) throws { try transaction { try execute("DELETE FROM photos WHERE id=?", [id]) } }

    /// Import retains source bytes; completion marker and imported commands are one transaction.
    func importLegacyJournal(_ entries: [SyncJournal.Entry], sourceKey: String) throws {
        guard try metadata("migration:\(sourceKey)") == nil else { return }
        try transaction {
            for entry in entries {
                let groups = Dictionary(grouping: entry.ops, by: \.routeID)
                for (routeID, ops) in groups.sorted(by: { $0.key < $1.key }) {
                    let sequence = Int64(try scalar("SELECT next_sequence FROM route_state WHERE route=?", [routeID]) ?? "1") ?? 1
                    var command = DurableCommand(id: entry.id + "_" + routeID, accountID: ownerID, routeID: routeID, sequence: sequence, createdAt: entry.createdAt,
                        label: entry.label, ops: ops.map(\.changeOp), baseRevision: -1, baseRouteCreatedAt: try snapshot(routeID)?.route.createdAt, payloadDigest: "", state: .blocked,
                        lastError: "Legacy pending work needs explicit reconciliation. Its historical revision coverage is unknown.")
                    command.payloadDigest = try Self.commandDigest(command); try writeCommand(command)
                    try execute("INSERT INTO route_state(route,next_sequence) VALUES(?,?) ON CONFLICT(route) DO UPDATE SET next_sequence=excluded.next_sequence", [routeID, String(sequence + 1)])
                }
            }
            try setMetadata("migration:\(sourceKey)", "complete")
        }
    }

    func hasLegacyPhotoMigration(sourceKey: String) throws -> Bool { try metadata("photo-migration:" + sourceKey) != nil }
    func importLegacyPhotos(_ records: [DurablePhotoRecord], sourceKey: String) throws {
        guard try !hasLegacyPhotoMigration(sourceKey: sourceKey) else { return }
        try transaction {
            let existing = Set(try loadPhotos().map { $0.item.id })
            for record in records where !existing.contains(record.item.id) { try savePhoto(record) }
            try setMetadata("photo-migration:" + sourceKey, "complete")
        }
    }

    func recoverLegacy(commandID: String, serverSnapshot: RouteSnapshot) throws -> LocalCommitAck {
        try transaction {
            guard var legacy = try commands().first(where: { $0.id == commandID }), legacy.baseRevision == -1,
                  legacy.routeID == serverSnapshot.route.id else { throw LocalPersistenceFailure.conflict("Saved legacy work has no safe route binding.") }
            let pending = try commands(routeID: legacy.routeID).filter { $0.state != .verified }
            guard pending.first?.id == commandID, pending.allSatisfy({ $0.baseRevision == -1 }) else {
                throw LocalPersistenceFailure.conflict("Recover saved changes in their original order, and synchronize the earlier change first.")
            }
            if let created = legacy.baseRouteCreatedAt, abs(created.timeIntervalSince(serverSnapshot.route.createdAt)) >= 0.000_002 {
                throw LocalPersistenceFailure.conflict("The legacy route was replaced. Saved intent has been preserved.")
            }
            guard serverSnapshot.route.isOpen else { throw LocalPersistenceFailure.conflict("The legacy route is closed. Reopen it before reconciling saved work.") }
            // A user-requested Retry establishes a *new* verified baseline, never fabricates a
            // historical one. Keep the same local ID/sequence so later legacy intent cannot overtake it.
            let others = pending.filter { $0.id != commandID }
            for var command in others { command.state = .verified; try writeCommand(command) }
            legacy.state = .verified; try writeCommand(legacy)
            try pin(serverSnapshot)
            legacy.ops.removeAll { if case .bumpRouteRevision = $0 { true } else { false } }
            legacy.ops.append(.bumpRouteRevision(legacy.routeID, expectedMinimum: serverSnapshot.route.inputRevision + 1))
            legacy.baseRevision = serverSnapshot.route.inputRevision
            legacy.baseRouteCreatedAt = serverSnapshot.route.createdAt
            legacy.baseRouteUpdatedAt = serverSnapshot.route.updatedAt
            legacy.baselines = try baselines(for: legacy.ops, routeID: legacy.routeID)
            legacy.state = .pending; legacy.lastError = nil
            legacy.payloadDigest = try Self.commandDigest(legacy)
            _ = try apply(legacy.ops, routeID: legacy.routeID, route: serverSnapshot.route)
            try writeCommand(legacy)
            for command in others { try writeCommand(command) }
            return LocalCommitAck(commandIDs: [legacy.id], syncPending: true)
        }
    }
    private func baselines(for ops: [ChangeOp], routeID: RouteID) throws -> [CommandDocumentBaseline] {
        try ops.compactMap { op in
            let kind: String; let id: String
            switch op {
            case let .putStop(_, value): kind = "stops"; id = value.id
            case let .deleteStop(_, value): kind = "stops"; id = value
            case let .putPackage(_, value): kind = "packages"; id = value.id
            case let .deletePackage(_, value): kind = "packages"; id = value
            case let .putTask(_, value): kind = "tasks"; id = value.id
            case let .deleteTask(_, value): kind = "tasks"; id = value
            default: return nil
            }
            let payload = try rows("SELECT payload FROM documents WHERE route=? AND kind=? AND id=?", [routeID, kind, id]).first?.first
            return CommandDocumentBaseline(documentKey: op.documentKey, payload: payload)
        }
    }
    func eraseOperationalData() throws {
        try transaction {
            try execute("DELETE FROM documents"); try execute("DELETE FROM commands"); try execute("DELETE FROM photos"); try execute("DELETE FROM route_state"); try execute("DELETE FROM execution")
            try execute("DELETE FROM meta WHERE key != 'owner'")
        }
    }

    private func put<T: Encodable>(_ value: T, route: String, kind: String, id: String) throws {
        let payload = try Self.encode(value)
        try execute("INSERT INTO documents(route,kind,id,payload,digest) VALUES(?,?,?,?,?) ON CONFLICT(route,kind,id) DO UPDATE SET payload=excluded.payload,digest=excluded.digest",
            [Data(route.utf8), Data(kind.utf8), Data(id.utf8), payload, Data(Self.digest(payload).utf8)])
    }
    private func document<T: Decodable>(route: String, kind: String, id: String) throws -> T? {
        guard let row = try rows("SELECT payload,digest FROM documents WHERE route=? AND kind=? AND id=?", [route, kind, id]).first else { return nil }
        guard Self.digest(row[0]) == string(row[1]) else { throw LocalPersistenceFailure.corrupt("Protected record checksum failed.") }
        return try Self.decode(T.self, row[0])
    }
    private func delete(_ route: String, _ kind: String, _ id: String) throws { try execute("DELETE FROM documents WHERE route=? AND kind=? AND id=?", [route, kind, id]) }
    private func metadata(_ key: String) throws -> String? { try scalar("SELECT value FROM meta WHERE key=?", [key]) }
    private func setMetadata(_ key: String, _ value: String) throws { try execute("INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, value]) }
    private func string(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }
    private func storageError() -> LocalPersistenceFailure {
        let code = sqlite3_errcode(db)
        if code == SQLITE_CORRUPT || code == SQLITE_NOTADB { return .corrupt("SQLite couldn't open the preserved store.") }
        return .storage(String(cString: sqlite3_errmsg(db)))
    }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try injectFailure?(.beforeTransaction)
        // Migration helpers may use this transaction; do not independently commit nested calls.
        let nested = sqlite3_get_autocommit(db) == 0
        if !nested { try execute("BEGIN IMMEDIATE") }
        do {
            let value = try body()
            if !nested { try injectFailure?(.beforeCommit); try execute("COMMIT") }
            return value
        } catch {
            if !nested { try? execute("ROLLBACK") }
            throw error
        }
    }
    private func prepare(_ sql: String, _ values: [Data]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw storageError() }
        for (index, value) in values.enumerated() {
            let result = value.withUnsafeBytes { bytes in sqlite3_bind_text(statement, Int32(index + 1), bytes.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(value.count), Self.transient) }
            guard result == SQLITE_OK else { sqlite3_finalize(statement); throw storageError() }
        }
        return statement
    }
    private func execute(_ sql: String, _ values: [String] = []) throws { try execute(sql, values.map { Data($0.utf8) }) }
    private func execute(_ sql: String, _ values: [Data]) throws {
        let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw storageError() }
    }
    private func rows(_ sql: String, _ values: [String] = []) throws -> [[Data]] {
        let statement = try prepare(sql, values.map { Data($0.utf8) }); defer { sqlite3_finalize(statement) }
        var result: [[Data]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW else { throw storageError() }
            result.append((0..<sqlite3_column_count(statement)).map { column in
                guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
                return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
            })
        }
    }
    private func scalar(_ sql: String, _ values: [String] = []) throws -> String? { try rows(sql, values).first?.first.map(string) }
}
