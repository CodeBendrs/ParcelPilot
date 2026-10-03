import Foundation

/// Normalized rectangle (0…1) with the origin at the **top-left** of the image.
public struct OCRBox: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var minX: Double { x }
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var maxY: Double { y + height }
    public var midY: Double { y + height / 2 }

    public func union(_ o: OCRBox) -> OCRBox {
        let nx = min(minX, o.minX), ny = min(minY, o.minY)
        return OCRBox(x: nx, y: ny, width: max(maxX, o.maxX) - nx, height: max(maxY, o.maxY) - ny)
    }

    func horizontalOverlap(with o: OCRBox) -> Double {
        max(0, min(maxX, o.maxX) - max(minX, o.minX))
    }

    func verticalOverlap(with o: OCRBox) -> Double {
        max(0, min(maxY, o.maxY) - max(minY, o.minY))
    }
}

/// One recognised line of text. Confidence is the recognizer's own score (0…1); it is a
/// recognition signal only and is not a probability that the address is correct.
public struct OCRLine: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var text: String
    public var confidence: Double
    public var box: OCRBox
    /// Lower-ranked transcriptions from the recognizer, used to detect uncertain characters.
    public var alternatives: [String]

    public init(id: Int, text: String, confidence: Double, box: OCRBox, alternatives: [String] = []) {
        self.id = id; self.text = text; self.confidence = confidence; self.box = box; self.alternatives = alternatives
    }
}

public struct OCRPage: Sendable, Hashable {
    public var lines: [OCRLine]
    /// Recognition languages actually used (device-supported subset of en/fr).
    public var languages: [String]

    public init(lines: [OCRLine], languages: [String] = []) {
        self.lines = lines; self.languages = languages
    }
}

public struct DetectedBarcode: Codable, Hashable, Sendable {
    public var payload: String
    public var symbology: String
    public var box: OCRBox?

    public init(payload: String, symbology: String, box: OCRBox? = nil) {
        self.payload = payload; self.symbology = symbology; self.box = box
    }
}

/// Coarse recognition level shown to drivers. Derived from recognizer scores, labelled as such.
public enum RecognitionLevel: String, Codable, Hashable, Sendable, Comparable {
    case low, medium, high

    public static func from(score: Double) -> RecognitionLevel {
        if score >= 0.85 { return .high }
        if score >= 0.5 { return .medium }
        return .low
    }

    public static func < (a: RecognitionLevel, b: RecognitionLevel) -> Bool {
        let order: [RecognitionLevel] = [.low, .medium, .high]
        return order.firstIndex(of: a)! < order.firstIndex(of: b)!
    }

    public var label: String {
        switch self {
        case .high: return "Clear text"
        case .medium: return "Some unclear text"
        case .low: return "Hard to read"
        }
    }
}

public enum OCRText {
    /// Recognizers occasionally return Cyrillic or Greek letters that are visually identical to Latin
    /// ones (e.g. "ВС" for "BC"). Canadian address text is Latin script, so these exact look-alikes are
    /// mapped back. Accented Latin letters (é, è, ç, ô…) are untouched, and no Latin character is ever
    /// substituted for another.
    public static func normalizeConfusableScripts(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { (0x0370...0x03FF).contains($0.value) || (0x0400...0x04FF).contains($0.value) }) else { return s }
        return String(String.UnicodeScalarView(s.unicodeScalars.map { confusables[$0] ?? $0 }))
    }

    static let confusables: [Unicode.Scalar: Unicode.Scalar] = {
        let pairs: [(String, String)] = [
            // Cyrillic
            ("А", "A"), ("В", "B"), ("С", "C"), ("Е", "E"), ("Н", "H"), ("І", "I"), ("Ј", "J"), ("К", "K"),
            ("М", "M"), ("О", "O"), ("Р", "P"), ("Ѕ", "S"), ("Т", "T"), ("Х", "X"), ("У", "Y"),
            ("а", "a"), ("с", "c"), ("е", "e"), ("і", "i"), ("ј", "j"), ("о", "o"), ("р", "p"), ("ѕ", "s"), ("х", "x"), ("у", "y"),
            // Greek
            ("Α", "A"), ("Β", "B"), ("Ε", "E"), ("Ζ", "Z"), ("Η", "H"), ("Ι", "I"), ("Κ", "K"), ("Μ", "M"),
            ("Ν", "N"), ("Ο", "O"), ("Ρ", "P"), ("Τ", "T"), ("Υ", "Y"), ("Χ", "X"), ("ο", "o"),
        ]
        var map: [Unicode.Scalar: Unicode.Scalar] = [:]
        for (from, to) in pairs { map[from.unicodeScalars.first!] = to.unicodeScalars.first! }
        return map
    }()
}
