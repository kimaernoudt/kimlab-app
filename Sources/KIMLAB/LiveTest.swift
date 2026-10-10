import Foundation
import AVFoundation
import AppKit
import Synchronization

/// App start. With  --livetest <report file>  the app plays generated test media through the real
/// audio device and video players, measures sync, writes a report and quits. Nothing is saved in that mode.
func startUp(_ show: Show) {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--idletest") {
        show.noPersist = true
        show.setup()
        IdleTest.run(show, i + 1 < args.count ? args[i + 1] : "/tmp/kimlab_idle.txt")
        return
    }
    if let i = args.firstIndex(of: "--livetest") {
        show.noPersist = true
        show.setup()
        show.settings.oscSend = false
        show.settings.midiSend = false
        LiveTest.run(show, report: i + 1 < args.count ? args[i + 1] : "/tmp/kimlab_livetest.txt")
    } else {
        show.setup()
    }
}

func makeTestWav(seconds: Int) -> URL? {
    let sr = 48000, frames = 48000 * seconds
    var b = [UInt8]()
    func u32(_ v: Int) { b += [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8((v >> 24) & 255)] }
    func u16(_ v: Int) { b += [UInt8(v & 255), UInt8((v >> 8) & 255)] }
    b += Array("RIFF".utf8); u32(36 + frames * 4); b += Array("WAVEfmt ".utf8)
    u32(16); u16(1); u16(2); u32(sr); u32(sr * 4); u16(4); u16(16)
    b += Array("data".utf8); u32(frames * 4)
    b.reserveCapacity(b.count + frames * 4)
    for _ in 0..<frames { u16(16384); u16(8192) }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kimlab_test_" + String(getpid()) + ".wav")
    do { try Data(b).write(to: url) } catch { return nil }
    return url
}

func makeTestMovie(seconds: Int) -> URL? {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kimlab_test_" + String(getpid()) + ".mov")
    guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360])
    let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)
    input.expectsMediaDataInRealTime = false
    guard w.canAdd(input) else { return nil }
    w.add(input)
    guard w.startWriting() else { return nil }
    w.startSession(atSourceTime: .zero)
    for i in 0..<(seconds * 25) {
        var tries = 0
        while !input.isReadyForMoreMediaData && tries < 2000 { usleep(2000); tries += 1 }
        var pb: CVPixelBuffer? = nil
        guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        if let base = CVPixelBufferGetBaseAddress(buf) {
            memset(base, Int32(40 + (i * 3) % 200), CVPixelBufferGetBytesPerRow(buf) * CVPixelBufferGetHeight(buf))
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        if !adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 25)) { return nil }
    }
    input.markAsFinished()
    let sem = DispatchSemaphore(value: 0)
    w.finishWriting { sem.signal() }
    sem.wait()
    return w.status == .completed ? url : nil
}

enum LiveTest {
    static var lines = [String]()
    static var fails = 0
    static var path = ""

    static func check(_ name: String, _ ok: Bool) {
        lines.append((ok ? "PASS  " : "FAIL  ") + name)
        if !ok { fails += 1 }
    }
    static func finish() {
        lines.append(fails == 0 ? "ALL PASS" : String(fails) + " FAILED")
        try? lines.joined(separator: NL).write(toFile: path, atomically: true, encoding: .utf8)
        exit(fails == 0 ? 0 : 1)
    }
    static func f3(_ v: Double) -> String { String(format: "%.3f", v) }

    static func run(_ show: Show, report: String) {
        path = report
        DispatchQueue.global().async {
            let mov = makeTestMovie(seconds: 8)
            let wav = makeTestWav(seconds: 8)
            DispatchQueue.main.async {
                guard let m = mov, let wv = wav else { check("make test media", false); finish(); return }
                var a = Cue()
                a.num = "1"; a.name = "test video"; a.file = m.path; a.level = "-80"; a.fade = "0"
                var b = Cue()
                b.num = "2"; b.name = "test audio"; b.file = wv.path; b.level = "-80"; b.fade = "0"; b.with = true
                var g = Cue()
                g.num = "0"; g.name = "test group"; g.group = true
                a.with = true
                show.cues = [g, a, b]
                show.standby = 0
                show.preloadStandby()
                check("audio device running (" + String(Int(show.mixer.sampleRate)) + " Hz, " + String(show.mixer.channels) + " ch)", show.mixer.hal.running)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { step1(show) }
            }
        }
    }

    static func step1(_ show: Show) {
        check("standby video preloaded", show.video.ready(0) || show.video.ready(1))
        let t0 = Date()
        show.go()
        check("GO started a group of two", show.playing.count == 2)
        check("standby moved to end of list", show.standby == 3)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { step2(show, t0) }
    }

    static func step2(_ show: Show, _ t0: Date) {
        let el = Date().timeIntervalSince(t0)
        guard let vp = show.playing.first(where: { $0.isVideo }), let ap = show.playing.first(where: { !$0.isVideo }) else {
            check("both cues still playing", false); finish(); return
        }
        let vpos = show.position(vp), apos = show.position(ap)
        let latency = el - vpos
        check("both launched", vp.launched && ap.launched)
        check("video running: position " + f3(vpos) + " s after " + f3(el) + " s (GO latency " + f3(latency) + " s)", vpos > 1.5 && latency >= 0 && latency < 0.5)
        check("audio in sync with video: " + f3(apos) + " vs " + f3(vpos) + " (diff " + f3(abs(apos - vpos)) + " s)", abs(apos - vpos) < 0.05)
        check("audio callbacks arriving (" + String(show.mixer.cycle.load(ordering: .relaxed)) + ")", show.mixer.cycle.load(ordering: .relaxed) > 50)
        check("video duration read (" + f3(show.duration(vp)) + " s)", abs(show.duration(vp) - 8.0) < 0.2)
        check("group row shows as playing", show.live.rows[show.cues[0].id] != nil)
        show.live.timelineCue = show.cues[0].id
        show.seekTimeline(seconds: 5.0)
        let t1 = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { step3(show, t1) }
    }

    static func step3(_ show: Show, _ t1: Date) {
        let el = Date().timeIntervalSince(t1)
        guard let vp = show.playing.first(where: { $0.isVideo }), let ap = show.playing.first(where: { !$0.isVideo }) else {
            check("both cues playing after seek", false); finish(); return
        }
        let vpos = show.position(vp), apos = show.position(ap)
        let want = 5.0 + el - 0.12
        check("seek: video at " + f3(vpos) + " s, expected about " + f3(want), abs(vpos - want) < 0.15)
        check("seek: audio still in sync (diff " + f3(abs(apos - vpos)) + " s)", abs(apos - vpos) < 0.05)
        show.trigger("blackout")
        show.trigger("blackout")
        show.stopAll(fade: 0.2)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            check("STOP: nothing playing", show.playing.isEmpty)
            check("STOP: all voices free", show.mixer.busyVoices == 0)
            check("output window open (" + show.video.resolution + ")", show.video.windowOpen)
            step4(show)
        }
    }
}
