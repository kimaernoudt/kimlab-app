import Foundation

/// A group cue that was fired, with the subcues it started.
final class GroupRun {
    let head: UUID
    let members: [Playing]
    let started = Date()
    var followDone = false
    init(head: UUID, members: [Playing]) { self.head = head; self.members = members }
}

extension Show {
    func cueOrGroupPlaying(_ id: UUID) -> Bool {
        if playing.contains(where: { $0.cue == id && !$0.stopping }) { return true }
        guard let i = index(id), cues[i].group else { return false }
        for j in groupRange(i) {
            let sub = cues[j].id
            if playing.contains(where: { $0.cue == sub && !$0.stopping }) { return true }
        }
        return false
    }

    func alive(_ run: GroupRun) -> [Playing] {
        run.members.filter { m in !m.stopping && playing.contains(where: { $0 === m }) }
    }

    /// Group follow (seconds, or end = when every subcue is done) and the group's row in the cue list.
    func groupTick(_ rows: inout [UUID: RowInfo]) {
        for run in Array(groupRuns) {
            let live = alive(run)
            guard let c = cue(run.head) else { continue }
            if settings.autoFollow && !run.followDone {
                if let secs = parseNum(c.follow) {
                    if Date().timeIntervalSince(run.started) >= secs { run.followDone = true; fireNext(after: c) }
                } else if c.follow.lowercased() == "end" && live.isEmpty {
                    run.followDone = true
                    fireNext(after: c)
                }
            }
            // the group row shows the subcue with the most time left
            var best: RowInfo? = nil
            for m in live {
                guard let r = rows[m.cue] else { continue }
                if let b = best { if r.dur - r.pos > b.dur - b.pos { best = r } } else { best = r }
            }
            if let b = best { rows[c.id] = b }
        }
        groupRuns.removeAll { run in !run.members.contains(where: { m in playing.contains(where: { $0 === m }) }) }
    }

    func toggleCollapse(_ id: UUID) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }

    /// New group cue. With a cue selected, that cue (and anything linked to it) becomes the group's first subcues.
    func addGroupOld() {
        var g = Cue()
        g.group = true
        g.name = "Group"
        g.level = ""
        g.audioOut = ""
        g.num = String((cues.compactMap { Int($0.num) }.max() ?? 0) + 1)
        editCues {
            if let i = selectedIndex {
                let h = headOf(i)
                if cues[h].group {
                    cues.insert(g, at: groupRange(h).upperBound)
                } else {
                    cues[h].with = true
                    cues.insert(g, at: h)
                }
            } else {
                cues.append(g)
            }
        }
        select(g.id)
    }

    /// ADD and file drops. With a group or subcue selected the new cue goes into that group.
    func addCueOld2(url: URL?) {
        var c = Cue()
        c.num = String((cues.compactMap { Int($0.num) }.max() ?? 0) + 1)
        if let u = url {
            c.file = u.path
            c.name = u.deletingPathExtension().lastPathComponent
        } else { c.name = "New cue" }
        editCues {
            if let i = selectedIndex {
                let inGroup = cues[i].group || cues[i].with
                c.with = inGroup
                if url == nil { cues.insert(c, at: i + 1) }
                else if inGroup { cues.insert(c, at: groupRange(headOf(i)).upperBound) }
                else { cues.append(c) }
            } else {
                cues.append(c)
            }
        }
        select(c.id)
    }

    /// A subcue moves inside its group; a group (or single cue) moves as a whole block.
    func moveSelected(_ d: Int) {
        guard let i = selectedIndex else { return }
        if cues[i].with {
            let r = groupRange(headOf(i))
            let j = i + d
            guard j > r.lowerBound && j < r.upperBound else { return }
            editCues { cues.swapAt(i, j) }
            return
        }
        let r = groupRange(i)
        editCues {
            let block = Array(cues[r])
            if d < 0 {
                guard r.lowerBound > 0 else { return }
                let ph = headOf(r.lowerBound - 1)
                cues.removeSubrange(r)
                cues.insert(contentsOf: block, at: ph)
            } else {
                guard r.upperBound < cues.count else { return }
                let nextCount = groupRange(r.upperBound).count
                cues.removeSubrange(r)
                cues.insert(contentsOf: block, at: r.lowerBound + nextCount)
            }
        }
    }

    func duplicateSelectedOld2() {
        guard let i = selectedIndex else { return }
        var n = cues.compactMap { Int($0.num) }.max() ?? 0
        let r = cues[i].with ? i..<(i + 1) : groupRange(i)
        var copy = Array(cues[r])
        for k in 0..<copy.count {
            n += 1
            copy[k].id = UUID()
            copy[k].num = String(n)
        }
        copy[0].name += " copy"
        editCues { cues.insert(contentsOf: copy, at: r.upperBound) }
        select(copy[0].id)
    }

    // MARK: timeline (a group moves all its subcues together)

    func timelinePlayings() -> [Playing] {
        guard let id = live.timelineCue else { return [] }
        if let own = playing.last(where: { $0.cue == id && !$0.stopping && $0.launched }) { return [own] }
        guard let run = groupRuns.last(where: { $0.head == id }) else { return [] }
        return alive(run).filter { $0.launched }
    }
    func skipCore(_ s: Double) {
        for p in timelinePlayings() { relocate(p, to: max(0, position(p) + s), lead: 0.12) }
    }
    func seekTimelineCore(seconds t: Double) {
        for p in timelinePlayings() { relocate(p, to: max(0, min(t, max(0, duration(p) - 0.2))), lead: 0.12) }
    }
}
