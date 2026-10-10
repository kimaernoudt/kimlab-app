import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

/// Same palette as the TouchDesigner version.
enum P {
    static let bg = Color(hex: 0x121314)
    static let panel = Color(hex: 0x1c1d20)
    static let panel2 = Color(hex: 0x25272b)
    static let panel3 = Color(hex: 0x34373d)
    static let text = Color(hex: 0xe9eaec)
    static let muted = Color(hex: 0x8b8f97)
    static let green = Color(hex: 0x2fd16f)
    static let amber = Color(hex: 0xf5a623)
    static let red = Color(hex: 0xe5484d)
    static let blue = Color(hex: 0x3b9eff)
    static let pink = Color(hex: 0xe5559a)
    static let violet = Color(hex: 0xa78bfa)
    static let track = Color(hex: 0x0d0e10)
    static let livebg = Color(hex: 0x1d5e37)
}

func arial(_ size: CGFloat, bold: Bool = false) -> Font {
    Font.custom("Arial", size: size).weight(bold ? .bold : .regular)
}

/// Button bound to a named action, so it can be MIDI-learned and respects LOCK.
struct KButton: View {
    @EnvironmentObject var show: Show
    let title: String
    let action: String
    var on = false
    var color = P.blue
    var size: CGFloat = 11
    var height: CGFloat = 26
    var body: some View {
        let mapped = show.learning && show.midimap.contains(where: { $0.action == action })
        Button(action: { show.press(action) }) {
            Text(title).font(arial(size, bold: true)).lineLimit(1).minimumScaleFactor(0.6)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                .background(show.learnTarget == action ? P.violet : (on ? color : P.panel3))
                .foregroundColor(P.text)
                .cornerRadius(4)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(mapped ? P.violet : Color.clear, lineWidth: 1.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(show.locked && action != "lock")
    }
}

/// Plain button with a closure (not learnable).
struct PButton: View {
    @EnvironmentObject var show: Show
    let title: String
    var on = false
    var color = P.blue
    var height: CGFloat = 26
    let run: () -> Void
    var body: some View {
        Button(action: run) {
            Text(title).font(arial(11, bold: true)).lineLimit(1).minimumScaleFactor(0.6)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                .background(on ? color : P.panel3)
                .foregroundColor(P.text)
                .cornerRadius(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(show.locked)
    }
}

struct Panel<Content: View>: View {
    var title: String = ""
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !title.isEmpty { Text(title).font(arial(10, bold: true)).foregroundColor(P.muted).lineLimit(1) }
            content()
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(P.panel)
        .cornerRadius(5)
    }
}

struct Field: View {
    let label: String
    @Binding var text: String
    var width: CGFloat? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(arial(9)).foregroundColor(P.muted).lineLimit(1)
            TextField("", text: $text).textFieldStyle(.plain).font(arial(12))
                .padding(.horizontal, 5).frame(height: 22).background(P.track).cornerRadius(3)
        }
        .frame(width: width)
    }
}

struct IntField: View {
    @Binding var value: Int
    var width: CGFloat = 52
    @State private var text = ""
    var body: some View {
        TextField("", text: $text)
            .onSubmit { if let v = Int(text) { value = v } else { text = String(value) } }
            .textFieldStyle(.plain).font(arial(11))
            .padding(.horizontal, 4).frame(width: width, height: 20).background(P.track).cornerRadius(3)
            .onAppear { text = String(value) }
            .onChange(of: value) { _, v in text = String(v) }
    }
}

struct ContentViewOld: View {
    @EnvironmentObject var show: Show
    var body: some View {
        VStack(spacing: 6) {
            HeaderView()
            HStack(alignment: .top, spacing: 6) {
                LeftColumn().frame(width: 390)
                MiddleColumn()
                RightColumn().frame(width: 420)
            }
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

struct HeaderViewOld: View {
    @EnvironmentObject var show: Show
    var body: some View {
        HStack(spacing: 10) {
            Text("KIMLAB").font(arial(20, bold: true))
            Text("AUDIO").font(arial(10, bold: true)).foregroundColor(P.muted)
            Picker("", selection: Binding(get: { show.settings.audioDevice }, set: { show.setAudioDevice($0) })) {
                Text("System default").tag("")
                ForEach(show.devices.filter { $0.outs > 0 }) { d in
                    Text(d.name + " (" + String(d.outs) + " out)").tag(d.uid)
                }
            }
            .labelsHidden().frame(width: 260)
            PButton(title: "REFRESH", height: 22) { show.refreshDevices() }.frame(width: 80)
            Spacer()
            Text(show.message).font(arial(11)).foregroundColor(P.amber).lineLimit(1)
            Spacer()
            KButton(title: show.outputOpen ? "OUTPUT ON" : "OUTPUT OFF", action: "output", on: show.outputOpen, height: 22).frame(width: 100)
            OutputPicker()
            Button(action: { show.showHelp.toggle() }) {
                Text("HELP").font(arial(11, bold: true)).frame(width: 60, height: 22).background(show.showHelp ? P.blue : P.panel3).cornerRadius(4)
            }
            .buttonStyle(.plain)
        }
    }
}

struct PreviewView: NSViewRepresentable {
    let layer: CALayer
    func makeNSView(context: Context) -> LayerHostView { LayerHostView(hosted: layer) }
    func updateNSView(_ v: LayerHostView, context: Context) {}
}

struct LeftColumnOld: View {
    @EnvironmentObject var show: Show
    let cols5 = Array(repeating: GridItem(.flexible(), spacing: 4), count: 5)
    let cols4 = Array(repeating: GridItem(.flexible(), spacing: 4), count: 4)
    var body: some View {
        VStack(spacing: 6) {
            PreviewView(layer: show.video.previewRoot).aspectRatio(16.0 / 9.0, contentMode: .fit).cornerRadius(4)
            LazyVGrid(columns: cols5, spacing: 4) {
                KButton(title: "BLACKOUT", action: "blackout", on: show.blackout, color: P.red)
                KButton(title: "TEST", action: "test", on: show.testPattern)
                KButton(title: "LOCK", action: "lock", on: show.locked, color: P.amber)
                KButton(title: "KEYS", action: "keys", on: show.settings.keyboard)
                KButton(title: "AUTO", action: "auto", on: show.settings.autoFollow)
                KButton(title: "TC FOLLOW", action: "tcfollow", on: show.settings.followTC)
                KButton(title: "TC CHASE", action: "tcchase", on: show.settings.tcChase)
                KButton(title: "SEND TC", action: "sendtc", on: show.settings.sendTC)
                PButton(title: "SAVE") { show.saveShowfile() }
                PButton(title: "LOAD") { show.loadShowfile() }
            }
            LiveBars(live: show.live)
            HStack(spacing: 4) {
                KButton(title: "PREV", action: "prev", size: 14, height: 54).frame(width: 70)
                KButton(title: "GO", action: "go", on: true, color: P.green, size: 28, height: 54)
                KButton(title: "NEXT", action: "next", size: 14, height: 54).frame(width: 70)
                KButton(title: "STOP", action: "stop", on: true, color: P.red, size: 14, height: 54).frame(width: 70)
            }
            LazyVGrid(columns: cols4, spacing: 4) {
                ForEach(0..<8, id: \.self) { i in ShortcutButton(index: i) }
            }
            Spacer(minLength: 0)
        }
    }
}

struct LiveBars: View {
    @EnvironmentObject var show: Show
    @ObservedObject var live: LiveState
    var standbyText: String {
        guard show.standby < show.cues.count else { return "end of list" }
        return show.groupRange(show.standby).map { show.cues[$0].num + " " + show.cues[$0].name }.joined(separator: "  +  ")
    }
    var body: some View {
        let id = live.liveVideo ?? live.rows.keys.first
        let info = id.flatMap { live.rows[$0] }
        let cue = id.flatMap { show.cue($0) }
        let name = cue.map { $0.num + "  " + $0.name } ?? "-"
        let left = info.map { max(0, $0.dur - $0.pos) } ?? 0
        let warn = info.map { !$0.loop && $0.dur > 0 && left < 10 } ?? false
        VStack(spacing: 4) {
            HStack {
                Text("LIVE").font(arial(10, bold: true))
                Text(name).font(arial(13, bold: true)).lineLimit(1)
                Spacer()
                if let i = info {
                    Text(TC.clock(i.pos) + "  /  -" + TC.clock(left)).font(arial(13, bold: true).monospacedDigit())
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(warn ? P.red : (info != nil ? P.livebg : P.panel))
            .cornerRadius(4)
            HStack {
                Text("STANDBY").font(arial(10, bold: true))
                Text(standbyText).font(arial(13, bold: true)).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(P.panel)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(P.amber, lineWidth: 1.5))
            .cornerRadius(4)
        }
    }
}

struct ShortcutButton: View {
    @EnvironmentObject var show: Show
    let index: Int
    @State private var editing = false
    var body: some View {
        let s = show.shortcuts[index]
        KButton(title: s.label.isEmpty ? "F" + String(index + 1) : s.label, action: "f" + String(index + 1), height: 30)
            .contextMenu { Button("Edit shortcut") { editing = true } }
            .popover(isPresented: $editing) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Shortcut F" + String(index + 1)).font(arial(12, bold: true))
                    Field(label: "LABEL", text: $show.shortcuts[index].label)
                    Field(label: "TYPE  (osc / note / cc / pc)", text: $show.shortcuts[index].type)
                    Field(label: "TARGET  (OSC address or number)", text: $show.shortcuts[index].target)
                    Field(label: "VALUE  (OSC arguments or velocity)", text: $show.shortcuts[index].value)
                    Field(label: "MIDI CHANNEL", text: $show.shortcuts[index].channel)
                }
                .padding(10).frame(width: 280).background(P.panel).foregroundColor(P.text)
            }
    }
}

struct TimelineBar: View {
    @EnvironmentObject var show: Show
    @ObservedObject var live: LiveState
    var body: some View {
        let info = live.timelineCue.flatMap { live.rows[$0] }
        let name = live.timelineCue.flatMap { show.cue($0) }?.name ?? ""
        let frac: Double = info.map { $0.dur > 0 ? min(1, max(0, $0.pos / $0.dur)) : 0 } ?? 0
        Panel(title: "TIMELINE   " + name) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Rectangle().fill(P.track)
                    Rectangle().fill(P.blue.opacity(0.45)).frame(width: w * frac)
                    Rectangle().fill(P.red).frame(width: 2).offset(x: w * frac - 1)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { g in
                    if let i = info, i.dur > 0, !show.locked, w > 0 {
                        show.seekTimeline(seconds: Double(max(0, min(1, g.location.x / w))) * i.dur)
                    }
                })
            }
            .frame(height: 34).cornerRadius(3)
            HStack {
                Text(info.map { TC.clock($0.pos) } ?? "-")
                Spacer()
                Text(info.map { TC.clock($0.dur) } ?? "-")
                Spacer()
                Text(info.map { "-" + TC.clock(max(0, $0.dur - $0.pos)) } ?? "-")
            }
            .font(arial(11).monospacedDigit()).foregroundColor(P.muted)
        }
    }
}
