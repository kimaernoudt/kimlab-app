import AppKit

// Renders kimlab.svg to a 1024 px PNG and prints a few pixels so the result can be checked.
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
guard let img = NSImage(contentsOf: dir.appendingPathComponent("kimlab.svg")) else { print("cannot read svg"); exit(1) }
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
rep.size = NSSize(width: 1024, height: 1024)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
img.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024), from: .zero, operation: .copy, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: dir.appendingPathComponent("KIMLAB-1024.png"))
func px(_ x: Int, _ y: Int) -> String {
    guard let c = rep.colorAt(x: x, y: y) else { return "?" }
    return String(format: "%02x%02x%02x a%.2f", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255), c.alphaComponent)
}
print("corner " + px(10, 10) + " | top " + px(512, 150) + " | green " + px(650, 362) + " | amber " + px(512, 500) + " | grey " + px(600, 215) + " | text " + px(476, 760) + " | gap " + px(512, 650) + " | outline " + px(512, 103))
