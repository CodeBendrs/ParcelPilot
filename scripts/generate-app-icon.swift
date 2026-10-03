#!/usr/bin/env swift
// Generates the original ParcelPilot app icon (light + dark) — a parcel with a route path.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let out = root.appendingPathComponent("ParcelPilot/Resources/Assets.xcassets/AppIcon.appiconset")

func render(dark: Bool, to name: String) {
    let s = 1024
    let ctx = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let top = dark ? CGColor(red: 0.06, green: 0.10, blue: 0.22, alpha: 1) : CGColor(red: 0.12, green: 0.35, blue: 0.88, alpha: 1)
    let bottom = dark ? CGColor(red: 0.02, green: 0.30, blue: 0.32, alpha: 1) : CGColor(red: 0.04, green: 0.60, blue: 0.58, alpha: 1)
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(s)), end: CGPoint(x: CGFloat(s), y: 0), options: [])
    // Route path: dashed curve with two waypoints.
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.85))
    ctx.setLineWidth(34)
    ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: [2, 70])
    ctx.move(to: CGPoint(x: 170, y: 210))
    ctx.addCurve(to: CGPoint(x: 820, y: 300), control1: CGPoint(x: 420, y: 80), control2: CGPoint(x: 640, y: 420))
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])
    for p in [CGPoint(x: 170, y: 210), CGPoint(x: 820, y: 300)] {
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: p.x - 46, y: p.y - 46, width: 92, height: 92))
        ctx.setFillColor(bottom)
        ctx.fillEllipse(in: CGRect(x: p.x - 22, y: p.y - 22, width: 44, height: 44))
    }
    // Parcel: isometric box.
    let c = CGPoint(x: 512, y: 600)
    let w: CGFloat = 250, h: CGFloat = 145, d: CGFloat = 230
    let topFace = [CGPoint(x: c.x, y: c.y + h), CGPoint(x: c.x + w, y: c.y + h * 0.35 + 20), CGPoint(x: c.x, y: c.y - 40 + 20), CGPoint(x: c.x - w, y: c.y + h * 0.35 + 20)]
    func poly(_ pts: [CGPoint], _ color: CGColor) { ctx.setFillColor(color); ctx.move(to: pts[0]); pts.dropFirst().forEach { ctx.addLine(to: $0) }; ctx.closePath(); ctx.fillPath() }
    poly([topFace[3], topFace[2], CGPoint(x: topFace[2].x, y: topFace[2].y - d), CGPoint(x: topFace[3].x, y: topFace[3].y - d)], CGColor(red: 0.96, green: 0.80, blue: 0.55, alpha: 1))
    poly([topFace[2], topFace[1], CGPoint(x: topFace[1].x, y: topFace[1].y - d), CGPoint(x: topFace[2].x, y: topFace[2].y - d)], CGColor(red: 0.86, green: 0.66, blue: 0.40, alpha: 1))
    poly(topFace, CGColor(red: 1.0, green: 0.88, blue: 0.66, alpha: 1))
    // Tape stripe.
    ctx.setStrokeColor(CGColor(red: 0.70, green: 0.50, blue: 0.28, alpha: 1))
    ctx.setLineWidth(26)
    ctx.move(to: CGPoint(x: (topFace[0].x + topFace[3].x) / 2, y: (topFace[0].y + topFace[3].y) / 2))
    ctx.addLine(to: CGPoint(x: (topFace[1].x + topFace[2].x) / 2, y: (topFace[1].y + topFace[2].y) / 2))
    ctx.strokePath()
    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}
render(dark: false, to: "AppIcon.png")
render(dark: true, to: "AppIcon-Dark.png")
print("icons written")
