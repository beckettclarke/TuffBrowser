import AppKit

/// The main colours of a favicon, for tinting the selected favourite tile (Instagram's tile
/// gets its pink-to-orange, Snapchat's its yellow).
enum FaviconColors {
    private final class Entry {
        let colors: [NSColor]?
        init(_ colors: [NSColor]?) { self.colors = colors }
    }

    /// Keyed by the image object itself; a new favicon is a new image.
    private static let cache = NSCache<NSImage, Entry>()

    /// Up to three vivid colours, ordered from the icon's top-left to its bottom-right; nil when
    /// the icon is essentially colourless (black, white or grey) or missing.
    static func palette(for image: NSImage?) -> [NSColor]? {
        guard let image else { return nil }
        if let hit = cache.object(forKey: image) { return hit.colors }
        let colors = compute(image)
        cache.setObject(Entry(colors), forKey: image)
        return colors
    }

    private struct Bucket {
        var weight: CGFloat = 0
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        var x: CGFloat = 0, y: CGFloat = 0
    }

    private static func compute(_ image: NSImage) -> [NSColor]? {
        let side = 24
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return nil }

        // Twelve hue slices; colourless pixels only count towards the total.
        var buckets = Array(repeating: Bucket(), count: 12)
        var opaque: CGFloat = 0
        for py in 0..<side {
            for px in 0..<side {
                let i = (py * side + px) * 4
                let a = CGFloat(data[i + 3]) / 255
                guard a > 0.5 else { continue }
                // Premultiplied: undo it.
                let r = CGFloat(data[i]) / 255 / a, g = CGFloat(data[i + 1]) / 255 / a, b = CGFloat(data[i + 2]) / 255 / a
                opaque += 1
                let maxC = max(r, g, b), minC = min(r, g, b)
                let saturation = maxC > 0 ? (maxC - minC) / maxC : 0
                guard saturation > 0.28, maxC > 0.25 else { continue }
                var hue: CGFloat
                let delta = maxC - minC
                if maxC == r { hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
                else if maxC == g { hue = (b - r) / delta + 2 }
                else { hue = (r - g) / delta + 4 }
                hue /= 6
                if hue < 0 { hue += 1 }
                let slot = Int(hue * 12) % 12
                let weight = saturation * maxC
                buckets[slot].weight += weight
                buckets[slot].r += r * weight
                buckets[slot].g += g * weight
                buckets[slot].b += b * weight
                buckets[slot].x += CGFloat(px) * weight
                buckets[slot].y += CGFloat(py) * weight
            }
        }
        let total = buckets.reduce(0) { $0 + $1.weight }
        // Under about a tenth of the icon in colour: treat it as colourless.
        guard opaque > 0, total / opaque > 0.08 else { return nil }

        let ranked = buckets.indices.sorted { buckets[$0].weight > buckets[$1].weight }
        guard let top = ranked.first else { return nil }
        var picked = [top]
        for slot in ranked.dropFirst() where picked.count < 3 {
            guard buckets[slot].weight >= buckets[top].weight * 0.22 else { break }
            // Skip hues right next to one already picked, so the gradient actually shifts.
            let far = picked.allSatisfy { min(abs($0 - slot), 12 - abs($0 - slot)) >= 2 }
            if far { picked.append(slot) }
        }

        // Bitmap rows run bottom-up in AppKit's drawing above but top-down in memory, so `y`
        // grows downwards here: order top-left first.
        let ordered = picked.sorted { a, b in
            let ba = buckets[a], bb = buckets[b]
            return (ba.x + ba.y) / ba.weight < (bb.x + bb.y) / bb.weight
        }
        return ordered.map { slot in
            let bucket = buckets[slot]
            let color = NSColor(srgbRed: bucket.r / bucket.weight, green: bucket.g / bucket.weight, blue: bucket.b / bucket.weight, alpha: 1)
            return vivid(color)
        }
    }

    /// Lifts a muddy average so it reads as an outline on a dark or light sidebar.
    private static func vivid(_ color: NSColor) -> NSColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        (color.usingColorSpace(.sRGB) ?? color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(1, max(s, 0.55)), brightness: max(b, 0.82), alpha: 1)
    }
}
