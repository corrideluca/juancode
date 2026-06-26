#!/usr/bin/env swift
// Generates AppIcon.icns for the juancode app: a white code glyph
// (chevron.left.forwardslash.chevron.right, i.e. `</>`) on a black rounded
// square, following Apple's icon canvas proportions. Run from anywhere:
//
//   swift apps/native/scripts/make-icon.swift
//
// Output: apps/native/AppIcon.icns (consumed by scripts/dev-app.sh).
import AppKit

let nativeDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // scripts/
    .deletingLastPathComponent() // native/
let outICNS = nativeDir.appendingPathComponent("AppIcon.icns")

// Render one square icon image at the given pixel size.
func renderIcon(_ px: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)

    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    // Apple's icon grid: rounded square inset ~10%, corner radius ~22.5% of it.
    let inset = px * 0.10
    let rect = NSRect(x: inset, y: inset, width: px - 2 * inset, height: px - 2 * inset)
    let radius = rect.width * 0.225
    let bg = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSColor.black.setFill()
    bg.fill()

    // White `</>` SF Symbol, centered, ~55% of the inner square.
    let cfg = NSImage.SymbolConfiguration(pointSize: rect.width * 0.55, weight: .semibold)
    if let base = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right",
                          accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        // Template symbols draw in their native (black) color, so tint to white
        // by compositing white over the glyph's alpha.
        let sym = NSImage(size: base.size)
        sym.lockFocus()
        base.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1.0)
        NSColor.white.set()
        NSRect(origin: .zero, size: base.size).fill(using: .sourceAtop)
        sym.unlockFocus()

        let s = sym.size
        let drawRect = NSRect(
            x: rect.midX - s.width / 2, y: rect.midY - s.height / 2,
            width: s.width, height: s.height)
        sym.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0,
                 respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// Build an .iconset and convert with iconutil (standard macOS icns sizes).
let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("juancode.iconset")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

let sizes: [(name: String, px: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    let data = renderIcon(px).representation(using: .png, properties: [:])!
    try! data.write(to: tmp.appendingPathComponent("\(name).png"))
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", tmp.path, "-o", outICNS.path]
try! proc.run()
proc.waitUntilExit()
guard proc.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}
print("wrote \(outICNS.path)")
