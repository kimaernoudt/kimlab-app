import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct HeaderView: View {
    @EnvironmentObject var show: Show
    var body: some View {
        let bad = show.linkOn && (!show.peerAlive || !show.linkNote.isEmpty)
        let role = show.isMain ? "MAIN" : "BACKUP"
        let other = show.isMain ? "BACKUP" : "MAIN"
        let status = !show.linkNote.isEmpty ? show.linkNote : (show.peerAlive ? other + " OK" : "NO " + other)
        HStack(spacing: 10) {
            Text("KIMLAB").font(arial(20, bold: true))
            if show.linkOn {
                Text(role + "   " + status).font(arial(12, bold: true))
                    .padding(.horizontal, 10).frame(height: 22)
                    .background(bad ? P.red : P.livebg).cornerRadius(4)
            }
            Spacer()
            Text(show.message).font(arial(11)).foregroundColor(P.amber).lineLimit(1)
            Spacer()
            Button(action: { show.showHelp.toggle() }) {
                Text("HELP").font(arial(11, bold: true)).frame(width: 60, height: 22).background(show.showHelp ? P.blue : P.panel3).cornerRadius(4)
            }
            .buttonStyle(.plain)
        }
    }
}

/// Picture and names of the standby cue (or group).
struct NextPreview: View {
    @EnvironmentObject var show: Show
    var body: some View {
        let has = show.standby < show.cues.count
        let range = has ? Array(show.groupRange(show.standby).prefix(6)) : []
        Panel(title: "NEXT") {
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    Rectangle().fill(Color.black)
                    if let img = show.nextThumb {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Text(has ? "no picture" : "end of list").font(arial(10)).foregroundColor(P.muted)
                    }
                }
                .frame(width: 192, height: 108).cornerRadius(3)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(range, id: \.self) { i in
                        Text(show.cues[i].num + "  " + show.cues[i].name)
                            .font(arial(i == show.standby ? 13 : 11, bold: i == show.standby))
                            .foregroundColor(i == show.standby ? P.text : P.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(P.amber, lineWidth: 1))
    }
}

/// Output resolution, next to the screen selection.
struct ResPicker: View {
    @EnvironmentObject var show: Show
    var body: some View {
        Picker("", selection: Binding(get: { show.settings.outputRes }, set: { show.setOutputRes($0) })) {
            Text("Native").tag("")
            Text("1280 x 720").tag("1280x720")
            Text("1920 x 1080").tag("1920x1080")
            Text("1920 x 1200").tag("1920x1200")
            Text("2560 x 1440").tag("2560x1440")
            Text("3840 x 2160").tag("3840x2160")
        }
        .labelsHidden().frame(width: 118)
    }
}

struct LeftColumn: View {
    @EnvironmentObject var show: Show
    let cols5 = Array(repeating: GridItem(.flexible(), spacing: 4), count: 5)
    let cols4 = Array(repeating: GridItem(.flexible(), spacing: 4), count: 4)
    var body: some View {
        VStack(spacing: 6) {
            PreviewView(layer: show.video.previewRoot).aspectRatio(16.0 / 9.0, contentMode: .fit).cornerRadius(4)
            HStack(spacing: 4) {
                KButton(title: show.outputOpen ? "OUTPUT ON" : "OUTPUT OFF", action: "output", on: show.outputOpen, height: 22).frame(width: 92)
                OutputPicker().frame(width: 214).clipped()
                ResPicker()
                Spacer(minLength: 0)
            }
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
            HStack(spacing: 4) {
                KButton(title: "PREV", action: "prev", size: 14, height: 54).frame(width: 78)
                KButton(title: "GO", action: "go", on: true, color: P.green, size: 28, height: 54)
                KButton(title: "NEXT", action: "next", size: 14, height: 54).frame(width: 78)
                KButton(title: "STOP", action: "stop", on: true, color: P.red, size: 14, height: 54).frame(width: 78)
            }
            LazyVGrid(columns: cols4, spacing: 4) {
                ForEach(0..<8, id: \.self) { i in ShortcutButton(index: i) }
            }
            NextPreview()
            Spacer(minLength: 0)
        }
    }
}

struct AudioDeviceRow: View {
    @EnvironmentObject var show: Show
    var body: some View {
        HStack(spacing: 6) {
            Text("AUDIO").font(arial(10, bold: true)).foregroundColor(P.muted)
            Picker("", selection: Binding(get: { show.settings.audioDevice }, set: { show.setAudioDevice($0) })) {
                Text("System default").tag("")
                ForEach(show.devices.filter { $0.outs > 0 }) { d in
                    Text(d.name + " (" + String(d.outs) + " out)").tag(d.uid)
                }
            }
            .labelsHidden().frame(maxWidth: .infinity)
            PButton(title: "REFRESH", height: 22) { show.refreshDevices() }.frame(width: 76)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(P.panel).cornerRadius(5)
    }
}

/// Main / backup link with a second laptop. OFF is the bypass: a plain single-machine player.
struct RedundancyPanel: View {
    @EnvironmentObject var show: Show
    var body: some View {
        Panel {
            HStack(spacing: 4) {
                Text("REDUNDANCY").font(arial(10, bold: true)).foregroundColor(P.muted)
                Picker("", selection: Binding(get: { show.settings.redundancy }, set: { show.settings.redundancy = $0; show.configureLink() })) {
                    Text("OFF (bypass)").tag("off")
                    Text("MAIN").tag("main")
                    Text("BACKUP").tag("backup")
                }
                .labelsHidden().frame(width: 124)
                Text("OTHER").font(arial(10)).foregroundColor(P.muted)
                TextField("IP address", text: $show.settings.peerHost).textFieldStyle(.plain).font(arial(11))
                    .padding(.horizontal, 4).frame(height: 20).background(P.track).cornerRadius(3)
                Text(":").font(arial(10))
                IntField(value: $show.settings.peerPort, width: 44)
            }
            HStack(spacing: 4) {
                Text("LISTEN").font(arial(10)).foregroundColor(P.muted)
                IntField(value: Binding(get: { show.settings.linkListen }, set: { show.settings.linkListen = $0; show.configureLink() }), width: 44)
                PButton(title: "SENSE TONE", on: show.settings.senseTone, color: P.green, height: 20) { show.settings.senseTone.toggle() }.frame(width: 96)
                Text("OUT").font(arial(10)).foregroundColor(P.muted)
                IntField(value: $show.settings.senseChannel, width: 34)
                Text("1 kHz, -20 dB").font(arial(9)).foregroundColor(P.muted).lineLimit(1)
                Spacer(minLength: 0)
            }
        }
    }
}

struct RightColumn: View {
    @EnvironmentObject var show: Show
    var body: some View {
        VStack(spacing: 6) {
            AudioDeviceRow()
            MetersPanel(tick: show.live.meterTick, live: show.live)
            MidiPanel()
            OscPanel()
            TCPanel(tick: show.live.clockTick, live: show.live)
            RedundancyPanel()
            SyncRow()
            Spacer(minLength: 0)
            SystemPanel(tick: show.live.sysTick, live: show.live)
        }
    }
}

struct CueEditor: View {
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
        let path = c?.file ?? ""
        Panel(title: "EDIT CUE") {
            HStack(spacing: 6) {
                Field(label: "#", text: bind(\.num), width: 50)
                Field(label: "NAME", text: bind(\.name))
                Field(label: "LEVEL dB", text: bind(\.level), width: 60)
                Field(label: "OUT", text: bind(\.audioOut), width: 60)
            }
            HStack(spacing: 6) {
                Field(label: "FADE IN s", text: bind(\.fade))
                Field(label: "FADE OUT s", text: bind(\.fadeOut))
                Field(label: "HOLD s", text: bind(\.hold))
                Field(label: "FOLLOW", text: bind(\.follow))
                Field(label: "TC", text: bind(\.tc), width: 96)
            }
            HStack(spacing: 6) {
                Field(label: "MIDI IN", text: bind(\.midiIn), width: 70)
                Field(label: "MIDI OUT", text: bind(\.midiOut), width: 70)
                Field(label: "OSC OUT", text: bind(\.oscOut))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("FILE").font(arial(9)).foregroundColor(P.muted)
                HStack(spacing: 4) {
                    Text(path)
                        .font(arial(11)).lineLimit(1).truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 5).frame(height: 22).background(P.track).cornerRadius(3)
                        .help(path)
                    PButton(title: "CHOOSE", height: 22) { show.chooseFile() }.frame(width: 64)
                }
            }
            HStack(spacing: 4) {
                PButton(title: "IN GROUP", on: c?.with ?? false) { show.toggleInGroup() }
                PButton(title: "LOOP", on: c?.loop ?? false) { toggle(\.loop) }
                PButton(title: replace ? "REPLACE" : "LAYER", on: replace, color: P.amber) { toggleMode() }
                PButton(title: chase.isEmpty ? "CHASE" : (chase == "1" ? "CHASE ON" : "CHASE OFF"), on: !chase.isEmpty, color: chase == "1" ? P.blue : P.red) { cycleChase() }
                KButton(title: "GO CUE", action: "gocue", on: true, color: P.green)
            }
            HStack(spacing: 4) {
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

/// Cue list: group rows fold, subcues are indented; rows and Finder files can be dropped onto rows.
struct CueListOld3: View {
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func row(_ i: Int, _ c: Cue) -> some View {
        let info = live.rows[c.id]
        let inStandby = show.standby < show.cues.count && show.groupRange(show.standby).contains(i)
        let missing = live.missing.contains(c.id)
        var marker = ""
        if info != nil { marker = ">" } else if inStandby { marker = "+" }
        if !c.follow.isEmpty { marker += "~" }
        if missing { marker += "!" }
        var left = ""
        if let r = info { left = r.loop ? "LOOP" : (r.dur > 0 ? "-" + TC.clock(max(0, r.dur - r.pos)) : "") }
        var length = ""
        if let l = show.lengths[c.file], l > 0, !c.group { length = TC.clock(l) }
        let frac: Double = info.map { $0.dur > 0 ? min(1, max(0, $0.pos / $0.dur)) : 0 } ?? 0
        let isSel = show.selected == c.id
        let isDrop = dropTarget == c.id
        let base = info != nil ? P.livebg : (isSel ? P.panel3 : (c.group ? P.bg : P.panel2))
        let edge = isDrop ? P.violet : (inStandby ? P.amber : (isSel ? P.blue : Color.clear))
        let kind = c.group ? "G" : (c.hasFile ? (c.isAudio ? "A" : (c.isImage ? "I" : "V")) : "-")
        let targeted = Binding<Bool>(get: { dropTarget == c.id }, set: { on in
            if on { dropTarget = c.id } else if dropTarget == c.id { dropTarget = nil }
        })
        return HStack(spacing: 0) {
            cell(marker, 24).foregroundColor(missing ? P.red : P.text)
            if c.with {
                Rectangle().fill(P.blue.opacity(0.7)).frame(width: 2, height: 22).padding(.leading, 8).padding(.trailing, 12)
            }
            cell(c.num, 34)
            cell(kind, 20)
            nameCell(i, c)
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
        .onTapGesture { if !show.locked { show.select(c.id) } }
        .draggable(c.id.uuidString)
        .onDrop(of: CueList.dropTypes, isTargeted: targeted) { providers in handle(providers, c.id) }
    }

    var body: some View {
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
                            row(i, show.cues[i]).id(show.cues[i].id)
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
