import Foundation

/// Text helpers shared by parsing, matching and destination keys.
///
/// Folding (removing accents, case and punctuation) is only ever used to *compare* text. Stored and
/// displayed address text keeps the characters the driver confirmed, including French accents.
public enum AddressText {
    public static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    public static func foldForMatching(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_CA"))
            .uppercased()
        var out = ""
        out.reserveCapacity(folded.count)
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else {
                out.append(" ")
            }
        }
        return collapseWhitespace(out)
    }

    /// Levenshtein distance for short strings (street names). O(n·m).
    public static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// Canonical street-type and direction tokens (English and French) for comparison keys.
    static let streetTokenCanonical: [String: String] = [
        "STREET": "ST", "STR": "ST", "ST": "ST",
        "AVENUE": "AVE", "AV": "AVE", "AVE": "AVE",
        "ROAD": "RD", "RD": "RD",
        "DRIVE": "DR", "DR": "DR",
        "BOULEVARD": "BLVD", "BOUL": "BLVD", "BLVD": "BLVD", "BL": "BLVD",
        "CRESCENT": "CRES", "CRES": "CRES", "CR": "CRES", "CROISSANT": "CROIS", "CROIS": "CROIS",
        "COURT": "CRT", "CRT": "CRT", "CT": "CRT",
        "PLACE": "PL", "PL": "PL",
        "LANE": "LANE", "LN": "LANE",
        "TERRACE": "TERR", "TERR": "TERR", "TER": "TERR",
        "HIGHWAY": "HWY", "HWY": "HWY",
        "PARKWAY": "PKY", "PKWY": "PKY", "PKY": "PKY",
        "CIRCLE": "CIR", "CIR": "CIR",
        "TRAIL": "TRAIL", "TRL": "TRAIL",
        "SQUARE": "SQ", "SQ": "SQ",
        "HEIGHTS": "HTS", "HTS": "HTS",
        "CONCESSION": "CONC", "CONC": "CONC",
        "CHEMIN": "CH", "CH": "CH",
        "PROMENADE": "PROM", "PROM": "PROM",
        "RUE": "RUE", "RANG": "RANG", "ROUTE": "RTE", "RTE": "RTE",
        "MONTEE": "MONTEE", "COTE": "COTE", "ALLEE": "ALLEE", "IMPASSE": "IMP", "IMP": "IMP",
        "NORTH": "N", "NORD": "N", "N": "N",
        "SOUTH": "S", "SUD": "S", "S": "S",
        "EAST": "E", "EST": "E", "E": "E",
        "WEST": "W", "OUEST": "W", "W": "W", "O": "W",
        "SAINT": "ST", "SAINTE": "STE", "STE": "STE",
    ]

    /// Street-type words used to recognise a street line. Includes French types that precede the name.
    static let streetTypeWords: Set<String> = [
        "ST", "STREET", "AVE", "AVENUE", "AV", "RD", "ROAD", "DR", "DRIVE", "BLVD", "BOULEVARD", "BOUL",
        "CRES", "CRESCENT", "CRT", "COURT", "CT", "PL", "PLACE", "WAY", "LANE", "LN", "TERR", "TERRACE",
        "HWY", "HIGHWAY", "PKY", "PKWY", "PARKWAY", "CIR", "CIRCLE", "TRAIL", "TRL", "SQ", "SQUARE", "GATE",
        "GROVE", "GR", "HTS", "HEIGHTS", "LINE", "SIDEROAD", "SDRD", "CONC", "CONCESSION", "CHEMIN", "CH",
        "RUE", "RANG", "ROUTE", "RTE", "MONTEE", "COTE", "PROMENADE", "PROM", "ALLEE", "IMPASSE", "CARRE",
        "CROISSANT", "CROIS", "BAY", "CLOSE", "COMMON", "LANDING", "MEWS", "PATH", "POINT", "RIDGE",
        "ROW", "VIEW", "WALK", "PARK", "ESPLANADE", "QUAI", "RUELLE", "SENTIER", "CIRCUIT", "VOIE",
    ]

    /// Comparison key for a street name, e.g. "rue Sainte-Catherine Ouest" → "RUE STE CATHERINE W".
    public static func streetKey(_ street: String) -> String {
        foldForMatching(street)
            .split(separator: " ")
            .map { streetTokenCanonical[String($0)] ?? String($0) }
            .joined(separator: " ")
    }

    public static func unitKey(_ unit: String) -> String {
        let folded = foldForMatching(unit).replacingOccurrences(of: " ", with: "")
        return folded
    }

    public static func civicKey(_ civic: String) -> String {
        foldForMatching(civic).replacingOccurrences(of: " ", with: "")
    }
}
