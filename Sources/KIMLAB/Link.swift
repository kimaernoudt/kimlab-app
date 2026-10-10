import Foundation
import AppKit
import AVFoundation

// MARK: cue list structure (explicit group membership)

extension Show {
    /// Every subcue carries the id of its group (parent). The list is kept as: group, its subcues, next cue...
    /// The 'with' flag (indent, starts with the group) is derived from that, so it cannot drift.
    func normalizeCues() {
        var list = cues
        let groups = Set(list.filter { $0.group }.map { $0.id.uuidString })
        var headIsGroup = false
        var headID = ""
        var seenHead = false
        for i in 0..<list.count {
            if list[i].group { list[i].parent = ""; list[i].with = false }
            if !list[i].parent.isEmpty && !groups.contains(list[i].parent) { list[i].parent = ""; list[i].with = false }
            // older saves and CSV showfiles: a linked cue under a group becomes a real subcue of it
            if list[i].parent.isEmpty && list[i].with {
                if !seenHead { list[i].with = false }
                else if headIsGroup { list[i].parent = headID }
            }
            if list[i].parent.isEmpty && !list[i].with {
                seenHead = true
                headIsGroup = list[i].group
                headID = list[i].id.uuidString
            }
        }
        var kids = [String: [Cue]]()
        for c in list where !c.parent.isEmpty {
            var x = c
            x.with = true
            kids[c.parent, default: []].append(x)
        }
        var out = [Cue]()
        for c in list where c.parent.isEmpty {
            out.append(c)
            if c.group { out.append(contentsOf: kids[c.id.uuidString] ?? []) }
        }
        if out != cues { cues = out }
    }

    func nextNumber() -> Int { (cues.compactMap { Int($0.num) }.max() ?? 0) + 1 }

    func addGroup() {
        var g = Cue()
        g.group = true
        g.name = "Group"
        g.level = ""
        g.audioOut = ""
        g.num = String(nextNumber())
        editCues {
            if let i = selectedIndex, !cues[i].group, cues[i].parent.isEmpty, !cues[i].with {
                cues[i].parent = g.id.uuidString
                cues[i].with = true
                cues.insert(g, at: i)
            } else if let i = selectedIndex {
                cues.insert(g, at: groupRange(headOf(i)).upperBound)
            } else {
                cues.append(g)
            }
        }
        select(g.id)
    }

    /// ADD: inside the group when a group or subcue is selected, otherwise after the selected cue.
    func addCue(url: URL?) {
        var c = Cue()
        c.num = String(nextNumber())
        if let u = url {
            c.file = u.path
            c.name = u.deletingPathExtension().lastPathComponent
        } else { c.name = "New cue" }
        editCues {
            if url == nil, let i = selectedIndex {
                let s = cues[i]
                if s.group {
                    c.parent = s.id.uuidString
                    c.with = true
                    cues.insert(c, at: groupRange(i).upperBound)
                } else if !s.parent.isEmpty {
                    c.parent = s.parent
                    c.with = true
                    cues.insert(c, at: i + 1)
                } else {
                    cues.insert(c, at: groupRange(headOf(i)).upperBound)
                }
            } else {
                cues.append(c)
            }
        }
        select(c.id)
    }

    /// IN GROUP button: takes a subcue out of its group, or puts a cue into the group right above it.
    func toggleInGroup() {
        guard let i = selectedIndex, !cues[i].group else { return }
        if !cues[i].parent.isEmpty || cues[i].with {
            editCues { cues[i].parent = ""; cues[i].with = false }
            return
        }
        guard i > 0 else { message = "There is no group above this cue"; return }
        let above = cues[i - 1]
        let gid = above.group ? above.id.uuidString : above.parent
        if gid.isEmpty { message = "There is no group right above this cue"; return }
        editCues { cues[i].parent = gid; cues[i].with = true }
    }

    func deleteSelected() {
        guard let i = selectedIndex else { return }
        if isPlaying(cues[i].id) { message = "A playing cue can't be deleted"; deleteArmed = false; return }
        if !deleteArmed {
            deleteArmed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.deleteArmed = false }
            return
        }
        deleteArmed = false
        editCues {
            let c = cues[i]
            if c.group {
                // the subcues stay in the list as normal cues
                let gid = c.id.uuidString
                for k in 0..<cues.count where cues[k].parent == gid { cues[k].parent = ""; cues[k].with = false }
            } else if !c.with && i + 1 < cues.count && cues[i + 1].with && cues[i + 1].parent.isEmpty {
                cues[i + 1].with = false
            }
            cues.remove(at: i)
        }
        selected = cues.isEmpty ? nil : cues[min(i, cues.count - 1)].id
    }

    func duplicateSelected() {
        guard let i = selectedIndex else { return }
        var n = nextNumber() - 1
        let single = !cues[i].parent.isEmpty || cues[i].with
        let r = single ? i..<(i + 1) : groupRange(i)
        var copy = Array(cues[r])
        for k in 0..<copy.count {
            n += 1
            copy[k].id = UUID()
            copy[k].num = String(n)
        }
        if copy[0].group { for k in 1..<copy.count { copy[k].parent = copy[0].id.uuidString } }
        copy[0].name += " copy"
        editCues { cues.insert(contentsOf: copy, at: r.upperBound) }
        select(copy[0].id)
    }

    /// Drag a cue: onto a group = last subcue of it; onto a subcue = before it in that group;
    /// onto any other cue = before it; target nil = end of the list. Groups move as a block and stay top level.
    func dropCue(_ dragged: UUID, onto target: UUID?) {
        guard !locked, dragged != target, let from = index(dragged) else { return }
        let d = cues[from]
        let single = !d.parent.isEmpty || d.with
        let block: Range<Int> = single ? from..<(from + 1) : groupRange(from)
        if let t = target, let ti = index(t), block.contains(ti) { return }
        let isBlock = d.group || block.count > 1
        editCues {
            var items = Array(cues[block])
            cues.removeSubrange(block)
            func top() { if !isBlock { items[0].parent = ""; items[0].with = false } }
            guard let t = target, let ti = index(t) else {
                top()
                cues.append(contentsOf: items)
                return
            }
            let tc = cues[ti]
            if !isBlock && tc.group {
                items[0].parent = tc.id.uuidString
                items[0].with = true
                cues.insert(contentsOf: items, at: groupRange(ti).upperBound)
            } else if !isBlock && !tc.parent.isEmpty {
                items[0].parent = tc.parent
                items[0].with = true
                cues.insert(contentsOf: items, at: ti)
            } else {
                top()
                cues.insert(contentsOf: items, at: headOf(ti))
            }
        }
    }

    /// Files from Finder land where they are dropped (same rules as dropCue), whatever is selected.
    func dropFiles(_ urls: [URL], onto target: UUID?) {
        guard !locked, !urls.isEmpty else { return }
        var n = nextNumber() - 1
        var fresh = [Cue]()
        for u in urls {
            var c = Cue()
            n += 1
            c.num = String(n)
            c.file = u.path
            c.name = u.deletingPathExtension().lastPathComponent
            fresh.append(c)
        }
        editCues {
            guard let t = target, let ti = index(t) else { cues.append(contentsOf: fresh); return }
            let tc = cues[ti]
            let gid = tc.group ? tc.id.uuidString : tc.parent
            if !gid.isEmpty {
                for k in 0..<fresh.count { fresh[k].parent = gid; fresh[k].with = true }
                cues.insert(contentsOf: fresh, at: tc.group ? groupRange(ti).upperBound : ti)
            } else {
                cues.insert(contentsOf: fresh, at: headOf(ti))
            }
        }
        if let last = fresh.last { select(last.id) }
    }

    // MARK: file lengths for the cue list

    func refreshLengths() {
        lengthCalls += 1
        if lengthCalls % 20 == 0 {
            for (k, v) in lengths where v < 0 { lengths[k] = nil; lengthPending.remove(k) }
        }
        for c in cues where c.hasFile && !c.isImage && lengths[c.file] == nil && !lengthPending.contains(c.file) {
            let path = c.file
            lengthPending.insert(path)
            DispatchQueue.global(qos: .utility).async {
                var secs = -1.0
                if FileManager.default.fileExists(atPath: path) {
                    let d = CMTimeGetSeconds(AVURLAsset(url: URL(fileURLWithPath: path)).duration)
                    if d.isFinite { secs = d }
                }
                DispatchQueue.main.async { [weak self] in self?.lengths[path] = secs }
            }
        }
    }

    // MARK: output resolution

    func setOutputRes(_ r: String) {
        settings.outputRes = r
        applyOutputRes()
    }
    func applyOutputRes() {
        if let m = video.applyResolution(settings.outputRes) { message = m }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.video.refit() }
    }
    func setOutputScreen(_ i: Int) {
        _ = video.applyResolution("")       // put the screen we are leaving back to its own mode
        setOutputScreenCore(i)
        applyOutputRes()
    }
}

// MARK: main / backup link

extension Mixer {
    /// Sense tone for an automatic audio switcher: 1 kHz at -20 dB, only while the app's main loop is alive.
    func addTone(_ p: UnsafeMutablePointer<Float>, _ n: Int, _ sr: Double) {
        let now = mach_absolute_time()
        let alive = toneAlive
        if alive == 0 || now < alive || Double(now - alive) * hostToSec > 0.5 { return }
        let step = 2.0 * Double.pi * 1000.0 / sr
        var ph = tonePhase
        for i in 0..<n {
            p[i] += Float(sin(ph)) * 0.1
            ph += step
        }
        tonePhase = ph.truncatingRemainder(dividingBy: 2.0 * Double.pi)
    }
}

extension Show {
    var linkOn: Bool { settings.redundancy != "off" }
    var isMain: Bool { settings.redundancy == "main" }
    var isBackup: Bool { settings.redundancy == "backup" }
    /// The backup stays quiet towards other gear (cue OSC and MIDI) while the main is alive.
    var linkSuppress: Bool { isBackup && peerAlive }

    func configureLink() {
        link.shutdown()
        configureSync()
        peerAlive = false
        peerHeard = false
        linkNote = ""
        lastPeer = Date.distantPast
        guard linkOn else { return }
        link.onMessage = { [weak self] a, args in self?.linkIn(a, args) }
        if !link.listen(port: settings.linkListen) { linkNote = "PORT " + String(settings.linkListen) + " IN USE" }
    }
    func linkSend(_ addr: String, _ args: [Any]) {
        guard linkOn, !settings.peerHost.isEmpty else { return }
        link.send(addr, args, host: settings.peerHost, port: settings.peerPort)
    }
    func listSig() -> String {
        var h: UInt32 = 5381
        for c in cues { for b in (c.num + "|" + c.name + "|" + (c.file as NSString).lastPathComponent).utf8 { h = (h &* 33) ^ UInt32(b) } }
        return String(cues.count) + ":" + String(h)
    }
    func playSig() -> String {
        playing.filter { $0.launched && !$0.stopping }.compactMap { index($0.cue) }.sorted().map { String($0) }.joined(separator: ",")
    }

    func linkTick() {
        mixer.toneAlive = mach_absolute_time()
        syncTick()
        mixer.toneChannel = settings.senseTone ? max(0, settings.senseChannel - 1) : -1
        guard linkOn else {
            if peerAlive { peerAlive = false }
            return
        }
        if tickCount % 15 == 0 {
            linkSeq += 1
            linkSend("/kimlab/hb", [settings.redundancy, standby, listSig(), playSig(), linkSeq])
        }
        let alive = Date().timeIntervalSince(lastPeer) < 2.0
        if alive != peerAlive {
            peerAlive = alive
            let other = isMain ? "BACKUP" : "MAIN"
            if alive { message = other + " connected" }
            else if peerHeard {
                message = other + " LOST"
                if !noPersist { NSSound.beep() }
            }
        }
    }

    func linkFire(_ head: Int, _ offset: Double) {
        lastLinkFire[head] = Date()
        if isMain { linkSend("/kimlab/fire", [head, offset]) }
    }

    /// Main -> backup: the current state, so a backup that joins late or fell behind catches up.
    func linkSync() {
        linkSend("/kimlab/syncbegin", [])
        for p in playing where p.launched && !p.stopping {
            if let i = index(p.cue) { linkSend("/kimlab/play", [i, position(p)]) }
        }
        linkSend("/kimlab/standby", [standby])
        linkSend("/kimlab/set", ["blackout", blackout ? 1 : 0])
        linkSend("/kimlab/set", ["test", testPattern ? 1 : 0])
    }

    func fireOne(_ i: Int, offset: Double) {
        guard i >= 0 && i < cues.count else { return }
        let c = cues[i]
        if c.group { return }
        let fade = min(0.3, max(0, parseNum(c.fade) ?? settings.defaultFade))
        let off = c.loop ? 0 : offset
        let p = (c.hasFile && c.isAudio) ? playAudio(c, fade: fade, offset: off) : playVideo(c, fade: fade, offset: off)
        if let p = p {
            pending.append([p])
            tryLaunch()
            schedulePending()
        }
    }

    func linkIn(_ addr: String, _ args: [Any]) {
        guard linkOn else { return }
        func int(_ i: Int) -> Int? {
            guard i < args.count else { return nil }
            if let n = args[i] as? Int { return n }
            if let d = args[i] as? Double { return Int(d) }
            return nil
        }
        func dbl(_ i: Int) -> Double? {
            guard i < args.count else { return nil }
            if let d = args[i] as? Double { return d }
            if let n = args[i] as? Int { return Double(n) }
            return nil
        }
        func str(_ i: Int) -> String? { i < args.count ? (args[i] as? String) : nil }

        if addr == "/kimlab/hb" {
            lastPeer = Date()
            peerHeard = true
            let role = str(0) ?? ""
            var note = ""
            if role == settings.redundancy { note = "BOTH ARE " + role.uppercased() }
            else if let ls = str(2), ls != listSig() { note = "CUE LISTS DIFFER" }
            if note != linkNote { linkNote = note }
            if isBackup && role == "main" && note.isEmpty {
                if let sb = int(1), sb != standby, sb >= 0, sb <= cues.count {
                    standby = sb
                    preloadStandby()
                }
                // different cues playing for more than 1.5 s: ask the main for its state
                if (str(3) ?? "") != playSig() {
                    if let since = sigDiffSince {
                        if Date().timeIntervalSince(since) > 1.5 {
                            sigDiffSince = nil
                            linkSend("/kimlab/syncreq", [])
                        }
                    } else { sigDiffSince = Date() }
                } else { sigDiffSince = nil }
            }
            return
        }
        if addr == "/kimlab/syncreq" {
            if isMain { linkSync() }
            return
        }
        guard isBackup else { return }
        if addr == "/kimlab/fire" {
            guard let h = int(0), h >= 0, h < cues.count else { return }
            if let t = lastLinkFire[h], Date().timeIntervalSince(t) < 0.3 { return }
            fireGroup(h, offset: dbl(1) ?? 0)
            standby = nextHead(after: h)
            preloadStandby()
        } else if addr == "/kimlab/play" {
            if let i = int(0), let pos = dbl(1) { fireOne(i, offset: pos + 0.25) }
        } else if addr == "/kimlab/syncbegin" {
            stopAll(fade: 0)
        } else if addr == "/kimlab/act" {
            if let a = str(0), a == "stop" || a == "audiostop" { triggerCore(a) }
        } else if addr == "/kimlab/set" {
            guard let k = str(0), let v = int(1) else { return }
            if k == "blackout" && (v != 0) != blackout { triggerCore("blackout") }
            if k == "test" && (v != 0) != testPattern { triggerCore("test") }
        } else if addr == "/kimlab/standby" {
            if let sb = int(0), sb >= 0, sb <= cues.count {
                standby = sb
                preloadStandby()
            }
        } else if addr == "/kimlab/seek" {
            guard let i = int(0), let t = dbl(1), i >= 0, i < cues.count else { return }
            let id = cues[i].id
            for p in playing where p.cue == id && p.launched && !p.stopping { relocate(p, to: t, lead: 0.12) }
        }
    }

    // wrappers that add the mirroring to the normal actions

    func trigger(_ a: String) {
        triggerCore(a)
        guard isMain else { return }
        if a == "prev" || a == "next" || a == "go" || a == "gocue" { linkSend("/kimlab/standby", [standby]) }
        else if a == "blackout" { linkSend("/kimlab/set", ["blackout", blackout ? 1 : 0]) }
        else if a == "test" { linkSend("/kimlab/set", ["test", testPattern ? 1 : 0]) }
        else if a == "stop" || a == "audiostop" { linkSend("/kimlab/act", [a]) }
    }
    func linkSeek() {
        guard isMain else { return }
        for p in timelinePlayings() {
            if let i = index(p.cue) { linkSend("/kimlab/seek", [i, p.seekTarget]) }
        }
    }
    func skip(_ s: Double) {
        skipCore(s)
        linkSeek()
    }
    func seekTimeline(seconds t: Double) {
        seekTimelineCore(seconds: t)
        linkSeek()
    }
    func sendOSC(_ addr: String, _ args: [Any]) {
        if linkSuppress { return }
        sendOSCCore(addr, args)
    }
    func sendMIDI(_ bytes: [UInt8]) {
        if linkSuppress { return }
        sendMIDICore(bytes)
    }
}
