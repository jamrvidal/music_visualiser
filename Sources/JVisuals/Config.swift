import SwiftUI

enum VisualMode: String, Codable, CaseIterable, Identifiable {
    case scope, xy, spectrum, pulse
    var id: Self { self }

    var title: String {
        switch self {
        case .scope: "Scope"
        case .xy: "X \(Typeface.dot) Y"
        case .spectrum: "Spectrum"
        case .pulse: "Pulse"
        }
    }

    /// Oscilloscope-style modes get the graticule and the stronger CRT bloom.
    var isScope: Bool { self == .scope || self == .xy }
}

enum ScopeStyle: String, Codable, CaseIterable, Identifiable {
    case line, circle
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

/// The figure Pulse mode draws at the centre and sends out on each beat.
enum PulseShape: String, Codable, CaseIterable, Identifiable {
    case circle, triangle, square, hexagon, star
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

/// What drives the X·Y beam: the two stereo channels, or the signal against a delayed copy of itself
/// (a phase portrait, which keeps moving even when the music is mono).
enum XYSource: String, Codable, CaseIterable, Identifiable {
    case stereo, delay
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

enum SpectrumStyle: String, Codable, CaseIterable, Identifiable {
    case line, bars, horizontalBars, terrain
    var id: Self { self }

    var title: String {
        switch self {
        case .line: "Line"
        case .bars: "Bars"
        case .horizontalBars: "H-Bars"
        case .terrain: "Terrain"
        }
    }

    var isBars: Bool { self == .bars || self == .horizontalBars }
    /// Styles with a floor to reflect off.
    var canReflect: Bool { self == .line || self == .bars }
    var showsPeaks: Bool { self != .terrain }

    /// Styles that no longer exist (filled, mirror, radial) load as Line instead of failing the whole config.
    init(from decoder: Decoder) throws {
        self = SpectrumStyle(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .line
    }
}

/// Everything the viewer can customise. Persisted as JSON in UserDefaults.
struct Config: Codable, Equatable {
    var mode: VisualMode = .spectrum
    var gain: Double = 1

    // Colour
    var primary = "#80D1FF"
    var secondary = "#2E5CFF"
    var gradient = true
    var cycleColors = false
    /// Full trips around the colour wheel per minute.
    var cycleSpeed: Double = 4
    /// Take the colours from the playing album's artwork (falls back to `primary`/`secondary`).
    var albumColors = false

    // Scope
    var scopeStyle: ScopeStyle = .line
    var timeSpan: Double = 1024
    var trigger = true

    // X · Y
    var rotateXY = false
    var xySource: XYSource = .delay
    var xyDelay: Double = 2.5 // ms
    var xyWidth: Double = 2
    var xySpin: Double = 0
    var autoGain = true

    // Spectrum
    var spectrumStyle: SpectrumStyle = .line
    var smoothing: Double = 0.5
    var showPeaks = true
    var reflection = true
    /// Line style: fill under the curve with vertical lines (count set by `barCount`).
    var lineFill = false
    var barCount: Double = 48
    var terrainHeight: Double = 1
    /// New ridges per second.
    var terrainSpeed: Double = 30
    /// Number of ridges from front to horizon.
    var terrainDepth: Double = 48
    var terrainGrid = false
    /// Terrain: vertical strokes hanging under each ridge (density set by `barCount`).
    var terrainFill = true

    // Pulse
    var pulseShape: PulseShape = .hexagon
    /// How far the bass pushes the shapes outward.
    var pulsePunch: Double = 1
    var pulseSpin: Double = 0.3
    /// 0…1: higher fires rings on softer beats.
    var pulseSensitivity: Double = 0.5

    // Look
    var glow: Double = 1
    var trails: Double = 0.6
    var thickness: Double = 1
    var scanlines: Double = 0
    var grid = true
}

final class VisualSettings: ObservableObject {
    private static let key = "config"

    @Published var config: Config {
        didSet {
            if let data = try? JSONEncoder().encode(config) {
                UserDefaults.standard.set(data, forKey: Self.key)
            }
        }
    }

    /// Colours picked from the playing album's artwork while `albumColors` is on. Not saved.
    @Published private(set) var artworkColors: BaseColors?
    /// What was showing when `artworkColors` last changed, faded out over `fadeDuration` from `fadeStart`.
    private var fadeFrom: BaseColors?
    private(set) var fadeStart = Date.distantPast
    static let fadeDuration = 1.5

    init() {
        config = Self.load() ?? Config()
    }

    func setArtworkColors(_ colors: BaseColors?) {
        guard colors != artworkColors else { return }
        let now = Date()
        fadeFrom = baseColors(at: now)
        fadeStart = now
        artworkColors = colors
    }

    /// The colours to show before cycling: the artwork's if there are any, else the chosen ones,
    /// crossfading for a moment after each change.
    func baseColors(at date: Date) -> BaseColors {
        let target = artworkColors ?? BaseColors(config)
        let t = Float(date.timeIntervalSince(fadeStart) / Self.fadeDuration)
        guard let fadeFrom, t < 1 else { return target }
        let eased = t * t * (3 - 2 * t)
        return BaseColors(primary: fadeFrom.primary + (target.primary - fadeFrom.primary) * eased,
                          secondary: fadeFrom.secondary + (target.secondary - fadeFrom.secondary) * eased)
    }

    /// Saved values laid over the defaults, so settings survive when new fields are added.
    private static func load() -> Config? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaultData = try? JSONEncoder().encode(Config()),
              let defaults = try? JSONSerialization.jsonObject(with: defaultData) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: defaults.merging(saved) { $1 })
        else { return nil }
        return try? JSONDecoder().decode(Config.self, from: merged)
    }

    /// Restores the look but keeps the current mode, colours and gain.
    func resetLook() {
        var fresh = Config()
        fresh.mode = config.mode
        fresh.gain = config.gain
        fresh.primary = config.primary
        fresh.secondary = config.secondary
        fresh.gradient = config.gradient
        fresh.albumColors = config.albumColors
        config = fresh
    }
}

// MARK: - Colour

enum Hex {
    /// Accepts "#RRGGBB", "RRGGBB" or the short "#RGB" form.
    static func parse(_ string: String) -> SIMD3<Float>? {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        return SIMD3(Float((value >> 16) & 0xFF), Float((value >> 8) & 0xFF), Float(value & 0xFF)) / 255
    }

    static func string(_ c: SIMD3<Float>) -> String {
        let v = (c.clamped(lowerBound: .zero, upperBound: .one) * 255).rounded(.toNearestOrEven)
        return String(format: "#%02X%02X%02X", Int(v.x), Int(v.y), Int(v.z))
    }
}

/// The two colours everything else is derived from.
struct BaseColors: Equatable {
    var primary: SIMD3<Float>
    var secondary: SIMD3<Float>
}

extension BaseColors {
    /// The colours chosen in the controls.
    init(_ config: Config) {
        self.init(primary: Hex.parse(config.primary) ?? [0.5, 0.82, 1],
                  secondary: Hex.parse(config.secondary) ?? [0.18, 0.36, 1])
    }
}

/// Colours derived from the chosen primary/secondary, shared by the renderer (SIMD) and interface (SwiftUI).
struct Palette {
    let primary: SIMD3<Float>
    let secondary: SIMD3<Float>
    let usesGradient: Bool

    init(primary: SIMD3<Float>, secondary: SIMD3<Float>, usesGradient: Bool) {
        self.primary = primary
        self.secondary = secondary
        self.usesGradient = usesGradient
    }

    /// The current colours (chosen or from album artwork), as both the renderer and interface show them.
    init(_ settings: VisualSettings, at date: Date = Date()) {
        self.init(settings.config, base: settings.baseColors(at: date), at: date)
    }

    /// The base colours (the configured ones by default); with colour cycling on, both are turned around the
    /// hue wheel by an amount set by the wall clock, so the renderer and the interface stay in step without
    /// sharing state.
    init(_ config: Config, base: BaseColors? = nil, at date: Date = Date()) {
        let base = base ?? BaseColors(config)
        var primary = base.primary, secondary = base.secondary
        if config.cycleColors {
            let turns = date.timeIntervalSinceReferenceDate * config.cycleSpeed / 60
            let shift = Float(turns - turns.rounded(.down))
            primary = primary.hueRotated(by: shift)
            secondary = secondary.hueRotated(by: shift)
        }
        self.init(primary: primary, secondary: secondary, usesGradient: config.gradient)
    }

    var beam: SIMD3<Float> { primary }
    var peak: SIMD3<Float> { primary + (SIMD3(repeating: 1) - primary) * 0.5 }
    /// Plain neutral grey, independent of the chosen (or cycling) colours.
    var grid: SIMD3<Float> { SIMD3(repeating: 0.15) }

    /// Spectrum colour across the frequency range, t in 0…1 (secondary at the bass end).
    func gradient(_ t: Float) -> SIMD3<Float> {
        usesGradient ? secondary + (primary - secondary) * t : primary
    }

    var accentColor: Color { Color(simd: primary) }
    var textColor: Color { Color(simd: primary + (SIMD3(repeating: 1) - primary) * 0.85) }
    var panelColor: Color { Color(simd: SIMD3(repeating: 0.03) + primary * 0.02) }
}

extension SIMD3 where Scalar == Float {
    /// Same saturation and brightness, hue moved by `turns` of the colour wheel (via HSV).
    func hueRotated(by turns: Float) -> SIMD3<Float> {
        let maxC = Swift.max(x, y, z), minC = Swift.min(x, y, z)
        let delta = maxC - minC
        guard delta > 1e-5 else { return self } // greys have no hue to turn
        var hue: Float
        if maxC == x {
            hue = (y - z) / delta
        } else if maxC == y {
            hue = (z - x) / delta + 2
        } else {
            hue = (x - y) / delta + 4
        }
        hue = hue / 6 + turns
        hue -= hue.rounded(.down)

        let saturation = delta / maxC
        let h = hue * 6
        let sector = Int(h) % 6
        let f = h - Float(Int(h))
        let p = maxC * (1 - saturation)
        let q = maxC * (1 - saturation * f)
        let t = maxC * (1 - saturation * (1 - f))
        switch sector {
        case 0: return [maxC, t, p]
        case 1: return [q, maxC, p]
        case 2: return [p, maxC, t]
        case 3: return [p, q, maxC]
        case 4: return [t, p, maxC]
        default: return [maxC, p, q]
        }
    }
}

extension Color {
    init(simd c: SIMD3<Float>) {
        self.init(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }
}
