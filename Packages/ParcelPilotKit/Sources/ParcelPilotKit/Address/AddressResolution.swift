import Foundation

/// Normalized identity of a delivery destination. Two packages share a stop only when their keys are
/// identical — civic number, street, unit and postal code all included. Coordinates are never used.
public enum DestinationKey {
    public static func make(_ a: PostalAddress) -> String? {
        let area: String
        if let code = a.validPostalCode {
            area = code.compact
        } else if let m = a.municipality, !m.isEmpty {
            area = "M:" + AddressText.foldForMatching(m) + ":" + (a.province?.rawValue ?? "")
        } else if let p = a.postalCode, !p.isEmpty {
            area = "P:" + AddressText.foldForMatching(p)
        } else {
            area = ""
        }
        let unit = AddressText.unitKey(a.unit ?? "")
        if let civic = a.civicNumber?.trimmedNonEmptyValue, let street = a.streetName?.trimmedNonEmptyValue {
            return ["C", AddressText.civicKey(civic), AddressText.streetKey(street), unit, area].joined(separator: "|")
        }
        if let installation = a.deliveryInstallation?.trimmedNonEmptyValue {
            return ["D", AddressText.foldForMatching(installation), unit, area].joined(separator: "|")
        }
        return nil
    }

    /// Same building, ignoring the unit — used only to *inform* the driver ("another unit in this
    /// building is already on the route"), never to merge.
    public static func buildingKey(_ a: PostalAddress) -> String? {
        var copy = a
        copy.unit = nil
        return make(copy)
    }
}

extension String {
    var trimmedNonEmptyValue: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - Geocoder output

public enum GeocodeGranularity: String, Codable, Hashable, Sendable {
    case rooftop, rangeInterpolated, geometricCenter, approximate, unknown
}

/// One candidate from an address resolver. For Google this is Google Maps Content: the coordinate is
/// cached ≤ 30 days and only displayed on a Google map.
public struct GeocodeCandidate: Codable, Hashable, Sendable, Identifiable {
    public var placeID: String?
    public var formattedAddress: String
    public var location: GeoPoint
    public var granularity: GeocodeGranularity
    public var types: [String]
    public var streetNumber: String?
    public var route: String?
    public var subpremise: String?
    public var locality: String?
    public var provinceCode: String?
    public var postalCode: String?
    public var countryCode: String?
    public var provider: ProviderKind

    public var id: String { placeID ?? formattedAddress }

    public init(placeID: String?, formattedAddress: String, location: GeoPoint, granularity: GeocodeGranularity, types: [String], streetNumber: String? = nil, route: String? = nil, subpremise: String? = nil, locality: String? = nil, provinceCode: String? = nil, postalCode: String? = nil, countryCode: String? = nil, provider: ProviderKind) {
        self.placeID = placeID; self.formattedAddress = formattedAddress; self.location = location
        self.granularity = granularity; self.types = types; self.streetNumber = streetNumber; self.route = route
        self.subpremise = subpremise; self.locality = locality; self.provinceCode = provinceCode
        self.postalCode = postalCode; self.countryCode = countryCode; self.provider = provider
    }

    var isBuildingLevelType: Bool {
        types.contains { ["street_address", "premise", "subpremise"].contains($0) }
    }
}

// MARK: - Match assessment

/// How well a resolver result matches the driver's address. A *separate* signal from recognition
/// quality and address completeness; not a probability.
public enum MatchQuality: String, Codable, Hashable, Sendable {
    /// Building-level result whose civic number, street, province and postal code agree.
    case building
    /// Building-level result, but some fields disagree with the label.
    case buildingWithDifferences
    /// Only the street was matched.
    case street
    /// Only the postal code area (centroid) was matched — never acceptable as a destination.
    case postalArea
    /// Only the city/region was matched.
    case municipality
    /// Province or country conflicts with the address.
    case conflict
    case notFound
    /// Demo / emulator result — not a real-world verification.
    case synthetic
    /// Location placed by the driver.
    case driverPin

    public var label: String {
        switch self {
        case .building: return "Building match"
        case .buildingWithDifferences: return "Building found, details differ"
        case .street: return "Street only"
        case .postalArea: return "Postal code area only"
        case .municipality: return "City only"
        case .conflict: return "Conflicting region"
        case .notFound: return "Not found"
        case .synthetic: return "Demo location — not verified"
        case .driverPin: return "Pin placed by you"
        }
    }
}

public enum MatchDifference: Codable, Hashable, Sendable {
    case civicNumber(label: String?, result: String?)
    case street(label: String?, result: String?)
    case postalCode(label: String?, result: String?)
    case province(label: String?, result: String?)
    case municipality(label: String?, result: String?)
    case unitNotRepresented(String)

    public var isBlocking: Bool {
        switch self {
        case .municipality, .unitNotRepresented: return false
        default: return true
        }
    }

    public var explanation: String {
        func q(_ s: String?) -> String { s.map { "“\($0)”" } ?? "nothing" }
        switch self {
        case let .civicNumber(l, r): return "Street number: label \(q(l)), map result \(q(r))."
        case let .street(l, r): return "Street: label \(q(l)), map result \(q(r))."
        case let .postalCode(l, r): return "Postal code: label \(q(l)), map result \(q(r))."
        case let .province(l, r): return "Province: label \(q(l)), map result \(q(r))."
        case let .municipality(l, r): return "City: label \(q(l)), map result \(q(r)). This is common when a neighbourhood and city differ."
        case let .unitNotRepresented(u): return "Unit \(u) is kept on the stop; the map location is the building."
        }
    }
}

public struct MatchAssessment: Hashable, Sendable {
    public var quality: MatchQuality
    public var differences: [MatchDifference]
    public var candidate: GeocodeCandidate?
    /// More than one distinct building-level result was returned.
    public var ambiguous: Bool

    public init(quality: MatchQuality, differences: [MatchDifference], candidate: GeocodeCandidate?, ambiguous: Bool = false) {
        self.quality = quality; self.differences = differences; self.candidate = candidate; self.ambiguous = ambiguous
    }
}

extension PostalAddress {
    /// The address exactly as a provider result states it, used when the driver picks a search
    /// suggestion. Missing components stay missing; nothing is filled in from elsewhere.
    public init(candidate c: GeocodeCandidate) {
        self.init(
            unit: c.subpremise,
            civicNumber: c.streetNumber,
            streetName: c.route,
            municipality: c.locality,
            province: c.provinceCode.flatMap(Province.match),
            postalCode: c.postalCode.map { CanadianPostalCode($0)?.value ?? $0 },
            country: c.countryCode ?? "CA"
        )
    }
}

public enum MatchAssessor {
    public static func assess(address: PostalAddress, candidates: [GeocodeCandidate]) -> MatchAssessment {
        guard !candidates.isEmpty else { return MatchAssessment(quality: .notFound, differences: [], candidate: nil) }
        let assessed = candidates.map { assess(address: address, candidate: $0) }
        let rank: [MatchQuality: Int] = [.building: 0, .buildingWithDifferences: 1, .synthetic: 2, .street: 3, .postalArea: 4, .municipality: 5, .conflict: 6, .notFound: 7, .driverPin: 8]
        let sorted = assessed.sorted { (rank[$0.quality] ?? 9, $0.differences.filter(\.isBlocking).count) < (rank[$1.quality] ?? 9, $1.differences.filter(\.isBlocking).count) }
        var best = sorted[0]
        let buildingLevel = assessed.filter { $0.quality == .building || $0.quality == .buildingWithDifferences }
        let distinctPlaces = Set(buildingLevel.compactMap { $0.candidate?.placeID ?? $0.candidate?.formattedAddress })
        if distinctPlaces.count > 1, best.quality == .building {
            // Two different buildings both look right — the driver must choose.
            best.ambiguous = true
        }
        return best
    }

    public static func assess(address: PostalAddress, candidate c: GeocodeCandidate) -> MatchAssessment {
        var diffs: [MatchDifference] = []

        let labelCivic = address.civicNumber.map(AddressText.civicKey)
        let resultCivic = c.streetNumber.map(AddressText.civicKey)
        if labelCivic != resultCivic { diffs.append(.civicNumber(label: address.civicNumber, result: c.streetNumber)) }

        if !streetsMatch(address.streetName, c.route) { diffs.append(.street(label: address.streetName, result: c.route)) }

        let labelPostal = address.validPostalCode?.compact
        let resultPostal = c.postalCode.flatMap(CanadianPostalCode.init)?.compact
        if labelPostal != resultPostal { diffs.append(.postalCode(label: address.postalCode, result: c.postalCode)) }

        var regionConflict = false
        if let p = address.province, let rp = c.provinceCode.flatMap(Province.match), p != rp {
            diffs.append(.province(label: p.rawValue, result: c.provinceCode))
            regionConflict = true
        }
        if let country = c.countryCode, country.uppercased() != "CA" { regionConflict = true }

        if let m = address.municipality, let rm = c.locality, AddressText.foldForMatching(m) != AddressText.foldForMatching(rm) {
            diffs.append(.municipality(label: m, result: rm))
        }
        if let unit = address.unit, c.subpremise.map(AddressText.unitKey) != AddressText.unitKey(unit) {
            diffs.append(.unitNotRepresented(unit))
        }

        if regionConflict { return MatchAssessment(quality: .conflict, differences: diffs, candidate: c) }

        let preciseGranularity = c.granularity == .rooftop || c.granularity == .rangeInterpolated
        let quality: MatchQuality
        if c.isBuildingLevelType && preciseGranularity && c.streetNumber != nil {
            quality = diffs.contains(where: \.isBlocking) ? .buildingWithDifferences : .building
        } else if c.types.contains("route") || (c.route != nil && c.streetNumber == nil && !c.types.contains("postal_code")) {
            quality = .street
        } else if c.types.contains("postal_code") {
            quality = .postalArea
        } else if c.types.contains(where: { ["locality", "sublocality", "administrative_area_level_1", "administrative_area_level_2", "administrative_area_level_3", "neighborhood", "political"].contains($0) }) {
            quality = .municipality
        } else if c.isBuildingLevelType {
            quality = .buildingWithDifferences
        } else {
            quality = .municipality
        }
        // Demo / emulator results are graded like real ones first, so a synthetic postal-code or street
        // centroid stays coarse (never a destination). Only a clean building-level synthetic result
        // becomes `.synthetic`, which is still never treated as a real-world verification.
        if c.provider == .demo || c.provider == .emulatorFake, quality == .building {
            return MatchAssessment(quality: .synthetic, differences: diffs, candidate: c)
        }
        return MatchAssessment(quality: quality, differences: diffs, candidate: c)
    }

    static func streetsMatch(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        let ka = AddressText.streetKey(a), kb = AddressText.streetKey(b)
        if ka == kb { return true }
        // Tolerate a missing street type/direction ("EXAMPLE" vs "EXAMPLE ST") and tiny spelling noise.
        let ta = Set(ka.split(separator: " ")), tb = Set(kb.split(separator: " "))
        let core = ta.intersection(tb).filter { !AddressText.streetTypeWords.contains(String($0)) && $0.count > 2 }
        if !core.isEmpty, ta.isSubset(of: tb) || tb.isSubset(of: ta) { return true }
        return min(ka.count, kb.count) >= 6 && AddressText.editDistance(ka, kb) <= 1
    }
}
