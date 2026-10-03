import Foundation

/// A structured Canadian delivery address as confirmed (or being confirmed) by the driver.
/// Every field keeps the text exactly as read or typed — including accents — so the driver sees what
/// is on the label. Comparison uses folded keys, never rewrites.
public struct PostalAddress: Codable, Hashable, Sendable {
    public var recipientName: String?
    /// Unit / apartment / suite identifier without its designator, e.g. "204", "12", "PH3".
    public var unit: String?
    /// Designator as printed, e.g. "UNIT", "APT", "APP.", "SUITE", "BUREAU", "#".
    public var unitDesignator: String?
    /// Civic (street) number, e.g. "123", "1234A".
    public var civicNumber: String?
    /// Street name including type and direction, e.g. "EXAMPLE ST", "rue Sainte-Catherine Ouest".
    public var streetName: String?
    /// Non-civic delivery mode text such as "PO BOX 123", "RR 2", "C.P. 45", "GD".
    public var deliveryInstallation: String?
    public var municipality: String?
    public var province: Province?
    /// Normalized `A1A 1A1` when valid; otherwise the raw text as read (and flagged by validation).
    public var postalCode: String?
    /// ISO country code when known ("CA"), or the raw country text.
    public var country: String?
    /// Lines that were part of the block but not understood (shown to the driver, never dropped silently).
    public var additionalLines: [String]

    public init(
        recipientName: String? = nil,
        unit: String? = nil,
        unitDesignator: String? = nil,
        civicNumber: String? = nil,
        streetName: String? = nil,
        deliveryInstallation: String? = nil,
        municipality: String? = nil,
        province: Province? = nil,
        postalCode: String? = nil,
        country: String? = "CA",
        additionalLines: [String] = []
    ) {
        self.recipientName = recipientName
        self.unit = unit
        self.unitDesignator = unitDesignator
        self.civicNumber = civicNumber
        self.streetName = streetName
        self.deliveryInstallation = deliveryInstallation
        self.municipality = municipality
        self.province = province
        self.postalCode = postalCode
        self.country = country
        self.additionalLines = additionalLines
    }

    public var validPostalCode: CanadianPostalCode? { postalCode.flatMap(CanadianPostalCode.init) }

    /// "123 EXAMPLE ST" (no unit).
    public var streetLine: String? {
        let parts = [civicNumber, streetName].compactMap { $0?.trimmed.nilIfEmpty }
        if parts.isEmpty { return deliveryInstallation?.trimmed.nilIfEmpty }
        return parts.joined(separator: " ")
    }

    /// "UNIT 204" style label for display.
    public var unitLabel: String? {
        guard let unit = unit?.trimmed.nilIfEmpty else { return nil }
        let designator = unitDesignator?.trimmed.nilIfEmpty ?? "Unit"
        if designator == "#" { return "#\(unit)" }
        return "\(designator) \(unit)"
    }

    /// "VICTORIA BC V8W 1A1"
    public var localityLine: String? {
        let parts = [municipality?.trimmed.nilIfEmpty, province?.rawValue, postalCode?.trimmed.nilIfEmpty].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Full single-line form including the unit, for lists and confirmation.
    public var singleLine: String {
        var parts: [String] = []
        if let unitLabel { parts.append(unitLabel) }
        if let streetLine { parts.append(streetLine) }
        if let installation = deliveryInstallation?.trimmed.nilIfEmpty, civicNumber != nil { parts.append(installation) }
        if let localityLine { parts.append(localityLine) }
        return parts.joined(separator: ", ")
    }

    /// Building-level query for navigation apps and geocoding: civic + street, municipality, province,
    /// postal code, country. The unit is deliberately omitted (it stays on the stop card).
    public var buildingQuery: String {
        var parts: [String] = []
        if let streetLine { parts.append(streetLine) }
        if let municipality = municipality?.trimmed.nilIfEmpty { parts.append(municipality) }
        let provincePostal = [province?.rawValue, validPostalCode?.value].compactMap { $0 }.joined(separator: " ")
        if !provincePostal.isEmpty { parts.append(provincePostal) }
        parts.append("Canada")
        return parts.joined(separator: ", ")
    }

    public var isNonCivicDelivery: Bool {
        civicNumber == nil && deliveryInstallation != nil
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension Optional where Wrapped == String {
    var trimmedNonEmpty: String? { self?.trimmed.nilIfEmpty }
}
