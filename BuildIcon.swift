import AppKit
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let size = CGFloat(pixels)
        let tile = NSBezierPath(roundedRect: NSRect(x: size * 0.05, y: size * 0.05, width: size * 0.9, height: size * 0.9),
                                xRadius: size * 0.21, yRadius: size * 0.21)
        NSGradient(starting: NSColor(red: 0.12, green: 0.30, blue: 0.78, alpha: 1),
                   ending: NSColor(red: 0.28, green: 0.63, blue: 0.86, alpha: 1))!.draw(in: tile, angle: 60)
        NSColor.white.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: NSRect(x: size * 0.20, y: size * 0.34, width: size * 0.62, height: size * 0.42),
                     xRadius: size * 0.06, yRadius: size * 0.06).fill()
        NSColor.white.withAlphaComponent(0.96).setFill()
        NSBezierPath(roundedRect: NSRect(x: size * 0.15, y: size * 0.23, width: size * 0.66, height: size * 0.44),
                     xRadius: size * 0.07, yRadius: size * 0.07).fill()
        let play = NSBezierPath()
        play.move(to: NSPoint(x: size * 0.43, y: size * 0.34))
        play.line(to: NSPoint(x: size * 0.43, y: size * 0.56))
        play.line(to: NSPoint(x: size * 0.61, y: size * 0.45)); play.close()
        NSColor(red: 0.16, green: 0.41, blue: 0.78, alpha: 1).setFill(); play.fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
