import Foundation

/// Problems found while reading an address. Each one is shown to the driver with an explanation; none
/// of them causes a field to be invented or a character to be changed silently.
public enum AddressIssue: Codable, Hashable, Sendable {
    case missingCivicNumber
    case uncertainCivicNumber(raw: String)
    case missingStreet
    case missingMunicipality
    case missingProvince
    case missingPostalCode
    case invalidPostalCode(raw: String)
    case uncertainPostalCode(raw: String, suggestion: String)
    case postalProvinceConflict(postalCode: String, province: Province)
    case poBox
    case ruralRoute
    case generalDelivery
    case nonCanadianCountry(String)
    case multipleUnitCandidates([String])
    case unparsedLines([String])

    /// Plain-language explanation for the confirmation card.
    public var explanation: String {
        switch self {
        case .missingCivicNumber: return "No street number was found. Check the label and type the number."
        case let .uncertainCivicNumber(raw): return "The street number “\(raw)” contains characters that may be misread."
        case .missingStreet: return "No street name was found."
        case .missingMunicipality: return "No city or town was found."
        case .missingProvince: return "No province or territory was found."
        case .missingPostalCode: return "No postal code was found."
        case let .invalidPostalCode(raw): return "“\(raw)” is not a valid Canadian postal code format."
        case let .uncertainPostalCode(raw, suggestion): return "Postal code read as “\(raw)”. It may be \(suggestion) — confirm against the label."
        case let .postalProvinceConflict(postal, province): return "Postal code \(postal) does not belong to \(province.englishName)."
        case .poBox: return "PO box address — there is no street location to drive to."
        case .ruralRoute: return "Rural route address — the exact location usually needs the driver's local knowledge."
        case .generalDelivery: return "General delivery — the parcel is held at a post office."
        case let .nonCanadianCountry(country): return "The country appears to be “\(country)”. ParcelPilot currently supports Canadian addresses only."
        case let .multipleUnitCandidates(units): return "More than one unit number was found (\(units.joined(separator: ", "))). Choose the right one."
        case let .unparsedLines(lines): return "Some lines were not understood: \(lines.joined(separator: " / "))."
        }
    }

    /// Issues that block automatic acceptance in batch mode.
    public var blocksAutomaticAcceptance: Bool {
        switch self {
        case .unparsedLines: return false
        default: return true
        }
    }
}

public struct ParsedAddress: Hashable, Sendable {
    public var address: PostalAddress
    public var issues: [AddressIssue]
    public var postalReading: PostalCodeReading?
    /// Lines (after splitting) that were used, in order — kept so the UI can show the raw text.
    public var lines: [String]

    public var hasCivicAddress: Bool {
        address.civicNumber != nil && address.streetName != nil
    }

    public init(address: PostalAddress, issues: [AddressIssue], postalReading: PostalCodeReading?, lines: [String]) {
        self.address = address
        self.issues = issues
        self.postalReading = postalReading
        self.lines = lines
    }

    /// Validates an already-structured address (typed, edited or imported field by field): the same
    /// completeness and consistency issues the parser reports, without re-reading any text.
    public init(validating address: PostalAddress) {
        var issues: [AddressIssue] = []
        var reading: PostalCodeReading?
        if let raw = address.postalCode?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            if let code = CanadianPostalCode(raw) {
                reading = .valid(code, raw: raw)
            } else if let scanned = PostalCodeScanner.read(in: raw) {
                reading = scanned
                switch scanned {
                case let .uncertain(r, suggestion): issues.append(.uncertainPostalCode(raw: r, suggestion: suggestion.value))
                case let .invalid(r): issues.append(.invalidPostalCode(raw: r))
                case .valid: break
                }
            } else {
                issues.append(.invalidPostalCode(raw: raw))
            }
        } else {
            issues.append(.missingPostalCode)
        }
        if let installation = address.deliveryInstallation, address.civicNumber == nil {
            let upper = installation.uppercased()
            if upper.contains("RR") || upper.contains("RURAL") || upper.contains("SITE") { issues.append(.ruralRoute) }
            else if upper.hasPrefix("GD") || upper.contains("GENERAL DELIVERY") || upper.contains("POSTE RESTANTE") { issues.append(.generalDelivery) }
            else { issues.append(.poBox) }
        } else {
            if address.civicNumber?.isEmpty ?? true { issues.append(.missingCivicNumber) }
            if address.streetName?.isEmpty ?? true { issues.append(.missingStreet) }
        }
        if address.municipality?.isEmpty ?? true { issues.append(.missingMunicipality) }
        if address.province == nil { issues.append(.missingProvince) }
        if let code = address.validPostalCode, let p = address.province, !code.provinces.contains(p) {
            issues.append(.postalProvinceConflict(postalCode: code.value, province: p))
        }
        if let country = address.country, !country.isEmpty, AddressText.foldForMatching(country) != "CA", AddressText.foldForMatching(country) != "CANADA" {
            issues.append(.nonCanadianCountry(country))
        }
        self.init(address: address, issues: issues, postalReading: reading, lines: [])
    }
}

public enum CanadianAddressParser {
    // MARK: Patterns

    static let unitDesignators = ["UNIT", "APT", "APARTMENT", "SUITE", "STE", "APP", "APPT", "APPARTEMENT", "BUREAU", "PH", "PENTHOUSE", "LOGEMENT", "LOG", "#", "NO", "UNITÉ", "UNITE"]
    private static let designatorAlternation = "(?:UNIT|UNITÉ|UNITE|APARTMENT|APPARTEMENT|APPT|APT|APP|SUITE|STE|BUREAU|PENTHOUSE|PH|LOGEMENT|LOG|#)"

    private static func regex(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
    }

    /// "UNIT 204, 123 EXAMPLE ST" / "APP. 12 1234 rue X"
    private static let unitFirst = regex("^(\(designatorAlternation))\\.?\\s*:?\\s*#?\\s*([A-Z0-9][A-Z0-9-]{0,7})\\s*[,;]?\\s+(\\d{1,6}[A-Z]?)\\b[,]?\\s+(.+)$")
    /// "204-123 EXAMPLE ST"
    private static let hyphenated = regex("^([A-Z0-9]{1,6})\\s*-\\s*(\\d{1,6}[A-Z]?)\\b[,]?\\s+(.+)$")
    /// "123 EXAMPLE ST" with optional trailing unit ", APT 5" / " #204" / " UNIT 204"
    private static let civicFirst = regex("^(\\d{1,6}[A-Z]?)\\b[,]?\\s+(.+?)(?:(?:\\s*[,;]\\s*|\\s+)(\(designatorAlternation))\\.?\\s*:?\\s*#?\\s*([A-Z0-9][A-Z0-9-]{0,7}))?$")
    /// Line that only carries a unit: "APP. 12", "UNIT 204", "#204"
    private static let unitOnly = regex("^(\(designatorAlternation))\\.?\\s*:?\\s*#?\\s*([A-Z0-9][A-Z0-9-]{0,7})$")
    /// A civic token that looks like a number with OCR confusions (e.g. "l23", "1O5").
    private static let confusedCivic = regex("^([0-9OoIlSB|]{1,6})\\b[,]?\\s+(.+)$")

    private static let poBox = regex("^(?:P\\.?\\s?O\\.?\\s?BOX|POST OFFICE BOX|BOX|C\\.?\\s?P\\.?|CASE POSTALE)\\s*#?\\s*\\d+")
    private static let ruralRoute = regex("^(?:R\\.?\\s?R\\.?|RURAL ROUTE|ROUTE RURALE|SITE\\s+\\d+.*COMP|COMP\\s+\\d+)\\s*#?\\s*\\d*")
    private static let generalDelivery = regex("^(?:G\\.?\\s?D\\.?|GENERAL DELIVERY|POSTE RESTANTE)\\b")
    private static let phone = regex("(?:TEL|TÉL|PHONE|PH:|T:)|\\(?\\b\\d{3}\\)?[ .-]\\d{3}[ .-]\\d{4}\\b")
    private static let noise = regex("^(?:REF|ORDER|COMMANDE|PO#|INVOICE|FACTURE|WEIGHT|POIDS|WT|DIM|KG|LBS?|TRACKING|SUIVI|PIN|SERVICE|DATE)\\b")

    static let nonCanadaCountries: Set<String> = ["USA", "US", "U S A", "UNITED STATES", "UNITED STATES OF AMERICA", "ETATS UNIS", "ETATS UNIS D AMERIQUE", "MEXICO", "MEXIQUE", "UNITED KINGDOM", "UK", "FRANCE"]

    // MARK: Public API

    /// Parses a single comma-separated address such as a pasted line or CSV cell.
    public static func parse(singleLine: String) -> ParsedAddress {
        parse(lines: [singleLine])
    }

    /// Parses the lines of one address block (heading already removed), top to bottom.
    public static func parse(lines rawLines: [String]) -> ParsedAddress {
        var issues: [AddressIssue] = []
        var address = PostalAddress()
        var lines = splitLogicalLines(rawLines)

        // Country line(s).
        if let last = lines.last {
            let folded = AddressText.foldForMatching(last)
            if folded == "CANADA" {
                lines.removeLast()
                address.country = "CA"
            } else if nonCanadaCountries.contains(folded) {
                lines.removeLast()
                address.country = last
                issues.append(.nonCanadianCountry(last))
            }
        }

        // Locality: last line holding a postal code, or else a province at its end.
        var localityIndex: Int?
        var postalReading: PostalCodeReading?
        // Prefer the last line with a valid (or correctable) code; fall back to an invalid one.
        for acceptInvalid in [false, true] where localityIndex == nil {
            for (i, line) in lines.enumerated().reversed() {
                if matches(phone, line) || matches(noise, line) { continue }
                guard let reading = PostalCodeScanner.read(in: line), !looksLikeStreetLineOnly(line, reading: reading) else { continue }
                if case .invalid = reading, !acceptInvalid { continue }
                localityIndex = i
                postalReading = reading
                break
            }
        }
        if localityIndex == nil {
            for (i, line) in lines.enumerated().reversed() where trailingProvince(in: line) != nil && !startsWithDigit(line) {
                localityIndex = i
                break
            }
        }

        var consumed = Set<Int>()
        if let li = localityIndex {
            consumed.insert(li)
            var text = lines[li]
            if let reading = postalReading {
                text = text.replacingOccurrences(of: reading.raw, with: " ")
                switch reading {
                case let .valid(code, _): address.postalCode = code.value
                case let .uncertain(raw, suggestion):
                    address.postalCode = raw.uppercased()
                    issues.append(.uncertainPostalCode(raw: raw, suggestion: suggestion.value))
                case let .invalid(raw):
                    address.postalCode = raw.uppercased()
                    issues.append(.invalidPostalCode(raw: raw))
                }
            }
            text = text.replacingOccurrences(of: "(?i)\\bcanada\\b", with: " ", options: .regularExpression)
            let (municipality, province) = splitMunicipalityProvince(text)
            address.province = province
            address.municipality = municipality
            // Municipality / province on preceding lines ("Victoria" / "BC" / "V8W 1A1",
            // "VICTORIA BC" / "V8W 1A1").
            var back = li - 1
            while (address.municipality == nil || address.province == nil), back >= 0, back >= li - 2, isPlainLocalityText(lines[back]) {
                let (m2, p2) = splitMunicipalityProvince(lines[back])
                if address.province == nil, let p2 { address.province = p2 }
                if address.municipality == nil, let m2 { address.municipality = m2 }
                if m2 != nil || p2 != nil { consumed.insert(back) }
                back -= 1
            }
        }

        // Street, unit and installation lines above the locality line.
        let upper = (localityIndex ?? lines.count)
        var streetIndex: Int?
        for i in stride(from: upper - 1, through: 0, by: -1) where !consumed.contains(i) {
            let line = lines[i]
            if matches(poBox, line) || matches(ruralRoute, line) || matches(generalDelivery, line) { continue }
            if matches(unitOnly, line) { continue }
            if isStreetLine(line) { streetIndex = i; break }
        }

        var unitCandidates: [(designator: String?, unit: String)] = []
        if let si = streetIndex {
            consumed.insert(si)
            var parsed = parseStreetLine(lines[si])
            // A civic suffix letter that looks like a digit (10O, 12I) is an OCR ambiguity, not a suffix.
            if let civic = parsed.civic, let last = civic.last, civic.count > 1, "OoQDIl".contains(last) {
                parsed.uncertainCivic = civic
                parsed.civic = nil
            }
            address.civicNumber = parsed.civic
            address.streetName = parsed.street
            if let unit = parsed.unit { unitCandidates.append((parsed.designator, unit)) }
            if let raw = parsed.uncertainCivic { issues.append(.uncertainCivicNumber(raw: raw)) }
        }

        for i in 0..<upper where !consumed.contains(i) {
            let line = lines[i]
            if matches(poBox, line) {
                address.deliveryInstallation = line; consumed.insert(i); issues.append(.poBox)
            } else if matches(ruralRoute, line) {
                address.deliveryInstallation = line; consumed.insert(i); issues.append(.ruralRoute)
            } else if matches(generalDelivery, line) {
                address.deliveryInstallation = line; consumed.insert(i); issues.append(.generalDelivery)
            } else if let m = firstMatch(unitOnly, line) {
                unitCandidates.append((m[1].isEmpty ? nil : m[1], m[2])); consumed.insert(i)
            }
        }

        // Unit: one distinct value is accepted; several distinct values need the driver's choice.
        let distinctUnits = unitCandidates.reduce(into: [String]()) { acc, c in
            if !acc.contains(where: { AddressText.unitKey($0) == AddressText.unitKey(c.unit) }) { acc.append(c.unit) }
        }
        if let first = unitCandidates.first {
            address.unit = first.unit
            address.unitDesignator = normalizedDesignator(first.designator)
        }
        if distinctUnits.count > 1 { issues.append(.multipleUnitCandidates(distinctUnits)) }

        // Remaining lines above the street: first plain-text line is the recipient name.
        var unparsed: [String] = []
        let nameLimit = streetIndex ?? upper
        for i in 0..<lines.count where !consumed.contains(i) {
            let line = lines[i]
            if matches(phone, line) || matches(noise, line) { unparsed.append(line); continue }
            if i < nameLimit, address.recipientName == nil, !line.contains(where: { $0.isNumber }) {
                address.recipientName = line
            } else {
                unparsed.append(line)
            }
        }
        address.additionalLines = unparsed

        // Completeness and consistency issues.
        if address.deliveryInstallation == nil || address.civicNumber != nil || address.streetName != nil {
            if address.civicNumber == nil, !issues.contains(where: { if case .uncertainCivicNumber = $0 { return true }; return false }) {
                issues.append(.missingCivicNumber)
            }
            if address.streetName == nil { issues.append(.missingStreet) }
        }
        if address.municipality == nil { issues.append(.missingMunicipality) }
        if address.province == nil { issues.append(.missingProvince) }
        if postalReading == nil { issues.append(.missingPostalCode) }
        if let code = address.validPostalCode, let province = address.province, !code.provinces.contains(province) {
            issues.append(.postalProvinceConflict(postalCode: code.value, province: province))
        }
        if !unparsed.isEmpty { issues.append(.unparsedLines(unparsed)) }

        return ParsedAddress(address: address, issues: issues, postalReading: postalReading, lines: lines)
    }

    // MARK: Helpers

    /// Splits comma-joined address text into logical lines. Only lines containing digits are split
    /// (so "TEST, ALEX" stays a name), and a bare civic number is re-joined with the street that
    /// follows it (French style "1234, rue Sainte-Catherine").
    static func splitLogicalLines(_ rawLines: [String]) -> [String] {
        var out: [String] = []
        for raw in rawLines {
            let line = AddressText.collapseWhitespace(raw).trimmingCharacters(in: CharacterSet(charactersIn: " .;"))
            guard !line.isEmpty else { continue }
            guard line.contains(","), line.contains(where: { $0.isNumber }) else { out.append(line); continue }
            let segments = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            var merged: [String] = []
            var i = 0
            while i < segments.count {
                let seg = segments[i]
                if seg.range(of: "^\\d{1,6}[A-Za-z]?$", options: .regularExpression) != nil, i + 1 < segments.count {
                    merged.append("\(seg), \(segments[i + 1])")
                    i += 2
                } else {
                    merged.append(seg)
                    i += 1
                }
            }
            out.append(contentsOf: merged)
        }
        return out
    }

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// Capture groups of the first match; groups that did not participate are empty strings.
    static func firstMatch(_ re: NSRegularExpression, _ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { idx in
            let r = m.range(at: idx)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }

    static func startsWithDigit(_ s: String) -> Bool { s.first?.isNumber == true }

    /// A line like "123 V8W 1A1"? — a street line that merely contains a postal-shaped token is not a
    /// locality line when it starts with a civic number and has a street word.
    static func looksLikeStreetLineOnly(_ line: String, reading: PostalCodeReading) -> Bool {
        guard case .invalid = reading else { return false }
        return isStreetLine(line)
    }

    static func isStreetLine(_ line: String) -> Bool {
        if matches(unitFirst, line) || matches(hyphenated, line) { return true }
        let tokens = AddressText.foldForMatching(line).split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return false }
        let hasStreetWord = tokens.contains { AddressText.streetTypeWords.contains($0) }
        if tokens[0].first?.isNumber == true, tokens.count >= 2 {
            // "123 EXAMPLE ST", "1234 rue X" — civic number followed by words.
            return tokens.dropFirst().contains { $0.first?.isLetter == true }
        }
        if matches(confusedCivic, line), hasStreetWord { return true }
        return hasStreetWord && !matches(phone, line) && trailingProvince(in: line) == nil
    }

    struct StreetLine { var civic: String?; var street: String?; var unit: String?; var designator: String?; var uncertainCivic: String? }

    static func parseStreetLine(_ line: String) -> StreetLine {
        if let m = firstMatch(unitFirst, line) {
            return StreetLine(civic: m[3], street: cleanStreet(m[4]), unit: m[2], designator: m[1])
        }
        if let m = firstMatch(hyphenated, line), m[1].contains(where: { $0.isNumber }) || m[1].count <= 3 {
            return StreetLine(civic: m[2], street: cleanStreet(m[3]), unit: m[1], designator: nil)
        }
        if let m = firstMatch(civicFirst, line) {
            let unit = m[4].isEmpty ? nil : m[4]
            return StreetLine(civic: m[1], street: cleanStreet(m[2]), unit: unit, designator: m[3].isEmpty ? nil : m[3])
        }
        if let m = firstMatch(confusedCivic, line) {
            return StreetLine(civic: nil, street: cleanStreet(m[2]), unit: nil, designator: nil, uncertainCivic: m[1])
        }
        return StreetLine(civic: nil, street: cleanStreet(line), unit: nil, designator: nil)
    }

    static func cleanStreet(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: " ,;"))
    }

    static func normalizedDesignator(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: CharacterSet(charactersIn: " .:")), !raw.isEmpty else { return nil }
        let upper = raw.uppercased()
        switch upper {
        case "APP", "APPT": return "App."
        case "APT", "APARTMENT": return "Apt"
        case "STE", "SUITE": return "Suite"
        case "#", "NO": return "#"
        case "BUREAU": return "Bureau"
        case "PH", "PENTHOUSE": return "PH"
        case "APPARTEMENT": return "App."
        case "LOG", "LOGEMENT": return "Logement"
        case "UNITE", "UNITÉ": return "Unité"
        default: return "Unit"
        }
    }

    /// Province found at the end of a line, if any (e.g. "VICTORIA BC", "Montréal (Québec)").
    static func trailingProvince(in line: String) -> Province? {
        splitMunicipalityProvince(line).1
    }

    static func isPlainLocalityText(_ line: String) -> Bool {
        !line.contains(where: { $0.isNumber }) && !isStreetLine(line) && !matches(unitOnly, line)
            && !matches(poBox, line) && !matches(generalDelivery, line)
    }

    /// Splits "VICTORIA BC" → ("VICTORIA", .BC); "Montréal (Québec)" → ("Montréal", .QC). Keeps the
    /// municipality text exactly as written.
    static func splitMunicipalityProvince(_ text: String) -> (String?, Province?) {
        let cleaned = text.replacingOccurrences(of: "[()]", with: " ", options: .regularExpression)
        let tokens = cleaned.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        guard !tokens.isEmpty else { return (nil, nil) }
        // Try the longest province phrase that ends the line (up to 5 tokens: "Territoires du Nord-Ouest").
        for length in stride(from: min(5, tokens.count), through: 1, by: -1) {
            let phrase = tokens.suffix(length).joined(separator: " ")
            if let province = Province.match(phrase) {
                let rest = tokens.dropLast(length).joined(separator: " ")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,;-"))
                // Avoid reading a trailing "ON"/"NS" inside a street-style phrase as a province when
                // nothing precedes it and the token is ambiguous (e.g. a lone "NE"). Two-letter codes
                // standing alone are accepted.
                return (rest.isEmpty ? nil : rest, province)
            }
        }
        let rest = tokens.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,;-"))
        return (rest.isEmpty ? nil : rest, nil)
    }
}
