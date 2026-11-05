import Foundation

/// "12.5", "1:23.5" or "1:02:03.5" -> seconds. Empty or unreadable -> nil.
func parseClock(_ s: String) -> Double? {
    let t = s.trimmingCharacters(in: .whitespaces)
    if t.isEmpty { return nil }
    let parts = t.split(separator: ":", omittingEmptySubsequences: false)
    if parts.count > 3 { return nil }
    var v = 0.0
    for p in parts {
        guard let n = parseNum(String(p)), n >= 0 else { return nil }
        v = v * 60 + n
    }
    return v
}

extension Show {
    /// START / END trim of a cue, in seconds into the file. END is 0 when the cue plays to the file's end.
    func trim(_ c: Cue) -> (Double, Double) {
        let s = parseClock(c.start) ?? 0
        var e = parseClock(c.end) ?? 0
        if e <= s + 0.01 { e = 0 }
        return (s, e)
    }

    /// FADE OUT at the end: a cue with a FADE OUT time that plays to its end (file end or END)
    /// starts fading that long before the end, so it reaches silence / black exactly there.
    /// FOLLOW = end still fires at the end point.
    func endFade(_ p: Playing, _ c: Cue) -> Bool {
        guard !c.loop, !c.isImage, parseNum(c.hold) == nil, !p.chasePaused,
              let f = parseNum(c.fadeOut), f > 0.001,
              Date().timeIntervalSince(p.started) > 0.1 else { return false }
        let d = duration(p)
        guard d > 0 else { return false }
        let left = d - position(p)
        guard left <= f else { return false }
        if c.follow.lowercased() == "end", settings.autoFollow, !p.followDone {
            p.followDone = true
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, left)) { [weak self] in
                guard let s = self, s.playing.contains(where: { $0 === p }) else { return }
                s.fireNext(after: c)
            }
        }
        stop(p, fade: max(0.02, left))
        return true
    }
}
