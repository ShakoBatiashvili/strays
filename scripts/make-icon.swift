// Draws the app icon (a paw print on a warm tile) into an .iconset folder.
// Vector code only, no third-party artwork. Usage: swift scripts/make-icon.swift <out.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(size: CGFloat) -> Data? {
    let pixels = Int(size)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // macOS icon grid: the tile is ~80% of the canvas, with a soft shadow.
    let inset = size * 0.1
    let tile = NSRect(x: inset, y: inset * 1.15, width: size - inset * 2, height: size - inset * 2)
    let radius = tile.width * 0.225
    let path = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = size * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 1.00, green: 0.66, blue: 0.27, alpha: 1),
        NSColor(calibratedRed: 0.93, green: 0.36, blue: 0.20, alpha: 1),
    ])!
    gradient.draw(in: path, angle: -90)

    // A faint top highlight for depth.
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // The paw print.
    let config = NSImage.SymbolConfiguration(pointSize: tile.width * 0.5, weight: .bold)
    if let paw = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let tinted = NSImage(size: paw.size, flipped: false) { rect in
            paw.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let s = tinted.size
        let scale = (tile.width * 0.56) / max(s.width, s.height)
        let w = s.width * scale, h = s.height * scale
        tinted.draw(in: NSRect(x: tile.midX - w / 2, y: tile.midY - h / 2 - tile.height * 0.01, width: w, height: h))
    }
    return rep.representation(using: .png, properties: [:])
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        if let data = render(size: CGFloat(base * scale)) { try data.write(to: output.appendingPathComponent(name)) }
    }
}
print("Wrote \(output.path)")
