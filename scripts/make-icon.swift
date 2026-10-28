// Renders Assets/AppIcon.icns: a blue rounded square with a white download arrow and segment bar.
// Run: swift scripts/make-icon.swift
import AppKit

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS icon grid: ~10% margin, continuous-corner square.
    let inset = s * 0.1
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(starting: NSColor(red: 0.20, green: 0.56, blue: 1.0, alpha: 1),
               ending: NSColor(red: 0.07, green: 0.30, blue: 0.85, alpha: 1))!.draw(in: shape, angle: -90)
    NSColor.white.setFill()
    let w = body.width, x0 = body.minX, y0 = body.minY
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: x0 + w * 0.42, y: y0 + w * 0.80))
    arrow.line(to: NSPoint(x: x0 + w * 0.58, y: y0 + w * 0.80))
    arrow.line(to: NSPoint(x: x0 + w * 0.58, y: y0 + w * 0.52))
    arrow.line(to: NSPoint(x: x0 + w * 0.72, y: y0 + w * 0.52))
    arrow.line(to: NSPoint(x: x0 + w * 0.50, y: y0 + w * 0.30))
    arrow.line(to: NSPoint(x: x0 + w * 0.28, y: y0 + w * 0.52))
    arrow.line(to: NSPoint(x: x0 + w * 0.42, y: y0 + w * 0.52))
    arrow.close()
    arrow.fill()
    // Segmented progress bar, a nod to parallel connections.
    let barY = y0 + w * 0.16, barH = w * 0.07, gap = w * 0.02
    let segW = (w * 0.64 - gap * 3) / 4
    for i in 0..<4 {
        let r = NSRect(x: x0 + w * 0.18 + CGFloat(i) * (segW + gap), y: barY, width: segW, height: barH)
        NSColor.white.withAlphaComponent(i < 3 ? 1 : 0.4).setFill()
        NSBezierPath(roundedRect: r, xRadius: barH / 2, yRadius: barH / 2).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments.first.map { _ in FileManager.default.currentDirectoryPath }!)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let out = root.appendingPathComponent("Assets/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! p.run()
p.waitUntilExit()
try! render(1024).write(to: root.appendingPathComponent("Assets/AppIcon-1024.png"))
print(p.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
