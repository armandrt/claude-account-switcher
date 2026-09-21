import CoreGraphics
import Foundation

/// A radial burst of tapered blades, drawn in code so no trademarked artwork
/// ships with the app.  Vector, so it stays crisp at any size.
public enum ClaudeMark {
    /// Blade geometry as fractions of the half-size.  Lengths cycle through a
    /// short pattern so the burst does not look mechanical.
    public struct Shape: Sendable {
        public var blades: Int
        public var innerRadius: CGFloat
        public var outerRadius: CGFloat
        public var baseHalfWidth: CGFloat
        public var tipHalfWidth: CGFloat
        public var lengthPattern: [CGFloat]
        /// Turns the whole burst so no blade sits exactly on the vertical.
        public var rotation: CGFloat

        public static let menuBar = Shape(
            blades: 11,
            innerRadius: 0.08,
            outerRadius: 0.94,
            baseHalfWidth: 0.145,
            tipHalfWidth: 0.072,
            lengthPattern: [1.0, 0.90, 0.97, 0.86, 0.94],
            rotation: .pi / 22)
    }

    public static func cgPath(in rect: CGRect, shape: Shape = .menuBar) -> CGPath {
        let path = CGMutablePath()
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let unit = min(rect.width, rect.height) / 2

        for index in 0..<shape.blades {
            let angle = shape.rotation + (CGFloat(index) / CGFloat(shape.blades)) * 2 * .pi
            let length = shape.lengthPattern[index % shape.lengthPattern.count]
            appendBlade(to: path, centre: centre, angle: angle,
                        inner: shape.innerRadius * unit,
                        outer: shape.outerRadius * length * unit,
                        baseHalfWidth: shape.baseHalfWidth * unit,
                        tipHalfWidth: shape.tipHalfWidth * unit)
        }
        return path
    }

    /// One blade: a rounded base, two straight tapering flanks, a rounded tip.
    private static func appendBlade(to path: CGMutablePath, centre: CGPoint, angle: CGFloat,
                                    inner: CGFloat, outer: CGFloat,
                                    baseHalfWidth: CGFloat, tipHalfWidth: CGFloat) {
        let direction = CGPoint(x: cos(angle), y: sin(angle))
        let base = CGPoint(x: centre.x + direction.x * inner, y: centre.y + direction.y * inner)
        let tip = CGPoint(x: centre.x + direction.x * outer, y: centre.y + direction.y * outer)
        let left = angle + .pi / 2
        let right = angle - .pi / 2

        path.move(to: CGPoint(x: base.x + cos(left) * baseHalfWidth,
                              y: base.y + sin(left) * baseHalfWidth))
        path.addLine(to: CGPoint(x: tip.x + cos(left) * tipHalfWidth,
                                 y: tip.y + sin(left) * tipHalfWidth))
        path.addArc(center: tip, radius: tipHalfWidth, startAngle: left, endAngle: right,
                    clockwise: true)
        path.addLine(to: CGPoint(x: base.x + cos(right) * baseHalfWidth,
                                 y: base.y + sin(right) * baseHalfWidth))
        path.addArc(center: base, radius: baseHalfWidth, startAngle: right, endAngle: left,
                    clockwise: true)
        path.closeSubpath()
    }
}
