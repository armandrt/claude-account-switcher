import SwiftUI
import SwitcherCore

/// The panel: a scrolling list of rows and a fixed footer.  Every control in it
/// wears a word — the panel has no icon a pointer has to guess at.
struct MenuContentView: View {
    @ObservedObject var model: AppModel
    /// `ImageRenderer` draws no LazyVStack inside a ScrollView — a lazy container
    /// only builds its rows when a live scroll view asks — so the screenshot
    /// renderer asks for an eager list of exactly the same rows.
    var isRendering = false

    static let width: CGFloat = 400
    /// Beyond this the list scrolls; about seven rows are visible.
    static let maxListHeight: CGFloat = 480

    @State private var expanded: String?
    @State private var showHelp = false
    @State private var showAdd = false
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // A confirmation takes the panel over rather than stacking on the list.
            if model.isConfirming {
                confirmation
            } else {
                list
            }
            footer
        }
        .frame(width: Self.width)
    }
}

// MARK: - The list

extension MenuContentView {
    @ViewBuilder private var list: some View {
        if showHelp { help }
        if model.actionError != nil {
            errorBanner
        }
        if model.rows.isEmpty {
            empty
        } else {
            eagerWhenRendering {
                VStack(spacing: 2) {
                    ForEach(model.rows) { row in
                        rowView(row)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 8)
            }
            // The NSPanel is sized from this view's fitting size; a flexible
            // scroll view would collapse it.
            .frame(height: isRendering ? nil : listHeight)
            .scrollIndicators(.automatic)
        }
    }

    /// Rows are summed, not counted, and an open row is summed with its numbers:
    /// the list asks each row how tall it is rather than guessing at a figure.
    private var listHeight: CGFloat {
        var wanted: CGFloat = 12
        for row in model.rows {
            // A row being renamed or removed shows that instead of its numbers.
            let inline = model.renaming == row.name || model.removing == row.name
            wanted += AccountRowView.height(
                for: row,
                expanded: !inline && expanded == row.name,
                hasUnstoredTokens: model.unstoredSlots.contains(row.name)) + 2
        }
        return min(max(wanted, AccountRowView.baseHeight), Self.maxListHeight)
    }

    /// One row, built in its own function: assembled inline it is a single
    /// expression with twenty arguments, which the type-checker gives up on.
    @ViewBuilder
    private func rowView(_ row: AccountRow) -> some View {

                AccountRowView(
                    row: row,
                    isRendering: isRendering,
                    isBusy: model.busySlot == row.name,
                    hasUnstoredTokens: model.unstoredSlots.contains(row.name),
                    isExpanded: expanded == row.name,
                    isRenaming: model.renaming == row.name,
                    isRemoving: model.removing == row.name,
                    progress: model.sweepProgress[row.name]
                        ?? (model.switchingTo == row.name ? "switching…" : nil),
                    onSwitch: {
                        model.switchTo(row.name,
                                       showPlan: NSEvent.modifierFlags.contains(.option))
                    },
                    onSwitchShowingSteps: { model.requestSwitch(to: row.name) },
                    onRefresh: { model.refreshCredentials(for: row.name) },
                    onCapture: { model.requestCapture(as: row.name) },
                    onRetryStore: { model.retryStoringTokens(for: row.name) },
                    onRepair: { model.beginRepair(of: row.name) },
                    onToggleDetail: {
                        withAnimation(.easeOut(duration: 0.18)) {
                            expanded = expanded == row.name ? nil : row.name
                        }
                    },
                    onRenameBegin: { model.beginRename(of: row.name) },
                    onRename: { model.rename(row.name, to: $0) },
                    onRenameCancel: { model.cancelRename() },
                    onRemoveAsk: { model.askToRemove(row.name) },
                    onRemoveConfirm: { model.confirmRemove() },
                    onRemoveCancel: { model.cancelRemove() },
                    // Only a name this list knows is a reorder; anything else
                    // dragged over the panel is refused rather than swallowed.
            onDrop: { dragged in
                        // A click that wobbled into a drag lands back on its
                        // own row: taken, and nothing moves.
                        guard dragged != row.name else { return true }
                        guard model.rows.contains(where: { $0.name == dragged })
                        else { return false }
                        withAnimation(.easeOut(duration: 0.18)) {
                            model.move(dragged, onto: row.name)
                        }
                        return true
                    })
    }

    /// The same rows, in a scroll view for the panel and in a plain stack for a
    /// rendered picture.
    @ViewBuilder
    private func eagerWhenRendering<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if isRendering {
            content()
        } else {
            ScrollView(.vertical) { content() }
        }
    }

    private var empty: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 5) {
                Text("No accounts yet").font(.system(size: 13, weight: .medium))
                Button("Add an account") {
                    withAnimation(.easeOut(duration: 0.15)) { showAdd = true }
                }
                .buttonStyle(ChipButtonStyle(kind: .tinted(.accentColor)))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    /// Opt-in, and only what is true: the panel's own controls say what they do.
    private var help: some View {
        VStack(alignment: .leading, spacing: 5) {
            legend("Click", "switch to that account")
            legend("⌥-click", "see the steps first")
            legend("Drag", "reorder the list")
            legend("More", "renew, capture, rename, remove")
            legend("Right-click", "the same, anywhere on a row")
            HStack(spacing: 6) {
                Text("Gauges").font(.system(size: 11, weight: .medium))
                    .frame(width: 78, alignment: .leading)
                swatch(Color(nsColor: .systemGreen))
                swatch(Color(nsColor: .systemYellow))
                swatch(Color(nsColor: .systemOrange))
                swatch(Color(nsColor: .systemRed))
                Text("quota used · colour by what is left").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func swatch(_ colour: Color) -> some View {
        Capsule().fill(Palette.fill(colour)).frame(width: 16, height: 6)
    }

    private func legend(_ term: String, _ meaning: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(term).font(.system(size: 11, weight: .medium))
                .frame(width: 78, alignment: .leading)
            Text(meaning).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What went wrong, and a way to put it away: an error that can only be
    /// cleared by trying something else is a message with nowhere to go.
    private var errorBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(nsColor: .systemRed))
            Text(model.actionError ?? "")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Dismiss") { model.actionError = nil }
                .buttonStyle(ChipButtonStyle())
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(nsColor: .systemRed).opacity(0.12)))
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }
}

// MARK: - Confirmations

extension MenuContentView {
    @ViewBuilder private var confirmation: some View {
        if let login = model.login {
            LoginView(state: login, model: model)
        }
        if let plan = model.pendingSwitch {
            SwitchConfirmView(plan: plan, isBusy: model.busySlot != nil,
                              onConfirm: { model.confirmSwitch() },
                              onCancel: { model.cancelSwitch() })
        }
        if let plan = model.pendingCapture {
            CaptureConfirmView(plan: plan, isBusy: model.busySlot != nil,
                               onConfirm: { model.confirmCapture() },
                               onCancel: { model.cancelCapture() })
        }
        if model.actionError != nil {
            errorBanner
        }
    }
}

// MARK: - Footer

extension MenuContentView {
    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 1)
            VStack(alignment: .leading, spacing: 8) {
                if showAdd { addAccount }
                refreshAll
                if let report = model.sweepReport { self.report(report) }
                controls
                if let status = model.policyStatus { armed(status) }
                if let note = model.mode.sideNote {
                    Text(note).font(.system(size: 10)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                logLines
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .background(Color.primary.opacity(0.035))
    }

    /// The second footer line: every one of them a word.
    private var controls: some View {
        HStack(spacing: 8) {
            Picker("Mode", selection: $model.mode) {
                ForEach(SwitchMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .font(.system(size: 11))
            .fixedSize()
            .help(model.mode == .manual ? "Nothing switches on its own"
                  : "May switch on its own")
            Button(showAdd ? "Cancel" : "Add") {
                withAnimation(.easeOut(duration: 0.15)) { showAdd.toggle() }
            }
            .buttonStyle(ChipButtonStyle(kind: showAdd ? .neutral : .tinted(.accentColor)))
            .help("Add an account")
            Spacer(minLength: 4)
            Button("Reload") { Task { await model.reloadNow() } }
                .buttonStyle(ChipButtonStyle())
                .help("Read the live account's quota now")
            Button(showHelp ? "Hide help" : "Help") {
                withAnimation(.easeOut(duration: 0.15)) { showHelp.toggle() }
            }
            .buttonStyle(ChipButtonStyle())
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(ChipButtonStyle())
        }
    }

    @ViewBuilder private var refreshAll: some View {
        if model.sweepLine != nil {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.55).frame(width: 12, height: 12)
                Text(model.sweepLine ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Stop") { model.stopRefreshAll() }
                    .buttonStyle(ChipButtonStyle())
            }
        } else {
            HStack(spacing: 8) {
                Button("Refresh all") { model.refreshAll() }
                    .buttonStyle(ChipButtonStyle())
                    .disabled(model.busySlot != nil)
                    .help("Renew every expired account now")
                Spacer(minLength: 4)
                LaunchAtLoginToggle(login: model.launchAtLogin)
            }
        }
    }

    /// What the sweep did, until dismissed: the count, then only what is still wrong.
    private func report(_ report: SweepReport) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(report.headline)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(report.stopped == nil ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Dismiss") { model.dismissSweepReport() }
                    .buttonStyle(ChipButtonStyle())
            }
            ForEach(report.lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.05)))
    }

    /// One line under the picker: that the app may switch on its own.  What it is
    /// doing about it right now is a hover, not a paragraph.
    @ViewBuilder private func armed(_ status: PolicyStatus) -> some View {
        let line = HStack(spacing: 5) {
            Image(systemName: status.isHolding ? "bolt.slash.fill" : "bolt.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(status.headline)
                .font(.system(size: 10.5, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(status.isHolding ? Color.secondary : Color.orange)
        if let detail = status.detail {
            line.help(detail)
        } else {
            line
        }
    }

    /// The last log line, with Undo beside it while a switch can be taken back.
    @ViewBuilder private var logLines: some View {
        let entries = model.log.entries
        if let first = entries.first {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(Format.clock.string(from: first.at)) \(first.text)")
                        .font(.system(size: 10))
                        .foregroundStyle(first.kind == .failed ? Color.red : Color.secondary)
                        .lineLimit(showLog ? 3 : 1)
                        .truncationMode(.tail)
                    if let offer = model.undo {
                        Button("Undo") { model.undoSwitch() }
                            .buttonStyle(ChipButtonStyle(kind: .tinted(.accentColor)))
                            .disabled(model.busySlot != nil || model.sweepLine != nil)
                            .help("Back to \(offer.from)")
                    }
                    Spacer(minLength: 2)
                    if entries.count > 1 {
                        Button(showLog ? "Hide" : "History") {
                            withAnimation(.easeOut(duration: 0.15)) { showLog.toggle() }
                        }
                        .buttonStyle(ChipButtonStyle())
                    }
                }
                if showLog {
                    ForEach(entries.dropFirst().prefix(6)) { entry in
                        Text("\(Format.clock.string(from: entry.at)) \(entry.text)")
                            .font(.system(size: 10))
                            .foregroundStyle(entry.kind == .failed
                                             ? Color.red : Color.secondary.opacity(0.7))
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private var addAccount: some View {
        HStack(spacing: 6) {
            TextField("name", text: $model.captureName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .onSubmit { if !model.captureName.isEmpty { model.beginAddAccount() } }
            Button("Sign in…") { model.beginAddAccount() }
                .controlSize(.small)
                .disabled(model.captureName.isEmpty)
            Button("Capture") { model.requestCapture(as: model.captureName) }
                .controlSize(.small)
                .disabled(model.captureName.isEmpty || model.busySlot != nil)
                .help("Store the login you are using now")
        }
        .padding(.bottom, 2)
    }
}
