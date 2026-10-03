import Foundation

/// What a barcode tells us. Tracking barcodes identify a *package*, not a destination; the address
/// comes from the printed label unless the payload explicitly encodes one.
public enum BarcodeContent: Hashable, Sendable {
    /// Package identifier. `carrierHint` is a pattern guess only — no carrier lookup is performed.
    case trackingIdentifier(normalized: String, carrierHint: String?)
    /// A payload that explicitly carries a postal address (vCard / MECARD).
    case explicitAddress(PostalAddress, format: String)
    /// GS1 Application Identifier 420/421: ship-to postal code. Used only to cross-check OCR.
    case shipToPostalCode(String)
    case url(String)
    case other(String)
}

public enum BarcodeClassifier {
    public static func classify(_ barcode: DetectedBarcode) -> [BarcodeContent] {
        let payload = barcode.payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return [] }

        if payload.uppercased().hasPrefix("BEGIN:VCARD"), let address = parseVCardAddress(payload) {
            return [.explicitAddress(address, format: "vCard")]
        }
        if payload.uppercased().hasPrefix("MECARD:"), let address = parseMECardAddress(payload) {
            return [.explicitAddress(address, format: "MECARD")]
        }
        if let url = URL(string: payload), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return [.url(payload)]
        }

        var results: [BarcodeContent] = []
        let gs1 = parseGS1ShipToPostal(payload)
        if let postal = gs1 { results.append(.shipToPostalCode(postal)) }

        if gs1 == nil, let tracking = normalizedTrackingID(payload) {
            results.append(.trackingIdentifier(normalized: tracking, carrierHint: carrierHint(for: tracking)))
        }
        if results.isEmpty { results.append(.other(payload)) }
        return results
    }

    /// Uppercased alphanumerics, 8–40 characters, at least one digit. Spaces and dashes removed.
    public static func normalizedTrackingID(_ raw: String) -> String? {
        let compact = raw.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard (8...40).contains(compact.count),
              compact.allSatisfy({ $0.isASCIIDigit || $0.isASCIILetter }),
              compact.contains(where: { $0.isASCIIDigit }) else { return nil }
        return compact
    }

    static func carrierHint(for id: String) -> String? {
        if id.range(of: "^1Z[0-9A-Z]{16}$", options: .regularExpression) != nil { return "UPS-style number" }
        if id.range(of: "^[A-Z]{2}\\d{9}CA$", options: .regularExpression) != nil { return "Canada Post-style number" }
        if id.range(of: "^\\d{16}$", options: .regularExpression) != nil { return "16-digit number" }
        if id.range(of: "^TBA\\d{9,12}$", options: .regularExpression) != nil { return "Amazon-style number" }
        if id.range(of: "^\\d{12}$|^\\d{15}$", options: .regularExpression) != nil { return "12/15-digit number" }
        return nil
    }

    /// GS1-128 payloads may include AI (420) ship-to postal code or (421) ISO country + postal code.
    /// Both bracketed text form and raw form with FNC1/GS separators are handled.
    static func parseGS1ShipToPostal(_ payload: String) -> String? {
        let gsSeparated = payload.replacingOccurrences(of: "\u{1D}", with: "|")
        if let r = gsSeparated.range(of: "\\(420\\)([A-Z0-9 ]{3,9})", options: .regularExpression) {
            let value = String(gsSeparated[r]).dropFirst(5)
            return CanadianPostalCode(String(value))?.value
        }
        if let r = gsSeparated.range(of: "\\(421\\)124([A-Z0-9 ]{3,9})", options: .regularExpression) {
            let value = String(gsSeparated[r]).dropFirst(8)
            return CanadianPostalCode(String(value))?.value
        }
        if gsSeparated.hasPrefix("420") {
            let value = gsSeparated.dropFirst(3).prefix { $0 != "|" }
            if let code = CanadianPostalCode(String(value)) { return code.value }
        }
        if gsSeparated.hasPrefix("421124") {
            let value = gsSeparated.dropFirst(6).prefix { $0 != "|" }
            if let code = CanadianPostalCode(String(value)) { return code.value }
        }
        return nil
    }

    /// vCard ADR: PO box; extended; street; locality; region; postal code; country.
    static func parseVCardAddress(_ payload: String) -> PostalAddress? {
        let lines = payload.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n").map(String.init)
        var name: String?
        var adr: [String]?
        for line in lines {
            let upper = line.uppercased()
            if upper.hasPrefix("FN:") { name = String(line.dropFirst(3)) }
            if upper.hasPrefix("ADR"), let colon = line.firstIndex(of: ":") {
                adr = line[line.index(after: colon)...].split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            }
        }
        guard let parts = adr, parts.count >= 7 else { return nil }
        return addressFromComponents(name: name, poBox: parts[0], extended: parts[1], street: parts[2], locality: parts[3], region: parts[4], postal: parts[5], country: parts[6])
    }

    /// MECARD:N:Name;ADR:po,ext,street,locality,region,postal,country;;
    static func parseMECardAddress(_ payload: String) -> PostalAddress? {
        let body = payload.dropFirst("MECARD:".count)
        var name: String?
        var adr: String?
        for field in body.split(separator: ";") {
            if field.uppercased().hasPrefix("N:") { name = String(field.dropFirst(2)) }
            if field.uppercased().hasPrefix("ADR:") { adr = String(field.dropFirst(4)) }
        }
        guard let adr else { return nil }
        let parts = adr.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 7 {
            return addressFromComponents(name: name, poBox: parts[0], extended: parts[1], street: parts[2], locality: parts[3], region: parts[4], postal: parts[5], country: parts[6])
        }
        var parsed = CanadianAddressParser.parse(singleLine: adr).address
        parsed.recipientName = name
        return parsed
    }

    static func addressFromComponents(name: String?, poBox: String, extended: String, street: String, locality: String, region: String, postal: String, country: String) -> PostalAddress? {
        var lines: [String] = []
        if let name, !name.isEmpty { lines.append(name) }
        if !extended.isEmpty { lines.append(extended) }
        if !street.isEmpty { lines.append(street) }
        if !poBox.isEmpty { lines.append(poBox) }
        lines.append([locality, region, postal].filter { !$0.isEmpty }.joined(separator: " "))
        if !country.isEmpty { lines.append(country) }
        let parsed = CanadianAddressParser.parse(lines: lines)
        guard parsed.address.streetName != nil || parsed.address.deliveryInstallation != nil else { return nil }
        return parsed.address
    }
}
