import Foundation

/// Live test part 6: collect a show folder, send it to the backup (second Show in this process), send again.
extension LiveTest {
    static func step6(_ show: Show, _ b: Show) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        let folder = tmp.appendingPathComponent("kimlab_show_" + String(getpid()))
        let recv = tmp.appendingPathComponent("kimlab_recv_" + String(getpid()))
        guard let wav = makeTestWav(seconds: 2) else { check("make sync test file", false); finish(); return }
        var c = Cue()
        c.num = "1"; c.name = "sync test"; c.file = wav.path; c.level = "-80"
        show.cues = [c]
        show.normalizeCues()
        show.collect(into: folder) { ok in
            let csv = (try? String(contentsOf: folder.appendingPathComponent("show.csv"), encoding: .utf8)) ?? ""
            check("collect: media copied into the show folder", ok && show.cues[0].file.hasPrefix(folder.path + "/media/") && fm.fileExists(atPath: show.cues[0].file))
            check("collect: showfile uses relative paths", csv.contains(",media/kimlab_test_") && !csv.contains(tmp.path))
            check("collect: original file left in place", fm.fileExists(atPath: wav.path))
            b.settings.receiveFolder = recv.path
            b.settings.syncPort = 7112
            b.settings.redundancy = "backup"
            b.cues = []
            b.configureLink()
            show.settings.redundancy = "main"
            show.settings.syncPort = 7112
            show.configureLink()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                check("sync: link is up again", show.peerAlive && b.peerAlive)
                show.sendShow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let got = recv.path + "/" + folder.lastPathComponent + "/media/" + (show.cues[0].file as NSString).lastPathComponent
                    check("sync: file arrived on the backup", fm.fileExists(atPath: got) && show.sameFile(show.cues[0].file, got))
                    check("sync: backup loaded the show (" + b.message + ")", b.cues.count == 1 && b.cues[0].file == got)
                    check("sync: main reports: " + show.message, show.message.hasPrefix("Sent to backup"))
                    show.sendShow()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        check("sync: second send skips media that is already there: " + show.message, show.message.contains("1 already there"))
                        finish()
                    }
                }
            }
        }
    }
}
