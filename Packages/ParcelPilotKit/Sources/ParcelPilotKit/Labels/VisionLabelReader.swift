#if canImport(Vision)
import CoreGraphics
import Foundation
import ImageIO
import Vision

/// On-device OCR and barcode detection with Apple's Vision framework. Nothing leaves the device.
public struct VisionLabelReader: Sendable {
    public init() {}

    /// Process-wide one-time warm-up (used by tests and the scanner).
    public static let warmUpOnce: Void = VisionLabelReader().prewarm()

    /// Recognition languages requested, limited to what this device's Vision revision supports.
    public static func supportedLanguages() -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = (try? request.supportedRecognitionLanguages()) ?? ["en-US"]
        let wanted = ["en-US", "fr-FR", "en-CA", "fr-CA"]
        let chosen = wanted.filter { supported.contains($0) }
        return chosen.isEmpty ? ["en-US"] : chosen
    }

    public func recognizeText(in image: CGImage, orientation: CGImagePropertyOrientation = .up) throws -> OCRPage {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Language correction can "fix" street names and postal codes into dictionary words, so it is
        // off; alternatives are inspected instead.
        request.usesLanguageCorrection = false
        let languages = Self.supportedLanguages()
        request.recognitionLanguages = languages
        request.minimumTextHeight = 0.012
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        var lines: [OCRLine] = []
        for (i, obs) in observations.enumerated() {
            let candidates = obs.topCandidates(3)
            guard let best = candidates.first else { continue }
            let b = obs.boundingBox // normalized, origin bottom-left
            lines.append(OCRLine(
                id: i,
                text: OCRText.normalizeConfusableScripts(best.string),
                confidence: Double(best.confidence),
                box: OCRBox(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height),
                alternatives: candidates.dropFirst().map { OCRText.normalizeConfusableScripts($0.string) }.filter { $0 != OCRText.normalizeConfusableScripts(best.string) }
            ))
        }
        return OCRPage(lines: lines, languages: languages)
    }

    /// Loads the recognition model ahead of the first capture (the first request in a process can
    /// take far longer than later ones). Call from a background task when the scanner opens.
    public func prewarm() {
        let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        guard let ctx else { return }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        guard let image = ctx.makeImage() else { return }
        _ = try? recognizeText(in: image)
    }

    public func detectBarcodes(in image: CGImage, orientation: CGImagePropertyOrientation = .up) throws -> [DetectedBarcode] {
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        try handler.perform([request])
        return (request.results ?? []).compactMap { obs in
            guard let payload = obs.payloadStringValue, !payload.isEmpty else { return nil }
            let b = obs.boundingBox
            return DetectedBarcode(payload: payload, symbology: obs.symbology.rawValue, box: OCRBox(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
        }
    }
}

/// Full captured-image pipeline: quality check → OCR (trying rotations when needed) → barcodes →
/// label analysis. The image and the OCR text are kept in memory only.
public struct LabelImagePipeline: Sendable {
    public struct Result: Sendable {
        public var analysis: LabelAnalysis
        public var quality: ImageQualityReport
        public var orientationUsed: CGImagePropertyOrientation
        public var lineCount: Int
    }

    let reader = VisionLabelReader()

    public init() {}

    public func process(_ image: CGImage, orientation: CGImagePropertyOrientation = .up) throws -> Result {
        let quality = ImageQualityAnalyzer.analyze(image)
        let barcodes = (try? reader.detectBarcodes(in: image, orientation: orientation)) ?? []
        var best: (LabelAnalysis, CGImagePropertyOrientation, Int)?
        // Labels are often photographed sideways. Rotations are tried only when the capture
        // orientation yields no coherent address, because a sideways read of an upright label can
        // produce plausible-looking nonsense.
        let attempts: [CGImagePropertyOrientation] = [orientation] + [.right, .left, .down].map { rotate(orientation, by: $0) }
        for attempt in attempts {
            let page = try reader.recognizeText(in: image, orientation: attempt)
            let analysis = LabelAnalyzer.analyze(page: page, barcodes: barcodes)
            if best == nil || Self.score(analysis) > Self.score(best!.0) { best = (analysis, attempt, page.lines.count) }
            if Self.score(best!.0) >= 3 { break }
        }
        let chosen = best!
        return Result(analysis: chosen.0, quality: quality, orientationUsed: chosen.1, lineCount: chosen.2)
    }

    /// Higher is better: number of address fields present in the best candidate, plus a bonus for a
    /// recipient heading. A garbled read has few fields and cannot outrank a clean upright one.
    static func score(_ a: LabelAnalysis) -> Int {
        let best = a.candidates.map { c -> Int in
            let x = c.address
            var fields = 0
            if x.civicNumber != nil || c.parsed.issues.contains(where: { if case .uncertainCivicNumber = $0 { return true }; return false }) { fields += 1 }
            if x.streetName != nil || x.deliveryInstallation != nil { fields += 1 }
            if x.municipality != nil { fields += 1 }
            if x.province != nil { fields += 1 }
            if let reading = c.parsed.postalReading, reading.validCode != nil || { if case .uncertain = reading { return true }; return false }() { fields += 1 }
            // A single merged line holding a whole block is a sign of a sideways read.
            if c.rawLines.count == 1, c.rawLines[0].split(separator: " ").count > 8 { fields -= 2 }
            return fields
        }.max() ?? 0
        return best + (a.barcodeAddress != nil ? 5 : 0)
    }

    func rotate(_ base: CGImagePropertyOrientation, by extra: CGImagePropertyOrientation) -> CGImagePropertyOrientation {
        // Quarter-turn arithmetic on the four upright orientations.
        let order: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
        guard let a = order.firstIndex(of: base), let b = order.firstIndex(of: extra) else { return extra }
        return order[(a + b) % 4]
    }
}
#endif
