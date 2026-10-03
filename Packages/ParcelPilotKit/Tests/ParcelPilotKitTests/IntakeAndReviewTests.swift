import Foundation
import Testing
@testable import ParcelPilotKit

private func googleCandidate(civic: String? = "123", route: String? = "Example Street", postal: String? = "V8W 1A1", province: String = "BC", locality: String = "Victoria", granularity: GeocodeGranularity = .rooftop, types: [String] = ["street_address"], placeID: String = "place-1") -> GeocodeCandidate {
    GeocodeCandidate(placeID: placeID, formattedAddress: "\(civic ?? "") \(route ?? ""), \(locality), \(province) \(postal ?? ""), Canada", location: GeoPoint(latitude: 48.42, longitude: -123.36), granularity: granularity, types: types, streetNumber: civic, route: route, locality: locality, provinceCode: province, postalCode: postal, countryCode: "CA", provider: .google)
}

@Suite("Match assessment and review policy")
struct ReviewTests {
    let e1 = CanadianAddressParser.parse(singleLine: "ALEX TEST, UNIT 204, 123 EXAMPLE ST, VICTORIA BC V8W 1A1")

    @Test("Building-level agreement with clear text is auto-acceptable")
    func buildingMatch() {
        let assessment = MatchAssessor.assess(address: e1.address, candidates: [googleCandidate()])
        #expect(assessment.quality == .building)
        #expect(assessment.differences == [.unitNotRepresented("204")])
        let decision = ReviewPolicy.evaluate(parsed: e1, recognition: .high, resolution: .resolved(assessment))
        #expect(decision.autoAcceptable)
        #expect(decision.statusIfAdded == .verified)
    }

    @Test("A picked suggestion's address matches its own result at building level")
    func addressFromCandidate() {
        let c = googleCandidate(postal: "v8w1a1")
        let address = PostalAddress(candidate: c)
        #expect(address.civicNumber == "123")
        #expect(address.streetName == "Example Street")
        #expect(address.municipality == "Victoria")
        #expect(address.province == .BC)
        #expect(address.postalCode == "V8W 1A1")
        #expect(address.unit == nil)
        let assessment = MatchAssessor.assess(address: address, candidates: [c])
        #expect(assessment.quality == .building)
        #expect(assessment.differences.isEmpty)
        let parsed = ParsedAddress(validating: address)
        #expect(ReviewPolicy.evaluate(parsed: parsed, recognition: nil, resolution: .resolved(assessment)).autoAcceptable)
    }

    @Test("E4: postal-code centroid is never accepted as a destination")
    func postalCentroid() {
        let noCivic = CanadianAddressParser.parse(lines: ["ALEX TEST", "UNIT 204", "EXAMPLE ST", "VICTORIA BC V8W 1A1"])
        let centroid = googleCandidate(civic: nil, route: nil, granularity: .approximate, types: ["postal_code"])
        let assessment = MatchAssessor.assess(address: noCivic.address, candidates: [centroid])
        #expect(assessment.quality == .postalArea)
        let decision = ReviewPolicy.evaluate(parsed: noCivic, recognition: .high, resolution: .resolved(assessment))
        #expect(!decision.autoAcceptable)
        #expect(decision.reasons.contains(.missingCivicNumber))
        #expect(decision.reasons.contains(.postalAreaOnly))
        #expect(ConfirmationPolicy.statusAfterDriverConfirmation(match: .postalArea, hasDriverPin: false, demoMode: false) == .needsReview)
        #expect(!ConfirmationPolicy.mayUseResolvedLocation(.postalArea))
    }

    @Test("Differences between label and result require review")
    func differences() {
        let other = googleCandidate(civic: "128")
        let assessment = MatchAssessor.assess(address: e1.address, candidates: [other])
        #expect(assessment.quality == .buildingWithDifferences)
        #expect(assessment.differences.contains(.civicNumber(label: "123", result: "128")))
        let decision = ReviewPolicy.evaluate(parsed: e1, recognition: .high, resolution: .resolved(assessment))
        #expect(!decision.autoAcceptable)
        #expect(decision.reasons == [.partialMatch])
    }

    @Test("Region conflict")
    func conflict() {
        let assessment = MatchAssessor.assess(address: e1.address, candidates: [googleCandidate(province: "ON")])
        #expect(assessment.quality == .conflict)
    }

    @Test("Street-only and city-only matches")
    func coarse() {
        #expect(MatchAssessor.assess(address: e1.address, candidates: [googleCandidate(civic: nil, granularity: .geometricCenter, types: ["route"])]).quality == .street)
        #expect(MatchAssessor.assess(address: e1.address, candidates: [googleCandidate(civic: nil, route: nil, postal: nil, granularity: .approximate, types: ["locality", "political"])]).quality == .municipality)
    }

    @Test("Two different buildings matching → ambiguous review")
    func ambiguousBuildings() {
        let a = googleCandidate(placeID: "a")
        let b = googleCandidate(placeID: "b")
        let assessment = MatchAssessor.assess(address: e1.address, candidates: [a, b])
        #expect(assessment.ambiguous)
        #expect(ReviewPolicy.evaluate(parsed: e1, recognition: .high, resolution: .resolved(assessment)).reasons.contains(.ambiguousResults))
    }

    @Test("E1: synthetic demo location is never reported as verified")
    func synthetic() {
        var demo = googleCandidate()
        demo.provider = .demo
        let assessment = MatchAssessor.assess(address: e1.address, candidates: [demo])
        #expect(assessment.quality == .synthetic)
        let production = ReviewPolicy.evaluate(parsed: e1, recognition: .high, resolution: .resolved(assessment))
        #expect(!production.autoAcceptable)
        let demoMode = ReviewPolicy.evaluate(parsed: e1, recognition: .high, resolution: .resolved(assessment), allowSyntheticAcceptance: true)
        #expect(demoMode.autoAcceptable)
        #expect(demoMode.statusIfAdded == .demoSynthetic)
        #expect(demoMode.statusIfAdded != .verified)
    }

    @Test("E4 in demo/emulator: a synthetic postal-code or street centroid stays coarse and is never accepted")
    func syntheticCoarse() {
        let noCivic = CanadianAddressParser.parse(lines: ["ALEX TEST", "EXAMPLE ST", "VICTORIA BC V8W 1B2"])
        for provider in [ProviderKind.demo, .emulatorFake] {
            var centroid = googleCandidate(civic: nil, route: nil, postal: "V8W 1B2", granularity: .approximate, types: ["postal_code"])
            centroid.provider = provider
            let assessment = MatchAssessor.assess(address: noCivic.address, candidates: [centroid])
            #expect(assessment.quality == .postalArea)
            let decision = ReviewPolicy.evaluate(parsed: noCivic, recognition: .high, resolution: .resolved(assessment), allowSyntheticAcceptance: true)
            #expect(!decision.autoAcceptable)
            #expect(decision.statusIfAdded == .needsReview)
            #expect(!ConfirmationPolicy.mayUseResolvedLocation(assessment.quality))

            var street = googleCandidate(civic: nil, granularity: .geometricCenter, types: ["route"])
            street.provider = provider
            #expect(MatchAssessor.assess(address: e1.address, candidates: [street]).quality == .street)

            var otherProvince = googleCandidate(province: "ON")
            otherProvince.provider = provider
            #expect(MatchAssessor.assess(address: e1.address, candidates: [otherProvince]).quality == .conflict)
        }
    }

    @Test("Offline scans are saved as pending verification and excluded from optimization")
    func offline() {
        let decision = ReviewPolicy.evaluate(parsed: e1, recognition: .high, resolution: .offline)
        #expect(!decision.autoAcceptable)
        #expect(decision.statusIfAdded == .pendingVerification)
        var route = makeRoute()
        route.start = RoutePlace(label: "Depot", located: LocatedPoint(point: GeoPoint(latitude: 48.4, longitude: -123.3), source: .driverPin))
        var stop = Stop(address: e1.address, addressStatus: .pendingVerification, sequence: 1)
        stop.id = "s1"
        let pkg = Package(stopID: "s1", source: .scan)
        let result = Eligibility.evaluate(RouteSnapshot(route: route, stops: [stop], packages: [pkg], outcomes: []), now: Date(), demoMode: false)
        #expect(result.eligible.isEmpty)
        #expect(result.excluded == [ExcludedStop(stopID: "s1", reason: .addressNotVerified)])
    }

    @Test("E2: uncertain French label requests review")
    func frenchUncertain() {
        let parsed = CanadianAddressParser.parse(lines: ["CAMILLE TEST", "APP. 12", "1234, rue Sainte-Catherine Ouest", "Montréal (Québec) H3G 1P1"])
        let partial = googleCandidate(civic: "1234", route: "Rue Sainte-Catherine O", postal: "H3G 1P2", province: "QC", locality: "Montréal")
        let assessment = MatchAssessor.assess(address: parsed.address, candidates: [partial])
        #expect(assessment.quality == .buildingWithDifferences)
        let decision = ReviewPolicy.evaluate(parsed: parsed, recognition: .high, resolution: .resolved(assessment))
        #expect(!decision.autoAcceptable)
        // Street spelled differently by the geocoder still matches ("O" = Ouest).
        #expect(!assessment.differences.contains { if case .street = $0 { return true }; return false })
    }
}

@Suite("Intake: duplicates, stops and packages")
struct IntakeTests {
    let e1 = CanadianAddressParser.parse(singleLine: "ALEX TEST, UNIT 204, 123 EXAMPLE ST, VICTORIA BC V8W 1A1").address
    let otherUnit = CanadianAddressParser.parse(singleLine: "SAM TEST, UNIT 305, 123 EXAMPLE ST, VICTORIA BC V8W 1A1").address

    @Test("E3: repeated tracking ID → duplicate; same destination → existing stop; other unit → new stop")
    func e3Placement() {
        var stop = Stop(address: e1, addressStatus: .verified, sequence: 1)
        stop.id = "s1"
        let pkg = Package(id: "p1", stopID: "s1", trackingID: "1Z999AA10123456784", source: .scan)
        var index = RouteIntakeIndex(stops: [stop], packages: [pkg])
        #expect(index.placement(for: e1, trackingID: "1Z999AA10123456784") == .duplicateTracking(packageID: "p1", stopID: "s1"))
        #expect(index.placement(for: e1, trackingID: "1z999aa1012345 6784") == .duplicateTracking(packageID: "p1", stopID: "s1"))
        #expect(index.placement(for: e1, trackingID: "1Z999AA10123456795") == .existingStop("s1"))
        #expect(index.placement(for: otherUnit, trackingID: "1Z999AA10123456806") == .newStop)
        #expect(!index.otherUnitsInBuilding(for: otherUnit).isEmpty)
        let p2 = Package(id: "p2", stopID: "s1", trackingID: "1Z999AA10123456795", source: .scan)
        index.register(package: p2)
        #expect(index.placement(for: e1, trackingID: "1Z999AA10123456795") == .duplicateTracking(packageID: "p2", stopID: "s1"))
    }

    @Test("Coordinates never merge stops")
    func coordinatesDoNotMerge() {
        var a = Stop(address: e1, addressStatus: .verified, sequence: 1)
        var b = Stop(address: otherUnit, addressStatus: .verified, sequence: 2)
        let point = LocatedPoint(point: GeoPoint(latitude: 48.42, longitude: -123.36), source: .providerGeocode, expiresAt: Date().addingTimeInterval(1000))
        a.resolution = StopResolution(provider: .google, placeID: "same", located: point, match: .building, resolvedAt: Date())
        b.resolution = a.resolution
        #expect(a.destinationKey != b.destinationKey)
    }

    @Test("Repeated camera frames are ignored; the same label later is flagged")
    func frameDedupe() {
        var d = ScanDeduplicator(cooldown: 4)
        let t0 = Date(timeIntervalSince1970: 1000)
        #expect(d.check(fingerprint: "T:1Z1", at: t0) == .process)
        d.markProcessed("T:1Z1")
        for i in 1...20 { #expect(d.check(fingerprint: "T:1Z1", at: t0.addingTimeInterval(Double(i) * 0.1)) == .ignoreRepeatedFrame) }
        #expect(d.check(fingerprint: "T:1Z1", at: t0.addingTimeInterval(30)) == .seenEarlierThisSession)
        #expect(d.check(fingerprint: "T:1Z2", at: t0.addingTimeInterval(30.1)) == .process)
        d.forget("T:1Z1")
        #expect(d.check(fingerprint: "T:1Z1", at: t0.addingTimeInterval(60)) == .process)
    }

    @Test("E5: batch auto-add only for clear, complete, building-verified scans")
    func batchPolicy() {
        let parsed = CanadianAddressParser.parse(singleLine: "ALEX TEST, UNIT 204, 123 EXAMPLE ST, VICTORIA BC V8W 1A1")
        let assessment = MatchAssessor.assess(address: parsed.address, candidates: [googleCandidate()])
        #expect(ReviewPolicy.evaluate(parsed: parsed, recognition: .high, roleCertain: true, resolution: .resolved(assessment)).autoAcceptable)
        #expect(!ReviewPolicy.evaluate(parsed: parsed, recognition: .high, roleCertain: false, resolution: .resolved(assessment)).autoAcceptable)
        #expect(!ReviewPolicy.evaluate(parsed: parsed, recognition: .high, multipleDestinations: true, resolution: .resolved(assessment)).autoAcceptable)
        #expect(!ReviewPolicy.evaluate(parsed: parsed, recognition: .low, resolution: .resolved(assessment)).autoAcceptable)
        #expect(!ReviewPolicy.evaluate(parsed: parsed, recognition: .high, uncertainFields: [.postalCode], resolution: .resolved(assessment)).autoAcceptable)
    }
}
