#!/usr/bin/env swift
// Draws the Tuff app icon (a tiny glass browser window) into the asset catalog.
// Usage: swift scripts/make-icon.swift TuffBrowser/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha
    )
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func draw(size: Int) -> Data {
    let s = CGFloat(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // macOS icon grid: an 824pt rounded square centred on a 1024pt canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = rounded(body, 186)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x0E1A1C))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let background = CGGradient(
        colorsSpace: space, colors: [color(0x2A5C55), color(0x13292B), color(0x0A1416)] as CFArray,
        locations: [0, 0.55, 1]
    )!
    ctx.drawLinearGradient(background, start: CGPoint(x: 200, y: 924), end: CGPoint(x: 824, y: 100), options: [])
    // Soft glow, top-left.
    let glow = CGGradient(
        colorsSpace: space, colors: [color(0x7FE0C3, 0.45), color(0x7FE0C3, 0)] as CFArray, locations: [0, 1]
    )!
    ctx.drawRadialGradient(
        glow, startCenter: CGPoint(x: 290, y: 800), startRadius: 0,
        endCenter: CGPoint(x: 290, y: 800), endRadius: 520, options: []
    )

    // The web "card".
    let card = CGRect(x: 432, y: 228, width: 380, height: 568)
    ctx.addPath(rounded(card, 54))
    ctx.setFillColor(color(0xFFFFFF, 0.93))
    ctx.fillPath()

    // Sidebar: favourites, then tab rows with one selected.
    let tiles: [CGRect] = [
        CGRect(x: 212, y: 716, width: 84, height: 80), CGRect(x: 312, y: 716, width: 84, height: 80),
    ]
    for (i, tile) in tiles.enumerated() {
        ctx.addPath(rounded(tile, 24))
        ctx.setFillColor(i == 0 ? color(0x7FE0C3, 0.95) : color(0xFFFFFF, 0.2))
        ctx.fillPath()
    }
    let rows: [(CGFloat, CGFloat, CGFloat)] = [(612, 184, 0.34), (532, 184, 0.16), (452, 150, 0.16), (372, 170, 0.16), (292, 120, 0.16)]
    for (y, width, alpha) in rows {
        ctx.addPath(rounded(CGRect(x: 212, y: y, width: width, height: 52), 20))
        ctx.setFillColor(color(0xFFFFFF, alpha))
        ctx.fillPath()
    }

    // Glass edge highlight.
    ctx.addPath(rounded(body.insetBy(dx: 3, dy: 3), 183))
    ctx.setStrokeColor(color(0xFFFFFF, 0.16))
    ctx.setLineWidth(6)
    ctx.strokePath()
    ctx.restoreGState()

    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

let entries: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
for (points, scale) in entries {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try draw(size: points * scale).write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: URL(fileURLWithPath: output).appendingPathComponent("Contents.json"))
print("Wrote \(entries.count) icon sizes to \(output)")
