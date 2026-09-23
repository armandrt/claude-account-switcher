import AppKit
import Combine
import Foundation
import SwitcherCore

/// A switch that can still be taken back.
struct UndoOffer: Equatable {
    let from: String
    let to: String
}

/// The executable is `main.swift` and this call; everything else lives in this
/// module, where the tests can reach it.
@MainActor public func makeAppDelegate() -> any NSApplicationDelegate {
    AppDelegate()
}

/// The slice of `UserDefaults` the model keeps state in.  Injected, so a test
/// never writes to the owner's real defaults — and never reads them either,
/// which would make a test's answer depend on how the app was last used.
protocol Preferences: AnyObject {
    func bool(forKey defaultName: String) -> Bool
    func data(forKey defaultName: String) -> Data?
    func stringArray(forKey defaultName: String) -> [String]?
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: Preferences {}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var rows: [AccountRow] = []
    /// Failover and Balance switch on their own; Manual never does.
    @Published var mode: SwitchMode = .manual {
        didSet {
            guard mode != oldValue, !isDisarming else { return }
            // Choosing a mode is deliberate, so it clears a stop from earlier failures.
            autoState.rearm()
            policyStatus = nil
            note(mode == .manual
                 ? "automatic switching off"
                 : "\(mode.title) armed — the app may switch accounts on its own")
            Task { await refresh() }
        }
    }
    /// What the armed mode is doing right now, for the footer.  Nil in Manual.
    @Published var policyStatus: PolicyStatus?
    /// Whether macOS starts the app at login.  Read again each time the panel opens,
    /// because System Settings can change it behind the app's back.
    let launchAtLogin = LaunchAtLogin()

    /// The dry run shown for an ⌥-click; a plain click switches without it.
    @Published private(set) var pendingSwitch: SwitchPlan?
    @Published private(set) var undo: UndoOffer?
    /// The row a click is switching to right now.
    @Published private(set) var switchingTo: String?
    @Published var actionError: String?
    /// The slot an action is running for, so its buttons go quiet.
    @Published var busySlot: String?
    /// Slots whose rotated tokens are in memory and not yet in the keychain.
    @Published private(set) var unstoredSlots: Set<String> = []
    @Published private(set) var pendingCapture: CapturePlan?
    @Published var captureName: String = ""
    /// The row being renamed, and the row asking whether to be removed: one of each,
    /// inline, never both at once.
    @Published private(set) var renaming: String?
    @Published private(set) var removing: String?
    /// The order the owner dragged the list into; also the policy's tie-breaker.
    @Published private(set) var order: SlotOrder
    @Published private(set) var log = SwitchLog()

    /// "Refresh all" while it runs: one footer line and one word per row.
    @Published var sweepLine: String?
    @Published var sweepProgress: [String: String] = [:]
    @Published var sweepReport: SweepReport?

    /// The sign-in the panel is showing, if any.
    @Published var login: LoginState?

    static let lastAutoRenewKey = "CASLastAutoRenewAt"
    static let lastOpenSweepKey = "CASLastOpenSweepAt"
    static let orderKey = "CASAccountOrder"
    /// How long Undo stays on offer.  An instance value so a test can shorten it.
    var undoWindow: TimeInterval = 15

    let store: SlotStore
    let refresher: TokenRefresher
    /// Where the order, the renewal clock and the allowance are kept.
    let preferences: Preferences
    /// The sign-in's two injection points: the keychain it writes a new slot
    /// into, and the flow itself.  A test gets a fake for both, so nothing it
    /// runs can reach the real keychain or the network.
    var loginWriter: KeychainWriting?
    var oauth = OAuthLogin()
    /// The only place the app opens a URL; a test watches it instead of the browser.
    var openURL: @MainActor (URL) -> Void = { url in _ = NSWorkspace.shared.open(url) }
    private let usage: UsageClient
    private let cache: UsageCache
    private let switcher: Switcher
    /// One config for both: the gate reuses the policy's own interval and thresholds.
    private static let policyConfig = PolicyConfig()
    private let policy = PolicyEngine(config: AppModel.policyConfig)
    let gate = AutoSwitchGate(config: AppModel.policyConfig)
    /// The hourly cap and the run of failures that turns automatic switching off.
    var autoState = AutoSwitchState()
    /// True only while the app itself is putting the mode back to Manual.
    var isDisarming = false
    let notifier = Notifier()
    /// Any switch, the owner's clicks included, starts the cool-off.
    var lastSwitchAt: Date?
    private var pollTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var undoTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private let fakeAccountCount = FakeAccounts.requested
    /// The running "Refresh all"; nil when none.
    var sweepTask: Task<Void, Never>?
    /// Sign-in state kept out of the published struct: a secret and a socket.
    var loginPKCE: PKCE?
    var loginListener: LoopbackCallback?
    var loginTask: Task<Void, Never>?
    /// On disk, so a relaunch is not a way to rotate another token.
    var lastAutoRenewAt: Date? {
        get { preferences.object(forKey: Self.lastAutoRenewKey) as? Date }
        set { preferences.set(newValue, forKey: Self.lastAutoRenewKey) }
    }

    /// The panel-open sweep renews too, so its clock is kept next to the other one:
    /// quitting and reopening must not be a way to rotate another refresh token.
    var lastOpenSweepAt: Date? {
        get { preferences.object(forKey: Self.lastOpenSweepKey) as? Date }
        set { preferences.set(newValue, forKey: Self.lastOpenSweepKey) }
    }

    /// One allowance for the whole app, however many accounts are listed.
    var budget = RateLimitBudget()
    /// Last good reading per slot, from disk, so the first frame has numbers.
    private var cached: [String: UsageSnapshot]

    init(store: SlotStore = SlotStore(), usage: UsageClient = UsageClient(),
         cache: UsageCache = UsageCache(), switcher: Switcher = Switcher(),
         refresher: TokenRefresher? = nil,
         preferences: Preferences = UserDefaults.standard) {
        self.store = store
        self.usage = usage
        self.cache = cache
        self.switcher = switcher
        self.preferences = preferences
        // Straight into the backing store: going through the property would run
        // `didSet`, which writes the value back and logs a line nobody asked for.
        self.order = SlotOrder(preferences.stringArray(forKey: Self.orderKey) ?? [])
        // The refresher's writer cannot reach the live item; only the switcher's can.
        self.refresher = refresher ?? TokenRefresher(
            writer: SystemKeychainWriter(servicePrefix: store.loginPrefix),
            reader: store.reader,
            servicePrefix: store.loginPrefix,
            liveSlotName: { store.activeSlotName() })
        self.cached = cache.load()
        // A relaunch must not reset the allowance: restarting in a loop is how
        // the endpoint rate-limited us in the first place.
        if let saved = Self.savedBudgetState(preferences) {
            budget.restore(saved, now: Date())
        } else if let newest = self.cached.values.map(\.fetchedAt).max() {
            budget.recordRequest(at: newest)
        }
    }

    static let budgetStateKey = "CASRateLimitBudget"
    /// A panel opened twice in a row renews once.
    static let openSweepInterval: TimeInterval = 600

    private static func savedBudgetState(_ preferences: Preferences) -> RateLimitBudget.State? {
        guard let data = preferences.data(forKey: budgetStateKey) else { return nil }
        return try? JSONDecoder().decode(RateLimitBudget.State.self, from: data)
    }

    /// Called after anything that moves the allowance.
    func saveBudgetState() {
        guard let data = try? JSONEncoder().encode(budget.state) else { return }
        preferences.set(data, forKey: Self.budgetStateKey)
    }

    /// Fills the list for `--screenshot`, which draws the panel without a
    /// keychain, a network or a window.
    func showDemoRows(_ demo: [AccountRow]) { rows = demo }

    var activeRow: AccountRow? { rows.first { $0.slot.isActive } }

    func start() {
        guard pollTask == nil else { return }
        // Workspace notifications are posted on the workspace's own centre, not `.default`.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        startClock()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let seconds = await self?.tick() else { return }
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    /// Redraws every half minute so countdowns tick and a window that resets
    /// while the panel is open refills itself. Arithmetic only: no requests.
    private func startClock() {
        guard clockTask == nil else { return }
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, !Task.isCancelled else { return }
                objectWillChange.send()
            }
        }
    }

    func stop() {
        clockTask?.cancel()
        clockTask = nil
        pollTask?.cancel()
        pollTask = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }
}

// MARK: - Switching

extension AppModel {
    /// One click switches and Undo follows; with ⌥ held the dry run is shown first.
    func switchTo(_ name: String, showPlan: Bool = false) {
        if showPlan { return requestSwitch(to: name) }
        actionError = nil
        guard !isFake(name) else { return }
        // One switch at a time; a second click while one is under way is the same wish.
        guard switchingTo == nil else { return }
        pendingSwitch = nil
        // Nothing in the way: the switch starts in this very turn.
        if busySlot == nil, sweepTask == nil {
            startSwitch(to: name)
            return
        }
        // Something is running.  Switching is what this app is for, so the click
        // is never answered with "wait": the row says "switching…" at once, and
        // whatever is running gives way.
        switchingTo = name
        Task { [weak self] in
            guard let self else { return }
            await makeWayForSwitch()
            switchingTo = nil
            startSwitch(to: name)
        }
    }

    /// Marked as switching only once the work is under way, so a refusal cannot
    /// leave a row spinning for a switch that never started.
    private func startSwitch(to name: String) {
        guard run(for: name, { switcher in
            try switcher.switchTo(name, dryRun: false)
        }, onSuccess: { [weak self] done in
            self?.finish(done)
        }) else { return }
        switchingTo = name
    }

    /// Clears the road for a switch: stops a running sweep and lets a row's own
    /// action finish, rather than refusing the click.
    ///
    /// Stopping a sweep is safe mid-renewal: the refresher runs each rotation in
    /// a task of its own, which a cancelled sweep cannot take down, so the new
    /// tokens are still written back before this returns. A sweep and a switch
    /// must not overlap, though — both write keychain slots, and the switch saves
    /// the live login into the slot being left, which may be the one being renewed.
    func makeWayForSwitch() async {
        if let sweep = sweepTask {
            sweep.cancel()
            sweepLine = "stopping for the switch…"
            await sweep.value
        }
        // A row's own action (a renewal, a capture) is one request and one
        // keychain write; its deadline is 20 s, so this cannot wait for ever.
        let deadline = Date().addingTimeInterval(25)
        while busySlot != nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// The switch the app makes by itself: the same call a click makes, with its
    /// own log line, its own failure count and a notification.
    func automaticSwitch(to name: String, reason: String) {
        guard let row = rows.first(where: { $0.name == name }), !row.isFake,
              busySlot == nil, sweepTask == nil else { return }
        actionError = nil
        pendingSwitch = nil
        guard run(for: name, { switcher in
            try switcher.switchTo(name, dryRun: false)
        }, onSuccess: { [weak self] done in
            self?.finish(done, automatic: reason)
        }, onFailure: { [weak self] text in
            self?.autoSwitchFailed(to: name, text: text)
        }) else { return }
        // Counted as it starts, so one that fails still uses up its turn — but
        // only once it has started: a refused call must not spend a turn.
        autoState.recordSwitch(at: Date())
        switchingTo = name
    }

    /// The reverse switch.  The offer is consumed only once the switch can
    /// start, so a click while something else runs does not lose it.
    func undoSwitch() {
        // Undo is a switch, so it gives way to nothing either: `switchTo` clears
        // the road rather than refusing.  A second click while it runs is ignored.
        guard let offer = undo, switchingTo == nil else { return }
        undoTask?.cancel()
        undo = nil
        switchTo(offer.from)
    }

    /// `automatic` carries the policy's reason: a click needs none, the owner made it.
    private func finish(_ done: SwitchPlan, automatic reason: String? = nil) {
        pendingSwitch = nil
        switchingTo = nil
        lastSwitchAt = Date()
        note("switched \(done.from?.name ?? "?") → \(done.to.name)"
             + (done.prunedBackups > 0 ? ", pruned \(done.prunedBackups) backups" : "")
             + (reason.map { ": \($0)" } ?? ""),
             kind: .switched)
        offerUndo(from: done.from?.name, to: done.to.name)
        if let reason {
            autoSwitchSucceeded(from: done.from?.name, to: done.to.name, reason: reason)
        }
        Task { await refresh() }
    }

    private func offerUndo(from: String?, to: String) {
        undoTask?.cancel()
        guard let from, from != to else {
            undo = nil
            return
        }
        undo = UndoOffer(from: from, to: to)
        undoTask = Task { [weak self, undoWindow] in
            try? await Task.sleep(nanoseconds: UInt64(undoWindow * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.undo = nil
        }
    }

    /// The ⌥ path: a dry run, shown before anything is written.
    func requestSwitch(to name: String) {
        actionError = nil
        guard !isFake(name) else { return }
        pendingSwitch = nil
        run(for: name) { switcher in
            try switcher.switchTo(name, dryRun: true)
        } onSuccess: { [weak self] plan in
            self?.pendingSwitch = plan
        }
    }

    func cancelSwitch() {
        pendingSwitch = nil
        actionError = nil
    }

    /// The plan goes back to the switcher, which refuses if the world moved.
    func confirmSwitch() {
        guard let plan = pendingSwitch else { return }
        let name = plan.to.name
        run(for: name) { switcher in
            try switcher.switchTo(name, dryRun: false, confirming: plan)
        } onSuccess: { [weak self] done in
            self?.finish(done)
        }
    }

    /// True, with a message, while another action or a sweep holds the model.
    func refuseIfBusy() -> Bool {
        guard busySlot != nil || sweepTask != nil else { return false }
        actionError = sweepTask != nil
            ? "Refresh all is running — try again when it is done"
            : "another action is still running"
        return true
    }

    /// Runs one blocking switcher call off the main actor; the keychain and
    /// file writes are slow enough to stutter the panel.  False when it refused
    /// to start, so the caller can keep its own state out of the refused case.
    @discardableResult
    private func run<T: Sendable>(for slot: String,
                                  _ work: @escaping @Sendable (Switcher) throws -> T,
                                  onSuccess: @escaping @MainActor (T) -> Void,
                                  onFailure: (@MainActor (String) -> Void)? = nil) -> Bool {
        guard !refuseIfBusy() else { return false }
        busySlot = slot
        let switcher = self.switcher
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try work(switcher) }
            }.value
            guard let self else { return }
            busySlot = nil
            switch result {
            case .success(let value):
                onSuccess(value)
            case .failure(let error):
                switchingTo = nil
                let text = (error as? SwitchError)?.description ?? "\(error)"
                actionError = text
                if let onFailure { onFailure(text) } else { note("failed: \(text)", kind: .failed) }
            }
        }
        return true
    }

    /// Stores the login Claude Code is using now under a name, dry run first:
    /// aimed at the wrong name it overwrites a good account.
    func requestCapture(as name: String) {
        actionError = nil
        pendingCapture = nil
        guard !isFake(name) else { return }
        guard Switcher.isValidName(name) else {
            actionError = SwitchError.badName(name).description
            return
        }
        run(for: name) { switcher in
            try switcher.capture(into: name, dryRun: true)
        } onSuccess: { [weak self] plan in
            self?.pendingCapture = plan
        }
    }

    func cancelCapture() {
        pendingCapture = nil
        actionError = nil
    }

    func confirmCapture() {
        guard let plan = pendingCapture else { return }
        run(for: plan.name) { switcher in
            try switcher.capture(into: plan.name, dryRun: false)
        } onSuccess: { [weak self] done in
            guard let self else { return }
            pendingCapture = nil
            captureName = ""
            note("captured the current login as \(done.name) (\(done.byteCount) bytes)",
                 kind: .captured)
            Task { await self.refresh() }
        }
    }

    /// Renews an inactive slot's access token; the refresher refuses the live one.
    func refreshCredentials(for name: String) {
        guard !isFake(name), !refuseIfBusy() else { return }
        guard let row = rows.first(where: { $0.name == name }) else { return }
        guard !row.slot.isActive else {
            actionError = "\(name) is the live login: Claude Code refreshes that one"
            return
        }
        guard let payload = row.slot.payload else {
            actionError = "\(name) has no readable stored payload to refresh"
            return
        }
        busySlot = name
        actionError = nil
        let refresher = self.refresher
        Task { [weak self] in
            let result: Result<OAuthCredentials, Error>
            do {
                result = .success(try await refresher.refresh(slot: name, payload: payload))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            // Cleared last, once the row is fully described: clearing it first left a
            // frame where the row looked idle but did not yet wear "Retry save",
            // which is the one state the owner must not miss.
            defer { busySlot = nil }
            switch result {
            case .success(let credentials):
                note("refreshed \(name), valid until \(Format.time(credentials.expiry))",
                     kind: .refreshed)
                // A renewal can succeed by storing tokens that were held in memory, so the
                // "Retry save" state has to be re-read here too, not only after a failure.
                await refreshUnstoredSlots()
                await reloadSlots()
                await pollAccount(named: name)
            case .failure(let error):
                let text = (error as? RefreshError)?.description ?? "\(error)"
                actionError = text
                note("refresh failed for \(name): \(text)", kind: .failed)
                await refreshUnstoredSlots()
            }
        }
    }

    /// Writes rotated tokens the keychain refused.  No network call: another
    /// rotation would kill the only tokens that still work.
    func retryStoringTokens(for name: String) {
        guard !isFake(name), !refuseIfBusy() else { return }
        busySlot = name
        let refresher = self.refresher
        Task { [weak self] in
            var failure: String?
            do {
                try await refresher.retryWriteBack(slot: name)
            } catch {
                failure = (error as? RefreshError)?.description ?? "\(error)"
            }
            guard let self else { return }
            // Cleared last, so the row never looks idle while still wearing "Retry save".
            defer { busySlot = nil }
            actionError = failure
            note(failure.map { "retry failed for \(name): \($0)" } ?? "stored the rotated tokens for \(name)",
                 kind: failure == nil ? .note : .failed)
            await refreshUnstoredSlots()
            await reloadSlots()
        }
    }

    /// Which slots hold rotated tokens the keychain refused: in memory only.
    func refreshUnstoredSlots() async {
        var names: Set<String> = []
        for row in rows where await refresher.hasUnstoredTokens(for: row.name) {
            names.insert(row.name)
        }
        unstoredSlots = names
    }

    func note(_ text: String, kind: SwitchLogEntry.Kind = .note) {
        log.add(kind, text)
        NSLog("[ClaudeAccountSwitcher] %@", text)
    }
}

// MARK: - Policy

extension AppModel {
    /// A confirmation or the sign-in panel owns the panel; nothing runs over it.
    var isConfirming: Bool {
        pendingSwitch != nil || pendingCapture != nil || login != nil
    }

    /// The log is private(set); this is how a decision that did not happen reaches it.
    func recordHeld(_ decision: PolicyDecision, held: String) {
        log.record(decision, from: activeRow?.name, held: held)
    }

    /// Computes what Failover or Balance would do, then hands it to the gate,
    /// which is the only thing that may turn it into a switch.
    func evaluatePolicy() {
        guard mode != .manual else {
            policyStatus = nil
            return
        }
        let now = Date()
        let accounts = policyAccounts(now: now)
        let decision = policy.evaluate(mode: mode, accounts: accounts, active: activeRow?.name,
                                       now: now, lastSwitchAt: lastSwitchAt)
        act(on: decision, accounts: accounts, now: now)
    }
}

extension AppModel {
    /// The rows as the policy and the pick see them, from the same rolled reading
    /// the row and the mark are drawn from: a window past its reset is empty again,
    /// so the raw snapshot would have the policy switch away from an account that
    /// has refilled.
    func policyAccounts(now: Date) -> [PolicyAccount] {
        // A CAS_FAKE_ACCOUNTS row has no keychain item: neither a target nor a pick.
        rows.filter { !$0.isFake }.enumerated().map { index, row in
            let usage = row.usage(now: now)
            return PolicyAccount(
                name: row.name,
                // The list order, which is the dragged one: the tie-breaker.
                order: index,
                sessionPercent: usage?.sessionPercent,
                weeklyPercent: usage?.weeklyPercent,
                weeklyResetsAt: usage?.weeklyResetsAt,
                // Which model a session uses is invisible to this app.
                blockedForModelInUse: false,
                isUsable: row.slot.health.isUsable)
        }
    }

    /// The account to use now (see `BestPick`), live or not. Only shown; it never
    /// switches anything, whatever the mode.
    var bestPick: BestPick.Pick? {
        let now = Date()
        return BestPick.choose(policyAccounts(now: now), now: now)
    }
}

// MARK: - Polling

extension AppModel {
    /// One pass: re-read the keychain, then at most one network call.
    func refresh() async {
        await reloadSlots()
        // A sweep already holds the allowance.
        if sweepTask == nil {
            await autoRenewIfDue()
            await pollOneAccount()
        }
        evaluatePolicy()
        logSnapshot()
    }

    /// The Reload button: the owner asked, so the live account is read now —
    /// sweep or no sweep — and if the allowance says not yet, the footer says
    /// when, instead of the button appearing to do nothing.
    func reloadNow() async {
        await reloadSlots()
        guard let row = activeRow ?? rows.first(where: { PollSchedule.canReadUsage($0.slot) }) else {
            note("nothing to read: no account has a usable token")
            return
        }
        let wait = budget.waitTime(now: Date())
        if wait > 0 {
            note("next reading allowed in \(Int(wait.rounded())) s")
            return
        }
        await poll(row)
        evaluatePolicy()
    }

    private func tick() async -> TimeInterval {
        await refresh()
        return nextTickDelay
    }

    /// Late enough for the budget, no later than the next account falling due.
    var nextTickDelay: TimeInterval {
        let now = Date()
        return PollSchedule.delay(for: rows, now: now, budgetWait: budget.waitTime(now: now))
    }

    /// Keychain reads are slow enough to stutter the panel, so they run off the main actor.
    func reloadSlots() async {
        let store = self.store
        let slots = await Task.detached(priority: .userInitiated) { store.slots() }.value
        apply(slots)
    }

    private func apply(_ slots: [Slot]) {
        var previous: [String: AccountRow] = [:]
        for row in rows { previous[row.name] = row }

        var built = slots.map { slot -> AccountRow in
            if var row = previous[slot.name] {
                // A slot that changed health needs its explanation redone: the
                // renewed one was still saying "access token expired", and a
                // slot that went corrupt said nothing at all.
                let changed = row.slot.health != slot.health
                row.slot = slot
                if changed { row.problem = AccountRow.explain(slot) }
                return row
            }
            var row = AccountRow(slot: slot)
            if let snapshot = cached[slot.name] {
                row.usage = snapshot
                row.fetchedAt = snapshot.fetchedAt
                row.isLive = false
            }
            row.problem = AccountRow.explain(slot)
            return row
        }
        built = ordered(built)
        // CAS_FAKE_ACCOUNTS is the total the list should show.
        if fakeAccountCount > built.count {
            built += FakeAccounts.rows(fakeAccountCount - built.count,
                                       excluding: Set(built.map(\.name)))
        }
        rows = built
    }

    /// The dragged order; an account with no stored place keeps the alphabetical
    /// position the keychain read gave it, after the ones that have.
    private func ordered(_ rows: [AccountRow]) -> [AccountRow] {
        var byName: [String: AccountRow] = [:]
        for row in rows { byName[row.name] = row }
        return order.sorted(rows.map(\.name)).compactMap { byName[$0] }
    }

    /// Refuses, with a message, an action aimed at a CAS_FAKE_ACCOUNTS row.
    func isFake(_ name: String) -> Bool {
        guard rows.first(where: { $0.name == name })?.isFake == true else { return false }
        actionError = "\(name) is a fake row from CAS_FAKE_ACCOUNTS — there is no keychain slot behind it"
        return true
    }

    private func pollOneAccount() async {
        guard let row = PollSchedule.next(from: rows, now: Date()) else { return }
        await poll(row)
    }

    /// One account now, if the allowance permits.
    func pollAccount(named name: String) async {
        guard let row = rows.first(where: { $0.name == name }),
              PollSchedule.canReadUsage(row.slot) else { return }
        await poll(row)
    }

    private func poll(_ row: AccountRow) async {
        let now = Date()
        guard budget.allows(now), let token = row.slot.credentials?.accessToken else { return }
        budget.recordRequest(at: now)
        saveBudgetState()
        update(row.name) { $0.lastAttemptAt = now }
        do {
            let snapshot = try await usage.fetch(accessToken: token)
            budget.recordSuccess()
            saveBudgetState()
            apply(snapshot, to: row.name)
        } catch {
            // A stopped sweep cancels the request in flight; that is not the account's fault.
            guard !Task.isCancelled else { return }
            if let error = error as? UsageError {
                handle(error, for: row.name)
            } else {
                update(row.name) { $0.problem = "\(error)" }
            }
        }
    }

    private func apply(_ snapshot: UsageSnapshot, to name: String) {
        update(name) { row in
            row.usage = snapshot
            row.fetchedAt = snapshot.fetchedAt
            row.isLive = true
            row.problem = nil
        }
        cached[name] = snapshot
        do {
            try cache.save(cached)
        } catch {
            NSLog("[ClaudeAccountSwitcher] could not write the usage cache: %@", "\(error)")
        }
    }

    private func handle(_ error: UsageError, for name: String) {
        switch error {
        case .rateLimited(let retryAfter):
            // The numbers on screen stay, labelled with their age.
            let until = budget.recordRateLimit(retryAfter: retryAfter, now: Date())
            saveBudgetState()
            update(name) { $0.problem = "rate limited — retrying at \(Format.clock.string(from: until))" }
        default:
            update(name) { $0.problem = error.bannerText }
        }
    }

    private func update(_ name: String, _ change: (inout AccountRow) -> Void) {
        guard let index = rows.firstIndex(where: { $0.name == name }) else { return }
        change(&rows[index])
    }

    /// `CAS_LOG=1` prints one line per pass.  Tokens never appear here.
    private func logSnapshot() {
        guard ProcessInfo.processInfo.environment["CAS_LOG"] != nil else { return }
        let now = Date()
        let detail = rows.map { row -> String in
            "\(row.name)[\(row.slot.isActive ? "active" : "idle")] "
                + "label=\"\(row.label(now: now).text)\" "
                + "tone=\(row.tone.rawValue)/\(row.label(now: now).toneSource.rawValue) "
                + "source=\(row.isLive ? "live" : "cache") "
                + "health \(row.slot.health.label)"
                + (row.problem.map { " problem: \($0)" } ?? "")
        }.joined(separator: " | ")
        let label = MenuBarTitle.label(for: activeRow)
        NSLog("[CAS] mark=%@ (%@) tooltip=\"%@\" wait=%ds pick=%@ | %@",
              label.tone.rawValue, label.toneSource.rawValue, label.text,
              Int(budget.waitTime(now: now)), bestPick?.name ?? "none", detail)
    }
}

// MARK: - Renaming, removing, reordering

extension AppModel {
    /// The row shows a field instead of its name; nothing is written until it is submitted.
    func beginRename(of name: String) {
        guard !isFake(name), !refuseIfBusy() else { return }
        // Renewed tokens are held against the old name, and the copy would not carry them.
        guard !unstoredSlots.contains(name) else {
            actionError = "\(name) is holding renewed tokens that are not saved yet — use Retry save first"
            return
        }
        actionError = nil
        removing = nil
        renaming = name
    }

    func cancelRename() {
        renaming = nil
        actionError = nil
    }

    /// A rename is a write under the new name and a delete of the old, in that order.
    func rename(_ old: String, to typed: String) {
        let new = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard renaming == old, !isFake(old) else { return }
        guard new != old else { return cancelRename() }
        guard Switcher.isValidName(new) else {
            actionError = SlotEditError.badName(new).description
            return
        }
        if let taken = rows.first(where: { $0.name == new }) {
            actionError = SlotEditError.nameTaken(new, email: taken.slot.email).description
            return
        }
        actionError = nil
        run(for: old) { switcher in
            try switcher.rename(old, to: new)
        } onSuccess: { [weak self] result in
            guard let self else { return }
            renaming = nil
            setOrder(order.renamed(result.from, to: result.to))
            note("renamed \(result.from) → \(result.to)"
                 + (result.movedMarker ? ", and the active-login marker with it" : "")
                 + (result.oldItemLeftBehind
                    ? " — the old keychain item is still there, so \(result.from) may reappear"
                    : ""),
                 kind: result.oldItemLeftBehind ? .failed : .note)
            Task { await self.refresh() }
        }
    }

    /// The row asks first: this is the one action that cannot be undone.
    func askToRemove(_ name: String) {
        guard !isFake(name), !refuseIfBusy() else { return }
        guard rows.first(where: { $0.name == name })?.slot.isActive != true else {
            actionError = SlotEditError.holdsLiveLogin(name, why: "it is the active login").description
            return
        }
        actionError = nil
        renaming = nil
        removing = name
    }

    func cancelRemove() {
        removing = nil
        actionError = nil
    }

    func confirmRemove() {
        guard let name = removing, !isFake(name) else { return }
        actionError = nil
        run(for: name) { switcher in
            try switcher.remove(name)
        } onSuccess: { [weak self] result in
            guard let self else { return }
            removing = nil
            setOrder(order.without(result.name))
            note("removed \(result.name)"
                 + (result.email.map { " (\(Redact.email($0)))" } ?? "")
                 + " — its stored login is gone")
            Task { await self.refresh() }
        }
    }

    /// A drag: the dragged account takes the row it was dropped on, and the whole list
    /// is stored, so the policy's tie-breaker matches what is on screen.
    func move(_ name: String, onto target: String) {
        let visible = rows.filter { !$0.isFake }.map(\.name)
        guard visible.contains(name), visible.contains(target), name != target else { return }
        setOrder(SlotOrder(SlotOrder.moving(name, onto: target, in: visible)))
        evaluatePolicy()
    }

    private func setOrder(_ new: SlotOrder) {
        order = new
        preferences.set(new.names, forKey: Self.orderKey)
        rows = ordered(rows.filter { !$0.isFake }) + rows.filter(\.isFake)
    }
}

// MARK: - Whose turn it is

/// Which account the next reading is spent on, and how long to wait for it.
/// Pure: given the rows and a time it answers the same way every time, so the
/// rule that stopped an account from starving is checked over simulated hours
/// rather than by watching the app.
enum PollSchedule {
    static let active: TimeInterval = 120
    /// The active account, when one of its windows is nearly gone.
    static let activeWhenLow: TimeInterval = 30
    static let inactive: TimeInterval = 600
    static let lowRemaining = 15

    /// An expired slot keeps its cached numbers until it is renewed.
    static func canReadUsage(_ slot: Slot) -> Bool {
        guard slot.health == .ok, let credentials = slot.credentials else { return false }
        return credentials.canReadUsage
    }

    static func interval(for row: AccountRow) -> TimeInterval {
        guard row.slot.isActive else { return inactive }
        return (row.tightestRemaining ?? 100) < lowRemaining ? activeWhenLow : active
    }

    /// The account most overdue for a reading, measured against its own
    /// interval rather than the clock.
    ///
    /// Preferring the active account outright starved the others: it falls due
    /// every two minutes, the loop wakes when it does, so it won every turn and
    /// the inactive accounts were never read at all. Overdue-ness is a ratio,
    /// so an account on the ten-minute interval overtakes the active one once
    /// it is proportionally further behind. Judged by the last attempt, not the
    /// last success, so one account that keeps failing cannot starve the rest.
    static func next(from rows: [AccountRow], now: Date) -> AccountRow? {
        let candidates = rows.filter { row in
            guard canReadUsage(row.slot) else { return false }
            // A window reset since the last reading: whatever is on screen is an
            // assumption now, so this account jumps the queue.
            if row.awaitsPostResetReading(now: now), !attemptedSinceReset(row, now: now) { return true }
            guard let last = row.lastAttemptAt else { return true }
            return now.timeIntervalSince(last) >= interval(for: row)
        }
        return candidates.max { left, right in
            overdueness(left, now: now) < overdueness(right, now: now)
        }
    }

    /// A reading already asked for since the reset is not asked for again on the
    /// same grounds — a 429 must not turn into a hammer.
    static func attemptedSinceReset(_ row: AccountRow, now: Date) -> Bool {
        guard let last = row.lastAttemptAt, let fetchedAt = row.fetchedAt else { return false }
        return last > fetchedAt && last > (row.usage?.limits.compactMap(\.resetsAt).filter { $0 <= now }.max() ?? .distantPast)
    }

    static func overdueness(_ row: AccountRow, now: Date) -> Double {
        if row.awaitsPostResetReading(now: now), !attemptedSinceReset(row, now: now) { return .infinity }
        guard let last = row.lastAttemptAt else { return .infinity }
        return now.timeIntervalSince(last) / max(1, interval(for: row))
    }

    /// Late enough for the allowance, no later than the next account falling due
    /// or the next window resetting, and always between 10 s and 2 min so the
    /// countdowns keep moving.
    static func delay(for rows: [AccountRow], now: Date, budgetWait: TimeInterval) -> TimeInterval {
        let due = rows.compactMap { row -> TimeInterval? in
            guard canReadUsage(row.slot) else { return nil }
            if row.awaitsPostResetReading(now: now), !attemptedSinceReset(row, now: now) { return 0 }
            guard let last = row.lastAttemptAt else { return 0 }
            return max(0, interval(for: row) - now.timeIntervalSince(last))
        }.min() ?? active
        // Wake a moment after a reset so the assumed-empty bar is replaced by a
        // reading, not left standing for the rest of the interval.
        let untilReset = rows.compactMap { row -> TimeInterval? in
            guard canReadUsage(row.slot), let reset = row.nextReset(after: now) else { return nil }
            return reset.timeIntervalSince(now) + 2
        }.min() ?? .infinity
        return min(max(max(budgetWait, min(due, untilReset)), 10), 120)
    }
}
