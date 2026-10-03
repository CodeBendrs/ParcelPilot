import Foundation
import Observation
import ParcelPilotKit

/// One candidate address from a scanned label, as kept in a draft.
struct DraftCandidate: Codable, Hashable, Sendable {
    var address: PostalAddress
    /// The recipient block's recognised lines (not the whole label) so the driver can compare.
    var rawLines: [String]
    var role: AddressRole
    var roleEvidence: String?
    var issues: [AddressIssue]
}

/// A scanned label that has not been confirmed yet (review queue). Owned by `DraftStore` until the
/// driver confirms it — then it becomes a Stop/Package write and the draft is deleted. Label images
/// and full OCR text are never stored.
struct ScanDraft: Codable, Hashable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        /// Scanned offline (or the resolver was unavailable): "Needs address verification".
        case needsVerification
        /// Resolution ran, but the driver must review (partial match, low confidence…).
        case needsReview
        /// Several destinations on the label — the driver must choose.
        case needsChoice
    }

    var id: String
    var routeID: RouteID
    var createdAt: Date
    var candidates: [DraftCandidate]
    var selectedIndex: Int?
    var trackingIDs: [String]
    var recognition: RecognitionLevel?
    var uncertainFields: [AddressField]
    var reasons: [ReviewReason]
    var state: State
    var barcodePostalCode: String?
    /// Best resolver candidate (provider content — expires with `resolvedExpiresAt`).
    var resolved: GeocodeCandidate?
    var resolvedExpiresAt: Date?
    var match: MatchQuality?
    var differences: [MatchDifference]
    var package: PackageDraft

    var selected: DraftCandidate? { selectedIndex.flatMap { candidates.indices.contains($0) ? candidates[$0] : nil } }
}

@MainActor
@Observable
final class DraftStore {
    private(set) var drafts: [ScanDraft] = []
    private let fileURL: URL

    init(fileURL: URL = DraftStore.defaultURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder.appStorage.decode([ScanDraft].self, from: data) {
            drafts = decoded
        }
    }

    static var defaultURL: URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("scan-drafts.json")
    }

    func drafts(for routeID: RouteID) -> [ScanDraft] {
        drafts.filter { $0.routeID == routeID }.sorted { $0.createdAt < $1.createdAt }
    }

    func upsert(_ draft: ScanDraft) {
        if let i = drafts.firstIndex(where: { $0.id == draft.id }) { drafts[i] = draft } else { drafts.append(draft) }
        save()
    }

    func remove(_ id: String) {
        drafts.removeAll { $0.id == id }
        save()
    }

    func removeAll() {
        drafts = []
        save()
    }

    private func save() {
        do {
            try JSONEncoder.appStorage.encode(drafts).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            AppLog.storage.error("Draft save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

