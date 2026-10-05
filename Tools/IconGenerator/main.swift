import AppKit

// Writes an .iconset directory for `iconutil -c icns`.
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: IconGenerator <output.iconset>\n".data(using: .utf8)!)
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = IPIcon.appIconBitmap(pixels: base * scale).representation(using: .png, properties: [:])!
        try png.write(to: output.appendingPathComponent(name))
    }
}
// Preview of the template menu bar glyph at 2x, for visual checks.
let menuRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
menuRep.size = NSSize(width: 18, height: 18)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: menuRep)
IPIcon.menuBarImage().draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
NSGraphicsContext.restoreGraphicsState()
try menuRep.representation(using: .png, properties: [:])!
    .write(to: output.deletingLastPathComponent().appendingPathComponent("menubar-preview@2x.png"))
