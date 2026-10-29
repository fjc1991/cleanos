// Renders the CleanOS app icon (gradient squircle + sparkles) into an .iconset and builds AppIcon.icns.
import AppKit

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "App/Resources"
let iconset = URL(filePath: NSTemporaryDirectory()).appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.cgContext.setAllowsAntialiasing(true)
    let p = CGFloat(pixels)
    let rect = NSRect(x: 0, y: 0, width: p, height: p)
    // macOS icons leave a margin around the squircle.
    let body = rect.insetBy(dx: p * 0.08, dy: p * 0.08)
    let squircle = NSBezierPath(roundedRect: body, xRadius: p * 0.21, yRadius: p * 0.21)

    // Shadow under the squircle.
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = p * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -p * 0.015)
    shadow.set()
    NSColor(red: 0.12, green: 0.15, blue: 0.40, alpha: 1).setFill()
    squircle.fill()
    NSShadow().set()

    // Deep blue → violet gradient, like the app window.
    let gradient = NSGradient(colors: [
        NSColor(red: 0.20, green: 0.42, blue: 0.98, alpha: 1),
        NSColor(red: 0.16, green: 0.20, blue: 0.60, alpha: 1),
        NSColor(red: 0.42, green: 0.26, blue: 0.80, alpha: 1),
    ], atLocations: [0, 0.55, 1], colorSpace: .deviceRGB)!
    gradient.draw(in: squircle, angle: -62)

    // Soft highlight across the top.
    squircle.addClip()
    let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
    highlight.draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: 90)

    // Sparkles symbol, white with a slight glow.
    let config = NSImage.SymbolConfiguration(pointSize: p * 0.46, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let size = symbol.size
        let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 + p * 0.01)
        let tinted = NSImage(size: size, flipped: false) { r in
            symbol.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let glow = NSShadow()
        glow.shadowColor = NSColor(red: 0.6, green: 0.8, blue: 1, alpha: 0.9)
        glow.shadowBlurRadius = p * 0.04
        glow.shadowOffset = .zero
        glow.set()
        tinted.draw(at: origin, from: NSRect(origin: .zero, size: size), operation: .sourceOver, fraction: 1)
        NSShadow().set()
        tinted.draw(at: origin, from: NSRect(origin: .zero, size: size), operation: .sourceOver, fraction: 1)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in entries {
    let rep = render(pixels: pixels)
    try rep.representation(using: .png, properties: [:])!.write(to: iconset.appending(path: "\(name).png"))
}
// Preview for humans.
try render(pixels: 512).representation(using: .png, properties: [:])!.write(to: URL(filePath: outputDir).appending(path: "AppIcon-preview.png"))

let process = Process()
process.executableURL = URL(filePath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", URL(filePath: outputDir).appending(path: "AppIcon.icns").path]
try process.run()
process.waitUntilExit()
print(process.terminationStatus == 0 ? "AppIcon.icns written to \(outputDir)" : "iconutil failed")
