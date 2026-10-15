import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Synchronization

extension Show {
    // MARK: 30 Hz tick

    func tick() {
        tickCount += 1
        for c in 0..<outChannels {
            let pk = mixer.peak[c]
            mixer.peak[c] = 0
            let v = max(pk, live.peaks[c] * 0.82)
            live.peaks[c] = v < 0.0001 ? 0 : v
            if pk > live.holds[c] { live.holds[c] = pk }
        }
        for p in Array(playing) where !p.stopping && p.launched {
            guard let c = cue(p.cue) else { stop(p, fade: 0.05); continue }
            if holdDone(p, c) { continue }
            if let vi = p.voice {
                let v = mixer.voices[vi]
                if !p.isVideo && v.finished.load(ordering: .sequentiallyConsistent) { ended(p); continue }
                v.level = c.levelLin
                if c.audioOut != p.routeSpec {
                    p.routeSpec = c.audioOut
                    p.feeder?.setRoute(c.audioOut)
                }
            }
            if settings.autoFollow, !p.followDone, let secs = parseNum(c.follow), Date().timeIntervalSince(p.started) >= secs {
                p.followDone = true
                fireNext(after: c)
            }
        }
        tcTick()
        linkTick()
        var rows = [UUID: RowInfo]()
        for p in playing where !p.stopping {
            rows[p.cue] = RowInfo(pos: position(p), dur: duration(p), loop: cue(p.cue)?.loop ?? false)
        }
        groupTick(&rows)
        live.rows = rows
        live.liveVideo = playing.last(where: { $0.isVideo && !$0.stopping })?.cue
        if let s = selected, rows[s] != nil { live.timelineCue = s }
        else { live.timelineCue = live.liveVideo ?? playing.first(where: { !$0.stopping })?.cue }
        if tickCount % 30 == 0 { updateSys(); preloadStandby() }
        if tickCount % 60 == 0 && dirty { saveState() }
        publishLive(rows.isEmpty)
        countdownTick()
    }

    func updateSys() {
        let devName = devices.first(where: { $0.id == mixer.hal.deviceID })?.name ?? "-"
        let load = mixer.loadPeak
        mixer.loadPeak = 0
        var s = [(String, String)]()
        s.append(("AUDIO", devName))
        s.append(("FORMAT", String(Int(mixer.sampleRate)) + " Hz / " + String(mixer.channels) + " ch"))
        s.append(("DSP LOAD", String(format: "%.0f %%", load * 100)))
        s.append(contentsOf: sysMeter.rows())
        refreshLengths()
        s.append(("VOICES", String(mixer.busyVoices) + " / " + String(Mixer.maxVoices)))
        s.append(("PLAYER A", video.status(0)))
        s.append(("PLAYER B", video.status(1)))
        s.append(("OUTPUT", video.windowOpen ? video.resolution : "closed"))
        s.append(("TC MODE", settings.followTC ? (settings.tcChase ? "FOLLOW+CHASE" : "FOLLOW") : "FREE RUN"))
        s.append(("TC IN", live.tcInLocked ? "LOCKED" : "no signal"))
        s.append(("MIDI IN", Date().timeIntervalSince(lastMidi) < 1 ? "active" : "idle"))
        s.append(("OSC IN", Date().timeIntervalSince(lastOsc) < 1 ? "active" : "idle"))
        if tickCount % 90 == 0 || tickCount <= 30 { refreshMissing() }
        live.sys = s
        live.sysTick.bump()
        if outputOpen != video.windowOpen { outputOpen = video.windowOpen }
    }

    // MARK: timecode

    func chaseBase(_ p: Playing) -> Double? {
        guard let i = index(p.cue) else { return nil }
        let c = cues[i]
        if c.loop || c.isImage { return nil }
        let on = c.chase.isEmpty ? settings.tcChase : c.chase == "1"
        if !on { return nil }
        return TC.parse(c.tc, fps: settings.fps) ?? TC.parse(cues[headOf(i)].tc, fps: settings.fps)
    }

    func tcTick() {
        let fps = max(1, settings.fps)
        var tcNow: Double? = nil
        if settings.tcSource == "ltc" {
            let st = ltcDec.stampHost.load(ordering: .sequentiallyConsistent)
            let fr = ltcDec.frame.load(ordering: .relaxed)
            let now = mach_absolute_time()
            if st != 0 && fr >= 0 && now >= st {
                let age = Double(now - st) * hostToSec
                if age < 0.2 { tcNow = Double(fr) / Double(max(1, ltcDec.fps.load(ordering: .relaxed))) + age }
            }
            live.ltcLevel = ltcDec.peak
            ltcDec.peak = 0
        } else if let o = oscTC {
            let age = Date().timeIntervalSince(o.1)
            if age < 0.5 { tcNow = o.0 + age }
        }
        live.tcInLocked = tcNow != nil
        if let t = tcNow { live.tcIn = TC.format(t, fps: fps) } else { live.tcIn = "--:--:--:--" }

        // timecode out: cue TC + clip position of the live cue
        var outT: Double? = nil
        if settings.sendTC {
            let on = playing.filter { $0.launched && !$0.stopping && !$0.chasePaused }
            if let p = on.last(where: { $0.isVideo }) ?? on.first, let c = cue(p.cue) {
                outT = (TC.parse(c.tc, fps: fps) ?? 0) + position(p)
            }
        }
        if let t = outT {
            let f = Double(ltcEnc.fps)
            let cur = Double(ltcEnc.current.load(ordering: .relaxed)) / f
            if !ltcEnc.running.load(ordering: .relaxed) || abs(cur - t) > 1.5 / f {
                ltcEnc.jam.store(Int((t * f).rounded(.down)), ordering: .sequentiallyConsistent)
            }
            ltcEnc.running.store(true, ordering: .sequentiallyConsistent)
            live.tcOut = TC.format(t, fps: fps)
            if settings.oscSend && tickCount % 2 == 0 { osc.send("/tc", [live.tcOut], host: settings.oscOutHost, port: settings.oscOutPort) }
        } else {
            ltcEnc.running.store(false, ordering: .sequentiallyConsistent)
            live.tcOut = "--:--:--:--"
        }

        // follow + chase
        guard settings.followTC else { tcCue = nil; lastTC = nil; return }
        guard let t = tcNow else {
            if settings.tcChase { for p in playing where p.chasing && p.launched && !p.stopping && !p.chasePaused { pause(p) } }
            lastTC = nil
            return
        }
        let dt = Date().timeIntervalSince(lastTCAt)
        var jumped = true
        if let l = lastTC { jumped = abs(t - (l + dt)) > 0.5 }
        lastTC = t
        lastTCAt = Date()
        var target: Int? = nil
        var best = -1.0
        for (i, c) in cues.enumerated() where !c.with {
            if let b = TC.parse(c.tc, fps: fps), b <= t, b >= best { best = b; target = i }
        }
        if let tg = target {
            let id = cues[tg].id
            let on = isPlaying(id)
            if tcCue != id || (jumped && !on) {
                tcCue = id
                if !on {
                    fireGroup(tg, offset: settings.tcChase ? max(0, t - best) : 0, viaTC: true)
                    standby = nextHead(after: tg)
                    preloadStandby()
                }
            }
        }
        guard settings.tcChase else { return }
        let tol = max(2.0 / fps, 0.06)
        for p in playing where p.launched && !p.stopping {
            guard let base = chaseBase(p) else { continue }
            let want = t - base
            if want < 0 { continue }
            p.chasing = true
            if p.chasePaused { relocate(p, to: want + 0.2); continue }
            if Date().timeIntervalSince(p.lastRelocate) < 1.0 || Date().timeIntervalSince(p.started) < 0.5 { continue }
            if abs(position(p) - want) > tol { relocate(p, to: want + 0.2) }
        }
    }

    // MARK: outputs

    func logOSC(_ s: String) {
        oscLog.append(s)
        if oscLog.count > 8 { oscLog.removeFirst(oscLog.count - 8) }
    }
    func logMIDI(_ s: String) {
        midiLog.append(s)
        if midiLog.count > 8 { midiLog.removeFirst(midiLog.count - 8) }
    }
    func sendOSCCore(_ addr: String, _ args: [Any]) {
        guard settings.oscSend else { return }
        osc.send(addr, args, host: settings.oscOutHost, port: settings.oscOutPort)
        logOSC("OUT " + addr + " " + args.map { String(describing: $0) }.joined(separator: " "))
    }
    func sendMIDICore(_ bytes: [UInt8]) {
        guard settings.midiSend else { return }
        midi.send(bytes)
        logMIDI("OUT " + bytes.map { String($0) }.joined(separator: " "))
    }
    func sendNote(_ n: UInt8, _ vel: UInt8, _ ch: Int) {
        let c = UInt8(max(0, min(15, ch - 1)))
        sendMIDI([0x90 | c, n, vel])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let s = self, s.settings.midiSend else { return }
            s.midi.send([0x80 | c, n, 0])
        }
    }
    func cueOutputs(_ c: Cue) {
        var idArg: Any = c.num
        if let n = Int(c.num) { idArg = n }
        sendOSC("/cue/fired", [idArg, c.name])
        if !c.oscOut.isEmpty { sendOSC(c.oscOut, [1]) }
        if let n = Int(c.midiOut), n >= 0, n < 128 { sendNote(UInt8(n), 127, 1) }
    }
    func fireShortcut(_ i: Int) {
        guard i >= 0 && i < shortcuts.count else { return }
        let s = shortcuts[i]
        let ch = UInt8(max(0, min(15, (Int(s.channel) ?? 1) - 1)))
        let val = UInt8(max(0, min(127, Int(s.value) ?? 127)))
        let type = s.type.lowercased()
        if type == "osc" {
            var args = [Any]()
            for part in s.value.split(separator: " ") {
                if let n = Int(part) { args.append(n) } else if let d = Double(part) { args.append(d) } else { args.append(String(part)) }
            }
            if !s.target.isEmpty { sendOSC(s.target, args) }
            return
        }
        guard let n = Int(s.target), n >= 0, n < 128 else { return }
        if type == "note" { sendNote(UInt8(n), max(1, val), Int(ch) + 1) }
        else if type == "cc" { sendMIDI([0xB0 | ch, UInt8(n), val]) }
        else if type == "pc" { sendMIDI([0xC0 | ch, UInt8(n)]) }
    }

    // MARK: actions (buttons, MIDI, OSC, keyboard all end up here)

    func press(_ a: String) {
        if learning { learnTarget = (learnTarget == a) ? nil : a; return }
        if locked && a != "lock" { return }
        trigger(a)
    }

    func triggerCore(_ a: String) {
        switch a {
        case "go": go()
        case "prev": prev()
        case "next": next()
        case "stop": stopAll(fade: -1)
        case "audiostop": stopAudio()
        case "blackout":
            blackout.toggle()
            video.setBlackout(blackout)
        case "test":
            testPattern.toggle()
            video.setTest(testPattern)
        case "lock": locked.toggle()
        case "keys": settings.keyboard.toggle()
        case "auto": settings.autoFollow.toggle()
        case "tcfollow":
            settings.followTC.toggle()
            configureLTCIn()
        case "tcchase": settings.tcChase.toggle()
        case "sendtc":
            settings.sendTC.toggle()
            configureLTCOut()
        case "resetpk":
            for i in 0..<Mixer.maxOut { live.holds[i] = 0 }
            live.meterTick.bump()
        case "gocue": if let i = selectedIndex { fireCue(at: i) }
        case "output":
            if video.windowOpen { video.closeWindow() } else { video.openWindow() }
            outputOpen = video.windowOpen
        case "countdown": toggleCountdown()
        case "ndi": toggleNDI()
        default:
            if a.hasPrefix("mute"), let n = Int(a.dropFirst(4)) { toggleOut(0, n - 1) }
            else if a.hasPrefix("solo"), let n = Int(a.dropFirst(4)) { toggleOut(1, n - 1) }
            else if a.hasPrefix("pink"), let n = Int(a.dropFirst(4)) { toggleOut(2, n - 1) }
            else if a.hasPrefix("f"), let n = Int(a.dropFirst(1)), n >= 1, n <= 8 { fireShortcut(n - 1) }
        }
    }

    func toggleOut(_ kind: Int, _ ch: Int) {
        guard ch >= 0 && ch < Mixer.maxOut else { return }
        if kind == 0 { mutes[ch].toggle(); mixer.mute[ch] = mutes[ch] }
        else if kind == 1 { solos[ch].toggle(); mixer.solo[ch] = solos[ch] }
        else { pinks[ch].toggle(); mixer.pink[ch] = pinks[ch] }
    }

    func learnButton() {
        if !learning { learning = true; learnTarget = nil }
        else if let t = learnTarget { midimap.removeAll { $0.action == t }; learnTarget = nil }
        else { learning = false }
    }

    func midiIn(_ status: UInt8, _ d1: UInt8, _ d2: UInt8) {
        lastMidi = Date()
        let type = status & 0xF0
        let ch = Int(status & 0x0F) + 1
        let kindName = type == 0x90 ? "NOTE" : (type == 0x80 ? "OFF" : (type == 0xB0 ? "CC" : (type == 0xC0 ? "PC" : "MSG")))
        logMIDI("IN  " + kindName + " " + String(d1) + " " + String(d2) + " ch" + String(ch))
        let noteOn = type == 0x90 && d2 > 0
        let cc = type == 0xB0 && d2 > 0
        guard noteOn || cc else { return }
        let kind = noteOn ? "note" : "cc"
        if learning {
            if let t = learnTarget {
                midimap.removeAll { $0.action == t }
                midimap.append(MidiBind(action: t, type: kind, channel: ch, number: Int(d1)))
                learnTarget = nil
            }
            return
        }
        for b in midimap where b.type == kind && b.number == Int(d1) && (b.channel == 0 || b.channel == ch) { trigger(b.action) }
        if noteOn, let i = cues.firstIndex(where: { Int($0.midiIn) == Int(d1) }) { fireCue(at: i) }
    }

    func oscIn(_ addr: String, _ args: [Any]) {
        lastOsc = Date()
        logOSC("IN  " + addr + " " + args.map { String(describing: $0) }.joined(separator: " "))
        var flag: Bool? = nil
        var number: Double? = nil
        var text = ""
        if let i = args.first as? Int { flag = i != 0; number = Double(i); text = String(i) }
        else if let d = args.first as? Double { flag = d != 0; number = d; text = String(Int(d)) }
        else if let b = args.first as? Bool { flag = b }
        else if let s = args.first as? String { number = parseNum(s); text = s }
        switch addr {
        case "/cue/go": trigger("go")
        case "/cue/prev": trigger("prev")
        case "/cue/next": trigger("next")
        case "/cue/stop": trigger("stop")
        case "/cue/goto": if let i = cues.firstIndex(where: { $0.num == text }) { fireCue(at: i) }
        case "/audio/resetpeaks": trigger("resetpk")
        case "/audio/stop": trigger("audiostop")
        case "/out/blackout": if flag == nil || flag != blackout { trigger("blackout") }
        case "/out/test": if flag == nil || flag != testPattern { trigger("test") }
        case "/ui/lock": if flag == nil || flag != locked { trigger("lock") }
        case "/out/countdown": if flag == nil || flag != countdownOpen { trigger("countdown") }
        case "/out/ndi": if flag == nil || flag != settings.countdownNDI { trigger("ndi") }
        case "/tc": if let t = TC.parse(text, fps: settings.fps) { oscTC = (t, Date()) }
        case "/timeline/skip": if let v = number { skip(v) }
        case "/timeline/seek": if let v = number { seekTimeline(seconds: v) }
        default:
            if addr.hasPrefix("/shortcut/"), let n = Int(addr.dropFirst(10)), n >= 1, n <= 8 { fireShortcut(n - 1) }
        }
    }

    func installKeys() {
        _ = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let s = self, s.settings.keyboard else { return e }
            if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.control) || e.modifierFlags.contains(.option) { return e }
            if let r = NSApp.keyWindow?.firstResponder, r is NSTextView { return e }
            switch e.keyCode {
            case 49: s.trigger("go"); return nil
            case 123: s.trigger("prev"); return nil
            case 124: s.trigger("next"); return nil
            case 126: s.selectMove(-1); return nil
            case 125: s.selectMove(1); return nil
            default: break
            }
            let ch = e.charactersIgnoringModifiers ?? ""
            if ch == "x" { s.trigger("stop") }
            else if ch == "b" { s.trigger("blackout") }
            else if ch == "t" { s.trigger("test") }
            else if ch == "a" { s.trigger("audiostop") }
            else if ch == "[" { s.skip(-5) }
            else if ch == "]" { s.skip(5) }
            else if let n = Int(ch), n >= 1, n <= 8 { s.fireShortcut(n - 1) }
            else { return e }
            return nil
        }
    }

    // MARK: timeline

    func timelinePlaying() -> Playing? {
        guard let id = live.timelineCue else { return nil }
        return playing.last(where: { $0.cue == id && !$0.stopping && $0.launched })
    }
    func skipOld(_ s: Double) {
        if let p = timelinePlaying() { relocate(p, to: max(0, position(p) + s), lead: 0.12) }
    }
    func seekTimelineOld(seconds t: Double) {
        guard let p = timelinePlaying() else { return }
        relocate(p, to: max(0, min(t, max(0, duration(p) - 0.2))), lead: 0.12)
    }

    // MARK: editing

    func select(_ id: UUID) {
        selected = id
        deleteArmed = false
    }
    func selectMove(_ d: Int) {
        guard !cues.isEmpty else { return }
        let i = (selectedIndex ?? (d > 0 ? -1 : cues.count)) + d
        select(cues[max(0, min(cues.count - 1, i))].id)
    }
    /// Runs an edit of the cue list and keeps standby on the same cue.
    func editCues(_ body: () -> Void) {
        let sid = standby < cues.count ? cues[standby].id : nil
        body()
        normalizeCues()
        if let s = sid, let i = index(s) { standby = headOf(i) } else { standby = min(standby, cues.count) }
        preloadStandby()
    }
    func addCueOld(url: URL?) {
        var c = Cue()
        c.num = String((cues.compactMap { Int($0.num) }.max() ?? 0) + 1)
        if let u = url {
            c.file = u.path
            c.name = u.deletingPathExtension().lastPathComponent
        } else { c.name = "New cue" }
        editCues {
            if url == nil, let i = selectedIndex { cues.insert(c, at: i + 1) } else { cues.append(c) }
        }
        select(c.id)
    }
    func deleteSelectedOld() {
        guard let i = selectedIndex else { return }
        if isPlaying(cues[i].id) { message = "A playing cue can't be deleted"; deleteArmed = false; return }
        if !deleteArmed {
            deleteArmed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.deleteArmed = false }
            return
        }
        deleteArmed = false
        editCues {
            let wasHead = !cues[i].with
            cues.remove(at: i)
            if wasHead && i < cues.count && cues[i].with { cues[i].with = false }
        }
        selected = cues.isEmpty ? nil : cues[min(i, cues.count - 1)].id
    }
    func moveSelectedOld(_ d: Int) {
        guard let i = selectedIndex else { return }
        let j = i + d
        guard j >= 0 && j < cues.count else { return }
        editCues { cues.swapAt(i, j) }
    }
    func duplicateSelectedOld() {
        guard let i = selectedIndex else { return }
        var c = cues[i]
        c.id = UUID()
        c.num = String((cues.compactMap { Int($0.num) }.max() ?? 0) + 1)
        c.name += " copy"
        editCues { cues.insert(c, at: i + 1) }
        select(c.id)
    }
    func chooseFile() {
        guard let i = selectedIndex else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audio, .image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let u = panel.url {
            cues[i].file = u.path
            if cues[i].name.isEmpty || cues[i].name == "New cue" { cues[i].name = u.deletingPathExtension().lastPathComponent }
            preloadStandby()
        }
    }
    func handleDrop(_ providers: [NSItemProvider]) {
        for p in providers {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let u = url { DispatchQueue.main.async { [weak self] in self?.addCue(url: u) } }
            }
        }
    }

    // MARK: settings that need a restart of something

    func setLTCIn(device: String? = nil, channel: Int? = nil) {
        if let d = device { settings.ltcInDevice = d }
        if let c = channel { settings.ltcInChannel = c }
        configureLTCIn()
    }
    func setLTCOut(device: String? = nil, channel: Int? = nil) {
        if let d = device { settings.ltcOutDevice = d }
        if let c = channel { settings.ltcOutChannel = c }
        configureLTCOut()
    }
    func setMidiIn(_ n: String) { settings.midiIn = n; midi.selectInput(n) }
    func setMidiOut(_ n: String) { settings.midiOut = n; midi.selectOutput(n) }
    func setOscPort(_ p: Int) {
        settings.oscInPort = p
        if !osc.listen(port: p) { message = "OSC port " + String(p) + " is in use" }
    }
    func setFps(_ f: Double) {
        settings.fps = max(1, f)
        configureLTCOut()
    }

    // MARK: showfiles (CSV, same columns as the TouchDesigner version)

    func saveShowfileOld() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "show.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var rows = [Cue.columns]
        for c in cues { rows.append(c.row) }
        do { try CSV.write(rows).write(to: url, atomically: true, encoding: .utf8) } catch { message = "Could not save the showfile"; return }
        var sc = [["key", "label", "type", "target", "value", "channel"]]
        for (i, s) in shortcuts.enumerated() { sc.append(["F" + String(i + 1), s.label, s.type, s.target, s.value, s.channel]) }
        try? CSV.write(sc).write(toFile: url.deletingPathExtension().path + "_shortcuts.csv", atomically: true, encoding: .utf8)
        message = "Saved " + url.lastPathComponent
    }

    func loadShowfileOld() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let rows = CSV.parse(text)
        guard let header = rows.first, header.contains("name"), header.contains("file") else { message = "That is not a KIMLAB showfile"; return }
        stopAll(fade: 0)
        cues = rows.dropFirst().map { Cue(header: header, row: $0) }
        normalizeCues()
        standby = 0
        selected = nil
        if let t = try? String(contentsOfFile: url.deletingPathExtension().path + "_shortcuts.csv", encoding: .utf8) {
            let sr = CSV.parse(t)
            if let h = sr.first {
                for (i, r) in sr.dropFirst().enumerated() where i < 8 {
                    func g(_ k: String) -> String {
                        if let x = h.firstIndex(of: k), x < r.count { return r[x] }
                        return ""
                    }
                    shortcuts[i] = Shortcut(label: g("label"), type: g("type"), target: g("target"), value: g("value"), channel: g("channel"))
                }
            }
        }
        message = "Loaded " + url.lastPathComponent
        preloadStandby()
    }
}

extension Show {
    /// -1 = output in a normal window, otherwise the index of the screen to fill.
    func setOutputScreenCore(_ i: Int) {
        settings.outputScreen = i
        video.moveWindow(to: i)
        if !video.windowOpen { video.openWindow() }
        outputOpen = video.windowOpen
        if video.windowOpen, video.controlOn(i) { video.focus(); message = "Output covers this screen: press Esc or double-click it to close" }
    }
}
