import AppKit
import Combine
import SwiftUI
import SwitcherCore

/// Hosts the panel's content and says when SwiftUI wants a different height.
///
/// The panel is sized to its content and the content changes while it is open — a row's
/// numbers, the legend, the add-account field, the sweep report, a rename — and most of
/// that is view-local state the model never sees.
@MainActor
final class MeasuringHostingView: NSHostingView<AnyView> {
    var onContentChange: (() -> Void)?

    /// Only the invalidation is hooked, never `layout()`: re-measuring lays out, and a
    /// callback from that would measure again for ever.
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onContentChange?()
    }

    required init(rootView: AnyView) { super.init(rootView: rootView) }

    required init?(coder: NSCoder) { fatalError("the panel is built in code, never from a nib") }
}

/// Owns the menu bar item and the panel under it.
@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let panel: MenuPanel
    private let hosting: MeasuringHostingView
    private let container: NSVisualEffectView
    /// One re-measure per turn, and never inside the layout pass that asked for it.
    private var resizeScheduled = false

    private var outsideClick: Any?
    private var workspaceObserver: NSObjectProtocol?
    private var cancellables: Set<AnyCancellable> = []

    /// Our own record of the panel's state.  `NSWindow.isVisible` is false for a
    /// transparent or off-screen window that is still ordered in.
    private(set) var isOpen = false
    private(set) var opens = 0
    private(set) var closes = 0
    /// Set by the self-test: the panel opens off screen and transparent.
    private var panelSuppressed = false

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        panel = MenuPanel.make()

        // Built now, so the first click has nothing left to construct.
        hosting = MeasuringHostingView(rootView: AnyView(MenuContentView(model: model)))
        hosting.translatesAutoresizingMaskIntoConstraints = false

        container = NSVisualEffectView()
        container.material = .menu
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        // The hairline a macOS menu wears, so the material has an edge.
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        super.init()

        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.contentView = container
        panel.onCancel = { [weak self] in self?.hide() }
        hosting.onContentChange = { [weak self] in self?.contentDidChange() }

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(buttonClicked)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.imagePosition = .imageOnly
        }
        redraw()

        // `objectWillChange` fires before the change lands, so redraw on the next turn.
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.redraw()
                self?.contentDidChange()
            }
            .store(in: &cancellables)

        // Another app coming to the front closes the panel (cmd-tab, Mission Control,
        // a click elsewhere).  Our own activation must not: showing the panel can
        // activate us, and hiding on that turned every click into a no-op.
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor in self?.hide() }
        }
    }

    deinit {
        MainActor.assumeIsolated {
            if let workspaceObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            }
            if let outsideClick { NSEvent.removeMonitor(outsideClick) }
        }
    }

    /// The bar carries the mark and its colour; the numbers live in the tooltip.
    func redraw() {
        statusItem.button?.image = MenuBarTitle.image(for: model.activeRow)
        statusItem.button?.toolTip = MenuBarTitle.tooltip(for: model.activeRow)
    }

    /// On a notched Mac a status item can be pushed under the notch and become unclickable.
    var buttonFrameInScreen: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private var screen: NSScreen? {
        statusItem.button?.window?.screen ?? NSScreen.main
    }

    @objc private func buttonClicked() {
        isOpen ? hide() : show()
    }
}

// MARK: - Showing and hiding

extension StatusItemController {
    func show() {
        guard !isOpen else { return }
        isOpen = true
        let start = Date()
        resize()
        position()
        panel.orderFrontRegardless()
        panel.makeKey()
        statusItem.button?.highlight(!panelSuppressed)
        startWatchingForOutsideClicks()
        opens += 1
        let milliseconds = Date().timeIntervalSince(start) * 1000

        // Fresh numbers once the panel is up; the self-test measures the open path alone.
        if !panelSuppressed {
            Task {
                await model.refresh()
                model.refreshAllIfAnythingWentDark()
            }
        }

        if ProcessInfo.processInfo.environment["CAS_LOG"] != nil {
            NSLog("[CAS] open #%d in %.1f ms · panel %@ · button %@",
                  opens, milliseconds, NSStringFromRect(panel.frame),
                  NSStringFromRect(buttonFrameInScreen ?? .zero))
        }
    }

    func hide() {
        guard isOpen else { return }
        isOpen = false
        stopWatchingForOutsideClicks()
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        closes += 1
    }

    /// What the content wants, capped to the screen the item is on.
    private func fittedSize() -> NSSize {
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        size.width = max(size.width, MenuContentView.width)
        if let visible = screen?.visibleFrame {
            size.height = min(size.height, visible.height - 40)
        }
        return size
    }

    private func resize() {
        panel.setContentSize(fittedSize())
    }

    /// The content grew or shrank while the panel was open.  Coalesced to the next turn:
    /// the callback arrives from inside a layout pass, which is no place to lay out again.
    func contentDidChange() {
        guard isOpen, !panelSuppressed, !resizeScheduled else { return }
        resizeScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            resizeScheduled = false
            resizeIfNeeded()
        }
    }

    /// Re-measures and, when the height really moved, re-hangs the panel from the item:
    /// a window grows from its bottom-left, so a taller panel left where it was would
    /// climb over the menu bar instead of down the screen.
    private func resizeIfNeeded() {
        guard isOpen, !panelSuppressed else { return }
        let wanted = fittedSize()
        let current = panel.contentView?.frame.size ?? panel.frame.size
        guard abs(wanted.height - current.height) > 0.5
                || abs(wanted.width - current.width) > 0.5 else { return }
        panel.setContentSize(wanted)
        position()
    }

    /// Centred under the item, pulled back on screen near an edge.
    private func position() {
        if panelSuppressed {
            panel.alphaValue = 0
            panel.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            return
        }
        panel.alphaValue = 1
        guard let buttonFrame = buttonFrameInScreen else { return }
        let size = panel.frame.size
        var origin = NSPoint(x: buttonFrame.midX - size.width / 2,
                             y: buttonFrame.minY - size.height - 6)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = max(origin.y, visible.minY + 8)
        }
        panel.setFrameOrigin(origin)
    }

    /// Global monitors see other applications only, so a click on our own status
    /// item never reaches this and cannot fight the toggle.
    private func startWatchingForOutsideClicks() {
        guard outsideClick == nil else { return }
        outsideClick = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    private func stopWatchingForOutsideClicks() {
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }
        outsideClick = nil
    }

    // Losing key is deliberately not a reason to hide: a status item click hands
    // key to the menu bar for a moment, and hiding on that raced the toggle.
}

// MARK: - Self-test

extension StatusItemController {
    /// Clicks the item from inside the app `clicks` times and logs how often the panel
    /// really opened and closed.  Real `NSEvent`s on our own queue; only the window
    /// server's delivery is out of reach (it would need an accessibility grant).
    func runSelfTest(clicks: Int) async {
        guard let button = statusItem.button, let window = button.window else {
            NSLog("[CAS] self-test: no status item button")
            return
        }
        panelSuppressed = true
        defer {
            hide()
            panelSuppressed = false
            panel.alphaValue = 1
        }
        var failedToOpen = 0
        var failedToClose = 0
        var openTimes: [Double] = []

        for index in 0..<clicks {
            let start = Date()
            post(.leftMouseDown, to: button, in: window, number: index * 2)
            await settle()
            if isOpen {
                openTimes.append(Date().timeIntervalSince(start) * 1000)
            } else {
                failedToOpen += 1
            }

            post(.leftMouseDown, to: button, in: window, number: index * 2 + 1)
            await settle()
            if isOpen { failedToClose += 1 }
        }

        // Esc has to close it too.
        post(.leftMouseDown, to: button, in: window, number: clicks * 2)
        await settle()
        let openedForEscape = isOpen
        postEscape()
        await settle()
        let closedByEscape = openedForEscape && !isOpen
        if isOpen { hide() }

        // Second pass through the button's own target/action.  If the two passes
        // disagree, the difference is in event delivery, not in us.
        var actionFailures = 0
        for _ in 0..<clicks {
            statusItem.button?.performClick(nil)
            await settle()
            if !isOpen { actionFailures += 1 }
            statusItem.button?.performClick(nil)
            await settle()
            if isOpen { actionFailures += 1 }
        }

        let first = openTimes.first ?? -1
        let rest = openTimes.dropFirst()
        let average = rest.isEmpty ? -1 : rest.reduce(0, +) / Double(rest.count)
        NSLog("[CAS] self-test: %d clicks, %d failed to open, %d failed to close, "
              + "esc closes: %@, %d action-path failures in %d toggles, "
              + "first round trip %.1f ms, later %.1f ms avg (round trips include an 80 ms settle)",
              clicks, failedToOpen, failedToClose, closedByEscape ? "yes" : "NO",
              actionFailures, clicks * 2, first, average)
    }

    private func post(_ type: NSEvent.EventType, to button: NSStatusBarButton,
                      in window: NSWindow, number: Int) {
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        guard let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: number, clickCount: 1, pressure: 1) else { return }
        NSApp.postEvent(event, atStart: false)
        // An idle accessory app is parked in the run loop; wake it so the event goes now.
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private func postEscape() {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    /// Let the posted event be dispatched before looking at the result.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 80_000_000)
    }
}
