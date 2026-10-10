import Foundation
import AppKit
import SwiftUI

// MARK: small blocking TCP helper (used on background threads only)

final class Sock {
    let fd: Int32
    private var buf = [UInt8]()
    private var pos = 0

    init(fd: Int32) {
        self.fd = fd
        var tv = timeval(tv_sec: 20, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }
    deinit { Darwin.close(fd) }

    static func connect(host: String, port: Int) -> Sock? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = in_port_t(UInt16(clamping: port)).bigEndian
        guard inet_pton(AF_INET, host, &a.sin_addr) == 1 else { Darwin.close(fd); return nil }
        let r = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if r != 0 { Darwin.close(fd); return nil }
        return Sock(fd: fd)
    }
    func send(_ bytes: UnsafeRawBufferPointer) -> Bool {
        guard let p = bytes.baseAddress else { return true }
        var off = 0
        while off < bytes.count {
            let n = Darwin.send(fd, p + off, bytes.count - off, 0)
            if n <= 0 { return false }
            off += n
        }
        return true
    }
    func sendLine(_ obj: [String: Any]) -> Bool {
        guard var d = try? JSONSerialization.data(withJSONObject: obj) else { return false }
        d.append(10)
        return d.withUnsafeBytes { send($0) }
    }
    private func fill() -> Bool {
        var tmp = [UInt8](repeating: 0, count: 262144)
        let n = recv(fd, &tmp, tmp.count, 0)
        if n <= 0 { return false }
        buf = Array(tmp[0..<n])
        pos = 0
        return true
    }
    func readLine() -> [String: Any]? {
        var line = [UInt8]()
        while true {
            if pos >= buf.count { if !fill() { return nil } }
            let b = buf[pos]
            pos += 1
            if b == 10 { break }
            line.append(b)
            if line.count > 4_000_000 { return nil }
        }
        return (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
    }
    func readBytes(_ n: Int, _ sink: (UnsafeRawBufferPointer) -> Void) -> Bool {
        var left = n
        while left > 0 {
            if pos >= buf.count { if !fill() { return false } }
            let take = min(left, buf.count - pos)
            buf[pos..<(pos + take)].withUnsafeBytes { sink($0) }
            pos += take
            left -= take
        }
        return true
    }
}

/// Sends a show folder to the backup. Only files that are new or changed (size or date) are copied.
enum SyncClient {
    /// show.csv, the shortcuts file and everything in media/, as (relative path, size, modification time)
    static func files(in folder: URL) -> [(String, Int, Double)] {
        let fm = FileManager.default
        var out = [(String, Int, Double)]()
        func add(_ rel: String) {
            let p = folder.path + "/" + rel
            guard let a = try? fm.attributesOfItem(atPath: p), (a[.type] as? FileAttributeType) == .typeRegular else { return }
            let size = (a[.size] as? NSNumber)?.intValue ?? 0
            let m = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            out.append((rel, size, m))
        }
        add("show.csv")
        add("show_shortcuts.csv")
        for n in ((try? fm.contentsOfDirectory(atPath: folder.path + "/media")) ?? []).sorted() {
            if n.hasPrefix(".") || n.hasSuffix(".part") { continue }
            add("media/" + n)
        }
        return out
    }

    static func push(folder: URL, name: String, host: String, port: Int, status: (String) -> Void) -> String {
        status("Connecting to the backup")
        guard let s = Sock.connect(host: host, port: port) else { return "Could not reach the backup on port " + String(port) }
        guard s.sendLine(["op": "list", "show": name]), let reply = s.readLine(), let remote = reply["files"] as? [String: Any] else {
            return "The backup did not answer"
        }
        let local = files(in: folder)
        var need = [(String, Int, Double)]()
        for f in local {
            if f.0.hasPrefix("media/"), let r = remote[f.0] as? [NSNumber], r.count == 2, r[0].intValue == f.1, abs(r[1].doubleValue - f.2) < 2 { continue }
            need.append(f)
        }
        var sent = 0
        for (i, f) in need.enumerated() {
            status("Sending " + String(i + 1) + "/" + String(need.count) + "  " + (f.0 as NSString).lastPathComponent)
            guard let fh = FileHandle(forReadingAtPath: folder.path + "/" + f.0) else { continue }
            defer { fh.closeFile() }
            guard s.sendLine(["op": "put", "show": name, "path": f.0, "size": f.1, "mtime": f.2]) else { return "Connection to the backup lost" }
            var left = f.1
            while left > 0 {
                let d = fh.readData(ofLength: min(left, 1 << 20))
                if d.isEmpty { break }
                if !d.withUnsafeBytes({ s.send($0) }) { return "Connection lost while sending " + f.0 }
                left -= d.count
            }
            if left > 0 { return "File changed while sending: " + f.0 }
            guard let r = s.readLine(), (r["ok"] as? Bool) == true else { return "The backup could not store " + f.0 }
            sent += 1
        }
        guard s.sendLine(["op": "done", "show": name]), let r = s.readLine(), (r["ok"] as? Bool) == true else { return "The backup did not confirm" }
        return "Sent to backup: " + String(sent) + " updated, " + String(local.count - need.count) + " already there"
    }
}

/// Runs on the backup: receives show folders into the receive folder. Never deletes anything there.
final class SyncServer {
    private var lfd: Int32 = -1
    private var base = ""
    var onDone: ((URL) -> Void)? = nil
    var onStatus: ((String) -> Void)? = nil

    func start(port: Int, base b: String) -> Bool {
        stop()
        let l = socket(AF_INET, SOCK_STREAM, 0)
        guard l >= 0 else { return false }
        var yes: Int32 = 1
        setsockopt(l, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = in_port_t(UInt16(clamping: port)).bigEndian
        a.sin_addr.s_addr = 0
        let r = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(l, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard r == 0, listen(l, 4) == 0 else { Darwin.close(l); return false }
        lfd = l
        base = b
        let t = Thread { [self] in
            while true {
                let c = accept(l, nil, nil)
                if c < 0 { break }
                let s = Sock(fd: c)
                Thread { [self] in self.serve(s) }.start()
            }
        }
        t.start()
        return true
    }
    func stop() {
        if lfd >= 0 { Darwin.close(lfd); lfd = -1 }
    }
    private func safeName(_ n: String) -> Bool {
        !n.isEmpty && !n.contains("/") && !n.contains("..") && !n.hasPrefix(".")
    }
    private func safePath(_ rel: String) -> Bool {
        let parts = rel.split(separator: "/", omittingEmptySubsequences: false).map { String($0) }
        if parts.isEmpty || parts.count > 2 { return false }
        for p in parts where !safeName(p) { return false }
        return parts.count == 1 || parts[0] == "media"
    }
    private func serve(_ s: Sock) {
        let fm = FileManager.default
        while let m = s.readLine() {
            guard let op = m["op"] as? String, let show = m["show"] as? String, safeName(show) else { _ = s.sendLine(["ok": false]); return }
            let dir = base + "/" + show
            if op == "list" {
                var out = [String: [Double]]()
                for f in SyncClient.files(in: URL(fileURLWithPath: dir)) { out[f.0] = [Double(f.1), f.2] }
                _ = s.sendLine(["files": out])
            } else if op == "put" {
                guard let rel = m["path"] as? String, safePath(rel), let size = (m["size"] as? NSNumber)?.intValue, size >= 0,
                      let mtime = (m["mtime"] as? NSNumber)?.doubleValue else { _ = s.sendLine(["ok": false]); return }
                let dst = dir + "/" + rel
                let tmp = dst + ".part"
                try? fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                fm.createFile(atPath: tmp, contents: nil)
                guard let fh = FileHandle(forWritingAtPath: tmp) else { _ = s.sendLine(["ok": false]); return }
                onStatus?("Receiving " + (rel as NSString).lastPathComponent)
                let ok = s.readBytes(size) { fh.write(Data($0)) }
                fh.closeFile()
                if !ok { try? fm.removeItem(atPath: tmp); return }
                var stored = false
                do {
                    if fm.fileExists(atPath: dst) { try fm.removeItem(atPath: dst) }
                    try fm.moveItem(atPath: tmp, toPath: dst)
                    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)], ofItemAtPath: dst)
                    stored = true
                } catch { stored = false }
                _ = s.sendLine(["ok": stored])
            } else if op == "done" {
                _ = s.sendLine(["ok": true])
                onDone?(URL(fileURLWithPath: dir + "/show.csv"))
            } else {
                _ = s.sendLine(["ok": false])
                return
            }
        }
    }
}

// MARK: show folder (all media next to the showfile, paths relative to it)

extension Show {
    func writeShow(to url: URL) -> Bool {
        let base = url.deletingLastPathComponent().path + "/"
        var rows = [Cue.columns]
        for c in cues {
            var r = c.row
            if c.file.hasPrefix(base) { r[2] = String(c.file.dropFirst(base.count)) }
            rows.append(r)
        }
        do { try CSV.write(rows).write(to: url, atomically: true, encoding: .utf8) } catch { return false }
        var sc = [["key", "label", "type", "target", "value", "channel"]]
        for (i, s) in shortcuts.enumerated() { sc.append(["F" + String(i + 1), s.label, s.type, s.target, s.value, s.channel]) }
        try? CSV.write(sc).write(toFile: url.deletingPathExtension().path + "_shortcuts.csv", atomically: true, encoding: .utf8)
        return true
    }

    func readShow(from url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let rows = CSV.parse(text)
        guard let header = rows.first, header.contains("name"), header.contains("file") else { return false }
        let base = url.deletingLastPathComponent().path + "/"
        stopAll(fade: 0)
        cues = rows.dropFirst().map { r -> Cue in
            var c = Cue(header: header, row: r)
            if !c.file.isEmpty && !c.file.hasPrefix("/") { c.file = base + c.file }
            return c
        }
        normalizeCues()
        standby = 0
        selected = nil
        if let t = try? String(contentsOfFile: url.deletingPathExtension().path + "_shortcuts.csv", encoding: .utf8) {
            let sr = CSV.parse(t)
            if let h = sr.first {
                for (i, r) in sr.dropFirst().enumerated() where i < 8 {
                    func g(_ k: String) -> String {
                        if let x = h.firstIndex(of: k), x < r.count { return r[x] }
                        return ""
                    }
                    shortcuts[i] = Shortcut(label: g("label"), type: g("type"), target: g("target"), value: g("value"), channel: g("channel"))
                }
            }
        }
        lengths = [:]
        lengthPending = []
        preloadStandby()
        return true
    }

    func saveShowfile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "show.csv"
        if !settings.showFolder.isEmpty { panel.directoryURL = URL(fileURLWithPath: settings.showFolder) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        message = writeShow(to: url) ? "Saved " + url.lastPathComponent : "Could not save the showfile"
    }

    func loadShowfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard readShow(from: url) else { message = "That is not a KIMLAB showfile"; return }
        let dir = url.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("media").path) { settings.showFolder = dir.path }
        message = "Loaded " + url.lastPathComponent
    }

    func sameFile(_ a: String, _ b: String) -> Bool {
        let fm = FileManager.default
        guard let x = try? fm.attributesOfItem(atPath: a), let y = try? fm.attributesOfItem(atPath: b) else { return false }
        let sx = (x[.size] as? NSNumber)?.intValue ?? -1, sy = (y[.size] as? NSNumber)?.intValue ?? -2
        let mx = (x[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, my = (y[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 10
        return sx == sy && abs(mx - my) < 2
    }

    /// COLLECT: asks for the show folder, then copies every cue's media into it.
    func collectShow() {
        let panel = NSSavePanel()
        panel.title = "Show folder"
        panel.message = "Name the show folder. All media is copied into it and the cue list will play from there."
        panel.prompt = "Collect"
        panel.nameFieldStringValue = settings.showFolder.isEmpty ? "My show" : (settings.showFolder as NSString).lastPathComponent
        if !settings.showFolder.isEmpty { panel.directoryURL = URL(fileURLWithPath: settings.showFolder).deletingLastPathComponent() }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        collect(into: url, then: nil)
    }

    /// Copies media that is not in <folder>/media yet (or changed), points the cues at the copies, writes show.csv.
    /// The original files are left where they are.
    func collect(into folder: URL, then done: ((Bool) -> Void)?) {
        if syncBusy { message = "Still busy with the previous copy"; done?(false); return }
        let fm = FileManager.default
        let media = folder.appendingPathComponent("media")
        do { try fm.createDirectory(at: media, withIntermediateDirectories: true) } catch {
            message = "Could not create the show folder"
            done?(false)
            return
        }
        let prefix = media.path + "/"
        var mapped = [String: String]()
        var taken = [String: String]()
        var plan = [(String, String)]()
        var missing = 0
        for c in cues where c.hasFile && c.file.hasPrefix(prefix) {
            mapped[c.file] = c.file
            taken[(c.file as NSString).lastPathComponent] = c.file
        }
        for c in cues where c.hasFile && mapped[c.file] == nil {
            let src = c.file
            guard fm.fileExists(atPath: src) else { missing += 1; mapped[src] = src; continue }
            let original = (src as NSString).lastPathComponent
            let stem = (original as NSString).deletingPathExtension, ext = (original as NSString).pathExtension
            var name = original
            var k = 2
            while let other = taken[name], other != src {
                name = stem + " " + String(k) + (ext.isEmpty ? "" : "." + ext)
                k += 1
            }
            taken[name] = src
            mapped[src] = prefix + name
            if !sameFile(src, prefix + name) { plan.append((src, prefix + name)) }
        }
        syncBusy = true
        let total = plan.count
        DispatchQueue.global(qos: .userInitiated).async {
            var failed = 0
            for (n, p) in plan.enumerated() {
                DispatchQueue.main.async { self.syncStatus = "Copying " + String(n + 1) + "/" + String(total) + "  " + (p.0 as NSString).lastPathComponent }
                let tmp = p.1 + ".part"
                try? fm.removeItem(atPath: tmp)
                do {
                    try fm.copyItem(atPath: p.0, toPath: tmp)
                    if fm.fileExists(atPath: p.1) { try fm.removeItem(atPath: p.1) }
                    try fm.moveItem(atPath: tmp, toPath: p.1)
                } catch { failed += 1 }
            }
            DispatchQueue.main.async {
                self.syncBusy = false
                self.syncStatus = ""
                for i in 0..<self.cues.count {
                    if let d = mapped[self.cues[i].file], d != self.cues[i].file, fm.fileExists(atPath: d) { self.cues[i].file = d }
                }
                let ok = self.writeShow(to: folder.appendingPathComponent("show.csv"))
                self.settings.showFolder = folder.path
                self.lengths = [:]
                self.lengthPending = []
                var text = "Show folder ready: " + String(total - failed) + " copied"
                if missing > 0 { text += ", " + String(missing) + " missing" }
                if failed > 0 { text += ", " + String(failed) + " failed" }
                self.message = ok ? text : "Could not write show.csv in the show folder"
                done?(ok && failed == 0)
            }
        }
    }

    // MARK: send to backup

    func sendShow() {
        if syncBusy { return }
        guard !settings.showFolder.isEmpty, FileManager.default.fileExists(atPath: settings.showFolder) else {
            message = "Press COLLECT first to make a show folder"
            return
        }
        guard isMain, peerAlive else { message = "Set REDUNDANCY to MAIN and connect the backup first"; return }
        let folder = URL(fileURLWithPath: settings.showFolder)
        collect(into: folder) { [weak self] ok in
            if ok { self?.pushShow(folder) } else { self?.message = "Not sent: the show folder is not complete" }
        }
    }

    func pushShow(_ folder: URL) {
        syncBusy = true
        let host = settings.peerHost, port = settings.syncPort, name = folder.lastPathComponent
        DispatchQueue.global(qos: .userInitiated).async {
            let result = SyncClient.push(folder: folder, name: name, host: host, port: port) { s in
                DispatchQueue.main.async { self.syncStatus = s }
            }
            DispatchQueue.main.async {
                self.syncBusy = false
                self.syncStatus = ""
                self.message = result
            }
        }
    }

    /// Backup side: listen for shows while in BACKUP mode.
    func configureSync() {
        syncServer.stop()
        guard isBackup else { return }
        let base = (settings.receiveFolder as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        syncServer.onStatus = { [weak self] s in DispatchQueue.main.async { self?.syncStatus = s } }
        syncServer.onDone = { [weak self] url in
            DispatchQueue.main.async {
                self?.pendingShow = url
                self?.syncStatus = ""
            }
        }
        if !syncServer.start(port: settings.syncPort, base: base) { message = "Sync port " + String(settings.syncPort) + " is in use" }
    }

    /// A received show is loaded as soon as nothing is playing.
    func syncTick() {
        guard let u = pendingShow, playing.isEmpty else { return }
        pendingShow = nil
        if readShow(from: u) {
            settings.showFolder = u.deletingLastPathComponent().path
            message = "Show received from the main: " + String(cues.count) + " cues"
        } else {
            message = "A show arrived but could not be read"
        }
    }
}

struct SyncRow: View {
    @EnvironmentObject var show: Show
    var body: some View {
        let folder = show.settings.showFolder.isEmpty ? "no show folder yet" : (show.settings.showFolder as NSString).lastPathComponent
        HStack(spacing: 6) {
            PButton(title: "COLLECT", height: 22) { show.collectShow() }.frame(width: 74)
            PButton(title: "SEND TO BACKUP", height: 22) { show.sendShow() }.frame(width: 116)
            Text(show.syncStatus.isEmpty ? folder : show.syncStatus).font(arial(10)).foregroundColor(P.muted).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(P.panel).cornerRadius(5)
    }
}
