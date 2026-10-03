import Foundation

/// Why a scanned or typed address needs the driver's review. Every reason has a plain explanation.
public enum ReviewReason: String, Codable, Hashable, Sendable, CaseIterable {
    case lowRecognition
    case uncertainCharacters
    case missingCivicNumber
    case missingStreet
    case missingMunicipality
    case missingProvince
    case missingPostalCode
    case invalidPostalCode
    case postalProvinceConflict
    case poBox
    case ruralRoute
    case generalDelivery
    case nonCanadian
    case multipleDestinations
    case recipientUncertain
    case multipleUnits
    case partialMatch
    case streetLevelOnly
    case postalAreaOnly
    case municipalityOnly
    case regionConflict
    case notFound
    case ambiguousResults
    case notVerifiedOffline
    case providerUnavailable
    case barcodePostalConflict
    case syntheticLocation
    case possibleDuplicate

    public var explanation: String {
        switch self {
        case .lowRecognition: return "Parts of the label were hard to read."
        case .uncertainCharacters: return "Some characters could be read more than one way (for example 0/O or 1/I)."
        case .missingCivicNumber: return "The street number is missing or unreadable. A postal code alone is not a delivery location."
        case .missingStreet: return "The street name is missing."
        case .missingMunicipality: return "The city is missing."
        case .missingProvince: return "The province is missing."
        case .missingPostalCode: return "The postal code is missing."
        case .invalidPostalCode: return "The postal code is not in a valid Canadian format."
        case .postalProvinceConflict: return "The postal code and province don't belong together."
        case .poBox: return "PO box — there is no street location to drive to."
        case .ruralRoute: return "Rural route — confirm or pin the exact location."
        case .generalDelivery: return "General delivery — held at a post office."
        case .nonCanadian: return "The address doesn't look Canadian."
        case .multipleDestinations: return "More than one possible delivery address was found on the label."
        case .recipientUncertain: return "The label has no SHIP TO / DESTINATAIRE heading, so the recipient could not be confirmed."
        case .multipleUnits: return "More than one unit number was found."
        case .partialMatch: return "The map result differs from the label."
        case .streetLevelOnly: return "Only the street could be found, not the building."
        case .postalAreaOnly: return "Only the postal code area could be found. That is not precise enough to deliver to."
        case .municipalityOnly: return "Only the city could be found."
        case .regionConflict: return "The map result is in a different province or country."
        case .notFound: return "No matching address was found."
        case .ambiguousResults: return "More than one building matched."
        case .notVerifiedOffline: return "Saved while offline. The address will be verified when you're back online."
        case .providerUnavailable: return "Address verification is unavailable right now."
        case .barcodePostalConflict: return "The postal code in the barcode differs from the printed one."
        case .syntheticLocation: return "Demo mode: the location is synthetic and has not been verified."
        case .possibleDuplicate: return "This label looks like one you already scanned."
        }
    }
}

/// State of online resolution when the decision is made.
public enum ResolutionState: Hashable, Sendable {
    case resolved(MatchAssessment)
    case offline
    case unavailable(String)
}

public struct ReviewDecision: Hashable, Sendable {
    /// Safe to add without the driver looking at it (batch mode).
    public var autoAcceptable: Bool
    public var reasons: [ReviewReason]
    /// Status the stop gets if the driver adds it as-is.
    public var statusIfAdded: AddressStatus
}

public enum ReviewPolicy {
    /// - Parameters:
    ///   - parsed: The address text (scanned or typed).
    ///   - recognition: OCR quality; nil for typed/imported addresses.
    ///   - uncertainFields: Fields with conflicting OCR readings.
    ///   - roleCertain: The recipient block was identified by a heading (always true for typed input).
    ///   - multipleDestinations: The label offered several plausible destinations.
    ///   - barcodePostalCode: Ship-to postal code from a GS1 barcode, if any.
    ///   - resolution: Outcome of online resolution.
    ///   - allowSyntheticAcceptance: Demo mode — synthetic results may be added (labelled as such).
    public static func evaluate(
        parsed: ParsedAddress,
        recognition: RecognitionLevel?,
        uncertainFields: [AddressField] = [],
        roleCertain: Bool = true,
        multipleDestinations: Bool = false,
        barcodePostalCode: String? = nil,
        resolution: ResolutionState,
        allowSyntheticAcceptance: Bool = false
    ) -> ReviewDecision {
        var reasons: [ReviewReason] = []
        func add(_ r: ReviewReason) { if !reasons.contains(r) { reasons.append(r) } }

        if let recognition, recognition == .low { add(.lowRecognition) }
        if !uncertainFields.isEmpty { add(.uncertainCharacters) }
        if !roleCertain { add(.recipientUncertain) }
        if multipleDestinations { add(.multipleDestinations) }

        for issue in parsed.issues {
            switch issue {
            case .missingCivicNumber, .uncertainCivicNumber: add(.missingCivicNumber)
            case .missingStreet: add(.missingStreet)
            case .missingMunicipality: add(.missingMunicipality)
            case .missingProvince: add(.missingProvince)
            case .missingPostalCode: add(.missingPostalCode)
            case .invalidPostalCode: add(.invalidPostalCode)
            case .uncertainPostalCode: add(.uncertainCharacters)
            case .postalProvinceConflict: add(.postalProvinceConflict)
            case .poBox: add(.poBox)
            case .ruralRoute: add(.ruralRoute)
            case .generalDelivery: add(.generalDelivery)
            case .nonCanadianCountry: add(.nonCanadian)
            case .multipleUnitCandidates: add(.multipleUnits)
            case .unparsedLines: break
            }
        }
        if let barcodePostalCode, let printed = parsed.address.validPostalCode, printed.value != barcodePostalCode {
            add(.barcodePostalConflict)
        }
        if let code = parsed.address.validPostalCode, code.isRuralFSA, parsed.address.civicNumber == nil {
            add(.ruralRoute)
        }

        var status: AddressStatus = .needsReview
        switch resolution {
        case .offline:
            add(.notVerifiedOffline)
            status = .pendingVerification
        case .unavailable:
            add(.providerUnavailable)
            status = .pendingVerification
        case let .resolved(assessment):
            switch assessment.quality {
            case .building:
                if assessment.ambiguous { add(.ambiguousResults) }
            case .buildingWithDifferences: add(.partialMatch)
            case .street: add(.streetLevelOnly)
            case .postalArea: add(.postalAreaOnly)
            case .municipality: add(.municipalityOnly)
            case .conflict: add(.regionConflict)
            case .notFound: add(.notFound)
            case .synthetic: add(.syntheticLocation)
            case .driverPin: break
            }
            if assessment.quality == .notFound { status = .unresolvable }
        }

        // Demo mode: a synthetic location is the *only* allowed reason when synthetic acceptance is on.
        let blocking = reasons.filter { !(allowSyntheticAcceptance && $0 == .syntheticLocation) }
        let autoAcceptable = blocking.isEmpty
        if autoAcceptable {
            if case let .resolved(a) = resolution, a.quality == .synthetic { status = .demoSynthetic } else { status = .verified }
        }
        return ReviewDecision(autoAcceptable: autoAcceptable, reasons: reasons, statusIfAdded: status)
    }
}
