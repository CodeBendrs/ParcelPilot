import Foundation
import ImageIO
import ParcelPilotKit
import Testing
import UIKit
@testable import ParcelPilot

/// The scan pipeline on synthetic label images, end to end inside the app (Vision runs in the
/// Simulator). Camera capture itself requires a physical iPhone — see docs/DEVICE_TEST_CHECKLIST.md.
@MainActor
@Suite("Scan pipeline (Vision on Simulator)", .serialized)
struct ScanPipelineTests {
    init() { _ = VisionLabelReader.warmUpOnce }

    func process(_ name: String, in model: ScanModel, automatic: Bool = false) async throws {
        let image = try #require(AppFixtures.label(name), "fixture \(name) missing")
        await model.process(image: image.cgImage!, orientation: .up, automatic: automatic)
    }

    @Test("Normal mode: E1 opens a confirmation card with the recipient block and unit 204")
    func normalMode() async throws {
        let env = TestEnvironment()
        env.makeRoute()
        let model = ScanModel(services: env.services, toasts: ToastCenter())
        model.batchMode = false
        try await process("e1_victoria_unit204", in: model)
        let candidate = try #require(model.confirmation?.candidate)
        #expect(candidate.address.unit == "204")
        #expect(candidate.address.civicNumber == "123")
        #expect(candidate.fromLabel?.role == .recipient)
        #expect(candidate.package.trackingID == "1Z999AA10123456784")
        // Demo resolver: synthetic, never "verified".
        #expect(candidate.verification?.assessment?.quality == .synthetic)
        #expect(candidate.confirmedStop(verifier: env.services.verifier).0 == .demoSynthetic)
        #expect(env.snapshot.stops.isEmpty) // nothing added until the driver confirms
    }

    @Test("E3 + E5: batch mode adds clear labels with Undo, merges same destination, separates other unit, flags repeats")
    func batchMode() async throws {
        let env = TestEnvironment()
        env.makeRoute()
        let toasts = ToastCenter()
        let model = ScanModel(services: env.services, toasts: toasts)
        model.batchMode = true

        try await process("e1_victoria_unit204", in: model)
        #expect(env.snapshot.stops.count == 1)
        #expect(env.snapshot.packages.count == 1)
        #expect(toasts.current?.undo != nil)

        // Same label again: duplicate tracking → feedback, no new package.
        try await process("e1_victoria_unit204", in: model)
        #expect(env.snapshot.packages.count == 1)
        #expect(toasts.current?.message.contains("Already scanned") == true)

        // Different package, identical destination → same stop, two packages.
        try await process("e3_same_destination_second_package", in: model)
        #expect(env.snapshot.stops.count == 1)
        #expect(env.snapshot.packages.count == 2)

        // Different unit in the same building → separate stop.
        try await process("e3_other_unit", in: model)
        #expect(env.snapshot.stops.count == 2)

        // Undo the last add.
        toasts.current?.undo?()
        #expect(env.snapshot.stops.count == 1)
    }

    @Test("E5: an ambiguous label goes to the review queue without blocking the next scan")
    func ambiguousGoesToReview() async throws {
        let env = TestEnvironment()
        env.makeRoute()
        let model = ScanModel(services: env.services, toasts: ToastCenter())
        model.batchMode = true
        try await process("ambiguous_two_addresses", in: model)
        #expect(env.snapshot.stops.isEmpty)
        let drafts = env.drafts.drafts(for: env.snapshot.route.id)
        #expect(drafts.count == 1)
        #expect(drafts.first?.state == .needsChoice)
        #expect(model.phase == .idle)
        try await process("e1_victoria_unit204", in: model)
        #expect(env.snapshot.stops.count == 1)
    }

    @Test("E4: tracking-only label adds nothing; obscured civic number goes to review")
    func incompleteLabels() async throws {
        let env = TestEnvironment()
        env.makeRoute()
        let model = ScanModel(services: env.services, toasts: ToastCenter())
        model.batchMode = true
        try await process("e4_tracking_only", in: model)
        #expect(env.snapshot.stops.isEmpty)
        #expect(model.statusMessage?.contains("no delivery address") == true)
        try await process("e4_obscured_civic", in: model)
        #expect(env.snapshot.stops.isEmpty)
        let draft = try #require(env.drafts.drafts(for: env.snapshot.route.id).first)
        #expect(draft.reasons.contains(.missingCivicNumber))
    }

    @Test("E4 import: a row without a civic number goes to review with no stored location; clean rows are accepted")
    func importNeedsReview() async throws {
        let env = TestEnvironment()
        env.makeRoute()
        let clean = CanadianAddressParser.parse(singleLine: "45 Sample Ave, Victoria BC V8V 2B2").address
        let noCivic = CanadianAddressParser.parse(singleLine: "Example St, Victoria BC V8W 1B2").address
        func imported(_ address: PostalAddress) async -> (AddressStatus, StopResolution?, [ReviewReason]) {
            var intake = IntakeCandidate(routeID: env.snapshot.route.id, source: .paste, address: address, verification: await env.services.verifier.verify(address))
            intake.driverEdited = true
            return intake.confirmedStop(verifier: env.services.verifier, driverReviewed: false)
        }
        let a = await imported(clean)
        #expect(a.0 == .demoSynthetic)
        #expect(a.1?.located != nil)
        let b = await imported(noCivic)
        #expect(b.0 == .needsReview)
        #expect(b.1?.match == .postalArea)
        #expect(b.1?.located == nil)
        #expect(b.2.contains(.missingCivicNumber))
        #expect(b.2.contains(.postalAreaOnly))
    }

    @Test("Offline: scans are kept as drafts that need address verification and are not optimized")
    func offlineDraft() async throws {
        let env = TestEnvironment(online: false)
        env.makeRoute()
        let model = ScanModel(services: env.services, toasts: ToastCenter())
        model.batchMode = true
        try await process("e2_french_destinataire", in: model)
        #expect(env.snapshot.stops.isEmpty)
        let draft = try #require(env.drafts.drafts(for: env.snapshot.route.id).first)
        #expect(draft.state == .needsVerification)
        #expect(draft.reasons.contains(.notVerifiedOffline))
        #expect(draft.candidates.first?.address.municipality == "Montréal")
        #expect(draft.candidates.first?.address.unit == "12")

        // Driver confirms it anyway → stop exists but stays out of optimization until verified.
        let candidate = IntakeCandidate.fromDraft(draft)
        let (status, _, _) = candidate.confirmedStop(verifier: env.services.verifier)
        #expect(status == .pendingVerification)
        env.store.addDelivery(to: env.snapshot, address: candidate.address, status: status, resolution: nil, reviewReasons: [], packages: [candidate.package], source: .scan)
        let eligibility = Eligibility.evaluate(env.snapshot, now: Date(), demoMode: true)
        #expect(eligibility.eligible.isEmpty)
        #expect(eligibility.excluded.first?.reason == .addressNotVerified)

        // Back online: drafts and pending stops are verified automatically.
        let online = env.relaunch(online: true)
        await online.services.verifyOfflineDrafts()
        #expect(online.drafts.drafts(for: env.snapshot.route.id).first?.state == .needsReview)
        #expect(online.drafts.drafts(for: env.snapshot.route.id).first?.match == .synthetic)
        online.store.currentRouteID = env.snapshot.route.id
        await online.services.verifier.verifyPendingStops(in: online.store.current!, store: online.store)
        // The relaunched services also verify in the background; wait for whichever finishes.
        for _ in 0..<40 where online.store.current?.stops.first?.addressStatus == .pendingVerification {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(online.store.current!.stops.first?.addressStatus == .demoSynthetic)
    }

    @Test("Drafts persist across relaunch (durable review queue)")
    func draftsPersist() async throws {
        let env = TestEnvironment(online: false)
        env.makeRoute()
        let model = ScanModel(services: env.services, toasts: ToastCenter())
        model.batchMode = true
        try await process("e1_victoria_unit204", in: model)
        let relaunched = env.relaunch()
        #expect(relaunched.drafts.drafts(for: env.snapshot.route.id).count == 1)
    }
}
