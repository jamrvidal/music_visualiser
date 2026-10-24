import Accelerate

/// Hann-windowed real FFT that reduces a block of mono samples to per-band peak levels in dBFS.
final class Spectrum {
    let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var power: [Float]

    init(log2n: Int = 12) {
        size = 1 << log2n
        self.log2n = vDSP_Length(log2n)
        setup = vDSP_create_fftsetup(self.log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        windowed = [Float](repeating: 0, count: size)
        real = [Float](repeating: 0, count: size / 2)
        imag = [Float](repeating: 0, count: size / 2)
        power = [Float](repeating: 0, count: size / 2)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// `samples` must hold `size` values. `edges` are band boundaries in Hz (bands = edges.count - 1).
    func bandLevels(_ samples: [Float], sampleRate: Double, edges: [Double], into levels: inout [Float]) {
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(size))
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(size / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                split.imagp[0] = 0 // zrip packs Nyquist here; drop it
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(size / 2))
            }
        }

        // zrip output is 2x a plain DFT and the Hann window halves amplitude, so a full-scale sine peaks at size/2.
        let norm = Float(size / 2)
        let binHz = sampleRate / Double(size)
        let lastBin = size / 2 - 1
        for band in 0..<(edges.count - 1) {
            let lo = max(Int((edges[band] / binHz).rounded(.up)), 1)
            let hi = min(Int(edges[band + 1] / binHz), lastBin)
            var peak: Float = 0
            if lo <= hi {
                for bin in lo...hi { peak = max(peak, power[bin]) }
            } else {
                // Band narrower than a bin (low end): interpolate at its centre frequency.
                let centre = (edges[band] * edges[band + 1]).squareRoot() / binHz
                let i = min(max(Int(centre), 1), lastBin - 1)
                let f = Float(centre - Double(i))
                peak = power[i] * (1 - f) + power[i + 1] * f
            }
            levels[band] = 20 * log10(peak.squareRoot() / norm + 1e-9)
        }
    }
}
