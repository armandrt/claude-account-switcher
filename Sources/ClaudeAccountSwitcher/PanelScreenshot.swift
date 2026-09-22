import AppKit
import SwiftUI
import SwitcherCore

/// `--screenshot <file.png>` draws the panel and exits.
///
/// The picture in the README is generated, never captured: no window is shown,
/// no screen recording permission is asked for, and the accounts in it are
/// invented, so nobody's email or quota is published. Regenerate it with the
/// app and it can never drift from what the app looks like:
///
///     ClaudeAccountSwitcher.app/Contents/MacOS/ClaudeAccountSwitcher \
///         --screenshot docs/panel.png [--dark]
public enum PanelScreenshot {
    public static func renderIfAsked() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--screenshot") else { return }
        guard flag + 1 < arguments.count else {
            FileHandle.standardError.write(Data("--screenshot needs a file to write\n".utf8))
            exit(2)
        }
        let url = URL(fileURLWithPath: arguments[flag + 1])
        let dark = arguments.contains("--dark")
        MainActor.assumeIsolated {
            render(to: url, dark: dark)
        }
        exit(0)
    }

    @MainActor
    private static func render(to url: URL, dark: Bool) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApp?.appearance = appearance

        // The picture shows the switch off, whatever this Mac has registered.
        LaunchAtLogin.pinned = .off
        let model = AppModel.forScreenshot()
        // The colour scheme goes on last so the background resolves in it too.
        let renderer = ImageRenderer(content:
            MenuContentView(model: model, isRendering: true)
                .background(Color(nsColor: .windowBackgroundColor))
                .frame(width: MenuContentView.width)
                .environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 2

        // The appearance has to be current while the view is rasterised, or the
        // NSColor-backed palette resolves against the wrong one.
        var png: Data?
        appearance?.performAsCurrentDrawingAppearance {
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff) else { return }
            png = bitmap.representation(using: .png, properties: [:])
        }

        guard let png else {
            FileHandle.standardError.write(Data("screenshot: the panel did not render\n".utf8))
            exit(1)
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try png.write(to: url)
            print("screenshot: wrote \(url.path) (\(png.count) bytes, \(dark ? "dark" : "light"))")
        } catch {
            FileHandle.standardError.write(Data("screenshot: \(error)\n".utf8))
            exit(1)
        }
    }
}

// MARK: - The accounts in the picture

extension AppModel {
    /// A model holding invented accounts and nothing else: no keychain is read,
    /// no request is made, and the rows below are the ones in the README.
    @MainActor
    static func forScreenshot() -> AppModel {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cas-screenshot-\(UUID().uuidString)")
        let model = AppModel(
            // A prefix nothing uses, so the enumeration finds no real slot.
            store: SlotStore(loginPrefix: "CAS Screenshot Never: ",
                             activeLoginURL: sandbox.appendingPathComponent("active-login")),
            cache: UsageCache(directory: sandbox),
            switcher: Switcher(loginPrefix: "CAS Screenshot Never: ",
                               paths: Switcher.Paths(
                                   config: sandbox.appendingPathComponent(".claude.json"),
                                   activeLogin: sandbox.appendingPathComponent("active-login"),
                                   lock: sandbox.appendingPathComponent("lock"))),
            preferences: ScreenshotPreferences())
        model.showDemoRows(Self.demoRows())
        return model
    }

    /// Three accounts that between them show everything the panel can say: one
    /// live and comfortable, one nearly out of its week with a model spent, and
    /// one whose token has expired and wears its own fix.
    @MainActor
    static func demoRows(now: Date = Date()) -> [AccountRow] {
        func credentials(expired: Bool = false) -> OAuthCredentials {
            OAuthCredentials(
                accessToken: "demo", refreshToken: "demo",
                expiresAt: now.addingTimeInterval(expired ? -600 : 7200).timeIntervalSince1970 * 1000,
                refreshTokenExpiresAt: now.addingTimeInterval(864_000).timeIntervalSince1970 * 1000,
                scopes: ["user:profile", "user:inference"], subscriptionType: "max")
        }
        func row(_ name: String, active: Bool, health: CredentialHealth,
                 session: Double?, weekly: Double?, model: Double?) -> AccountRow {
            let slot = Slot(name: name, isActive: active, health: health,
                            credentials: credentials(expired: health == .expired),
                            account: OAuthAccount(emailAddress: "\(name)@example.com",
                                                  organizationRateLimitTier: "default_claude_max_20x"),
                            byteCount: 2_048)
            var row = AccountRow(slot: slot)
            guard let session, let weekly else { return row }
            var limits = [
                UsageLimit(kind: .session, percent: session,
                           severity: session >= 92 ? .critical : session >= 78 ? .warning : .normal,
                           resetsAt: now.addingTimeInterval(11_400)),
                UsageLimit(kind: .weeklyAll, percent: weekly,
                           severity: weekly >= 92 ? .critical : weekly >= 78 ? .warning : .normal,
                           resetsAt: now.addingTimeInterval(212_000)),
            ]
            if let model {
                limits.append(UsageLimit(kind: .weeklyScoped, percent: model,
                                         severity: model >= 92 ? .critical : .normal,
                                         resetsAt: now.addingTimeInterval(212_000),
                                         modelDisplayName: "Fable"))
            }
            row.usage = UsageSnapshot(limits: limits, fetchedAt: now.addingTimeInterval(-40))
            row.fetchedAt = row.usage?.fetchedAt
            row.isLive = true
            return row
        }
        return [
            row("work", active: true, health: .ok, session: 24, weekly: 38, model: 62),
            row("personal", active: false, health: .ok, session: 0, weekly: 97, model: 100),
            row("spare", active: false, health: .expired, session: nil, weekly: nil, model: nil),
        ]
    }
}

/// Defaults that live nowhere: a screenshot must not read or write the owner's.
private final class ScreenshotPreferences: Preferences {
    private var values: [String: Any] = [:]
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
