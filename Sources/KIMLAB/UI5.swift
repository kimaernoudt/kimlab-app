import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// One cue row. Equatable, so SwiftUI only redraws the rows whose values changed (the playing ones).
struct CueRowView: View, Equatable {
    let i: Int
    let c: Cue
    let info: RowInfo?
    let inStandby: Bool
    let missing: Bool
    let selected: Bool
    let isDrop: Bool
    let length: String
    let folded: Bool
    let count: Int
    let onFold: () -> Void

    static func == (a: CueRowView, b: CueRowView) -> Bool {
        a.i == b.i && a.c == b.c && a.info == b.info && a.inStandby == b.inStandby && a.missing == b.missing
            && a.selected == b.selected && a.isDrop == b.isDrop && a.length == b.length && a.folded == b.folded && a.count == b.count
    }

    func cell(_ t: String, _ w: CGFloat) -> some View {
        Text(t).lineLimit(1).frame(width: w, alignment: .leading)
    }

    var body: some View {
        var marker = ""
        if info != nil { marker = ">" } else if inStandby { marker = "+" }
        if !c.follow.isEmpty { marker += "~" }
        if missing { marker += "!" }
        var left = ""
        if let r = info { left = r.loop ? "LOOP" : (r.dur > 0 ? "-" + TC.clock(max(0, r.dur - r.pos)) : "") }
        let frac: Double = info.map { $0.dur > 0 ? min(1, max(0, $0.pos / $0.dur)) : 0 } ?? 0
        let base = info != nil ? P.livebg : (selected ? P.panel3 : (c.group ? P.bg : P.panel2))
        let edge = isDrop ? P.violet : (inStandby ? P.amber : (selected ? P.blue : Color.clear))
        let kind = c.group ? "G" : (c.hasFile ? (c.isAudio ? "A" : (c.isImage ? "I" : "V")) : "-")
        return HStack(spacing: 0) {
            cell(marker, 24).foregroundColor(missing ? P.red : P.text)
            if c.with {
                Rectangle().fill(P.blue.opacity(0.7)).frame(width: 2, height: 22).padding(.leading, 8).padding(.trailing, 12)
            }
            cell(c.num, 34)
            cell(kind, 20)
            HStack(spacing: 5) {
                if c.group {
                    Image(systemName: folded ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 14, height: 20)
                        .contentShape(Rectangle())
                        .onTapGesture { onFold() }
                    Text(c.name).font(arial(12, bold: true)).lineLimit(1)
                    Text(String(count) + (count == 1 ? " cue" : " cues")).font(arial(10)).foregroundColor(P.muted).lineLimit(1)
                } else {
                    Text(c.name).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            cell(c.group ? "" : c.level, 40)
            cell(c.group ? "" : c.audioOut, 44)
            cell(c.tc, 80)
            cell(c.group ? "" : c.fade, 34)
            cell(c.group ? "" : c.fadeOut, 38)
            cell(c.group ? "" : c.hold, 38)
            cell(length, 48)
            cell(left, 54)
        }
        .font(arial(12).monospacedDigit())
        .padding(.horizontal, 4)
        .frame(height: 22)
        .background(GeometryReader { g in
            ZStack(alignment: .leading) {
                base
                if info != nil { P.green.opacity(0.35).frame(width: g.size.width * frac) }
            }
        })
        .overlay(Rectangle().stroke(edge, lineWidth: isDrop ? 2 : 1))
        .contentShape(Rectangle())
    }
}

/// Cue list: group rows fold, subcues are indented; rows and Finder files can be dropped onto rows.
struct CueList: View {
    @EnvironmentObject var show: Show
    @ObservedObject var live: LiveState
    @State private var dropTarget: UUID? = nil
    @State private var dropEnd = false
    static let dropTypes = [UTType.fileURL, UTType.utf8PlainText, UTType.plainText]

    func cell(_ t: String, _ w: CGFloat) -> some View {
        Text(t).lineLimit(1).frame(width: w, alignment: .leading)
    }

    func visible() -> [Int] {
        var out = [Int]()
        var hide = false
        for (i, c) in show.cues.enumerated() {
            if !c.with {
                hide = c.group && show.collapsed.contains(c.id)
                out.append(i)
            } else if !hide { out.append(i) }
        }
        return out
    }

    /// Files from Finder become cues at the drop position; a dragged cue is moved there.
    func handle(_ providers: [NSItemProvider], _ target: UUID?) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if !files.isEmpty {
            var urls = [URL?](repeating: nil, count: files.count)
            let g = DispatchGroup()
            for (i, p) in files.enumerated() {
                g.enter()
                _ = p.loadObject(ofClass: URL.self) { u, _ in
                    DispatchQueue.main.async { urls[i] = u; g.leave() }
                }
            }
            g.notify(queue: .main) { show.dropFiles(urls.compactMap { $0 }, onto: target) }
            return true
        }
        guard let p = providers.first else { return false }
        _ = p.loadObject(ofClass: String.self) { s, _ in
            if let s = s, let id = UUID(uuidString: s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                DispatchQueue.main.async { show.dropCue(id, onto: target) }
            }
        }
        return true
    }

    func row(_ i: Int, _ c: Cue, _ standbyRange: Range<Int>) -> some View {
        var length = ""
        if !c.group, let l = show.lengths[c.file], l > 0 { length = TC.clock(l) }
        let targeted = Binding<Bool>(get: { dropTarget == c.id }, set: { on in
            if on { dropTarget = c.id } else if dropTarget == c.id { dropTarget = nil }
        })
        return CueRowView(i: i, c: c, info: live.rows[c.id], inStandby: standbyRange.contains(i),
                          missing: live.missing.contains(c.id), selected: show.selected == c.id, isDrop: dropTarget == c.id,
                          length: length, folded: show.collapsed.contains(c.id),
                          count: c.group ? show.groupRange(i).count - 1 : 0,
                          onFold: { show.toggleCollapse(c.id) })
            .equatable()
            .onTapGesture { if !show.locked { show.select(c.id) } }
            .draggable(c.id.uuidString)
            .onDrop(of: CueList.dropTypes, isTargeted: targeted) { providers in handle(providers, c.id) }
    }

    var body: some View {
        let standbyRange = show.standby < show.cues.count ? show.groupRange(show.standby) : 0..<0
        Panel {
            HStack(spacing: 0) {
                cell("", 24)
                cell("#", 34)
                cell("T", 20)
                Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
                cell("LEVEL", 40)
                cell("OUT", 44)
                cell("TC", 80)
                cell("F.IN", 34)
                cell("F.OUT", 38)
                cell("HOLD", 38)
                cell("LENGTH", 48)
                cell("LEFT", 54)
            }
            .font(arial(10, bold: true)).foregroundColor(P.muted).padding(.horizontal, 4)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(visible(), id: \.self) { i in
                            row(i, show.cues[i], standbyRange).id(show.cues[i].id)
                        }
                        Text(show.cues.isEmpty ? "Drop video, audio or image files here, or press ADD" : (dropEnd ? "drop here: end of the list" : " "))
                            .font(arial(11)).foregroundColor(P.muted)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(dropEnd ? P.violet.opacity(0.25) : Color.clear)
                            .contentShape(Rectangle())
                            .onDrop(of: CueList.dropTypes, isTargeted: $dropEnd) { providers in handle(providers, nil) }
                    }
                }
                .onChange(of: show.standby) { _, s in
                    if s < show.cues.count { proxy.scrollTo(show.cues[s].id, anchor: .center) }
                }
            }
        }
    }
}

/// All meter bars in one canvas. Only this view follows the meter signal; the buttons below it do not.
struct MeterBars: View {
    @ObservedObject var tick: Ticker
    let live: LiveState
    let n: Int
    let mutes: [Bool]

    func y(_ v: Float, _ h: CGFloat) -> CGFloat {
        let db = v <= 0.000001 ? -60 : max(-60, min(0, 20 * log10(v)))
        return h * CGFloat(1 + db / 60)
    }
    var body: some View {
        Canvas { ctx, size in
            let gap: CGFloat = 3
            let w = (size.width - gap * CGFloat(max(0, n - 1))) / CGFloat(max(1, n))
            let top: CGFloat = 12
            let h = size.height - top
            for c in 0..<n {
                let x = CGFloat(c) * (w + gap)
                let hold = live.holds[c]
                let dim = c < mutes.count && mutes[c]
                ctx.fill(Path(CGRect(x: x, y: top, width: w, height: h)), with: .color(P.track))
                let lv = y(live.peaks[c], h)
                let amberY = h * 0.7, redY = h * 0.9
                let segs: [(CGFloat, CGFloat, Color)] = [(0, min(lv, amberY), P.green), (amberY, min(lv, redY), P.amber), (redY, lv, P.red)]
                for s in segs where s.1 > s.0 {
                    ctx.fill(Path(CGRect(x: x, y: top + h - s.1, width: w, height: s.1 - s.0)), with: .color(s.2.opacity(dim ? 0.3 : 1)))
                }
                for db in [0.0, 6.0, 12.0, 24.0, 48.0] {
                    ctx.fill(Path(CGRect(x: x, y: top + h * CGFloat(db / 60), width: w, height: 0.5)), with: .color(P.panel3))
                }
                if hold > 0.00001 {
                    ctx.fill(Path(CGRect(x: x, y: top + h - y(hold, h), width: w, height: 1.5)), with: .color(hold >= 1 ? P.red : Color.white))
                    let t = hold >= 1 ? "CLIP" : String(format: "%.0f", 20 * log10(hold))
                    ctx.draw(Text(t).font(arial(8)).foregroundColor(hold >= 1 ? P.red : P.muted), at: CGPoint(x: x + w / 2, y: 5))
                }
            }
        }
    }
}

struct MetersPanel: View {
    @EnvironmentObject var show: Show
    var tick = Ticker()
    var live: LiveState
    func small(_ t: String, _ act: String, _ c: Int, _ on: Bool, _ col: Color) -> some View {
        KButton(title: t, action: act + String(c + 1), on: on, color: col, size: 9, height: 16)
    }
    var body: some View {
        let n = min(show.outChannels, 16)
        Panel {
            HStack {
                Text("AUDIO OUTS").font(arial(10, bold: true)).foregroundColor(P.muted)
                Spacer()
                KButton(title: "RESET PK", action: "resetpk", height: 18).frame(width: 70)
            }
            MeterBars(tick: tick, live: live, n: n, mutes: Array(show.mutes.prefix(n))).frame(height: 82)
            HStack(alignment: .top, spacing: 3) {
                ForEach(0..<n, id: \.self) { c in
                    VStack(spacing: 2) {
                        Text(String(c + 1)).font(arial(9, bold: true)).foregroundColor(c < show.deviceChannels ? P.text : P.muted)
                        small("M", "mute", c, show.mutes[c], P.red)
                        small("S", "solo", c, show.solos[c], P.amber)
                        small("P", "pink", c, show.pinks[c], P.pink)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}
