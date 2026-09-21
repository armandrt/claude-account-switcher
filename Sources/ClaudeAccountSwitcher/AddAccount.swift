import AppKit
import Foundation
import SwitcherCore

/// The in-app sign-in: name it, open the browser, look at who came back, store
/// it. Nothing live is touched, nothing is written before the email is on
/// screen, and a readable slot is never overwritten unasked.
struct LoginState {
    enum Stage: Equatable {
        case naming
        /// The browser is open and the listener is waiting for the redirect.
        case waiting
        /// The fallback: the code is shown in the browser and pasted here.
        case pasting
        /// Tokens in hand, showing whose account it turned out to be.
        case confirming
        case storing
    }

    /// One sign-in run: a reply from an abandoned run must never land on the next one.
    let id = UUID()
    var stage: Stage = .naming
    var name: String
    /// The name came from a row: a repair replaces one slot and cannot be renamed.
    var isRepair: Bool
    /// What that slot holds today, when anything readable is in it.
    var replacing: String?
    var authorizeURL: URL?
    var manualURL: URL?
    var pasted = ""
    var minted: MintedLogin?
    var warnings: [String] = []
    var error: String?

    var title: String { isRepair ? "Sign in to \"\(name)\" again" : "Add an account" }
}

extension AppModel {
    /// From the footer's +: a new account, name to be typed.
    func beginAddAccount() {
        actionError = nil
        // The footer's + stays live behind this panel, so this may be the second
        // sign-in started: the first one's listener must not answer into it.
        endLoginRun()
        login = LoginState(name: captureName, isRepair: false)
    }

    /// From a row: the same flow, aimed at one slot.
    func beginRepair(of name: String) {
        guard !isFake(name) else { return }
        let existing = rows.first { $0.name == name }
        guard existing?.slot.isActive != true else {
            actionError = Self.liveSlotRefusal(name)
            return
        }
        actionError = nil
        endLoginRun()
        login = LoginState(name: name, isRepair: true,
                           replacing: existing?.slot.email,
                           warnings: repairWarnings(for: existing))
    }

    /// The live slot mirrors the live item; a different account in it would be
    /// overwritten with the live credentials on the next switch.
    static func liveSlotRefusal(_ name: String) -> String {
        "\(name) is the live login. Signing in would put a different account in that slot "
            + "while Claude Code carries on with this one — add it under another name."
    }

    private func repairWarnings(for row: AccountRow?) -> [String] {
        guard let row else { return [] }
        switch row.slot.health {
        case .corrupt:
            return ["\"\(row.name)\" is unreadable today, so signing in again is the repair: "
                    + "the new login replaces what is in there."]
        case .needsRelogin:
            return ["\"\(row.name)\"'s refresh token is dead, which is the one thing a renewal "
                    + "cannot fix. A new sign-in is the only way back."]
        default:
            return ["\"\(row.name)\" currently holds a login that still works"
                    + (row.slot.email.map { " for \($0)" } ?? "")
                    + ". Signing in replaces it."]
        }
    }

    func cancelLogin() {
        endLoginRun()
        login = nil
    }

    /// Drops the socket and the thread waiting on it. The verifier stays: the paste
    /// page is opened mid-wait and a code from either page has to still match.
    private func stopListening() {
        loginTask?.cancel()
        loginTask = nil
        loginListener?.cancel()
        loginListener = nil
    }

    private func endLoginRun() {
        stopListening()
        loginPKCE = nil
    }

    /// Opens the browser and starts listening. The only place the app opens a URL.
    func openSignIn(manual: Bool = false) {
        guard var state = login else { return }
        guard Switcher.isValidName(state.name) else {
            state.error = LoginSlotError.badName(state.name).description
            login = state
            return
        }
        // Refused before the browser opens: a sign-in cannot be undone.
        if !state.isRepair {
            if rows.contains(where: { $0.name == state.name && $0.slot.isActive }) {
                state.error = Self.liveSlotRefusal(state.name)
                login = state
                return
            }
            if let existing = slotWriter.existing(state.name) {
                state.error = LoginSlotError.nameTaken(state.name,
                                                      email: existing.account?.emailAddress).description
                login = state
                return
            }
        }

        // One PKCE pair per sign-in: fresh from the naming screen, kept when the
        // paste page is opened mid-wait so a code from either page still matches.
        let pkce = state.stage == .naming ? PKCE() : (loginPKCE ?? PKCE())
        loginPKCE = pkce
        let client = oauth
        state.error = nil

        if manual {
            stopListening()
            let url = client.authorizeURL(pkce: pkce, redirect: .manual)
            state.manualURL = url
            state.stage = .pasting
            login = state
            openURL(url)
            note("sign-in: opened the browser for \"\(state.name)\", code to be pasted")
            return
        }

        stopListening()
        let listener = LoopbackCallback(expectedState: pkce.state)
        do {
            try listener.start()
        } catch {
            state.warnings.append("The app could not listen for the browser's reply (\(error)), "
                                  + "so the code has to be copied across by hand this time.")
            login = state
            openSignIn(manual: true)
            return
        }
        loginListener = listener

        let url = client.authorizeURL(pkce: pkce, redirect: .loopback(port: listener.port))
        state.authorizeURL = url
        state.stage = .waiting
        login = state
        openURL(url)
        note("sign-in: opened the browser for \"\(state.name)\", listening on 127.0.0.1:\(listener.port)")

        let run = state.id
        loginTask = Task { [weak self] in
            await self?.awaitCallback(listener: listener, pkce: pkce, port: listener.port, run: run)
        }
    }

    private func awaitCallback(listener: LoopbackCallback, pkce: PKCE, port: Int,
                               run: UUID) async {
        let result = await Task.detached(priority: .userInitiated) {
            Result { try listener.wait() }
        }.value
        // The panel may have been cancelled, or moved on to another sign-in, while
        // this one waited; either way this reply is not the one it is showing.
        guard login?.id == run else { return }
        if loginListener === listener { loginListener = nil }

        switch result {
        case .success(let callback):
            if let error = callback.error {
                fail(LoginError.denied(callback.errorDescription ?? error).description,
                     stage: .naming, run: run)
                return
            }
            guard let code = callback.code, let state = callback.state else {
                fail(LoginError.noCode.description, stage: .naming, run: run)
                return
            }
            await exchange(code: code, state: state, pkce: pkce,
                           redirect: .loopback(port: port), run: run)
        case .failure(let error):
            guard let failure = error as? LoopbackCallback.Failure, failure != .cancelled else { return }
            fail("\(failure). Nothing is listening any more — open the sign-in page again.",
                 stage: .naming, run: run)
        }
    }

    /// The paste fallback: `<code>#<state>` comes in through the field.
    func submitPastedCode() {
        guard var state = login, state.stage == .pasting, let pkce = loginPKCE else { return }
        do {
            let (code, returned) = try OAuthLogin.splitPastedCode(state.pasted)
            // Moved on here and not in the task: Return and the button both fire, and
            // a code is good for one exchange.
            let run = state.id
            state.stage = .storing
            state.error = nil
            login = state
            loginTask?.cancel()
            loginTask = Task { [weak self] in
                await self?.exchange(code: code, state: returned, pkce: pkce,
                                     redirect: .manual, run: run)
            }
        } catch {
            fail((error as? LoginError)?.description ?? "\(error)", stage: .pasting, run: state.id)
        }
    }

    private func exchange(code: String, state returnedState: String, pkce: PKCE,
                          redirect: OAuthLogin.Redirect, run: UUID) async {
        guard login?.id == run else { return }
        login?.stage = .storing
        login?.error = nil

        do {
            let minted = try await oauth.complete(code: code, state: returnedState,
                                                  pkce: pkce, redirect: redirect)
            guard var current = login, current.id == run else { return }
            current.minted = minted
            current.stage = .confirming
            current.warnings += duplicateWarnings(for: minted)
            // Spent, and the verifier with it: neither is kept past the exchange.
            current.pasted = ""
            login = current
            loginPKCE = nil
            note("sign-in: \(Redact.email(minted.email)) came back for \"\(current.name)\"")
        } catch {
            fail((error as? LoginError)?.description ?? "\(error)",
                 stage: redirect == .manual ? .pasting : .naming, run: run)
        }
    }

    /// Two slots for one login share one quota, so the panel would double-count it.
    private func duplicateWarnings(for minted: MintedLogin) -> [String] {
        guard let email = minted.email else { return [] }
        let others = rows.filter { $0.slot.email == email && $0.name != login?.name }
        guard !others.isEmpty else { return [] }
        return ["\(email) is already stored as \(others.map(\.name).joined(separator: ", ")). "
                + "Two slots for one account share one quota."]
    }

    /// Back to `.naming` also drops the PKCE pair: the next attempt gets a fresh one.
    private func fail(_ text: String, stage: LoginState.Stage, run: UUID) {
        guard var current = login, current.id == run else { return }
        current.error = text
        current.stage = stage
        login = current
        if stage == .naming { loginPKCE = nil }
        note("sign-in failed: \(text)", kind: .failed)
    }
}

// MARK: - Storing it

extension AppModel {
    /// `loginWriter` is nil in the app, which is what makes this the real
    /// keychain; a test hands it a fake one and nothing leaves the process.
    var slotWriter: LoginSlotWriter {
        LoginSlotWriter(reader: store.reader, writer: loginWriter, loginPrefix: store.loginPrefix)
    }

    /// The only step that writes, after the email has been on screen.
    func confirmLogin() {
        guard var state = login, state.stage == .confirming, let minted = state.minted else { return }
        let name = state.name
        // A switch may have made this slot the live one while the browser was open,
        // and the live slot has to go on mirroring the live item.
        guard !rows.contains(where: { $0.name == name && $0.slot.isActive }) else {
            state.error = Self.liveSlotRefusal(name)
            login = state
            return
        }
        let replacing = state.isRepair
        let writer = slotWriter
        let run = state.id
        state.stage = .storing
        login = state

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try writer.store(minted, as: name, replacing: replacing) }
            }.value
            guard let self else { return }
            switch result {
            case .success(let bytes):
                // The write happened even if the panel has moved on to another sign-in.
                if login?.id == run {
                    endLoginRun()
                    login = nil
                    captureName = ""
                }
                note("signed in and stored \"\(name)\" (\(bytes) bytes)", kind: .captured)
                await reloadSlots()
                await pollAccount(named: name)
            case .failure(let error):
                let text = (error as? LoginSlotError)?.description ?? "\(error)"
                if login?.id == run {
                    login?.error = text
                    login?.stage = .confirming
                }
                // The log carries no email; `nameTaken`'s description does.
                var logged = text
                if case .nameTaken(let taken, _)? = error as? LoginSlotError {
                    logged = "\"\(taken)\" already holds a working login"
                }
                note("could not store \"\(name)\": \(logged)", kind: .failed)
            }
        }
    }
}
