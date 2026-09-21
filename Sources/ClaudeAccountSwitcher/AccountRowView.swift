import SwiftUI
import SwitcherCore

/// One account, one row: a ring badge, the name, what is happening on the right,
/// and two gauges under it.  A used-up model adds a third, thinner gauge.
struct AccountRowView: View {
    /// A resting row: 7 + 20 (name line) + 5 + 24 (gauges) + 7.
    static let baseHeight: CGFloat = 63
    static let modelBarHeight: CGFloat = 20
    /// Fixed, so the name can never push what is on the right out of column.
    static let trailingWidth: CGFloat = 140
    static let badgeSide: CGFloat = 28
    static let badgeGap: CGFloat = 9
    static let sidePadding: CGFloat = 10

    static func height(for row: AccountRow) -> CGFloat {
        baseHeight + (row.hasModelBar ? modelBarHeight : 0)
    }

    /// Known before it opens, so the list never has to guess and never clips.
    static func detailHeight(for row: AccountRow, hasUnstoredTokens: Bool) -> CGFloat {
        let lines = row.details(hasUnstoredTokens: hasUnstoredTokens)
        guard !lines.isEmpty else { return 0 }
        let content = lines.reduce(CGFloat(0)) { $0 + ($1.wraps ? 30 : 15) }
            + CGFloat(lines.count - 1) * 3
        return content + 16 + 8
    }

    static func height(for row: AccountRow, expanded: Bool, hasUnstoredTokens: Bool) -> CGFloat {
        height(for: row)
            + (expanded ? detailHeight(for: row, hasUnstoredTokens: hasUnstoredTokens) : 0)
    }

    let row: AccountRow
    /// Set while the panel is drawn to a PNG: `ImageRenderer` paints a draggable
    /// view in its "cannot drop here" state, an artefact of rendering offscreen.
    var isRendering = false
    var isBusy = false
    var hasUnstoredTokens = false
    var isExpanded = false
    /// The row is showing a name field, or its Remove/Cancel pair, instead of itself.
    var isRenaming = false
    var isRemoving = false
    /// One word from a running sweep or switch; while set, the row's own controls step aside.
    var progress: String?
    let onSwitch: () -> Void
    let onSwitchShowingSteps: () -> Void
    let onRefresh: () -> Void
    let onCapture: () -> Void
    let onRetryStore: () -> Void
    let onRepair: () -> Void
    let onToggleDetail: () -> Void
    let onRenameBegin: () -> Void
    let onRename: (String) -> Void
    let onRenameCancel: () -> Void
    let onRemoveAsk: () -> Void
    let onRemoveConfirm: () -> Void
    let onRemoveCancel: () -> Void
    /// The name of the row dropped on this one; false when it is not one of ours.
    let onDrop: (String) -> Bool

    @State private var isHovering = false
    @State private var isDropTarget = false
    @State private var draft = ""

    /// Inactive and usable: the row can be switched to or renewed.
    private var canAct: Bool { !row.slot.isActive && row.slot.health.isUsable && !isLocked }
    /// A CAS_FAKE_ACCOUNTS row has no keychain item: every action would be refused,
    /// so none is offered.
    private var isLocked: Bool { row.isFake }
    private var fix: RowFix? {
        guard !isLocked else { return nil }
        return row.fix(hasUnstoredTokens: hasUnstoredTokens)
    }
    /// An action is already running for this row: a second click would only be refused.
    private var isWorking: Bool { isBusy || progress != nil }
    private var showsMenu: Bool { isHovering && !isWorking }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isRenaming {
                inline { renameField }
            } else if isRemoving {
                inline { removeConfirmation }
            } else {
                // The gestures ride on the resting row alone: a drag inside the
                // rename field is text selection, and the open numbers are not a button.
                resting
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Never swallowed because a sweep or a renewal is running:
                        // the model makes way for a switch rather than refusing it,
                        // and ignores a second click on a switch already under way.
                        // A row that cannot be switched to opens its numbers, so a
                        // click is never a dead end.
                        canAct ? onSwitch() : onToggleDetail()
                    }
                    .modifier(DraggableRow(name: row.name, enabled: !isRendering))
                    // Not while renaming: the field needs its own Cut/Copy/Paste menu.
                    .contextMenu { menu }
                    .help(tooltip)
                if isExpanded { detail }
            }
        }
        .background(background)
        .overlay(dropIndicator)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .modifier(RowDropTarget(enabled: !isRendering, onDrop: onDrop,
                                isTargeted: { isDropTarget = $0 }))
    }

    /// Hover text, for the day a non-activating panel is allowed one: what a
    /// click does, and how old the numbers are when they are not fresh.
    private var tooltip: String {
        let base = canAct ? "Switch to \(row.name)"
            : row.slot.isActive ? "\(row.name) is the live login"
            : "\(row.name): \(row.slot.health.label)"
        guard let age = row.age() else { return base }
        return "\(base) · numbers \(MenuBarLabel.ageText(age))"
    }

    private var resting: some View {
        HStack(spacing: Self.badgeGap) {
            AccountBadge(initial: row.initial,
                         fraction: row.tightestFraction,
                         colour: Palette.level(row.tightestFraction, tone: row.barTone),
                         isLive: row.slot.isActive,
                         side: Self.badgeSide)
                .opacity(row.isStale ? 0.7 : 1)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    nameLine
                    Spacer(minLength: 8)
                    trailing
                }
                .frame(height: 20)
                bars
            }
        }
        .padding(.horizontal, Self.sidePadding)
        .padding(.vertical, 7)
        .frame(height: Self.height(for: row), alignment: .top)
    }

    /// A rename or a removal takes the row over at its own height, so the list never jumps.
    private func inline<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, Self.sidePadding)
            .padding(.vertical, 7)
            .frame(height: Self.height(for: row), alignment: .center)
    }

    private var nameLine: some View {
        HStack(spacing: 5) {
            Text(row.name)
                .font(.system(size: 13, weight: row.slot.isActive ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            if row.slot.isActive { pill("Live", colour: .accentColor) }
            if row.isFake { pill("demo", colour: .secondary) }
        }
    }

    private func pill(_ word: String, colour: Color) -> some View {
        Text(word)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(colour)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(colour.opacity(0.16)))
            .fixedSize()
    }

    /// Bars drawn from a reading a reset has overtaken are estimates until the
    /// next reading lands, and are dimmed to say so.
    private var bars: some View {
        let estimated = row.awaitsPostResetReading()
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .bottom, spacing: 14) {
                ForEach(row.bars.filter { !$0.isModel }) { bar in
                    UsageBarView(bar: bar, isStale: row.isStale || estimated).frame(maxWidth: .infinity)
                }
            }
            ForEach(row.bars.filter(\.isModel)) { bar in
                ModelBarView(bar: bar, isStale: row.isStale || estimated)
            }
        }
        .opacity(estimated ? 0.6 : 1)
        .animation(.easeOut(duration: 0.3), value: estimated)
    }
}

// MARK: - What is happening on the right

extension AccountRowView {
    /// One fixed-width column: the state or the countdown at rest, the menu
    /// under the pointer, and the one fix the row wears at all times.  Nothing
    /// in it moves when the pointer arrives.
    private var trailing: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            ZStack(alignment: .trailing) {
                status.opacity(showsMenu ? 0 : 1)
                moreMenu
                    .opacity(showsMenu ? 1 : 0)
                    .allowsHitTesting(showsMenu)
            }
            if let fix, progress == nil {
                fixButton(fix)
            }
        }
        .frame(width: Self.trailingWidth, height: 20, alignment: .trailing)
        .animation(.easeOut(duration: 0.12), value: showsMenu)
    }

    @ViewBuilder private var status: some View {
        if isWorking {
            HStack(spacing: 5) {
                ProgressView().controlSize(.small).scaleEffect(0.55).frame(width: 12, height: 12)
                Text(progress ?? "working")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else if row.awaitsPostResetReading() {
            // A window reset since the last reading: the bars are estimates until
            // the read the schedule has already queued comes back.
            HStack(spacing: 5) {
                ProgressView().controlSize(.small).scaleEffect(0.55).frame(width: 12, height: 12)
                Text("reset — refreshing")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else if row.slot.health != .ok {
            let tone = Palette.color(for: row.secondaryTone ?? .normal, normal: .secondary)
            HStack(spacing: 4) {
                Circle().fill(tone).frame(width: 5, height: 5)
                Text(row.slot.health.label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(tone)
                    .lineLimit(1)
            }
        } else if row.usage() == nil {
            Text("no reading")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    /// The hover control, and the only one: a word that opens the same named
    /// items the right-click menu holds.  An icon on its own says nothing.
    private var moreMenu: some View {
        Menu {
            menu
        } label: {
            HStack(spacing: 3) {
                Text("More")
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .black))
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.10)))
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func fixButton(_ fix: RowFix) -> some View {
        Button(fix.title) { action(for: fix)() }
            .buttonStyle(ChipButtonStyle(
                kind: .tinted(Palette.color(for: fix.tone, normal: .accentColor))))
            .disabled(isBusy)
            .help(fix.help)
    }

    private func action(for fix: RowFix) -> () -> Void {
        switch fix {
        case .renew: return onRefresh
        case .retrySave: return onRetryStore
        case .login: return onRepair
        }
    }

    /// The actions by name, for the hover menu and the right-click alike.
    @ViewBuilder private var menu: some View {
        if canAct {
            Button("Switch to \(row.name)", action: onSwitch)
            Button("Show the steps first…", action: onSwitchShowingSteps)
        }
        Button(isExpanded ? "Hide the numbers" : "Show the numbers", action: onToggleDetail)
        if canAct {
            Button("Renew the access token", action: onRefresh)
        }
        if !row.slot.isActive && !isLocked {
            Button("Sign in again…", action: onRepair)
        }
        if !isLocked {
            Button("Capture the current login as \(row.name)…", action: onCapture)
        }
        if hasUnstoredTokens {
            Button("Retry saving the renewed tokens", action: onRetryStore)
        }
        if !isLocked {
            Divider()
            Button("Rename…", action: onRenameBegin)
            if !row.slot.isActive {
                Button("Remove…", action: onRemoveAsk)
            }
        }
    }
}

// MARK: - Renaming and removing, in the row's own height

extension AccountRowView {
    private var canRename: Bool {
        !isBusy && !draft.isEmpty && draft != row.name
    }

    private var renameField: some View {
        HStack(spacing: 6) {
            TextField("name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .onSubmit { if canRename { onRename(draft) } }
            Button("Cancel", action: onRenameCancel)
                .controlSize(.small)
                .font(.system(size: 10))
            Button("Rename") { onRename(draft) }
                .controlSize(.small)
                .font(.system(size: 10))
                .disabled(!canRename)
        }
        .onAppear { draft = row.name }
    }

    private var removeConfirmation: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Remove \"\(row.name)\"?")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.slot.email.map { "\($0) — deleted for good" } ?? "deleted for good")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button("Cancel", action: onRemoveCancel)
                .controlSize(.small)
                .font(.system(size: 10))
            Button("Remove", action: onRemoveConfirm)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
                .font(.system(size: 10))
                .disabled(isBusy)
        }
    }
}

// MARK: - Background, and where a drag would land

extension AccountRowView {
    private var background: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(fillColour)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(row.slot.isActive ? 0.26 : 0),
                                  lineWidth: 1))
            .animation(.easeOut(duration: 0.22), value: row.slot.isActive)
    }

    private var fillColour: Color {
        if isDropTarget { return Color.accentColor.opacity(0.14) }
        if row.slot.isActive { return Color.accentColor.opacity(isHovering ? 0.17 : 0.11) }
        return Color.primary.opacity(isHovering ? 0.07 : 0)
    }

    /// A drag says where it would land rather than tinting the whole row, so a
    /// reorder never looks like a click that switched something.
    @ViewBuilder private var dropIndicator: some View {
        if isDropTarget {
            VStack(spacing: 0) {
                Capsule().fill(Color.accentColor).frame(height: 2.5)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - The numbers, when asked for

extension AccountRowView {
    private var detail: some View {
        let lines = row.details(hasUnstoredTokens: hasUnstoredTokens)
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                detailLine(line)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.045)))
        .padding(.leading, Self.sidePadding + Self.badgeSide + Self.badgeGap)
        .padding(.trailing, Self.sidePadding)
        .padding(.bottom, 8)
        .frame(height: Self.detailHeight(for: row, hasUnstoredTokens: hasUnstoredTokens),
               alignment: .top)
    }

    private func detailLine(_ line: RowDetail) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(line.text)
                .font(.system(size: 11))
                .foregroundStyle(Palette.color(for: line.tone, normal: .secondary))
                .lineLimit(line.wraps ? 2 : 1)
                .truncationMode(line.wraps ? .tail : .middle)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let value = line.value {
                Text(value)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(height: line.wraps ? 30 : 15, alignment: .top)
    }
}

/// Drag to reorder, off while the panel is being rendered to an image.
private struct DraggableRow: ViewModifier {
    let name: String
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled { content.draggable(name) } else { content }
    }
}

private struct RowDropTarget: ViewModifier {
    let enabled: Bool
    let onDrop: (String) -> Bool
    let isTargeted: (Bool) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.dropDestination(for: String.self) { names, _ in
                guard let name = names.first else { return false }
                return onDrop(name)
            } isTargeted: { targeted in
                withAnimation(.easeOut(duration: 0.1)) { isTargeted(targeted) }
            }
        } else {
            content
        }
    }
}
