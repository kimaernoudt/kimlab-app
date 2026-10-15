import AppKit
import CoreText

/// One line on the countdown screen, already formatted (so an unchanged screen is not redrawn).
struct CountLine: Equatable {
    var label = ""
    var time = ""
    var frac = -1       // progress 0...1000, -1 = no bar (loop, or no end)
    var tone = 0        // 0 white, 1 amber (30 s or less), 2 red (10 s or less), 3 grey (no end)
}

/// Everything on the countdown screen. To add something to the screen: add a field here, fill it in
/// Show.countFrame(), and draw it in its own function called from CountdownCanvas.draw(). The screen is
/// only redrawn (and the same picture sent over NDI) when this value changes.
struct CountFrame: Equatable {
    var lines: [CountLine] = []
    var next = ""
    var clock = ""
}

/// Countdown screen: the time left on the running cues, in its own window (any screen) and optionally over NDI.
/// Drawn into one 1920 x 1080 bitmap off the main thread; the window shows that bitmap and NDI sends the same pixels.
final class Countdown {
    let layer = CALayer()
    var screenIndex = -1
    var onClose: (() -> Void)? = nil
    private var window: CountdownWindow? = nil
    private let q = DispatchQueue(label: "kimlab.countdown", qos: .userInitiated)
    private let canvas = CountdownCanvas()      // only used on q
    private let ndi = NDISender()               // only used on q
    private var last: CountFrame? = nil
    private var drawn = false                   // only used on q
    private var busy = false
    private(set) var ndiOn = false

    init() {
        layer.backgroundColor = NSColor.black.cgColor
        layer.contentsGravity = .resizeAspect
    }

    // MARK: window

    func openWindow() {
        if let w = window { w.orderFront(nil); return }
        let screens = NSScreen.screens
        let w: CountdownWindow
        if screenIndex >= 0 && screenIndex < screens.count {
            let s = screens[screenIndex]
            w = CountdownWindow(contentRect: s.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
            w.setFrame(s.frame, display: true)
        } else {
            w = CountdownWindow(contentRect: NSRect(x: 120, y: 120, width: 960, height: 540),
                                styleMask: [.titled, .resizable, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "KIMLAB countdown"
            w.collectionBehavior = [.fullScreenPrimary]
            _ = w.setFrameAutosaveName("KIMLAB countdown")
        }
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.contentView = LayerHostView(hosted: layer)
        w.onHide = { [weak self] in self?.onClose?() }
        w.orderFront(nil)
        window = w
        last = nil      // draw the first frame right away
    }
    func moveWindow(to index: Int) {
        let wasOpen = windowOpen
        screenIndex = index
        window?.onHide = nil
        window?.orderOut(nil)
        window = nil
        layer.removeFromSuperlayer()
        if wasOpen { openWindow() }
    }
    func closeWindow() { window?.orderOut(nil) }
    var windowOpen: Bool { window?.isVisible ?? false }
    func focus() { window?.makeKey() }

    // MARK: NDI

    /// Starts or stops the NDI source. Returns a message when NDI cannot be started.
    func setNDI(_ on: Bool, name: String) -> String? {
        if on == ndiOn { return nil }
        if on {
            guard NDISender.available else {
                return "NDI is not installed: install NDI Tools or the NDI SDK (ndi.video), then turn NDI on again"
            }
            ndiOn = true
            last = nil
            q.async { [ndi] in ndi.start(name: name) }
        } else {
            ndiOn = false
            q.async { [ndi] in ndi.stop() }
        }
        return nil
    }

    // MARK: frames (called from the 30 Hz tick)

    func update(_ f: CountFrame) {
        let show = windowOpen
        guard show || ndiOn else { return }
        let changed = f != last
        if busy || (!changed && !ndiOn) { return }
        busy = true
        last = f
        let send = ndiOn
        q.async { [weak self] in
            guard let s = self else { return }
            var img: CGImage? = nil
            if changed || !s.drawn {
                s.canvas.draw(f)
                s.drawn = true
                if show { img = s.canvas.image() }
            }
            if send { s.ndi.send(s.canvas) }
            DispatchQueue.main.async {
                if let i = img {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    s.layer.contents = i
                    CATransaction.commit()
                }
                s.busy = false
            }
        }
    }
}

/// Countdown window: Esc or a double-click closes it when it fills a screen; in a normal window a double-click
/// toggles full screen and Esc leaves full screen.
final class CountdownWindow: NSWindow {
    var onHide: (() -> Void)? = nil
    var fillsScreen: Bool { !styleMask.contains(.titled) }
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 53 else { super.keyDown(with: event); return }
        if fillsScreen { orderOut(nil) } else if styleMask.contains(.fullScreen) { toggleFullScreen(nil) }
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { if fillsScreen { orderOut(nil) } else { toggleFullScreen(nil) } }
        else { super.mouseDown(with: event) }
    }
    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        onHide?()
    }
    override func close() {
        super.close()
        onHide?()
    }
}

/// The 1920 x 1080 BGRA bitmap the countdown is drawn into (the pixel layout NDI wants).
final class CountdownCanvas {
    static let w = 1920, h = 1080
    let ctx: CGContext
    init() {
        ctx = CGContext(data: nil, width: CountdownCanvas.w, height: CountdownCanvas.h, bitsPerComponent: 8,
                        bytesPerRow: CountdownCanvas.w * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    }
    var data: UnsafeMutableRawPointer? { ctx.data }
    var stride: Int { ctx.bytesPerRow }
    func image() -> CGImage? { ctx.makeImage() }

    static let white = CGColor(gray: 1, alpha: 1)
    static let grey = CGColor(gray: 0.55, alpha: 1)
    static let dim = CGColor(gray: 0.3, alpha: 1)
    static let amber = CGColor(red: 1, green: 0.72, blue: 0.1, alpha: 1)
    static let red = CGColor(red: 1, green: 0.22, blue: 0.2, alpha: 1)
    static func color(_ tone: Int) -> CGColor { [white, amber, red, grey][max(0, min(3, tone))] }

    /// The screen, top to bottom. Each part draws in its own band of the 1920 x 1080 picture (y = 0 is the bottom).
    func draw(_ f: CountFrame) {
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: CGFloat(CountdownCanvas.h)))
        drawTopRow(f)           // y 960...1080
        drawMain(f)             // y 320...960
        drawOthers(f)           // y 0...300
    }
    private var W: CGFloat { CGFloat(CountdownCanvas.w) }

    /// Time of day left, standby cue right.
    private func drawTopRow(_ f: CountFrame) {
        text(f.clock, size: 48, color: CountdownCanvas.grey, x: 80, y: 1000, align: 0, maxW: 400, mono: true)
        if !f.next.isEmpty {
            text("NEXT  " + f.next, size: 48, color: CountdownCanvas.grey, x: W - 80, y: 1000, align: 2, maxW: 1300)
        }
    }

    /// The cue started last: name, big time left and progress bar.
    private func drawMain(_ f: CountFrame) {
        guard let main = f.lines.first else {
            text("--:--", size: 400, color: CountdownCanvas.dim, x: W / 2, y: 420, align: 1, maxW: 1760, mono: true)
            return
        }
        text(main.label, size: 76, color: CountdownCanvas.white, x: W / 2, y: 850, align: 1, maxW: 1760, bold: true)
        text(main.time, size: 400, color: CountdownCanvas.color(main.tone), x: W / 2, y: 420, align: 1, maxW: 1760, mono: true)
        if main.frac >= 0 {
            ctx.setFillColor(CGColor(gray: 0.18, alpha: 1))
            ctx.fill(CGRect(x: 120, y: 330, width: W - 240, height: 22))
            ctx.setFillColor(CountdownCanvas.color(main.tone))
            ctx.fill(CGRect(x: 120, y: 330, width: (W - 240) * CGFloat(main.frac) / 1000, height: 22))
        }
    }

    /// Up to three other running cues, smaller.
    private func drawOthers(_ f: CountFrame) {
        var y: CGFloat = 240
        for l in f.lines.dropFirst().prefix(3) {
            text(l.label, size: 56, color: CountdownCanvas.grey, x: 120, y: y, align: 0, maxW: 1300)
            text(l.time, size: 56, color: CountdownCanvas.color(l.tone), x: W - 120, y: y, align: 2, maxW: 400, mono: true)
            y -= 80
        }
    }

    /// align: 0 left, 1 centre, 2 right of x; y is the baseline. Long names are cut with an ellipsis, long times shrunk.
    private func text(_ s: String, size: CGFloat, color: CGColor, x: CGFloat, y: CGFloat, align: Int, maxW: CGFloat,
                      bold: Bool = false, mono: Bool = false) {
        if s.isEmpty { return }
        func line(_ str: String, _ sz: CGFloat) -> CTLine {
            let font = mono ? NSFont.monospacedDigitSystemFont(ofSize: sz, weight: .bold)
                                    : NSFont.systemFont(ofSize: sz, weight: bold ? .bold : .regular)
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
            return CTLineCreateWithAttributedString(NSAttributedString(string: str, attributes: attrs))
        }
        var l = line(s, size)
        var width = CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil))
        if width > maxW {
            if mono { l = line(s, size * maxW / width) }
            else if let t = CTLineCreateTruncatedLine(l, Double(maxW), .end, line("\u{2026}", size)) { l = t }
            width = CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil))
        }
        let x0 = align == 0 ? x : (align == 1 ? x - width / 2 : x - width)
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: x0, y: y)
        CTLineDraw(l, ctx)
    }
}

/// NDI video sender. The NDI library is loaded at run time, so KIMLAB builds and runs without it;
/// NDI only works on a Mac with NDI Tools or the NDI SDK installed.
final class NDISender {
    private typealias InitFn = @convention(c) () -> Bool
    private typealias CreateFn = @convention(c) (UnsafeRawPointer?) -> OpaquePointer?
    private typealias SendFn = @convention(c) (OpaquePointer?, UnsafeRawPointer?) -> Void
    private typealias DestroyFn = @convention(c) (OpaquePointer?) -> Void

    private struct Lib {
        let initialize: InitFn
        let create: CreateFn
        let send: SendFn
        let destroy: DestroyFn
    }
    private static let lib: Lib? = {
        var paths = [String]()
        let env = ProcessInfo.processInfo.environment
        for k in ["NDI_RUNTIME_DIR_V6", "NDI_RUNTIME_DIR_V5", "NDI_RUNTIME_DIR_V4"] {
            if let d = env[k], !d.isEmpty { paths.append((d as NSString).appendingPathComponent("libndi.dylib")) }
        }
        if let fw = Bundle.main.privateFrameworksPath { paths.append((fw as NSString).appendingPathComponent("libndi.dylib")) }
        paths.append(("~/Library/Application Support/KIMLAB/libndi.dylib" as NSString).expandingTildeInPath)
        paths += ["/Library/NDI SDK for Apple/lib/macOS/libndi.dylib",
                  "/Library/NDI SDK for Apple/lib/macOS/libndi_advanced.dylib",
                  "/usr/local/lib/libndi.dylib",
                  "/usr/local/lib/libndi.6.dylib",
                  "/usr/local/lib/libndi.5.dylib",
                  "/usr/local/lib/libndi.4.dylib",
                  "/opt/homebrew/lib/libndi.dylib"]
        for p in paths where FileManager.default.fileExists(atPath: p) {
            guard let h = dlopen(p, RTLD_NOW | RTLD_LOCAL) else { continue }
            guard let i = dlsym(h, "NDIlib_initialize"), let c = dlsym(h, "NDIlib_send_create"),
                  let s = dlsym(h, "NDIlib_send_send_video_v2"), let d = dlsym(h, "NDIlib_send_destroy") else { dlclose(h); continue }
            let lib = Lib(initialize: unsafeBitCast(i, to: InitFn.self), create: unsafeBitCast(c, to: CreateFn.self),
                          send: unsafeBitCast(s, to: SendFn.self), destroy: unsafeBitCast(d, to: DestroyFn.self))
            if !lib.initialize() { dlclose(h); continue }
            return lib
        }
        return nil
    }()
    static var available: Bool { lib != nil }

    private var instance: OpaquePointer? = nil
    private let frame = UnsafeMutableRawPointer.allocate(byteCount: 72, alignment: 8)
    deinit { stop(); frame.deallocate() }

    func start(name: String) {
        guard instance == nil, let lib = NDISender.lib else { return }
        // NDIlib_send_create_t { const char* p_ndi_name; const char* p_groups; bool clock_video; bool clock_audio; }
        let create = UnsafeMutableRawPointer.allocate(byteCount: 24, alignment: 8)
        create.initializeMemory(as: UInt8.self, repeating: 0, count: 24)
        let cname = strdup(name)
        create.storeBytes(of: UnsafePointer(cname), toByteOffset: 0, as: UnsafePointer<CChar>?.self)
        instance = lib.create(UnsafeRawPointer(create))
        free(cname)
        create.deallocate()
    }
    func stop() {
        guard let i = instance, let lib = NDISender.lib else { return }
        lib.destroy(i)
        instance = nil
    }
    /// Sends the canvas as one progressive 30 fps BGRA frame (NDIlib_video_frame_v2_t, 72 bytes on 64-bit).
    func send(_ c: CountdownCanvas) {
        guard let i = instance, let lib = NDISender.lib, let data = c.data else { return }
        func fourCC(_ s: String) -> UInt32 { s.utf8.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << (8 * UInt32($1.offset))) } }
        frame.initializeMemory(as: UInt8.self, repeating: 0, count: 72)
        frame.storeBytes(of: Int32(CountdownCanvas.w), toByteOffset: 0, as: Int32.self)     // xres
        frame.storeBytes(of: Int32(CountdownCanvas.h), toByteOffset: 4, as: Int32.self)     // yres
        frame.storeBytes(of: fourCC("BGRA"), toByteOffset: 8, as: UInt32.self)              // FourCC
        frame.storeBytes(of: Int32(30), toByteOffset: 12, as: Int32.self)                   // frame_rate_N
        frame.storeBytes(of: Int32(1), toByteOffset: 16, as: Int32.self)                    // frame_rate_D
        frame.storeBytes(of: Float(16.0 / 9.0), toByteOffset: 20, as: Float.self)           // picture_aspect_ratio
        frame.storeBytes(of: Int32(1), toByteOffset: 24, as: Int32.self)                    // progressive
        frame.storeBytes(of: Int64.max, toByteOffset: 32, as: Int64.self)                   // timecode: synthesize
        frame.storeBytes(of: data, toByteOffset: 40, as: UnsafeMutableRawPointer.self)      // p_data
        frame.storeBytes(of: Int32(c.stride), toByteOffset: 48, as: Int32.self)             // line_stride_in_bytes
        lib.send(i, UnsafeRawPointer(frame))
    }
}

// MARK: show side

extension Show {
    func setupCountdown() {
        countdown.onClose = { [weak self] in
            DispatchQueue.main.async {
                guard let s = self else { return }
                s.countdownOpen = s.countdown.windowOpen
                s.settings.countdownOpen = s.countdownOpen
            }
        }
        if settings.countdownOpen {
            countdown.screenIndex = video.startupIndex(settings.countdownScreen)
            if countdown.screenIndex != settings.countdownScreen { settings.countdownScreen = countdown.screenIndex }
            countdown.openWindow()
        } else {
            countdown.screenIndex = settings.countdownScreen
        }
        countdownOpen = countdown.windowOpen
        if settings.countdownNDI, let m = countdown.setNDI(true, name: "KIMLAB Countdown") {
            settings.countdownNDI = false
            message = m
        }
    }

    func toggleCountdown() {
        if countdown.windowOpen { countdown.closeWindow() } else { countdown.openWindow() }
        countdownOpen = countdown.windowOpen
        settings.countdownOpen = countdownOpen
    }

    /// -1 = countdown in a normal window, otherwise the index of the screen to fill.
    func setCountdownScreen(_ i: Int) {
        settings.countdownScreen = i
        countdown.moveWindow(to: i)
        if !countdown.windowOpen { countdown.openWindow() }
        countdownOpen = countdown.windowOpen
        settings.countdownOpen = countdownOpen
        if i >= 0 && i == settings.outputScreen && video.windowOpen { message = "The countdown and the output are on the same screen" }
        else if countdown.windowOpen, video.controlOn(i) { countdown.focus(); message = "Countdown covers this screen: press Esc or double-click it to close" }
    }

    func toggleNDI() {
        let on = !countdown.ndiOn
        if let m = countdown.setNDI(on, name: "KIMLAB Countdown") { message = m; settings.countdownNDI = false; return }
        settings.countdownNDI = on
    }

    /// Called from the 30 Hz tick; does nothing while the window is closed and NDI is off.
    func countdownTick() {
        guard countdown.windowOpen || countdown.ndiOn else { return }
        countdown.update(countFrame())
    }

    func countFrame() -> CountFrame {
        var f = CountFrame()
        f.clock = Show.clockFormat.string(from: Date())
        if standby < cues.count { f.next = cueLabel(cues[standby]) }
        var items = [(Date, CountLine, Double)]()       // started, line, seconds left (for groups)
        var inGroup = Set<ObjectIdentifier>()
        for run in groupRuns {
            let members = alive(run).filter { $0.launched }
            for m in run.members { inGroup.insert(ObjectIdentifier(m)) }
            guard !members.isEmpty, let g = cue(run.head) else { continue }
            // a group counts down to its subcue with the most time left (a loop only when nothing else has an end)
            var best: (CountLine, Double)? = nil
            for m in members {
                let it = countLine(m)
                if best == nil || it.1 > best!.1 { best = it }
            }
            if var b = best {
                b.0.label = cueLabel(g)
                items.append((run.started, b.0, b.1))
            }
        }
        for p in playing where p.launched && !p.stopping && !inGroup.contains(ObjectIdentifier(p)) {
            let it = countLine(p)
            items.append((p.started, it.0, it.1))
        }
        f.lines = items.sorted { $0.0 > $1.0 }.map { $0.1 }
        return f
    }

    /// Line for one playing cue, and its seconds left (-1 = no end).
    func countLine(_ p: Playing) -> (CountLine, Double) {
        let c = cue(p.cue)
        var l = CountLine()
        l.label = c.map { cueLabel($0) } ?? ""
        let pos = position(p), dur = duration(p)
        var left = -1.0, total = 0.0
        if dur > 0 && !(c?.loop ?? false) { left = dur - pos; total = dur }
        if let h = parseNum(c?.hold ?? ""), h > 0 {
            let hl = h - Date().timeIntervalSince(p.started)
            if left < 0 || hl < left { left = hl; total = h }
        }
        if left < 0 {
            l.time = (c?.loop ?? false) && dur > 0 ? "LOOP" : "+" + Show.mmss(pos)
            l.tone = 3
            return (l, -1)
        }
        left = max(0, left)
        l.time = Show.mmss(left.rounded(.up))
        l.frac = total > 0 ? max(0, min(1000, Int((1 - left / total) * 1000))) : -1
        l.tone = left <= 10 ? 2 : (left <= 30 ? 1 : 0)
        return (l, left)
    }

    func cueLabel(_ c: Cue) -> String {
        let n = c.num.trimmingCharacters(in: .whitespaces)
        let name = c.name.isEmpty ? ((c.file as NSString).lastPathComponent as String) : c.name
        return n.isEmpty ? name : n + "   " + name
    }

    static let clockFormat: DateFormatter = {
        let d = DateFormatter()
        d.dateFormat = "HH:mm:ss"
        return d
    }()
    /// 75 -> "01:15", 3725 -> "1:02:05"
    static func mmss(_ t: Double) -> String {
        let s = max(0, Int(t))
        let h = s / 3600, m = (s / 60) % 60, sec = s % 60
        if h > 0 { return String(h) + ":" + String(format: "%02d:%02d", m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }
}
