import Foundation

/// RFC 4180 CSV reader with delimiter detection (comma, semicolon, tab), quoted fields, escaped
/// quotes, CRLF/LF line endings and a UTF-8 BOM.
public enum CSVReader {
    public static func detectDelimiter(_ text: String) -> Character {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let counts: [(Character, Int)] = [(",", firstLine.filter { $0 == "," }.count), (";", firstLine.filter { $0 == ";" }.count), ("\t", firstLine.filter { $0 == "\t" }.count)]
        return counts.max { $0.1 < $1.1 }.flatMap { $0.1 > 0 ? $0.0 : nil } ?? ","
    }

    public static func parse(_ input: String, delimiter: Character? = nil) -> [[String]] {
        var text = input
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let delim = delimiter ?? detectDelimiter(text)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = Array(text).makeIterator()
        var pending: Character? = nil
        func next() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }
        while let c = next() {
            if inQuotes {
                if c == "\"" {
                    if let n = next() {
                        if n == "\"" { field.append("\"") } else { inQuotes = false; pending = n }
                    } else { inQuotes = false }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"" where field.isEmpty: inQuotes = true
                case delim: row.append(field); field = ""
                case "\r\n", "\n", "\r":
                    row.append(field); field = ""
                    rows.append(row); row = []
                default: field.append(c)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
    }
}

public enum ImportColumnRole: String, Codable, CaseIterable, Hashable, Sendable {
    case ignore, fullAddress, street, unit, municipality, province, postalCode, recipientName, trackingID, packageCount, storageLocation, notes

    public var label: String {
        switch self {
        case .ignore: return "Ignore"
        case .fullAddress: return "Full address"
        case .street: return "Street address"
        case .unit: return "Unit / apt"
        case .municipality: return "City"
        case .province: return "Province"
        case .postalCode: return "Postal code"
        case .recipientName: return "Recipient"
        case .trackingID: return "Tracking ID"
        case .packageCount: return "Package count"
        case .storageLocation: return "Vehicle location"
        case .notes: return "Notes"
        }
    }

    static let synonyms: [ImportColumnRole: [String]] = [
        .fullAddress: ["ADDRESS", "FULL ADDRESS", "ADRESSE", "ADRESSE COMPLETE", "DESTINATION", "DELIVERY ADDRESS"],
        .street: ["STREET", "STREET ADDRESS", "ADDRESS 1", "ADDRESS1", "ADDRESS LINE 1", "LINE 1", "RUE", "ADRESSE 1", "CIVIC ADDRESS"],
        .unit: ["UNIT", "APT", "APARTMENT", "SUITE", "ADDRESS 2", "ADDRESS2", "ADDRESS LINE 2", "APP", "APPARTEMENT", "BUREAU", "UNITE"],
        .municipality: ["CITY", "TOWN", "MUNICIPALITY", "VILLE", "MUNICIPALITE", "LOCALITY"],
        .province: ["PROVINCE", "PROV", "STATE", "REGION", "TERRITORY"],
        .postalCode: ["POSTAL CODE", "POSTAL", "POSTCODE", "ZIP", "ZIP CODE", "CODE POSTAL", "CP"],
        .recipientName: ["NAME", "RECIPIENT", "CUSTOMER", "CONTACT", "NOM", "DESTINATAIRE", "CLIENT"],
        .trackingID: ["TRACKING", "TRACKING ID", "TRACKING NUMBER", "TRACKING #", "BARCODE", "PARCEL ID", "PACKAGE ID", "NUMERO DE SUIVI", "SUIVI"],
        .packageCount: ["PACKAGES", "PACKAGE COUNT", "QTY", "QUANTITY", "PIECES", "COLIS", "NOMBRE DE COLIS"],
        .storageLocation: ["LOCATION", "SHELF", "BIN", "TOTE", "VEHICLE LOCATION", "EMPLACEMENT"],
        .notes: ["NOTES", "NOTE", "COMMENTS", "INSTRUCTIONS", "DELIVERY NOTES", "REMARQUES"],
    ]

    public static func guess(header: String) -> ImportColumnRole {
        let key = AddressText.foldForMatching(header)
        for (role, words) in synonyms where words.map(AddressText.foldForMatching).contains(key) { return role }
        return .ignore
    }
}

/// One address to import, from any bulk source (CSV row, pasted block).
public struct ImportCandidate: Identifiable, Hashable, Sendable {
    public var id: Int { rowNumber }
    /// 1-based row/entry number as the driver sees it in the source.
    public var rowNumber: Int
    public var sourceText: String
    public var parsed: ParsedAddress
    public var trackingID: String?
    public var packageCount: Int
    public var storageLocation: String?
    public var notes: String?
    public var errors: [String]
    /// Row number of an earlier row with the same destination in this import.
    public var duplicateOfRow: Int?
    /// An existing stop with the same destination on the route.
    public var duplicateOfStop: StopID?
    /// Tracking ID already on the route or earlier in this import.
    public var duplicateTracking: Bool

    public var isImportable: Bool { errors.isEmpty }
}

public enum BulkImportPlanner {
    /// Splits pasted text into address entries: blank lines separate multi-line entries; otherwise
    /// each line is one address.
    public static func pastedEntries(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if blocks.count > 1 { return blocks }
        let lines = normalized.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // A single multi-line block whose only postal code is on the last line is one address.
        let postalLines = lines.filter { PostalCodeScanner.read(in: $0) != nil }
        if postalLines.count == 1, PostalCodeScanner.read(in: lines.last ?? "") != nil, lines.count <= 5,
           !lines.dropLast().contains(where: { $0.contains(",") && PostalCodeScanner.read(in: $0) != nil }) {
            return [lines.joined(separator: "\n")]
        }
        return lines
    }

    public static func fromPaste(_ text: String, index: RouteIntakeIndex) -> [ImportCandidate] {
        let entries = pastedEntries(text)
        let candidates = entries.enumerated().map { i, entry -> ImportCandidate in
            let parsed = CanadianAddressParser.parse(lines: entry.split(separator: "\n").map(String.init))
            return ImportCandidate(rowNumber: i + 1, sourceText: entry, parsed: parsed, trackingID: nil, packageCount: 1, storageLocation: nil, notes: nil, errors: errors(for: parsed), duplicateOfRow: nil, duplicateOfStop: nil, duplicateTracking: false)
        }
        return markDuplicates(candidates, index: index)
    }

    public static func fromCSV(rows: [[String]], hasHeader: Bool, mapping: [ImportColumnRole], index: RouteIntakeIndex) -> [ImportCandidate] {
        let dataRows = hasHeader ? Array(rows.dropFirst()) : rows
        let offset = hasHeader ? 2 : 1
        let candidates = dataRows.enumerated().map { i, row -> ImportCandidate in
            func value(_ role: ImportColumnRole) -> String? {
                let parts = mapping.enumerated().filter { $0.element == role }.compactMap { idx, _ in idx < row.count ? row[idx].trimmingCharacters(in: .whitespaces) : nil }.filter { !$0.isEmpty }
                return parts.isEmpty ? nil : parts.joined(separator: " ")
            }
            var lines: [String] = []
            if let name = value(.recipientName) { lines.append(name) }
            if let full = value(.fullAddress) { lines.append(full) }
            if let unit = value(.unit) {
                let hasDesignator = unit.range(of: "^(?i)(unit|apt|app|suite|ste|bureau|#)", options: .regularExpression) != nil
                lines.append(hasDesignator ? unit : "Unit \(unit)")
            }
            if let street = value(.street) { lines.append(street) }
            let locality = [value(.municipality), value(.province), value(.postalCode)].compactMap { $0 }.joined(separator: " ")
            if !locality.isEmpty { lines.append(locality) }
            var parsed = CanadianAddressParser.parse(lines: lines)
            if let name = value(.recipientName) { parsed.address.recipientName = name }
            var errs = errors(for: parsed)
            var count = 1
            if let raw = value(.packageCount) {
                if let n = Int(raw), (1...50).contains(n) { count = n } else { errs.append("Package count “\(raw)” must be a whole number from 1 to 50.") }
            }
            if lines.isEmpty { errs = ["Row is empty for the mapped columns."] }
            return ImportCandidate(rowNumber: i + offset, sourceText: row.joined(separator: ", "), parsed: parsed, trackingID: value(.trackingID), packageCount: count, storageLocation: value(.storageLocation), notes: value(.notes), errors: errs, duplicateOfRow: nil, duplicateOfStop: nil, duplicateTracking: false)
        }
        return markDuplicates(candidates, index: index)
    }

    /// Row-level errors block import of that row; review-level issues (e.g. missing postal code) are
    /// handled later by address verification and do not block.
    static func errors(for parsed: ParsedAddress) -> [String] {
        var errs: [String] = []
        let a = parsed.address
        if a.streetName == nil && a.deliveryInstallation == nil { errs.append("No street address found.") }
        if a.municipality == nil && a.validPostalCode == nil { errs.append("Needs a city or a postal code.") }
        if case let .some(.invalid(raw)) = parsed.postalReading { errs.append("“\(raw)” is not a valid postal code.") }
        for issue in parsed.issues { if case let .nonCanadianCountry(c) = issue { errs.append("Country “\(c)” is not supported.") } }
        return errs
    }

    static func markDuplicates(_ input: [ImportCandidate], index: RouteIntakeIndex) -> [ImportCandidate] {
        var firstRowForKey: [String: Int] = [:]
        var seenTracking = Set<String>()
        return input.map { c in
            var c = c
            if let key = DestinationKey.make(c.parsed.address) {
                if let row = firstRowForKey[key] { c.duplicateOfRow = row } else { firstRowForKey[key] = c.rowNumber }
                if let stop = index.stopsByKey[key] { c.duplicateOfStop = stop }
            }
            if let t = c.trackingID, let key = BarcodeClassifier.normalizedTrackingID(t) ?? Package.looseKey(t) {
                if index.packagesByTracking[key] != nil || !seenTracking.insert(key).inserted { c.duplicateTracking = true }
            }
            return c
        }
    }
}
