import SwiftUI
import AppKit

struct MiddleColumn: View {
    @EnvironmentObject var show: Show
    var body: some View {
        VStack(spacing: 6) {
            CueList(live: show.live)
            CueEditor()
        }
    }
}

struct CueListOld: View {
    @EnvironmentObject var show: Show
    @ObservedObject var live: LiveState

    func cell(_ t: String, _ w: CGFloat) -> some View {
        Text(t).lineLimit(1).frame(width: w, alignment: .leading)
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
        let base = info != nil ? P.livebg : (show.selected == c.id ? P.panel3 : P.panel2)
        let edge = inStandby ? P.amber : (show.selected == c.id ? P.blue : Color.clear)
        return HStack(spacing: 0) {
            cell(marker, 26).foregroundColor(missing ? P.red : P.text)
            cell(c.num, 40)
            cell(c.hasFile ? (c.isAudio ? "A" : "V") : "-", 20)
            Text(c.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            cell(c.level, 44)
            cell(c.audioOut, 50)
            cell(c.tc, 86)
            cell(c.fade, 40)
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
                        ForEach(Array(show.cues.enumerated()), id: \.element.id) { pair in
                            row(pair.offset, pair.element).id(pair.element.id)
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

struct CueEditorOld: View {
    @EnvironmentObject var show: Show

    func bind(_ kp: WritableKeyPath<Cue, String>) -> Binding<String> {
        Binding(get: {
            if let i = show.selectedIndex { return show.cues[i][keyPath: kp] }
            return ""
        }, set: { v in
            if let i = show.selectedIndex, show.cues[i][keyPath: kp] != v { show.cues[i][keyPath: kp] = v }
        })
    }
    func toggle(_ kp: WritableKeyPath<Cue, Bool>) {
        if let i = show.selectedIndex { show.cues[i][keyPath: kp].toggle() }
    }
    func cycleChase() {
        guard let i = show.selectedIndex else { return }
        let v = show.cues[i].chase
        show.cues[i].chase = v.isEmpty ? "1" : (v == "1" ? "0" : "")
    }
    func toggleMode() {
        guard let i = show.selectedIndex else { return }
        show.cues[i].mode = show.cues[i].mode == "replace" ? "" : "replace"
    }

    var body: some View {
        let c = show.selectedIndex.map { show.cues[$0] }
        let chase = c?.chase ?? ""
        let replace = (c?.mode ?? "") == "replace"
        Panel(title: "EDIT CUE") {
            HStack(spacing: 6) {
                Field(label: "#", text: bind(\.num), width: 50)
                Field(label: "NAME", text: bind(\.name))
                Field(label: "LEVEL dB", text: bind(\.level), width: 60)
                Field(label: "OUT", text: bind(\.audioOut), width: 60)
                Field(label: "FADE s", text: bind(\.fade), width: 50)
                Field(label: "FOLLOW", text: bind(\.follow), width: 60)
            }
            HStack(spacing: 6) {
                Field(label: "TC", text: bind(\.tc), width: 96)
                Field(label: "MIDI IN", text: bind(\.midiIn), width: 56)
                Field(label: "MIDI OUT", text: bind(\.midiOut), width: 56)
                Field(label: "OSC OUT", text: bind(\.oscOut), width: 120)
                VStack(alignment: .leading, spacing: 1) {
                    Text("FILE").font(arial(9)).foregroundColor(P.muted)
                    HStack(spacing: 4) {
                        Text(c.map { ($0.file as NSString).lastPathComponent } ?? "")
                            .font(arial(11)).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 5).frame(height: 22).background(P.track).cornerRadius(3)
                        PButton(title: "CHOOSE", height: 22) { show.chooseFile() }.frame(width: 64)
                    }
                }
            }
            HStack(spacing: 4) {
                PButton(title: "LINK", on: c?.with ?? false) { toggle(\.with) }
                PButton(title: "LOOP", on: c?.loop ?? false) { toggle(\.loop) }
                PButton(title: replace ? "REPLACE" : "LAYER", on: replace, color: P.amber) { toggleMode() }
                PButton(title: chase.isEmpty ? "CHASE" : (chase == "1" ? "CHASE ON" : "CHASE OFF"), on: !chase.isEmpty, color: chase == "1" ? P.blue : P.red) { cycleChase() }
                KButton(title: "GO CUE", action: "gocue", on: true, color: P.green)
                PButton(title: "GROUP") { show.addGroup() }
                PButton(title: "ADD") { show.addCue(url: nil) }
                PButton(title: "UP") { show.moveSelected(-1) }
                PButton(title: "DOWN") { show.moveSelected(1) }
                PButton(title: "DUPLICATE") { show.duplicateSelected() }
                PButton(title: show.deleteArmed ? "CONFIRM?" : "DELETE", on: show.deleteArmed, color: P.red) { show.deleteSelected() }
            }
        }
        .disabled(show.locked)
    }
}

struct RightColumnOld: View {
    @EnvironmentObject var show: Show
    var body: some View {
        VStack(spacing: 6) {
            MetersPanel(live: show.live)
            SystemPanel(live: show.live)
            MidiPanel()
            OscPanel()
            TCPanel(live: show.live)
            Spacer(minLength: 0)
        }
    }
}

struct Meter: View {
    let level: Float
    let hold: Float
    let dim: Bool
    func y(_ v: Float, _ h: CGFloat) -> CGFloat {
        let db = v <= 0.000001 ? -60 : max(-60, min(0, 20 * log10(v)))
        return h * CGFloat(1 + db / 60)
    }
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(P.track))
            let h = y(level, size.height)
            let amberY = size.height * 0.7, redY = size.height * 0.9
            let segs: [(CGFloat, CGFloat, Color)] = [(0, min(h, amberY), P.green), (amberY, min(h, redY), P.amber), (redY, h, P.red)]
            for s in segs where s.1 > s.0 {
                ctx.fill(Path(CGRect(x: 0, y: size.height - s.1, width: size.width, height: s.1 - s.0)), with: .color(s.2.opacity(dim ? 0.3 : 1)))
            }
            for db in [0.0, 6.0, 12.0, 24.0, 48.0] {
                ctx.fill(Path(CGRect(x: 0, y: size.height * CGFloat(db / 60), width: size.width, height: 0.5)), with: .color(P.panel3))
            }
            if hold > 0.00001 {
                ctx.fill(Path(CGRect(x: 0, y: size.height - y(hold, size.height), width: size.width, height: 1.5)), with: .color(hold >= 1 ? P.red : Color.white))
            }
        }
        .cornerRadius(2)
    }
}

struct MetersPanelOld: View {
    @EnvironmentObject var show: Show
    @ObservedObject var tick = Ticker()
    var live: LiveState
    func small(_ t: String, _ act: String, _ c: Int, _ on: Bool, _ col: Color) -> some View {
        KButton(title: t, action: act + String(c + 1), on: on, color: col, size: 9, height: 16)
    }
    func peakText(_ v: Float) -> String {
        if v <= 0.00001 { return " " }
        if v >= 1 { return "CLIP" }
        return String(format: "%.0f", 20 * log10(v))
    }
    var body: some View {
        let n = min(show.outChannels, 16)
        Panel {
            HStack {
                Text("AUDIO OUTS").font(arial(10, bold: true)).foregroundColor(P.muted)
                Spacer()
                KButton(title: "RESET PK", action: "resetpk", height: 18).frame(width: 70)
            }
            HStack(alignment: .top, spacing: 3) {
                ForEach(0..<n, id: \.self) { c in
                    VStack(spacing: 2) {
                        Text(peakText(live.holds[c])).font(arial(8)).foregroundColor(live.holds[c] >= 1 ? P.red : P.muted)
                            .lineLimit(1).minimumScaleFactor(0.5)
                        Meter(level: live.peaks[c], hold: live.holds[c], dim: show.mutes[c]).frame(height: 70)
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

struct SystemPanel: View {
    @ObservedObject var tick = Ticker()
    var live: LiveState
    var body: some View {
        Panel(title: "SYSTEM") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 2) {
                ForEach(0..<live.sys.count, id: \.self) { i in
                    HStack(spacing: 4) {
                        Text(live.sys[i].0).foregroundColor(P.muted)
                        Text(live.sys[i].1).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(arial(10))
                }
            }
        }
    }
}

struct LogLines: View {
    let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(0..<5, id: \.self) { i in
                Text(lines.count - 5 + i >= 0 ? lines[lines.count - 5 + i] : " ")
                    .font(arial(10)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(4).background(P.track).cornerRadius(3)
    }
}

struct NamePicker: View {
    let label: String
    let names: [String]
    let current: String
    let set: (String) -> Void
    var body: some View {
        Picker(label, selection: Binding(get: { current }, set: { set($0) })) {
            Text("None").tag("")
            ForEach(names, id: \.self) { n in Text(n).tag(n) }
        }
        .font(arial(10)).frame(maxWidth: .infinity)
    }
}

struct MidiPanel: View {
    @EnvironmentObject var show: Show
    var body: some View {
        Panel {
            HStack(spacing: 4) {
                Text("MIDI").font(arial(10, bold: true)).foregroundColor(P.muted)
                NamePicker(label: "IN", names: show.midiSources, current: show.settings.midiIn) { show.setMidiIn($0) }
                NamePicker(label: "OUT", names: show.midiDests, current: show.settings.midiOut) { show.setMidiOut($0) }
                PButton(title: show.learning ? (show.learnTarget == nil ? "PICK BUTTON" : "SEND MIDI") : "LEARN",
                        on: show.learning, color: P.violet, height: 20) { show.learnButton() }.frame(width: 90)
            }
            LogLines(lines: show.midiLog)
        }
    }
}

struct OscPanel: View {
    @EnvironmentObject var show: Show
    @State private var ip = localIP()
    var body: some View {
        Panel {
            HStack(spacing: 4) {
                Text("OSC").font(arial(10, bold: true)).foregroundColor(P.muted)
                Text(ip + " :").font(arial(10))
                IntField(value: Binding(get: { show.settings.oscInPort }, set: { show.setOscPort($0) }), width: 50)
                Text("to").font(arial(10)).foregroundColor(P.muted)
                TextField("", text: $show.settings.oscOutHost).textFieldStyle(.plain).font(arial(11))
                    .padding(.horizontal, 4).frame(height: 20).background(P.track).cornerRadius(3)
                Text(":").font(arial(10))
                IntField(value: $show.settings.oscOutPort, width: 50)
            }
            LogLines(lines: show.oscLog)
        }
    }
}

struct TCPanel: View {
    @EnvironmentObject var show: Show
    @ObservedObject var tick = Ticker()
    var live: LiveState
    func devicePicker(input: Bool, current: String, _ set: @escaping (String) -> Void) -> some View {
        Picker("", selection: Binding(get: { current }, set: { set($0) })) {
            Text(input ? "Default input" : "Main audio device").tag("")
            ForEach(show.devices.filter { input ? $0.ins > 0 : $0.outs > 0 }) { d in Text(d.name).tag(d.uid) }
        }
        .labelsHidden().font(arial(10))
    }
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Panel {
                HStack(spacing: 4) {
                    Text("TC IN").font(arial(10, bold: true)).foregroundColor(P.muted)
                    Picker("", selection: Binding(get: { show.settings.tcSource }, set: { show.settings.tcSource = $0; show.configureLTCIn() })) {
                        Text("LTC").tag("ltc")
                        Text("OSC").tag("osc")
                    }
                    .labelsHidden().frame(width: 66)
                    Picker("", selection: Binding(get: { Int(show.settings.fps.rounded()) }, set: { show.setFps(Double($0)) })) {
                        Text("24 fps").tag(24)
                        Text("25 fps").tag(25)
                        Text("30 fps").tag(30)
                    }
                    .labelsHidden().frame(width: 76)
                }
                HStack(spacing: 4) {
                    devicePicker(input: true, current: show.settings.ltcInDevice) { show.setLTCIn(device: $0) }
                    Text("CH").font(arial(10))
                    IntField(value: Binding(get: { show.settings.ltcInChannel }, set: { show.setLTCIn(channel: max(1, $0)) }), width: 32)
                }
                Text(live.tcIn).font(arial(22, bold: true).monospacedDigit()).foregroundColor(live.tcInLocked ? P.green : P.muted)
            }
            Panel {
                Text("TC OUT").font(arial(10, bold: true)).foregroundColor(P.muted).frame(height: 22)
                HStack(spacing: 4) {
                    devicePicker(input: false, current: show.settings.ltcOutDevice) { show.setLTCOut(device: $0) }
                    Text("CH").font(arial(10))
                    IntField(value: Binding(get: { show.settings.ltcOutChannel }, set: { show.setLTCOut(channel: max(1, $0)) }), width: 32)
                }
                Text(live.tcOut).font(arial(22, bold: true).monospacedDigit()).foregroundColor(show.settings.sendTC ? P.text : P.muted)
            }
        }
    }
}

struct HelpView: View {
    @EnvironmentObject var show: Show
    var body: some View {
        let lines: [String] = [
            "KEYBOARD (KEYS on):  space GO   left/right PREV/NEXT   up/down select cue   x STOP   b BLACKOUT   t TEST",
            "                     a stop audio   [ ] skip 5 s   1-8 shortcuts F1-F8",
            "",
            "OSC IN:  /cue/go  /cue/prev  /cue/next  /cue/stop  /cue/goto <id>  /shortcut/1..8",
            "         /audio/stop  /audio/resetpeaks  /out/blackout  /out/test  /ui/lock",
            "         /timeline/skip <s>  /timeline/seek <s>  /tc HH:MM:SS:FF",
            "OSC OUT: /cue/fired <id> <name>  /cue/stopped  /tc  + each cue's OSC OUT address",
            "",
            "CUE LIST:  > playing   + standby   & starts with the cue above   ~ auto-follow   ! file missing",
            "OUT:  1-2   3,4   5-12   or 5 (start at output 5)      FOLLOW:  end, or seconds",
            "F1-F8:  right-click a shortcut button to edit it",
            "",
            "MIDI LEARN:  press LEARN, click a button, send a note or CC.  LEARN again on a picked button clears it.",
            "MIDI MAP:"]
        VStack(alignment: .leading, spacing: 3) {
            ForEach(0..<lines.count, id: \.self) { i in Text(lines[i].isEmpty ? " " : lines[i]) }
            ForEach(0..<show.midimap.count, id: \.self) { i in
                let b = show.midimap[i]
                Text(mapLine(b))
            }
            Text(" ")
            Text("Click to close").foregroundColor(P.muted)
        }
        .font(Font.system(size: 12, design: .monospaced))
        .padding(16)
        .background(P.panel2)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(P.blue, lineWidth: 1))
        .foregroundColor(P.text)
        .onTapGesture { show.showHelp = false }
    }
}

func mapLine(_ b: MidiBind) -> String {
    var s = "    " + b.action
    s += "  =  " + b.type
    s += " " + String(b.number)
    if b.channel > 0 { s += "  ch " + String(b.channel) }
    return s
}
