import Foundation

/// The `claude-acct login` swap.  The only thing in this app that writes the live login.
///
/// Order: lock → read and validate the target → read the config and the live item →
/// save the live credentials into the slot being left → back up the config → replace
/// `oauthAccount` → write the live item → move the marker → prune backups.
/// Nothing is written before the write-back; every step after the backup is undone
/// if the next one fails.
public struct Switcher: Sendable {
    /// Every path is injected so the tests run a whole switch inside a temporary directory.
    public struct Paths: Sendable {
        public var config: URL
        public var activeLogin: URL
        public var lock: URL
        public var backupsKept: Int

        public init(config: URL, activeLogin: URL, lock: URL, backupsKept: Int = 10) {
            self.config = config
            self.activeLogin = activeLogin
            self.lock = lock
            self.backupsKept = backupsKept
        }

        public static var production: Paths {
            let home = URL(fileURLWithPath: NSHomeDirectory())
            return Paths(
                config: home.appendingPathComponent(".claude.json"),
                activeLogin: home.appendingPathComponent(".config/claude-accounts/active-login"),
                // ~/.config/claude-accounts belongs to the shell function.
                lock: UsageCache.defaultDirectory.appendingPathComponent("switch.lock"))
        }
    }

    let reader: KeychainReading
    let writer: KeychainWriting
    let loginPrefix: String
    let liveService: String
    let paths: Paths

    public init(reader: KeychainReading = SystemKeychainReader(),
                writer: KeychainWriting? = nil,
                loginPrefix: String = SlotStore.defaultLoginPrefix,
                liveService: String = SlotStore.defaultLiveService,
                paths: Paths = .production) {
        self.reader = reader
        self.writer = writer ?? SystemKeychainWriter(servicePrefix: loginPrefix,
                                                     writableLiveService: liveService)
        self.loginPrefix = loginPrefix
        self.liveService = liveService
        self.paths = paths
    }

    var config: ClaudeConfig { ClaudeConfig(url: paths.config) }

    /// `claude-acct`'s own rule, so a name made here still works there.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { character in
            character.isLetter || character.isNumber || character == "." || character == "_"
                || character == "-"
        }
    }

    public func activeSlotName() -> String? {
        guard let text = try? String(contentsOf: paths.activeLogin, encoding: .utf8) else { return nil }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

// MARK: - Switching

extension Switcher {
    /// Everything a switch needs, gathered before anything is written.
    private struct Prepared {
        var plan: SwitchPlan
        /// The slot that receives the write-back; the marker's name unless the marker was stale.
        var activeName: String?
        var markerName: String?
        var configData: Data
        var configAccountJSON: Data?
        var liveData: Data
        var liveAccessToken: String
        var targetCredentialsJSON: Data
        var targetAccountJSON: Data
        var targetAccessToken: String
    }

    /// The whole switch.  `dryRun` builds the plan and writes nothing; `confirming` is the
    /// plan the owner read, and the switch is refused if the world moved since.
    @discardableResult
    public func switchTo(_ name: String, dryRun: Bool, confirming: SwitchPlan? = nil,
                         now: Date = Date()) throws -> SwitchPlan {
        guard Self.isValidName(name) else { throw SwitchError.badName(name) }

        let lock = try FileLock(url: paths.lock)
        guard lock.tryLock() else {
            throw SwitchError.busy("another switch holds \(paths.lock.lastPathComponent)")
        }
        defer { lock.unlock() }

        let prepared = try prepare(target: name, now: now)
        if let confirming, confirming.to != prepared.plan.to || confirming.from != prepared.plan.from {
            throw SwitchError.changed(prepared.plan.headline)
        }
        guard !dryRun else { return prepared.plan }
        return try perform(prepared, now: now)
    }

    private func prepare(target name: String, now: Date) throws -> Prepared {
        let service = loginPrefix + name
        let slotData: Data
        do {
            slotData = try reader.data(forService: service)
        } catch KeychainError.itemNotFound {
            throw SwitchError.noSuchSlot(name)
        } catch {
            throw SwitchError.slotUnusable(name, "\(error)")
        }
        let payload: CredentialPayload
        do {
            payload = try CredentialPayload.parse(slotData)
        } catch {
            throw SwitchError.slotUnusable(name, "\(error)")
        }
        guard let credentialsJSON = payload.credentialsJSON else {
            throw SwitchError.slotUnusable(name, "no credentials object in the payload")
        }
        let accountJSON = payload.accountJSON ?? Data("{}".utf8)

        let configData = try config.read()
        guard (try? JSONSerialization.jsonObject(with: configData)) is [String: Any] else {
            throw SwitchError.configFailed("\(paths.config.lastPathComponent) is not valid JSON — refusing to touch it")
        }
        let configAccountJSON = config.oauthAccountJSON(in: configData)
        let liveAccount = config.decodedAccount(in: configData)

        // Always read, even with no slot to save into: it is the only way to put the live
        // item back if a later step fails.
        let liveData: Data
        let liveAccessToken: String
        do {
            liveData = try reader.data(forService: liveService)
            liveAccessToken = try CredentialPayload.parse(liveData, liveShape: true).credentials.accessToken
        } catch {
            throw SwitchError.liveUnreadable("\(error)")
        }

        let markerName = activeSlotName()
        var activeName = markerName
        var warnings: [String] = []
        var steps: [SwitchStep] = []

        // The marker is bookkeeping: `/login` and `claude-acct login` move the live login
        // without touching it.  The write-back goes to the slot that really holds the live
        // account, or nowhere.
        if let markerName, let liveEmail = liveAccount?.emailAddress {
            let storedEmail = storedEmail(of: markerName)
            if storedEmail != liveEmail {
                if let owner = slotName(holding: liveEmail) {
                    warnings.append("the marker said \"\(markerName)\" but the live login is \(liveEmail),"
                                    + " which \"\(owner)\" holds — it is saved back there instead")
                    activeName = owner
                } else if let storedEmail {
                    throw SwitchError.markerStale(markerName, liveEmail: liveEmail, storedEmail: storedEmail)
                }
                // A slot that cannot say whose it is gets the live login written into it.
            }
        }

        let sameAccount = activeName == name
        if let activeName {
            steps.append(SwitchStep(
                title: "save the live credentials back into \"\(activeName)\"",
                detail: "keychain item \"\(loginPrefix)\(activeName)\" ← \(liveData.count) bytes of live credentials"
                    + " plus the current oauthAccount"))
        } else {
            warnings.append("nothing is recorded as the active login, so the credentials being replaced are not saved anywhere first")
        }

        if sameAccount {
            warnings.append("\(name) is already the active login: only its snapshot is refreshed from the live credentials")
            if markerName != name {
                steps.append(SwitchStep(title: "record the active login",
                                        detail: "\(paths.activeLogin.path) ← \(name)"))
            }
        } else {
            // The slot's oauthAccount is spliced into .claude.json verbatim, so an empty one
            // would replace a real account with nothing and leave Claude Code nameless.
            if Self.isEmptyObject(accountJSON), let existing = configAccountJSON,
               !Self.isEmptyObject(existing) {
                throw SwitchError.slotUnusable(
                    name, "it carries no oauthAccount, so switching would blank the account in "
                        + paths.config.lastPathComponent
                        + " — capture or sign in to that slot again first")
            }
            if payload.credentials.refreshTokenIsDead(now: now) {
                warnings.append("\(name)'s refresh token is past its expiry — the switch will work but Claude Code may ask you to log in again")
            }
            if let email = liveAccount?.emailAddress, email == payload.account?.emailAddress {
                warnings.append("the live login and \"\(name)\" are both \(email): check the active-login marker is right")
            }
            steps.append(SwitchStep(
                title: "back up \(paths.config.lastPathComponent)",
                detail: config.backupURL(now: now).lastPathComponent))
            steps.append(SwitchStep(
                title: "set oauthAccount in \(paths.config.lastPathComponent)",
                detail: "\(payload.account?.emailAddress ?? "unknown account"), \(accountJSON.count) bytes;"
                    + " every other key is left byte for byte as it is"))
            steps.append(SwitchStep(
                title: "write the live keychain item",
                detail: "\"\(liveService)\" ← \(credentialsJSON.count) bytes from \"\(service)\""))
            steps.append(SwitchStep(
                title: "record the active login",
                detail: "\(paths.activeLogin.path) ← \(name)"))

            let existing = config.backups().count + 1
            if existing > paths.backupsKept {
                steps.append(SwitchStep(
                    title: "prune old backups",
                    detail: "\(existing - paths.backupsKept) of \(existing) \(config.backupPrefix)* removed, newest \(paths.backupsKept) kept"))
            }
        }

        let from = activeName.map {
            SwitchEndpoint(name: $0, email: liveAccount?.emailAddress, planTier: liveAccount?.planTier)
        }
        let to = SwitchEndpoint(name: name, email: payload.account?.emailAddress,
                                planTier: payload.account?.planTier ?? payload.credentials.rateLimitTier)

        return Prepared(
            plan: SwitchPlan(from: from, to: to, steps: steps, warnings: warnings),
            activeName: activeName, markerName: markerName,
            configData: configData, configAccountJSON: configAccountJSON,
            liveData: liveData, liveAccessToken: liveAccessToken,
            targetCredentialsJSON: credentialsJSON, targetAccountJSON: accountJSON,
            targetAccessToken: payload.credentials.accessToken)
    }

    /// `{}`, or anything that is not a JSON object at all.
    static func isEmptyObject(_ json: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
            return true
        }
        return object.isEmpty
    }

    /// The email a slot says it holds; nil when the slot is missing, corrupt or has no account.
    private func storedEmail(of name: String) -> String? {
        guard let data = try? reader.data(forService: loginPrefix + name),
              let payload = try? CredentialPayload.parse(data) else { return nil }
        return payload.account?.emailAddress
    }

    /// The first slot whose stored account is `email`.
    private func slotName(holding email: String) -> String? {
        guard let services = try? reader.services(withPrefix: loginPrefix) else { return nil }
        for service in services.sorted() {
            let name = String(service.dropFirst(loginPrefix.count))
            if storedEmail(of: name) == email { return name }
        }
        return nil
    }

    private func perform(_ prepared: Prepared, now: Date) throws -> SwitchPlan {
        var plan = prepared.plan
        var index = 0
        func complete() {
            if index < plan.steps.count { plan.steps[index].done = true }
            index += 1
        }

        // Write-back first.  If it fails nothing else is attempted: the rotated refresh
        // token that exists only in the live item would otherwise be lost.
        if let activeName = prepared.activeName {
            do {
                let snapshot = try CredentialPayload.slotPayload(
                    credentials: prepared.liveData, account: prepared.configAccountJSON)
                try write(snapshot, service: loginPrefix + activeName,
                          label: "Claude Code login snapshot for \(activeName)",
                          verifyingAccessToken: prepared.liveAccessToken)
            } catch {
                throw SwitchError.writeBackFailed(activeName, "\(error)")
            }
            complete()
        }

        // The live item already holds this account; loading the slot over it would replace
        // a rotated refresh token with a stale one.
        if plan.isNoOp {
            if prepared.markerName != plan.to.name {
                do {
                    try writeMarker(plan.to.name)
                } catch {
                    throw SwitchError.markerFailed("\(error)", rolledBack: false)
                }
                complete()
            }
            plan.performed = true
            return plan
        }

        let backup: URL
        do {
            backup = try config.backup(prepared.configData, now: now)
        } catch let error as SwitchError {
            throw error
        } catch {
            throw SwitchError.configFailed("cannot back up \(paths.config.lastPathComponent): \(error.localizedDescription)")
        }
        plan.backupURL = backup
        complete()

        do {
            try config.replaceOAuthAccount(with: prepared.targetAccountJSON, in: prepared.configData)
        } catch {
            try? config.restore(from: backup)
            throw error
        }
        complete()

        // Claude Code reads the live item through `security` on every launch, so an item whose
        // partition list names a cdhash rather than `apple-tool:` asks for the keychain
        // password once per launch — once per *concurrent* launch, in fact, which is what a
        // wall of identical dialogs is. `-U` would keep that list; only a delete replaces it,
        // and the switch is replacing these bytes anyway, so it costs nothing here.
        let recreating = KeychainAudit.didPrompt(liveService)
        if recreating { try? writer.delete(service: liveService) }
        do {
            // No label: renaming Claude Code's own item is not this app's business.
            try write(prepared.targetCredentialsJSON, service: liveService,
                      label: "", verifyingAccessToken: prepared.targetAccessToken)
            if recreating {
                KeychainAudit.clearPrompt(liveService)
                KeychainAudit.record("settled", service: liveService,
                                     outcome: "recreated by security — partition list apple-tool: now")
            }
        } catch {
            let configBack = (try? config.restore(from: backup)) != nil
            // A refused write left the item alone; one that was accepted but read back
            // wrong has replaced it — and if the delete above already took it, the bytes
            // have to go back whatever the error was.
            let liveBack = (!recreating && !(error is WriteFailure)) || restoreLive(prepared)
            throw SwitchError.keychainFailed("\(error)", rolledBack: configBack && liveBack)
        }
        complete()

        // A stale marker would make the NEXT switch save the new account's credentials
        // into the old account's slot, so this step is undone too.
        do {
            try writeMarker(plan.to.name)
        } catch {
            let configBack = (try? config.restore(from: backup)) != nil
            let liveBack = restoreLive(prepared)
            throw SwitchError.markerFailed("\(error)", rolledBack: configBack && liveBack)
        }
        complete()

        plan.prunedBackups = config.pruneBackups(keeping: paths.backupsKept).count
        if index < plan.steps.count { plan.steps[index].done = true }

        plan.performed = true
        return plan
    }

    private func restoreLive(_ prepared: Prepared) -> Bool {
        (try? write(prepared.liveData, service: liveService, label: "",
                    verifyingAccessToken: prepared.liveAccessToken)) != nil
    }

    /// Writes a keychain item and reads it back: a keychain that accepts a write and stores
    /// something else is exactly what `security -i` did to a slot once.
    func write(_ data: Data, service: String, label: String,
               verifyingAccessToken expected: String?) throws {
        try writer.write(data, service: service, label: label)
        guard let expected else { return }
        let readBack: Data
        do {
            readBack = try reader.data(forService: service)
        } catch {
            throw WriteFailure("wrote \"\(service)\" but cannot read it back: \(error)")
        }
        let parsed = try? CredentialPayload.parse(readBack, liveShape: service == liveService)
        guard let parsed, parsed.credentials.accessToken == expected else {
            throw WriteFailure(
                "\"\(service)\" came back as \(readBack.count) bytes that are not the credentials just written")
        }
    }

    /// Not a `SwitchError`: only the caller knows which step failed.
    struct WriteFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    func writeMarker(_ name: String) throws {
        do {
            let directory = paths.activeLogin.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try Data((name + "\n").utf8).write(to: paths.activeLogin, options: [.atomic])
        } catch {
            throw WriteFailure(error.localizedDescription)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: paths.activeLogin.path)
        guard activeSlotName() == name else {
            throw WriteFailure("the marker does not read back as \"\(name)\"")
        }
    }
}

// MARK: - Capture

extension Switcher {
    /// `claude-acct capture`: store the live login as a named slot and record it as active.
    /// Writes one keychain item and the marker; never the live item or `.claude.json`.
    @discardableResult
    public func capture(into name: String, dryRun: Bool, now: Date = Date()) throws -> CapturePlan {
        guard Self.isValidName(name) else { throw SwitchError.badName(name) }

        let lock = try FileLock(url: paths.lock)
        guard lock.tryLock() else {
            throw SwitchError.busy("a switch holds \(paths.lock.lastPathComponent)")
        }
        defer { lock.unlock() }

        let liveData: Data
        do {
            liveData = try reader.data(forService: liveService)
            _ = try CredentialPayload.parse(liveData, liveShape: true)
        } catch {
            throw SwitchError.liveUnreadable("\(error)")
        }

        let configData = (try? config.read()) ?? Data()
        let accountJSON = configData.isEmpty ? nil : config.oauthAccountJSON(in: configData)
        let liveEmail = configData.isEmpty ? nil : config.decodedAccount(in: configData)?.emailAddress

        // A slot that exists but cannot be read is not replaced: the dry run could not say
        // whose login it was overwriting.
        let service = loginPrefix + name
        let existingData: Data?
        do {
            existingData = try reader.data(forService: service)
        } catch KeychainError.itemNotFound {
            existingData = nil
        } catch {
            throw SwitchError.slotUnusable(name, "cannot read the slot this would replace: \(error)")
        }
        let existing = existingData.flatMap { try? CredentialPayload.parse($0) }

        var warnings: [String] = []
        if accountJSON == nil {
            warnings.append("no oauthAccount in \(paths.config.lastPathComponent): the slot will carry credentials but no email")
        }
        if let existingEmail = existing?.account?.emailAddress, let liveEmail, existingEmail != liveEmail {
            warnings.append("\"\(name)\" currently holds \(existingEmail); this replaces it with \(liveEmail)")
        }
        if existingData != nil, existing == nil {
            warnings.append("\"\(name)\" is unreadable or corrupt today — this replaces it, which is the fix")
        }
        if activeSlotName() != name {
            warnings.append("this also records \"\(name)\" as the active login, because the credentials being stored ARE the live ones")
        }

        let payload = try CredentialPayload.slotPayload(credentials: liveData, account: accountJSON)
        var plan = CapturePlan(name: name, service: service, liveEmail: liveEmail,
                               replacingEmail: existing?.account?.emailAddress,
                               slotExists: existingData != nil, byteCount: payload.count,
                               warnings: warnings)
        guard !dryRun else { return plan }

        let parsed = try CredentialPayload.parse(payload)
        try write(payload, service: service, label: "Claude Code login snapshot for \(name)",
                  verifyingAccessToken: parsed.credentials.accessToken)
        // The snapshot is stored and verified; a marker failure is reported, not rolled back.
        do {
            try writeMarker(name)
        } catch {
            throw SwitchError.markerFailed("\(error)", rolledBack: false)
        }
        plan.performed = true
        return plan
    }
}
