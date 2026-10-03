import Foundation

public enum AddressRole: String, Codable, Hashable, Sendable {
    case recipient
    case sender
    case unknown

    public var label: String {
        switch self {
        case .recipient: return "Recipient"
        case .sender: return "Sender / return address"
        case .unknown: return "Unlabelled address"
        }
    }
}

public enum AddressField: String, Codable, Hashable, Sendable, CaseIterable {
    case civicNumber, street, municipality, province, postalCode

    public var label: String {
        switch self {
        case .civicNumber: return "street number"
        case .street: return "street name"
        case .municipality: return "city"
        case .province: return "province"
        case .postalCode: return "postal code"
        }
    }
}

public enum NonCivicKind: String, Codable, Hashable, Sendable {
    case poBox, ruralRoute, generalDelivery
}

/// How complete the *text* of an address is. Independent of recognition quality and map matching.
public struct AddressCompleteness: Codable, Hashable, Sendable {
    public var missing: [AddressField]
    public var nonCivic: NonCivicKind?

    public init(missing: [AddressField], nonCivic: NonCivicKind?) {
        self.missing = missing
        self.nonCivic = nonCivic
    }

    public init(issues: [AddressIssue]) {
        var missing: [AddressField] = []
        var nonCivic: NonCivicKind?
        for issue in issues {
            switch issue {
            case .missingCivicNumber, .uncertainCivicNumber: missing.append(.civicNumber)
            case .missingStreet: missing.append(.street)
            case .missingMunicipality: missing.append(.municipality)
            case .missingProvince: missing.append(.province)
            case .missingPostalCode, .invalidPostalCode, .uncertainPostalCode: missing.append(.postalCode)
            case .poBox: nonCivic = .poBox
            case .ruralRoute: nonCivic = .ruralRoute
            case .generalDelivery: nonCivic = .generalDelivery
            default: break
            }
        }
        var seen = Set<AddressField>()
        self.missing = missing.filter { seen.insert($0).inserted }
        self.nonCivic = nonCivic
    }

    public var isComplete: Bool { missing.isEmpty && nonCivic == nil }

    public var label: String {
        if let nonCivic {
            switch nonCivic {
            case .poBox: return "PO box (no street location)"
            case .ruralRoute: return "Rural route"
            case .generalDelivery: return "General delivery"
            }
        }
        if missing.isEmpty { return "Complete" }
        return "Missing " + missing.map(\.label).joined(separator: ", ")
    }
}

/// One address-like block found on a label.
public struct AddressCandidate: Identifiable, Hashable, Sendable {
    public let id: Int
    public var parsed: ParsedAddress
    public var role: AddressRole
    /// Human-readable reason for the role, e.g. "Under “SHIP TO”".
    public var roleEvidence: String?
    /// The recognised lines exactly as read (heading removed).
    public var rawLines: [String]
    /// Lowest recognizer score among the block's address lines.
    public var recognitionScore: Double
    /// Fields where the recognizer's alternative readings disagree with the chosen reading.
    public var uncertainFields: [AddressField]
    public var box: OCRBox?

    public var recognition: RecognitionLevel {
        uncertainFields.isEmpty ? RecognitionLevel.from(score: recognitionScore) : min(.medium, RecognitionLevel.from(score: recognitionScore))
    }

    public var completeness: AddressCompleteness { AddressCompleteness(issues: parsed.issues) }
    public var address: PostalAddress { parsed.address }
}

public enum CandidateSelection: Hashable, Sendable {
    /// One destination was identified (role may still be uncertain; see `roleIsCertain`).
    case single(Int)
    /// Several plausible destinations — the driver must choose.
    case choice([Int])
    /// No destination address could be found.
    case none(String)
}

public struct LabelAnalysis: Hashable, Sendable {
    public var candidates: [AddressCandidate]
    public var selection: CandidateSelection
    /// Normalized tracking identifiers from barcodes and printed text.
    public var trackingIDs: [String]
    public var trackingHints: [String: String]
    /// An address explicitly encoded in a barcode payload (vCard/MECARD), if any.
    public var barcodeAddress: PostalAddress?
    /// Ship-to postal code from a GS1 barcode, used to cross-check OCR.
    public var barcodePostalCode: String?
    /// Stable text used to recognise the same physical label across frames.
    public var fingerprint: String

    public var selectedCandidate: AddressCandidate? {
        if case let .single(id) = selection { return candidates.first { $0.id == id } }
        return nil
    }

    public var roleIsCertain: Bool {
        selectedCandidate?.role == .recipient
    }
}

public enum LabelAnalyzer {
    static let recipientHeadings: [String] = [
        "SHIP TO", "SHIPTO", "SHIP TO ADDRESS", "DELIVER TO", "DELIVERY TO", "DELIVERY ADDRESS", "DELIVERY",
        "RECIPIENT", "CONSIGNEE", "DESTINATAIRE", "DESTINATION", "LIVRER A", "LIVRAISON A", "EXPEDIER A",
        "ADRESSE DE LIVRAISON", "A L ATTENTION DE", "TO",
    ]
    static let senderHeadings: [String] = [
        "SHIP FROM", "FROM", "SENDER", "SHIPPER", "RETURN TO", "RETURN ADDRESS", "IF UNDELIVERABLE RETURN TO",
        "IF UNDELIVERABLE", "RETURN", "SHIPPED BY", "ORIGIN", "EXPEDITEUR", "EXPEDITRICE", "EXPEDIE PAR",
        "RETOUR", "RETOURNER A", "EN CAS DE NON LIVRAISON RETOURNER A", "EN CAS DE NON LIVRAISON", "ORIGINE", "DE",
    ]
    /// Short headings that only count when followed by a colon or standing alone.
    static let shortHeadings: Set<String> = ["TO", "DE", "A", "DELIVERY", "RETURN", "ORIGIN"]

    public struct HeadingMatch: Sendable { public var role: AddressRole; public var heading: String; public var remainder: String }

    /// Detects a heading at the start of a line. Returns the role and the text after the heading.
    public static func heading(in text: String) -> HeadingMatch? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let folded = AddressText.foldForMatching(trimmed)
        let candidates = (recipientHeadings.map { ($0, AddressRole.recipient) } + senderHeadings.map { ($0, AddressRole.sender) } + [("A", .recipient)])
            .sorted { $0.0.count > $1.0.count }
        for (phrase, role) in candidates {
            guard folded == phrase || folded.hasPrefix(phrase + " ") else { continue }
            // Locate the end of the heading in the original text: count words.
            let wordCount = phrase.split(separator: " ").count
            let originalWords = trimmed.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "'" || $0 == "’" || $0 == ":" || $0 == "." })
            guard originalWords.count >= wordCount else { continue }
            let lastWord = originalWords[wordCount - 1]
            var remainder = String(trimmed[lastWord.endIndex...])
            let hasColon = remainder.trimmingCharacters(in: .whitespaces).hasPrefix(":")
            remainder = remainder.trimmingCharacters(in: CharacterSet(charactersIn: " :.-–"))
            if shortHeadings.contains(phrase) {
                // "TO:" / "TO" alone / "À: Name" — but not "TORONTO" (handled by word split) or "TO THE DOOR".
                guard hasColon || remainder.isEmpty else { continue }
            } else if !hasColon, !remainder.isEmpty, phrase.split(separator: " ").count == 1 {
                // Single-word headings followed by text without a colon ("RETURN POLICY…") are ignored
                // unless the word is unmistakable.
                guard ["DESTINATAIRE", "EXPEDITEUR", "EXPEDITRICE", "RECIPIENT", "CONSIGNEE", "SENDER", "SHIPPER", "SHIPTO"].contains(phrase) else { continue }
            }
            return HeadingMatch(role: role, heading: String(trimmed[..<lastWord.endIndex]), remainder: remainder)
        }
        return nil
    }

    struct Section {
        var lines: [OCRLine]
        var role: AddressRole
        var evidence: String?
    }

    public static func analyze(page: OCRPage, barcodes: [DetectedBarcode] = []) -> LabelAnalysis {
        // Any OCR source (Vision, VisionKit live text) may emit script look-alikes.
        let normalizedLines = page.lines.map { line -> OCRLine in
            var l = line
            l.text = OCRText.normalizeConfusableScripts(line.text)
            l.alternatives = line.alternatives.map(OCRText.normalizeConfusableScripts)
            return l
        }
        let blocks = LabelBlockSegmenter.segment(normalizedLines)

        // 1. Split blocks at heading lines; collect heading-only blocks for association.
        var sections: [Section] = []
        var orphanHeadings: [(box: OCRBox, role: AddressRole, heading: String)] = []
        for block in blocks {
            var current = Section(lines: [], role: .unknown, evidence: nil)
            for line in block.lines {
                if let match = heading(in: line.text) {
                    if !current.lines.isEmpty || current.role != .unknown { sections.append(current) }
                    current = Section(lines: [], role: match.role, evidence: "Under “\(match.heading.uppercased())”")
                    if !match.remainder.isEmpty {
                        var rest = line
                        rest.text = match.remainder
                        current.lines.append(rest)
                    } else {
                        // Remember the heading position for blocks that are visually separate.
                        current.lines = []
                        if block.lines.count == 1 {
                            orphanHeadings.append((line.box, match.role, match.heading))
                        }
                    }
                } else {
                    current.lines.append(line)
                }
            }
            if !current.lines.isEmpty { sections.append(current) }
        }

        // 2. Attach orphan headings to the nearest unlabelled section below or to the right.
        for orphan in orphanHeadings {
            var best: (index: Int, distance: Double)?
            for (i, section) in sections.enumerated() where section.role == .unknown && !section.lines.isEmpty {
                let box = section.lines.dropFirst().reduce(section.lines[0].box) { $0.union($1.box) }
                let below = box.minY - orphan.box.maxY
                let right = box.minX - orphan.box.maxX
                let verticalSpan = max(orphan.box.height * 4, 0.08)
                var distance: Double?
                if below >= -orphan.box.height * 0.5, below < verticalSpan,
                   box.horizontalOverlap(with: orphan.box) > 0 || abs(box.minX - orphan.box.minX) < 0.1 {
                    distance = below
                } else if right >= 0, right < 0.15, box.verticalOverlap(with: orphan.box) > 0 || abs(box.minY - orphan.box.minY) < orphan.box.height * 2 {
                    distance = right + 0.01
                }
                if let distance, distance < (best?.distance ?? .infinity) { best = (i, distance) }
            }
            if let best {
                sections[best.index].role = orphan.role
                sections[best.index].evidence = "Under “\(orphan.heading.uppercased())”"
            }
        }

        // 3. Parse sections into address candidates.
        var candidates: [AddressCandidate] = []
        var nextID = 0
        for section in sections {
            let texts = section.lines.map(\.text)
            let parsed = CanadianAddressParser.parse(lines: texts)
            // A recipient-headed block is kept even when incomplete (e.g. cut off by the frame) so the
            // driver is told what is missing instead of being offered the sender address.
            let partialRecipient = section.role == .recipient && section.lines.contains { $0.text.contains(where: { $0.isNumber }) }
            guard isAddressLike(parsed) || partialRecipient else { continue }
            let addressLines = section.lines.filter { $0.text.contains(where: { $0.isNumber }) }
            let scoreLines = addressLines.isEmpty ? section.lines : addressLines
            let score = scoreLines.map(\.confidence).min() ?? 0
            let box = section.lines.dropFirst().reduce(section.lines[0].box) { $0.union($1.box) }
            candidates.append(AddressCandidate(
                id: nextID,
                parsed: parsed,
                role: section.role,
                roleEvidence: section.evidence,
                rawLines: texts,
                recognitionScore: score,
                uncertainFields: uncertainFields(in: section.lines, parsed: parsed),
                box: box
            ))
            nextID += 1
        }

        // 4. Barcodes.
        var trackingIDs: [String] = []
        var hints: [String: String] = [:]
        var barcodeAddress: PostalAddress?
        var barcodePostal: String?
        for barcode in barcodes {
            for content in BarcodeClassifier.classify(barcode) {
                switch content {
                case let .trackingIdentifier(id, hint):
                    if !trackingIDs.contains(id) { trackingIDs.append(id) }
                    if let hint { hints[id] = hint }
                case let .explicitAddress(address, _): barcodeAddress = address
                case let .shipToPostalCode(code): barcodePostal = code
                case .url, .other: break
                }
            }
        }

        // Printed tracking numbers (strict carrier-style patterns only) — covers damaged barcodes and
        // devices/simulators where barcode detection is unavailable.
        for id in printedTrackingIDs(in: normalizedLines.map(\.text)) where !trackingIDs.contains(id) {
            trackingIDs.append(id)
            if let hint = BarcodeClassifier.carrierHint(for: id) { hints[id] = hint }
        }

        let selection = select(candidates)
        let fingerprint = makeFingerprint(trackingIDs: trackingIDs, candidates: candidates, selection: selection)
        return LabelAnalysis(
            candidates: candidates,
            selection: selection,
            trackingIDs: trackingIDs,
            trackingHints: hints,
            barcodeAddress: barcodeAddress,
            barcodePostalCode: barcodePostal,
            fingerprint: fingerprint
        )
    }

    private static let printedTrackingPatterns: [NSRegularExpression] = [
        "\\b1Z[0-9A-Z]{16}\\b",              // UPS-style
        "\\b[A-Z]{2}[0-9]{9}CA\\b",          // Canada Post international-style
        "\\bTBA[0-9]{9,12}\\b",              // Amazon-style
    ].map { try! NSRegularExpression(pattern: $0) }
    private static let trackingLabel = try! NSRegularExpression(pattern: "^(?:TRACKING|TRACKING #|TRACKING NO|TRACKING NUMBER|SUIVI|NO DE SUIVI|PIN)\\b[ .:#]*([A-Z0-9 -]{10,40})$", options: [.caseInsensitive])

    /// Tracking numbers printed as text. Only unmistakable patterns (or text after a TRACKING/SUIVI
    /// label) are accepted, so postal codes, phone numbers and civic numbers are never mistaken for them.
    static func printedTrackingIDs(in lines: [String]) -> [String] {
        var found: [String] = []
        for line in lines {
            let upper = line.uppercased()
            let ns = upper as NSString
            for re in printedTrackingPatterns {
                for m in re.matches(in: upper, range: NSRange(location: 0, length: ns.length)) {
                    let id = ns.substring(with: m.range)
                    if !found.contains(id) { found.append(id) }
                }
            }
            if let m = trackingLabel.firstMatch(in: upper, range: NSRange(location: 0, length: ns.length)),
               let id = BarcodeClassifier.normalizedTrackingID(ns.substring(with: m.range(at: 1))), !found.contains(id) {
                found.append(id)
            }
        }
        return found
    }

    static func isAddressLike(_ parsed: ParsedAddress) -> Bool {
        let a = parsed.address
        if parsed.postalReading != nil && (a.streetName != nil || a.municipality != nil || a.deliveryInstallation != nil) { return true }
        if a.streetName != nil, a.civicNumber != nil || hasUncertainCivic(parsed), a.municipality != nil || a.province != nil { return true }
        if a.deliveryInstallation != nil, a.municipality != nil || a.province != nil { return true }
        return false
    }

    static func hasUncertainCivic(_ parsed: ParsedAddress) -> Bool {
        parsed.issues.contains { if case .uncertainCivicNumber = $0 { return true }; return false }
    }

    /// Selection rules:
    /// * Sender-labelled blocks are never selected automatically.
    /// * Exactly one recipient-labelled destination → selected.
    /// * Several distinct recipient-labelled destinations → choice.
    /// * No headings: one unlabelled block → selected with an uncertain role; several → choice.
    static func select(_ candidates: [AddressCandidate]) -> CandidateSelection {
        let recipients = distinctDestinations(candidates.filter { $0.role == .recipient })
        if recipients.count == 1 { return .single(recipients[0].id) }
        if recipients.count > 1 { return .choice(recipients.map(\.id)) }
        let unknown = distinctDestinations(candidates.filter { $0.role == .unknown })
        if unknown.count == 1 { return .single(unknown[0].id) }
        if unknown.count > 1 { return .choice(unknown.map(\.id)) }
        if !candidates.isEmpty {
            // Only sender/return addresses were found — offer them, but never pick one automatically.
            return .choice(candidates.map(\.id))
        }
        return .none("No delivery address was found on this label. Make sure the SHIP TO block is inside the frame, or enter the address manually.")
    }

    static func distinctDestinations(_ list: [AddressCandidate]) -> [AddressCandidate] {
        var seen = Set<String>()
        return list.filter { candidate in
            let key = DestinationKey.make(candidate.address) ?? "raw:" + AddressText.foldForMatching(candidate.rawLines.joined(separator: " "))
            return seen.insert(key).inserted
        }
    }

    /// Compares each line's alternatives with the chosen reading for civic number and postal code.
    static func uncertainFields(in lines: [OCRLine], parsed: ParsedAddress) -> [AddressField] {
        var fields: [AddressField] = []
        let chosenPostal = parsed.postalReading?.raw.uppercased().filter { !$0.isWhitespace }
        let chosenCivic = parsed.address.civicNumber
        for line in lines {
            for alt in line.alternatives {
                if let chosenPostal, line.text.uppercased().filter({ !$0.isWhitespace }).contains(chosenPostal) {
                    let altPostal = PostalCodeScanner.read(in: alt)?.raw.uppercased().filter { !$0.isWhitespace }
                    if altPostal != chosenPostal, !fields.contains(.postalCode) { fields.append(.postalCode) }
                }
                if let chosenCivic, line.text.contains(chosenCivic), CanadianAddressParser.isStreetLine(line.text) {
                    let altCivic = CanadianAddressParser.parseStreetLine(alt).civic
                    if altCivic != chosenCivic, !fields.contains(.civicNumber) { fields.append(.civicNumber) }
                }
            }
        }
        if parsed.issues.contains(where: { if case .uncertainPostalCode = $0 { return true }; return false }), !fields.contains(.postalCode) {
            fields.append(.postalCode)
        }
        if hasUncertainCivic(parsed), !fields.contains(.civicNumber) { fields.append(.civicNumber) }
        return fields
    }

    static func makeFingerprint(trackingIDs: [String], candidates: [AddressCandidate], selection: CandidateSelection) -> String {
        if !trackingIDs.isEmpty { return "T:" + trackingIDs.sorted().joined(separator: ",") }
        let chosen: [AddressCandidate]
        switch selection {
        case let .single(id): chosen = candidates.filter { $0.id == id }
        case let .choice(ids): chosen = candidates.filter { ids.contains($0.id) }
        case .none: chosen = []
        }
        let text = chosen.map { AddressText.foldForMatching($0.rawLines.joined(separator: " ")) }.joined(separator: "|")
        return "A:" + text
    }
}
