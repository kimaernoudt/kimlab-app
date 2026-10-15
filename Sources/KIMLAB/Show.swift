import SwiftUI
import AVFoundation
import Synchronization

/// One cue that is playing (or about to).
final class Playing {
    let cue: UUID
    let isVideo: Bool
    var voice: Int? = nil
    var feeder: Feeder? = nil
    var video: Int? = nil
    var started = Date()
    var launched = false
    var offset = 0.0
    var fade = 0.0
    var followDone = false
    var stopping = false
    var chasePaused = false
    var chasing = false
    var seekTarget = 0.0
    var lastRelocate = Date.distantPast
    var routeSpec = ""
    init(cue: UUID, isVideo: Bool) { self.cue = cue; self.isVideo = isVideo }
}

struct RowInfo: Equatable {
    var pos = 0.0
    var dur = 0.0
    var loop = false
}

/// Fast-changing display state (meters, positions, timecode). Published as one batch ~15 times a second.
final class LiveState: ObservableObject {
    var rows: [UUID: RowInfo] = [:]
    var liveVideo: UUID? = nil
    var timelineCue: UUID? = nil
    var peaks = [Float](repeating: 0, count: Mixer.maxOut)
    var holds = [Float](repeating: 0, count: Mixer.maxOut)
    var tcIn = "--:--:--:--"
    var tcOut = "--:--:--:--"
    var tcInLocked = false
    var ltcLevel: Float = 0
    var sys: [(String, String)] = []
    var missing = Set<UUID>()
    let meterTick = Ticker()
    let clockTick = Ticker()
    let sysTick = Ticker()
    var metersActive = false
    var hadRows = false
    var clockSig = ""
    func bump() { objectWillChange.send() }
}

final class Show: ObservableObject {
    static let defaultMap = [
        MidiBind(action: "go", type: "note", channel: 0, number: 60),
        MidiBind(action: "prev", type: "note", channel: 0, number: 61),
        MidiBind(action: "stop", type: "note", channel: 0, number: 62),
        MidiBind(action: "next", type: "note", channel: 0, number: 63)]

    @Published var cues: [Cue] = [] { didSet { dirty = true } }
    @Published var shortcuts: [Shortcut] = Array(repeating: Shortcut(), count: 8) { didSet { dirty = true } }
    @Published var midimap: [MidiBind] = Show.defaultMap { didSet { dirty = true } }
    @Published var settings = Settings() { didSet { dirty = true } }
    @Published var standby = 0
    @Published var selected: UUID? = nil
    @Published var blackout = false
    @Published var testPattern = false
    @Published var locked = false
    @Published var learning = false
    @Published var learnTarget: String? = nil
    @Published var showHelp = false
    @Published var deleteArmed = false
    @Published var outputOpen = false
    @Published var devices: [AudioDevice] = []
    @Published var midiSources: [String] = []
    @Published var midiDests: [String] = []
    @Published var midiLog: [String] = []
    @Published var oscLog: [String] = []
    @Published var message = ""
    @Published var mutes = [Bool](repeating: false, count: Mixer.maxOut)
    @Published var solos = [Bool](repeating: false, count: Mixer.maxOut)
    @Published var pinks = [Bool](repeating: false, count: Mixer.maxOut)
    @Published var outChannels = 8
    @Published var deviceChannels = 2
    @Published var collapsed = Set<UUID>()
    @Published var nextThumb: NSImage? = nil
    @Published var lengths: [String: Double] = [:]
    @Published var peerAlive = false
    @Published var linkNote = ""
    @Published var syncStatus = ""
    @Published var countdownOpen = false

    let live = LiveState()
    let mixer = Mixer()
    let video = VideoOut()
    let countdown = Countdown()
    let osc = OSC()
    let midi = MIDI()
    let ltcEnc = LTCEncoder()
    let ltcDec = LTCDecoder()
    let ltcIn = HALInput()
    let ltcOutHal = HALOutput()
    var playing: [Playing] = []
    var pending: [[Playing]] = []
    var videoOwner: [Playing?] = [nil, nil]
    var timer: Timer? = nil
    var lastGo = Date.distantPast
    var dirty = false
    var tickCount = 0
    var started = false
    var oscTC: (Double, Date)? = nil
    var lastTC: Double? = nil
    var lastTCAt = Date()
    var tcCue: UUID? = nil
    var lastOsc = Date.distantPast
    var lastMidi = Date.distantPast
    var pendingScheduled = false
    var noPersist = false
    var groupRuns: [GroupRun] = []
    var nextThumbKey = "-"
    var lengthPending = Set<String>()
    var lengthCalls = 0
    let link = OSC()
    var lastPeer = Date.distantPast
    var peerHeard = false
    var linkSeq = 0
    var lastLinkFire: [Int: Date] = [:]
    var sigDiffSince: Date? = nil
    var syncBusy = false
    var pendingShow: URL? = nil
    let syncServer = SyncServer()

    // MARK: setup

    func setup() {
        if started { return }
        started = true
        loadState()
        normalizeCues()
        mixer.ltc = ltcEnc
        refreshDevices()
        startAudio()
        osc.onMessage = { [weak self] a, args in self?.oscIn(a, args) }
        if !osc.listen(port: settings.oscInPort) { message = "OSC port " + String(settings.oscInPort) + " is in use" }
        midi.onMessage = { [weak self] s, a, b in self?.midiIn(s, a, b) }
        midi.selectInput(settings.midiIn)
        midi.selectOutput(settings.midiOut)
        video.onEnded = { [weak self] i in self?.videoEnded(i) }
        video.screenIndex = video.startupIndex(settings.outputScreen)
        if video.screenIndex != settings.outputScreen { settings.outputScreen = video.screenIndex }
        video.openWindow()
        outputOpen = true
        if !settings.outputRes.isEmpty { applyOutputRes() }
        setupCountdown()
        configureLink()
        configureLTCIn()
        installKeys()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.saveState()
        }
        preloadStandby()
    }

    var stateURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KIMLAB")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }

    func loadState() {
        defer { dirty = false }
        if noPersist { return }
        guard let d = try? Data(contentsOf: stateURL),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        func decode<T: Codable>(_ v: Any, _ t: T.Type) -> T? {
            guard let dd = try? JSONSerialization.data(withJSONObject: v) else { return nil }
            return try? JSONDecoder().decode(t, from: dd)
        }
        func dict<T: Codable>(_ v: T) -> [String: Any] {
            guard let dd = try? JSONEncoder().encode(v) else { return [:] }
            return ((try? JSONSerialization.jsonObject(with: dd)) as? [String: Any]) ?? [:]
        }
        // saved values are merged over the defaults, so a newer version with extra fields still loads old files
        if let arr = obj["cues"] as? [[String: Any]] {
            var out = [Cue]()
            for saved in arr {
                var base = dict(Cue())
                for (k, v) in saved { base[k] = v }
                if let c = decode(base, Cue.self) { out.append(c) }
            }
            cues = out
        }
        if let s = obj["shortcuts"], let v = decode(s, [Shortcut].self), v.count == 8 { shortcuts = v }
        if let s = obj["midimap"], let v = decode(s, [MidiBind].self) { midimap = v }
        if let saved = obj["settings"] as? [String: Any] {
            var base = dict(settings)
            for (k, v) in saved { base[k] = v }
            if let v = decode(base, Settings.self) { settings = v }
        }
    }

    func saveState() {
        if noPersist { dirty = false; return }
        let s = SavedState(cues: cues, shortcuts: shortcuts, midimap: midimap, settings: settings)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: stateURL, options: .atomic) }
        dirty = false
    }

    func refreshDevices() {
        devices = CA.devices()
        lengths = [:]
        lengthPending = []
        midiSources = MIDI.sources()
        midiDests = MIDI.destinations()
    }

    func startAudio() {
        let dev = CA.device(uid: settings.audioDevice, input: false)
        if !mixer.start(device: dev) { message = "The audio device did not start" }
        mixer.pinkGain = dbToLin(settings.pinkLevel)
        deviceChannels = mixer.channels
        outChannels = min(max(8, mixer.channels), Mixer.maxOut)
        mixer.busChannels = outChannels
        video.setClock(device: dev)
        configureLTCOut()
    }

    func setAudioDevice(_ uid: String) {
        stopAll(fade: 0)
        settings.audioDevice = uid
        startAudio()
    }

    func configureLTCOut() {
        ltcEnc.fps = max(1, Int(settings.fps.rounded()))
        let mainUID = devices.first(where: { $0.id == mixer.hal.deviceID })?.uid ?? ""
        let ch = max(0, settings.ltcOutChannel - 1)
        if !settings.sendTC {
            mixer.ltcChannel = -1
            ltcOutHal.stop()
            ltcEnc.running.store(false, ordering: .sequentiallyConsistent)
            return
        }
        if settings.ltcOutDevice.isEmpty || settings.ltcOutDevice == mainUID {
            ltcOutHal.stop()
            mixer.ltcChannel = ch
        } else {
            mixer.ltcChannel = -1
            let enc = ltcEnc, hal = ltcOutHal
            hal.render = { [unowned hal] bufs, n, _ in
                if ch < bufs.count, let p = bufs[ch].mData?.assumingMemoryBound(to: Float.self) {
                    enc.render(p, frames: n, sampleRate: hal.sampleRate)
                }
            }
            if !hal.start(device: CA.device(uid: settings.ltcOutDevice, input: false)) { message = "The LTC output device did not start" }
        }
    }

    func configureLTCIn() {
        ltcIn.stop()
        guard settings.tcSource == "ltc", settings.followTC || !settings.ltcInDevice.isEmpty else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] ok in
            DispatchQueue.main.async {
                guard let s = self else { return }
                if !ok { s.message = "Allow microphone access for KIMLAB to read LTC"; return }
                let ch = max(0, s.settings.ltcInChannel - 1)
                let dec = s.ltcDec, hal = s.ltcIn
                hal.onAudio = { [unowned hal] bufs, n, host in
                    if ch < bufs.count, let p = bufs[ch].mData?.assumingMemoryBound(to: Float.self) {
                        dec.process(UnsafePointer(p), frames: n, sampleRate: hal.sampleRate, hostTime: host,
                                    ticksPerSample: 1.0 / (hal.sampleRate * hostToSec))
                    }
                }
                if !hal.start(device: CA.device(uid: s.settings.ltcInDevice, input: true)) { s.message = "The LTC input device did not start" }
            }
        }
    }

    // MARK: cue list helpers

    func cue(_ id: UUID) -> Cue? { cues.first { $0.id == id } }
    func index(_ id: UUID) -> Int? { cues.firstIndex { $0.id == id } }
    var selectedIndex: Int? { selected.flatMap { index($0) } }
    func groupRange(_ head: Int) -> Range<Int> {
        var e = head + 1
        while e < cues.count && cues[e].with { e += 1 }
        return head..<e
    }
    func headOf(_ i: Int) -> Int {
        var h = max(0, min(i, cues.count - 1))
        while h > 0 && cues[h].with { h -= 1 }
        return h
    }
    func nextHead(after head: Int) -> Int { groupRange(head).upperBound }
    func isPlaying(_ id: UUID) -> Bool { cueOrGroupPlaying(id) }

    // MARK: transport

    func go() {
        guard Date().timeIntervalSince(lastGo) >= settings.goLock else { return }
        lastGo = Date()
        guard standby < cues.count else { return }
        let h = standby
        fireGroup(h)
        standby = nextHead(after: h)
        preloadStandby()
    }
    func prev() {
        if standby > 0 && !cues.isEmpty { standby = headOf(standby - 1) }
        preloadStandby()
    }
    func next() {
        if standby < cues.count { standby = nextHead(after: standby) }
        preloadStandby()
    }
    func stopAll(fade: Double) {
        pending.removeAll()
        for p in Array(playing) { stop(p, fade: fade < 0 ? outFade(p, settings.defaultFade) : fade) }
        tcCue = nil
        sendOSC("/cue/stopped", [])
    }
    func stopAudio() {
        for p in Array(playing) where !p.isVideo { stop(p, fade: outFade(p, settings.defaultFade)) }
    }
    func fireCue(at i: Int) {
        guard i >= 0 && i < cues.count else { return }
        let h = headOf(i)
        fireGroup(h)
        standby = nextHead(after: h)
        preloadStandby()
    }
    func fireNext(after c: Cue) {
        guard let i = index(c.id) else { return }
        let nh = nextHead(after: headOf(i))
        if nh < cues.count { fireCue(at: nh) }
    }

    func fireGroup(_ head: Int, offset: Double = 0, viaTC: Bool = false) {
        guard head >= 0 && head < cues.count else { return }
        linkFire(head, offset)
        var group = [Playing]()
        let headBase = TC.parse(cues[head].tc, fps: settings.fps)
        for i in groupRange(head) {
            let c = cues[i]
            if c.group { cueOutputs(c); continue }
            let fade = max(0, parseNum(c.fade) ?? settings.defaultFade)
            var off = offset
            if viaTC, let hb = headBase, let base = TC.parse(c.tc, fps: settings.fps) { off = max(0, offset + hb - base) }
            if c.loop { off = 0 }
            let p = (c.hasFile && c.isAudio) ? playAudio(c, fade: fade, offset: off) : playVideo(c, fade: fade, offset: off)
            if let p = p { group.append(p) }
            cueOutputs(c)
        }
        if cues[head].group { groupRuns.append(GroupRun(head: cues[head].id, members: group)) }
        if !group.isEmpty {
            pending.append(group)
            tryLaunch()
            schedulePending()
        }
    }

    // MARK: playback

    func makeVoice(url: URL, level: Float, fadeIn: Double, offset: Double, loop: Bool, route: String, p: Playing) {
        guard let vi = mixer.acquire() else { message = "No free audio voice"; return }
        let v = mixer.voices[vi]
        v.reset(level: level, fadeIn: fadeIn, sampleRate: mixer.sampleRate, hold: true)
        p.voice = vi
        p.routeSpec = route
        p.feeder = Feeder(url: url, voice: v, sampleRate: mixer.sampleRate, start: offset, loop: loop, routeSpec: route)
    }

    func playAudio(_ c: Cue, fade: Double, offset: Double) -> Playing? {
        guard FileManager.default.fileExists(atPath: c.file) else { message = "File missing: " + c.name; return nil }
        for p in Array(playing) where p.cue == c.id && !p.isVideo { stop(p, fade: 0.03) }
        if c.mode == "replace" { for p in Array(playing) where !p.isVideo && !p.stopping { stop(p, fade: max(0.05, outFade(p, fade))) } }
        if playing.filter({ !$0.isVideo && !$0.stopping }).count >= 8 { message = "All 8 audio players are busy"; return nil }
        let p = Playing(cue: c.id, isVideo: false)
        p.offset = offset
        p.fade = fade
        makeVoice(url: URL(fileURLWithPath: c.file), level: c.levelLin, fadeIn: fade, offset: offset, loop: c.loop, route: c.audioOut, p: p)
        if p.voice == nil { return nil }
        playing.append(p)
        return p
    }

    func playVideo(_ c: Cue, fade: Double, offset: Double) -> Playing? {
        let hasMedia = c.hasFile && FileManager.default.fileExists(atPath: c.file)
        if c.hasFile && !hasMedia { message = "File missing: " + c.name }
        // the current video fades out under the new one (or to black when this cue has no file)
        for p in Array(playing) where p.isVideo && !p.stopping { stop(p, fade: outFade(p, fade), videoHide: !hasMedia) }
        guard hasMedia else { return nil }
        let url = URL(fileURLWithPath: c.file)
        var idx = videoOwner[0] == nil ? 0 : (videoOwner[1] == nil ? 1 : -1)
        if idx < 0 {
            // both players busy (very fast GOs): drop the older one
            let a = videoOwner[0]!, b = videoOwner[1]!
            let old = a.started <= b.started ? 0 : 1
            finish(videoOwner[old]!)
            idx = old
        }
        if c.isImage { if video.urls[idx] != url || !video.imageShown[idx] { if !video.loadImage(idx, url: url) { message = "Could not open image: " + c.name } } } else if video.urls[idx] != url || offset > 0 { video.load(idx, url: url, at: offset) }
        let p = Playing(cue: c.id, isVideo: true)
        p.offset = offset
        p.fade = fade
        p.video = idx
        videoOwner[idx] = p
        if !c.isImage { makeVoice(url: url, level: c.levelLin, fadeIn: fade, offset: offset, loop: false, route: c.audioOut, p: p) }
        playing.append(p)
        return p
    }

    func primed(_ p: Playing) -> Bool {
        guard let f = p.feeder, let vi = p.voice else { return true }
        if f.noAudio { return true }
        let v = mixer.voices[vi]
        return v.w.load(ordering: .sequentiallyConsistent) >= 2048 || v.eof.load(ordering: .sequentiallyConsistent)
    }

    func tryLaunch() {
        var rest = [[Playing]]()
        for g in pending {
            let waiting = g.contains { p in
                if p.stopping || Date().timeIntervalSince(p.started) > 3 { return false }
                if let i = p.video, !video.ready(i) && !video.failed(i) { return true }
                return !primed(p)
            }
            if waiting { rest.append(g); continue }
            let lead = g.contains { $0.offset > 0 } ? 0.2 : 0.06
            let at = hostAfter(lead)
            let vAt = hostAfter(max(0, lead + settings.avOffsetMs / 1000))
            for p in g where !p.stopping {
                if let f = p.feeder, f.noAudio { freeVoice(p) }
                if let vi = p.voice { mixer.voices[vi].startHost.store(at, ordering: .sequentiallyConsistent) }
                if let i = p.video {
                    video.start(i, at: p.offset, host: vAt)
                    video.show(i, fade: p.fade)
                }
                p.launched = true
                p.started = Date()
            }
        }
        pending = rest
    }

    func schedulePending() {
        if pending.isEmpty || pendingScheduled { return }
        pendingScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) { [weak self] in
            guard let s = self else { return }
            s.pendingScheduled = false
            s.tryLaunch()
            s.schedulePending()
        }
    }

    func stop(_ p: Playing, fade: Double, videoHide: Bool = true) {
        if p.stopping { return }
        p.stopping = true
        if let vi = p.voice {
            if !p.launched || p.chasePaused || fade <= 0.001 { freeVoice(p) }
            else { mixer.voices[vi].fade(to: 0, seconds: fade, sampleRate: mixer.sampleRate, thenStop: true) }
        }
        if let i = p.video, videoHide { video.hide(i, fade: fade) }
        if fade <= 0.001 { finish(p); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + fade + 0.15) { [weak self] in self?.finish(p) }
    }

    func freeVoice(_ p: Playing) {
        p.feeder?.cancel()
        p.feeder = nil
        if let vi = p.voice { mixer.release(vi); p.voice = nil }
    }

    func finish(_ p: Playing) {
        p.stopping = true
        freeVoice(p)
        if let i = p.video, videoOwner[i] === p {
            video.hide(i, fade: 0)
            video.clear(i)
            videoOwner[i] = nil
        }
        playing.removeAll { $0 === p }
    }

    func ended(_ p: Playing) {
        let c = cue(p.cue)
        finish(p)
        if let c = c, c.follow.lowercased() == "end", settings.autoFollow, !p.followDone {
            p.followDone = true
            fireNext(after: c)
        }
    }

    func videoEnded(_ idx: Int) {
        guard let p = videoOwner[idx], !p.stopping, p.launched else { return }
        if let c = cue(p.cue), c.loop { relocate(p, to: 0, lead: 0.08) } else if holdsOpen(p) { return } else { ended(p) }
    }

    func relocate(_ p: Playing, to t: Double, lead: Double = 0.2) {
        let at = hostAfter(lead)
        p.lastRelocate = Date()
        p.seekTarget = t
        p.chasePaused = false
        if let f = p.feeder, let vi = p.voice {
            let v = mixer.voices[vi]
            f.seek(t)
            v.startHost.store(at, ordering: .sequentiallyConsistent)
            v.paused.store(false, ordering: .sequentiallyConsistent)
            if v.finished.load(ordering: .sequentiallyConsistent) {
                v.finished.store(false, ordering: .sequentiallyConsistent)
                v.active.store(true, ordering: .sequentiallyConsistent)
            }
        }
        if let i = p.video { video.start(i, at: t, host: hostAfter(max(0, lead + settings.avOffsetMs / 1000))) }
    }

    func pause(_ p: Playing) {
        p.chasePaused = true
        if let vi = p.voice { mixer.voices[vi].paused.store(true, ordering: .sequentiallyConsistent) }
        if let i = p.video { video.pause(i) }
    }

    func position(_ p: Playing) -> Double {
        if !p.launched { return p.offset }
        if let i = p.video { return video.imageShown[i] ? Date().timeIntervalSince(p.started) : video.position(i) }
        return p.feeder?.position() ?? 0
    }
    func duration(_ p: Playing) -> Double {
        if let i = p.video { return video.imageShown[i] ? (parseNum(cue(p.cue)?.hold ?? "") ?? 0) : video.duration(i) }
        return p.feeder?.duration ?? 0
    }

    /// Loads the standby video paused in the idle player so GO starts without a hiccup.
    func preloadStandby() {
        updateNextThumb()
        guard standby < cues.count else { return }
        for i in groupRange(standby) {
            let c = cues[i]
            if !c.hasFile || c.isAudio { continue }
            guard let idx = (videoOwner[0] == nil ? 0 : (videoOwner[1] == nil ? 1 : nil)) else { return }
            let url = URL(fileURLWithPath: c.file)
            if video.urls[idx] != url && FileManager.default.fileExists(atPath: c.file) { if c.isImage { _ = video.loadImage(idx, url: url) } else { video.load(idx, url: url, at: 0) } }
            return
        }
    }
}
