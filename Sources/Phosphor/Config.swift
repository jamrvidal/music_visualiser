import SwiftUI

enum VisualMode: String, Codable, CaseIterable, Identifiable {
    case scope, xy, spectrum
    var id: Self { self }

    var title: String {
        switch self {
        case .scope: "Scope"
        case .xy: "X · Y"
        case .spectrum: "Spectrum"
        }
    }
}

enum SpectrumStyle: String, Codable, CaseIterable, Identifiable {
    case line, filled, mirror, bars
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

/// Everything the viewer can customise. Persisted as JSON in UserDefaults.
struct Config: Codable, Equatable {
    var mode: VisualMode = .spectrum
    var gain: Double = 1

    // Colour
    var primary = "#80D1FF"
    var secondary = "#2E5CFF"
    var gradient = true

    // Scope
    var timeSpan: Double = 1024
    var trigger = true

    // X · Y
    var rotateXY = false

    // Spectrum
    var spectrumStyle: SpectrumStyle = .filled
    var smoothing: Double = 0.5
    var showPeaks = true
    var reflection = true

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

    init() {
        let data = UserDefaults.standard.data(forKey: Self.key)
        config = data.flatMap { try? JSONDecoder().decode(Config.self, from: $0) } ?? Config()
    }

    /// Restores the look but keeps the current mode, colours and gain.
    func resetLook() {
        var fresh = Config()
        fresh.mode = config.mode
        fresh.gain = config.gain
        fresh.primary = config.primary
        fresh.secondary = config.secondary
        fresh.gradient = config.gradient
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

    init(_ config: Config) {
        self.init(primary: Hex.parse(config.primary) ?? [0.5, 0.82, 1],
                  secondary: Hex.parse(config.secondary) ?? [0.18, 0.36, 1],
                  usesGradient: config.gradient)
    }

    var beam: SIMD3<Float> { primary }
    var peak: SIMD3<Float> { primary + (SIMD3(repeating: 1) - primary) * 0.5 }
    var grid: SIMD3<Float> { primary * 0.22 }

    /// Spectrum colour across the frequency range, t in 0…1 (secondary at the bass end).
    func gradient(_ t: Float) -> SIMD3<Float> {
        usesGradient ? secondary + (primary - secondary) * t : primary
    }

    var accentColor: Color { Color(simd: primary) }
    var textColor: Color { Color(simd: primary + (SIMD3(repeating: 1) - primary) * 0.85) }
    var panelColor: Color { Color(simd: SIMD3(repeating: 0.03) + primary * 0.02) }
}

extension Color {
    init(simd c: SIMD3<Float>) {
        self.init(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }
}
