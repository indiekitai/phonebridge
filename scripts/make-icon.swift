// Generates Resources/AppIcon.icns from SF Symbols.
// Usage: swift scripts/make-icon.swift && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

func render(_ size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = size * 0.1
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.18, yRadius: size * 0.18)
    NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.98, alpha: 1),
               ending: NSColor(calibratedRed: 0.10, green: 0.30, blue: 0.80, alpha: 1))!
        .draw(in: path, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .medium)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "iphone.gen3", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let s = symbol.size
        symbol.draw(in: NSRect(x: size * 0.30 - s.width / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
    }
    if let arrows = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size * 0.2, weight: .bold)
            .applying(.init(paletteColors: [.white]))) {
        let s = arrows.size
        arrows.draw(in: NSRect(x: size * 0.66 - s.width / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(CGFloat(base)).write(to: dir.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(CGFloat(base * 2)).write(to: dir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("wrote \(dir.path)")
