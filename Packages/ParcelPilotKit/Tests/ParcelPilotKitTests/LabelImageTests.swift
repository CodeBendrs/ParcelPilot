import CoreGraphics
import Foundation
import Testing
@testable import ParcelPilotKit

/// End-to-end OCR tests on synthetic label images (Vision runs on the Mac host). These cover the
/// recognition → recipient selection → parsing path; camera capture itself needs a real iPhone
/// (see docs/DEVICE_TEST_CHECKLIST.md).
@Suite("Label images (Vision OCR)", .serialized)
struct LabelImageTests {
    let pipeline = LabelImagePipeline()

    init() {
        // The first Vision request in a process loads the model (very slow on some Macs); do it once.
        VisionLabelReader.warmUpOnce
    }

    func run(_ name: String) throws -> LabelImagePipeline.Result {
        try pipeline.process(try Fixtures.labelImage(name))
    }

    @Test("E1: SHIP TO block chosen over Toronto return address; unit 204 kept")
    func e1() throws {
        let result = try run("e1_victoria_unit204")
        let candidate = try #require(result.analysis.selectedCandidate, "selection: \(result.analysis.selection)")
        #expect(candidate.role == .recipient)
        let a = candidate.address
        #expect(a.unit == "204")
        #expect(a.civicNumber == "123")
        #expect(a.streetName?.uppercased() == "EXAMPLE ST")
        #expect(a.municipality?.uppercased() == "VICTORIA")
        #expect(a.province == .BC)
        #expect(a.postalCode == "V8W 1A1")
        #expect(a.recipientName?.uppercased() == "ALEX TEST")
        #expect(result.analysis.trackingIDs.contains("1Z999AA10123456784"))
        // The return address was found but not chosen.
        #expect(result.analysis.candidates.contains { $0.role == .sender && $0.address.municipality?.uppercased() == "TORONTO" })
    }

    @Test("E1 variant: unlabelled return address is not offered as the destination")
    func e1Unlabelled() throws {
        let result = try run("e1_unlabelled_return")
        let candidate = try #require(result.analysis.selectedCandidate)
        #expect(candidate.role == .recipient)
        #expect(candidate.address.unit == "204")
        #expect(candidate.address.postalCode == "V8W 1A1")
    }

    @Test("E2: French DESTINATAIRE label keeps accents and APP. 12")
    func e2() throws {
        let result = try run("e2_french_destinataire")
        let candidate = try #require(result.analysis.selectedCandidate, "selection: \(result.analysis.selection)")
        #expect(candidate.role == .recipient)
        let a = candidate.address
        #expect(a.unit == "12")
        #expect(a.unitDesignator == "App.")
        #expect(a.civicNumber == "1234")
        #expect(a.streetName == "rue Sainte-Catherine Ouest")
        #expect(a.municipality == "Montréal")
        #expect(a.province == .QC)
        #expect(a.postalCode == "H3G 1P1")
        #expect(result.analysis.candidates.contains { $0.role == .sender })
    }

    @Test("E3: second label for the same destination and a different unit")
    func e3() throws {
        let first = try run("e1_victoria_unit204").analysis
        let second = try run("e3_same_destination_second_package").analysis
        let otherUnit = try run("e3_other_unit").analysis
        let a1 = try #require(first.selectedCandidate).address
        let a2 = try #require(second.selectedCandidate).address
        let a3 = try #require(otherUnit.selectedCandidate).address
        #expect(DestinationKey.make(a1) == DestinationKey.make(a2))
        #expect(DestinationKey.make(a1) != DestinationKey.make(a3))
        #expect(first.trackingIDs != second.trackingIDs)
        #expect(first.fingerprint != second.fingerprint)
    }

    @Test("E4: obscured street number with readable postal code stays unresolved")
    func e4Obscured() throws {
        let result = try run("e4_obscured_civic")
        let candidate = try #require(result.analysis.selectedCandidate)
        #expect(candidate.address.civicNumber == nil)
        #expect(candidate.address.postalCode == "V8W 1A1")
        let decision = ReviewPolicy.evaluate(parsed: candidate.parsed, recognition: candidate.recognition, uncertainFields: candidate.uncertainFields, roleCertain: true, resolution: .offline)
        #expect(!decision.autoAcceptable)
        #expect(decision.reasons.contains(.missingCivicNumber))
    }

    @Test("E4: tracking-only barcode produces a package ID but no address")
    func e4TrackingOnly() throws {
        let result = try run("e4_tracking_only")
        #expect(result.analysis.trackingIDs == ["1Z999AA10123456817"])
        #expect(result.analysis.selectedCandidate == nil)
        #expect(result.analysis.barcodeAddress == nil)
        if case .none = result.analysis.selection {} else { Issue.record("expected no address, got \(result.analysis.selection)") }
    }

    @Test("Two unlabelled addresses require a choice")
    func ambiguous() throws {
        let result = try run("ambiguous_two_addresses")
        guard case let .choice(ids) = result.analysis.selection else {
            Issue.record("expected choice, got \(result.analysis.selection)"); return
        }
        #expect(ids.count == 2)
    }

    @Test("Side-by-side FROM/TO columns pick the TO column")
    func columns() throws {
        let result = try run("columns_from_to")
        let candidate = try #require(result.analysis.selectedCandidate, "selection: \(result.analysis.selection)")
        #expect(candidate.role == .recipient)
        #expect(candidate.address.municipality?.uppercased() == "VICTORIA")
        #expect(candidate.address.unit == "204")
    }

    @Test("QR vCard with an explicit address is used as an address payload")
    func qrVCard() throws {
        let result = try run("qr_vcard_address")
        let address = try #require(result.analysis.barcodeAddress)
        #expect(address.civicNumber == "123")
        #expect(address.unit == "204")
        #expect(address.postalCode == "V8W 1A1")
    }

    @Test("Rural route is flagged for review")
    func ruralRoute() throws {
        let result = try run("rural_route")
        let candidate = try #require(result.analysis.selectedCandidate)
        #expect(candidate.completeness.nonCivic == .ruralRoute)
        let decision = ReviewPolicy.evaluate(parsed: candidate.parsed, recognition: candidate.recognition, resolution: .offline)
        #expect(decision.reasons.contains(.ruralRoute))
    }

    @Test("Rotated label is read by trying other orientations")
    func rotated() throws {
        let result = try run("quality_rotated")
        let candidate = try #require(result.analysis.selectedCandidate, "selection: \(result.analysis.selection)")
        #expect(candidate.address.unit == "204")
        #expect(result.orientationUsed != .up)
    }

    @Test("Blurred label is reported as blurry and never auto-accepted with missing fields")
    func blurred() throws {
        let result = try run("quality_blurred")
        #expect(result.quality.isBlurry)
        if let candidate = result.analysis.selectedCandidate {
            let decision = ReviewPolicy.evaluate(parsed: candidate.parsed, recognition: candidate.recognition, uncertainFields: candidate.uncertainFields, resolution: .offline)
            #expect(!decision.autoAcceptable)
        }
    }

    @Test("Glare is detected")
    func glare() throws {
        let result = try run("quality_glare")
        #expect(result.quality.hasGlare)
        let sharp = try run("e1_victoria_unit204")
        #expect(!sharp.quality.hasGlare)
        #expect(!sharp.quality.isBlurry)
    }

    @Test("Incomplete label (cut off): the partial SHIP TO block is reported, nothing is invented")
    func incomplete() throws {
        let result = try run("quality_incomplete")
        let candidate = try #require(result.analysis.selectedCandidate, "selection: \(result.analysis.selection)")
        #expect(candidate.role == .recipient)
        #expect(candidate.address.unit == "204")
        #expect(candidate.address.postalCode == nil)
        #expect(candidate.address.municipality == nil)
        #expect(!candidate.completeness.isComplete)
        let decision = ReviewPolicy.evaluate(parsed: candidate.parsed, recognition: candidate.recognition, uncertainFields: candidate.uncertainFields, resolution: .offline)
        #expect(!decision.autoAcceptable)
        #expect(decision.reasons.contains(.missingPostalCode))
    }
}
