import Foundation
import AppKit

/// Live test part 5: group structure, file lengths, and a main + backup pair running in this one process.
extension LiveTest {
    static var peer: Show? = nil

    static func step5(_ show: Show) {
        // explicit group membership
        var g = Cue()
        g.group = true; g.name = "G"
        var x = Cue()
        x.name = "x"; x.with = true
        var y = Cue()
        y.name = "y"
        show.cues = [g, x, y]
        show.normalizeCues()
        check("older list: linked cue under a group becomes its subcue", show.cues[1].parent == g.id.uuidString && show.cues[2].parent.isEmpty)
        show.select(y.id)
        show.toggleInGroup()
        check("IN GROUP puts a cue into the group above", show.cues[2].parent == g.id.uuidString && show.cues[2].with)
        show.toggleInGroup()
        check("IN GROUP takes it out again", show.cues[2].parent.isEmpty && !show.cues[2].with)
        show.dropFiles([URL(fileURLWithPath: "/tmp/a.wav"), URL(fileURLWithPath: "/tmp/b.wav")], onto: x.id)
        let names = show.cues.map { $0.name }.joined(separator: " ")
        check("files dropped on a subcue land before it, in the group (" + names + ")", names == "G a b x y" && show.cues[1].with && show.cues[2].with && !show.cues[4].with)
        show.select(g.id)
        show.deleteSelected()
        show.deleteSelected()
        check("deleting a group keeps its subcues as normal cues", show.cues.count == 4 && !show.cues.contains(where: { $0.with || !$0.parent.isEmpty }))

        guard let wav = makeTestWav(seconds: 6) else { check("make link test file", false); finish(); return }
        var c1 = Cue()
        c1.num = "1"; c1.name = "link test"; c1.file = wav.path; c1.level = "-80"; c1.fade = "0"; c1.fadeOut = "0.1"
        let b = Show()
        b.noPersist = true
        peer = b
        b.setup()
        b.settings.oscSend = false
        b.settings.midiSend = false
        show.cues = [c1]
        b.cues = [c1]
        show.standby = 0
        b.standby = 0
        show.settings.redundancy = "main"; show.settings.linkListen = 7101; show.settings.peerHost = "127.0.0.1"; show.settings.peerPort = 7102
        b.settings.redundancy = "backup"; b.settings.linkListen = 7102; b.settings.peerHost = "127.0.0.1"; b.settings.peerPort = 7101
        show.configureLink()
        b.configureLink()
        show.refreshDevices()
        show.refreshLengths()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { link1(show, b, c1) }
    }

    static func pos(_ s: Show) -> Double {
        guard let p = s.playing.first(where: { $0.launched && !$0.stopping }) else { return -1 }
        return s.position(p)
    }

    static func link1(_ show: Show, _ b: Show, _ c1: Cue) {
        check("file length read for the cue list (" + f3(show.lengths[c1.file] ?? -1) + " s)", abs((show.lengths[c1.file] ?? -1) - 6.0) < 0.05)
        check("link: main and backup see each other", show.peerAlive && b.peerAlive && show.linkNote.isEmpty && b.linkNote.isEmpty)
        show.lastGo = Date.distantPast
        show.trigger("go")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let a = pos(show), c = pos(b)
            check("link: GO on main starts the backup (main " + f3(a) + " s, backup " + f3(c) + " s)", a > 0.5 && c > 0.5 && abs(a - c) < 0.15)
            check("link: backup standby follows", b.standby == show.standby)
            show.live.timelineCue = c1.id
            show.seekTimeline(seconds: 3.0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let a2 = pos(show), c2 = pos(b)
                check("link: seek is mirrored (main " + f3(a2) + " s, backup " + f3(c2) + " s)", a2 > 3.3 && abs(a2 - c2) < 0.2)
                show.trigger("stop")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    check("link: STOP is mirrored", show.playing.isEmpty && b.playing.isEmpty)
                    show.standby = 0
                    show.lastGo = Date.distantPast
                    show.trigger("go")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        b.stopAll(fade: 0)        // the backup falls out of step
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { link2(show, b) }
                    }
                }
            }
        }
    }

    static func link2(_ show: Show, _ b: Show) {
        let a = pos(show), c = pos(b)
        check("link: backup resyncs by itself (main " + f3(a) + " s, backup " + f3(c) + " s)", a > 3 && c > 0 && abs(a - c) < 0.3)
        check("link: backup keeps quiet towards other gear while main is alive", b.linkSuppress && !show.linkSuppress)
        show.settings.redundancy = "off"        // bypass on the main: the backup must raise the alarm
        show.configureLink()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.7) {
            check("link: backup notices the main is gone (" + b.message + ")", !b.peerAlive && b.message.contains("LOST") && !b.linkSuppress)
            check("bypass: main runs alone", !show.linkOn && !show.peerAlive)
            show.stopAll(fade: 0)
            b.stopAll(fade: 0)
            step6(show, b)
        }
    }
}
