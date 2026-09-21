import AppKit
import ServiceManagement
import SwiftUI

/// Whether macOS starts the app at login, through `SMAppService.mainApp`
/// (macOS 13+).  Nothing here registers anything by itself: the state is read
/// at startup and only changed when the owner flips the switch.
///
///     let login = LaunchAtLogin()      // reads, writes nothing
///     LaunchAtLogin.isAvailable        // false for a bare .build binary
///     login.isEnabled = true           // registers; a refusal lands in `failure`
///     login.refresh()                  // System Settings can change it behind us
@MainActor
final class LaunchAtLogin: ObservableObject {
    enum State: Equatable {
        case on
        case off
        /// Registered, but macOS wants the owner to allow it in
        /// System Settings › General › Login Items.
        case needsApproval
        /// Not running from an .app bundle, so there is nothing to register.
        case unavailable
    }

    @Published private(set) var state: State = .unavailable
    /// The last refusal, in words the panel can show.  Cleared by a change that works.
    @Published private(set) var failure: String?

    /// False when the binary runs straight out of `.build`: SMAppService needs a
    /// bundle, which `scripts/make-app.sh` produces.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    init() { state = Self.read() }

    /// Reading is free.  Setting registers or unregisters and never throws: the
    /// reason for a refusal belongs on screen, in `failure`, not in a trap.
    var isEnabled: Bool {
        get { state == .on }
        set { apply(newValue) }
    }

    func refresh() { state = Self.read() }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    private static func read() -> State {
        guard isAvailable else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        case .notRegistered, .notFound: return .off
        @unknown default: return .off
        }
    }

    private func apply(_ wanted: Bool) {
        guard Self.isAvailable else {
            failure = "Only the built app can start at login — build it with scripts/make-app.sh."
            return
        }
        var refusal: Error?
        do {
            if wanted {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            refusal = error
        }
        // What macOS ended up doing decides, not what it returned: unregistering
        // something already gone throws, and registering can land on "approve me".
        state = Self.read()
        if (wanted && state == .on) || (!wanted && state == .off) {
            failure = nil
        } else if state == .needsApproval {
            failure = "macOS wants this allowed once: System Settings › General › Login Items."
        } else {
            failure = Self.explain(refusal, wanted: wanted)
        }
    }

    private static func explain(_ error: Error?, wanted: Bool) -> String {
        let verb = wanted ? "start at login" : "stop starting at login"
        guard let error else { return "macOS would not \(verb), and gave no reason." }
        let problem = error as NSError
        // 1 is SMAppService's "Operation not permitted", which is what a login
        // item switched off in System Settings comes back as.
        if problem.domain == "SMAppServiceErrorDomain" && problem.code == 1 {
            return "macOS is blocking it. Turn Claude Account Switcher on in "
                + "System Settings › General › Login Items."
        }
        return "Could not \(verb): \(problem.localizedDescription)"
    }
}

/// The footer's control: one switch, plus the way out when macOS wants a word.
@MainActor
struct LaunchAtLoginToggle: View {
    @StateObject private var login = LaunchAtLogin()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(get: { login.isEnabled },
                                     set: { login.isEnabled = $0 })) {
                    Text("Launch at login").font(.system(size: 10))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(login.state == .unavailable)
                .help(login.state == .unavailable
                      ? "Only the built app can start at login (scripts/make-app.sh)"
                      : "Start Claude Account Switcher when you log in")
                Spacer(minLength: 4)
                if login.state == .needsApproval {
                    Button("Allow…") { login.openLoginItemsSettings() }
                        .controlSize(.small)
                        .font(.system(size: 10))
                }
            }
            if let failure = login.failure {
                Text(failure)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { login.refresh() }
    }
}
