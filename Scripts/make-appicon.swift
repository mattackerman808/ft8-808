#!/usr/bin/env swift
//
// make-appicon.swift — generate Sources/ft8gui/AppIcon.icns from code, so the
// icon is reproducible and reviewable in git. Dark rounded tile, amber "FT8"
// lettermark, and a thin waterfall-spectrum bar underneath.
//
// Usage: swift Scripts/make-appicon.swift   (run from the repo root)

import AppKit
import Foundation

let repoRoot = FileManager.default.currentDirectoryPath
let iconset = "\(repoRoot)/.appicon.iconset"
let outIcns = "\(repoRoot)/Sources/ft8gui/AppIcon.icns"

try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

// (filename, pixel size)
let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

let amber = NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.18, alpha: 1.0)

func draw(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px)

    // Rounded "squircle-ish" tile with a slight inset, dark vertical gradient.
    let inset = s * 0.06
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = rect.width * 0.2237
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    path.addClip()
    let grad = NSGradient(starting: NSColor(white: 0.10, alpha: 1.0),
                          ending: NSColor(white: 0.02, alpha: 1.0))!
    grad.draw(in: rect, angle: -90)

    // Waterfall spectrum bar near the bottom (green → yellow → red).
    let barH = rect.height * 0.10
    let barRect = CGRect(x: rect.minX + rect.width * 0.16,
                         y: rect.minY + rect.height * 0.17,
                         width: rect.width * 0.68, height: barH)
    let bar = NSBezierPath(roundedRect: barRect, xRadius: barH / 2, yRadius: barH / 2)
    bar.addClip()
    let spectrum = NSGradient(colors: [
        NSColor(red: 0.10, green: 0.70, blue: 0.30, alpha: 1),
        NSColor(red: 0.95, green: 0.85, blue: 0.15, alpha: 1),
        NSColor(red: 0.90, green: 0.20, blue: 0.15, alpha: 1)])!
    spectrum.draw(in: barRect, angle: 0)
    ctx.resetClip()
    path.addClip()

    // "FT8" lettermark, amber, bold rounded, centered above the bar.
    let fontSize = rect.height * 0.40
    let font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: amber, .paragraphStyle: para,
        .kern: -fontSize * 0.02,
    ]
    let text = "FT8" as NSString
    let size = text.size(withAttributes: attrs)
    let origin = CGPoint(x: rect.midX - size.width / 2,
                         y: rect.minY + rect.height * 0.40)
    NSGraphicsContext.current!.cgContext.setShadow(
        offset: .zero, blur: fontSize * 0.10, color: amber.withAlphaComponent(0.5).cgColor)
    text.draw(at: origin, withAttributes: attrs)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (name, px) in variants {
    let rep = draw(px)
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: "\(iconset)/\(name)"))
}

// Pack into an .icns.
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", outIcns]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(atPath: iconset)
print(p.terminationStatus == 0 ? "Wrote \(outIcns)" : "iconutil failed (\(p.terminationStatus))")
