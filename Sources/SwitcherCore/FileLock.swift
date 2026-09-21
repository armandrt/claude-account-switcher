import Foundation

/// An advisory `flock` around the whole switch (docs/DESIGN.md §2).
///
/// The zsh version has no lock at all, so two swaps at once — the app and a
/// `claude-acct login` in a terminal — can interleave the write-back, the
/// `.claude.json` edit and the keychain write, and leave the live credentials
/// belonging to one account while `.claude.json` names another.
///
/// `flock` is the right primitive here: the kernel drops the lock when the
/// process dies, so a crash mid-switch cannot leave a stale lock file wedged
/// forever, and a lock file left on disk is harmless (it holds nothing).  Two
/// separate `open()`s conflict even inside one process, so the app cannot race
/// itself either.
///
/// It is only mutual with `claude-acct` once that script takes the same lock —
/// see docs/DESIGN.md §2.
final class FileLock {
    private let descriptor: Int32
    private var held = false

    /// Creates the lock file and its directory if they are missing.  The file
    /// is only ever a handle: nothing is written into it, so its contents can
    /// never disagree with reality.
    init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw SwitchError.busy("cannot open the lock file \(url.path): \(String(cString: strerror(errno)))")
        }
    }

    /// Non-blocking on purpose: a switch that has to wait is a switch the user
    /// should be told about, not one that silently hangs a menu bar app.
    func tryLock() -> Bool {
        guard !held else { return true }
        held = flock(descriptor, LOCK_EX | LOCK_NB) == 0
        return held
    }

    func unlock() {
        guard held else { return }
        _ = flock(descriptor, LOCK_UN)
        held = false
    }

    deinit {
        unlock()
        close(descriptor)
    }
}
