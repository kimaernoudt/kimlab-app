import Foundation
import CoreMIDI

/// Minimal OSC over UDP (int, float, string, bool; bundles on receive).
final class OSC {
    private var fd: Int32 = -1
    private var sfd: Int32 = -1
    private var src: DispatchSourceRead? = nil
    var onMessage: ((String, [Any]) -> Void)? = nil

    func listen(port: Int) -> Bool {
        shutdown()
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { return false }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(clamping: port)).bigEndian
        addr.sin_addr.s_addr = 0
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard r == 0 else { Darwin.close(s); return false }
        fd = s
        let ds = DispatchSource.makeReadSource(fileDescriptor: s, queue: .main)
        ds.setEventHandler { [weak self] in self?.read() }
        ds.resume()
        src = ds
        return true
    }
    func shutdown() {
        src?.cancel()
        src = nil
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }
    private func read() {
        var buf = [UInt8](repeating: 0, count: 8192)
        let n = recv(fd, &buf, buf.count, 0)
        if n > 0 { for m in OSC.decode(Array(buf[0..<n])) { onMessage?(m.0, m.1) } }
    }
    func send(_ addr: String, _ args: [Any], host: String, port: Int) {
        if sfd < 0 { sfd = socket(AF_INET, SOCK_DGRAM, 0) }
        guard sfd >= 0 else { return }
        var to = sockaddr_in()
        to.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        to.sin_family = sa_family_t(AF_INET)
        to.sin_port = in_port_t(UInt16(clamping: port)).bigEndian
        guard inet_pton(AF_INET, host, &to.sin_addr) == 1 else { return }
        let d = OSC.encode(addr, args)
        let s = sfd
        _ = withUnsafePointer(to: &to) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(s, d, d.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }

    static func pad(_ b: [UInt8]) -> [UInt8] {
        var o = b
        o.append(0)
        while o.count % 4 != 0 { o.append(0) }
        return o
    }
    static func encode(_ addr: String, _ args: [Any]) -> [UInt8] {
        var tags = ","
        var body = [UInt8]()
        func be(_ v: UInt32) { body += [UInt8(v >> 24), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)] }
        for a in args {
            if let b = a as? Bool { tags += b ? "T" : "F" }
            else if let i = a as? Int { tags += "i"; be(UInt32(bitPattern: Int32(truncatingIfNeeded: i))) }
            else if let f = a as? Double { tags += "f"; be(Float(f).bitPattern) }
            else if let f = a as? Float { tags += "f"; be(f.bitPattern) }
            else if let s = a as? String { tags += "s"; body += pad(Array(s.utf8)) }
        }
        return pad(Array(addr.utf8)) + pad(Array(tags.utf8)) + body
    }
    static func decode(_ d: [UInt8]) -> [(String, [Any])] {
        var out = [(String, [Any])]()
        func be32(_ p: Int) -> UInt32 { UInt32(d[p]) << 24 | UInt32(d[p + 1]) << 16 | UInt32(d[p + 2]) << 8 | UInt32(d[p + 3]) }
        func str(_ p: inout Int, _ end: Int) -> String? {
            var e = p
            while e < end && d[e] != 0 { e += 1 }
            if e >= end { return nil }
            let s = String(decoding: d[p..<e], as: UTF8.self)
            p = (e + 4) & ~3
            return s
        }
        func msg(_ start: Int, _ end: Int) {
            var p = start
            guard let addr = str(&p, end) else { return }
            if addr == "#bundle" {
                p += 8
                while p + 4 <= end {
                    let n = Int(be32(p))
                    p += 4
                    if n <= 0 || p + n > end { break }
                    msg(p, p + n)
                    p += n
                }
                return
            }
            var args = [Any]()
            if p < end, let tags = str(&p, end) {
                for t in tags.dropFirst() {
                    if t == "i" { if p + 4 <= end { args.append(Int(Int32(bitPattern: be32(p)))); p += 4 } }
                    else if t == "f" { if p + 4 <= end { args.append(Double(Float(bitPattern: be32(p)))); p += 4 } }
                    else if t == "s" { if let s = str(&p, end) { args.append(s) } }
                    else if t == "T" { args.append(true) }
                    else if t == "F" { args.append(false) }
                }
            }
            out.append((addr, args))
        }
        msg(0, d.count)
        return out
    }
}

/// CoreMIDI in/out on one selected device each.
final class MIDI {
    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private var src: MIDIEndpointRef = 0
    private var dst: MIDIEndpointRef = 0
    var onMessage: ((UInt8, UInt8, UInt8) -> Void)? = nil

    init() {
        MIDIClientCreateWithBlock("KIMLAB" as CFString, &client, nil)
        MIDIInputPortCreateWithBlock(client, "in" as CFString, &inPort) { [weak self] list, _ in self?.handle(list) }
        MIDIOutputPortCreate(client, "out" as CFString, &outPort)
    }
    static func name(_ ep: MIDIEndpointRef) -> String {
        var s: Unmanaged<CFString>? = nil
        MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &s)
        if let u = s { return u.takeRetainedValue() as String }
        return "?"
    }
    static func sources() -> [String] { (0..<MIDIGetNumberOfSources()).map { name(MIDIGetSource($0)) } }
    static func destinations() -> [String] { (0..<MIDIGetNumberOfDestinations()).map { name(MIDIGetDestination($0)) } }

    func selectInput(_ n: String) {
        if src != 0 { MIDIPortDisconnectSource(inPort, src); src = 0 }
        for i in 0..<MIDIGetNumberOfSources() where MIDI.name(MIDIGetSource(i)) == n {
            src = MIDIGetSource(i)
            MIDIPortConnectSource(inPort, src, nil)
            break
        }
    }
    func selectOutput(_ n: String) {
        dst = 0
        for i in 0..<MIDIGetNumberOfDestinations() where MIDI.name(MIDIGetDestination(i)) == n {
            dst = MIDIGetDestination(i)
            break
        }
    }
    func send(_ bytes: [UInt8]) {
        guard dst != 0, !bytes.isEmpty, bytes.count <= 16 else { return }
        var pl = MIDIPacketList()
        let port = outPort, dest = dst
        withUnsafeMutablePointer(to: &pl) { p in
            let pkt = MIDIPacketListInit(p)
            _ = MIDIPacketListAdd(p, MemoryLayout<MIDIPacketList>.size, pkt, 0, bytes.count, bytes)
            MIDISend(port, dest, p)
        }
    }
    private func handle(_ list: UnsafePointer<MIDIPacketList>) {
        var msgs = [(UInt8, UInt8, UInt8)]()
        var p = UnsafeRawPointer(list) + 4
        for _ in 0..<Int(list.pointee.numPackets) {
            let len = Int(p.loadUnaligned(fromByteOffset: 8, as: UInt16.self))
            let data = (p + 10).assumingMemoryBound(to: UInt8.self)
            var i = 0
            while i < len {
                let st = data[i]
                if st < 0x80 || st >= 0xF0 { i += 1; continue }
                let need = (st & 0xF0 == 0xC0 || st & 0xF0 == 0xD0) ? 1 : 2
                if i + need < len { msgs.append((st, data[i + 1], need == 2 ? data[i + 2] : 0)) }
                i += need + 1
            }
            p = UnsafeRawPointer(bitPattern: (UInt(bitPattern: p + 10 + len) + 3) & ~UInt(3))!
        }
        if msgs.isEmpty { return }
        DispatchQueue.main.async { [weak self] in
            for m in msgs { self?.onMessage?(m.0, m.1, m.2) }
        }
    }
}

func localIP() -> String {
    var result = "127.0.0.1"
    var ifa: UnsafeMutablePointer<ifaddrs>? = nil
    guard getifaddrs(&ifa) == 0 else { return result }
    var p = ifa
    while let a = p {
        let name = String(cString: a.pointee.ifa_name)
        if let addr = a.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), name.hasPrefix("en") {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result = String(cString: host)
                break
            }
        }
        p = a.pointee.ifa_next
    }
    freeifaddrs(ifa)
    return result
}
