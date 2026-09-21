import AppKit
import SwitcherApp

// AppKit lifecycle: the status item and its panel are AppKit objects we own,
// and SwiftUI only draws the panel's contents.  Everything else — the model,
// the delegate, the views — lives in the SwitcherApp library so the tests can
// reach it; this file is the process and nothing else.

// `--render-iconset <dir>` draws the app icon and exits, so no artwork is
// committed; scripts/make-app.sh calls it.  Before NSApplication, so a
// render never starts the app.
AppIcon.renderIfAsked()

let application = NSApplication.shared
// `--screenshot <file>` draws the panel to a PNG and exits: NSApp must exist for
// SwiftUI to rasterise, but nothing is shown and no window is ever ordered in.
PanelScreenshot.renderIfAsked()
// Top-level code without `await` is not main-actor isolated in Swift 5 mode.
let delegate = MainActor.assumeIsolated { makeAppDelegate() }
application.delegate = delegate
application.setActivationPolicy(.accessory)   // menu bar only: no Dock icon
application.run()
