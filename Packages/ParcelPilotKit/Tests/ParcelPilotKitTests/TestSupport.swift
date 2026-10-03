import CoreGraphics
import Foundation
import ImageIO
@testable import ParcelPilotKit

enum Fixtures {
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // ParcelPilotKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // ParcelPilotKit
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // repo root

    static func labelImage(_ name: String) throws -> CGImage {
        let url = repoRoot.appendingPathComponent("fixtures/labels/\(name).png")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw FixtureError.missing(url.path)
        }
        return image
    }

    static func sharedJSON(_ name: String) throws -> Data {
        try Data(contentsOf: repoRoot.appendingPathComponent("fixtures/shared/\(name)"))
    }

    enum FixtureError: Error { case missing(String) }
}

/// Builds an OCR page from lines laid out top to bottom, for parser-level tests without images.
func page(_ blocks: [(x: Double, y: Double, lines: [String])], lineHeight: Double = 0.03, confidence: Double = 1.0) -> OCRPage {
    var lines: [OCRLine] = []
    var id = 0
    for block in blocks {
        for (i, text) in block.lines.enumerated() {
            lines.append(OCRLine(id: id, text: text, confidence: confidence, box: OCRBox(x: block.x, y: block.y + Double(i) * lineHeight * 1.3, width: min(0.9 - block.x, Double(text.count) * 0.018), height: lineHeight)))
            id += 1
        }
    }
    return OCRPage(lines: lines, languages: ["en-US", "fr-FR"])
}

func makeRoute(stops: Int = 0, date: String = "2026-10-05", tz: String = "America/Vancouver") -> Route {
    var route = Route(name: "Test", serviceDate: date, timeZoneID: tz, departureMinute: 8 * 60, now: Date(timeIntervalSince1970: 1_790_000_000))
    route.start = RoutePlace(label: "Depot", located: LocatedPoint(point: GeoPoint(latitude: 48.4284, longitude: -123.3656), source: .driverPin))
    return route
}

func makeStop(_ n: Int, lat: Double, lng: Double, status: AddressStatus = .demoSynthetic, sequence: Double? = nil) -> Stop {
    let address = PostalAddress(civicNumber: "\(100 + n)", streetName: "EXAMPLE ST", municipality: "VICTORIA", province: .BC, postalCode: "V8W 1A1")
    var stop = Stop(id: "stop-\(n)", address: address, addressStatus: status, sequence: sequence ?? Double(n), now: Date(timeIntervalSince1970: 1_790_000_000))
    stop.resolution = StopResolution(provider: .demo, placeID: nil, located: LocatedPoint(point: GeoPoint(latitude: lat, longitude: lng), source: .demoSynthetic), match: .synthetic, resolvedAt: Date(timeIntervalSince1970: 1_790_000_000))
    return stop
}
