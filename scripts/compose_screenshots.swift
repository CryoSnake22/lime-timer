// Composes App Store screenshots (2880×1800) from transparent captures of the real UI.
// Usage: swift scripts/compose_screenshots.swift <captures-dir> <output-dir>
//   expects rest.png, hover.png, input.png, settings.png in <captures-dir>
import AppKit

let args = CommandLine.arguments
let inDir = URL(fileURLWithPath: args[1]), outDir = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let W = 2880, H = 1800
let lime = NSColor(srgbRed: 0xE6 / 255, green: 0xF0 / 255, blue: 0xA3 / 255, alpha: 1)
let bg = NSColor(srgbRed: 0x0B / 255, green: 0x0B / 255, blue: 0x0D / 255, alpha: 1)
let dim = NSColor(srgbRed: 0x8C / 255, green: 0x8C / 255, blue: 0x90 / 255, alpha: 1)

let scenes: [(file: String, title: String, subtitle: String, keys: [(String, String)])] = [
    ("rest", "Run it entirely\nfrom your keyboard.", "Works from any app, at any time.",
     [("N", "NEW TIMER"), ("P", "PAUSE / RESUME"), ("S", "STOP"), ("E", "EDIT TIME")]),
    ("hover", "Everything appears\nwhen you need it.", "A small card in the corner of your screen.\nHover to see all your timers.", []),
    ("input", "Start a timer without\nleaving your app.", "⌃⌥N, type “25m focus”, press Return.\nNo clicking, no windows.", []),
    ("settings", "Make it yours.", "Opacity, blur, sounds, and a shake\nwhen time is up.", []),
]

/// A row of keycaps (⌃ ⌥ key) followed by a label, like the app's own shortcut list.
func drawShortcut(_ key: String, _ label: String, at origin: NSPoint) {
    var x = origin.x
    for cap in ["⌃", "⌥", key] {
        let rect = NSRect(x: x, y: origin.y, width: 76, height: 76)
        lime.setFill()
        let path = NSBezierPath()
        let cut: CGFloat = 12 // the notched corner from the app's buttons
        path.move(to: NSPoint(x: rect.minX, y: rect.maxY)); path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY)); path.line(to: NSPoint(x: rect.minX + cut, y: rect.minY))
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + cut)); path.close(); path.fill()
        let t = text(cap, size: 40, weight: .semibold, color: bg)
        let sz = t.size()
        t.draw(at: NSPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2))
        x += 90
    }
    text(label, size: 36, weight: .medium, color: .white, tracking: 4)
        .draw(at: NSPoint(x: x + 24, y: origin.y + 18))
}

/// Bounding box of non-transparent pixels (the card + its shadow), in image coordinates (origin bottom-left).
func opaqueBounds(_ rep: NSBitmapImageRep) -> NSRect {
    var minX = rep.pixelsWide, minY = rep.pixelsHigh, maxX = 0, maxY = 0
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    // colorAt uses top-left origin; convert to bottom-left
    return NSRect(x: minX, y: rep.pixelsHigh - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1)
}

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, tracking: CGFloat = 0, lineHeight: CGFloat? = nil) -> NSAttributedString {
    let p = NSMutableParagraphStyle()
    if let lineHeight { p.minimumLineHeight = lineHeight; p.maximumLineHeight = lineHeight }
    return NSAttributedString(string: s, attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: size, weight: weight),
        .foregroundColor: color, .kern: tracking, .paragraphStyle: p,
    ])
}

for (i, scene) in scenes.enumerated() {
    guard let capture = NSBitmapImageRep(data: try! Data(contentsOf: inDir.appendingPathComponent("\(scene.file).png"))) else { continue }
    let crop = opaqueBounds(capture)

    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let full = NSRect(x: 0, y: 0, width: W, height: H)

    // Background: near-black with a soft lime glow behind the card.
    bg.setFill(); full.fill()
    NSGradient(colors: [lime.withAlphaComponent(0.16), lime.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: 2050, y: 1150), radius: 0, toCenter: NSPoint(x: 2050, y: 1150), radius: 1100, options: [])
    // Faint dot grid for texture.
    NSColor.white.withAlphaComponent(0.035).setFill()
    for gx in stride(from: 40, to: W, by: 60) { for gy in stride(from: 40, to: H, by: 60) { NSRect(x: gx, y: gy, width: 3, height: 3).fill() } }

    // Copy (left).
    text("LIME TIMER", size: 34, weight: .medium, color: lime, tracking: 8).draw(at: NSPoint(x: 200, y: 1330))
    // Headline, then the subtitle a fixed gap below it, whatever the headline's line count.
    let title = text(scene.title, size: 104, weight: .semibold, color: .white, lineHeight: 128)
    let titleHeight = CGFloat(scene.title.split(separator: "\n").count) * 128
    let titleTop: CGFloat = 1300
    title.draw(in: NSRect(x: 200, y: titleTop - titleHeight, width: 1300, height: titleHeight))
    let subtitleHeight = CGFloat(scene.subtitle.split(separator: "\n").count) * 60
    let subtitleBottom = titleTop - titleHeight - 70 - subtitleHeight
    text(scene.subtitle, size: 40, weight: .regular, color: dim, lineHeight: 60)
        .draw(in: NSRect(x: 200, y: subtitleBottom, width: 1300, height: subtitleHeight))
    for (k, (key, label)) in scene.keys.enumerated() {
        drawShortcut(key, label, at: NSPoint(x: 200, y: subtitleBottom - 150 - CGFloat(k) * 110))
    }
    text("0\(i + 1)", size: 30, weight: .medium, color: dim.withAlphaComponent(0.6), tracking: 6).draw(at: NSPoint(x: 200, y: 200))

    // The real UI (right), enlarged 1.5× for legibility, top-anchored like on screen.
    let scale: CGFloat = 1.5
    let size = NSSize(width: crop.width * scale, height: crop.height * scale)
    let topY: CGFloat = 1500
    let dest = NSRect(x: 2680 - size.width, y: topY - size.height, width: size.width, height: size.height)
    let image = NSImage(size: NSSize(width: capture.pixelsWide, height: capture.pixelsHigh))
    image.addRepresentation(capture)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: dest, from: crop, operation: .sourceOver, fraction: 1)

    NSGraphicsContext.restoreGraphicsState()
    let out = outDir.appendingPathComponent(String(format: "%02d-%@.png", i + 1, scene.file))
    try! rep.representation(using: .png, properties: [:])!.write(to: out)
    print("wrote", out.path)
}
