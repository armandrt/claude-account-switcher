import Foundation
import SwitcherCore

/// "Refresh all" and the opt-in that does the same on a timer.
///
/// Strictly sequential, waits out the 30 s floor between calls, and the first
/// 429 ends it: pushing on would turn one refusal into a lockout for every account.
extension AppModel {
    /// Renew every inactive slot whose token has expired, then read every quota.
    func refreshAll() {
        guard !refuseIfBusy() else { return }
        sweepReport = nil
        actionError = nil
        sweepTask = Task { [weak self] in
            await self?.runSweep()
            self?.sweepTask = nil
            self?.sweepLine = nil
            self?.sweepProgress = [:]
        }
    }

    /// Opening the panel renews accounts that have gone dark.
    ///
    /// An inactive account's access token lasts hours, so one left alone overnight shows
    /// nothing until a button is pressed — which defeats the point of a panel that exists to
    /// show every account at once. Opening it counts as asking, so the sweep runs itself.
    func refreshAllIfAnythingWentDark() {
        guard sweepTask == nil, busySlot == nil, login == nil,
              pendingSwitch == nil, pendingCapture == nil else { return }
        let now = Date()
        // One sweep per opening spree: reopening the panel must not rotate tokens again.
        if let last = lastOpenSweepAt, now.timeIntervalSince(last) < Self.openSweepInterval { return }
        let dark = rows.contains { !$0.isFake && !$0.slot.isActive && $0.slot.health == .expired }
        guard dark else { return }
        lastOpenSweepAt = now
        refreshAll()
    }

    /// Stops after the call in flight: a rotation already on the wire has to be
    /// written back, or the account is left holding a retired refresh token.
    ///
    /// Nothing happens with no sweep running: the Stop button is on screen for
    /// the frame after the sweep ends, and a "stopping…" line set there would
    /// have stayed for good, hiding Refresh all and the toggle behind it.
    func stopRefreshAll() {
        guard let task = sweepTask else { return }
        task.cancel()
        sweepLine = "stopping after this account…"
    }

    func dismissSweepReport() { sweepReport = nil }

    private func runSweep() async {
        let live = rows.filter { !$0.isFake }
        let readAt = Dictionary(uniqueKeysWithValues: live.compactMap { row in
            row.fetchedAt.map { (row.name, $0) }
        })
        let steps = SweepPlanner.plan(slots: live.map(\.slot), readAt: readAt)
        guard !steps.isEmpty else {
            sweepReport = SweepReport(outcomes: [])
            return
        }
        note("refresh all: \(steps.count) accounts, \(steps.reduce(0) { $0 + $1.action.requests }) requests")

        var outcomes: [SweepOutcome] = []
        var stopped: String?

        for (index, step) in steps.enumerated() {
            guard stopped == nil else {
                outcomes.append(SweepOutcome(name: step.name, result: .notReached))
                continue
            }
            sweepLine = "\(index + 1) of \(steps.count): \(step.name)"

            switch step.action {
            case .skip(let why):
                outcomes.append(SweepOutcome(name: step.name, result: .skipped(why)))
                mark(step.name, "skipped")
            case .renew:
                let outcome = await renew(step.name)
                outcomes.append(outcome)
                if case .failed(let why) = outcome.result, isRateLimit(why) { stopped = why }
            case .read:
                let outcome = await read(step.name, renewed: false)
                outcomes.append(outcome)
                if case .failed(let why) = outcome.result, isRateLimit(why) { stopped = why }
            }

            if Task.isCancelled, stopped == nil { stopped = "you stopped it" }
        }

        let report = SweepReport(outcomes: outcomes, stopped: stopped)
        sweepReport = report
        note("refresh all: \(report.headline)", kind: stopped == nil ? .note : .failed)
        await refreshUnstoredSlots()
    }

    private func isRateLimit(_ why: String) -> Bool {
        why.contains("rate limited") || why.contains("429")
    }

    private func mark(_ name: String, _ text: String?) {
        if let text {
            sweepProgress[name] = text
        } else {
            sweepProgress.removeValue(forKey: name)
        }
    }
}

// MARK: - One account at a time

extension AppModel {
    /// Renew a slot's access token, then read its quota: two requests, each waiting its turn.
    private func renew(_ name: String) async -> SweepOutcome {
        guard let row = rows.first(where: { $0.name == name }), let payload = row.slot.payload else {
            return SweepOutcome(name: name, result: .skipped("nothing readable is stored for it"))
        }
        // No wait and no charge against the allowance: a renewal goes to the token
        // endpoint on another host, which the usage endpoint's rate limit knows
        // nothing about. Gating it behind the 30 s floor doubled every sweep's
        // countdown for nothing — that is what made it look stuck on one account.
        guard !Task.isCancelled else { return SweepOutcome(name: name, result: .notReached) }
        mark(name, "renewing…")
        do {
            let credentials = try await refresher.refresh(slot: name, payload: payload)
            note("renewed \(name), valid until \(Format.time(credentials.expiry))", kind: .refreshed)
            await reloadSlots()
            let outcome = await read(name, renewed: true)
            if case .failed(let why) = outcome.result {
                return SweepOutcome(name: name, result: .failed("renewed, but \(why)"))
            }
            return outcome
        } catch let error as RefreshError {
            mark(name, "failed")
            await refreshUnstoredSlots()
            // Rotated tokens the keychain refused are alive in memory; quitting loses them.
            if case .writeBack = error {
                return SweepOutcome(name: name, result: .renewedNotStored(
                    "renewed, but the keychain refused the new tokens — use Retry save before quitting"))
            }
            return SweepOutcome(name: name, result: .failed(error.description))
        } catch {
            mark(name, "failed")
            return SweepOutcome(name: name, result: .failed("\(error)"))
        }
    }

    /// Read one account's quota.  Success means a NEW reading, not the absence of an error.
    private func read(_ name: String, renewed: Bool) async -> SweepOutcome {
        guard await wait(for: name, doing: "reading") else {
            return SweepOutcome(name: name, result: renewed ? .renewed : .notReached)
        }
        mark(name, "reading…")
        let before = rows.first(where: { $0.name == name })?.fetchedAt
        await pollAccount(named: name)

        guard let row = rows.first(where: { $0.name == name }) else {
            return SweepOutcome(name: name, result: .failed("it disappeared from the list mid-sweep"))
        }
        guard row.problem == nil, row.isLive, row.fetchedAt != before else {
            if Task.isCancelled {
                mark(name, nil)
                return SweepOutcome(name: name, result: renewed ? .renewed : .notReached)
            }
            mark(name, "failed")
            return SweepOutcome(name: name, result: .failed(row.problem ?? "its quota was not read"))
        }
        mark(name, "done")
        return SweepOutcome(name: name, result: renewed ? .renewed : .alreadyFine)
    }

    /// Sits out the shared allowance, counting down in the footer.  False when stopped.
    private func wait(for name: String, doing verb: String) async -> Bool {
        while !Task.isCancelled {
            let remaining = budget.waitTime(now: Date())
            guard remaining > 0 else { return true }
            let seconds = Int(remaining.rounded())
            mark(name, "\(seconds) s")
            sweepLine = "\(verb) \(name) in \(seconds) s"
            try? await Task.sleep(nanoseconds: UInt64(min(remaining, 1) * 1_000_000_000))
        }
        mark(name, nil)
        return false
    }
}

// MARK: - The opt-in

extension AppModel {
    /// One renewal per pass at most, only with the toggle on and the half hour gone by.
    func autoRenewIfDue() async {
        guard sweepTask == nil, busySlot == nil, budget.allows(Date()) else { return }
        let slots = rows.filter { !$0.isFake }.map(\.slot)
        guard let name = AutoRenew.due(slots: slots, lastRenewAt: lastAutoRenewAt),
              let payload = rows.first(where: { $0.name == name })?.slot.payload else { return }

        // Recorded before the call: a renewal that fails still used its turn.
        lastAutoRenewAt = Date()
        busySlot = name
        budget.recordRequest(at: Date())
        saveBudgetState()
        defer { busySlot = nil }
        do {
            let credentials = try await refresher.refresh(slot: name, payload: payload)
            note("kept \(name) up to date, valid until \(Format.time(credentials.expiry))",
                 kind: .refreshed)
            // It may have succeeded by storing tokens that were held in memory.
            await refreshUnstoredSlots()
            await reloadSlots()
        } catch {
            let text = (error as? RefreshError)?.description ?? "\(error)"
            note("automatic renewal failed for \(name): \(text)", kind: .failed)
            await refreshUnstoredSlots()
        }
    }
}
