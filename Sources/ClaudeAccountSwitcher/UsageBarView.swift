import SwiftUI
import SwitcherCore

/// One gauge: a word and a percentage over a capsule filled with what is USED —
/// the convention Claude Code uses, so the two panels read the same. Colour still
/// warns by how little is left.
/// The gauges on a row share their width, so the words and the numbers read as
/// columns down the list and need no legend.
struct UsageBarView: View {
    let bar: QuotaBar
    /// Cached or stale numbers are drawn back a little: the panel never pretends
    /// an old reading is a new one.
    var isStale = false

    static let trackHeight: CGFloat = 7
    static let labelHeight: CGFloat = 14
    /// Word and number, a gap, then the capsule.
    static var height: CGFloat { labelHeight + 3 + trackHeight }

    private var colour: Color { Palette.level(bar.fraction, tone: bar.tone) }

    var body: some View {
        // No reset time, no hover text: a window that has just refilled has none.
        if let resetsAt = bar.resetsAt {
            content.help("\(bar.label) \(Format.countdown(to: resetsAt))")
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(bar.label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                // Every window says when it comes back, beside its own name: one
                // countdown in the corner left the other windows to guesswork.
                if let resetsAt = bar.resetsAt {
                    Text("· \(Format.short(to: resetsAt))")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer(minLength: 4)
                Text(bar.text)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(Palette.number(bar.fraction, tone: bar.tone))
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(height: Self.labelHeight)
            track
        }
        .opacity(isStale ? 0.62 : 1)
        .animation(.easeOut(duration: 0.3), value: bar.fraction)
    }

    private var track: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.085))
                if let filled = bar.filled, filled > 0 {
                    Capsule()
                        .fill(Palette.fill(colour))
                        // 3 pt minimum so 1% used is visible rather than rounding away.
                        .frame(width: max(3, proxy.size.width * min(1, max(0, filled))))
                        .shadow(color: colour.opacity(0.35), radius: 1.5, y: 0.5)
                }
            }
        }
        .frame(height: Self.trackHeight)
    }
}

/// The third gauge: a model-scoped window, on one line, named after the model and
/// the widest bar on the row.
struct ModelBarView: View {
    let bar: QuotaBar
    var isStale = false

    static let height: CGFloat = 15
    static let labelWidth: CGFloat = 96
    static let trackHeight: CGFloat = 6

    /// The same ramp as the two gauges above it; it was judged by the server's
    /// severity flag alone and drew grey at 77% left while they drew green.
    private var colour: Color { Palette.level(bar.fraction, tone: bar.tone) }

    var body: some View {
        if let resetsAt = bar.resetsAt {
            content.help("\(bar.label) \(Format.countdown(to: resetsAt))")
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Text(bar.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                if let resetsAt = bar.resetsAt {
                    Text("· \(Format.short(to: resetsAt))")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .frame(width: Self.labelWidth, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.085))
                    if let filled = bar.filled, filled > 0 {
                        Capsule()
                            .fill(Palette.fill(colour))
                            .frame(width: max(3, proxy.size.width * min(1, max(0, filled))))
                    }
                }
            }
            .frame(height: Self.trackHeight)
            Text(bar.text)
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(Palette.number(bar.fraction, tone: bar.tone))
                .fixedSize()
        }
        .frame(height: Self.height)
        .opacity(isStale ? 0.62 : 1)
    }
}
