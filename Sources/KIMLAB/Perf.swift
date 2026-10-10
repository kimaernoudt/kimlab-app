import SwiftUI

/// A redraw signal of its own, so that a moving meter does not redraw the cue list (and the other way round).
final class Ticker: ObservableObject {
    func bump() { objectWillChange.send() }
}

extension Show {
    /// Tells the window what changed. An idle player sends nothing, so nothing is redrawn.
    func publishLive(_ noRows: Bool) {
        // meters: about 15 times a second while there is signal, plus one last frame when it falls silent
        var active = false
        for c in 0..<outChannels where live.peaks[c] > 0 { active = true; break }
        if (active && tickCount % 2 == 0) || (!active && live.metersActive) { live.meterTick.bump() }
        live.metersActive = active
        // cue rows and timeline: 10 times a second while something plays, once more when it stops
        if (!noRows && tickCount % 3 == 0) || (noRows && live.hadRows) { live.bump() }
        live.hadRows = !noRows
        // timecode boxes: only when the text changes
        let sig = live.tcIn + live.tcOut + (live.tcInLocked ? "1" : "0")
        if sig != live.clockSig {
            live.clockSig = sig
            live.clockTick.bump()
        }
    }

    /// Which cue files are missing on disk (every 3 seconds; redraws the list only when that changes).
    func refreshMissing() {
        let m = Set(cues.filter { $0.hasFile }.filter { !FileManager.default.fileExists(atPath: $0.file) }.map { $0.id })
        if m != live.missing {
            live.missing = m
            live.bump()
        }
    }
}
