import Foundation

/// KIMLAB --idletest <report file>: measures the app's own CPU use with a 24-cue list, idle and while playing.
enum IdleTest {
    static var lines = [String]()

    static func cpu() -> Double {
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        return Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6 + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
    }

    static func run(_ show: Show, _ path: String) {
        show.settings.oscSend = false
        show.settings.midiSend = false
        var list = [Cue]()
        for i in 0..<24 {
            var c = Cue()
            c.num = String(i + 1)
            c.name = "cue " + String(i + 1)
            list.append(c)
        }
        guard let wav = makeTestWav(seconds: 20) else { exit(1) }
        list[0].file = wav.path
        list[0].level = "-40"
        list[0].fade = "0.5"
        list[0].fadeOut = "0.5"
        show.cues = list
        show.standby = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            let c0 = cpu(), t0 = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                lines.append(String(format: "idle: %.1f %% of one core", (cpu() - c0) / Date().timeIntervalSince(t0) * 100))
                show.lastGo = Date.distantPast
                show.go()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let c1 = cpu(), t1 = Date()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                        lines.append(String(format: "playing one audio cue: %.1f %% of one core", (cpu() - c1) / Date().timeIntervalSince(t1) * 100))
                        try? lines.joined(separator: NL).write(toFile: path, atomically: true, encoding: .utf8)
                        exit(0)
                    }
                }
            }
        }
    }
}
