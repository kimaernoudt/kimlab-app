import Foundation

let QUOTE = Character(UnicodeScalar(UInt8(34)))
let QS = String(QUOTE)
let NL = String(Character(UnicodeScalar(UInt8(10))))

func parseNum(_ s: String) -> Double? {
    Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
}
func dbToLin(_ db: Double) -> Float { Float(pow(10.0, db / 20.0)) }

enum TC {
    /// HH:MM:SS:FF -> seconds
    static func parse(_ s: String, fps: Double) -> Double? {
        let parts = s.split(whereSeparator: { $0 == ":" || $0 == ";" || $0 == "." })
        if parts.count != 4 { return nil }
        var v = [Int]()
        for p in parts { guard let n = Int(p) else { return nil }; v.append(n) }
        return Double(v[0] * 3600 + v[1] * 60 + v[2]) + Double(v[3]) / max(fps, 1)
    }
    static func format(_ t: Double, fps: Double) -> String {
        let f = max(1, Int(fps.rounded()))
        let total = Int((max(0, t) * Double(f) + 0.0001).rounded(.down))
        let s = total / f
        return String(format: "%02d:%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60, total % f)
    }
    static func clock(_ t: Double) -> String {
        let s = Int(max(0, t).rounded(.down))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// "1-2", "3,4", "5-12" or "5" (start at output 5) -> zero-based output indices
func parseOuts(_ s: String) -> (outs: [Int], openEnded: Bool) {
    let t = s.replacingOccurrences(of: " ", with: "")
    if t.isEmpty { return ([0, 1], false) }
    if let n = Int(t) { return ([max(0, n - 1)], true) }
    var outs = [Int]()
    for part in t.split(separator: ",") {
        let ab = part.split(separator: "-")
        if ab.count == 2, let a = Int(ab[0]), let b = Int(ab[1]), a >= 1, b >= a {
            for c in a...min(b, a + 63) { outs.append(c - 1) }
        } else if let a = Int(part), a >= 1 { outs.append(a - 1) }
    }
    return (outs.isEmpty ? [0, 1] : outs, false)
}

/// (source channel, output channel) pairs for a source with srcCh channels
func routePairs(_ spec: String, srcCh: Int) -> [(Int, Int)] {
    let (outs, open) = parseOuts(spec)
    var pairs = [(Int, Int)]()
    if open { for c in 0..<srcCh { pairs.append((c, outs[0] + c)) } }
    else if srcCh == 1 { for o in outs { pairs.append((0, o)) } }
    else { for c in 0..<min(srcCh, outs.count) { pairs.append((c, outs[c])) } }
    return Array(pairs.prefix(64))
}

enum CSV {
    static func parse(_ text: String) -> [[String]] {
        var rows = [[String]](), row = [String](), field = "", inQ = false
        let ch = Array(text)
        var i = 0
        while i < ch.count {
            let c = ch[i]
            if inQ {
                if c == QUOTE {
                    if i + 1 < ch.count && ch[i + 1] == QUOTE { field.append(QUOTE); i += 1 } else { inQ = false }
                } else { field.append(c) }
            } else if c == QUOTE { inQ = true }
            else if c == "," { row.append(field); field = "" }
            else if c.unicodeScalars.contains(where: { $0.value == 10 || $0.value == 13 }) {
                row.append(field); field = ""; rows.append(row); row = []
            } else { field.append(c) }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }
    static func write(_ rows: [[String]]) -> String {
        let lines = rows.map { r -> String in
            r.map { f -> String in
                let special = f.contains(",") || f.contains(QUOTE) || f.unicodeScalars.contains(where: { $0.value == 10 || $0.value == 13 })
                return special ? QS + f.replacingOccurrences(of: QS, with: QS + QS) + QS : f
            }.joined(separator: ",")
        }
        return lines.joined(separator: NL) + NL
    }
}

struct Cue: Identifiable, Codable, Equatable {
    var id = UUID()
    var num = ""
    var name = ""
    var file = ""
    var tc = ""
    var fade = ""
    var loop = false
    var level = "0"
    var audioOut = "1-2"
    var with = false
    var follow = ""
    var mode = ""
    var notes = ""
    var midiIn = ""
    var midiOut = ""
    var oscOut = ""
    var chase = ""
    var group = false
    var fadeOut = ""
    var hold = ""
    var parent = ""

    static let audioExt: Set<String> = ["wav", "mp3", "aif", "aiff", "flac", "m4a", "aac", "caf"]
    static let columns = ["id", "name", "file", "tc", "fade", "loop", "level", "audio_out", "with", "follow", "mode",
                          "notes", "midi_in", "midi_out", "osc_out", "chase", "group", "fade_out", "hold"]
    var hasFile: Bool { !file.isEmpty }
    static let imageExt: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "heic", "gif", "bmp", "webp"]
    var isImage: Bool { Cue.imageExt.contains((file as NSString).pathExtension.lowercased()) }
    var isAudio: Bool { Cue.audioExt.contains((file as NSString).pathExtension.lowercased()) }
    var levelLin: Float { dbToLin(parseNum(level) ?? 0) }
    var row: [String] {
        [num, name, file, tc, fade, loop ? "1" : "0", level, audioOut, with ? "1" : "", follow, mode, notes, midiIn, midiOut, oscOut, chase, group ? "1" : "", fadeOut, hold]
    }
    init() {}
    init(header: [String], row: [String]) {
        func g(_ k: String) -> String {
            if let i = header.firstIndex(of: k), i < row.count { return row[i] }
            return ""
        }
        num = g("id"); name = g("name"); file = g("file"); tc = g("tc"); fade = g("fade"); loop = g("loop") == "1"
        level = g("level"); if level.isEmpty { level = "0" }
        audioOut = g("audio_out"); with = g("with") == "1"; follow = g("follow"); mode = g("mode"); notes = g("notes")
        midiIn = g("midi_in"); midiOut = g("midi_out"); oscOut = g("osc_out"); chase = g("chase"); group = g("group") == "1"; fadeOut = g("fade_out"); hold = g("hold")
    }
}

struct Shortcut: Codable, Equatable {
    var label = ""
    var type = ""
    var target = ""
    var value = ""
    var channel = ""
}

struct MidiBind: Codable, Equatable {
    var action: String
    var type: String      // note | cc
    var channel: Int      // 0 = any
    var number: Int
}

struct Settings: Codable, Equatable {
    var defaultFade = 1.0
    var goLock = 0.5
    var autoFollow = true
    var keyboard = true
    var fps = 25.0
    var followTC = false
    var tcSource = "ltc"
    var sendTC = false
    var tcChase = true
    var audioDevice = ""
    var ltcInDevice = ""
    var ltcInChannel = 1
    var ltcOutDevice = ""
    var ltcOutChannel = 1
    var pinkLevel = -20.0
    var oscInPort = 7000
    var oscOutHost = "127.0.0.1"
    var oscOutPort = 7001
    var oscSend = true
    var midiSend = true
    var midiIn = ""
    var midiOut = ""
    var avOffsetMs = 0.0
    var outputScreen = -1
    var outputRes = ""
    var redundancy = "off"
    var linkListen = 7100
    var peerHost = ""
    var peerPort = 7100
    var senseTone = false
    var senseChannel = 8
    var showFolder = ""
    var syncPort = 7110
    var receiveFolder = "~/Movies/KIMLAB Shows"
}

struct SavedState: Codable {
    var cues: [Cue] = []
    var shortcuts: [Shortcut] = []
    var midimap: [MidiBind] = []
    var settings = Settings()
}
