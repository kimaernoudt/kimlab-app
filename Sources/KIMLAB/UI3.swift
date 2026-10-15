import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Chooses where the video output goes: a normal window, or one of the screens (fullscreen).
struct OutputPicker: View {
    @EnvironmentObject var show: Show
    var body: some View {
        Picker("", selection: Binding(get: { show.settings.outputScreen }, set: { show.setOutputScreen($0) })) {
            Text("Output in a window").tag(-1)
            ForEach(0..<NSScreen.screens.count, id: \.self) { i in
                Text("Output on screen " + String(i + 1) + ": " + NSScreen.screens[i].localizedName).tag(i)
            }
        }
        .labelsHidden().frame(width: 214)
    }
}

/// Where the countdown window goes: a normal window, or filling one screen.
struct CountdownPicker: View {
    @EnvironmentObject var show: Show
    var body: some View {
        Picker("", selection: Binding(get: { show.settings.countdownScreen }, set: { show.setCountdownScreen($0) })) {
            Text("Countdown in a window").tag(-1)
            ForEach(0..<NSScreen.screens.count, id: \.self) { i in
                Text("Countdown on screen " + String(i + 1) + ": " + NSScreen.screens[i].localizedName).tag(i)
            }
        }
        .labelsHidden().frame(width: 214)
    }
}

/// Main layout: three columns, timeline across the full width at the bottom.
struct ContentView: View {
    @EnvironmentObject var show: Show
    var body: some View {
        VStack(spacing: 6) {
            HeaderView()
            HStack(alignment: .top, spacing: 6) {
                LeftColumn().frame(width: 440)
                MiddleColumn()
                RightColumn().frame(width: 420)
            }
            TimelineBar(live: show.live)
        }
        .padding(8)
        .background(P.bg)
        .foregroundColor(P.text)
        .font(arial(12))
        .overlay { if show.showHelp { HelpView() } }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            show.handleDrop(providers)
            return true
        }
    }
}

/// Cue list with group cues: a group row can be folded, its subcues are indented under it.
struct CueListOld2: View {
    @EnvironmentObject var show: Show
    @ObservedObject var live: LiveState

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

    func nameCell(_ i: Int, _ c: Cue) -> some View {
        let folded = show.collapsed.contains(c.id)
        let count = c.group ? show.groupRange(i).count - 1 : 0
        return HStack(spacing: 5) {
            if c.group {
                Image(systemName: folded ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 14, height: 20)
                    .contentShape(Rectangle())
                    .onTapGesture { show.toggleCollapse(c.id) }
                Text(c.name).font(arial(12, bold: true)).lineLimit(1)
                Text(String(count) + (count == 1 ? " cue" : " cues")).font(arial(10)).foregroundColor(P.muted).lineLimit(1)
            } else {
                Text(c.name).lineLimit(1)
            }
        }
        .padding(.leading, c.with ? 18 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func row(_ i: Int, _ c: Cue) -> some View {
        let info = live.rows[c.id]
        let inStandby = show.standby < show.cues.count && show.groupRange(show.standby).contains(i)
        let missing = live.missing.contains(c.id)
        var marker = ""
        if info != nil { marker = ">" } else if inStandby { marker = "+" }
        if c.with { marker += "&" }
        if !c.follow.isEmpty { marker += "~" }
        if missing { marker += "!" }
        let left = info.map { $0.loop ? "LOOP" : "-" + TC.clock(max(0, $0.dur - $0.pos)) } ?? ""
        let frac: Double = info.map { $0.dur > 0 ? min(1, max(0, $0.pos / $0.dur)) : 0 } ?? 0
        let isSel = show.selected == c.id
        let base = info != nil ? P.livebg : (isSel ? P.panel3 : (c.group ? P.bg : P.panel2))
        let edge = inStandby ? P.amber : (isSel ? P.blue : Color.clear)
        let kind = c.group ? "G" : (c.hasFile ? (c.isAudio ? "A" : "V") : "-")
        return HStack(spacing: 0) {
            cell(marker, 26).foregroundColor(missing ? P.red : P.text)
            cell(c.num, 40)
            cell(kind, 20)
            nameCell(i, c)
            cell(c.group ? "" : c.level, 44)
            cell(c.group ? "" : c.audioOut, 50)
            cell(c.tc, 86)
            cell(c.group ? "" : c.fade, 40)
            cell(left, 60)
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
        .overlay(Rectangle().stroke(edge, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { if !show.locked { show.select(c.id) } }
    }

    var body: some View {
        Panel {
            HStack(spacing: 0) {
                cell("", 26)
                cell("#", 40)
                cell("T", 20)
                Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
                cell("LEVEL", 44)
                cell("OUT", 50)
                cell("TC", 86)
                cell("FADE", 40)
                cell("LEFT", 60)
            }
            .font(arial(10, bold: true)).foregroundColor(P.muted).padding(.horizontal, 4)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(visible(), id: \.self) { i in
                            row(i, show.cues[i]).id(show.cues[i].id)
                        }
                        if show.cues.isEmpty {
                            Text("Drop video or audio files here, or press ADD").font(arial(12)).foregroundColor(P.muted).padding(20)
                        }
                    }
                }
                .onChange(of: show.standby) { _, s in
                    if s < show.cues.count { proxy.scrollTo(show.cues[s].id, anchor: .center) }
                }
            }
        }
    }
}
