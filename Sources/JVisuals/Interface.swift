import AppKit
import SwiftUI

enum Typeface {
    static func font(_ size: CGFloat, _ weight: Font.Weight = .light) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette(Config())
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

extension View {
    func glow(_ color: Color, _ strength: Double = 1) -> some View {
        shadow(color: color.opacity(0.9 * strength), radius: 3)
            .shadow(color: color.opacity(0.5 * strength), radius: 12)
    }
}

/// Small spaced capitals used for labels and section headers.
private struct Caption: View {
    @Environment(\.palette) private var palette
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(Typeface.font(10, .medium))
            .tracking(3)
            .foregroundStyle(palette.textColor.opacity(0.45))
    }
}

struct ContentView: View {
    @StateObject private var capture = AudioCapture()
    @StateObject private var settings = VisualSettings()
    @StateObject private var nowPlaying = NowPlaying()
    @State private var showControls = true
    @State private var showSources = false
    @State private var showSettings = false
    @State private var showTrack = false
    @State private var hideTask: Task<Void, Never>?
    @State private var trackTask: Task<Void, Never>?
    @State private var keyMonitor: Any?
    /// Ticks while colours cycle so the interface glow follows the visuals.
    @State private var paletteDate = Date()

    private var palette: Palette { Palette(settings.config, at: paletteDate) }

    var body: some View {
        ZStack {
            MetalView(ring: capture.ring, settings: settings)

            if showControls || showSettings {
                overlay.transition(.opacity)
            }

            if let track = nowPlaying.track, showControls || showTrack, !showSettings {
                VStack {
                    HStack {
                        Spacer()
                        NowPlayingCard(nowPlaying: nowPlaying, track: track)
                    }
                    Spacer()
                }
                .padding(.horizontal, 44)
                .padding(.top, 82)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .background(Color.black)
        .environment(\.palette, palette)
        .onContinuousHover { _ in revealControls() }
        .onAppear {
            capture.start()
            nowPlaying.start()
            installKeys()
            revealControls()
        }
        .onChange(of: nowPlaying.track?.id) { _, id in
            if id != nil { announceTrack() }
        }
        .task(id: settings.config.cycleColors) {
            while settings.config.cycleColors && !Task.isCancelled {
                paletteDate = Date()
                try? await Task.sleep(for: .milliseconds(66))
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        }
        .frame(minWidth: 960, minHeight: 540)
    }

    private var overlay: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                .frame(height: 220)
                .allowsHitTesting(false)

            if showSources || showSettings {
                // Click anywhere else to close the open list or panel.
                Color.black.opacity(0.001).onTapGesture { closePopups() }
            }

            VStack {
                header
                Spacer()
                controls
            }
            .padding(.horizontal, 44)
            .padding(.top, 34)
            .padding(.bottom, 36)

            if showSettings {
                ControlDeck(settings: settings, sampleRate: capture.ring.sampleRate, close: closePopups)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text("JVISUALS")
                    .font(Typeface.font(13, .regular))
                    .tracking(8)
                    .foregroundStyle(palette.textColor.opacity(0.75))
                    .glow(palette.accentColor, 0.5)
                if let status = capture.status {
                    Text(status).font(Typeface.font(12)).foregroundStyle(Color(red: 1, green: 0.55, blue: 0.6))
                } else {
                    Text(currentSource.isPlaying ? "♪  \(currentSource.name)" : currentSource.name)
                        .font(Typeface.font(12))
                        .foregroundStyle(palette.textColor.opacity(0.5))
                }
            }
        }
        .opacity(showSettings ? 0 : 1)
    }

    private var controls: some View {
        HStack(alignment: .bottom, spacing: 48) {
            ModeDial(mode: $settings.config.mode)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 16) {
                SourceSelector(capture: capture, isOpen: $showSources)
                HStack(alignment: .center, spacing: 22) {
                    GlowKnob(label: "Gain",
                             value: Binding(get: { log2(settings.config.gain) },
                                            set: { settings.config.gain = pow(2, $0) }),
                             range: -2...2.6, defaultValue: 0, size: 40) { String(format: "×%.1f", pow(2, $0)) }
                    Button {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            showSources = false
                            showSettings.toggle()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "dial.medium").font(.system(size: 12, weight: .medium))
                            Text("CONTROLS").font(Typeface.font(11, .medium)).tracking(3)
                        }
                        .foregroundStyle(palette.textColor.opacity(0.6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
            }
            .frame(width: 290)
        }
        .opacity(showSettings ? 0 : 1)
    }

    private var currentSource: AudioSource {
        capture.sources.first { $0.id == capture.selectedID } ?? .system
    }

    private func closePopups() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            showSources = false
            showSettings = false
        }
        revealControls()
    }

    /// Shows the now-playing card for a few seconds on a track change, even with the interface hidden.
    private func announceTrack() {
        withAnimation(.easeOut(duration: 0.4)) { showTrack = true }
        trackTask?.cancel()
        trackTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.8)) { showTrack = false }
        }
    }

    private func revealControls() {
        if !showControls { withAnimation(.easeOut(duration: 0.3)) { showControls = true } }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, !showSources, !showSettings else { return }
            withAnimation(.easeInOut(duration: 0.8)) { showControls = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    /// ←/→ or 1–4 switch modes, S opens the controls, H hides the interface, F full screen.
    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modes = VisualMode.allCases
            let index = modes.firstIndex(of: settings.config.mode) ?? 0
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            switch (event.keyCode, key) {
            case (53, _): closePopups()
            case (123, _): settings.config.mode = modes[(index + modes.count - 1) % modes.count]
            case (124, _): settings.config.mode = modes[(index + 1) % modes.count]
            case (_, "1"), (_, "2"), (_, "3"), (_, "4"): settings.config.mode = modes[Int(key)! - 1]
            case (_, "s"):
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { showSettings.toggle() }
            case (_, "h"):
                hideTask?.cancel()
                withAnimation(.easeOut(duration: 0.3)) { showControls.toggle() }
                return nil
            case (_, "f"):
                event.window?.toggleFullScreen(nil)
                return nil
            default:
                return event
            }
            revealControls()
            return nil
        }
    }
}

// MARK: - Control deck

/// The customisation controls as a bank of knobs that slides up from the bottom.
private struct ControlDeck: View {
    @ObservedObject var settings: VisualSettings
    let sampleRate: Double
    let close: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 18) {
                Text("CONTROLS")
                    .font(Typeface.font(15, .regular))
                    .tracking(6)
                    .foregroundStyle(palette.textColor)
                    .glow(palette.accentColor, 0.6)
                Spacer()
                Button("RESET") {
                    withAnimation(.easeOut(duration: 0.3)) { settings.resetLook() }
                }
                .buttonStyle(.plain)
                .font(Typeface.font(10, .medium))
                .tracking(3)
                .foregroundStyle(palette.textColor.opacity(0.5))
                .help("Reset the look (keeps mode, colours and gain)")
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.textColor.opacity(0.6))
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 26) {
                    group("Colour") {
                        VStack(alignment: .leading, spacing: 14) {
                            ColorRow(label: "Primary", hex: $settings.config.primary)
                            if settings.config.gradient {
                                ColorRow(label: "Bass end", hex: $settings.config.secondary)
                                    .transition(.opacity)
                            }
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            Switch(label: "Gradient", isOn: $settings.config.gradient)
                            Switch(label: "Cycle", isOn: $settings.config.cycleColors)
                        }
                        if settings.config.cycleColors {
                            GlowKnob(label: "Speed", value: $settings.config.cycleSpeed, range: 0.5...30,
                                     defaultValue: 4) { String(format: "%.0f s", 60 / $0) }
                                .transition(.opacity)
                        }
                    }
                    divider
                    modeGroup
                    divider
                    group("Look") {
                        GlowKnob(label: "Glow", value: $settings.config.glow, range: 0...2, defaultValue: 1,
                                 readout: percent)
                        GlowKnob(label: "Trails", value: $settings.config.trails, range: 0...1, defaultValue: 0.6,
                                 readout: percent)
                        GlowKnob(label: "Line", value: $settings.config.thickness, range: 0.5...3, defaultValue: 1) {
                            String(format: "%.1f×", $0)
                        }
                        GlowKnob(label: "CRT", value: $settings.config.scanlines, range: 0...1, defaultValue: 0,
                                 readout: percent)
                        if settings.config.mode.isScope {
                            Switch(label: "Grid", isOn: $settings.config.grid)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 24)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.92)], startPoint: .top, endPoint: .bottom)
        )
        .overlay(alignment: .top) {
            Rectangle().fill(palette.accentColor.opacity(0.2)).frame(height: 1)
        }
        .animation(.easeOut(duration: 0.25), value: settings.config.mode)
        .animation(.easeOut(duration: 0.25), value: settings.config.gradient)
        .animation(.easeOut(duration: 0.25), value: settings.config.spectrumStyle)
    }

    @ViewBuilder private var modeGroup: some View {
        switch settings.config.mode {
        case .spectrum:
            group("Spectrum") {
                CycleButton(label: "Style", options: SpectrumStyle.allCases,
                            selection: $settings.config.spectrumStyle) { $0.title }
                let style = settings.config.spectrumStyle
                let filled = (style == .line && settings.config.lineFill)
                    || (style == .terrain && settings.config.terrainFill)
                if style.isBars || filled {
                    GlowKnob(label: filled ? "Lines" : "Bars", value: $settings.config.barCount, range: 8...128,
                             defaultValue: 48) {
                        "\(Int($0.rounded()))"
                    }
                    .transition(.opacity)
                }
                if settings.config.spectrumStyle == .terrain {
                    GlowKnob(label: "Height", value: $settings.config.terrainHeight, range: 0.2...2, defaultValue: 1,
                             readout: percent)
                    GlowKnob(label: "Speed", value: $settings.config.terrainSpeed, range: 5...60, defaultValue: 30) {
                        String(format: "%.0f/s", $0)
                    }
                    GlowKnob(label: "Depth", value: $settings.config.terrainDepth, range: 16...96, defaultValue: 48) {
                        "\(Int($0.rounded()))"
                    }
                }
                GlowKnob(label: "Smooth", value: $settings.config.smoothing, range: 0...1, defaultValue: 0.5,
                         readout: percent)
                VStack(alignment: .leading, spacing: 14) {
                    if style == .line {
                        Switch(label: "Fill", isOn: $settings.config.lineFill)
                    }
                    if style == .terrain {
                        Switch(label: "Fill", isOn: $settings.config.terrainFill)
                    }
                    if settings.config.spectrumStyle.showsPeaks {
                        Switch(label: "Peaks", isOn: $settings.config.showPeaks)
                    }
                    if settings.config.spectrumStyle.canReflect {
                        Switch(label: "Reflect", isOn: $settings.config.reflection)
                    }
                    if settings.config.spectrumStyle == .terrain {
                        Switch(label: "Grid", isOn: $settings.config.terrainGrid)
                    }
                }
            }
        case .pulse:
            group("Pulse") {
                CycleButton(label: "Shape", options: PulseShape.allCases, selection: $settings.config.pulseShape) {
                    $0.title
                }
                GlowKnob(label: "Punch", value: $settings.config.pulsePunch, range: 0...2, defaultValue: 1,
                         readout: percent)
                GlowKnob(label: "Spin", value: $settings.config.pulseSpin, range: -1...1, defaultValue: 0.3) {
                    String(format: "%+.0f%%", $0 * 100)
                }
                GlowKnob(label: "Sense", value: $settings.config.pulseSensitivity, range: 0...1, defaultValue: 0.5,
                         readout: percent)
            }
        case .scope:
            group("Scope") {
                CycleButton(label: "Style", options: ScopeStyle.allCases, selection: $settings.config.scopeStyle) {
                    $0.title
                }
                GlowKnob(label: "Time", value: $settings.config.timeSpan, range: 256...4096, defaultValue: 1024) {
                    String(format: "%.0f ms", $0 / sampleRate * 1000)
                }
                Switch(label: "Trigger", isOn: $settings.config.trigger)
            }
        case .xy:
            group("X · Y") {
                CycleButton(label: "Input", options: XYSource.allCases, selection: $settings.config.xySource) {
                    $0.title
                }
                if settings.config.xySource == .delay {
                    GlowKnob(label: "Delay", value: $settings.config.xyDelay, range: 0.2...10, defaultValue: 2.5) {
                        String(format: "%.1f ms", $0)
                    }
                    .transition(.opacity)
                }
                GlowKnob(label: "Width", value: $settings.config.xyWidth, range: 0...4, defaultValue: 2) {
                    String(format: "%.1f×", $0)
                }
                GlowKnob(label: "Spin", value: $settings.config.xySpin, range: -1...1, defaultValue: 0) {
                    String(format: "%+.0f°/s", $0 * 36)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Switch(label: "Auto gain", isOn: $settings.config.autoGain)
                    Switch(label: "Rotate 45°", isOn: $settings.config.rotateXY)
                }
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(palette.textColor.opacity(0.1)).frame(width: 1, height: 110)
    }

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Caption(text: title)
            HStack(alignment: .top, spacing: 16) {
                content()
            }
        }
    }
}

// MARK: - Components

/// Artwork, title, artist/album and a progress line for the track Spotify is playing.
private struct NowPlayingCard: View {
    @ObservedObject var nowPlaying: NowPlaying
    let track: Track
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .trailing, spacing: 4) {
                Text(nowPlaying.isPlaying ? "NOW PLAYING" : "PAUSED")
                    .font(Typeface.font(9, .medium))
                    .tracking(3)
                    .foregroundStyle(palette.textColor.opacity(0.45))
                Text(track.title)
                    .font(Typeface.font(17, .regular))
                    .foregroundStyle(palette.textColor)
                    .glow(palette.accentColor, 0.4)
                    .lineLimit(1)
                Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: "  ·  "))
                    .font(Typeface.font(12))
                    .foregroundStyle(palette.textColor.opacity(0.55))
                    .lineLimit(1)
                progress.padding(.top, 4)
            }
            artwork
        }
        .frame(maxWidth: 420, alignment: .trailing)
        .animation(.easeOut(duration: 0.3), value: track)
    }

    private var artwork: some View {
        AsyncImage(url: track.artwork) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            ZStack {
                Color.black.opacity(0.5)
                Image(systemName: "music.note").foregroundStyle(palette.textColor.opacity(0.4))
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(palette.accentColor.opacity(0.25), lineWidth: 1))
        .shadow(color: palette.accentColor.opacity(0.25), radius: 10)
    }

    private var progress: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let elapsed = nowPlaying.elapsed(at: context.date)
            let fraction = track.duration > 0 ? elapsed / track.duration : 0
            HStack(spacing: 10) {
                Text("\(Self.time(elapsed)) / \(Self.time(track.duration))")
                    .font(Typeface.font(10).monospacedDigit())
                    .foregroundStyle(palette.textColor.opacity(0.45))
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.textColor.opacity(0.14))
                    Capsule().fill(palette.accentColor)
                        .frame(width: 160 * min(max(fraction, 0), 1))
                        .glow(palette.accentColor, 0.5)
                }
                .frame(width: 160, height: 2)
            }
        }
    }

    private static func time(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Stepped mode selector: one detent per mode, with only the current mode's name beside it.
/// Click to step to the next mode, or drag to sweep through them.
private struct ModeDial: View {
    @Binding var mode: VisualMode
    @State private var dragStart: Int?
    @Environment(\.palette) private var palette

    private let modes = VisualMode.allCases
    private let size: CGFloat = 56
    private var index: Int { modes.firstIndex(of: mode) ?? 0 }

    var body: some View {
        HStack(spacing: 20) {
            KnobFace(fraction: Double(index) / Double(modes.count - 1), size: size, detents: modes.count)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: index)
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { drag in
                        let start = dragStart ?? index
                        dragStart = start
                        let steps = Int(((drag.translation.width - drag.translation.height) / 30).rounded())
                        mode = modes[min(max(start + steps, 0), modes.count - 1)]
                    }
                    .onEnded { _ in dragStart = nil })
                .onTapGesture { mode = modes[(index + 1) % modes.count] }
                .help("Mode: click to step, drag to sweep")

            Text(mode.title.uppercased())
                .font(Typeface.font(26))
                .tracking(5)
                .foregroundStyle(palette.textColor)
                .glow(palette.accentColor)
                .id(mode)
                .transition(.opacity)
        }
        .animation(.easeOut(duration: 0.2), value: mode)
    }
}

/// A colour picked on the colour wheel, typed as hex, or dialled in on R/G/B knobs.
private struct ColorRow: View {
    let label: String
    @Binding var hex: String
    @State private var text = ""
    @FocusState private var editing: Bool
    @Environment(\.palette) private var palette

    private var rgb: SIMD3<Float> { Hex.parse(hex) ?? .one }
    private var isValid: Bool { Hex.parse(text) != nil }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ColorPicker("", selection: pickerColor, supportsOpacity: false)
                        .labelsHidden()
                    TextField("#RRGGBB", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(isValid ? palette.textColor : Color(red: 1, green: 0.5, blue: 0.55))
                        .focused($editing)
                        .frame(width: 70)
                        .padding(.vertical, 3)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(palette.accentColor.opacity(editing ? 0.8 : 0.25))
                                .frame(height: 1)
                        }
                        .onSubmit { text = hex; editing = false }
                        .onChange(of: text) { _, new in
                            if let parsed = Hex.parse(new) { hex = Hex.string(parsed) }
                        }
                }
                Text(label.uppercased())
                    .font(Typeface.font(9, .medium))
                    .tracking(2)
                    .foregroundStyle(palette.textColor.opacity(0.45))
            }
            channel("R", 0, tint: Color(red: 1, green: 0.3, blue: 0.3))
            channel("G", 1, tint: Color(red: 0.3, green: 1, blue: 0.4))
            channel("B", 2, tint: Color(red: 0.35, green: 0.55, blue: 1))
        }
        .onAppear { text = hex }
        .onChange(of: hex) { _, new in
            if !editing || Hex.parse(text) != Hex.parse(new) { text = new }
        }
    }

    private var pickerColor: Binding<Color> {
        Binding(get: { Color(simd: rgb) }, set: { color in
            guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return }
            hex = Hex.string(SIMD3(Float(ns.redComponent), Float(ns.greenComponent), Float(ns.blueComponent)))
        })
    }

    private func channel(_ name: String, _ index: Int, tint: Color) -> some View {
        let value = Binding<Double>(
            get: { Double(rgb[index] * 255).rounded() },
            set: { new in
                var c = rgb
                c[index] = Float(new.rounded()) / 255
                hex = Hex.string(c)
            })
        return GlowKnob(label: name, value: value, range: 0...255, size: 26, tint: tint) { "\(Int($0))" }
    }
}

/// The drawn part of a knob: a dark cap, a 270° value arc and a pointer.
private struct KnobFace: View {
    let fraction: Double
    let size: CGFloat
    var tint: Color?
    /// Marks around the rim for stepped knobs, one per position.
    var detents = 0
    @Environment(\.palette) private var palette

    var body: some View {
        let arc = tint ?? palette.accentColor
        let ring: CGFloat = size > 30 ? 2 : 1.5
        ZStack {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(palette.textColor.opacity(0.12), style: StrokeStyle(lineWidth: ring, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle()
                .trim(from: 0, to: 0.75 * fraction)
                .stroke(arc, style: StrokeStyle(lineWidth: ring, lineCap: .round))
                .rotationEffect(.degrees(135))
                .glow(arc, 0.7)
            ForEach(0..<detents, id: \.self) { i in
                let position = Double(i) / Double(max(detents - 1, 1))
                Circle()
                    .fill(position <= fraction + 0.001 ? arc : palette.textColor.opacity(0.35))
                    .frame(width: 3, height: 3)
                    .offset(y: -size / 2 - 7)
                    .rotationEffect(.degrees(-135 + 270 * position))
            }
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.16), Color(white: 0.05)], center: .init(x: 0.4, y: 0.3),
                                     startRadius: 0, endRadius: size * 0.6))
                .overlay(Circle().stroke(palette.textColor.opacity(0.14), lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 3, y: 2)
                .padding(size > 30 ? 6 : 4)
            Capsule()
                .fill(palette.textColor)
                .frame(width: size > 30 ? 2 : 1.5, height: size * 0.22)
                .offset(y: -size * 0.2)
                .rotationEffect(.degrees(-135 + 270 * fraction))
                .glow(arc, 0.5)
        }
        .frame(width: size, height: size)
    }
}

/// Continuous knob: drag up/right to turn, double-click to reset. Shows its value while turning or hovered.
private struct GlowKnob: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var defaultValue: Double?
    var size: CGFloat = 44
    var tint: Color?
    let readout: (Double) -> String
    @State private var dragStart: Double?
    @State private var hovering = false
    @Environment(\.palette) private var palette

    private var fraction: Double {
        min(max((value - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }

    var body: some View {
        VStack(spacing: 6) {
            KnobFace(fraction: fraction, size: size, tint: tint)
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { drag in
                        let start = dragStart ?? fraction
                        dragStart = start
                        let f = min(max(start + (drag.translation.width - drag.translation.height) / 180, 0), 1)
                        value = range.lowerBound + f * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in dragStart = nil })
                .onTapGesture(count: 2) { if let defaultValue { value = defaultValue } }
                .onHover { hovering = $0 }
            Text(dragStart != nil || hovering ? readout(value) : label.uppercased())
                .font(Typeface.font(9, .medium).monospacedDigit())
                .tracking(1.5)
                .foregroundStyle(palette.textColor.opacity(dragStart != nil || hovering ? 0.9 : 0.45))
                .lineLimit(1)
                .frame(width: max(size + 14, 40))
        }
        .help(defaultValue == nil ? "Drag to turn" : "Drag to turn · double-click to reset")
    }
}

/// A round push-button styled like the knobs: the ring is split into one arc per option and the current one
/// glows. Each click steps to the next option.
private struct CycleButton<Option: Hashable & Identifiable>: View {
    let label: String
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    var size: CGFloat = 44
    @State private var hovering = false
    @Environment(\.palette) private var palette

    private var index: Int { options.firstIndex(of: selection) ?? 0 }

    var body: some View {
        VStack(spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { selection = options[(index + 1) % options.count] }
            } label: {
                ZStack {
                    // Same 270° sweep as the knobs, cut into one segment per option.
                    let segment = 0.75 / Double(options.count)
                    ForEach(options.indices, id: \.self) { i in
                        let lit = i == index
                        Circle()
                            .trim(from: Double(i) * segment + 0.012, to: Double(i + 1) * segment - 0.012)
                            .stroke(lit ? palette.accentColor : palette.textColor.opacity(0.12),
                                    style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(135))
                            .glow(palette.accentColor, lit ? 0.7 : 0)
                    }
                    CapView(size: size, hovering: hovering)
                }
                .frame(width: size, height: size)
                .contentShape(Circle())
            }
            .buttonStyle(CapPressStyle())
            .onHover { hovering = $0 }
            Text(hovering ? label.uppercased() : title(selection).uppercased())
                .font(Typeface.font(9, .medium))
                .tracking(1.5)
                .foregroundStyle(palette.textColor.opacity(0.9))
                .glow(palette.accentColor, hovering ? 0 : 0.4)
                .lineLimit(1)
                .frame(width: size + 14)
        }
        .help("\(label): click for the next option")
    }
}

/// The dark cap of a push-button, matching the knob caps, with a small centre light.
private struct CapView: View {
    let size: CGFloat
    let hovering: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [Color(white: 0.16), Color(white: 0.05)], center: .init(x: 0.4, y: 0.3),
                                 startRadius: 0, endRadius: size * 0.6))
            .overlay(Circle().stroke(palette.textColor.opacity(hovering ? 0.3 : 0.14), lineWidth: 1))
            .overlay(Circle().fill(palette.accentColor).frame(width: 4, height: 4).glow(palette.accentColor, 0.8))
            .shadow(color: .black.opacity(0.6), radius: 3, y: 2)
            .padding(6)
    }
}

/// Pushes the cap in slightly while pressed.
private struct CapPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// A labelled toggle, laid out like a panel switch.
private struct Switch: View {
    let label: String
    @Binding var isOn: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 8) {
            GlowToggle(isOn: $isOn)
            Text(label.uppercased())
                .font(Typeface.font(9, .medium))
                .tracking(1.5)
                .foregroundStyle(palette.textColor.opacity(0.45))
                .fixedSize()
        }
        .padding(.top, 12)
    }
}

private struct GlowToggle: View {
    @Binding var isOn: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? palette.accentColor.opacity(0.35) : palette.textColor.opacity(0.1))
                    .overlay(Capsule().stroke(palette.accentColor.opacity(isOn ? 0.6 : 0.15), lineWidth: 1))
                    .frame(width: 34, height: 16)
                Circle()
                    .fill(isOn ? palette.textColor : palette.textColor.opacity(0.45))
                    .frame(width: 10, height: 10)
                    .padding(.horizontal, 3)
                    .glow(palette.accentColor, isOn ? 0.9 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SourceSelector: View {
    @ObservedObject var capture: AudioCapture
    @Binding var isOpen: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 14) {
            Text("Source")
                .font(Typeface.font(13))
                .foregroundStyle(palette.textColor.opacity(0.8))
                .frame(width: 64, alignment: .leading)
            Button {
                if !isOpen { capture.refreshSources() }
                withAnimation(.easeOut(duration: 0.2)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(current.name)
                        .font(Typeface.font(15))
                        .foregroundStyle(palette.textColor)
                        .lineLimit(1)
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(palette.accentColor.opacity(0.8))
                        .rotationEffect(.degrees(isOpen ? 0 : 180))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottomLeading) {
            if isOpen {
                list
                    .offset(x: 78, y: -30)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }
        }
    }

    private var current: AudioSource {
        capture.sources.first { $0.id == capture.selectedID } ?? .system
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(capture.sources) { source in
                SourceRow(source: source, selected: source.id == capture.selectedID) {
                    capture.selectedID = source.id
                    withAnimation(.easeOut(duration: 0.2)) { isOpen = false }
                }
            }
        }
        .padding(8)
        .frame(width: 240, alignment: .leading)
        .background(palette.panelColor.opacity(0.95), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.accentColor.opacity(0.25), lineWidth: 1))
        .shadow(color: palette.accentColor.opacity(0.15), radius: 20)
        .fixedSize()
    }
}

private struct SourceRow: View {
    let source: AudioSource
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            HStack {
                Text(source.name)
                    .font(Typeface.font(14, selected ? .regular : .light))
                    .foregroundStyle(palette.textColor.opacity(selected || hovering ? 1 : 0.6))
                    .glow(palette.accentColor, selected ? 0.6 : 0)
                    .lineLimit(1)
                Spacer()
                if source.isPlaying {
                    Text("♪").font(Typeface.font(12)).foregroundStyle(palette.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(palette.accentColor.opacity(hovering ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
