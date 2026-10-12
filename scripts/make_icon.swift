// Draws Relaunch's original app icon (no Apple artwork).
// Usage:
//   swift scripts/make_icon.swift <out.iconset> [style] [light|dark]
//   swift scripts/make_icon.swift <out.png> [style] [light|dark]   # one 1024 px image
// Styles: paper (default), aurora, pages, spectrum.
//
// Style follows macOS 26+ "Liquid Glass": a continuous-corner tile with a lit
// rim, and glass tiles that blur and brighten the colour behind them.
import AppKit
import CoreImage

enum Style: String { case aurora, paper, pages, spectrum }

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "AppIcon.iconset"
let style = Style(rawValue: args.count > 2 ? args[2] : "paper") ?? .paper
let dark = args.count > 3 && args[3] == "dark"

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ci = CIContext()

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

func hsb(_ h: CGFloat, _ s: CGFloat, _ b: CGFloat) -> CGColor {
    NSColor(hue: h, saturation: s, brightness: b, alpha: 1).usingColorSpace(.sRGB)!.cgColor
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

func glows(_ g: CGContext, _ box: CGRect, _ list: [(CGFloat, CGFloat, CGFloat, CGColor)]) {
    for (x, y, radius, color) in list {
        let c = CGPoint(x: box.minX + box.width * x, y: box.minY + box.height * y)
        g.drawRadialGradient(gradient([(0, color), (1, color.copy(alpha: 0)!)]),
                             startCenter: c, startRadius: 0, endCenter: c, endRadius: box.width * radius, options: [])
    }
}

/// The colour the glass sits on.
func backdrop(_ g: CGContext, _ box: CGRect) {
    let bl = CGPoint(x: box.minX, y: box.minY), tr = CGPoint(x: box.maxX, y: box.maxY)
    let top = CGPoint(x: box.midX, y: box.maxY), bottom = CGPoint(x: box.midX, y: box.minY)
    switch (style, dark) {
    case (.aurora, false), (.pages, false):
        g.drawLinearGradient(gradient([
            (0.0, rgb(0.13, 0.22, 0.86)), (0.5, rgb(0.50, 0.28, 0.96)), (1.0, rgb(1.00, 0.42, 0.62)),
        ]), start: bl, end: tr, options: [])
        glows(g, box, [(0.15, 0.10, 0.65, rgb(0.20, 0.75, 1.00, 0.85)),
                       (0.90, 0.95, 0.55, rgb(1.00, 0.62, 0.45, 0.75))])
    case (.aurora, true), (.pages, true):
        g.drawLinearGradient(gradient([
            (0.0, rgb(0.04, 0.06, 0.24)), (0.55, rgb(0.16, 0.07, 0.36)), (1.0, rgb(0.36, 0.08, 0.28)),
        ]), start: bl, end: tr, options: [])
        glows(g, box, [(0.15, 0.10, 0.60, rgb(0.10, 0.45, 0.95, 0.60)),
                       (0.90, 0.95, 0.50, rgb(0.85, 0.30, 0.55, 0.50))])
    case (.paper, false), (.spectrum, false):
        g.drawLinearGradient(gradient([(0, rgb(1, 1, 1)), (1, rgb(0.90, 0.91, 0.95))]),
                             start: top, end: bottom, options: [])
    case (.paper, true):
        g.drawLinearGradient(gradient([(0, rgb(0.20, 0.20, 0.23)), (1, rgb(0.07, 0.07, 0.09))]),
                             start: top, end: bottom, options: [])
    case (.spectrum, true):
        g.drawLinearGradient(gradient([(0, rgb(0.10, 0.12, 0.26)), (1, rgb(0.02, 0.03, 0.09))]),
                             start: top, end: bottom, options: [])
        glows(g, box, [(0.5, 0.5, 0.6, rgb(0.35, 0.30, 0.90, 0.35))])
    }
}

/// One glass tile: a cast shadow, the frosted backdrop showing through, a
/// tint, a top-down sheen and a lit rim. `tint` nil means clear white glass.
func glassTile(_ g: CGContext, _ path: CGPath, clip: CGPath, frosted: CGImage, tint: CGColor?, s: CGFloat, rimWidth: CGFloat) {
    let rect = path.boundingBox
    let full = CGRect(x: 0, y: 0, width: s, height: s)
    let lightBackdrop = !dark && (style == .paper || style == .spectrum)

    g.saveGState()
    g.addPath(clip); g.clip()
    g.setShadow(offset: CGSize(width: 0, height: -s * 0.010), blur: s * 0.022,
                color: lightBackdrop ? rgb(0.15, 0.10, 0.35, 0.22) : rgb(0.02, 0.01, 0.15, dark ? 0.6 : 0.4))
    g.addPath(path); g.setFillColor(rgb(1, 1, 1, 0.01)); g.fillPath()
    g.restoreGState()

    g.saveGState()
    g.addPath(path); g.clip()
    g.draw(frosted, in: full)
    if let tint {
        g.setFillColor(tint.copy(alpha: 0.88)!); g.fill(rect)
    } else {
        g.setFillColor(rgb(1, 1, 1, dark ? 0.16 : 0.22)); g.fill(rect)
    }
    let sheen = tint == nil && dark ? 0.42 : 0.55
    g.drawLinearGradient(gradient([
        (0.0, rgb(1, 1, 1, sheen)), (0.5, rgb(1, 1, 1, 0.08)), (0.8, rgb(1, 1, 1, 0)),
        (1.0, rgb(0.25, 0.10, 0.55, 0.18)),
    ]), start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    g.restoreGState()

    rim(g, path, width: rimWidth, strength: dark && tint == nil ? 0.75 : 1)
}

/// Brand gradient sampled diagonally, for the paper style's tiles.
func brand(_ t: CGFloat) -> CGColor {
    let stops: [(CGFloat, (CGFloat, CGFloat, CGFloat))] = [
        (0.0, (0.20, 0.42, 1.00)), (0.5, (0.56, 0.32, 0.98)), (1.0, (1.00, 0.42, 0.55)),
    ]
    let i = t < 0.5 ? 0 : 1
    let (t0, a) = stops[i], (t1, b) = stops[i + 1]
    let u = (t - t0) / (t1 - t0)
    return rgb(a.0 + (b.0 - a.0) * u, a.1 + (b.1 - a.1) * u, a.2 + (b.2 - a.2) * u)
}

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    // macOS icon grid: 824/1024 art box centred in the canvas.
    let inset = s * 100 / 1024
    let box = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let tile = squircle(box, corner: box.width * 0.34)
    let full = CGRect(x: 0, y: 0, width: s, height: s)
    let lineScale = max(s / 1024, 0.5 / 16) // keep rims visible at 16 px

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

    // Tile with a soft drop shadow.
    g.saveGState()
    g.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: rgb(0, 0, 0, 0.35))
    g.addPath(tile); g.setFillColor(rgb(0.3, 0.3, 0.8)); g.fillPath()
    g.restoreGState()
    g.saveGState()
    g.addPath(tile); g.clip()
    g.draw(bg, in: full)
    g.restoreGState()

    if style == .pages {
        // One large glass page holding a grid of solid tiles, with page dots below.
        let pane = CGRect(x: box.minX + box.width * 0.15, y: box.minY + box.height * 0.25,
                          width: box.width * 0.70, height: box.height * 0.62)
        glassTile(g, squircle(pane, corner: pane.width * 0.24), clip: tile, frosted: frosted, tint: nil,
                  s: s, rimWidth: 8 * lineScale)
        let cell = pane.width * 0.2, gap = pane.width * 0.085
        let total = cell * 3 + gap * 2
        let o = CGPoint(x: pane.midX - total / 2, y: pane.midY - total / 2)
        for r in 0..<3 {
            for c in 0..<3 {
                let rect = CGRect(x: o.x + CGFloat(c) * (cell + gap), y: o.y + CGFloat(r) * (cell + gap),
                                  width: cell, height: cell)
                g.saveGState()
                g.setShadow(offset: CGSize(width: 0, height: -s * 0.004), blur: s * 0.01, color: rgb(0.1, 0.05, 0.3, 0.3))
                g.addPath(squircle(rect, corner: cell * 0.42))
                g.setFillColor(rgb(1, 1, 1, dark ? 0.82 : 0.96)); g.fillPath()
                g.restoreGState()
            }
        }
        let dot = box.width * 0.045, dotGap = box.width * 0.04
        let dotsWidth = dot * 3 + dotGap * 2
        for i in 0..<3 {
            let rect = CGRect(x: box.midX - dotsWidth / 2 + CGFloat(i) * (dot + dotGap),
                              y: box.minY + box.height * 0.115, width: dot, height: dot)
            g.setFillColor(rgb(1, 1, 1, i == 0 ? 0.95 : 0.40)); g.fillEllipse(in: rect)
        }
    } else {
        // 3×3 grid of glass tiles.
        let cell = box.width * 0.215, gap = box.width * 0.062
        let total = cell * 3 + gap * 2
        let origin = CGPoint(x: box.midX - total / 2, y: box.midY - total / 2)
        for r in 0..<3 {
            for c in 0..<3 {
                let rect = CGRect(x: origin.x + CGFloat(c) * (cell + gap), y: origin.y + CGFloat(r) * (cell + gap),
                                  width: cell, height: cell)
                // Diagonal position, 0 at bottom-left to 1 at top-right.
                let t = CGFloat(r + c) / 4
                let tint: CGColor?
                switch style {
                case .paper: tint = brand(t)
                // Hue wheel in reading order, red at top-left to violet at bottom-right.
                case .spectrum: tint = hsb(CGFloat((2 - r) * 3 + c) / 9 * 0.83, 0.72, 1)
                default: tint = nil
                }
                glassTile(g, squircle(rect, corner: cell * 0.42), clip: tile, frosted: frosted, tint: tint,
                          s: s, rimWidth: 7 * lineScale)
            }
        }
    }

    // Outer rim and a broad highlight across the top of the tile.
    g.saveGState()
    g.addPath(tile); g.clip()
    g.drawLinearGradient(gradient([(0, rgb(1, 1, 1, dark ? 0.08 : 0.18)), (1, rgb(1, 1, 1, 0))]),
                         start: CGPoint(x: box.midX, y: box.maxY), end: CGPoint(x: box.midX, y: box.midY), options: [])
    g.restoreGState()
    rim(g, tile, width: 7 * lineScale, strength: dark ? 0.45 : 0.85)

    let rep = NSBitmapImageRep(cgImage: g.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: outPath)
if out.pathExtension == "png" {
    try draw(1024).write(to: out)
} else {
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        try draw(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
        try draw(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
}
