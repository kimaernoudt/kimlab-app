import Foundation
import AVFoundation
import Accelerate
import Synchronization

let hostToSec: Double = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return Double(tb.numer) / Double(tb.denom) / 1e9
}()
func hostAfter(_ sec: Double) -> UInt64 { mach_absolute_time() + UInt64(max(0, sec) / hostToSec) }

/// One playback voice: a ring buffer filled by a Feeder thread and drained by the audio thread.
final class Voice {
    static let capFloats = 1 << 20
    let ring = UnsafeMutablePointer<Float>.allocate(capacity: Voice.capFloats)
    var srcCh = 2
    var capFrames = Voice.capFloats / 2
    let w = Atomic<Int>(0)
    let r = Atomic<Int>(0)
    let skipTo = Atomic<Int>(0)
    let active = Atomic<Bool>(false)
    let paused = Atomic<Bool>(false)
    let eof = Atomic<Bool>(false)
    let finished = Atomic<Bool>(false)
    let seekPending = Atomic<Bool>(false)
    let startHost = Atomic<UInt64>(0)      // 0 = play now, max = hold, else host time to start at
    var gainCur: Float = 0
    var gainTarget: Float = 1
    var gainStep: Float = 1
    var level: Float = 1
    var stopWhenSilent = false
    let pairs = UnsafeMutablePointer<Int32>.allocate(capacity: 256)
    let route = Atomic<Int>(0)             // table << 16 | pair count

    init() {
        ring.initialize(repeating: 0, count: Voice.capFloats)
        pairs.initialize(repeating: 0, count: 256)
    }
    func setRoute(_ p: [(Int, Int)]) {
        let t = 1 - (route.load(ordering: .sequentiallyConsistent) >> 16)
        let n = min(p.count, 64)
        for i in 0..<n {
            pairs[t * 128 + i * 2] = Int32(p[i].0)
            pairs[t * 128 + i * 2 + 1] = Int32(p[i].1)
        }
        route.store(t << 16 | n, ordering: .sequentiallyConsistent)
    }
    func reset(level lv: Float, fadeIn: Double, sampleRate: Double, hold: Bool) {
        w.store(0, ordering: .sequentiallyConsistent)
        r.store(0, ordering: .sequentiallyConsistent)
        skipTo.store(0, ordering: .sequentiallyConsistent)
        eof.store(false, ordering: .sequentiallyConsistent)
        finished.store(false, ordering: .sequentiallyConsistent)
        paused.store(false, ordering: .sequentiallyConsistent)
        seekPending.store(false, ordering: .sequentiallyConsistent)
        level = lv
        gainCur = fadeIn > 0.001 ? 0 : 1
        gainTarget = 1
        gainStep = fadeIn > 0.001 ? Float(1.0 / (fadeIn * sampleRate)) : 1
        stopWhenSilent = false
        startHost.store(hold ? UInt64.max : 0, ordering: .sequentiallyConsistent)
    }
    func fade(to g: Float, seconds: Double, sampleRate: Double, thenStop: Bool) {
        gainStep = seconds <= 0.001 ? 1 : Float(1.0 / (seconds * sampleRate))
        stopWhenSilent = thenStop
        gainTarget = g
    }
}

/// Native mixer: voices -> output matrix -> mute/solo -> pink -> LTC -> meters.
final class Mixer {
    static let maxVoices = 16
    static let maxOut = 64
    static let maxFrames = 8192
    let voices: [Voice]
    let hal = HALOutput()
    let cycle = Atomic<Int>(0)
    let mute = UnsafeMutablePointer<Bool>.allocate(capacity: Mixer.maxOut)
    let solo = UnsafeMutablePointer<Bool>.allocate(capacity: Mixer.maxOut)
    let pink = UnsafeMutablePointer<Bool>.allocate(capacity: Mixer.maxOut)
    let peak = UnsafeMutablePointer<Float>.allocate(capacity: Mixer.maxOut)
    private let gains = UnsafeMutablePointer<Float>.allocate(capacity: Mixer.maxFrames)
    private let pinkBuf = UnsafeMutablePointer<Float>.allocate(capacity: Mixer.maxFrames)
    var pinkGain: Float = 0.1
    var ltc: LTCEncoder? = nil
    var ltcChannel = -1
    var loadPeak: Float = 0
    let bus = UnsafeMutablePointer<Float>.allocate(capacity: Mixer.maxOut * Mixer.maxFrames)
    var busChannels = 8
    var toneChannel = -1
    var toneAlive: UInt64 = 0
    var tonePhase = 0.0
    private var rng: UInt32 = 0x1234ABCD
    private var b0: Float = 0
    private var b1: Float = 0
    private var b2: Float = 0
    private var inUse = [Bool](repeating: false, count: Mixer.maxVoices)
    private var freed = [Int](repeating: -10, count: Mixer.maxVoices)
    var sampleRate: Double { hal.sampleRate }
    var channels: Int { hal.channels }

    init() {
        voices = (0..<Mixer.maxVoices).map { _ in Voice() }
        mute.initialize(repeating: false, count: Mixer.maxOut)
        solo.initialize(repeating: false, count: Mixer.maxOut)
        pink.initialize(repeating: false, count: Mixer.maxOut)
        peak.initialize(repeating: 0, count: Mixer.maxOut)
        gains.initialize(repeating: 0, count: Mixer.maxFrames)
        pinkBuf.initialize(repeating: 0, count: Mixer.maxFrames)
        bus.initialize(repeating: 0, count: Mixer.maxOut * Mixer.maxFrames)
        hal.render = { [unowned self] bufs, n, host in self.render(bufs, n, host) }
    }
    func start(device: AudioDeviceID) -> Bool { hal.start(device: device) }

    func acquire() -> Int? {
        let c = cycle.load(ordering: .relaxed)
        for i in 0..<Mixer.maxVoices {
            if inUse[i] || voices[i].active.load(ordering: .sequentiallyConsistent) { continue }
            if hal.running && c - freed[i] < 2 { continue }
            inUse[i] = true
            return i
        }
        return nil
    }
    func release(_ i: Int) {
        voices[i].active.store(false, ordering: .sequentiallyConsistent)
        freed[i] = cycle.load(ordering: .relaxed)
        inUse[i] = false
    }
    var busyVoices: Int { inUse.filter { $0 }.count }

    private func render(_ bufs: UnsafeMutableAudioBufferListPointer, _ nIn: Int, _ host: UInt64) {
        let t0 = mach_absolute_time()
        let n = min(nIn, Mixer.maxFrames)
        let devCh = min(bufs.count, Mixer.maxOut)
        let outCh = max(devCh, min(busChannels, Mixer.maxOut))
        for c in 0..<outCh { vDSP_vclr(bus + c * Mixer.maxFrames, 1, vDSP_Length(n)) }
        let sr = hal.sampleRate
        for vi in 0..<Mixer.maxVoices {
            let v = voices[vi]
            if v.active.load(ordering: .sequentiallyConsistent) { mixVoice(v, bufs, n, outCh, host, sr) }
        }
        var anySolo = false, anyPink = false
        for c in 0..<outCh {
            if solo[c] { anySolo = true }
            if pink[c] { anyPink = true }
        }
        if anyPink {
            let g = pinkGain
            for i in 0..<n {
                rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
                let white = Float(Int32(bitPattern: rng)) / 2147483648.0
                b0 = 0.99765 * b0 + white * 0.0990460
                b1 = 0.96300 * b1 + white * 0.2965164
                b2 = 0.57000 * b2 + white * 1.0526913
                pinkBuf[i] = (b0 + b1 + b2 + white * 0.1848) * 0.25 * g
            }
        }
        for c in 0..<outCh {
            let p = bus + c * Mixer.maxFrames
            if anySolo ? !solo[c] : mute[c] { vDSP_vclr(p, 1, vDSP_Length(n)) }
            if pink[c] { vDSP_vadd(p, 1, pinkBuf, 1, p, 1, vDSP_Length(n)) }
            if c == ltcChannel, let l = ltc { l.render(p, frames: n, sampleRate: sr) }
            if c == toneChannel { addTone(p, n, sr) }
            var m: Float = 0
            vDSP_maxmgv(p, 1, &m, vDSP_Length(n))
            if m > peak[c] { peak[c] = m }
        }
        for c in 0..<devCh {
            if let d = bufs[c].mData { memcpy(d, bus + c * Mixer.maxFrames, n * 4) }
        }
        _ = cycle.add(1, ordering: .relaxed)
        let dt = Float(Double(mach_absolute_time() - t0) * hostToSec / (Double(max(1, n)) / sr))
        if dt > loadPeak { loadPeak = dt }
    }

    private func mixVoice(_ v: Voice, _ bufs: UnsafeMutableAudioBufferListPointer, _ n: Int, _ outCh: Int, _ host: UInt64, _ sr: Double) {
        if v.paused.load(ordering: .relaxed) || v.seekPending.load(ordering: .sequentiallyConsistent) { return }
        var off = 0
        let sh = v.startHost.load(ordering: .sequentiallyConsistent)
        if sh != 0 {
            if sh == UInt64.max { return }
            if sh > host {
                off = Int(Double(sh - host) * hostToSec * sr)
                if off >= n { return }
            }
            _ = v.startHost.compareExchange(expected: sh, desired: 0, ordering: .sequentiallyConsistent)
        }
        var rd = v.r.load(ordering: .relaxed)
        let sk = v.skipTo.load(ordering: .sequentiallyConsistent)
        if rd < sk { rd = sk }
        let wr = v.w.load(ordering: .sequentiallyConsistent)
        let take = max(0, min(n - off, wr - rd))
        if take > 0 {
            var g = v.gainCur
            let tgt = v.gainTarget, step = v.gainStep, lvl = v.level
            if g == tgt {
                var c = g * lvl
                vDSP_vfill(&c, gains, 1, vDSP_Length(take))
            } else {
                for i in 0..<take {
                    if g < tgt { g = min(tgt, g + step) } else if g > tgt { g = max(tgt, g - step) }
                    gains[i] = g * lvl
                }
                v.gainCur = g
            }
            let ch = v.srcCh, cap = v.capFrames
            let rt = v.route.load(ordering: .sequentiallyConsistent)
            let table = (rt >> 16) * 128, np = rt & 0xFFFF
            let start = rd % cap
            let first = min(take, cap - start)
            for k in 0..<np {
                let s = Int(v.pairs[table + k * 2]), d = Int(v.pairs[table + k * 2 + 1])
                if s < 0 || s >= ch || d < 0 || d >= outCh { continue }
                let o = bus + d * Mixer.maxFrames
                vDSP_vma(v.ring + start * ch + s, ch, gains, 1, o + off, 1, o + off, 1, vDSP_Length(first))
                if first < take {
                    vDSP_vma(v.ring + s, ch, gains + first, 1, o + off + first, 1, o + off + first, 1, vDSP_Length(take - first))
                }
            }
            rd += take
        }
        v.r.store(rd, ordering: .sequentiallyConsistent)
        var done = false
        if take < n - off && v.eof.load(ordering: .sequentiallyConsistent) && v.w.load(ordering: .sequentiallyConsistent) == rd { done = true }
        if v.stopWhenSilent && v.gainCur <= 0 && v.gainTarget <= 0 { done = true }
        if done {
            v.finished.store(true, ordering: .sequentiallyConsistent)
            v.active.store(false, ordering: .sequentiallyConsistent)
        }
    }
}

/// Decodes one file (all its audio tracks) into a Voice on its own thread.
final class Feeder {
    let url: URL
    let voice: Voice
    let sampleRate: Double
    var loop: Bool
    private(set) var duration = 0.0
    private(set) var srcCh = 0
    private(set) var noAudio = false
    private let lock = NSLock()
    private var segs: [(Int, Int)] = []
    private var seekReq: Double? = nil
    private var routeSpec: String
    private var cancelled = false
    private var lastSeek = 0.0

    init(url: URL, voice: Voice, sampleRate: Double, start: Double, loop: Bool, routeSpec: String) {
        self.url = url; self.voice = voice; self.sampleRate = sampleRate; self.loop = loop; self.routeSpec = routeSpec
        lastSeek = start
        segs = [(0, Int(start * sampleRate))]
        let t = Thread { [self] in self.run(start) }
        t.qualityOfService = .userInitiated
        t.start()
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func seek(_ t: Double) {
        lock.lock(); seekReq = max(0, t); lastSeek = max(0, t); lock.unlock()
        voice.seekPending.store(true, ordering: .sequentiallyConsistent)
    }
    func setRoute(_ spec: String) {
        lock.lock()
        routeSpec = spec
        if srcCh > 0 { voice.setRoute(routePairs(spec, srcCh: srcCh)) }
        lock.unlock()
    }
    func position() -> Double {
        lock.lock(); defer { lock.unlock() }
        if voice.seekPending.load(ordering: .sequentiallyConsistent) { return lastSeek }
        let rd = max(voice.r.load(ordering: .sequentiallyConsistent), voice.skipTo.load(ordering: .sequentiallyConsistent))
        var best = segs.first ?? (0, 0)
        for s in segs where s.0 <= rd { best = s }
        return Double(best.1 + rd - best.0) / sampleRate
    }

    private func open(_ asset: AVURLAsset, _ tracks: [AVAssetTrack], at t: Double) -> (AVAssetReader, [AVAssetReaderTrackOutput])? {
        guard let rd = try? AVAssetReader(asset: asset) else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        var outs = [AVAssetReaderTrackOutput]()
        for tr in tracks {
            let o = AVAssetReaderTrackOutput(track: tr, outputSettings: settings)
            o.alwaysCopiesSampleData = false
            guard rd.canAdd(o) else { return nil }
            rd.add(o)
            outs.append(o)
        }
        rd.timeRange = CMTimeRange(start: CMTime(seconds: max(0, t), preferredTimescale: 48000), duration: .positiveInfinity)
        guard rd.startReading() else { return nil }
        return (rd, outs)
    }

    private func append(_ sb: CMSampleBuffer, _ ch: Int, _ fifo: inout [Float], _ tmp: inout [Float]) {
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return }
        let len = CMBlockBufferGetDataLength(bb)
        let ns = CMSampleBufferGetNumSamples(sb)
        if len <= 0 || ns <= 0 { return }
        let floats = len / 4
        if tmp.count < floats { tmp = [Float](repeating: 0, count: floats) }
        let ok = tmp.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: floats * 4, destination: $0.baseAddress!) }
        if ok != kCMBlockBufferNoErr { return }
        let chA = max(1, floats / ns)
        if chA == ch {
            fifo.append(contentsOf: tmp[0..<floats])
        } else {
            for k in 0..<ns { for j in 0..<ch { fifo.append(j < chA ? tmp[k * chA + j] : 0) } }
        }
    }

    private func run(_ start: Double) {
        let asset = AVURLAsset(url: url)
        let tracks = asset.tracks(withMediaType: .audio)
        let d = CMTimeGetSeconds(asset.duration)
        var chans = [Int](), use = [AVAssetTrack](), offsets = [Int]()
        var total = 0
        for t in tracks {
            var c = 2
            if let fd = (t.formatDescriptions as? [CMFormatDescription])?.first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) { c = Int(asbd.pointee.mChannelsPerFrame) }
            c = max(1, c)
            if total + c > 16 { break }
            offsets.append(total); chans.append(c); use.append(t); total += c
        }
        lock.lock()
        duration = d.isFinite ? d : 0
        srcCh = total
        noAudio = total == 0
        if total > 0 && !cancelled {
            voice.srcCh = total
            voice.capFrames = Voice.capFloats / total
            voice.setRoute(routePairs(routeSpec, srcCh: total))
            voice.active.store(true, ordering: .sequentiallyConsistent)
        }
        lock.unlock()
        if total == 0 { return }

        var fifos = [[Float]](repeating: [], count: use.count)
        var done = [Bool](repeating: false, count: use.count)
        var tmp = [Float](repeating: 0, count: 65536)
        var reader = open(asset, use, at: start)
        var ended = false
        if reader == nil { ended = true; voice.eof.store(true, ordering: .sequentiallyConsistent) }
        let cap = voice.capFrames
        let window = min(cap, Int(2.0 * sampleRate))

        while true {
            lock.lock()
            let stop = cancelled
            let sk = seekReq
            seekReq = nil
            lock.unlock()
            if stop { break }
            if let t = sk {
                reader?.0.cancelReading()
                reader = open(asset, use, at: t)
                for i in 0..<fifos.count { fifos[i].removeAll(keepingCapacity: true); done[i] = false }
                ended = reader == nil
                let wNow = voice.w.load(ordering: .sequentiallyConsistent)
                lock.lock()
                segs = [(wNow, Int(t * sampleRate))]
                let again = seekReq != nil
                lock.unlock()
                voice.eof.store(ended, ordering: .sequentiallyConsistent)
                voice.skipTo.store(wNow, ordering: .sequentiallyConsistent)
                if !again { voice.seekPending.store(false, ordering: .sequentiallyConsistent) }
            }
            let rEff = max(voice.r.load(ordering: .sequentiallyConsistent), voice.skipTo.load(ordering: .sequentiallyConsistent))
            let wr = voice.w.load(ordering: .sequentiallyConsistent)
            let space = window - (wr - rEff)
            guard !ended, space >= 1024, let rdr = reader else { usleep(4000); continue }

            for i in 0..<use.count where !done[i] && fifos[i].count < 4096 * chans[i] {
                if let sb = rdr.1[i].copyNextSampleBuffer() { append(sb, chans[i], &fifos[i], &tmp) } else { done[i] = true }
            }
            var avail = Int.max
            var anyData = false
            for i in 0..<use.count {
                let fr = fifos[i].count / chans[i]
                if fr > 0 { anyData = true }
                if !(done[i] && fr == 0) { avail = min(avail, fr) }
            }
            if !anyData && !done.contains(false) {
                if loop {
                    reader = open(asset, use, at: 0)
                    for i in 0..<done.count { done[i] = false }
                    lock.lock()
                    segs.append((wr, 0))
                    if segs.count > 8 { segs.removeFirst(segs.count - 4) }
                    lock.unlock()
                    if reader == nil { ended = true; voice.eof.store(true, ordering: .sequentiallyConsistent) }
                } else {
                    ended = true
                    voice.eof.store(true, ordering: .sequentiallyConsistent)
                }
                continue
            }
            if avail == Int.max || avail == 0 { continue }
            let n = min(avail, space)
            for i in 0..<use.count {
                let c = chans[i], off = offsets[i]
                let have = fifos[i].count / c
                fifos[i].withUnsafeBufferPointer { src in
                    for k in 0..<n {
                        let base = ((wr + k) % cap) * total + off
                        if k < have { for j in 0..<c { voice.ring[base + j] = src[k * c + j] } }
                        else { for j in 0..<c { voice.ring[base + j] = 0 } }
                    }
                }
                if have > 0 { fifos[i].removeFirst(min(have, n) * c) }
            }
            voice.w.store(wr + n, ordering: .sequentiallyConsistent)
        }
        reader?.0.cancelReading()
    }
}
