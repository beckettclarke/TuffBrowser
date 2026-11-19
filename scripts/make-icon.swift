#!/usr/bin/env swift
// Builds the Tuff app icon from the square artwork in "assets/TuffBrowser Icon 1k.png".
// The app icon is an Icon Composer file (AppIcon.icon): the artwork goes in full-bleed as one flat
// layer and macOS masks it to its own icon shape, so it never lands in the grey "legacy icon" frame.
// Xcode also derives the .icns for macOS 15 from it. favicon.png gets the rounded shape drawn in.
// Usage: swift scripts/make-icon.swift TuffBrowser/Resources/AppIcon.icon [artwork.png] [favicon.png]
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icon"
let artworkPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "assets/TuffBrowser Icon 1k.png"
let faviconPath = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "favicon.png"

guard let source = NSImage(contentsOfFile: artworkPath),
      let artwork = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Couldn't read the icon artwork at \(artworkPath)")
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha
    )
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func png(size: Int, _ body: (CGContext) -> Void) -> Data {
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    body(ctx)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

// The Icon Composer layer: the artwork at exactly 1024pt, edge to edge.
let layer = png(size: 1024) { ctx in ctx.draw(artwork, in: CGRect(x: 0, y: 0, width: 1024, height: 1024)) }

// The favicon: the macOS icon grid (an 824pt rounded square on a 1024pt canvas) with a drop shadow.
let favicon = png(size: 256) { ctx in
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = rounded(body, 186)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x111111))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.draw(artwork, in: body)
}

let icon: [String: Any] = [
    "fill": ["solid": "srgb:0.09804,0.09804,0.09804,1.00000"],
    "groups": [[
        "layers": [[
            "image-name": "Artwork.png",
            "name": "Artwork",
            "glass": false,
            "position": ["scale": 1, "translation-in-points": [0, 0]],
        ]],
        "shadow": ["kind": "none", "opacity": 0],
        "specular": false,
        "translucency": ["enabled": false, "value": 0],
    ]],
    "supported-platforms": ["squares": ["macOS"]],
]

let root = URL(fileURLWithPath: output)
try FileManager.default.createDirectory(at: root.appendingPathComponent("Assets"), withIntermediateDirectories: true)
try layer.write(to: root.appendingPathComponent("Assets/Artwork.png"))
let json = try JSONSerialization.data(withJSONObject: icon, options: [.prettyPrinted, .sortedKeys])
try json.write(to: root.appendingPathComponent("icon.json"))
try favicon.write(to: URL(fileURLWithPath: faviconPath))
print("Wrote \(output) and \(faviconPath)")
