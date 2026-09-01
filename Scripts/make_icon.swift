#!/usr/bin/env swift
// Renders Resources/AppIcon.icns from vector drawing code. The source stays editable and
// reproducible; no generated bitmap is checked into the repository.
//
// Visual direction: a quiet macOS squircle with a raised, glassy mouse badge. The cobalt rim,
// dark inner keyline and soft material highlights borrow Ghostty's dimensional language without
// copying its ghost silhouette. Run from the repository root: swift Scripts/make_icon.swift
import AppKit
import CoreGraphics
import CoreImage

private let canvasSide: CGFloat = 1024
private let fileManager = FileManager.default
private let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
private let iconset = root.appendingPathComponent("build/AppIcon.iconset")
private let output = root.appendingPathComponent("Resources/AppIcon.icns")

try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

private func appColor(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

private func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    appColor(hex, alpha: alpha).cgColor
}

private func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

private func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
    let scale = min(rect.width / size.width, rect.height / size.height)
    let fitted = CGSize(width: size.width * scale, height: size.height * scale)
    return CGRect(
        x: rect.midX - fitted.width / 2,
        y: rect.midY - fitted.height / 2,
        width: fitted.width,
        height: fitted.height
    )
}

private let imageContext = CIContext(options: [.cacheIntermediates: true])

private enum MouseLayerMaterial {
    case gradient
    case blueRim
    case darkKeyline
    case glass
}

private func blurred(_ image: NSImage, radius: CGFloat) -> NSImage {
    var proposedRect = CGRect(origin: .zero, size: image.size)
    guard let source = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
        return image
    }

    let extent = CGRect(origin: .zero, size: image.size)
    let input = CIImage(cgImage: source)
        .clampedToExtent()
    let output = input
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
        .cropped(to: extent)

    guard let result = imageContext.createCGImage(output, from: extent) else {
        return image
    }
    return NSImage(cgImage: result, size: image.size)
}

/// Paints the fogged, refractive material visible inside Ghostty's badge while retaining the exact
/// `computermouse.fill` regions. Everything is clipped back to the symbol at the end, so none of
/// these light fields can become an invented wheel, button or external shadow.
private func drawGlassSurface(in bounds: CGRect, glyph: NSImage) {
    // Slightly warm at the light source, neutral through the middle and lavender toward the base.
    // This is intentionally low-contrast: depth comes from the soft fields and inner edges below.
    NSGradient(colorsAndLocations:
        (appColor(0xE7E7EA), 0.00),
        (appColor(0xF7F7F9), 0.30),
        (appColor(0xF3F4F8), 0.58),
        (appColor(0xEEF0FA), 0.82),
        (appColor(0xE7EBFC), 1.00)
    )?.draw(in: bounds, angle: -90)

    // Build broad, centered fields and blur them together. Ghostty's surface is mostly calm: the
    // glass reads through a soft top inset shadow, a milky center and a restrained lavender base.
    let atmosphere = NSImage(size: glyph.size)
    atmosphere.lockFocus()

    appColor(0x4C5062, alpha: 0.18).setFill()
    NSBezierPath(ovalIn: CGRect(
        x: bounds.minX - bounds.width * 0.08,
        y: bounds.minY + bounds.height * 0.76,
        width: bounds.width * 1.16,
        height: bounds.height * 0.24
    )).fill()

    appColor(0xFFFFFF, alpha: 0.42).setFill()
    NSBezierPath(ovalIn: CGRect(
        x: bounds.minX - bounds.width * 0.04,
        y: bounds.minY + bounds.height * 0.34,
        width: bounds.width * 1.08,
        height: bounds.height * 0.48
    )).fill()

    appColor(0x8794DA, alpha: 0.10).setFill()
    NSBezierPath(ovalIn: CGRect(
        x: bounds.minX - bounds.width * 0.02,
        y: bounds.minY - bounds.height * 0.11,
        width: bounds.width * 1.04,
        height: bounds.height * 0.43
    )).fill()

    appColor(0xFFFFFF, alpha: 0.22).setFill()
    NSBezierPath(ovalIn: CGRect(
        x: bounds.minX + bounds.width * 0.06,
        y: bounds.minY + bounds.height * 0.58,
        width: bounds.width * 0.58,
        height: bounds.height * 0.18
    )).fill()

    // A pair of offset, low-frequency fields recreates the cloudy tonal variation in Ghostty's
    // glass: one neutral shadow and one transmitted white glow, both without a readable edge.
    appColor(0x777C91, alpha: 0.16).setFill()
    NSBezierPath(ovalIn: CGRect(
        x: bounds.minX + bounds.width * 0.16,
        y: bounds.minY + bounds.height * 0.37,
        width: bounds.width * 0.42,
        height: bounds.height * 0.30
    )).fill()

    appColor(0xFFFFFF, alpha: 0.24).setFill()
    NSBezierPath(ovalIn: CGRect(
        x: bounds.minX + bounds.width * 0.42,
        y: bounds.minY + bounds.height * 0.30,
        width: bounds.width * 0.58,
        height: bounds.height * 0.38
    )).fill()

    atmosphere.unlockFocus()
    blurred(atmosphere, radius: min(bounds.width, bounds.height) * 0.105)
        .draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 0.68)

    // The symbol's dark dividers cast a very soft shadow into adjacent glass, just as Ghostty's
    // face details sit above its translucent panel. These blurred bands add depth without adding
    // any new mouse control or changing the source contour.
    let castShadows = NSImage(size: glyph.size)
    castShadows.lockFocus()
    appColor(0x343847, alpha: 0.20).setFill()
    CGRect(
        x: bounds.minX - bounds.width * 0.04,
        y: bounds.minY + bounds.height * 0.585,
        width: bounds.width * 1.08,
        height: bounds.height * 0.032
    ).fill()
    CGRect(
        x: bounds.minX + bounds.width * 0.482,
        y: bounds.minY + bounds.height * 0.60,
        width: bounds.width * 0.036,
        height: bounds.height * 0.38
    ).fill()
    castShadows.unlockFocus()
    blurred(castShadows, radius: min(bounds.width, bounds.height) * 0.018)
        .draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 0.46)

    // Keep the glass edge quiet. Explicit inner rings on this segmented SF Symbol form a
    // conspicuous crescent, unlike Ghostty's diffuse material boundary.

    // Very fine deterministic luminance variation keeps large sizes from looking like a flat SVG.
    // It disappears cleanly at menu-bar sizes instead of becoming visible speckle.
    var noiseState: UInt64 = 0x4F_70_65_6E_4D_6F_75_73
    for _ in 0..<900 {
        noiseState = noiseState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let xUnit = CGFloat((noiseState >> 16) & 0xFFFF) / CGFloat(UInt16.max)
        noiseState = noiseState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let yUnit = CGFloat((noiseState >> 16) & 0xFFFF) / CGFloat(UInt16.max)
        noiseState = noiseState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let light = (noiseState & 1) == 0
        (light ? appColor(0xFFFFFF, alpha: 0.020) : appColor(0x59618A, alpha: 0.014)).setFill()
        let dot = 0.7 + CGFloat((noiseState >> 8) & 0x7) * 0.12
        NSBezierPath(ovalIn: CGRect(
            x: bounds.minX + xUnit * bounds.width,
            y: bounds.minY + yUnit * bounds.height,
            width: dot,
            height: dot
        )).fill()
    }

    // Clip every material contribution to the source symbol once more after blurring.
    glyph.draw(in: bounds, from: .zero, operation: .destinationIn, fraction: 1)
}

private func drawBlueRimSurface(in bounds: CGRect) {
    // One continuous gradient across the expanded mask keeps the rim dimensional without any
    // clipped radial patches or seams between morphology copies.
    NSGradient(colorsAndLocations:
        (appColor(0x7184FF), 0.00),
        (appColor(0x526AF6), 0.28),
        (appColor(0x344BD7), 0.68),
        (appColor(0x5867D3), 1.00)
    )?.draw(in: bounds, angle: -90)
}

private func drawDarkKeylineSurface(in bounds: CGRect) {
    NSGradient(colorsAndLocations:
        (appColor(0x24283A), 0.00),
        (appColor(0x0A0C16), 0.36),
        (appColor(0x05060D), 0.70),
        (appColor(0x171C33), 1.00)
    )?.draw(in: bounds, angle: -90)
}

/// Draws the exact SF Symbol used by `StatusItemController`. Offset copies produce the cobalt rim
/// and dark keyline without scaling the glyph; the final layer receives the glass surface above.
@discardableResult
private func drawMenuBarMouseLayer(
    _ context: CGContext,
    in rect: CGRect,
    colors: [NSColor],
    spread: CGFloat = 0,
    material: MouseLayerMaterial = .gradient
) -> CGRect {
    let configuration = NSImage.SymbolConfiguration(pointSize: rect.height, weight: .regular)
    guard let glyph = NSImage(
        systemSymbolName: "computermouse.fill",
        accessibilityDescription: nil
    )?.withSymbolConfiguration(configuration) else {
        fatalError("computermouse.fill is unavailable")
    }

    let target = aspectFit(glyph.size, in: rect)
    let padding = spread > 0 ? spread + 2 : 0
    let localBounds = CGRect(
        origin: .zero,
        size: CGSize(width: target.width + padding * 2, height: target.height + padding * 2)
    )
    let localTarget = CGRect(
        x: padding,
        y: padding,
        width: target.width,
        height: target.height
    )

    // Construct a single alpha mask first. Filling this union once avoids visible gradient seams
    // where the morphology copies overlap, while still preserving the SF Symbol's exact geometry.
    let mask = NSImage(size: localBounds.size)
    mask.lockFocus()
    if spread > 0 {
        for index in 0..<96 {
            let angle = CGFloat(index) * 2 * .pi / 96
            glyph.draw(
                in: localTarget.offsetBy(dx: cos(angle) * spread, dy: sin(angle) * spread),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
        }
    }
    glyph.draw(in: localTarget, from: .zero, operation: .sourceOver, fraction: 1)
    mask.unlockFocus()

    let layer = NSImage(size: localBounds.size)
    layer.lockFocus()
    switch material {
    case .glass:
        drawGlassSurface(in: localBounds, glyph: mask)
    case .blueRim:
        drawBlueRimSurface(in: localBounds)
    case .darkKeyline:
        drawDarkKeylineSurface(in: localBounds)
    case .gradient:
        if colors.count > 1 {
            NSGradient(colors: colors)?.draw(in: localBounds, angle: -90)
        } else {
            colors[0].setFill()
            localBounds.fill()
        }
    }
    mask.draw(in: localBounds, from: .zero, operation: .destinationIn, fraction: 1)
    layer.unlockFocus()

    let destination = CGRect(
        x: target.minX - padding,
        y: target.minY - padding,
        width: localBounds.width,
        height: localBounds.height
    )
    context.saveGState()
    layer.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1)
    context.restoreGState()
    return target
}

private func fillGradient(
    _ context: CGContext,
    path: CGPath,
    colors: [CGColor],
    locations: [CGFloat],
    start: CGPoint,
    end: CGPoint
) {
    guard let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: colors as CFArray,
        locations: locations
    ) else { return }

    context.saveGState()
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

private func drawMaster(in context: CGContext) {
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // MARK: macOS tile

    let tileRect = CGRect(x: 72, y: 72, width: 880, height: 880)
    let tile = roundedRect(tileRect, radius: 224)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -18), blur: 28, color: color(0x0B1020, alpha: 0.22))
    context.addPath(tile)
    context.setFillColor(color(0xFFFFFF))
    context.fillPath()
    context.restoreGState()

    fillGradient(
        context,
        path: tile,
        colors: [color(0xFFFFFF), color(0xFBFCFF), color(0xF2F4FB)],
        locations: [0, 0.52, 1],
        start: CGPoint(x: 512, y: 952),
        end: CGPoint(x: 512, y: 72)
    )

    // A restrained inner edge makes the white tile visible on light desktops.
    context.addPath(tile)
    context.setStrokeColor(color(0xFFFFFF, alpha: 0.86))
    context.setLineWidth(3)
    context.strokePath()

    // MARK: raised mouse badge

    let outerRect = CGRect(x: 270, y: 202, width: 484, height: 620)
    drawMenuBarMouseLayer(
        context,
        in: outerRect,
        colors: [appColor(0x667BFF)],
        spread: 50,
        material: .blueRim
    )

    drawMenuBarMouseLayer(
        context,
        in: outerRect,
        colors: [appColor(0x171A2A)],
        spread: 25,
        material: .darkKeyline
    )

    drawMenuBarMouseLayer(
        context,
        in: outerRect,
        colors: [appColor(0xFFFFFF)],
        material: .glass
    )
}

private func makeBitmap(side: Int, drawing: (CGContext) -> Void) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: side,
        pixelsHigh: side,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("unable to create \(side)x\(side) bitmap")
    }

    rep.size = NSSize(width: side, height: side)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.cgContext.clear(CGRect(x: 0, y: 0, width: side, height: side))
    drawing(graphics.cgContext)
    graphics.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

private let master = makeBitmap(side: Int(canvasSide)) { context in
    drawMaster(in: context)
}

private func resizedMaster(to side: Int) -> NSBitmapImageRep {
    makeBitmap(side: side) { context in
        context.interpolationQuality = .high
        let image = NSImage(size: NSSize(width: canvasSide, height: canvasSide))
        image.addRepresentation(master)
        image.draw(
            in: CGRect(x: 0, y: 0, width: side, height: side),
            from: CGRect(x: 0, y: 0, width: canvasSide, height: canvasSide),
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let side = base * scale
        let rep = resizedMaster(to: side)
        guard let png = rep.representation(using: .png, properties: [.compressionFactor: 1]) else {
            fatalError("unable to encode \(side)x\(side) icon")
        }
        let suffix = scale == 1 ? "" : "@2x"
        try png.write(to: iconset.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
    }
}

let preview = iconset.appendingPathComponent("icon_512x512@2x.png")
let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try convert.run()
convert.waitUntilExit()

guard convert.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(convert.terminationStatus)")
}

print("wrote \(output.path)")
print("preview \(preview.path)")
