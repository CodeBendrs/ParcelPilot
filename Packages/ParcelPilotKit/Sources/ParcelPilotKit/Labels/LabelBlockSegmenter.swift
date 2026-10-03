import Foundation

/// A spatially coherent group of OCR lines (e.g. the SHIP TO block of a label).
public struct TextBlock: Hashable, Sendable {
    public var lines: [OCRLine]
    public var box: OCRBox

    public var texts: [String] { lines.map(\.text) }
    public var medianLineHeight: Double {
        let heights = lines.map(\.box.height).sorted()
        return heights.isEmpty ? 0 : heights[heights.count / 2]
    }
}

/// Groups OCR lines into blocks using vertical proximity and horizontal overlap. Lines that sit side
/// by side with a large gap (a FROM column next to a TO column) end up in different blocks.
public enum LabelBlockSegmenter {
    public static func segment(_ input: [OCRLine]) -> [TextBlock] {
        let lines = mergeSameBaselineFragments(input).filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return [] }
        let heights = lines.map(\.box.height).sorted()
        let typicalHeight = max(heights[heights.count / 2], 0.005)

        // Union-find over line pairs that belong together.
        var parent = Array(0..<lines.count)
        func find(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        func union(_ a: Int, _ b: Int) { let ra = find(a), rb = find(b); if ra != rb { parent[rb] = ra } }

        for i in 0..<lines.count {
            for j in (i + 1)..<lines.count {
                let a = lines[i].box, b = lines[j].box
                let upper = a.minY <= b.minY ? a : b
                let lower = a.minY <= b.minY ? b : a
                let gap = lower.minY - upper.maxY
                let lineHeight = max(min(a.height, b.height), typicalHeight * 0.6)
                let overlap = a.horizontalOverlap(with: b)
                let narrower = min(a.width, b.width)
                let leftAligned = abs(a.minX - b.minX) < max(typicalHeight * 1.5, 0.02)
                let horizontallyRelated = overlap > narrower * 0.3 || leftAligned
                if gap < lineHeight * 1.25, gap > -lineHeight * 0.5, horizontallyRelated {
                    union(i, j)
                }
            }
        }

        var groups: [Int: [OCRLine]] = [:]
        for i in 0..<lines.count { groups[find(i), default: []].append(lines[i]) }
        return groups.values.map { group in
            let sorted = group.sorted { $0.box.minY != $1.box.minY ? $0.box.minY < $1.box.minY : $0.box.minX < $1.box.minX }
            let box = sorted.dropFirst().reduce(sorted[0].box) { $0.union($1.box) }
            return TextBlock(lines: sorted, box: box)
        }
        .sorted { $0.box.minY != $1.box.minY ? $0.box.minY < $1.box.minY : $0.box.minX < $1.box.minX }
    }

    /// Vision sometimes splits one printed line ("VICTORIA BC" … "V8W 1A1") into fragments on the same
    /// baseline. Fragments with strong vertical overlap and a modest horizontal gap are joined.
    static func mergeSameBaselineFragments(_ lines: [OCRLine]) -> [OCRLine] {
        var remaining = lines.sorted { $0.box.minX < $1.box.minX }
        var result: [OCRLine] = []
        while !remaining.isEmpty {
            var current = remaining.removeFirst()
            var merged = true
            while merged {
                merged = false
                if let idx = remaining.firstIndex(where: { other in
                    let vOverlap = current.box.verticalOverlap(with: other.box)
                    let minHeight = min(current.box.height, other.box.height)
                    let gap = other.box.minX - current.box.maxX
                    return vOverlap > minHeight * 0.6 && gap >= -minHeight && gap < minHeight * 2.5
                }) {
                    let other = remaining.remove(at: idx)
                    current = OCRLine(
                        id: current.id,
                        text: current.text + " " + other.text,
                        confidence: min(current.confidence, other.confidence),
                        box: current.box.union(other.box),
                        alternatives: current.alternatives.map { $0 + " " + other.text }
                            + other.alternatives.map { current.text + " " + $0 }
                    )
                    merged = true
                }
            }
            result.append(current)
        }
        return result
    }
}
