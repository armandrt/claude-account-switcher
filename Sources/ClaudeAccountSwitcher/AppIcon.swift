import CoreGraphics
import Foundation
import ImageIO
import SwitcherCore
import UniformTypeIdentifiers

/// The app icon, drawn from the same vector mark the menu bar wears, so no
/// artwork is committed: `scripts/make-app.sh` runs the built binary with
/// `--render-iconset <dir>` and hands the PNGs to `iconutil`.
public enum AppIcon {
    static let flag = "--render-iconset"

    /// The ten pixel sizes an `.iconset` holds, under the names `iconutil` looks for.
    static let members: [(name: String, pixels: Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]

    /// Renders and exits when the flag is there, returns when it is not.  Called
    /// from main.swift before NSApplication exists: rendering never starts the
    /// app, shows a status item or touches the keychain.
    public static func renderIfAsked(_ arguments: [String] = CommandLine.arguments) {
        guard let index = arguments.firstIndex(of: flag) else { return }
        guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
            fail("\(flag) needs a directory to write the PNGs into")
        }
        let directory = URL(fileURLWithPath: arguments[index + 1])
        do {
            try writeIconset(to: directory)
        } catch {
            fail("\(error.localizedDescription)")
        }
        print("rendered \(members.count) icons into \(directory.path)")
        exit(0)
    }

    public static func writeIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for member in members {
            guard let image = draw(pixels: member.pixels) else {
                throw Failure("could not draw the icon at \(member.pixels)px")
            }
            let url = directory.appendingPathComponent(member.name + ".png")
            guard let sink = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw Failure("could not create \(url.path)")
            }
            CGImageDestinationAddImage(sink, image, nil)
            guard CGImageDestinationFinalize(sink) else {
                throw Failure("could not write \(url.path)")
            }
        }
    }

    struct Failure: LocalizedError {
        let text: String
        init(_ text: String) { self.text = text }
        var errorDescription: String? { text }
    }

    // MARK: - The drawing

    /// The plate: Claude's clay, lit from the top.
    private static let plateTop = CGColor(srgbRed: 0.910, green: 0.565, blue: 0.424, alpha: 1)
    private static let plateBottom = CGColor(srgbRed: 0.725, green: 0.325, blue: 0.204, alpha: 1)
    /// One flat tone where a gradient would only smear: 16 and 32 px.
    private static let plateFlat = CGColor(srgbRed: 0.831, green: 0.443, blue: 0.318, alpha: 1)
    private static let ink = CGColor(srgbRed: 0.992, green: 0.969, blue: 0.945, alpha: 1)

    /// Fewer, stouter blades as the canvas shrinks: the eleven thin ones close
    /// into a blob below 64 px, and eight still do at 16.
    static func shape(forPixels pixels: Int) -> ClaudeMark.Shape {
        if pixels >= 64 { return .menuBar }
        var shape = ClaudeMark.Shape.menuBar
        shape.innerRadius = 0.06
        shape.outerRadius = 0.98
        shape.lengthPattern = [1.0]
        if pixels >= 32 {
            shape.blades = 8
            shape.baseHalfWidth = 0.20
            shape.tipHalfWidth = 0.105
        } else {
            shape.blades = 6
            shape.baseHalfWidth = 0.25
            shape.tipHalfWidth = 0.13
            shape.rotation = .pi / 12
        }
        return shape
    }

    static func draw(pixels: Int) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard pixels > 0, let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        let size = CGFloat(pixels)
        // Below 64 px the shadow margin and the thin blades both cost more than
        // they give, so the small icons are the same idea drawn plainly.
        let detailed = pixels >= 64
        let inset = size * (detailed ? 0.0977 : 0.055)
        let plate = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
        let body = squircle(in: plate)

        context.setAllowsAntialiasing(true)
        if detailed {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -size * 0.014), blur: size * 0.032,
                              color: CGColor(gray: 0, alpha: 0.30))
            context.setFillColor(plateBottom)
            context.addPath(body)
            context.fillPath()
            context.restoreGState()
        }

        context.saveGState()
        context.addPath(body)
        context.clip()
        if detailed, let gradient = CGGradient(colorsSpace: space,
                                               colors: [plateTop, plateBottom] as CFArray,
                                               locations: [0, 1] as [CGFloat]) {
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: plate.midX, y: plate.maxY),
                                       end: CGPoint(x: plate.midX, y: plate.minY),
                                       options: [])
        } else {
            context.setFillColor(plateFlat)
            context.fill(plate)
        }
        context.restoreGState()

        if detailed {
            context.saveGState()
            context.addPath(body)
            context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18))
            context.setLineWidth(size * 0.006)
            context.strokePath()
            context.restoreGState()
        }

        let side = plate.width * (detailed ? 0.60 : 0.76)
        let markRect = CGRect(x: plate.midX - side / 2, y: plate.midY - side / 2,
                              width: side, height: side)
        context.setFillColor(ink)
        context.addPath(ClaudeMark.cgPath(in: markRect, shape: shape(forPixels: pixels)))
        context.fillPath()

        return context.makeImage()
    }

    /// macOS's rounded square is a superellipse, not a rounded rectangle: the
    /// corner never stops curving.  |x|^5 + |y|^5 = 1, sampled.
    private static func squircle(in rect: CGRect, exponent: Double = 5) -> CGPath {
        let path = CGMutablePath()
        let steps = 240
        let radiusX = Double(rect.width) / 2, radiusY = Double(rect.height) / 2
        for step in 0...steps {
            let angle = Double(step) / Double(steps) * 2 * .pi
            let cosine = cos(angle), sine = sin(angle)
            let point = CGPoint(
                x: Double(rect.midX) + radiusX * copysign(pow(abs(cosine), 2 / exponent), cosine),
                y: Double(rect.midY) + radiusY * copysign(pow(abs(sine), 2 / exponent), sine))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("ClaudeAccountSwitcher: \(message)\n".utf8))
        exit(1)
    }
}
