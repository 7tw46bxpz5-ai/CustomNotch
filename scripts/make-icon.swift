// Draws the app icon (flat dark colours with the #935B29 accent, no gradients) and writes Resources/AppIcon.icns.
// Run from the project folder:  swift scripts/make-icon.swift
import AppKit

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    // Flipped drawing: y grows downwards, like the design.
    let transform = NSAffineTransform()
    transform.translateX(by: 0, yBy: size)
    transform.scaleX(by: s, yBy: -s)
    transform.concat()

    // Body: the standard macOS icon square (824 pt inside a 1024 canvas).
    color(0x1C1C1E).setFill()
    NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185).fill()

    // The island: a black pill under the top edge, with an accent dot and a 3×3 grid.
    NSColor.black.setFill()
    NSBezierPath(roundedRect: NSRect(x: 262, y: 188, width: 500, height: 132), xRadius: 66, yRadius: 66).fill()
    color(0x935B29).setFill()
    NSBezierPath(ovalIn: NSRect(x: 318, y: 228, width: 52, height: 52)).fill()
    for row in 0..<3 {
        for column in 0..<3 {
            let alpha: CGFloat = row + column == 2 ? 1 : 0.4
            color(0x935B29).withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: NSRect(x: 636 + CGFloat(column) * 22, y: 222 + CGFloat(row) * 22, width: 15, height: 15),
                         xRadius: 4, yRadius: 4).fill()
        }
    }

    // Two tiles with lines of "text".
    for x in [196.0, 532.0] {
        color(0x2C2C2E).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: 396, width: 296, height: 420), xRadius: 56, yRadius: 56).fill()
        color(0xE3E7EF).setFill()
        NSBezierPath(roundedRect: NSRect(x: x + 44, y: 456, width: 150, height: 34), xRadius: 17, yRadius: 17).fill()
        color(0xA4ABBA).setFill()
        NSBezierPath(roundedRect: NSRect(x: x + 44, y: 516, width: 208, height: 26), xRadius: 13, yRadius: 13).fill()
        NSBezierPath(roundedRect: NSRect(x: x + 44, y: 562, width: 120, height: 26), xRadius: 13, yRadius: 13).fill()
    }
    color(0x935B29).setFill()
    NSBezierPath(roundedRect: NSRect(x: 240, y: 730, width: 140, height: 26), xRadius: 13, yRadius: 13).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = drawIcon(size: pixels).representation(using: .png, properties: [:])!
        try! png.write(to: iconset.appendingPathComponent(name))
    }
}
let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
