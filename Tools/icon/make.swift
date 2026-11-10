// Draws the Undertow icon (a U whose written half is solid and whose coming half is ghost, on a
// persimmon tile) and the matching menu-bar glyph.  Run: swift Tools/icon/make.swift
import AppKit

let tileColor: (CGFloat, CGFloat, CGFloat) = (0.93, 0.34, 0.14)
let inkColor: (CGFloat, CGFloat, CGFloat) = (1, 0.97, 0.93)
func col(_ c: (CGFloat, CGFloat, CGFloat), _ a: CGFloat = 1, _ k: CGFloat = 1) -> CGColor {
    CGColor(red: min(1, c.0 * k), green: min(1, c.1 * k), blue: min(1, c.2 * k), alpha: a)
}

/// The mark, in a 1024 box. `weight` is the stroke width; small sizes get a heavier one.
func uPaths() -> (written: CGPath, coming: CGPath) {
    let l = CGMutablePath()
    l.move(to: CGPoint(x: 342, y: 712)); l.addLine(to: CGPoint(x: 342, y: 496))
    l.addArc(center: CGPoint(x: 512, y: 496), radius: 170, startAngle: .pi, endAngle: 1.5 * .pi, clockwise: false)
    let r = CGMutablePath()
    r.move(to: CGPoint(x: 512, y: 326))
    r.addArc(center: CGPoint(x: 512, y: 496), radius: 170, startAngle: 1.5 * .pi, endAngle: 2 * .pi, clockwise: false)
    r.addLine(to: CGPoint(x: 682, y: 712))
    return (l, r)
}

func bitmap(_ px: Int, _ body: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let g = NSGraphicsContext.current!.cgContext
    g.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    body(g)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func appIcon(_ px: Int) -> NSBitmapImageRep {
    bitmap(px) { g in
        let small = px <= 64
        let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.28))
        g.addPath(shape); g.setFillColor(col(tileColor)); g.fillPath()
        g.restoreGState()
        g.saveGState(); g.addPath(shape); g.clip()
        // One colour, lit from above: a lightness shift, never a hue shift.
        let lit = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [col(tileColor, 1, 1.12), col(tileColor, 1, 0.9)] as CFArray, locations: [0, 1])!
        g.drawLinearGradient(lit, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
        g.restoreGState()

        let (written, coming) = uPaths()
        let w: CGFloat = small ? 132 : 116
        g.setLineCap(.round); g.setLineJoin(.round); g.setLineWidth(w)
        g.addPath(coming); g.setStrokeColor(col(inkColor, small ? 0.42 : 0.36)); g.strokePath()
        g.saveGState()
        if !small { g.setShadow(offset: CGSize(width: 0, height: -8), blur: 16, color: CGColor(gray: 0, alpha: 0.22)) }
        g.addPath(written); g.setStrokeColor(col(inkColor)); g.strokePath()
        g.restoreGState()

        g.addPath(CGPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184.5, cornerHeight: 184.5, transform: nil))
        g.setStrokeColor(CGColor(gray: 1, alpha: 0.14)); g.setLineWidth(3); g.strokePath()
    }
}

/// Template image: black with alpha only; the system tints it for light/dark menu bars.
func menuGlyph(_ px: Int) -> NSBitmapImageRep {
    bitmap(px) { g in
        // Fill the box: the U spans 284...740 in the 1024 design; scale it up around the centre.
        g.translateBy(x: 512, y: 512); g.scaleBy(x: 1.75, y: 1.75); g.translateBy(x: -512, y: -519)
        let (written, coming) = uPaths()
        g.setLineCap(.round); g.setLineJoin(.round); g.setLineWidth(96)
        g.addPath(coming); g.setStrokeColor(CGColor(gray: 0, alpha: 0.38)); g.strokePath()
        g.addPath(written); g.setStrokeColor(CGColor(gray: 0, alpha: 1)); g.strokePath()
    }
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let res = root.appendingPathComponent("Resources")
let set = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
func png(_ r: NSBitmapImageRep, _ u: URL) throws { try r.representation(using: .png, properties: [:])!.write(to: u) }
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    try png(appIcon(pt * scale), set.appendingPathComponent("icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", res.appendingPathComponent("AppIcon.icns").path]
try p.run(); p.waitUntilExit()
try png(menuGlyph(18), res.appendingPathComponent("MenuBarIcon.png"))
try png(menuGlyph(36), res.appendingPathComponent("MenuBarIcon@2x.png"))
try png(appIcon(1024), root.appendingPathComponent("build/icon-preview.png"))
print("wrote Resources/AppIcon.icns and MenuBarIcon")
