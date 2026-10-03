import CoreGraphics
import ImageIO
import Observation
import ParcelPilotKit
import UIKit

/// Label intake pipeline:
/// capture → on-device OCR (Vision) → recipient extraction → Canadian parsing → duplicate checks →
/// online verification (when available) → confirmation card (normal) or auto-add / review queue (batch).
/// Label images and OCR text exist only in memory while a capture is processed.
@MainActor
@Observable
final class ScanModel {
    enum Phase: Equatable {
        case idle
        case reading
        case checking
    }

    private(set) var phase: Phase = .idle
    var batchMode: Bool
    private(set) var hints: [String] = []
    private(set) var statusMessage: String?
    var confirmation: CandidateBox?
    private(set) var addedThisSession = 0
    private var dedupe = ScanDeduplicator(cooldown: 4)
    private let services: AppServices
    private let toasts: ToastCenter

    init(services: AppServices, toasts: ToastCenter) {
        self.services = services
        self.toasts = toasts
        self.batchMode = services.settings.settings.batchScanDefault
    }

    var isBusy: Bool { phase != .idle || confirmation != nil }

    /// - Parameter automatic: true for batch auto-capture (repeated frames are ignored silently).
    func process(image: CGImage, orientation: CGImagePropertyOrientation, automatic: Bool) async {
        guard phase == .idle, confirmation == nil else { return }
        guard let snapshot = services.store.current else {
            statusMessage = "Open or create a route first."
            return
        }
        phase = .reading
        statusMessage = "Reading label…"
        defer { if phase != .idle { phase = .idle } }

        let result: LabelImagePipeline.Result
        do {
            result = try await Task.detached(priority: .userInitiated) {
                try LabelImagePipeline().process(image, orientation: orientation)
            }.value
        } catch {
            statusMessage = "The label couldn't be read. Try again, or type the address."
            Haptics.error()
            return
        }
        hints = result.quality.hints
        let analysis = result.analysis

        let verdict = dedupe.check(fingerprint: analysis.fingerprint, at: Date())
        if verdict == .ignoreRepeatedFrame && automatic { phase = .idle; statusMessage = nil; return }

        // Same tracking number already on this route → one package only, with feedback (E3).
        let index = RouteIntakeIndex(stops: snapshot.stops, packages: snapshot.packages)
        for id in analysis.trackingIDs {
            if case let .duplicateTracking(_, stopID) = index.placement(for: PostalAddress(), trackingID: id) {
                let n = (snapshot.orderedStops.firstIndex { $0.id == stopID } ?? 0) + 1
                Haptics.warning()
                toasts.show("Already scanned — tracking …\(id.suffix(6)) is on stop \(n)", symbol: "exclamationmark.2", tone: .warning)
                statusMessage = nil
                dedupe.markProcessed(analysis.fingerprint)
                return
            }
        }

        guard var candidate = IntakeCandidate.fromAnalysis(analysis, routeID: snapshot.route.id) else {
            Haptics.warning()
            if let tracking = analysis.trackingIDs.first {
                statusMessage = "Read tracking …\(tracking.suffix(6)), but no delivery address. Tracking barcodes don't contain the address — scan the SHIP TO block or type it."
            } else if case let .none(reason) = analysis.selection {
                statusMessage = reason
            }
            return
        }

        phase = .checking
        statusMessage = "Checking address…"
        if candidate.alternatives.isEmpty {
            candidate.verification = await services.verifier.verify(candidate.address)
        }
        phase = .idle
        statusMessage = nil
        dedupe.markProcessed(analysis.fingerprint)

        if batchMode {
            handleBatch(candidate, seenBefore: verdict == .seenEarlierThisSession)
        } else {
            confirmation = CandidateBox(candidate: candidate)
        }
    }

    private func handleBatch(_ candidate: IntakeCandidate, seenBefore: Bool) {
        guard let snapshot = services.store.current else { return }
        let decision = candidate.decision(allowSynthetic: services.verifier.allowsSynthetic)
        let possibleDuplicate = seenBefore && candidate.trackingIDs.isEmpty
        if decision.autoAcceptable && !possibleDuplicate {
            let (status, resolution, reasons) = candidate.confirmedStop(verifier: services.verifier)
            let result = services.store.addDelivery(to: snapshot, address: candidate.address, status: status, resolution: resolution, reviewReasons: reasons, packages: [candidate.package], source: .scan)
            addedThisSession += 1
            Haptics.success()
            let where_ = result.placement == .newStop ? "new stop" : "existing stop"
            toasts.show("Added \(candidate.address.streetLine ?? "stop")\(candidate.address.unitLabel.map { ", \($0)" } ?? "") · \(where_)", symbol: "checkmark.circle.fill", tone: .success, undo: { [services] in
                if let current = services.store.current { services.store.undoAdd(result, in: current) }
            })
        } else {
            var draft = candidate.asDraft(allowSynthetic: services.verifier.allowsSynthetic)
            if possibleDuplicate, !draft.reasons.contains(.possibleDuplicate) { draft.reasons.append(.possibleDuplicate) }
            services.drafts.upsert(draft)
            Haptics.warning()
            let reason = draft.reasons.first?.explanation ?? "Needs review."
            toasts.show("Sent to review: \(reason)", symbol: "tray.and.arrow.down.fill", tone: .warning, seconds: 4)
        }
    }

    func clearStatus() { statusMessage = nil; hints = [] }

    func confirmationFinished(_ outcome: AddressConfirmationView.Outcome) {
        switch outcome {
        case let .added(message):
            addedThisSession += 1
            toasts.show(message, symbol: "checkmark.circle.fill", tone: .success)
        case .savedForReview:
            toasts.show("Saved to the review queue", symbol: "tray.and.arrow.down", tone: .neutral)
        case .discarded, .cancelled:
            break
        }
    }
}

extension CGImagePropertyOrientation {
    init(_ ui: UIImage.Orientation) {
        switch ui {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
