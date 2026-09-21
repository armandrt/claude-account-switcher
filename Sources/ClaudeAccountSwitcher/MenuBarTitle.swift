import AppKit
import SwitcherCore

/// The menu bar item: the mark alone, with a severity dot when something is wrong.
///
/// A logo-sized item cannot be pushed off a crowded bar, so the readout lives in
/// the tooltip and the panel instead.  Without a dot the image is a template and
/// macOS inks it for the bar; with a dot it must not be, or the dot loses its colour.
enum MenuBarTitle {
    static let markSide: CGFloat = 16
    static let horizontalPadding: CGFloat = 4
    static let height: CGFloat = 18
    static var width: CGFloat { markSide + horizontalPadding * 2 }
    static let dotDiameter: CGFloat = 5

    /// The severity dot, or `nil` when there is nothing to say.
    static func dotColor(for tone: LabelTone) -> NSColor? {
        switch tone {
        case .red: return .systemRed
        case .amber: return .systemOrange
        case .normal: return nil
        }
    }

    /// The readout the tooltip and the panel's first line show.
    static func label(for row: AccountRow?, now: Date = Date()) -> MenuBarLabel {
        guard let row else { return .noAccount }
        return row.label(now: now)
    }

    /// Hover text: the whole readout, with its age when it has one.
    static func tooltip(for row: AccountRow?, now: Date = Date()) -> String {
        label(for: row, now: now).text
    }

    static func image(for row: AccountRow?, now: Date = Date()) -> NSImage {
        let dot = dotColor(for: label(for: row, now: now).tone)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            let markRect = CGRect(x: horizontalPadding, y: (rect.height - markSide) / 2,
                                  width: markSide, height: markSide)
            // A template ignores its ink; a real image takes the bar's own label colour.
            context.setFillColor(dot == nil ? NSColor.black.cgColor : NSColor.labelColor.cgColor)
            context.addPath(ClaudeMark.cgPath(in: markRect))
            context.fillPath()

            if let dot {
                // Top-right, with a hole punched behind it so it reads as a dot.
                let diameter = dotDiameter
                let origin = CGPoint(x: rect.maxX - diameter - 1, y: rect.maxY - diameter - 1)
                let circle = CGRect(origin: origin, size: CGSize(width: diameter, height: diameter))
                context.setBlendMode(.clear)
                context.fillEllipse(in: circle.insetBy(dx: -1, dy: -1))
                context.setBlendMode(.normal)
                context.setFillColor(dot.cgColor)
                context.fillEllipse(in: circle)
            }
            return true
        }
        image.isTemplate = dot == nil
        return image
    }
}
