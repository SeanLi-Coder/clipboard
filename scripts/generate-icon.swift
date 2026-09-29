import AppKit

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".build/ClipShelf.iconset")
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 255) / 255,
        green: CGFloat((hex >> 8) & 255) / 255,
        blue: CGFloat(hex & 255) / 255,
        alpha: alpha
    )
}

func rounded(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func fill(_ rect: NSRect, radius: CGFloat, with value: NSColor) {
    value.setFill()
    rounded(rect, radius: radius).fill()
}

func drawIcon(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "ClipShelfIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to create drawing context."])
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    context.imageInterpolation = .high
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()

    let tile = rounded(NSRect(x: 76, y: 76, width: 872, height: 872), radius: 202)
    NSGraphicsContext.saveGraphicsState()
    let tileShadow = NSShadow()
    tileShadow.shadowColor = color(0x061B39, alpha: 0.30)
    tileShadow.shadowBlurRadius = 30
    tileShadow.shadowOffset = NSSize(width: 0, height: -12)
    tileShadow.set()
    color(0x083A64).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(0x082C56), color(0x146EA0), color(0x42B9C5)])!.draw(in: tile, angle: 50)

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    let ambientGlow = NSBezierPath(ovalIn: NSRect(x: 500, y: 615, width: 610, height: 560))
    color(0xBAFFFF, alpha: 0.08).setFill()
    ambientGlow.fill()
    NSGraphicsContext.restoreGraphicsState()

    fill(NSRect(x: 256, y: 208, width: 488, height: 554), radius: 57, with: color(0x051D3F, alpha: 0.18))
    fill(NSRect(x: 294, y: 204, width: 486, height: 568), radius: 57, with: color(0x87CDD8, alpha: 0.72))
    fill(NSRect(x: 248, y: 234, width: 486, height: 568), radius: 57, with: color(0xC6ECF3, alpha: 0.95))

    let paper = rounded(NSRect(x: 214, y: 268, width: 486, height: 568), radius: 57)
    NSGraphicsContext.saveGraphicsState()
    let paperShadow = NSShadow()
    paperShadow.shadowColor = color(0x002442, alpha: 0.22)
    paperShadow.shadowBlurRadius = 26
    paperShadow.shadowOffset = NSSize(width: 0, height: -14)
    paperShadow.set()
    color(0xF7FDFF).setFill()
    paper.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(0xDCECF5), color(0xFFFFFF)])!.draw(in: paper, angle: 90)

    fill(NSRect(x: 353, y: 788, width: 211, height: 96), radius: 35, with: color(0x062C50, alpha: 0.14))
    let clip = rounded(NSRect(x: 350, y: 801, width: 214, height: 88), radius: 31)
    NSGradient(colors: [color(0x54D6D0), color(0x92F1DA)])!.draw(in: clip, angle: 90)
    fill(NSRect(x: 396, y: 826, width: 122, height: 25), radius: 12, with: color(0x135873, alpha: 0.72))

    fill(NSRect(x: 292, y: 666, width: 228, height: 28), radius: 14, with: color(0x286382))
    fill(NSRect(x: 292, y: 594, width: 320, height: 24), radius: 12, with: color(0xA9C1D0))
    fill(NSRect(x: 292, y: 534, width: 262, height: 24), radius: 12, with: color(0xA9C1D0))
    fill(NSRect(x: 292, y: 474, width: 191, height: 24), radius: 12, with: color(0xA9C1D0))

    let history = NSBezierPath(ovalIn: NSRect(x: 553, y: 176, width: 276, height: 276))
    NSGraphicsContext.saveGraphicsState()
    let badgeShadow = NSShadow()
    badgeShadow.shadowColor = color(0x062640, alpha: 0.28)
    badgeShadow.shadowBlurRadius = 20
    badgeShadow.shadowOffset = NSSize(width: 0, height: -10)
    badgeShadow.set()
    color(0x58D5CA).setFill()
    history.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(0x27B2AD), color(0x84ECDA)])!.draw(in: history, angle: 90)

    let clock = NSBezierPath()
    clock.appendArc(withCenter: NSPoint(x: 691, y: 314), radius: 77, startAngle: 151, endAngle: -168, clockwise: true)
    clock.lineWidth = 18
    clock.lineCapStyle = .round
    color(0x073D59).setStroke()
    clock.stroke()

    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 616, y: 384))
    arrow.line(to: NSPoint(x: 621, y: 351))
    arrow.line(to: NSPoint(x: 655, y: 356))
    arrow.lineWidth = 16
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.stroke()

    let hands = NSBezierPath()
    hands.move(to: NSPoint(x: 691, y: 359))
    hands.line(to: NSPoint(x: 691, y: 312))
    hands.line(to: NSPoint(x: 726, y: 290))
    hands.lineWidth = 17
    hands.lineCapStyle = .round
    hands.lineJoinStyle = .round
    hands.stroke()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "ClipShelfIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to encode icon."])
    }
    return data
}

for points in [16, 32, 128, 256, 512] {
    for multiplier in [1, 2] {
        let suffix = multiplier == 2 ? "@2x" : ""
        let filename = "icon_\(points)x\(points)\(suffix).png"
        let data = try drawIcon(size: points * multiplier)
        try data.write(to: outputDirectory.appendingPathComponent(filename))
    }
}
print("Generated icon set: \(outputDirectory.path)")
