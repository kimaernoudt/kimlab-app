import Foundation
import Synchronization

/// Fills the 80 bits of one LTC frame (bit 0 is sent first).
func ltcFill(_ b: UnsafeMutablePointer<UInt8>, frame: Int, fps: Int) {
    let day = fps * 86400
    let total = ((frame % day) + day) % day
    let f = total % fps, s = (total / fps) % 60, m = (total / (fps * 60)) % 60, h = total / (fps * 3600)
    for i in 0..<80 { b[i] = 0 }
    func put(_ v: Int, _ start: Int, _ n: Int) { for i in 0..<n { b[start + i] = UInt8((v >> i) & 1) } }
    put(f % 10, 0, 4); put(f / 10, 8, 2)
    put(s % 10, 16, 4); put(s / 10, 24, 3)
    put(m % 10, 32, 4); put(m / 10, 40, 3)
    put(h % 10, 48, 4); put(h / 10, 56, 2)
    // sync word 0011 1111 1111 1101 in bits 64...79
    for i in 66...77 { b[i] = 1 }
    b[79] = 1
    var ones = 0
    for i in 0..<80 { ones += Int(b[i]) }
    if ones % 2 == 1 { b[fps == 25 ? 59 : 27] = 1 }
}

/// LTC generator. render() runs on the audio thread and adds the signal to the buffer.
final class LTCEncoder {
    private let bits = UnsafeMutablePointer<UInt8>.allocate(capacity: 80)
    private var frame = 0
    private var bitIndex = 0
    private var half = 0
    private var level: Float = 1
    private var acc = 0.0
    var fps = 25
    var amp: Float = 0.5
    let running = Atomic<Bool>(false)
    let jam = Atomic<Int>(-1)        // frame number to jump to
    let current = Atomic<Int>(0)     // frame being sent now

    init() {
        bits.initialize(repeating: 0, count: 80)
        ltcFill(bits, frame: 0, fps: fps)
    }

    func render(_ out: UnsafeMutablePointer<Float>, frames n: Int, sampleRate sr: Double) {
        let j = jam.exchange(-1, ordering: .sequentiallyConsistent)
        if j >= 0 {
            frame = j; bitIndex = 0; half = 0; acc = 0
            ltcFill(bits, frame: frame, fps: fps)
            current.store(frame, ordering: .relaxed)
        }
        if !running.load(ordering: .relaxed) { return }
        let perHalf = sr / (Double(max(1, fps)) * 160.0)
        for i in 0..<n {
            if acc <= 0 {
                if half == 0 { level = -level } else if bits[bitIndex] == 1 { level = -level }
                acc += perHalf
            }
            out[i] += level * amp
            acc -= 1
            if acc <= 0 {
                if half == 0 { half = 1 } else {
                    half = 0
                    bitIndex += 1
                    if bitIndex == 80 {
                        bitIndex = 0
                        frame += 1
                        ltcFill(bits, frame: frame, fps: fps)
                        current.store(frame, ordering: .relaxed)
                    }
                }
            }
        }
    }
}

/// LTC reader. process() runs on the audio input thread.
final class LTCDecoder {
    private var positive = false
    private var since = 0
    private var period = 0.0
    private var pendingHalf = false
    private var reg: UInt16 = 0
    private let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 80)
    private var idx = 0
    private var count = 0
    private var sinceSync = 0
    var threshold: Float = 0.01
    var peak: Float = 0
    let frame = Atomic<Int>(-1)          // frame that starts at stampHost
    let fps = Atomic<Int>(25)
    let stampHost = Atomic<UInt64>(0)

    init() { buf.initialize(repeating: 0, count: 80) }

    func process(_ x: UnsafePointer<Float>, frames n: Int, sampleRate sr: Double, hostTime: UInt64, ticksPerSample: Double) {
        if period == 0 { period = sr / 2000.0 }
        for i in 0..<n {
            let v = x[i]
            let a = abs(v)
            if a > peak { peak = a }
            since += 1
            sinceSync += 1
            var flipped = false
            if positive {
                if v < -threshold { positive = false; flipped = true }
            } else if v > threshold { positive = true; flipped = true }
            if !flipped { continue }
            let iv = Double(since)
            since = 0
            if iv > period * 3 {
                pendingHalf = false; count = 0; reg = 0; period = sr / 2000.0
                continue
            }
            if iv < period * 0.75 {
                period = period * 0.95 + iv * 2 * 0.05
                if pendingHalf {
                    pendingHalf = false
                    push(1, i, sr, hostTime, ticksPerSample)
                } else { pendingHalf = true }
            } else {
                period = period * 0.95 + iv * 0.05
                pendingHalf = false
                push(0, i, sr, hostTime, ticksPerSample)
            }
        }
    }

    private func get(_ start: Int, _ n: Int) -> Int {
        var v = 0
        for k in 0..<n { v |= Int(buf[(idx + start + k) % 80]) << k }
        return v
    }

    private func push(_ bit: UInt8, _ i: Int, _ sr: Double, _ hostTime: UInt64, _ tps: Double) {
        buf[idx] = bit
        idx = (idx + 1) % 80
        if count < 80 { count += 1 }
        reg = (reg << 1) | UInt16(bit)
        guard reg == 0x3FFD, count == 80 else { return }
        let f = get(0, 4) + 10 * get(8, 2), s = get(16, 4) + 10 * get(24, 3)
        let m = get(32, 4) + 10 * get(40, 3), h = get(48, 4) + 10 * get(56, 2)
        let gap = sinceSync
        sinceSync = 0
        var rate = fps.load(ordering: .relaxed)
        if gap > 0 {
            let est = sr / Double(gap)
            if est > 22 && est < 32 { rate = est < 24.5 ? 24 : (est < 27.5 ? 25 : 30) }
        }
        if f >= rate || s > 59 || m > 59 || h > 23 { return }
        fps.store(rate, ordering: .relaxed)
        frame.store(((h * 60 + m) * 60 + s) * rate + f + 1, ordering: .relaxed)
        stampHost.store(hostTime &+ UInt64(max(0, Double(i) * tps)), ordering: .sequentiallyConsistent)
    }
}
