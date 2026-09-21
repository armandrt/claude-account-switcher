import AppKit
import SwitcherCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var controller: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = StatusItemController(model: model)
        self.controller = controller
        model.start()

        if ProcessInfo.processInfo.environment["CAS_LOG"] != nil,
           let frame = controller.buttonFrameInScreen {
            let screen = NSScreen.main
            NSLog("[CAS] status item at %@ · screen %@ · notch inset %.0f",
                  NSStringFromRect(frame),
                  NSStringFromRect(screen?.frame ?? .zero),
                  screen?.safeAreaInsets.top ?? 0)
        }
        if let clicks = ProcessInfo.processInfo.environment["CAS_SELFTEST"].flatMap(Int.init) {
            Task { await controller.runSelfTest(clicks: clicks) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }
}
