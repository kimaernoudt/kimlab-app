import AppKit
import AVFoundation
import CoreMedia
import CoreAudio

/// NSView that hosts a CALayer tree and keeps it sized to the view.
final class LayerHostView: NSView {
    let hosted: CALayer
    init(hosted: CALayer) {
        self.hosted = hosted
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(hosted)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hosted.frame = bounds
        for l in hosted.sublayers ?? [] { l.frame = hosted.bounds }
        CATransaction.commit()
    }
}

/// Two video players (A/B) with crossfade, blackout and test pattern, shown in the output window and the preview.
final class VideoOut: NSObject {
    let players = [AVPlayer(), AVPlayer()]
    let root = CALayer()
    let previewRoot = CALayer()
    private var layers = [AVPlayerLayer]()
    private var previewLayers = [AVPlayerLayer]()
    private var blacks = [CALayer]()
    private var tests = [CALayer]()
    private var window: NSWindow? = nil
    private var z: CGFloat = 1
    private(set) var urls: [URL?] = [nil, nil]
    private var fadeToken = [0, 0]
    var imgLayers = [CALayer]()
    var imgPreview = [CALayer]()
    var imageShown = [false, false]
    var savedModes: [CGDirectDisplayID: CGDisplayMode] = [:]
    var onEnded: ((Int) -> Void)? = nil

    override init() {
        super.init()
        let img = VideoOut.testImage()
        for r in [root, previewRoot] {
            r.backgroundColor = NSColor.black.cgColor
            let t = CALayer()
            t.contents = img
            t.contentsGravity = .resizeAspect
            t.backgroundColor = NSColor.black.cgColor
            t.opacity = 0
            t.zPosition = 100000
            let b = CALayer()
            b.backgroundColor = NSColor.black.cgColor
            b.opacity = 0
            b.zPosition = 100001
            r.addSublayer(t)
            r.addSublayer(b)
            tests.append(t)
            blacks.append(b)
        }
        for p in players {
            p.isMuted = true
            p.automaticallyWaitsToMinimizeStalling = false
            p.actionAtItemEnd = .pause
            let a = AVPlayerLayer(player: p), b = AVPlayerLayer(player: p)
            for l in [a, b] { l.videoGravity = .resizeAspect; l.opacity = 0 }
            root.addSublayer(a)
            previewRoot.addSublayer(b)
            layers.append(a)
            previewLayers.append(b)
        }
        setupImageLayers()
        NotificationCenter.default.addObserver(self, selector: #selector(itemEnded(_:)), name: .AVPlayerItemDidPlayToEndTime, object: nil)
    }

    @objc private func itemEnded(_ n: Notification) {
        guard let item = n.object as? AVPlayerItem else { return }
        for i in 0..<2 where players[i].currentItem === item { onEnded?(i) }
    }

    // MARK: window

    func openWindow() {
        if let w = window { w.orderFront(nil); return }
        let screens = NSScreen.screens
        let w: NSWindow
        if screenIndex >= 0 && screenIndex < screens.count {
            let s = screens[screenIndex]
            w = OutputWindow(contentRect: s.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
            w.setFrame(s.frame, display: true)
        } else {
            w = OutputWindow(contentRect: NSRect(x: 80, y: 80, width: 960, height: 540),
                         styleMask: [.titled, .resizable, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "KIMLAB output"
        }
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.contentView = LayerHostView(hosted: root)
        w.orderFront(nil)
        window = w
    }
    var screenIndex = -1
    func moveWindow(to index: Int) {
        let wasOpen = windowOpen
        screenIndex = index
        window?.orderOut(nil)
        window = nil
        root.removeFromSuperlayer()
        if wasOpen { openWindow() }
    }
    func closeWindow() { window?.orderOut(nil) }
    var windowOpen: Bool { window?.isVisible ?? false }
    var resolution: String {
        guard let w = window, let s = w.screen else { return "-" }
        let sc = s.backingScaleFactor
        return String(Int(w.frame.width * sc)) + " x " + String(Int(w.frame.height * sc))
    }

    // MARK: players

    func setClock(device: AudioDeviceID) {
        var c: CMClock? = nil
        if CMAudioDeviceClockCreateFromAudioDeviceID(allocator: kCFAllocatorDefault, deviceID: device, clockOut: &c) == noErr, let clock = c {
            for p in players { p.sourceClock = clock }
        }
    }
    func load(_ idx: Int, url: URL, at t: Double) {
        let item = AVPlayerItem(url: url)
        clearImage(idx)
        players[idx].replaceCurrentItem(with: item)
        players[idx].pause()
        if t > 0 { players[idx].seek(to: CMTime(seconds: t, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero) }
        urls[idx] = url
    }
    func clear(_ idx: Int) {
        players[idx].pause()
        players[idx].replaceCurrentItem(with: nil)
        clearImage(idx)
        urls[idx] = nil
    }
    func ready(_ idx: Int) -> Bool { imageShown[idx] || players[idx].currentItem?.status == .readyToPlay }
    func failed(_ idx: Int) -> Bool { players[idx].currentItem?.status == .failed }
    func status(_ idx: Int) -> String {
        guard let it = players[idx].currentItem else { return imageShown[idx] ? "image" : "empty" }
        if it.status == .failed { return "failed" }
        if it.status != .readyToPlay { return "loading" }
        return players[idx].rate > 0 ? "playing" : "ready"
    }
    func duration(_ idx: Int) -> Double {
        guard let it = players[idx].currentItem else { return 0 }
        let s = CMTimeGetSeconds(it.duration)
        return s.isFinite ? s : 0
    }
    func position(_ idx: Int) -> Double {
        let s = CMTimeGetSeconds(players[idx].currentTime())
        return s.isFinite ? s : 0
    }
    func start(_ idx: Int, at t: Double, host: UInt64) {
        let ht = CMClockMakeHostTimeFromSystemUnits(host)
        players[idx].setRate(1.0, time: CMTime(seconds: max(0, t), preferredTimescale: 60000), atHostTime: ht)
    }
    func pause(_ idx: Int) { players[idx].pause() }

    // MARK: layers

    private func animate(_ idx: Int, _ o: Float, _ dur: Double) {
        CATransaction.begin()
        if dur <= 0.001 {
            CATransaction.setDisableActions(true)
        } else {
            CATransaction.setAnimationDuration(dur)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        }
        layers[idx].opacity = o
        previewLayers[idx].opacity = o
        imgLayers[idx].opacity = o; imgPreview[idx].opacity = o
        CATransaction.commit()
    }
    /// Fade player idx in on top of the other one; the other is hidden once the fade is done.
    func show(_ idx: Int, fade: Double) {
        z += 1
        let other = 1 - idx
        fadeToken[idx] += 1
        fadeToken[other] += 1
        let tok = fadeToken[other]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layers[idx].zPosition = z
        previewLayers[idx].zPosition = z
        imgLayers[idx].zPosition = z; imgPreview[idx].zPosition = z
        CATransaction.commit()
        animate(idx, 1, fade)
        DispatchQueue.main.asyncAfter(deadline: .now() + fade + 0.05) { [weak self] in
            guard let s = self, s.fadeToken[other] == tok else { return }
            s.animate(other, 0, 0)
        }
    }
    func hide(_ idx: Int, fade: Double) {
        fadeToken[idx] += 1
        animate(idx, 0, fade)
    }
    func setBlackout(_ on: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        for b in blacks { b.opacity = on ? 1 : 0 }
        CATransaction.commit()
    }
    func setTest(_ on: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for t in tests { t.opacity = on ? 1 : 0 }
        CATransaction.commit()
    }

    static func testImage() -> CGImage? {
        let w: CGFloat = 1920, h: CGFloat = 1080
        guard let ctx = CGContext(data: nil, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setStrokeColor(CGColor(gray: 0.45, alpha: 1))
        ctx.setLineWidth(1)
        var x: CGFloat = 0
        while x <= w { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: h)); x += 120 }
        var y: CGFloat = 0
        while y <= h { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: w, y: y)); y += 120 }
        ctx.strokePath()
        let bars: [(CGFloat, CGFloat, CGFloat)] = [(1, 1, 1), (1, 1, 0), (0, 1, 1), (0, 1, 0), (1, 0, 1), (1, 0, 0), (0, 0, 1), (0, 0, 0)]
        let bw = (w - 240) / 8
        for (i, c) in bars.enumerated() {
            ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fill(CGRect(x: 120 + CGFloat(i) * bw, y: 120, width: bw, height: 120))
        }
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(3)
        ctx.strokeEllipse(in: CGRect(x: w / 2 - 420, y: h / 2 - 420, width: 840, height: 840))
        ctx.move(to: CGPoint(x: w / 2, y: 0)); ctx.addLine(to: CGPoint(x: w / 2, y: h))
        ctx.move(to: CGPoint(x: 0, y: h / 2)); ctx.addLine(to: CGPoint(x: w, y: h / 2))
        ctx.strokePath()
        ctx.stroke(CGRect(x: 1.5, y: 1.5, width: w - 3, height: h - 3))
        let g = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 48), .foregroundColor: NSColor.white]
        ("KIMLAB TEST  1920 x 1080" as NSString).draw(at: NSPoint(x: 640, y: 720), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}

/// Output window: Esc or a double-click closes it (also when it fills a screen).
final class OutputWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { orderOut(nil) }
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { orderOut(nil) } else { super.mouseDown(with: event) }
    }
}

extension VideoOut {
    /// True when screen idx also holds the control window.
    func controlOn(_ idx: Int) -> Bool {
        guard idx >= 0, idx < NSScreen.screens.count else { return false }
        let s = NSScreen.screens[idx]
        return NSApp.windows.contains { !($0 is OutputWindow) && $0.isVisible && $0.screen == s }
    }
    /// On startup the output never fills the screen the control window is on; it opens as a window instead.
    func startupIndex(_ wanted: Int) -> Int {
        if controlOn(wanted) { return -1 }
        if let m = NSScreen.main, wanted >= 0, wanted < NSScreen.screens.count, NSScreen.screens[wanted] == m { return -1 }
        return wanted
    }
    func focus() { window?.makeKey() }
}

// Still images: each player slot also has an image layer that fades and stacks together with it.
extension VideoOut {
    func setupImageLayers() {
        for _ in 0..<2 {
            let a = CALayer(), b = CALayer()
            for l in [a, b] { l.contentsGravity = .resizeAspect; l.opacity = 0 }
            root.addSublayer(a)
            previewRoot.addSublayer(b)
            imgLayers.append(a)
            imgPreview.append(b)
        }
    }
    func loadImage(_ idx: Int, url: URL) -> Bool {
        guard let ns = NSImage(contentsOf: url), let img = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        players[idx].pause()
        players[idx].replaceCurrentItem(with: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imgLayers[idx].contents = img
        imgPreview[idx].contents = img
        imgLayers[idx].frame = root.bounds
        imgPreview[idx].frame = previewRoot.bounds
        CATransaction.commit()
        urls[idx] = url
        imageShown[idx] = true
        return true
    }
    func clearImage(_ idx: Int) {
        guard idx < imgLayers.count, imageShown[idx] else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imgLayers[idx].contents = nil
        imgPreview[idx].contents = nil
        CATransaction.commit()
        imageShown[idx] = false
    }
}

// Output resolution: a window gets that pixel size; a screen is switched to that display mode
// (for this app only, macOS restores the display when KIMLAB quits).
extension VideoOut {
    func displayID(_ idx: Int) -> CGDirectDisplayID? {
        guard idx >= 0, idx < NSScreen.screens.count else { return nil }
        return NSScreen.screens[idx].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
    /// res = "" for native, or "1920x1080". Returns a message when it cannot be done.
    func applyResolution(_ res: String) -> String? {
        let parts = res.split(separator: "x").compactMap { Int($0) }
        if screenIndex < 0 {
            guard parts.count == 2, let w = window else { return nil }
            let scale = w.screen?.backingScaleFactor ?? 2
            w.setContentSize(NSSize(width: CGFloat(parts[0]) / scale, height: CGFloat(parts[1]) / scale))
            return nil
        }
        guard let id = displayID(screenIndex) else { return nil }
        if parts.count != 2 {
            if let m = savedModes[id] {
                CGDisplaySetDisplayMode(id, m, nil)
                savedModes[id] = nil
            }
            return nil
        }
        let opts = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode] else { return "No display modes found" }
        var best: CGDisplayMode? = nil
        var bestScore = -1.0
        for m in modes where m.pixelWidth == parts[0] && m.pixelHeight == parts[1] && m.isUsableForDesktopGUI() {
            let score = (m.width == m.pixelWidth ? 1000.0 : 0.0) + m.refreshRate
            if score > bestScore { bestScore = score; best = m }
        }
        guard let mode = best else { return "This display has no " + res + " mode" }
        if savedModes[id] == nil, let cur = CGDisplayCopyDisplayMode(id) { savedModes[id] = cur }
        return CGDisplaySetDisplayMode(id, mode, nil) == .success ? nil : "Could not switch the display to " + res
    }
    func refit() {
        if screenIndex >= 0, screenIndex < NSScreen.screens.count, let w = window, w.isVisible {
            w.setFrame(NSScreen.screens[screenIndex].frame, display: true)
        }
    }
}
