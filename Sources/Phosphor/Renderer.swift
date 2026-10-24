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

private struct StripVertex {
    var position: SIMD2<Float>
    var pad: SIMD2<Float> = .zero
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
    private let stripPipeline: MTLRenderPipelineState
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
    private var strip: [StripVertex] = []
    private var stripRuns: [Range<Int>] = []

    private var xyCursor = 0
    private var xyLast = SIMD2<Float>.zero

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
            throw NSError(domain: "Phosphor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal is unavailable"])
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
        stripPipeline = try pipeline("strip_vertex", "strip_fragment", format: .rgba16Float, blend: additive)
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
        let layout = "\(config.mode)-\(config.spectrumStyle)-\(config.rotateXY)"
        if layout != lastLayout {
            clear = true
            lastLayout = layout
        }
        let now = CACurrentMediaTime()
        let dt = min(now - lastTime, 0.1)
        lastTime = now

        let viewport = SIMD2<Float>(Float(size.width), Float(size.height))
        let scale = Float(size.width / max(view.bounds.width, 1))
        let gain = Float(config.gain)

        segments.removeAll(keepingCapacity: true)
        rects.removeAll(keepingCapacity: true)
        strip.removeAll(keepingCapacity: true)
        stripRuns.removeAll(keepingCapacity: true)

        let beamWidth: Float
        let energy: Float
        switch config.mode {
        case .scope:
            buildScope(config: config, color: palette.beam.rgba, gain: gain)
            (beamWidth, energy) = (1.1, 1)
        case .xy:
            buildXY(config: config, color: palette.beam.rgba, gain: gain, aspect: viewport.y / viewport.x)
            (beamWidth, energy) = (1.0, 1)
        case .spectrum:
            buildSpectrum(config: config, palette: palette, gain: gain, dt: dt, now: now)
            (beamWidth, energy) = (1.4, 0)
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
        if !strip.isEmpty, let buffer = makeBuffer(strip) {
            encoder.setRenderPipelineState(stripPipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            for run in stripRuns {
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: run.lowerBound, vertexCount: run.count)
            }
        }
        if !rects.isEmpty, let buffer = makeBuffer(rects) {
            encoder.setRenderPipelineState(rectPipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: rects.count)
        }
        if !segments.isEmpty, let buffer = makeBuffer(segments) {
            var uniforms = SegmentUniforms(viewport: viewport, width: beamWidth * Float(config.thickness) * scale,
                                           energy: energy)
            encoder.setRenderPipelineState(segmentPipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<SegmentUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SegmentUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: segments.count)
        }
        encoder.endEncoding()

        if let blit = commands.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: accum)
            blit.endEncoding()
        }

        guard let present = commands.makeRenderCommandEncoder(descriptor: presentPass) else { return }
        let isScope = config.mode != .spectrum
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
    private func buildScope(config: Config, color: SIMD4<Float>, gain: Float) {
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
        var previous = SIMD2<Float>.zero
        for j in 0..<points {
            let sample = mono[start + Int(Float(j) * step)]
            let point = SIMD2<Float>(-0.95 + 1.9 * Float(j) / Float(points - 1),
                                     max(-1.1, min(1.1, sample * gain)) * 0.85)
            if j > 0 { segments.append(Segment(a: previous, b: point, color: color, intensity: 0.9)) }
            previous = point
        }
    }

    // MARK: X · Y

    /// Lissajous: left channel drives X, right drives Y (or mid/side when rotated, so mono is vertical).
    /// Draws exactly the samples that arrived since the last frame.
    private func buildXY(config: Config, color: SIMD4<Float>, gain: Float, aspect: Float) {
        let count = ring.read(after: &xyCursor, maxCount: 4096, left: &left, right: &right)
        let scale = 0.85 * gain
        var previous = xyLast
        for i in 0..<count {
            var x = left[i], y = right[i]
            if config.rotateXY {
                (x, y) = ((x - y) * 0.7071, (x + y) * 0.7071)
            }
            let point = SIMD2<Float>(x * scale * aspect, y * scale)
            segments.append(Segment(a: previous, b: point, color: color, intensity: 0.35))
            previous = point
        }
        xyLast = previous
    }

    // MARK: Spectrum

    private static let minX: Float = -0.94
    private static let maxX: Float = 0.94

    private func buildSpectrum(config: Config, palette: Palette, gain: Float, dt: Double, now: Double) {
        analyse(config: config, gain: gain, dt: dt, now: now)

        if config.spectrumStyle == .bars {
            buildBars(config: config, palette: palette)
            return
        }

        let curve = Self.resample(levels, perBand: 4)
        let peakCurve = config.showPeaks ? Self.resample(peaks, perBand: 2) : []
        let mirrored = config.spectrumStyle == .mirror
        let base: Float = mirrored ? 0 : -0.38
        let height: Float = mirrored ? 0.72 : 1.2
        let fill = config.spectrumStyle != .line

        func x(_ i: Int, of count: Int) -> Float {
            Self.minX + (Self.maxX - Self.minX) * Float(i) / Float(count - 1)
        }
        func color(_ i: Int, of count: Int) -> SIMD3<Float> {
            palette.gradient(Float(i) / Float(count - 1))
        }

        // Each pass draws the curve on one side of the baseline: up, then down (mirror) or reflection.
        let passes: [(direction: Float, strength: Float)] =
            mirrored ? [(1, 1), (-1, 1)] : config.reflection ? [(1, 1), (-1, 0.2)] : [(1, 1)]
        for (direction, strength) in passes {
            let isReflection = direction < 0 && !mirrored
            let origin = isReflection ? base - 0.02 : base
            let reach = isReflection ? height * 0.6 : height
            if fill {
                // Fills glow at the curve and fade towards the baseline; reflections fade away from it.
                let edgeLight: Float = isReflection ? 0 : mirrored ? 0.4 : 0.45
                let rootLight: Float = isReflection ? 0.6 : mirrored ? 0.12 : 0.03
                let start = strip.count
                for i in curve.indices {
                    let c = color(i, of: curve.count)
                    let px = x(i, of: curve.count)
                    let edge = SIMD2<Float>(px, origin + direction * curve[i] * reach)
                    strip.append(StripVertex(position: edge, color: SIMD4(c * edgeLight * strength, 1)))
                    strip.append(StripVertex(position: [px, origin], color: SIMD4(c * rootLight * strength, 1)))
                }
                stripRuns.append(start..<strip.count)
            }
            appendCurve(curve, origin: origin, direction: direction, height: reach, intensity: strength,
                        color: { color($0, of: curve.count) })
            if !peakCurve.isEmpty && !isReflection {
                appendCurve(peakCurve, origin: origin, direction: direction, height: reach, intensity: 0.28,
                            color: { _ in palette.peak })
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

    private func buildBars(config: Config, palette: Palette) {
        let groups = 48
        let perGroup = Self.bandCount / groups
        let slot = (Self.maxX - Self.minX) / Float(groups)
        let width = slot * 0.62
        let base: Float = -0.38, height: Float = 1.2
        for g in 0..<groups {
            let range = (g * perGroup)..<min((g + 1) * perGroup, Self.bandCount)
            let level = levels[range].max() ?? 0
            let peak = peaks[range].max() ?? 0
            let x0 = Self.minX + slot * Float(g) + (slot - width) / 2
            let c = SIMD4(palette.gradient(Float(g) / Float(groups - 1)), 1)
            let top = base + max(level, 0.004) * height
            rects.append(Rect(bounds: [x0, base, x0 + width, top], color: c * 0.9))
            if config.reflection {
                rects.append(Rect(bounds: [x0, base - 0.02 - (top - base) * 0.6, x0 + width, base - 0.02],
                                  color: c * 0.12))
            }
            if config.showPeaks && peak > 0.01 {
                let y = base + peak * height
                rects.append(Rect(bounds: [x0, y + 0.004, x0 + width, y + 0.012], color: SIMD4(palette.peak, 1)))
            }
        }
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
