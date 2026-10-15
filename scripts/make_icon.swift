// Renders the app icon → Resources/AppIcon.icns
// Usage: swift scripts/make_icon.swift   (run from the repo root)
import AppKit

let lime = NSColor(srgbRed: 0xE6 / 255, green: 0xF0 / 255, blue: 0xA3 / 255, alpha: 1)
let bg = NSColor(srgbRed: 0x0E / 255, green: 0x0E / 255, blue: 0x10 / 255, alpha: 1)
let track = NSColor(srgbRed: 0x26 / 255, green: 0x26 / 255, blue: 0x2A / 255, alpha: 1)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024) // draw on a 1024 grid

    // Body: macOS icon grid (824pt squircle-ish rounded rect, centered) with a soft drop shadow.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    bg.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Subtle top highlight + hairline border, like the panel.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(starting: NSColor.white.withAlphaComponent(0.06), ending: .clear)!
        .draw(in: body, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.08).setStroke()
    let border = NSBezierPath(roundedRect: body.insetBy(dx: 2, dy: 2), xRadius: 183, yRadius: 183)
    border.lineWidth = 4
    border.stroke()

    // Progress ring: dark track + lime arc (≈70%), flat caps.
    let c = NSPoint(x: 512, y: 512), r: CGFloat = 250
    let ring = NSBezierPath()
    ring.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
    ring.lineWidth = 64
    track.setStroke()
    ring.stroke()

    let arc = NSBezierPath()
    arc.appendArc(withCenter: c, radius: r, startAngle: 90, endAngle: 90 - 252, clockwise: true)
    arc.lineWidth = 64
    arc.lineCapStyle = .butt
    lime.setStroke()
    arc.stroke()

    // Center: the notched (cut-corner) lime block from the panel's primary button.
    let s: CGFloat = 150, cut: CGFloat = 38
    let b = NSRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s)
    let block = NSBezierPath()
    block.move(to: NSPoint(x: b.minX, y: b.maxY))
    block.line(to: NSPoint(x: b.maxX, y: b.maxY))
    block.line(to: NSPoint(x: b.maxX, y: b.minY))
    block.line(to: NSPoint(x: b.minX + cut, y: b.minY))
    block.line(to: NSPoint(x: b.minX, y: b.minY + cut))
    block.close()
    lime.setFill()
    block.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try! FileManager.default.createDirectory(at: URL(fileURLWithPath: "Resources"), withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
