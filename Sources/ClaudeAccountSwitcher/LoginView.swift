import SwiftUI
import SwitcherCore

/// The sign-in panel: name it, open the browser, check who came back, store it.
struct LoginView: View {
    let state: LoginState
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(state.title).font(.system(size: 13, weight: .semibold))
            ForEach(state.warnings, id: \.self) { Warning(text: $0) }

            switch state.stage {
            case .naming: naming
            case .waiting: waiting
            case .pasting: pasting
            case .confirming: confirming
            case .storing: storing
            }

            if let error = state.error {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private func body(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Naming it

extension LoginView {
    private var naming: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !state.isRepair {
                TextField("name", text: Binding(
                    get: { model.login?.name ?? "" },
                    set: { model.login?.name = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit { if !state.name.isEmpty { model.openSignIn() } }
            }
            HStack(spacing: 8) {
                Button("Sign in…") { model.openSignIn() }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.name.isEmpty)
                Button("Cancel") { model.cancelLogin() }.controlSize(.small)
            }
        }
    }
}

// MARK: - Waiting for the browser

extension LoginView {
    private var waiting: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.55).frame(width: 12, height: 12)
                Text("Waiting for the browser…").font(.system(size: 11))
            }
            HStack(spacing: 8) {
                if let url = state.authorizeURL {
                    Button("Open again") { NSWorkspace.shared.open(url) }.controlSize(.small)
                    Button("Copy link") { copy(url) }.controlSize(.small)
                }
                Button("Paste a code instead") { model.openSignIn(manual: true) }
                    .controlSize(.small)
                Button("Cancel") { model.cancelLogin() }.controlSize(.small)
            }
        }
    }

    private var pasting: some View {
        VStack(alignment: .leading, spacing: 8) {
            body("Paste the whole code, # and all.")
            HStack(spacing: 6) {
                TextField("code", text: Binding(
                    get: { model.login?.pasted ?? "" },
                    set: { model.login?.pasted = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit { model.submitPastedCode() }
                Button("Continue") { model.submitPastedCode() }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.pasted.isEmpty)
            }
            HStack(spacing: 8) {
                if let url = state.manualURL {
                    Button("Open again") { NSWorkspace.shared.open(url) }.controlSize(.small)
                    Button("Copy link") { copy(url) }.controlSize(.small)
                }
                Button("Cancel") { model.cancelLogin() }.controlSize(.small)
            }
        }
    }

    private func copy(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
    }

    private var storing: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small).scaleEffect(0.55).frame(width: 12, height: 12)
            Text("Finishing…").font(.system(size: 11))
        }
    }
}

// MARK: - Who came back

extension LoginView {
    /// The browser may have been signed in to something else entirely, so the
    /// email stays: it is the one check worth making before anything is written.
    private var confirming: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let minted = state.minted {
                VStack(alignment: .leading, spacing: 3) {
                    Text(minted.email ?? "no email on this account")
                        .font(.system(size: 12, weight: .medium))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    line("plan", minted.subscriptionType ?? minted.rateLimitTier ?? "—")
                    if let replacing = state.replacing {
                        line("replaces", replacing)
                    }
                }
            }
            HStack(spacing: 8) {
                Button(state.isRepair ? "Replace \"\(state.name)\"" : "Store as \"\(state.name)\"") {
                    model.confirmLogin()
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                Button("Cancel") { model.cancelLogin() }.controlSize(.small)
            }
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 10)).foregroundStyle(.tertiary)
                .frame(width: 66, alignment: .leading)
            Text(value).font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
