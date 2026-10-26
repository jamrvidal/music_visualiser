import AppKit

/// Picks a primary and bass-end colour from album artwork: the strongest hue and the strongest clearly
/// different one, brightened so they read as glowing lines on black.
enum ArtworkColors {
    private static var cache: [URL: BaseColors] = [:]

    static func load(_ url: URL) async -> BaseColors? {
        if let cached = cache[url] { return cached }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let colors = extract(from: data) else { return nil }
        cache[url] = colors
        return colors
    }

    static func extract(from data: Data) -> BaseColors? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let pixels = downsample(image) else { return nil }

        // Weight each pixel by how vivid it is, so dull backgrounds and black borders don't win.
        let binCount = 12
        var weights = [Float](repeating: 0, count: binCount)
        var sums = [SIMD3<Float>](repeating: .zero, count: binCount)
        var average = SIMD3<Float>.zero
        for c in pixels {
            average += c
            let maxC = c.max(), minC = c.min()
            let saturation = maxC > 0 ? (maxC - minC) / maxC : 0
            guard saturation > 0.2, maxC > 0.15 else { continue }
            let bin = Int(hue(of: c) * Float(binCount)) % binCount
            let weight = saturation * maxC
            weights[bin] += weight
            sums[bin] += c * weight
        }
        average /= Float(pixels.count)

        guard let first = weights.indices.max(by: { weights[$0] < weights[$1] }),
              weights[first] / Float(pixels.count) > 0.02 else {
            // Black-and-white or very muted cover: a light tint of its overall colour.
            let primary = brightened(average, to: 0.9)
            return BaseColors(primary: primary, secondary: primary * 0.5)
        }
        let primary = brightened(sums[first] / weights[first], to: 0.95)

        // At least two bins (60°) away, and not just a speck.
        let distinct = weights.indices.filter {
            let d = abs($0 - first)
            return min(d, binCount - d) >= 2 && weights[$0] > weights[first] * 0.15
        }
        guard let second = distinct.max(by: { weights[$0] < weights[$1] }) else {
            // One dominant hue: a deeper neighbour of it for the bass end.
            return BaseColors(primary: primary, secondary: primary.hueRotated(by: -0.07) * 0.6)
        }
        return BaseColors(primary: primary, secondary: brightened(sums[second] / weights[second], to: 0.8))
    }

    /// The image scaled to a small grid of sRGB colours.
    private static func downsample(_ image: CGImage, side: Int = 32) -> [SIMD3<Float>]? {
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        return stride(from: 0, to: bytes.count, by: 4).map {
            SIMD3(Float(bytes[$0]), Float(bytes[$0 + 1]), Float(bytes[$0 + 2])) / 255
        }
    }

    /// Hue in 0..<1.
    private static func hue(of c: SIMD3<Float>) -> Float {
        let maxC = c.max(), delta = maxC - c.min()
        guard delta > 0 else { return 0 }
        var h: Float
        if maxC == c.x {
            h = (c.y - c.z) / delta
        } else if maxC == c.y {
            h = (c.z - c.x) / delta + 2
        } else {
            h = (c.x - c.y) / delta + 4
        }
        h /= 6
        return h - h.rounded(.down)
    }

    /// Same hue and saturation, scaled up to at least `value` brightness.
    private static func brightened(_ c: SIMD3<Float>, to value: Float) -> SIMD3<Float> {
        let maxC = c.max()
        guard maxC > 1e-3 else { return SIMD3(repeating: value) }
        return maxC >= value ? c : c * (value / maxC)
    }
}
