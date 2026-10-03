import Foundation
import Testing
@testable import ParcelPilotKit

@Suite("Postal codes")
struct PostalCodeTests {
    @Test func normalizesValidCodes() {
        #expect(CanadianPostalCode("v8w1a1")?.value == "V8W 1A1")
        #expect(CanadianPostalCode("V8W-1A1")?.value == "V8W 1A1")
        #expect(CanadianPostalCode(" h3g 1p1 ")?.value == "H3G 1P1")
    }

    @Test func rejectsInvalidLettersAndShapes() {
        #expect(CanadianPostalCode("D8W 1A1") == nil) // D never first
        #expect(CanadianPostalCode("V8W 1O1") == nil) // O not allowed
        #expect(CanadianPostalCode("W8W 1A1") == nil) // W never first
        #expect(CanadianPostalCode("V8W1A") == nil)
        #expect(CanadianPostalCode("12345") == nil)
    }

    @Test func uncertainCharactersAreSuggestedNeverApplied() {
        let reading = PostalCodeScanner.read(in: "VICTORIA BC V8W 1AI")
        guard case let .uncertain(raw, suggestion) = reading else { Issue.record("expected uncertain, got \(String(describing: reading))"); return }
        #expect(raw == "V8W 1AI")
        #expect(suggestion.value == "V8W 1A1")
        let parsed = CanadianAddressParser.parse(lines: ["123 EXAMPLE ST", "VICTORIA BC V8W 1AI"])
        #expect(parsed.address.postalCode == "V8W 1AI") // kept as read
        #expect(parsed.issues.contains(.uncertainPostalCode(raw: "V8W 1AI", suggestion: "V8W 1A1")))
    }

    @Test func provinceConsistency() {
        let parsed = CanadianAddressParser.parse(lines: ["123 EXAMPLE ST", "VICTORIA ON V8W 1A1"])
        #expect(parsed.issues.contains(.postalProvinceConflict(postalCode: "V8W 1A1", province: .ON)))
        #expect(CanadianPostalCode("H3G 1P1")!.provinces == [.QC])
        #expect(CanadianPostalCode("X0A 0H0")!.provinces.contains(.NU))
        #expect(CanadianPostalCode("E0A 1A0")!.isRuralFSA)
        #expect(!CanadianPostalCode("E4B 0A1")!.isRuralFSA)
    }
}

@Suite("Canadian address parser")
struct AddressParserTests {
    @Test("E1 single line form keeps unit 204 distinct from civic 123")
    func e1SingleLine() {
        let p = CanadianAddressParser.parse(singleLine: "ALEX TEST, UNIT 204, 123 EXAMPLE ST, VICTORIA BC V8W 1A1")
        #expect(p.address.recipientName == "ALEX TEST")
        #expect(p.address.unit == "204")
        #expect(p.address.unitDesignator == "Unit")
        #expect(p.address.civicNumber == "123")
        #expect(p.address.streetName == "EXAMPLE ST")
        #expect(p.address.municipality == "VICTORIA")
        #expect(p.address.province == .BC)
        #expect(p.address.postalCode == "V8W 1A1")
        #expect(p.issues.isEmpty, "\(p.issues)")
    }

    @Test("E2 French layout with accents and APP. 12")
    func e2French() {
        let p = CanadianAddressParser.parse(lines: ["CAMILLE TEST", "APP. 12", "1234, rue Sainte-Catherine Ouest", "Montréal (Québec) H3G 1P1"])
        #expect(p.address.unit == "12")
        #expect(p.address.unitDesignator == "App.")
        #expect(p.address.civicNumber == "1234")
        #expect(p.address.streetName == "rue Sainte-Catherine Ouest")
        #expect(p.address.municipality == "Montréal")
        #expect(p.address.province == .QC)
        #expect(p.address.postalCode == "H3G 1P1")
        #expect(p.issues.isEmpty, "\(p.issues)")
    }

    @Test("Hyphenated unit-civic form 204-123")
    func hyphenated() {
        let p = CanadianAddressParser.parse(lines: ["204-123 EXAMPLE ST", "VICTORIA BC V8W 1A1"])
        #expect(p.address.unit == "204")
        #expect(p.address.civicNumber == "123")
    }

    @Test("Trailing unit forms")
    func trailingUnits() {
        let a = CanadianAddressParser.parse(singleLine: "123 Example St Apt 5, Halifax NS B3H 1A1")
        #expect(a.address.unit == "5"); #expect(a.address.civicNumber == "123"); #expect(a.address.streetName == "Example St")
        let b = CanadianAddressParser.parse(singleLine: "500 Placeholder Ave #1204, Calgary AB T2P 1J9")
        #expect(b.address.unit == "1204"); #expect(b.address.unitDesignator == "#")
        let c = CanadianAddressParser.parse(singleLine: "77 Mock Rd Suite 300, Winnipeg MB R3C 0A1")
        #expect(c.address.unit == "300"); #expect(c.address.unitDesignator == "Suite")
    }

    @Test("Street names containing designator-like words are not split")
    func noFalseUnits() {
        let p = CanadianAddressParser.parse(singleLine: "1234 rue Sainte-Catherine Ouest, Montréal QC H3G 1P1")
        #expect(p.address.unit == nil)
        #expect(p.address.streetName == "rue Sainte-Catherine Ouest")
    }

    @Test("Municipality and province on separate lines from postal code")
    func splitLocality() {
        let p = CanadianAddressParser.parse(lines: ["123 EXAMPLE ST", "VICTORIA BC", "V8W 1A1"])
        #expect(p.address.municipality == "VICTORIA")
        #expect(p.address.province == .BC)
        #expect(p.address.postalCode == "V8W 1A1")
        let q = CanadianAddressParser.parse(singleLine: "123 Example St, Victoria, BC, V8W 1A1")
        #expect(q.address.municipality == "Victoria")
        #expect(q.address.province == .BC)
    }

    @Test("Multi-word province names")
    func longProvince() {
        let p = CanadianAddressParser.parse(lines: ["9 MOCK CRES", "HALIFAX NOVA SCOTIA B3H 1A1"])
        #expect(p.address.province == .NS)
        #expect(p.address.municipality == "HALIFAX")
    }

    @Test("PO box and general delivery are flagged, not treated as civic addresses")
    func nonCivic() {
        let p = CanadianAddressParser.parse(lines: ["ALEX TEST", "PO BOX 123", "VICTORIA BC V8W 1A1"])
        #expect(p.issues.contains(.poBox))
        #expect(p.address.deliveryInstallation == "PO BOX 123")
        #expect(p.address.civicNumber == nil)
        #expect(!p.issues.contains(.missingCivicNumber))
        let g = CanadianAddressParser.parse(lines: ["GD", "SAMPLEVILLE NB E4B 0A1"])
        #expect(g.issues.contains(.generalDelivery))
        let f = CanadianAddressParser.parse(lines: ["C.P. 45", "Québec QC G1R 4P5"])
        #expect(f.issues.contains(.poBox))
    }

    @Test("Missing civic number is reported, nothing invented")
    func missingCivic() {
        let p = CanadianAddressParser.parse(lines: ["ALEX TEST", "EXAMPLE ST", "VICTORIA BC V8W 1A1"])
        #expect(p.address.civicNumber == nil)
        #expect(p.address.streetName == "EXAMPLE ST")
        #expect(p.issues.contains(.missingCivicNumber))
    }

    @Test("OCR-confused civic number is flagged as uncertain")
    func confusedCivic() {
        let p = CanadianAddressParser.parse(lines: ["l23 EXAMPLE ST", "VICTORIA BC V8W 1A1"])
        #expect(p.address.civicNumber == nil)
        #expect(p.issues.contains(.uncertainCivicNumber(raw: "l23")))
    }

    @Test("Two different units need a choice")
    func twoUnits() {
        let p = CanadianAddressParser.parse(lines: ["UNIT 5", "123 EXAMPLE ST APT 7", "VICTORIA BC V8W 1A1"])
        #expect(p.issues.contains { if case .multipleUnitCandidates = $0 { return true }; return false })
    }

    @Test("Phone numbers are not parsed as addresses")
    func phoneLine() {
        let p = CanadianAddressParser.parse(lines: ["ALEX TEST", "123 EXAMPLE ST", "VICTORIA BC V8W 1A1", "TEL 250-555-0100"])
        #expect(p.address.civicNumber == "123")
        #expect(p.address.additionalLines == ["TEL 250-555-0100"])
    }

    @Test("Non-Canadian country is rejected")
    func country() {
        let p = CanadianAddressParser.parse(lines: ["1 TEST WAY", "SEATTLE WA 98101", "USA"])
        #expect(p.issues.contains(.nonCanadianCountry("USA")))
    }

    @Test("Destination keys: same destination equal, different unit different, formatting ignored")
    func destinationKeys() {
        let a = CanadianAddressParser.parse(singleLine: "Unit 204, 123 Example Street, Victoria BC V8W1A1").address
        let b = CanadianAddressParser.parse(singleLine: "204-123 EXAMPLE ST, VICTORIA, BC V8W 1A1").address
        let c = CanadianAddressParser.parse(singleLine: "Unit 305, 123 Example St, Victoria BC V8W 1A1").address
        #expect(DestinationKey.make(a) == DestinationKey.make(b))
        #expect(DestinationKey.make(a) != DestinationKey.make(c))
        #expect(DestinationKey.buildingKey(a) == DestinationKey.buildingKey(c))
    }

    @Test("Province lookup covers French names and abbreviations")
    func provinces() {
        #expect(Province.match("Québec") == .QC)
        #expect(Province.match("Colombie-Britannique") == .BC)
        #expect(Province.match("B.C.") == .BC)
        #expect(Province.match("T.N.-O.") == .NT)
        #expect(Province.match("Nfld") == .NL)
        #expect(Province.match("Toronto") == nil)
    }

    @Test("Script look-alikes from OCR are mapped to Latin; accents kept")
    func confusables() {
        #expect(OCRText.normalizeConfusableScripts("VICTORIA ВС V8W 1A1") == "VICTORIA BC V8W 1A1")
        #expect(OCRText.normalizeConfusableScripts("Montréal (Québec)") == "Montréal (Québec)")
    }
}

@Suite("Label analysis (synthetic OCR layouts)")
struct LabelAnalyzerTests {
    @Test("Sender block labelled FROM is never selected")
    func senderExcluded() {
        let p = page([
            (0.05, 0.05, ["FROM:", "PARCEL SHOP TEST", "45 SAMPLE AVE", "TORONTO ON M5V 2T6"]),
            (0.05, 0.40, ["SHIP TO:", "ALEX TEST", "UNIT 204", "123 EXAMPLE ST", "VICTORIA BC V8W 1A1"]),
        ])
        let a = LabelAnalyzer.analyze(page: p)
        #expect(a.selectedCandidate?.address.municipality == "VICTORIA")
        #expect(a.selectedCandidate?.role == .recipient)
        #expect(a.roleIsCertain)
    }

    @Test("Heading inline with the first line")
    func inlineHeading() {
        let p = page([(0.05, 0.3, ["SHIP TO: ALEX TEST, UNIT 204, 123 EXAMPLE ST, VICTORIA BC V8W 1A1"])])
        let a = LabelAnalyzer.analyze(page: p)
        #expect(a.selectedCandidate?.address.unit == "204")
        #expect(a.selectedCandidate?.address.recipientName == "ALEX TEST")
    }

    @Test("Only a sender address → offered as a choice, never auto-selected")
    func onlySender() {
        let p = page([(0.05, 0.05, ["RETURN TO:", "PARCEL SHOP TEST", "45 SAMPLE AVE", "TORONTO ON M5V 2T6"])])
        let a = LabelAnalyzer.analyze(page: p)
        #expect(a.selectedCandidate == nil)
        if case .choice = a.selection {} else { Issue.record("expected choice") }
    }

    @Test("Two different SHIP TO destinations → choice")
    func twoRecipients() {
        let p = page([
            (0.05, 0.05, ["SHIP TO:", "ALEX TEST", "123 EXAMPLE ST", "VICTORIA BC V8W 1A1"]),
            (0.05, 0.55, ["DELIVER TO:", "SAM TEST", "9 MOCK CRES", "HALIFAX NS B3H 1A1"]),
        ])
        let a = LabelAnalyzer.analyze(page: p)
        if case let .choice(ids) = a.selection { #expect(ids.count == 2) } else { Issue.record("expected choice") }
    }

    @Test("Words like TORONTO are not mistaken for a TO heading")
    func toHeading() {
        #expect(LabelAnalyzer.heading(in: "TORONTO ON M5V 2T6") == nil)
        #expect(LabelAnalyzer.heading(in: "TO: ALEX TEST")?.role == .recipient)
        #expect(LabelAnalyzer.heading(in: "TO")?.role == .recipient)
        #expect(LabelAnalyzer.heading(in: "À : Camille")?.role == .recipient)
        #expect(LabelAnalyzer.heading(in: "EXPÉDITEUR :")?.role == .sender)
        #expect(LabelAnalyzer.heading(in: "DESTINATAIRE")?.role == .recipient)
        #expect(LabelAnalyzer.heading(in: "RETURN POLICY APPLIES") == nil)
    }

    @Test("Alternative OCR readings that change the civic number mark it uncertain")
    func uncertainFromAlternatives() {
        var p = page([(0.05, 0.3, ["SHIP TO:", "ALEX TEST", "123 EXAMPLE ST", "VICTORIA BC V8W 1A1"])])
        p.lines[2].alternatives = ["128 EXAMPLE ST"]
        let a = LabelAnalyzer.analyze(page: p)
        let c = a.selectedCandidate!
        #expect(c.uncertainFields.contains(.civicNumber))
        #expect(c.recognition <= .medium)
    }

    @Test("Low recognizer confidence gives a low recognition level")
    func lowConfidence() {
        let p = page([(0.05, 0.3, ["SHIP TO:", "ALEX TEST", "123 EXAMPLE ST", "VICTORIA BC V8W 1A1"])], confidence: 0.3)
        #expect(LabelAnalyzer.analyze(page: p).selectedCandidate?.recognition == .low)
    }
}

@Suite("Barcodes")
struct BarcodeTests {
    @Test func trackingIDsAreNotAddresses() {
        let contents = BarcodeClassifier.classify(DetectedBarcode(payload: "1Z999AA10123456784", symbology: "Code128"))
        #expect(contents == [.trackingIdentifier(normalized: "1Z999AA10123456784", carrierHint: "UPS-style number")])
    }

    @Test func gs1ShipToPostalCode() {
        let contents = BarcodeClassifier.classify(DetectedBarcode(payload: "(420)V8W1A1", symbology: "GS1-128"))
        #expect(contents == [.shipToPostalCode("V8W 1A1")])
        let conflict = ReviewPolicy.evaluate(parsed: CanadianAddressParser.parse(singleLine: "123 Example St, Victoria BC V8W 1A1"), recognition: .high, barcodePostalCode: "V8V 2B2", resolution: .offline)
        #expect(conflict.reasons.contains(.barcodePostalConflict))
    }

    @Test func urlsAndShortCodesIgnored() {
        #expect(BarcodeClassifier.classify(DetectedBarcode(payload: "https://example.com/t/123", symbology: "QR")) == [.url("https://example.com/t/123")])
        #expect(BarcodeClassifier.normalizedTrackingID("ABC") == nil)
        #expect(BarcodeClassifier.normalizedTrackingID("ABCDEFGHIJ") == nil) // needs a digit
    }

    @Test("Printed tracking numbers are read only for unmistakable patterns")
    func printedTracking() {
        #expect(LabelAnalyzer.printedTrackingIDs(in: ["TRACKING 1Z999AA10123456784"]) == ["1Z999AA10123456784"])
        #expect(LabelAnalyzer.printedTrackingIDs(in: ["SUIVI : CA123456789CA"]).contains("CA123456789CA"))
        #expect(LabelAnalyzer.printedTrackingIDs(in: ["VICTORIA BC V8W 1A1", "TEL 250-555-0100", "123 EXAMPLE ST", "REF 4471"]).isEmpty)
        let p = page([(0.05, 0.3, ["SHIP TO:", "ALEX TEST", "123 EXAMPLE ST", "VICTORIA BC V8W 1A1"]), (0.05, 0.7, ["TRACKING 1Z999AA10123456784"])])
        #expect(LabelAnalyzer.analyze(page: p).trackingIDs == ["1Z999AA10123456784"])
    }

    @Test func mecardAddress() {
        let contents = BarcodeClassifier.classify(DetectedBarcode(payload: "MECARD:N:ALEX TEST;ADR:,UNIT 204,123 EXAMPLE ST,VICTORIA,BC,V8W 1A1,CANADA;;", symbology: "QR"))
        guard case let .explicitAddress(a, format) = contents.first else { Issue.record("\(contents)"); return }
        #expect(format == "MECARD")
        #expect(a.unit == "204")
        #expect(a.civicNumber == "123")
    }
}
