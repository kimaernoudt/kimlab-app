import SwiftUI
import AppKit
import Synchronization

@main
struct Main {
    static func main() {
        if CommandLine.arguments.contains("--selftest") { exit(selfTest()) }
        KimlabApp.main()
    }
}

struct KimlabApp: App {
    @StateObject private var show = Show()
    var body: some Scene {
        WindowGroup("KIMLAB") {
            ContentView()
                .environmentObject(show)
                .frame(minWidth: 1480, minHeight: 950)
                .preferredColorScheme(.dark)
                .onAppear { startUp(show) }
        }
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

/// Engine checks that need no audio hardware: run with  KIMLAB --selftest
func selfTest() -> Int32 {
    var fails = 0
    func check(_ name: String, _ ok: Bool) {
        print((ok ? "PASS  " : "FAIL  ") + name)
        if !ok { fails += 1 }
    }
    check("timecode parse", abs((TC.parse("01:02:03:12", fps: 25) ?? 0) - 3723.48) < 0.000001)
    check("timecode format", TC.format(3723.48, fps: 25) == "01:02:03:12")
    check("outs 1-2", parseOuts("1-2").outs == [0, 1])
    check("outs 5-12", parseOuts("5-12").outs.count == 8)
    check("outs 5 (open)", parseOuts("5").openEnded && parseOuts("5").outs == [4])
    check("route mono to pair", routePairs("3,4", srcCh: 1).count == 2)
    let r51 = routePairs("5", srcCh: 6)
    check("route 5.1 from output 5", r51.count == 6 && r51[5].0 == 5 && r51[5].1 == 9)

    var c = Cue()
    c.name = "A, " + QS + "quoted" + QS
    c.file = "/x/y.wav"
    c.loop = true
    c.with = true
    let rows = CSV.parse(CSV.write([Cue.columns, c.row]))
    var csvOK = false
    if rows.count == 2 {
        let back = Cue(header: rows[0], row: rows[1])
        csvOK = back.name == c.name && back.loop && back.with && back.file == c.file && back.isAudio
    }
    check("showfile CSV roundtrip", csvOK)

    let msg = OSC.decode(OSC.encode("/cue/goto", [7, "x", 1.5, true]))
    var oscOK = false
    if msg.count == 1, msg[0].1.count == 4 {
        oscOK = msg[0].0 == "/cue/goto" && (msg[0].1[0] as? Int) == 7 && (msg[0].1[1] as? String) == "x"
            && (msg[0].1[2] as? Double) == 1.5 && (msg[0].1[3] as? Bool) == true
    }
    check("OSC encode/decode", oscOK)

    let cases: [(Double, Int)] = [(48000, 25), (44100, 30), (96000, 24), (48000, 30)]
    for (sr, fps) in cases {
        let enc = LTCEncoder()
        enc.fps = fps
        let dec = LTCDecoder()
        let start = ((1 * 60 + 2) * 60 + 3) * fps + 4
        enc.jam.store(start, ordering: .sequentiallyConsistent)
        enc.running.store(true, ordering: .sequentiallyConsistent)
        let n = 512
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: n)
        for _ in 0..<(Int(sr) * 2 / n) {
            for i in 0..<n { buf[i] = 0 }
            enc.render(buf, frames: n, sampleRate: sr)
            dec.process(UnsafePointer(buf), frames: n, sampleRate: sr, hostTime: 1, ticksPerSample: 0)
        }
        buf.deallocate()
        let got = dec.frame.load(ordering: .relaxed)
        let sent = enc.current.load(ordering: .relaxed)
        let ok = got >= start + fps && abs(got - sent) <= 1 && dec.fps.load(ordering: .relaxed) == fps
        check("LTC encode/decode " + String(Int(sr)) + " Hz " + String(fps) + " fps (sent " + String(sent) + ", read " + String(got) + ")", ok)
    }

    // mixer voice: routing + gain through the real render path is covered when the app runs; here the ring maths
    let v = Voice()
    v.srcCh = 2
    v.capFrames = Voice.capFloats / 2
    v.setRoute(routePairs("3-4", srcCh: 2))
    let rt = v.route.load(ordering: .sequentiallyConsistent)
    check("voice route table", (rt & 0xFFFF) == 2 && v.pairs[(rt >> 16) * 128 + 1] == 2 && v.pairs[(rt >> 16) * 128 + 3] == 3)

    selfTestAudio(check)
    print(fails == 0 ? "ALL PASS" : String(fails) + " FAILED")
    return fails == 0 ? 0 : 1
}
