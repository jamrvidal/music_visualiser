import MetalKit
import QuartzCore

// Layouts mirror the structs in Shaders.swift.
private struct Segment {
    var a: SIMD2<Float>
    var b: SIMD2<Float>
    var color: SIMD4<Float>
    var intensity: Float
}

private struct SegmentUniforms {
    var viewport: SIMD2<Float>
    var width: Float
    var energy: Float
}

private struct Rect {
    var bounds: SIMD4<Float>
    var color: SIMD4<Float>
}

private struct PresentUniforms {
    var gridTint: SIMD4<Float>
    var viewport: SIMD2<Float>
    var exposure: Float
    var bloom: Float
    var grid: Float
    var scanlines: Float
}

private extension SIMD3<Float> {
    var rgba: SIMD4<Float> { SIMD4(self, 1) }
}

final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let fadePipeline: MTLRenderPipelineState
    private let segmentPipeline: MTLRenderPipelineState
    private let rectPipeline: MTLRenderPipelineState
    private let maskPipeline: MTLRenderPipelineState
    private let presentPipeline: MTLRenderPipelineState

    private let ring: SampleRing
    private let settings: VisualSettings

    private var accum: MTLTexture?
    private var lastLayout: String?
    private var lastTime = CACurrentMediaTime()

    private var left = [Float](repeating: 0, count: 1 << 14)
    private var right = [Float](repeating: 0, count: 1 << 14)
    private var mono = [Float](repeating: 0, count: 1 << 14)
    private var segments: [Segment] = []
    private var rects: [Rect] = []
    /// Terrain only: triangle-strip outlines under each ridge, and per ridge (back to front) which strip
    /// and which segments belong to it, so they can be drawn interleaved for occlusion.
    private var maskPoints: [SIMD2<Float>] = []
    private var terrainRuns: [(mask: Range<Int>, lines: Range<Int>)] = []

    private var xyCursor = 0
    /// Where the beam ended last frame; nil after a layout change so the trace starts fresh.
    private var xyLast: SIMD2<Float>?
    private var xyHistory = [Float](repeating: 0, count: 1024) // longest delay at 96 kHz ≈ 10 ms
    private var xyEnvelope: Float = 0.3
    private var xyScale: Float = 0.85
    private var xySpinAngle: Float = 0

    private let spectrum = Spectrum(log2n: 12)
    private static let bandCount = 128
    private let bandEdges: [Double]
    private var bandDB: [Float]
    private var raw: [Float]
    private var levels: [Float]
    private var peaks: [Float]
    private var peakHold: [Double]

    init(ring: SampleRing, settings: VisualSettings) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw NSError(domain: "JVisuals", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal is unavailable"])
        }
        self.device = device
        self.queue = queue
        self.ring = ring
        self.settings = settings

        let library = try device.makeLibrary(source: shaderSource, options: nil)
        func pipeline(_ vertex: String, _ fragment: String, format: MTLPixelFormat,
                      blend: ((MTLRenderPipelineColorAttachmentDescriptor) -> Void)? = nil) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: vertex)
            desc.fragmentFunction = library.makeFunction(name: fragment)
            desc.colorAttachments[0].pixelFormat = format
            if let blend {
                desc.colorAttachments[0].isBlendingEnabled = true
                blend(desc.colorAttachments[0])
            }
            return try device.makeRenderPipelineState(descriptor: desc)
        }
        let additive: (MTLRenderPipelineColorAttachmentDescriptor) -> Void = {
            $0.sourceRGBBlendFactor = .one
            $0.destinationRGBBlendFactor = .one
            $0.sourceAlphaBlendFactor = .one
            $0.destinationAlphaBlendFactor = .one
        }
        fadePipeline = try pipeline("fullscreen_vertex", "fade_fragment", format: .rgba16Float) {
            $0.sourceRGBBlendFactor = .zero
            $0.destinationRGBBlendFactor = .oneMinusSourceAlpha
            $0.sourceAlphaBlendFactor = .zero
            $0.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        segmentPipeline = try pipeline("segment_vertex", "segment_fragment", format: .rgba16Float, blend: additive)
        rectPipeline = try pipeline("rect_vertex", "rect_fragment", format: .rgba16Float, blend: additive)
        maskPipeline = try pipeline("mask_vertex", "mask_fragment", format: .rgba16Float)
        presentPipeline = try pipeline("fullscreen_vertex", "present_fragment", format: .bgra8Unorm)

        let count = Self.bandCount
        bandEdges = (0...count).map { 25 * pow(18_000 / 25, Double($0) / Double(count)) }
        bandDB = [Float](repeating: -120, count: count)
        raw = [Float](repeating: 0, count: count)
        levels = [Float](repeating: 0, count: count)
        peaks = [Float](repeating: 0, count: count)
        peakHold = [Double](repeating: 0, count: count)
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        accum = nil
    }

    func draw(in view: MTKView) {
        let size = view.drawableSize
        guard size.width > 0, size.height > 0,
              let drawable = view.currentDrawable,
              let presentPass = view.currentRenderPassDescriptor,
              let commands = queue.makeCommandBuffer() else { return }

        var clear = false
        if accum == nil {
            accum = makeAccumulation(width: Int(size.width), height: Int(size.height))
            clear = true
        }
        guard let accum else { return }

        let config = settings.config
        let palette = Palette(config)
        // Wipe trails when the picture changes shape, so old geometry doesn't ghost into the new one.
        let layout = "\(config.mode)-\(config.spectrumStyle)-\(config.scopeStyle)-\(config.rotateXY)-\(config.xySource)"
        if layout != lastLayout {
            clear = true
            lastLayout = layout
            xyLast = nil
            terrainRows.removeAll()
        }
        let now = CACurrentMediaTime()
        let dt = min(now - lastTime, 0.1)
        lastTime = now

        let viewport = SIMD2<Float>(Float(size.width), Float(size.height))
        let scale = Float(size.width / max(view.bounds.width, 1))
        let gain = Float(config.gain)

        segments.removeAll(keepingCapacity: true)
        rects.removeAll(keepingCapacity: true)
        maskPoints.removeAll(keepingCapacity: true)
        terrainRuns.removeAll(keepingCapacity: true)

        let aspect = viewport.y / viewport.x
        let beamWidth: Float
        let energy: Float
        switch config.mode {
        case .scope:
            buildScope(config: config, color: palette.beam.rgba, gain: gain, aspect: aspect)
            (beamWidth, energy) = (1.1, 1)
        case .xy:
            buildXY(config: config, color: palette.beam.rgba, gain: gain, aspect: aspect, dt: dt)
            (beamWidth, energy) = (1.0, 1)
        case .spectrum:
            buildSpectrum(config: config, palette: palette, gain: gain, dt: dt, now: now)
            (beamWidth, energy) = (1.4, 0)
        case .pulse:
            buildPulse(config: config, palette: palette, gain: gain, aspect: aspect, dt: dt, now: now)
            (beamWidth, energy) = (1.6, 0)
        }

        let pass = MTLRenderPassDescriptor()
        let keep = Float(config.trails) * 0.92
        pass.colorAttachments[0].texture = accum
        pass.colorAttachments[0].loadAction = clear || keep == 0 ? .clear : .load
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }

        if keep > 0 {
            var keepNow = pow(keep, Float(dt * 60))
            encoder.setRenderPipelineState(fadePipeline)
            encoder.setFragmentBytes(&keepNow, length: MemoryLayout<Float>.size, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        if !rects.isEmpty, let buffer = makeBuffer(rects) {
            encoder.setRenderPipelineState(rectPipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: rects.count)
        }
        if !segments.isEmpty, let buffer = makeBuffer(segments) {
            var uniforms = SegmentUniforms(viewport: viewport, width: beamWidth * Float(config.thickness) * scale,
                                           energy: energy)
            func drawSegments(_ range: Range<Int>) {
                guard !range.isEmpty else { return }
                encoder.setRenderPipelineState(segmentPipeline)
                encoder.setVertexBuffer(buffer, offset: range.lowerBound * MemoryLayout<Segment>.stride, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<SegmentUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SegmentUniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: range.count)
            }
            if terrainRuns.isEmpty {
                drawSegments(0..<segments.count)
            } else if let masks = makeBuffer(maskPoints) {
                // Back to front: blank out everything below this ridge, then draw the ridge on top.
                for run in terrainRuns {
                    encoder.setRenderPipelineState(maskPipeline)
                    encoder.setVertexBuffer(masks, offset: 0, index: 0)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: run.mask.lowerBound,
                                           vertexCount: run.mask.count)
                    drawSegments(run.lines)
                }
            }
        }
        encoder.endEncoding()

        if let blit = commands.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: accum)
            blit.endEncoding()
        }

        guard let present = commands.makeRenderCommandEncoder(descriptor: presentPass) else { return }
        let isScope = config.mode.isScope
        var uniforms = PresentUniforms(
            gridTint: palette.grid.rgba,
            viewport: viewport,
            exposure: isScope ? 1.3 : 1.5,
            bloom: Float(config.glow) * (isScope ? 3.0 : 2.2),
            grid: config.grid && isScope ? 1 : 0,
            scanlines: Float(config.scanlines) * 0.5)
        present.setRenderPipelineState(presentPipeline)
        present.setFragmentTexture(accum, index: 0)
        present.setFragmentBytes(&uniforms, length: MemoryLayout<PresentUniforms>.stride, index: 0)
        present.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        present.endEncoding()

        commands.present(drawable)
        commands.commit()
    }

    // MARK: Scope

    /// Classic Y–T trace, optionally triggered on a rising zero crossing so periodic sounds stand still.
    /// In the Circle style the same window is wrapped around a ring, the signal pushing the radius in and out.
    private func buildScope(config: Config, color: SIMD4<Float>, gain: Float, aspect: Float) {
        let span = Int(config.timeSpan)
        let search = Int(ring.sampleRate / 25)
        let total = span + search
        ring.latest(total, left: &left, right: &right)
        for i in 0..<total { mono[i] = (left[i] + right[i]) * 0.5 }

        var start = search
        if config.trigger {
            for t in stride(from: search, to: 0, by: -1) where mono[t - 1] < 0 && mono[t] >= 0 {
                start = t
                break
            }
        }

        let points = min(span, 2048)
        let step = Float(span) / Float(points)
        if config.scopeStyle == .circle {
            appendScopeRing(start: start, points: points, step: step, gain: gain, aspect: aspect, color: color)
            return
        }
        var previous = SIMD2<Float>.zero
        for j in 0..<points {
            let sample = mono[start + Int(Float(j) * step)]
            let point = SIMD2<Float>(-0.95 + 1.9 * Float(j) / Float(points - 1),
                                     max(-1.1, min(1.1, sample * gain)) * 0.85)
            if j > 0 { segments.append(Segment(a: previous, b: point, color: color, intensity: 0.9)) }
            previous = point
        }
    }

    private func appendScopeRing(start: Int, points: Int, step: Float, gain: Float, aspect: Float,
                                 color: SIMD4<Float>) {
        let radius: Float = 0.5, depth: Float = 0.3
        // The window's two ends rarely meet, so blend the last few percent towards the first sample
        // to close the ring without a step.
        let first = mono[start]
        let blendFrom = Int(Float(points) * 0.94)
        var ring: [SIMD2<Float>] = []
        ring.reserveCapacity(points + 1)
        for j in 0..<points {
            var sample = mono[start + Int(Float(j) * step)]
            if j >= blendFrom {
                let t = Float(j - blendFrom) / Float(points - blendFrom)
                sample += (first - sample) * t * t
            }
            let r = radius + max(-1.2, min(1.2, sample * gain)) * depth
            let angle = Float(j) / Float(points) * 2 * .pi + .pi / 2
            ring.append(SIMD2(cos(angle) * r * aspect, sin(angle) * r))
        }
        ring.append(ring[0])
        for j in 1..<ring.count {
            segments.append(Segment(a: ring[j - 1], b: ring[j], color: color, intensity: 0.9))
        }
    }

    // MARK: X · Y

    /// Lissajous figure. Each sample gives a pair (a, b): left/right in Stereo, or the mono signal against
    /// itself a few milliseconds earlier in Delay. The pair is split into mid (a+b) and side (a−b) so Width can
    /// widen the side, then optionally rotated back so mono lies on the diagonal (classic) or kept upright.
    /// Draws exactly the samples that arrived since the last frame.
    private func buildXY(config: Config, color: SIMD4<Float>, gain: Float, aspect: Float, dt: Double) {
        let count = ring.read(after: &xyCursor, maxCount: 4096, left: &left, right: &right)
        guard count > 0 else { return }

        // Mono history ahead of this frame's samples, so the delayed copy reaches back across frames.
        let history = xyHistory.count
        let delay = min(max(Int(config.xyDelay / 1000 * ring.sampleRate), 1), history)
        if config.xySource == .delay {
            for i in 0..<count { mono[history + i] = (left[i] + right[i]) * 0.5 }
            for i in 0..<history { mono[i] = xyHistory[i] }
        }

        xySpinAngle += Float(config.xySpin * 0.2 * .pi * dt)
        let spin = SIMD2<Float>(cos(xySpinAngle), sin(xySpinAngle))
        let width = Float(config.xyWidth)

        var points: [SIMD2<Float>] = []
        points.reserveCapacity(count)
        var peak: Float = 0
        for i in 0..<count {
            let (a, b) = config.xySource == .delay ? (mono[history + i], mono[history + i - delay]) : (left[i], right[i])
            let mid = (a + b) * 0.7071
            let side = (a - b) * 0.7071 * width
            var p = config.rotateXY ? SIMD2(side, mid) : SIMD2((mid + side) * 0.7071, (mid - side) * 0.7071)
            p = SIMD2(p.x * spin.x - p.y * spin.y, p.x * spin.y + p.y * spin.x)
            peak = max(peak, max(abs(p.x), abs(p.y)))
            points.append(p)
        }
        if config.xySource == .delay {
            for i in 0..<history { xyHistory[i] = mono[count + i] }
        }

        // Auto gain follows the recent peak (quick to shrink on loud passages, slow to grow on quiet ones)
        // so the figure fills the screen at any volume.
        if config.autoGain {
            let fall = Float(pow(0.985, dt * 60))
            xyEnvelope = max(peak, xyEnvelope * fall, 0.05) // floor stops near-silence being blown up to noise
        }
        let target = config.autoGain ? 0.8 / xyEnvelope : 0.85
        xyScale += (target - xyScale) * min(1, Float(dt * 8))
        let scale = xyScale * gain

        // Where the beam lingers (bass, quiet passages) hundreds of samples land on the same pixels and their
        // glows stack into harsh, opaque strokes. Merge samples until the beam has moved a little, and let the
        // brightness grow with log(dwell) rather than linearly.
        let minStep: Float = 0.004
        var previous = xyLast
        var dwell = 0
        for p in points {
            let point = SIMD2<Float>(p.x * scale * aspect, p.y * scale)
            dwell += 1
            guard let start = previous else {
                previous = point
                dwell = 0
                continue
            }
            if simd_distance(point, start) < minStep { continue }
            let intensity = 0.35 * (1 + 0.6 * log2(Float(dwell)))
            segments.append(Segment(a: start, b: point, color: color, intensity: intensity))
            previous = point
            dwell = 0
        }
        xyLast = previous
    }

    // MARK: Spectrum

    private static let minX: Float = -0.94
    private static let maxX: Float = 0.94

    private func buildSpectrum(config: Config, palette: Palette, gain: Float, dt: Double, now: Double) {
        analyse(config: config, gain: gain, dt: dt, now: now)

        if config.spectrumStyle.isBars {
            buildBars(config: config, palette: palette)
            return
        }
        if config.spectrumStyle == .terrain {
            buildTerrain(config: config, palette: palette, dt: dt)
            return
        }

        let curve = Self.resample(levels, perBand: 4)
        let base: Float = -0.38, height: Float = 1.2
        let color = { (i: Int) in palette.gradient(Float(i) / Float(curve.count - 1)) }

        if config.lineFill {
            appendFillLines(curve, config: config, palette: palette, base: base, height: height)
        }
        appendCurve(curve, origin: base, direction: 1, height: height, intensity: 1, color: color)
        if config.showPeaks {
            appendCurve(Self.resample(peaks, perBand: 2), origin: base, direction: 1, height: height,
                        intensity: 0.28, color: { _ in palette.peak })
        }
        if config.reflection {
            appendCurve(curve, origin: base - 0.02, direction: -1, height: height * 0.6, intensity: 0.2, color: color)
        }
    }

    /// Evenly spaced vertical strokes from the floor up to the curve. Each is cut into a few pieces that
    /// brighten towards the top, so the fill glows at the curve and fades into the floor (and the reflection).
    private func appendFillLines(_ curve: [Float], config: Config, palette: Palette, base: Float, height: Float) {
        let count = min(max(Int(config.barCount.rounded()), 8), 128)
        let pieces = 4
        for k in 0..<count {
            let t = (Float(k) + 0.5) / Float(count)
            let position = t * Float(curve.count - 1)
            let i = min(Int(position), curve.count - 2)
            let value = curve[i] + (curve[i + 1] - curve[i]) * (position - Float(i))
            guard value > 0.004 else { continue }
            let x = Self.minX + (Self.maxX - Self.minX) * t
            let c = SIMD4(palette.gradient(t), 1)

            var strokes: [(from: Float, to: Float, strength: Float)] = [(base, base + value * height, 1)]
            if config.reflection {
                strokes.append((base - 0.02, base - 0.02 - value * height * 0.6, 0.2))
            }
            for stroke in strokes {
                for p in 0..<pieces {
                    let y0 = stroke.from + (stroke.to - stroke.from) * Float(p) / Float(pieces)
                    let y1 = stroke.from + (stroke.to - stroke.from) * Float(p + 1) / Float(pieces)
                    let rise = Float(p + 1) / Float(pieces)
                    segments.append(Segment(a: [x, y0], b: [x, y1], color: c,
                                            intensity: 0.5 * rise * rise * stroke.strength))
                }
            }
        }
    }

    private func appendCurve(_ values: [Float], origin: Float, direction: Float, height: Float, intensity: Float,
                             color: (Int) -> SIMD3<Float>) {
        var previous = SIMD2<Float>.zero
        for i in values.indices {
            let x = Self.minX + (Self.maxX - Self.minX) * Float(i) / Float(values.count - 1)
            let point = SIMD2<Float>(x, origin + direction * values[i] * height)
            if i > 0 {
                segments.append(Segment(a: previous, b: point, color: SIMD4(color(i), 1), intensity: intensity))
            }
            previous = point
        }
    }

    /// Vertical bars rise from a floor (with optional reflection); horizontal bars stack bass-to-treble
    /// up the screen and grow from the left edge.
    private func buildBars(config: Config, palette: Palette) {
        let horizontal = config.spectrumStyle == .horizontalBars
        let groups = min(max(Int(config.barCount.rounded()), 8), Self.bandCount)
        // Bars are laid out along the "across" axis and grow along the "along" axis.
        let acrossStart: Float = horizontal ? -0.86 : Self.minX
        let acrossEnd: Float = horizontal ? 0.86 : Self.maxX
        let base: Float = horizontal ? -0.92 : -0.38
        let length: Float = horizontal ? 1.84 : 1.2
        let slot = (acrossEnd - acrossStart) / Float(groups)
        let thickness = slot * 0.62
        let axis: Float = horizontal ? 1 : 0

        func rect(across a0: Float, _ a1: Float, along b0: Float, _ b1: Float, _ rgb: SIMD3<Float>) {
            let bounds: SIMD4<Float> = horizontal ? [b0, a0, b1, a1] : [a0, b0, a1, b1]
            rects.append(Rect(bounds: bounds, color: SIMD4(rgb, axis)))
        }

        for g in 0..<groups {
            // Spread all bands across the bars, even when the count doesn't divide evenly.
            let lo = g * Self.bandCount / groups
            let range = lo..<max((g + 1) * Self.bandCount / groups, lo + 1)
            let level = levels[range].max() ?? 0
            let peak = peaks[range].max() ?? 0
            let a0 = acrossStart + slot * Float(g) + (slot - thickness) / 2
            let a1 = a0 + thickness
            let c = palette.gradient(Float(g) / Float(groups - 1))
            let tip = base + max(level, 0.004) * length
            rect(across: a0, a1, along: base, tip, c * 0.9)
            if config.reflection && !horizontal {
                rect(across: a0, a1, along: base - 0.02 - (tip - base) * 0.6, base - 0.02, c * 0.12)
            }
            if config.showPeaks && peak > 0.01 {
                let p = base + peak * length
                rect(across: a0, a1, along: p + 0.004, p + 0.012, palette.peak)
            }
        }
    }

    // MARK: Terrain

    private static let terrainColumns = 96
    /// Recorded ridges, newest first.
    private var terrainRows: [[Float]] = []
    private var terrainClock: Double = 0

    /// The spectrum history as a landscape: a new ridge is recorded at the front `terrainSpeed` times a
    /// second and older ones recede towards a horizon in perspective, fading as they go. Ridges are emitted
    /// back to front, each with a black mask underneath, so nearer hills hide what's behind them.
    private func buildTerrain(config: Config, palette: Palette, dt: Double) {
        let depth = max(Int(config.terrainDepth.rounded()), 4)
        let interval = 1 / config.terrainSpeed
        terrainClock += dt
        while terrainClock >= interval {
            terrainClock -= interval
            terrainRows.insert(terrainRow(), at: 0)
        }
        if terrainRows.count > depth + 1 { terrainRows.removeLast(terrainRows.count - depth - 1) }
        guard !terrainRows.isEmpty else { return }

        // Rows drift back by `phase` of a slot between recordings, so the scroll is continuous.
        let phase = Float(terrainClock / interval)
        let horizon: Float = 0.42, front: Float = -0.8
        let height = Float(config.terrainHeight) * 0.6
        let columns = Self.terrainColumns
        let projected: [(points: [SIMD2<Float>], base: Float, z: Float)] = terrainRows.indices.map { i in
            let z = (Float(i) + phase) / Float(depth)
            let f = 1 / (1 + z * 3.2) // perspective shrink towards the horizon
            let base = horizon + (front - horizon) * f
            let points = (0..<columns).map { c in
                let x = Float(c) / Float(columns - 1) * 2 - 1
                return SIMD2<Float>(x * 1.3 * f, base + terrainRows[i][c] * height * f)
            }
            return (points, base, z)
        }
        // Fill strokes hang from every `fillStep`-th column, so the Lines knob sets their density.
        let fillStep = max(columns / min(max(Int(config.barCount.rounded()), 8), columns), 1)

        for i in projected.indices.reversed() {
            let (points, base, z) = projected[i]
            guard z <= 1 else { continue }
            let fade = pow(1 - z, 1.3)

            let maskStart = maskPoints.count
            for p in points {
                maskPoints.append(p)
                maskPoints.append(SIMD2(p.x, -1.1))
            }
            let lineStart = segments.count
            if config.terrainFill {
                // Vertical strokes from this ridge's ground up to the ridge, brightening towards the top.
                for c in stride(from: fillStep / 2, to: columns, by: fillStep) where points[c].y - base > 0.002 {
                    let color = SIMD4(palette.gradient(Float(c) / Float(columns - 1)), 1)
                    for p in 0..<3 {
                        let y0 = base + (points[c].y - base) * Float(p) / 3
                        let y1 = base + (points[c].y - base) * Float(p + 1) / 3
                        let rise = Float(p + 1) / 3
                        segments.append(Segment(a: [points[c].x, y0], b: [points[c].x, y1], color: color,
                                                intensity: 0.45 * rise * rise * fade))
                    }
                }
            }
            if config.terrainGrid && i + 1 < projected.count {
                let behind = projected[i + 1].points
                for c in stride(from: 0, to: columns, by: 3) {
                    let color = SIMD4(palette.gradient(Float(c) / Float(columns - 1)), 1)
                    segments.append(Segment(a: points[c], b: behind[c], color: color, intensity: 0.45 * fade))
                }
            }
            for c in 1..<columns {
                let color = SIMD4(palette.gradient(Float(c) / Float(columns - 1)), 1)
                segments.append(Segment(a: points[c - 1], b: points[c], color: color, intensity: fade))
            }
            terrainRuns.append((maskStart..<maskPoints.count, lineStart..<segments.count))
        }
    }

    /// The current spectrum resampled to the terrain's columns, tapered to flat at both edges.
    private func terrainRow() -> [Float] {
        let columns = Self.terrainColumns
        return (0..<columns).map { c in
            let t = Float(c) / Float(columns - 1)
            let position = t * Float(Self.bandCount - 1)
            let i = min(Int(position), Self.bandCount - 2)
            let f = position - Float(i)
            let level = levels[i] * (1 - f) + levels[i + 1] * f
            let edge = min(min(t, 1 - t) / 0.12, 1)
            return level * edge * edge * (3 - 2 * edge)
        }
    }

    // MARK: Pulse

    private struct PulseRing {
        let born: Double
        let rotation: Float
        let strength: Float
    }

    private var pulseRings: [PulseRing] = []
    private var pulseBassAverage: Float = 0
    private var pulseLastBeat: Double = 0
    private var pulseLevel: Float = 0
    private var pulseAngle: Float = 0

    /// A shape at the centre throbs with the bass and a smaller one counter-rotates with the mids;
    /// each detected beat launches a ring of the same shape that expands off-screen and fades.
    private func buildPulse(config: Config, palette: Palette, gain: Float, aspect: Float, dt: Double, now: Double) {
        analyse(config: config, gain: gain, dt: dt, now: now)
        let bass = bandMean(below: 150)
        let mids = bandMean(from: 150, to: 2000)
        let punch = Float(config.pulsePunch)

        // A beat is bass jumping well above its recent average; higher sensitivity lowers the bar.
        let threshold = 1.12 + (1 - Float(config.pulseSensitivity)) * 0.5
        if bass > pulseBassAverage * threshold && bass > 0.12 && now - pulseLastBeat > 0.16 {
            pulseLastBeat = now
            pulseRings.append(PulseRing(born: now, rotation: pulseAngle, strength: min(1, bass * 1.3)))
        }
        pulseBassAverage += (bass - pulseBassAverage) * min(1, Float(dt * 2))
        pulseLevel = max(bass, pulseLevel - Float(dt * 2.5))
        pulseAngle += Float(config.pulseSpin * dt * 1.2)

        let sides = config.pulseShape
        let core: Float = 0.16 + pulseLevel * 0.22 * punch
        appendShape(sides, radius: core, rotation: pulseAngle, aspect: aspect,
                    color: SIMD4(palette.primary, 1), intensity: 1)
        appendShape(sides, radius: core * (0.5 + mids * 0.25 * punch), rotation: -pulseAngle * 1.6, aspect: aspect,
                    color: SIMD4(palette.gradient(0.4), 1), intensity: 0.6)

        let life = 1.6
        pulseRings.removeAll { now - $0.born >= life }
        for ring in pulseRings {
            let t = Float((now - ring.born) / life)
            let radius = 0.16 + ring.strength * 0.22 * punch + t * t * 1.4 + t * 0.3
            let fade = (1 - t) * (1 - t) * ring.strength
            appendShape(sides, radius: radius, rotation: ring.rotation + t * Float(config.pulseSpin) * 0.8,
                        aspect: aspect, color: SIMD4(palette.gradient(1 - t), 1), intensity: fade)
        }
    }

    private func appendShape(_ shape: PulseShape, radius: Float, rotation: Float, aspect: Float,
                             color: SIMD4<Float>, intensity: Float) {
        let sides: Int
        switch shape {
        case .circle: sides = 96
        case .triangle: sides = 3
        case .square: sides = 4
        case .hexagon: sides = 6
        case .star: sides = 10
        }
        appendPolygon(sides: sides, radius: radius, rotation: rotation, aspect: aspect, color: color,
                      intensity: intensity, innerRadius: shape == .star ? radius * 0.45 : nil)
    }

    /// Closed regular polygon; with `innerRadius`, alternate corners are pulled in to make a star.
    private func appendPolygon(sides: Int, radius: Float, rotation: Float, aspect: Float,
                               color: SIMD4<Float>, intensity: Float, innerRadius: Float? = nil) {
        guard intensity > 0.002 else { return }
        func corner(_ i: Int) -> SIMD2<Float> {
            let r = innerRadius != nil && i % 2 == 1 ? innerRadius! : radius
            let angle = rotation + Float.pi / 2 + Float(i) / Float(sides) * 2 * .pi
            return SIMD2(cos(angle) * r * aspect, sin(angle) * r)
        }
        for i in 0..<sides {
            segments.append(Segment(a: corner(i), b: corner(i + 1), color: color, intensity: intensity))
        }
    }

    private func bandMean(below high: Double) -> Float {
        bandMean(from: 0, to: high)
    }

    /// Mean smoothed level of the bands whose centre lies in [low, high) Hz.
    private func bandMean(from low: Double, to high: Double) -> Float {
        var sum: Float = 0
        var count = 0
        for b in 0..<Self.bandCount {
            let centre = (bandEdges[b] * bandEdges[b + 1]).squareRoot()
            if centre >= low && centre < high {
                sum += levels[b]
                count += 1
            }
        }
        return count > 0 ? sum / Float(count) : 0
    }

    /// FFT → per-band level (0…1) with attack/release smoothing, light spatial blur and peak hold.
    private func analyse(config: Config, gain: Float, dt: Double, now: Double) {
        let n = spectrum.size
        ring.latest(n, left: &left, right: &right)
        for i in 0..<n { mono[i] = (left[i] + right[i]) * 0.5 }
        spectrum.bandLevels(Array(mono[0..<n]), sampleRate: ring.sampleRate, edges: bandEdges, into: &bandDB)

        let s = Float(config.smoothing)
        let frames = Float(dt * 60)
        let attack = 1 - pow(1 - (0.85 - 0.6 * s), frames)
        let release = 1 - pow(1 - (0.35 - 0.3 * s), frames)
        let gainDB = 20 * log10(max(gain, 0.01))
        for b in 0..<Self.bandCount {
            let centre = (bandEdges[b] * bandEdges[b + 1]).squareRoot()
            let tilt = Float(3 * log2(centre / 1000)) // music falls off with frequency; lift the highs
            let target = max(0, min(1, (bandDB[b] + tilt + gainDB + 64) / 58))
            raw[b] += (target - raw[b]) * (target > raw[b] ? attack : release)
        }

        // [1 4 6 4 1] blur across neighbouring bands, stronger smoothing → second pass.
        let passes = s > 0.5 ? 2 : 1
        levels = raw
        for _ in 0..<passes {
            let src = levels
            for b in 0..<Self.bandCount {
                func at(_ i: Int) -> Float { src[min(max(i, 0), Self.bandCount - 1)] }
                levels[b] = (at(b - 2) + 4 * at(b - 1) + 6 * at(b) + 4 * at(b + 1) + at(b + 2)) / 16
            }
        }

        for b in 0..<Self.bandCount {
            if levels[b] >= peaks[b] {
                peaks[b] = levels[b]
                peakHold[b] = now + 0.5
            } else if now > peakHold[b] {
                peaks[b] = max(levels[b], peaks[b] - Float(dt * 0.4))
            }
        }
    }

    /// Catmull-Rom upsampling so the curve reads as a smooth line rather than a polyline.
    private static func resample(_ values: [Float], perBand: Int) -> [Float] {
        guard values.count > 1 else { return values }
        var out: [Float] = []
        out.reserveCapacity((values.count - 1) * perBand + 1)
        func at(_ i: Int) -> Float { values[min(max(i, 0), values.count - 1)] }
        for i in 0..<(values.count - 1) {
            let p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2)
            for k in 0..<perBand {
                let t = Float(k) / Float(perBand)
                let a = 2 * p1
                let b = (p2 - p0) * t
                let c = (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                let d = (3 * p1 - p0 - 3 * p2 + p3) * t * t * t
                out.append(max(0, min(1.05, 0.5 * (a + b + c + d))))
            }
        }
        out.append(values[values.count - 1])
        return out
    }

    // MARK: Resources

    private func makeAccumulation(width: Int, height: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height,
                                                            mipmapped: true)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        return device.makeTexture(descriptor: desc)
    }

    private func makeBuffer<T>(_ items: [T]) -> MTLBuffer? {
        items.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
    }
}
