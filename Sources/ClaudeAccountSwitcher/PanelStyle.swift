import SwiftUI
import SwitcherCore

// MARK: - Colour that means something

/// One ramp for every gauge in the panel: green while there is room, yellow past
/// halfway, amber under a quarter, red when a window is nearly gone.
enum Palette {
    /// `normal` is the window's own ink, so a healthy label has no colour in it.
    static func color(for tone: LabelTone, normal: Color) -> Color {
        switch tone {
        case .red: return Color(nsColor: .systemRed)
        case .amber: return Color(nsColor: .systemOrange)
        case .normal: return normal
        }
    }

    /// The gauge colour for a fraction of quota LEFT.  A severity the server
    /// sent can only make it worse, never better: a `critical` window is never
    /// drawn green because our own thresholds happen to be relaxed.
    static func level(_ fraction: Double?, tone: LabelTone = .normal) -> Color {
        guard let fraction else { return Color.secondary.opacity(0.55) }
        var band = Color(nsColor: .systemGreen)
        if fraction < 0.50 { band = Color(nsColor: .systemYellow) }
        if fraction < 0.25 { band = Color(nsColor: .systemOrange) }
        if fraction < 0.10 { band = Color(nsColor: .systemRed) }
        switch tone {
        case .red: return Color(nsColor: .systemRed)
        case .amber: return fraction < 0.25 ? band : Color(nsColor: .systemOrange)
        case .normal: return band
        }
    }

    /// Numbers keep the window's own ink until they are worth looking at.
    static func number(_ fraction: Double?, tone: LabelTone) -> Color {
        guard let fraction else { return .secondary }
        if tone == .red || fraction < 0.10 { return Color(nsColor: .systemRed) }
        if tone == .amber || fraction < 0.25 { return Color(nsColor: .systemOrange) }
        return .primary
    }

    /// A gauge is a gradient, not a flat block: it gives the capsule its shape.
    static func fill(_ colour: Color) -> LinearGradient {
        LinearGradient(colors: [colour.opacity(0.62), colour],
                       startPoint: .leading, endPoint: .trailing)
    }
}

// MARK: - The mark, as a shape

/// The menu bar's mark, drawn in SwiftUI so the live row can wear the same thing
/// the bar is wearing.
struct ClaudeMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(ClaudeMark.cgPath(in: rect))
    }
}

// MARK: - The one small control

/// A word in a capsule.  Every action in a row is one of these or a named item
/// in a menu, so nothing in the panel is an unlabelled glyph.
struct ChipButtonStyle: ButtonStyle {
    enum Kind: Equatable {
        case neutral
        case tinted(Color)
    }

    var kind: Kind = .neutral

    func makeBody(configuration: Configuration) -> some View {
        Chip(configuration: configuration, kind: kind)
    }

    /// Not called `Body`: that name is the style's own associated type.
    private struct Chip: View {
        let configuration: ChipButtonStyle.Configuration
        let kind: Kind
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        private var tint: Color {
            switch kind {
            case .neutral: return .primary
            case .tinted(let colour): return colour
            }
        }

        private var ink: Color {
            switch kind {
            case .neutral: return .secondary
            case .tinted(let colour): return colour
            }
        }

        private var background: Color {
            let base: Double = kind == .neutral ? 0.09 : 0.15
            return tint.opacity(hovering ? base * 1.8 : base)
        }

        var body: some View {
            configuration.label
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(background))
                .contentShape(Capsule())
                .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
                .onHover { hovering = isEnabled && $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

// MARK: - The row's badge

/// A ring of the tightest window's quota with the account's initial inside, or
/// the mark when it is the live login.  It carries no number of its own: it is
/// the same reading the bars under it are drawn from.
struct AccountBadge: View {
    let initial: String
    let fraction: Double?
    let colour: Color
    let isLive: Bool
    var side: CGFloat = 28

    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 3)
            if let fraction, fraction > 0 {
                Circle()
                    .inset(by: 1.5)
                    .trim(from: 0, to: min(1, max(0.03, fraction)))
                    .stroke(colour, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: colour.opacity(0.40), radius: 2)
            }
            centre
        }
        .frame(width: side, height: side)
        .animation(.easeOut(duration: 0.35), value: fraction)
    }

    @ViewBuilder private var centre: some View {
        if isLive {
            ClaudeMarkShape()
                .fill(Color.accentColor)
                .frame(width: side * 0.54, height: side * 0.54)
        } else {
            Text(initial)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}
