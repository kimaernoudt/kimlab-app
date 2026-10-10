import Foundation
import AVFoundation
import Synchronization

/// Runs a real file through Feeder -> Voice -> Mixer without an audio device and checks what comes out.
func selfTestAudio(_ check: (String, Bool) -> Void) {
    // 1 s stereo 48 kHz 16-bit WAV: left = 0.5, right = 0.25
    let sr = 48000, frames = 48000
    var b = [UInt8]()
    func u32(_ v: Int) { b += [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8((v >> 24) & 255)] }
    func u16(_ v: Int) { b += [UInt8(v & 255), UInt8((v >> 8) & 255)] }
    b += Array("RIFF".utf8); u32(36 + frames * 4); b += Array("WAVEfmt ".utf8)
    u32(16); u16(1); u16(2); u32(sr); u32(sr * 4); u16(4); u16(16)
    b += Array("data".utf8); u32(frames * 4)
    for _ in 0..<frames { u16(16384); u16(8192) }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kimlab_selftest.wav")
    do { try Data(b).write(to: url) } catch { check("audio: write test file", false); return }

    let mixer = Mixer()
    let outCh = 8, n = 512
    let bl = AudioBufferList.allocate(maximumBuffers: outCh)
    for i in 0..<outCh { bl[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: calloc(n, 4)) }
    func render() {
        for i in 0..<outCh { memset(bl[i].mData, 0, n * 4) }
        if let r = mixer.hal.render { r(bl, n, mach_absolute_time()) }
    }
    func sample(_ ch: Int, _ i: Int) -> Float { bl[ch].mData!.assumingMemoryBound(to: Float.self)[i] }
    func waitFor(_ cond: () -> Bool) -> Bool {
        for _ in 0..<400 { if cond() { return true }; usleep(5000) }
        return cond()
    }
    func buffered(_ v: Voice) -> Int { v.w.load(ordering: .sequentiallyConsistent) - v.r.load(ordering: .sequentiallyConsistent) }

    guard let vi = mixer.acquire() else { check("audio: free voice", false); return }
    let v = mixer.voices[vi]
    v.reset(level: 0.5, fadeIn: 0, sampleRate: 48000, hold: false)
    let f = Feeder(url: url, voice: v, sampleRate: 48000, start: 0, loop: false, routeSpec: "3-4")
    check("audio: file decodes", waitFor { buffered(v) >= 2048 })
    render()
    check("audio: routed to outputs 3-4 at -6 dB", abs(sample(2, 100) - 0.25) < 0.01 && abs(sample(3, 100) - 0.125) < 0.01 && sample(0, 100) == 0)
    check("audio: position after one block", abs(f.position() - Double(n) / 48000) < 0.001)
    check("audio: duration", abs(f.duration - 1.0) < 0.01)
    mixer.mute[2] = true
    render()
    check("audio: mute", sample(2, 100) == 0 && sample(3, 100) != 0)
    mixer.mute[2] = false
    mixer.solo[3] = true
    render()
    check("audio: solo", sample(2, 100) == 0 && sample(3, 100) != 0)
    mixer.solo[3] = false
    mixer.pink[0] = true
    render()
    check("audio: pink noise", sample(0, 100) != 0 || sample(0, 101) != 0)
    mixer.pink[0] = false

    f.seek(0.5)
    let flushed = waitFor { !v.seekPending.load(ordering: .sequentiallyConsistent) && buffered(v) >= n }
    render()
    check("audio: seek to 0.5 s", flushed && abs(f.position() - (0.5 + Double(n) / 48000)) < 0.002 && abs(sample(2, 100) - 0.25) < 0.01)
    var blocks = 0
    while !v.finished.load(ordering: .sequentiallyConsistent) && blocks < 400 {
        _ = waitFor { buffered(v) >= n || v.eof.load(ordering: .sequentiallyConsistent) }
        render()
        blocks += 1
    }
    check("audio: plays to the end and stops (" + String(blocks) + " blocks)", v.finished.load(ordering: .sequentiallyConsistent) && blocks >= 40 && blocks <= 60)
    f.cancel()
    mixer.release(vi)

    guard let wi = mixer.acquire() else { check("audio: second voice", false); return }
    let v2 = mixer.voices[wi]
    v2.reset(level: 1, fadeIn: 0, sampleRate: 48000, hold: false)
    let f2 = Feeder(url: url, voice: v2, sampleRate: 48000, start: 0, loop: true, routeSpec: "1")
    for _ in 0..<150 {
        _ = waitFor { buffered(v2) >= n }
        render()
    }
    let pos = f2.position()
    check("audio: loop keeps playing (position " + String(format: "%.2f", pos) + " s)", !v2.finished.load(ordering: .sequentiallyConsistent) && sample(0, 100) > 0.4 && sample(1, 100) > 0.2 && pos < 1.0)
    v2.fade(to: 0, seconds: 0.05, sampleRate: 48000, thenStop: true)
    for _ in 0..<10 { render() }
    check("audio: fade-out frees the voice", v2.finished.load(ordering: .sequentiallyConsistent))
    f2.cancel()
    mixer.release(wi)
}
