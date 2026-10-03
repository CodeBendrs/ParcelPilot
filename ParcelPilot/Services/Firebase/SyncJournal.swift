import Foundation
import Observation
import ParcelPilotKit

/// Durable record of outcome-critical writes (delivery outcomes, undo, scanned stops).
///
/// Firestore's persistent cache already keeps pending writes across app termination and replays them;
/// this journal exists so that a write the server *rejects* (or one whose acknowledgement was lost when
/// the app was killed) is surfaced to the driver with Retry / Discard instead of silently reverting.
/// Retrying is safe: every document has a client-generated stable ID and outcomes are create-once.
@MainActor
@Observable
final class SyncJournal {
    struct Entry: Codable, Identifiable, Hashable {
        enum State: String, Codable { case pending, failed }
        var id: String
        var label: String
        var createdAt: Date
        var state: State
        var lastError: String?
        /// Encoded operations so the change can be retried exactly.
        var ops: [JournalOp]
    }

    private(set) var entries: [Entry] = []
    private let fileURL: URL

    init(fileURL: URL = SyncJournal.defaultURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder.appStorage.decode([Entry].self, from: data) {
            entries = decoded
        }
    }

    static var defaultURL: URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("sync-journal.json")
    }

    var failed: [Entry] { entries.filter { $0.state == .failed } }
    var pending: [Entry] { entries.filter { $0.state == .pending } }

    func begin(_ change: ChangeSet) -> String {
        let entry = Entry(id: StableID.make(), label: change.label, createdAt: Date(), state: .pending, lastError: nil, ops: change.ops.compactMap(JournalOp.init))
        entries.append(entry)
        save()
        return entry.id
    }

    func succeeded(_ id: String) {
        entries.removeAll { $0.id == id }
        save()
    }

    func failed(_ id: String, message: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].state = .failed
        entries[i].lastError = message
        save()
    }

    func discard(_ id: String) { succeeded(id) }

    /// Records a rejected change that has no retryable payload (shown with Discard only).
    func reportRejected(label: String, message: String) {
        entries.append(Entry(id: StableID.make(), label: label, createdAt: Date(), state: .failed, lastError: message, ops: []))
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        try? JSONEncoder.appStorage.encode(entries).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Codable mirror of the journaled subset of `ChangeOp`.
enum JournalOp: Codable, Hashable {
    case putStop(RouteID, Stop)
    case putPackage(RouteID, Package)
    case deleteStop(RouteID, StopID)
    case deletePackage(RouteID, PackageID)
    case createOutcome(RouteID, DeliveryOutcome)
    case voidOutcome(RouteID, OutcomeID, Date)

    init?(_ op: ChangeOp) {
        switch op {
        case let .putStop(r, s): self = .putStop(r, s)
        case let .putPackage(r, p): self = .putPackage(r, p)
        case let .deleteStop(r, s): self = .deleteStop(r, s)
        case let .deletePackage(r, p): self = .deletePackage(r, p)
        case let .createOutcome(r, o): self = .createOutcome(r, o)
        case let .voidOutcome(r, o, at): self = .voidOutcome(r, o, at)
        case .createRoute, .updateRoute, .putPhoto, .deletePhoto: return nil
        }
    }

    var changeOp: ChangeOp {
        switch self {
        case let .putStop(r, s): return .putStop(r, s)
        case let .putPackage(r, p): return .putPackage(r, p)
        case let .deleteStop(r, s): return .deleteStop(r, s)
        case let .deletePackage(r, p): return .deletePackage(r, p)
        case let .createOutcome(r, o): return .createOutcome(r, o)
        case let .voidOutcome(r, o, at): return .voidOutcome(r, o, at: at)
        }
    }
}
