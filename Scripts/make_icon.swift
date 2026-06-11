// One-off generator for AppIcon.appiconset. Run:
//   swift Scripts/make_icon.swift
// Renders a flat macOS squircle icon — slate background, wrench glyph.
import AppKit

let outDir = "macToolKit/Assets.xcassets/AppIcon.appiconset"

func render(px: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    rep.size = NSSize(width: px, height: px)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(px)
    // Full-bleed square: macOS 26 applies its own icon mask, so any baked-in
    // shape or transparent margin shows up as a shrunken floating tile.
    let rect = NSRect(x: 0, y: 0, width: s, height: s)

    // Quiet two-stop slate — close stops, no rainbow.
    let top = NSColor(calibratedRed: 0.255, green: 0.282, blue: 0.345, alpha: 1)
    let bottom = NSColor(calibratedRed: 0.157, green: 0.173, blue: 0.224, alpha: 1)
    NSGradient(starting: top, ending: bottom)?.draw(in: rect, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: s * 0.46, weight: .medium)
        .applying(.init(paletteColors: [NSColor(calibratedWhite: 0.96, alpha: 1)]))
    if let symbol = NSImage(systemSymbolName: "wrench.and.screwdriver.fill",
                            accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let size = symbol.size
        let origin = NSPoint(x: (s - size.width) / 2, y: (s - size.height) / 2)
        symbol.draw(in: NSRect(origin: origin, size: size))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let entries: [(px: Int, size: String, scale: Int)] = [
    (16, "16x16", 1), (32, "16x16", 2),
    (32, "32x32", 1), (64, "32x32", 2),
    (128, "128x128", 1), (256, "128x128", 2),
    (256, "256x256", 1), (512, "256x256", 2),
    (512, "512x512", 1), (1024, "512x512", 2),
]

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

var images: [[String: String]] = []
for entry in entries {
    let filename = "icon_\(entry.size)@\(entry.scale)x.png"
    guard let data = render(px: entry.px) else { fatalError("render failed \(entry.px)") }
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(filename)"))
    images.append(["size": entry.size, "idiom": "mac",
                   "filename": filename, "scale": "\(entry.scale)x"])
    print("wrote \(filename)")
}

let contents: [String: Any] = [
    "images": images,
    "info": ["version": 1, "author": "xcode"],
]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: URL(fileURLWithPath: "\(outDir)/Contents.json"))
print("wrote Contents.json")
