#!/usr/bin/env swift
// Generates synthetic shipping-label images for OCR tests.
//
//   swift scripts/generate-label-fixtures.swift
//
// Every address is fictional ("EXAMPLE ST", "ALEX TEST", …). The images are committed under
// fixtures/labels so tests are deterministic; rerun this script after changing a fixture.

import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let outDir = root.appendingPathComponent("fixtures/labels")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let width = 1200, height = 1600

struct Label {
    var name: String
    var draw: (CGContext, Canvas) -> Void
    var post: ((CGImage) -> CGImage)? = nil
}

final class Canvas {
    let ctx: CGContext
    init(_ ctx: CGContext) { self.ctx = ctx }

    /// Draws text with its top-left corner at (x, yTop) in a top-left coordinate system.
    func text(_ s: String, x: CGFloat, yTop: CGFloat, size: CGFloat, bold: Bool = false, gray: CGFloat = 0) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let color = CGColor(gray: gray, alpha: 1)
        let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        let ascent = CTFontGetAscent(font)
        ctx.textPosition = CGPoint(x: x, y: CGFloat(height) - yTop - ascent)
        CTLineDraw(line, ctx)
    }

    func lines(_ ls: [String], x: CGFloat, yTop: CGFloat, size: CGFloat, bold: Bool = false, spacing: CGFloat = 1.35) {
        for (i, l) in ls.enumerated() { text(l, x: x, yTop: yTop + CGFloat(i) * size * spacing, size: size, bold: bold) }
    }

    func rule(yTop: CGFloat) {
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 40, y: CGFloat(height) - yTop - 4, width: CGFloat(width) - 80, height: 4))
    }

    func box(x: CGFloat, yTop: CGFloat, w: CGFloat, h: CGFloat, gray: CGFloat = 0) {
        ctx.setFillColor(CGColor(gray: gray, alpha: 1))
        ctx.fill(CGRect(x: x, y: CGFloat(height) - yTop - h, width: w, height: h))
    }

    func image(_ img: CGImage, x: CGFloat, yTop: CGFloat, w: CGFloat, h: CGFloat) {
        ctx.interpolationQuality = .none
        ctx.draw(img, in: CGRect(x: x, y: CGFloat(height) - yTop - h, width: w, height: h))
    }
}

let ciContext = CIContext()

func barcode(_ payload: String, qr: Bool = false) -> CGImage {
    let filter = CIFilter(name: qr ? "CIQRCodeGenerator" : "CICode128BarcodeGenerator")!
    filter.setValue(payload.data(using: .ascii) ?? payload.data(using: .utf8)!, forKey: "inputMessage")
    if !qr { filter.setValue(10.0, forKey: "inputQuietSpace") } else { filter.setValue("M", forKey: "inputCorrectionLevel") }
    let output = filter.outputImage!
    return ciContext.createCGImage(output, from: output.extent)!
}

func blurred(_ img: CGImage, radius: Double) -> CGImage {
    let ci = CIImage(cgImage: img)
    let f = CIFilter(name: "CIGaussianBlur")!
    f.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
    f.setValue(radius, forKey: kCIInputRadiusKey)
    return ciContext.createCGImage(f.outputImage!, from: ci.extent)!
}

func rotated90(_ img: CGImage) -> CGImage {
    let ctx = CGContext(data: nil, width: img.height, height: img.width, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: CGFloat(img.height), y: 0)
    ctx.rotate(by: .pi / 2)
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return ctx.makeImage()!
}

func cropped(_ img: CGImage, keepTopFraction: Double) -> CGImage {
    img.cropping(to: CGRect(x: 0, y: 0, width: img.width, height: Int(Double(img.height) * keepTopFraction)))!
}

func withGlare(_ img: CGImage) -> CGImage {
    // A photo-like grey label with a bright specular reflection over the lower part of the address.
    let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    ctx.setFillColor(CGColor(gray: 0.25, alpha: 0.35))
    ctx.fill(CGRect(x: 0, y: 0, width: img.width, height: img.height))
    let colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0.95), CGColor(gray: 1, alpha: 0)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 0.55, 1])!
    let center = CGPoint(x: Double(img.width) * 0.7, y: Double(img.height) * 0.25)
    ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: 260, options: [])
    return ctx.makeImage()!
}

func render(_ label: Label) throws {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    // Label border.
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
    ctx.setLineWidth(6)
    ctx.stroke(CGRect(x: 20, y: 20, width: width - 40, height: height - 40))
    label.draw(ctx, Canvas(ctx))
    var image = ctx.makeImage()!
    if let post = label.post { image = post(image) }
    let url = outDir.appendingPathComponent("\(label.name).png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "fixtures", code: 1) }
    print("wrote \(url.lastPathComponent) (\(image.width)x\(image.height))")
}

let returnToronto = ["FROM:", "PARCEL SHOP TEST", "45 SAMPLE AVE", "TORONTO ON M5V 2T6"]
let shipToVictoria = ["ALEX TEST", "UNIT 204", "123 EXAMPLE ST", "VICTORIA BC V8W 1A1"]

let standardE1: (CGContext, Canvas) -> Void = { _, c in
    c.lines(returnToronto, x: 60, yTop: 60, size: 34)
    c.rule(yTop: 300)
    c.text("SHIP TO:", x: 60, yTop: 340, size: 44, bold: true)
    c.lines(shipToVictoria, x: 60, yTop: 410, size: 60, bold: true)
    c.rule(yTop: 780)
    c.text("TRACKING 1Z999AA10123456784", x: 60, yTop: 820, size: 34)
    c.image(barcode("1Z999AA10123456784"), x: 80, yTop: 880, w: 1040, h: 260)
    c.text("WEIGHT 2.3 KG   REF 4471", x: 60, yTop: 1200, size: 30)
}

let labels: [Label] = [
    // E1: Toronto return address + SHIP TO Victoria, unit 204.
    Label(name: "e1_victoria_unit204", draw: standardE1),
    // E1 variant: the return address has no heading at all.
    Label(name: "e1_unlabelled_return", draw: { _, c in
        c.lines(["PARCEL SHOP TEST", "45 SAMPLE AVE", "TORONTO ON M5V 2T6"], x: 60, yTop: 60, size: 30)
        c.rule(yTop: 260)
        c.text("SHIP TO", x: 60, yTop: 300, size: 44, bold: true)
        c.lines(shipToVictoria, x: 60, yTop: 370, size: 60, bold: true)
        c.image(barcode("1Z999AA10123456784"), x: 80, yTop: 860, w: 1040, h: 260)
    }),
    // E2: French label.
    Label(name: "e2_french_destinataire", draw: { _, c in
        c.text("EXPÉDITEUR :", x: 60, yTop: 60, size: 34, bold: true)
        c.lines(["Boutique Exemple", "88 rue de l'Essai", "Toronto ON M5V 2T6"], x: 60, yTop: 110, size: 34)
        c.rule(yTop: 300)
        c.text("DESTINATAIRE :", x: 60, yTop: 340, size: 44, bold: true)
        c.lines(["CAMILLE TEST", "APP. 12", "1234, rue Sainte-Catherine Ouest", "Montréal (Québec) H3G 1P1"], x: 60, yTop: 410, size: 54, bold: true)
        c.rule(yTop: 780)
        c.image(barcode("CA123456789CA"), x: 80, yTop: 840, w: 1040, h: 240)
    }),
    // E3: second package for the identical destination (different tracking ID).
    Label(name: "e3_same_destination_second_package", draw: { _, c in
        c.lines(returnToronto, x: 60, yTop: 60, size: 34)
        c.rule(yTop: 300)
        c.text("SHIP TO:", x: 60, yTop: 340, size: 44, bold: true)
        c.lines(shipToVictoria, x: 60, yTop: 410, size: 60, bold: true)
        c.image(barcode("1Z999AA10123456795"), x: 80, yTop: 880, w: 1040, h: 260)
    }),
    // E3: same building, different unit.
    Label(name: "e3_other_unit", draw: { _, c in
        c.lines(returnToronto, x: 60, yTop: 60, size: 34)
        c.rule(yTop: 300)
        c.text("SHIP TO:", x: 60, yTop: 340, size: 44, bold: true)
        c.lines(["SAM TEST", "UNIT 305", "123 EXAMPLE ST", "VICTORIA BC V8W 1A1"], x: 60, yTop: 410, size: 60, bold: true)
        c.image(barcode("1Z999AA10123456806"), x: 80, yTop: 880, w: 1040, h: 260)
    }),
    // E4: street number obscured, postal code readable.
    Label(name: "e4_obscured_civic", draw: { _, c in
        c.lines(returnToronto, x: 60, yTop: 60, size: 34)
        c.rule(yTop: 300)
        c.text("SHIP TO:", x: 60, yTop: 340, size: 44, bold: true)
        c.lines(["ALEX TEST", "UNIT 204", "     EXAMPLE ST", "VICTORIA BC V8W 1A1"], x: 60, yTop: 410, size: 60, bold: true)
        c.box(x: 55, yTop: 565, w: 150, h: 70, gray: 0.08)
    }),
    // E4: tracking barcode only, no printed address.
    Label(name: "e4_tracking_only", draw: { _, c in
        c.text("PARCEL", x: 60, yTop: 80, size: 60, bold: true)
        c.image(barcode("1Z999AA10123456817"), x: 80, yTop: 300, w: 1040, h: 300)
        c.text("1Z999AA10123456817", x: 260, yTop: 640, size: 40)
    }),
    // Two unlabelled addresses — must trigger a choice.
    Label(name: "ambiguous_two_addresses", draw: { _, c in
        c.lines(["JORDAN TEST", "77 PLACEHOLDER RD", "CALGARY AB T2P 1J9"], x: 60, yTop: 100, size: 50, bold: true)
        c.lines(["RILEY TEST", "9 MOCK CRES", "HALIFAX NS B3H 1A1"], x: 60, yTop: 700, size: 50, bold: true)
    }),
    // Side-by-side FROM / TO columns.
    Label(name: "columns_from_to", draw: { _, c in
        c.text("FROM:", x: 60, yTop: 80, size: 32, bold: true)
        c.lines(["PARCEL SHOP TEST", "45 SAMPLE AVE", "TORONTO ON", "M5V 2T6"], x: 60, yTop: 130, size: 30)
        c.text("SHIP TO:", x: 640, yTop: 80, size: 40, bold: true)
        c.lines(["ALEX TEST", "UNIT 204", "123 EXAMPLE ST", "VICTORIA BC", "V8W 1A1"], x: 640, yTop: 140, size: 44, bold: true)
    }),
    // Explicit address payload in a QR vCard (no printed address).
    Label(name: "qr_vcard_address", draw: { _, c in
        c.text("SCAN FOR DELIVERY DETAILS", x: 60, yTop: 80, size: 44, bold: true)
        let vcard = "BEGIN:VCARD\nVERSION:3.0\nFN:ALEX TEST\nADR;TYPE=home:;UNIT 204;123 EXAMPLE ST;VICTORIA;BC;V8W 1A1;Canada\nEND:VCARD"
        c.image(barcode(vcard, qr: true), x: 300, yTop: 300, w: 600, h: 600)
    }),
    // Rural route.
    Label(name: "rural_route", draw: { _, c in
        c.text("SHIP TO:", x: 60, yTop: 100, size: 44, bold: true)
        c.lines(["MORGAN TEST", "RR 2", "SAMPLEVILLE NB E4B 0A1"], x: 60, yTop: 170, size: 60, bold: true)
    }),
    // Quality variants of E1.
    Label(name: "quality_rotated", draw: standardE1, post: { rotated90($0) }),
    Label(name: "quality_blurred", draw: standardE1, post: { blurred($0, radius: 9) }),
    Label(name: "quality_glare", draw: standardE1, post: { withGlare($0) }),
    Label(name: "quality_incomplete", draw: standardE1, post: { cropped($0, keepTopFraction: 0.38) }),
]

for label in labels { try render(label) }
