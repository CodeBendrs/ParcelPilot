import Foundation

/// A syntactically valid Canadian postal code in `A1A 1A1` form.
///
/// A valid format is *not* evidence that the code exists or that an address is deliverable.
public struct CanadianPostalCode: Codable, Hashable, Sendable, CustomStringConvertible {
    public let value: String

    public var description: String { value }
    public var compact: String { value.replacingOccurrences(of: " ", with: "") }
    /// Forward sortation area (first three characters).
    public var fsa: String { String(value.prefix(3)) }
    public var firstLetter: Character { value.first! }
    public var provinces: [Province] { Province.forPostalFirstLetter(firstLetter) }
    /// A `0` in the second position indicates a rural FSA.
    public var isRuralFSA: Bool { value.dropFirst().first == "0" }

    static let firstLetters: Set<Character> = Set("ABCEGHJKLMNPRSTVXY")
    static let otherLetters: Set<Character> = Set("ABCEGHJKLMNPRSTVWXYZ")

    /// Strict initialiser: accepts only text that is already a valid code after removing one optional
    /// space or hyphen and uppercasing. Never substitutes characters.
    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        var chars = Array(trimmed)
        if chars.count == 7, chars[3] == " " || chars[3] == "-" { chars.remove(at: 3) }
        guard chars.count == 6, Self.isValid(chars) else { return nil }
        value = String(chars[0..<3]) + " " + String(chars[3..<6])
    }

    static func isValid(_ c: [Character]) -> Bool {
        guard c.count == 6 else { return false }
        return firstLetters.contains(c[0]) && c[1].isASCIIDigit && otherLetters.contains(c[2])
            && c[3].isASCIIDigit && otherLetters.contains(c[4]) && c[5].isASCIIDigit
    }
}

extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
    var isASCIILetter: Bool { ("A"..."Z").contains(self) || ("a"..."z").contains(self) }
}

/// Result of looking for a postal code in OCR or typed text.
public enum PostalCodeReading: Hashable, Sendable {
    /// The characters as read form a valid code.
    case valid(CanadianPostalCode, raw: String)
    /// The characters do not form a valid code, but swapping commonly confused OCR characters would.
    /// The suggestion must be confirmed by the driver; it is never applied automatically.
    case uncertain(raw: String, suggestion: CanadianPostalCode)
    /// Something postal-code shaped that cannot be made valid.
    case invalid(raw: String)

    public var validCode: CanadianPostalCode? {
        if case let .valid(code, _) = self { return code }
        return nil
    }

    public var raw: String {
        switch self {
        case let .valid(_, raw), let .uncertain(raw, _), let .invalid(raw): return raw
        }
    }
}

public enum PostalCodeScanner {
    // Letter-digit pattern allowing a single optional space/hyphen in the middle.
    private static let strict = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9])([A-Za-z][0-9][A-Za-z])[ -]?([0-9][A-Za-z][0-9])(?![A-Za-z0-9])")
    // Six alphanumerics in a 3+3 shape (possible OCR confusions).
    private static let loose = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9])([A-Za-z0-9]{3})[ -]?([A-Za-z0-9]{3})(?![A-Za-z0-9])")

    static let toDigit: [Character: Character] = ["O": "0", "Q": "0", "D": "0", "I": "1", "L": "1", "Z": "2", "S": "5", "B": "8", "G": "6", "T": "7"]
    static let toLetter: [Character: Character] = ["0": "O", "1": "I", "2": "Z", "5": "S", "8": "B", "6": "G", "7": "T", "4": "A"]

    /// Finds the last postal-code-like token in the text (destination postal codes are at the end of
    /// the locality line). Returns nil when nothing postal-shaped is present.
    public static func read(in text: String) -> PostalCodeReading? {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let match = strict.matches(in: text, range: range).last {
            let raw = ns.substring(with: match.range)
            if let code = CanadianPostalCode(raw) { return .valid(code, raw: raw) }
            // Shape is right but letters are not allowed in Canadian codes (e.g. D, F, I, O, Q, U).
            return .invalid(raw: raw)
        }
        for match in loose.matches(in: text, range: range).reversed() {
            let raw = ns.substring(with: match.range)
            let compact = raw.uppercased().filter { $0.isASCIIDigit || $0.isASCIILetter }
            guard compact.count == 6 else { continue }
            let chars = Array(compact)
            // Require at least four characters already in the right class so ordinary words and
            // civic numbers are not mistaken for postal codes.
            let pattern: [Bool] = [true, false, true, false, true, false] // true = letter expected
            let alreadyCorrect = zip(chars, pattern).filter { $1 ? $0.isASCIILetter : $0.isASCIIDigit }.count
            guard alreadyCorrect >= 4, alreadyCorrect < 6 else { continue }
            var fixed = chars
            var possible = true
            for i in 0..<6 {
                if pattern[i], !fixed[i].isASCIILetter {
                    if let l = toLetter[fixed[i]] { fixed[i] = l } else { possible = false }
                } else if !pattern[i], !fixed[i].isASCIIDigit {
                    if let d = toDigit[fixed[i]] { fixed[i] = d } else { possible = false }
                }
            }
            if possible, let suggestion = CanadianPostalCode(String(fixed)) {
                return .uncertain(raw: raw, suggestion: suggestion)
            }
        }
        return nil
    }
}
