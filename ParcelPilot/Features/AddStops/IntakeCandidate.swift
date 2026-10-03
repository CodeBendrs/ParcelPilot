import Foundation
import ParcelPilotKit

/// An address being confirmed, from a label scan, a manual search or the review queue.
struct IntakeCandidate: Sendable {
    var routeID: RouteID
    var source: PackageSource
    /// What was read from the label (nil for typed addresses).
    var fromLabel: DraftCandidate?
    /// Other destinations found on the same label (when a choice is needed).
    var alternatives: [DraftCandidate] = []
    var recognition: RecognitionLevel?
    var uncertainFields: [AddressField] = []
    var roleCertain: Bool = true
    var trackingIDs: [String] = []
    var barcodePostalCode: String?
    var address: PostalAddress
    var verification: AddressVerifier.Result?
    var draftID: String?
    var package = PackageDraft()
    var driverPin: GeoPoint?
    /// Set once the driver edits a field; their typed text then replaces the OCR reading.
    var driverEdited = false

    var parsed: ParsedAddress { ParsedAddress(validating: address) }

    func decision(allowSynthetic: Bool) -> ReviewDecision {
        let resolution: ResolutionState
        if let driverPin {
            resolution = .resolved(MatchAssessment(quality: .driverPin, differences: [], candidate: GeocodeCandidate(placeID: nil, formattedAddress: "Pinned location", location: driverPin, granularity: .rooftop, types: [], provider: .google)))
        } else {
            resolution = verification?.resolution ?? .offline
        }
        var parsedIssues = parsed
        if !driverEdited, let label = fromLabel {
            // Keep label-specific findings (e.g. an uncertain postal code) until the driver edits.
            parsedIssues.issues.append(contentsOf: label.issues.filter { if case .uncertainPostalCode = $0 { return true }; if case .multipleUnitCandidates = $0 { return true }; return false })
        }
        return ReviewPolicy.evaluate(
            parsed: parsedIssues,
            recognition: driverEdited ? nil : recognition,
            uncertainFields: driverEdited ? [] : uncertainFields,
            roleCertain: driverEdited ? true : roleCertain,
            multipleDestinations: !alternatives.isEmpty && !driverEdited,
            barcodePostalCode: barcodePostalCode,
            resolution: resolution,
            allowSyntheticAcceptance: allowSynthetic
        )
    }

    /// The status and resolution the stop gets when it is added. `driverReviewed` is true when the
    /// driver looked at this address's verification result and tapped Add; bulk import passes false so
    /// anything that is not auto-acceptable lands in the review queue instead of being confirmed.
    func confirmedStop(verifier: AddressVerifier, driverReviewed: Bool = true) -> (AddressStatus, StopResolution?, [ReviewReason]) {
        let decision = decision(allowSynthetic: verifier.allowsSynthetic)
        if let driverPin {
            return (.driverConfirmed, StopResolution(provider: nil, placeID: verification?.assessment?.candidate?.placeID, located: LocatedPoint(point: driverPin, source: .driverPin), match: .driverPin, resolvedAt: Date()), decision.reasons)
        }
        guard let assessment = verification?.assessment else {
            return (.pendingVerification, nil, decision.reasons)
        }
        let resolution = verifier.stopResolution(for: assessment, response: verification?.response)
        if decision.autoAcceptable { return (decision.statusIfAdded, resolution, []) }
        if !driverReviewed { return (decision.statusIfAdded, resolution, decision.reasons) }
        let status = ConfirmationPolicy.statusAfterDriverConfirmation(match: assessment.quality, hasDriverPin: false, demoMode: verifier.allowsSynthetic)
        return (status, resolution, decision.reasons)
    }

    static func fromAnalysis(_ analysis: LabelAnalysis, routeID: RouteID) -> IntakeCandidate? {
        func draft(_ c: AddressCandidate) -> DraftCandidate {
            DraftCandidate(address: c.address, rawLines: c.rawLines, role: c.role, roleEvidence: c.roleEvidence, issues: c.parsed.issues)
        }
        switch analysis.selection {
        case let .single(id):
            guard let c = analysis.candidates.first(where: { $0.id == id }) else { return nil }
            return IntakeCandidate(routeID: routeID, source: .scan, fromLabel: draft(c), recognition: c.recognition, uncertainFields: c.uncertainFields, roleCertain: c.role == .recipient, trackingIDs: analysis.trackingIDs, barcodePostalCode: analysis.barcodePostalCode, address: c.address, package: PackageDraft(trackingID: analysis.trackingIDs.first, recipientName: c.address.recipientName))
        case let .choice(ids):
            let candidates = analysis.candidates.filter { ids.contains($0.id) }
            guard let first = candidates.first else { return nil }
            return IntakeCandidate(routeID: routeID, source: .scan, fromLabel: draft(first), alternatives: candidates.map(draft), recognition: first.recognition, uncertainFields: first.uncertainFields, roleCertain: false, trackingIDs: analysis.trackingIDs, barcodePostalCode: analysis.barcodePostalCode, address: first.address, package: PackageDraft(trackingID: analysis.trackingIDs.first, recipientName: first.address.recipientName))
        case .none:
            guard let address = analysis.barcodeAddress else { return nil }
            return IntakeCandidate(routeID: routeID, source: .scan, fromLabel: DraftCandidate(address: address, rawLines: ["From barcode"], role: .recipient, roleEvidence: "Address encoded in the barcode", issues: []), recognition: .high, trackingIDs: analysis.trackingIDs, address: address, package: PackageDraft(trackingID: analysis.trackingIDs.first, recipientName: address.recipientName))
        }
    }

    static func fromDraft(_ d: ScanDraft) -> IntakeCandidate {
        let selected = d.selected ?? d.candidates.first
        var c = IntakeCandidate(routeID: d.routeID, source: .scan, fromLabel: selected, alternatives: d.state == .needsChoice ? d.candidates : [], recognition: d.recognition, uncertainFields: d.uncertainFields, roleCertain: selected?.role == .recipient, trackingIDs: d.trackingIDs, barcodePostalCode: d.barcodePostalCode, address: selected?.address ?? PostalAddress(), draftID: d.id, package: d.package)
        if let resolved = d.resolved, let match = d.match, (d.resolvedExpiresAt ?? .distantPast) > Date() {
            let assessment = MatchAssessment(quality: match, differences: d.differences, candidate: resolved)
            c.verification = AddressVerifier.Result(response: ResolveResponse(candidates: [resolved], provider: resolved.provider, resolvedAt: d.createdAt, coordinatesExpireAt: d.resolvedExpiresAt ?? Date()), assessment: assessment, resolution: .resolved(assessment), error: nil)
        }
        return c
    }

    func asDraft(id: String = StableID.make(), now: Date = Date(), allowSynthetic: Bool) -> ScanDraft {
        let decision = decision(allowSynthetic: allowSynthetic)
        let state: ScanDraft.State = !alternatives.isEmpty ? .needsChoice : (verification == nil || verification?.assessment == nil) ? .needsVerification : .needsReview
        var candidates = alternatives.isEmpty ? [fromLabel ?? DraftCandidate(address: address, rawLines: [], role: .unknown, roleEvidence: nil, issues: [])] : alternatives
        if alternatives.isEmpty { candidates[0].address = address }
        return ScanDraft(id: draftID ?? id, routeID: routeID, createdAt: now, candidates: candidates, selectedIndex: alternatives.isEmpty ? 0 : nil, trackingIDs: trackingIDs, recognition: recognition, uncertainFields: uncertainFields, reasons: decision.reasons, state: state, barcodePostalCode: barcodePostalCode, resolved: verification?.assessment?.candidate, resolvedExpiresAt: verification?.response?.coordinatesExpireAt, match: verification?.assessment?.quality, differences: verification?.assessment?.differences ?? [], package: package)
    }
}
