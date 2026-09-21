import AppKit

/// The dropdown, as a panel we own.
///
/// `MenuBarExtra(.window)` builds its content on the first click and animates
/// its own activation, which is where the missed first clicks and the slide
/// came from.  A panel created up front and positioned by hand has neither.
final class MenuPanel: NSPanel {
    /// Non-activating panels refuse key by default; the buttons and Esc need it.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var onCancel: (() -> Void)?

    /// Esc.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    static func make() -> MenuPanel {
        let panel = MenuPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovable = false
        // Tool tips need the window to take mouse-moved events.  A non-activating
        // panel may still refuse to show them, so nothing in the panel depends on
        // one: every control carries a word of its own.
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }
}
