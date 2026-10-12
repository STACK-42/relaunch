// Draws Relaunch's original app icon (no Apple artwork) into an .iconset.
// Usage: swift scripts/make_icon.swift <out.iconset>
//
// Style follows macOS 26+ "Liquid Glass": a squircle tile with a lit rim,
// and frosted glass tiles that blur and brighten the colour behind them.
import AppKit
import CoreImage

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ci = CIContext()

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

/// A rounded rect whose corners are superellipse quarters, so curvature
/// eases into the straight sides like Apple's continuous-corner icon shape.
/// `corner` is how far each corner curve reaches along a side.
func squircle(_ r: CGRect, corner: CGFloat, n: CGFloat = 3.6) -> CGPath {
    let path = CGMutablePath()
    let e = min(corner, min(r.width, r.height) / 2)
    // Corner centres and the quadrant each one sweeps, counter-clockwise from bottom-right.
    let corners: [(CGPoint, CGFloat)] = [
        (CGPoint(x: r.maxX - e, y: r.minY + e), -.pi / 2),
        (CGPoint(x: r.maxX - e, y: r.maxY - e), 0),
        (CGPoint(x: r.minX + e, y: r.maxY - e), .pi / 2),
        (CGPoint(x: r.minX + e, y: r.minY + e), .pi),
    ]
    let steps = 48
    for (k, (c, start)) in corners.enumerated() {
        for i in 0...steps {
            let t = start + CGFloat(i) / CGFloat(steps) * .pi / 2
            let ct = cos(t), st = sin(t)
            let p = CGPoint(x: c.x + e * copysign(pow(abs(ct), 2 / n), ct),
                            y: c.y + e * copysign(pow(abs(st), 2 / n), st))
            k == 0 && i == 0 ? path.move(to: p) : path.addLine(to: p)
        }
    }
    path.closeSubpath()
    return path
}

/// A specular rim: a gradient painted inside `path`, `width` deep, brightest
/// where light hits (top-left) and again faintly where it exits (bottom-right).
func rim(_ g: CGContext, _ path: CGPath, width: CGFloat, strength: CGFloat) {
    let r = path.boundingBox
    g.saveGState()
    g.addPath(path); g.clip()
    g.addPath(path.copy(strokingWithWidth: width * 2, lineCap: .round, lineJoin: .round, miterLimit: 1))
    g.clip()
    g.drawLinearGradient(gradient([
        (0.00, rgb(1, 1, 1, 1.00 * strength)),
        (0.30, rgb(1, 1, 1, 0.30 * strength)),
        (0.50, rgb(1, 1, 1, 0.00)),
        (0.75, rgb(1, 1, 1, 0.05 * strength)),
        (1.00, rgb(1, 1, 1, 0.60 * strength)),
    ]), start: CGPoint(x: r.minX, y: r.maxY), end: CGPoint(x: r.maxX, y: r.minY), options: [])
    g.restoreGState()
}

func bitmap(_ px: Int) -> CGContext {
    CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// The coloured backdrop the glass sits on: a vivid diagonal gradient with
/// two soft glows so the frosted tiles have colour variation to pick up.
func backdrop(_ g: CGContext, _ box: CGRect) {
    g.drawLinearGradient(gradient([
        (0.0, rgb(0.13, 0.22, 0.86)),
        (0.5, rgb(0.50, 0.28, 0.96)),
        (1.0, rgb(1.00, 0.42, 0.62)),
    ]), start: CGPoint(x: box.minX, y: box.minY), end: CGPoint(x: box.maxX, y: box.maxY), options: [])
    let glows: [(CGPoint, CGFloat, CGColor)] = [
        (CGPoint(x: box.minX + box.width * 0.15, y: box.minY + box.height * 0.10), 0.65, rgb(0.20, 0.75, 1.00, 0.85)),
        (CGPoint(x: box.minX + box.width * 0.90, y: box.minY + box.height * 0.95), 0.55, rgb(1.00, 0.62, 0.45, 0.75)),
    ]
    for (c, radius, color) in glows {
        g.drawRadialGradient(gradient([(0, color), (1, color.copy(alpha: 0)!)]),
                             startCenter: c, startRadius: 0, endCenter: c, endRadius: box.width * radius, options: [])
    }
}

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    // macOS icon grid: 824/1024 art box centred in the canvas.
    let inset = s * 100 / 1024
    let box = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let tile = squircle(box, corner: box.width * 0.34)

    // Backdrop on its own, plus a frosted copy for the glass to show.
    let bgCtx = bitmap(px)
    backdrop(bgCtx, box)
    let bg = bgCtx.makeImage()!
    let frosted: CGImage = {
        let input = CIImage(cgImage: bg)
        let blurred = input.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(s) * 0.035)
            .cropped(to: input.extent)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.35, kCIInputBrightnessKey: 0.10,
            ])
        return ci.createCGImage(blurred, from: input.extent)!
    }()

    let g = bitmap(px)
    let full = CGRect(x: 0, y: 0, width: s, height: s)

    // Tile with a soft drop shadow.
    g.saveGState()
    g.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: rgb(0, 0, 0, 0.35))
    g.addPath(tile); g.setFillColor(rgb(0.3, 0.3, 0.8)); g.fillPath()
    g.restoreGState()
    g.saveGState()
    g.addPath(tile); g.clip()
    g.draw(bg, in: full)
    g.restoreGState()

    // 3×3 grid of glass tiles.
    let cell = box.width * 0.215, gap = box.width * 0.062
    let total = cell * 3 + gap * 2
    let origin = CGPoint(x: box.midX - total / 2, y: box.midY - total / 2)
    let lineScale = max(s / 1024, 0.5 / 16) // keep rims visible at 16 px
    for r in 0..<3 {
        for c in 0..<3 {
            let rect = CGRect(x: origin.x + CGFloat(c) * (cell + gap), y: origin.y + CGFloat(r) * (cell + gap),
                              width: cell, height: cell)
            let glass = squircle(rect, corner: cell * 0.42)

            // Depth: a soft shadow cast onto the backdrop.
            g.saveGState()
            g.addPath(tile); g.clip()
            g.setShadow(offset: CGSize(width: 0, height: -s * 0.010), blur: s * 0.022, color: rgb(0.05, 0.02, 0.25, 0.40))
            g.addPath(glass); g.setFillColor(rgb(1, 1, 1, 0.01)); g.fillPath()
            g.restoreGState()

            // Body: frosted backdrop, a milky fill, and a top-down sheen.
            g.saveGState()
            g.addPath(glass); g.clip()
            g.draw(frosted, in: full)
            g.setFillColor(rgb(1, 1, 1, 0.22)); g.fill(rect)
            g.drawLinearGradient(gradient([
                (0.0, rgb(1, 1, 1, 0.55)), (0.5, rgb(1, 1, 1, 0.08)), (0.8, rgb(1, 1, 1, 0)),
                (1.0, rgb(0.25, 0.10, 0.55, 0.18)),
            ]), start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
            g.restoreGState()

            rim(g, glass, width: 7 * lineScale, strength: 1)
        }
    }

    // Outer rim and a broad highlight across the top of the tile.
    g.saveGState()
    g.addPath(tile); g.clip()
    g.drawLinearGradient(gradient([(0, rgb(1, 1, 1, 0.18)), (1, rgb(1, 1, 1, 0))]),
                         start: CGPoint(x: box.midX, y: box.maxY), end: CGPoint(x: box.midX, y: box.midY), options: [])
    g.restoreGState()
    rim(g, tile, width: 7 * lineScale, strength: 0.85)

    let rep = NSBitmapImageRep(cgImage: g.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try draw(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try draw(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
