// Renders Resources/AppIcon.icns.
//
//     swift Scripts/make-icon.swift Resources/AppIcon.icns
//
// The icon is a BSP layout of three windows on graphite, the focused one lit.

import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// Fills `path` with a gradient running from the top of `rect` to its bottom.
func fill(_ context: CGContext, _ path: CGPath, _ colors: [CGColor], over rect: CGRect) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
    context.restoreGState()
}

func render(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
        guard let context = NSGraphicsContext.current?.cgContext else { return false }
        context.scaleBy(x: size / 1024, y: size / 1024)

        // The macOS icon grid: an 824-point squircle centred on a 1024 canvas.
        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 12), blur: 26, color: CGColor(gray: 0, alpha: 0.32))
        context.addPath(shape)
        context.setFillColor(color(0x1D1F24))
        context.fillPath()
        context.restoreGState()
        fill(context, shape, [color(0x4A4E57), color(0x1D1F24)], over: body)

        // Three windows: one on the left, two stacked on the right, the lower one focused.
        let area = body.insetBy(dx: 150, dy: 160)
        let gap: CGFloat = 30, radius: CGFloat = 40
        let left = CGRect(x: area.minX, y: area.minY, width: (area.width - gap) / 2, height: area.height)
        let top = CGRect(x: left.maxX + gap, y: area.minY, width: left.width, height: (area.height - gap) / 2)
        let bottom = CGRect(x: top.minX, y: top.maxY + gap, width: top.width, height: top.height)
        let glass = [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0.16)]
        for (window, colors) in [(left, glass), (top, glass), (bottom, [color(0xFFFFFF), color(0xE9ECF1)])] {
            let path = CGPath(roundedRect: window, cornerWidth: radius, cornerHeight: radius, transform: nil)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: CGColor(gray: 0, alpha: 0.3))
            context.addPath(path)
            context.setFillColor(colors[1])
            context.fillPath()
            context.restoreGState()
            fill(context, path, colors, over: window)
            context.addPath(CGPath(roundedRect: window.insetBy(dx: 1.5, dy: 1.5), cornerWidth: radius - 1.5, cornerHeight: radius - 1.5, transform: nil))
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.2))
            context.setLineWidth(3)
            context.strokePath()
        }

        // A faint rim, so the icon keeps its shape on a dark Dock.
        context.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 184, cornerHeight: 184, transform: nil))
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.16))
        context.setLineWidth(4)
        context.strokePath()
        return true
    }
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for multiplier in [1, 2] {
        let pixels = CGFloat(base * multiplier)
        let image = render(size: pixels)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("could not render \(base)@\(multiplier)x") }
        let name = multiplier == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try png.write(to: iconset.appendingPathComponent(name))
    }
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output]
try process.run()
process.waitUntilExit()
print(process.terminationStatus == 0 ? "Wrote \(output)" : "iconutil failed")
