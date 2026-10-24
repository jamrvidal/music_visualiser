import Foundation

/// Stereo ring buffer written by the audio tap and read by the renderer each frame.
/// Positions are absolute sample counts since the ring was created.
final class SampleRing: @unchecked Sendable {
    let capacity: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private var total = 0
    private var rate: Double = 48_000
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = capacity
        left = .allocate(capacity: capacity)
        right = .allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity)
        right.initialize(repeating: 0, count: capacity)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    var sampleRate: Double {
        get { lock.withLock { rate } }
        set { lock.withLock { rate = newValue } }
    }

    /// Appends `count` frames. `stride` is 1 for planar buffers or the channel count for interleaved ones.
    func write(left l: UnsafePointer<Float>, right r: UnsafePointer<Float>, stride: Int, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        var w = total % capacity
        for i in 0..<count {
            left[w] = l[i * stride]
            right[w] = r[i * stride]
            w += 1
            if w == capacity { w = 0 }
        }
        total += count
    }

    /// Fills both arrays with the most recent `count` frames (zero-padded at the start if fewer exist).
    func latest(_ count: Int, left l: inout [Float], right r: inout [Float]) {
        lock.lock()
        defer { lock.unlock() }
        let n = min(count, capacity)
        let available = min(total, n)
        let pad = n - available
        for i in 0..<pad {
            l[i] = 0
            r[i] = 0
        }
        copyLocked(start: total - available, count: available, l: &l, r: &r, offset: pad)
    }

    /// Copies frames written since `position` (keeping at most the newest `maxCount`) and advances it.
    /// Returns the number of frames copied.
    func read(after position: inout Int, maxCount: Int, left l: inout [Float], right r: inout [Float]) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let limit = min(maxCount, capacity)
        let start = max(position, total - limit)
        let n = total - start
        copyLocked(start: start, count: n, l: &l, r: &r, offset: 0)
        position = total
        return n
    }

    private func copyLocked(start: Int, count: Int, l: inout [Float], r: inout [Float], offset: Int) {
        var p = start % capacity
        for i in 0..<count {
            l[offset + i] = left[p]
            r[offset + i] = right[p]
            p += 1
            if p == capacity { p = 0 }
        }
    }
}
