import Foundation

/// Canadian provinces and territories (Canada Post two-letter symbols).
public enum Province: String, Codable, CaseIterable, Hashable, Sendable {
    case NL, PE, NS, NB, QC, ON, MB, SK, AB, BC, YT, NT, NU

    public var englishName: String {
        switch self {
        case .NL: return "Newfoundland and Labrador"
        case .PE: return "Prince Edward Island"
        case .NS: return "Nova Scotia"
        case .NB: return "New Brunswick"
        case .QC: return "Quebec"
        case .ON: return "Ontario"
        case .MB: return "Manitoba"
        case .SK: return "Saskatchewan"
        case .AB: return "Alberta"
        case .BC: return "British Columbia"
        case .YT: return "Yukon"
        case .NT: return "Northwest Territories"
        case .NU: return "Nunavut"
        }
    }

    public var frenchName: String {
        switch self {
        case .NL: return "Terre-Neuve-et-Labrador"
        case .PE: return "Île-du-Prince-Édouard"
        case .NS: return "Nouvelle-Écosse"
        case .NB: return "Nouveau-Brunswick"
        case .QC: return "Québec"
        case .ON: return "Ontario"
        case .MB: return "Manitoba"
        case .SK: return "Saskatchewan"
        case .AB: return "Alberta"
        case .BC: return "Colombie-Britannique"
        case .YT: return "Yukon"
        case .NT: return "Territoires du Nord-Ouest"
        case .NU: return "Nunavut"
        }
    }

    /// First letters of postal codes assigned to the province/territory.
    public var postalFirstLetters: Set<Character> {
        switch self {
        case .NL: return ["A"]
        case .NS: return ["B"]
        case .PE: return ["C"]
        case .NB: return ["E"]
        case .QC: return ["G", "H", "J"]
        case .ON: return ["K", "L", "M", "N", "P"]
        case .MB: return ["R"]
        case .SK: return ["S"]
        case .AB: return ["T"]
        case .BC: return ["V"]
        case .NT, .NU: return ["X"]
        case .YT: return ["Y"]
        }
    }

    /// Suggested default route time zone (drivers can change it; several provinces span zones).
    public var suggestedTimeZoneIdentifier: String {
        switch self {
        case .NL: return "America/St_Johns"
        case .PE, .NS, .NB: return "America/Halifax"
        case .QC, .ON: return "America/Toronto"
        case .MB: return "America/Winnipeg"
        case .SK: return "America/Regina"
        case .AB: return "America/Edmonton"
        case .BC: return "America/Vancouver"
        case .YT: return "America/Whitehorse"
        case .NT: return "America/Yellowknife"
        case .NU: return "America/Iqaluit"
        }
    }

    public static func forPostalFirstLetter(_ letter: Character) -> [Province] {
        allCases.filter { $0.postalFirstLetters.contains(letter) }
    }

    /// Recognises symbols, English/French names and common abbreviations. Matching ignores case,
    /// accents and punctuation but the original text is never rewritten by this lookup.
    public static func match(_ raw: String) -> Province? {
        let key = AddressText.foldForMatching(raw).replacingOccurrences(of: " ", with: "")
        guard !key.isEmpty else { return nil }
        return aliasTable[key]
    }

    static let aliasTable: [String: Province] = {
        var table: [String: Province] = [:]
        func add(_ province: Province, _ aliases: [String]) {
            for alias in aliases {
                table[AddressText.foldForMatching(alias).replacingOccurrences(of: " ", with: "")] = province
            }
        }
        add(.NL, ["NL", "NF", "NFLD", "NEWFOUNDLAND", "NEWFOUNDLAND AND LABRADOR", "TERRE-NEUVE-ET-LABRADOR", "TNL", "T.-N.-L."])
        add(.PE, ["PE", "PEI", "P.E.I.", "PRINCE EDWARD ISLAND", "ILE-DU-PRINCE-EDOUARD", "IPE", "Î.-P.-É."])
        add(.NS, ["NS", "N.S.", "NOVA SCOTIA", "NOUVELLE-ECOSSE"])
        add(.NB, ["NB", "N.B.", "NEW BRUNSWICK", "NOUVEAU-BRUNSWICK", "N.-B."])
        add(.QC, ["QC", "QUE", "QUÉ", "PQ", "P.Q.", "QUEBEC", "QUÉBEC"])
        add(.ON, ["ON", "ONT", "ONTARIO"])
        add(.MB, ["MB", "MAN", "MANITOBA"])
        add(.SK, ["SK", "SASK", "SASKATCHEWAN"])
        add(.AB, ["AB", "ALTA", "ALBERTA"])
        add(.BC, ["BC", "B.C.", "BRITISH COLUMBIA", "COLOMBIE-BRITANNIQUE", "CB", "C.-B."])
        add(.YT, ["YT", "YK", "YUKON"])
        add(.NT, ["NT", "NWT", "N.W.T.", "NORTHWEST TERRITORIES", "TERRITOIRES DU NORD-OUEST", "TNO", "T.N.-O."])
        add(.NU, ["NU", "NUNAVUT"])
        return table
    }()
}
