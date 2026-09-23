import Foundation
import SwitcherCore
import UserNotifications

/// The footer's line for an armed mode: whether it can act, and what it is doing.
struct PolicyStatus: Equatable {
    var headline: String
    var detail: String?
    /// Armed, but something is holding it back right now.
    var isHolding: Bool
}

// MARK: - Decision to action

extension AppModel {
    /// The only path from a policy decision to the switcher.  Everything that can
    /// stop it lives in `AutoSwitchGate`; this carries out the verdict and says so.
    /// `now` is the clock the decision was made against; the gate must not use another.
    func act(on decision: PolicyDecision, accounts: [PolicyAccount], now: Date = Date()) {
        let conditions = AutoSwitchConditions(isSweeping: sweepTask != nil,
                                              isBusy: busySlot != nil,
                                              isConfirming: isConfirming)
        let verdict = gate.verdict(for: decision, mode: mode, accounts: accounts,
                                   active: activeRow?.name, conditions: conditions,
                                   state: autoState, now: now, lastSwitchAt: lastSwitchAt)
        switch verdict {
        case .act(let target):
            // The aura ranks by soonest reset; the modes rank by quota left per hour.
            // When they disagree the sentence says so, so a switch away from the
            // aura never looks like a mistake.
            var reason = decision.reason
            if let pick = BestPick.choose(accounts, now: now)?.name, pick != target {
                reason += " (the aura stays on \(pick), first to reset; \(mode.title) ranks by quota per hour)"
            }
            policyStatus = PolicyStatus(headline: armedHeadline,
                                        detail: "switching to \(target) — \(reason)",
                                        isHolding: false)
            automaticSwitch(to: target, reason: reason)
        case .hold(let refusal):
            recordHeld(decision, held: refusal.text)
            policyStatus = status(for: decision, refusal: refusal)
        }
    }

    func autoSwitchSucceeded(from: String?, to: String, reason: String) {
        autoState.recordSuccess()
        let who = from.map { "\($0) → \(to)" } ?? to
        policyStatus = PolicyStatus(headline: armedHeadline, detail: "switched \(who)",
                                    isHolding: false)
        notify(title: "Now on \(to)", body: reason)
    }

    /// Two failed switches in a row stop automatic switching: a loop that keeps
    /// rewriting credentials is the worst thing this app could do.
    func autoSwitchFailed(to name: String, text: String) {
        guard autoState.recordFailure() else {
            note("automatic switch to \(name) failed: \(text)", kind: .failed)
            policyStatus = PolicyStatus(headline: armedHeadline,
                                        detail: "last switch failed — one more stops it",
                                        isHolding: true)
            return
        }
        isDisarming = true
        mode = .manual
        isDisarming = false
        policyStatus = nil
        note("automatic switch to \(name) failed: \(text) — two in a row, back to Manual",
             kind: .failed)
        notify(title: "Automatic switching is off",
               body: "Two switches failed in a row, so the mode is back to Manual. \(text)",
               sound: true)
    }

    var armedHeadline: String { "\(mode.title) is armed — it can switch accounts on its own" }

    private func status(for decision: PolicyDecision,
                        refusal: AutoSwitchGate.Refusal) -> PolicyStatus? {
        switch refusal {
        case .manual:
            return nil
        case .staying:
            return PolicyStatus(headline: armedHeadline, detail: "staying — \(decision.reason)",
                                isHolding: false)
        case .stopped:
            return PolicyStatus(headline: "\(mode.title) is not switching", detail: refusal.text,
                                isHolding: true)
        default:
            let target = decision.target ?? "another account"
            return PolicyStatus(headline: armedHeadline,
                                detail: "would switch to \(target) — \(refusal.text)",
                                isHolding: true)
        }
    }

    private func notify(title: String, body: String, sound: Bool = false) {
        let notifier = self.notifier
        Task { await notifier.post(title: title, body: body, sound: sound) }
    }
}

// MARK: - Notifications

/// Only for what the owner did not do himself.  Authorisation is asked the first
/// time a notification is warranted, never at launch, and a refusal is final for
/// this run: the app carries on silently and never asks again.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private enum Permission { case unknown, granted, refused }
    private var permission: Permission = .unknown

    func post(title: String, body: String, sound: Bool) async {
        // The centre traps outside an app bundle, which is how the binary runs from SwiftPM.
        guard permission != .refused, Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        if permission == .unknown {
            center.delegate = self
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            permission = granted ? .granted : .refused
            guard granted else { return }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                                    content: content, trigger: nil))
    }

    /// The panel makes this app frontmost; without this the banner would be dropped.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
