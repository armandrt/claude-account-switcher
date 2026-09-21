<!-- The head of every release's notes. .github/workflows/release.yml fills in
     @VERSION@, @ZIP_SHA256@ and @DMG_SHA256@, then appends GitHub's generated
     notes. Edit the wording here, not in the workflow. -->
## Install

```sh
brew tap armandrt/tap
brew trust armandrt/tap    # Homebrew 7 and later
brew install --cask claude-account-switcher
```

Or download `ClaudeAccountSwitcher-@VERSION@.dmg` below and drag the app into Applications.

**Gatekeeper.** This app is signed ad hoc and not notarised — both need a paid Apple Developer
Program membership this project does not have — so macOS quarantines the download and refuses
it with a misleading "damaged and can't be opened" message. The Homebrew cask clears the
quarantine attribute for you after installing. For a direct download, run once:

```sh
xattr -dr com.apple.quarantine /Applications/ClaudeAccountSwitcher.app
```

(System Settings → Privacy & Security → "Open Anyway" does the same with more clicks, when
macOS offers it.) Or build from source in one command: `scripts/make-app.sh --install`.

Requires macOS 14 (Sonoma) or later.

### Checksums

| file | SHA-256 |
| --- | --- |
| `ClaudeAccountSwitcher-@VERSION@.zip` | `@ZIP_SHA256@` |
| `ClaudeAccountSwitcher-@VERSION@.dmg` | `@DMG_SHA256@` |

`shasum -a 256 -c SHA256SUMS.txt` checks both, from the directory you downloaded them into.
