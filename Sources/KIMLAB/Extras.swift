import Foundation
import AppKit
import AVFoundation
import IOKit

extension Show {
    /// A cue's own FADE OUT, or the fallback when it has none.
    func outFade(_ p: Playing, _ fallback: Double) -> Double {
        if let c = cue(p.cue), let f = parseNum(c.fadeOut) { return max(0, f) }
        return fallback
    }

    /// True while a cue with a HOLD time has not used it up yet (keeps the last video frame on screen).
    func holdsOpen(_ p: Playing) -> Bool {
        guard let c = cue(p.cue), let h = parseNum(c.hold) else { return false }
        return h > Date().timeIntervalSince(p.started)
    }

    /// HOLD: the cue stays up this many seconds, then fades out (FADE OUT) and counts as ended for FOLLOW = end.
    func holdDone(_ p: Playing, _ c: Cue) -> Bool {
        guard let h = parseNum(c.hold), h > 0, Date().timeIntervalSince(p.started) >= h else { return false }
        if c.follow.lowercased() == "end", settings.autoFollow, !p.followDone {
            p.followDone = true
            fireNext(after: c)
        }
        if !p.stopping { stop(p, fade: outFade(p, 0)) }
        return true
    }

    /// Thumbnail of the first picture (video or image) in the standby cue or group.
    func updateNextThumb() {
        var target: Cue? = nil
        if standby < cues.count {
            for i in groupRange(standby) {
                let c = cues[i]
                if c.hasFile && !c.isAudio { target = c; break }
            }
        }
        let key = target?.file ?? ""
        if key == nextThumbKey { return }
        nextThumbKey = key
        nextThumb = nil
        guard let c = target, FileManager.default.fileExists(atPath: c.file) else { return }
        let url = URL(fileURLWithPath: c.file)
        if c.isImage {
            nextThumb = NSImage(contentsOf: url)
            return
        }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 360)
        gen.generateCGImageAsynchronously(for: .zero) { [weak self] img, _, _ in
            _ = gen
            guard let img = img else { return }
            DispatchQueue.main.async {
                guard let s = self, s.nextThumbKey == key else { return }
                s.nextThumb = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
            }
        }
    }

    /// Drag and drop in the cue list. Dropped on a group: becomes its last subcue. On a subcue: goes before it,
    /// inside that group. On any other cue: goes before it. target nil = end of the list.
    /// A group (or a cue with linked cues) moves as one block and cannot go inside another group.
    func dropCueOld(_ dragged: UUID, onto target: UUID?) {
        guard !locked, dragged != target, let from = index(dragged) else { return }
        let block: Range<Int> = cues[from].with ? from..<(from + 1) : groupRange(from)
        if let t = target, let ti = index(t), block.contains(ti) { return }
        let isBlock = cues[from].group || block.count > 1
        editCues {
            var items = Array(cues[block])
            cues.removeSubrange(block)
            guard let t = target, let ti = index(t) else {
                items[0].with = false
                cues.append(contentsOf: items)
                return
            }
            if cues[ti].group && !isBlock {
                items[0].with = true
                cues.insert(contentsOf: items, at: groupRange(ti).upperBound)
            } else if cues[ti].with && !isBlock {
                items[0].with = true
                cues.insert(contentsOf: items, at: ti)
            } else {
                items[0].with = false
                cues.insert(contentsOf: items, at: headOf(ti))
            }
        }
    }
}

/// CPU and GPU load for the SYSTEM box.
final class SysMeter {
    private var lastTicks: (UInt32, UInt32, UInt32, UInt32)? = nil
    private var lastCPU = -1.0
    private var lastWall = Date()

    func gpuLoad() -> Int? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var best: Int? = nil
        while true {
            let s = IOIteratorNext(it)
            if s == 0 { break }
            if let ref = IORegistryEntryCreateCFProperty(s, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0),
               let d = ref.takeRetainedValue() as? [String: Any], let u = d["Device Utilization %"] as? Int {
                best = max(best ?? 0, u)
            }
            IOObjectRelease(s)
        }
        return best
    }

    func rows() -> [(String, String)] {
        var all = -1.0
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let cap = Int(count)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: cap) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        if kr == KERN_SUCCESS {
            let t = info.cpu_ticks
            if let l = lastTicks {
                let user = Double(t.0 &- l.0), sys = Double(t.1 &- l.1), idle = Double(t.2 &- l.2), nice = Double(t.3 &- l.3)
                let total = user + sys + idle + nice
                if total > 0 { all = (user + sys + nice) / total * 100 }
            }
            lastTicks = t
        }
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        let cpu = Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6 + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
        let now = Date()
        let dt = now.timeIntervalSince(lastWall)
        var app = -1.0
        if lastCPU >= 0 && dt > 0.05 { app = (cpu - lastCPU) / dt * 100 }
        lastCPU = cpu
        lastWall = now
        var cpuText = "-"
        if app >= 0 { cpuText = String(format: "app %.0f %%", app) }
        if all >= 0 { cpuText += String(format: "  all %.0f %%", all) }
        var gpuText = "-"
        if let g = gpuLoad() { gpuText = String(g) + " %" }
        return [("CPU", cpuText), ("GPU", gpuText)]
    }
}

let sysMeter = SysMeter()

extension LiveTest {
    static func makePNG() -> URL? {
        guard let ctx = CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        guard let img = ctx.makeImage(), let data = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kimlab_test_" + String(getpid()) + ".png")
        do { try data.write(to: url) } catch { return nil }
        return url
    }

    /// Image cue with HOLD and FOLLOW = end, then drag and drop in the cue list.
    static func step4(_ show: Show) {
        guard let png = makePNG(), let wav = makeTestWav(seconds: 3) else { check("make test image", false); finish(); return }
        var a = Cue()
        a.num = "1"; a.name = "test image"; a.file = png.path; a.fade = "0"; a.fadeOut = "0"; a.hold = "0.7"; a.follow = "end"
        var b = Cue()
        b.num = "2"; b.name = "after image"; b.file = wav.path; b.level = "-80"; b.fade = "0"; b.fadeOut = "0.1"
        show.cues = [a, b]
        show.standby = 0
        show.preloadStandby()
        check("image cue recognised", a.isImage && !a.isAudio)
        check("next-cue preview picture made", show.nextThumb != nil)
        show.lastGo = Date.distantPast
        show.go()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let p = show.playing.first(where: { $0.isVideo })
            let shown = show.video.status(0) == "image" || show.video.status(1) == "image"
            check("image cue showing", p != nil && (p?.launched ?? false) && shown)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                check("HOLD ended the image cue", !show.playing.contains(where: { $0.isVideo && !$0.stopping }))
                check("FOLLOW started the next cue", show.playing.contains(where: { !$0.isVideo && !$0.stopping }))
                show.stopAll(fade: 0)
                var g = Cue()
                g.group = true; g.name = "G"
                var x = Cue()
                x.name = "x"
                var y = Cue()
                y.name = "y"
                show.cues = [g, x, y]
                func names() -> String { show.cues.map { $0.name }.joined(separator: " ") }
                show.dropCue(y.id, onto: g.id)
                check("drag a cue into a group", names() == "G y x" && show.cues[1].with && !show.cues[2].with)
                show.dropCue(x.id, onto: g.id)
                show.dropCue(x.id, onto: y.id)
                check("reorder inside a group", names() == "G x y" && show.cues[1].with && show.cues[2].with)
                show.dropCue(y.id, onto: nil)
                check("drag a subcue out to the end", names() == "G x y" && !show.cues[2].with)
                show.dropCue(g.id, onto: nil)
                check("move a group as a block", names() == "y G x" && show.cues[2].with && !show.cues[0].with)
                let rows = sysMeter.rows()
                check("system load: " + rows[0].1 + ", GPU " + rows[1].1, rows.count == 2)
                step5(show)
            }
        }
    }
}
