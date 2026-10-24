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
    @State private var showControls = true
    @State private var showSources = false
    @State private var showSettings = false
    @State private var hideTask: Task<Void, Never>?
    @State private var keyMonitor: Any?

    private var palette: Palette { Palette(settings.config) }

    var body: some View {
        ZStack {
            MetalView(ring: capture.ring, settings: settings)

            if showControls || showSettings {
                overlay.transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .background(Color.black)
        .environment(\.palette, palette)
        .onContinuousHover { _ in revealControls() }
        .onAppear {
            capture.start()
            installKeys()
            revealControls()
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        }
        .frame(minWidth: 860, minHeight: 520)
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

            HStack {
                Spacer()
                if showSettings {
                    SettingsPanel(settings: settings, sampleRate: capture.ring.sampleRate, close: closePopups)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text("PHOSPHOR")
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
            ModeMenu(mode: $settings.config.mode)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 16) {
                SourceSelector(capture: capture, isOpen: $showSources)
                LabeledRow(label: "Gain", readout: String(format: "×%.1f", settings.config.gain)) {
                    GlowSlider(value: Binding(get: { log2(settings.config.gain) },
                                              set: { settings.config.gain = pow(2, $0) }),
                               range: -2...2.6)
                }
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        showSources = false
                        showSettings.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .medium))
                        Text("SETTINGS").font(Typeface.font(11, .medium)).tracking(3)
                    }
                    .foregroundStyle(palette.textColor.opacity(showSettings ? 1 : 0.6))
                    .glow(palette.accentColor, showSettings ? 0.7 : 0)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(width: 290)
        }
        .opacity(showSettings ? 0.25 : 1)
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

    /// ←/→ or 1–3 switch modes, S opens settings, H hides the interface, F full screen.
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
            case (_, "1"), (_, "2"), (_, "3"): settings.config.mode = modes[Int(key)! - 1]
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

// MARK: - Settings panel

private struct SettingsPanel: View {
    @ObservedObject var settings: VisualSettings
    let sampleRate: Double
    let close: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SETTINGS")
                    .font(Typeface.font(15, .regular))
                    .tracking(6)
                    .foregroundStyle(palette.textColor)
                    .glow(palette.accentColor, 0.6)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.textColor.opacity(0.6))
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 22)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 30) {
                    section("Colour") {
                        ColorRow(label: "Primary", hex: $settings.config.primary)
                        toggleRow("Gradient", $settings.config.gradient)
                        if settings.config.gradient {
                            ColorRow(label: "Bass end", hex: $settings.config.secondary)
                        }
                    }
                    modeSection
                    section("Look") {
                        sliderRow("Glow", $settings.config.glow, 0...2, percent: true)
                        sliderRow("Trails", $settings.config.trails, 0...1, percent: true)
                        sliderRow("Line", $settings.config.thickness, 0.5...3, format: "%.1f×")
                        sliderRow("CRT", $settings.config.scanlines, 0...1, percent: true)
                        if settings.config.mode != .spectrum {
                            toggleRow("Grid", $settings.config.grid)
                        }
                    }
                    Button("Reset look") {
                        withAnimation(.easeOut(duration: 0.3)) { settings.resetLook() }
                    }
                    .buttonStyle(.plain)
                    .font(Typeface.font(12, .regular))
                    .foregroundStyle(palette.textColor.opacity(0.5))
                }
                .padding(.bottom, 12)
            }
        }
        .padding(26)
        .frame(width: 340)
        .frame(maxHeight: .infinity)
        .background(palette.panelColor.opacity(0.9))
        .background(.ultraThinMaterial.opacity(0.4))
        .overlay(alignment: .leading) {
            Rectangle().fill(palette.accentColor.opacity(0.2)).frame(width: 1)
        }
        .animation(.easeOut(duration: 0.25), value: settings.config.mode)
        .animation(.easeOut(duration: 0.25), value: settings.config.gradient)
    }

    @ViewBuilder private var modeSection: some View {
        switch settings.config.mode {
        case .spectrum:
            section("Spectrum") {
                ChoiceRow(options: SpectrumStyle.allCases, selection: $settings.config.spectrumStyle) { $0.title }
                sliderRow("Smooth", $settings.config.smoothing, 0...1, percent: true)
                toggleRow("Peaks", $settings.config.showPeaks)
                if settings.config.spectrumStyle != .mirror {
                    toggleRow("Reflect", $settings.config.reflection)
                }
            }
        case .scope:
            section("Scope") {
                LabeledRow(label: "Time",
                           readout: String(format: "%.0f ms", settings.config.timeSpan / sampleRate * 1000)) {
                    GlowSlider(value: $settings.config.timeSpan, range: 256...4096)
                }
                toggleRow("Trigger", $settings.config.trigger)
            }
        case .xy:
            section("X · Y") {
                toggleRow("Rotate 45°", $settings.config.rotateXY)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Caption(text: title)
            content()
        }
    }

    private func sliderRow(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                           percent: Bool = false, format: String = "%.2f") -> some View {
        LabeledRow(label: label, readout: percent ? "\(Int((value.wrappedValue * 100).rounded()))%"
                                                  : String(format: format, value.wrappedValue)) {
            GlowSlider(value: value, range: range)
        }
    }

    private func toggleRow(_ label: String, _ isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label)
                .font(Typeface.font(13))
                .foregroundStyle(palette.textColor.opacity(0.8))
            Spacer()
            GlowToggle(isOn: isOn)
        }
    }
}

// MARK: - Components

private struct ModeMenu: View {
    @Binding var mode: VisualMode
    @Namespace private var underline

    var body: some View {
        HStack(spacing: 38) {
            ForEach(VisualMode.allCases) { item in
                ModeItem(title: item.title, selected: item == mode, underline: underline) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { mode = item }
                }
            }
        }
    }
}

private struct ModeItem: View {
    let title: String
    let selected: Bool
    let underline: Namespace.ID
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Text(title.uppercased())
                    .font(Typeface.font(26))
                    .tracking(5)
                    .foregroundStyle(palette.textColor.opacity(selected ? 1 : hovering ? 0.65 : 0.32))
                    .glow(palette.accentColor, selected ? 1 : 0)
                ZStack {
                    if selected {
                        Capsule()
                            .fill(palette.accentColor)
                            .glow(palette.accentColor)
                            .matchedGeometryEffect(id: "underline", in: underline)
                    }
                }
                .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// Text options with a gliding underline, used for small choices inside the panel.
private struct ChoiceRow<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    @Namespace private var underline
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 18) {
            ForEach(options) { option in
                let selected = option == selection
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selection = option }
                } label: {
                    VStack(spacing: 6) {
                        Text(title(option).uppercased())
                            .font(Typeface.font(12, selected ? .regular : .light))
                            .tracking(2)
                            .foregroundStyle(palette.textColor.opacity(selected ? 1 : 0.4))
                            .glow(palette.accentColor, selected ? 0.7 : 0)
                        ZStack {
                            if selected {
                                Capsule().fill(palette.accentColor)
                                    .matchedGeometryEffect(id: "choice", in: underline)
                            }
                        }
                        .frame(height: 1.5)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A colour edited as a hex code, R/G/B channels, or through the colour wheel.
private struct ColorRow: View {
    let label: String
    @Binding var hex: String
    @State private var text = ""
    @State private var expanded = false
    @FocusState private var editing: Bool
    @Environment(\.palette) private var palette

    private var rgb: SIMD3<Float> { Hex.parse(hex) ?? .one }
    private var isValid: Bool { Hex.parse(text) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(label)
                    .font(Typeface.font(13))
                    .foregroundStyle(palette.textColor.opacity(0.8))
                    .frame(width: 64, alignment: .leading)

                ColorPicker("", selection: pickerColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 30)

                TextField("#RRGGBB", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(isValid ? palette.textColor : Color(red: 1, green: 0.5, blue: 0.55))
                    .focused($editing)
                    .frame(width: 82)
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

                Spacer(minLength: 0)
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Text("RGB")
                        .font(Typeface.font(10, .medium))
                        .tracking(2)
                        .foregroundStyle(palette.textColor.opacity(expanded ? 1 : 0.45))
                        .glow(palette.accentColor, expanded ? 0.6 : 0)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if expanded {
                VStack(spacing: 8) {
                    channel("R", 0)
                    channel("G", 1)
                    channel("B", 2)
                }
                .transition(.opacity)
            }
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

    private func channel(_ name: String, _ index: Int) -> some View {
        let value = Binding<Double>(
            get: { Double(rgb[index] * 255).rounded() },
            set: { new in
                var c = rgb
                c[index] = Float(new.rounded()) / 255
                hex = Hex.string(c)
            })
        return LabeledRow(label: name, readout: "\(Int(value.wrappedValue))") {
            GlowSlider(value: value, range: 0...255)
        }
    }
}

private struct LabeledRow<Content: View>: View {
    let label: String
    let readout: String
    @ViewBuilder let content: Content
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 14) {
            Text(label)
                .font(Typeface.font(13))
                .foregroundStyle(palette.textColor.opacity(0.8))
                .frame(width: 64, alignment: .leading)
            content
            Text(readout)
                .font(Typeface.font(11).monospacedDigit())
                .foregroundStyle(palette.textColor.opacity(0.5))
                .frame(width: 48, alignment: .trailing)
        }
    }
}

private struct GlowSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    @State private var active = false
    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { geo in
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let x = geo.size.width * min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(palette.textColor.opacity(0.14)).frame(height: 2)
                Capsule().fill(palette.accentColor).frame(width: x, height: 2).glow(palette.accentColor, 0.6)
                Circle()
                    .fill(palette.textColor)
                    .frame(width: active ? 12 : 9, height: active ? 12 : 9)
                    .glow(palette.accentColor)
                    .offset(x: x - (active ? 6 : 4.5))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    active = true
                    let f = min(max(drag.location.x / geo.size.width, 0), 1)
                    value = range.lowerBound + f * (range.upperBound - range.lowerBound)
                }
                .onEnded { _ in active = false })
            .animation(.easeOut(duration: 0.12), value: active)
        }
        .frame(height: 18)
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
