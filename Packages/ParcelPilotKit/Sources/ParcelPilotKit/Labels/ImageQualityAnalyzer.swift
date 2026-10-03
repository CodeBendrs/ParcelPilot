import CoreGraphics
import Foundation

/// Cheap capture-quality hints shown to the driver ("hold steady", "tilt to avoid glare"). These
/// are guidance only; acceptance decisions use recognition, completeness and match signals.
public struct ImageQualityReport: Hashable, Sendable {
    /// Variance of the Laplacian on a downscaled grayscale image (higher = sharper).
    public var sharpness: Double
    /// Fraction of pixels that are clipped highlights.
    public var highlightFraction: Double
    /// Mean luminance 0…1.
    public var meanLuminance: Double
    /// 75th-percentile luminance 0…1 — approximately the paper colour of the label.
    public var paperLuminance: Double

    public var isBlurry: Bool { sharpness < 60 }
    /// Clipped highlights that are clearly brighter than the paper itself (a reflection), as opposed
    /// to a white label that is simply well exposed.
    public var hasGlare: Bool { paperLuminance < 0.92 && highlightFraction > 0.01 }
    public var isDark: Bool { meanLuminance < 0.18 }

    public var hints: [String] {
        var h: [String] = []
        if isBlurry { h.append("The photo looks blurry. Hold the phone steady and move a little closer.") }
        if hasGlare { h.append("Glare detected. Tilt the package or the phone to avoid reflections.") }
        if isDark { h.append("The label is too dark. Turn on the light or move somewhere brighter.") }
        return h
    }
}

public enum ImageQualityAnalyzer {
    public static func analyze(_ image: CGImage) -> ImageQualityReport {
        let maxSide = 320
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let w = max(8, Int(Double(image.width) * scale))
        let h = max(8, Int(Double(image.height) * scale))
        var pixels = [UInt8](repeating: 0, count: w * h)
        let space = CGColorSpaceCreateDeviceGray()
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return ImageQualityReport(sharpness: 0, highlightFraction: 0, meanLuminance: 0, paperLuminance: 0) }

        var sum = 0.0, clipped = 0
        var histogram = [Int](repeating: 0, count: 256)
        for p in pixels { sum += Double(p); histogram[Int(p)] += 1; if p >= 250 { clipped += 1 } }
        let mean = sum / Double(pixels.count) / 255
        var cumulative = 0, p75 = 255
        for (level, count) in histogram.enumerated() {
            cumulative += count
            if cumulative >= pixels.count * 3 / 4 { p75 = level; break }
        }

        // Laplacian variance.
        var lapSum = 0.0, lapSq = 0.0, n = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let c = Double(pixels[y * w + x])
                let lap = Double(pixels[(y - 1) * w + x]) + Double(pixels[(y + 1) * w + x]) + Double(pixels[y * w + x - 1]) + Double(pixels[y * w + x + 1]) - 4 * c
                lapSum += lap; lapSq += lap * lap; n += 1
            }
        }
        let lapMean = lapSum / max(n, 1)
        let variance = lapSq / max(n, 1) - lapMean * lapMean
        return ImageQualityReport(sharpness: variance, highlightFraction: Double(clipped) / Double(pixels.count), meanLuminance: mean, paperLuminance: Double(p75) / 255)
    }
}
