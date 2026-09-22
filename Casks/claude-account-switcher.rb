# The cask, kept in the repository it builds from and installed from the tap
# armandrt/homebrew-tap (Casks/claude-account-switcher.rb).  Each release
# renders this file with the tagged version and the zip's checksum and pushes
# the result there: scripts/update-cask.sh renders, the release workflow pushes.
# It rewrites exactly two lines, `version` and `sha256`, so keep them one per line.
cask "claude-account-switcher" do
  version "0.1.0"
  # All zeros means no release has been rendered from this file yet.
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/armandrt/claude-account-switcher/releases/download/v#{version}/ClaudeAccountSwitcher-#{version}.zip"
  name "Claude Account Switcher"
  desc "Shows every Claude Code account's quota and switches between them"
  homepage "https://github.com/armandrt/claude-account-switcher"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "ClaudeAccountSwitcher.app"

  postflight_steps do
    # Homebrew quarantines every cask download on purpose, so Gatekeeper runs
    # its checks, and `brew install` no longer offers --no-quarantine.  This
    # build is signed ad hoc and not notarised (no Apple Developer Program
    # membership), so a quarantined copy is refused with a misleading "damaged"
    # message.  Clearing the attribute here is the `xattr -dr` a direct
    # downloader runs by hand, done once, in a file anyone can read.
    run "/usr/bin/xattr",
        args:         ["-d", "-r", "com.apple.quarantine", "{{appdir}}/ClaudeAccountSwitcher.app"],
        must_succeed: false,
        print_stderr: true
  end

  # A menu bar item with no Dock icon.  Stopped with a signal rather than
  # `quit:`, which sends an Apple event and gets the terminal an Automation
  # permission dialog.  Homebrew skips a signal on upgrade unless asked, and
  # reopens nothing afterwards — hence the line in the caveats.
  uninstall signal:     ["TERM", "rt.armand.ClaudeAccountSwitcher"],
            on_upgrade: :signal

  # Only what the app itself wrote: cached percentages and reset times, the
  # keychain log, the switch lock, and its preferences.  Never the keychain
  # items (the app's saved logins, or Claude Code's own `Claude Code-credentials`)
  # and never ~/.claude.json: zapping this app must not sign you out of Claude
  # Code, and must not throw away logins it only ever borrowed.
  zap trash: [
    "~/Library/Application Support/Claude Account Switcher",
    "~/Library/Preferences/rt.armand.ClaudeAccountSwitcher.plist",
  ]

  caveats <<~EOS
    This build is not notarised (no Apple Developer Program membership). The cask
    clears the download quarantine for you after installing, which is what a
    direct downloader does by hand with `xattr -dr com.apple.quarantine`.

    `brew upgrade` closes the app and does not reopen it: open it again from
    Applications.
  EOS
end
