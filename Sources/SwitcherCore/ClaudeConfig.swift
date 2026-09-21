import Foundation

/// `~/.claude.json` as far as a switch is concerned: one key to change, a timestamped
/// backup to keep, old backups to prune.
struct ClaudeConfig: Sendable {
    static let oauthAccountKey = "oauthAccount"

    let url: URL

    init(url: URL) {
        self.url = url
    }

    var backupPrefix: String { url.lastPathComponent + ".bak." }

    func read() throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw SwitchError.configFailed("cannot read \(url.path): \(error.localizedDescription)")
        }
    }

    /// The raw bytes of the `oauthAccount` value, or nil when the key is absent.
    func oauthAccountJSON(in data: Data) -> Data? {
        guard let range = try? JSONSplice.valueRange(of: Self.oauthAccountKey, in: data) else {
            return nil
        }
        return data.subdata(in: range)
    }

    func decodedAccount(in data: Data) -> OAuthAccount? {
        guard let json = oauthAccountJSON(in: data) else { return nil }
        return try? JSONDecoder().decode(OAuthAccount.self, from: json)
    }

    /// Same name shape as `claude-acct`'s (`%Y%m%d%H%M%S`), so both tools' backups sort and
    /// prune as one pile.
    func backupURL(now: Date, suffix: Int = 0) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let extra = suffix == 0 ? "" : "-\(suffix)"
        return url.deletingLastPathComponent()
            .appendingPathComponent(backupPrefix + formatter.string(from: now) + extra)
    }

    @discardableResult
    func backup(_ data: Data, now: Date) throws -> URL {
        var destination = backupURL(now: now)
        var suffix = 0
        // Two switches inside one second must not overwrite each other's backup.
        while FileManager.default.fileExists(atPath: destination.path), suffix < 100 {
            suffix += 1
            destination = backupURL(now: now, suffix: suffix)
        }
        do {
            try data.write(to: destination, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: destination.path)
        } catch {
            throw SwitchError.configFailed("cannot write the backup \(destination.lastPathComponent): \(error.localizedDescription)")
        }
        return destination
    }

    /// Newest first.
    func backups() -> [URL] {
        let directory = url.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(backupPrefix) }
            .sorted(by: >)
            .map { directory.appendingPathComponent($0) }
    }

    /// A backup that will not delete never fails a switch that has already worked.
    @discardableResult
    func pruneBackups(keeping: Int) -> [URL] {
        let all = backups()
        guard all.count > keeping else { return [] }
        var removed: [URL] = []
        for old in all.dropFirst(keeping) {
            if (try? FileManager.default.removeItem(at: old)) != nil { removed.append(old) }
        }
        return removed
    }

    /// Replaces the `oauthAccount` value and nothing else, then reads the file back and
    /// checks every other top-level key is exactly what it was.
    func replaceOAuthAccount(with value: Data, in original: Data) throws {
        guard let wanted = (try? JSONSerialization.jsonObject(with: value)) as? [String: Any] else {
            throw SwitchError.configFailed("the slot's oauthAccount is not a JSON object")
        }
        guard let before = try? JSONSerialization.jsonObject(with: original) as? [String: Any] else {
            throw SwitchError.configFailed("\(url.lastPathComponent) is not valid JSON — refusing to write over it")
        }

        let updated: Data
        do {
            updated = try JSONSplice.replace(Self.oauthAccountKey, in: original, with: value)
        } catch JSONSplice.SpliceError.keyNotFound {
            // No oauthAccount at all (a fresh install): the key can only be added by a full re-encode.
            var root = before
            root[Self.oauthAccountKey] = wanted
            updated = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw SwitchError.configFailed("\(error)")
        }

        guard ((try? JSONSerialization.jsonObject(with: updated)) as? [String: Any]) != nil else {
            throw SwitchError.configFailed("the edited config did not parse — nothing was written")
        }
        try writeAtomically(updated)
        try verify(against: before, expecting: wanted)
    }

    /// Temp file beside the target, mode set, then `rename(2)`: a reader sees the old file
    /// or the new one, never a half-written one.
    func writeAtomically(_ data: Data) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).new.\(UUID().uuidString)")
        do {
            try data.write(to: temporary, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: temporary.path)
            guard rename(temporary.path, url.path) == 0 else {
                throw SwitchError.configFailed("rename failed: \(String(cString: strerror(errno)))")
            }
        } catch let error as SwitchError {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw SwitchError.configFailed("cannot write \(url.lastPathComponent): \(error.localizedDescription)")
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func verify(against before: [String: Any], expecting wanted: [String: Any]) throws {
        let reread: Data
        do {
            reread = try Data(contentsOf: url)
        } catch {
            throw SwitchError.configFailed("wrote \(url.lastPathComponent) but cannot read it back: \(error.localizedDescription)")
        }
        guard let after = try? JSONSerialization.jsonObject(with: reread) as? [String: Any] else {
            throw SwitchError.configFailed("wrote \(url.lastPathComponent) but it no longer parses")
        }
        guard let written = after[Self.oauthAccountKey] as? [String: Any],
              NSDictionary(dictionary: written).isEqual(to: wanted) else {
            throw SwitchError.configFailed("wrote \(url.lastPathComponent) but oauthAccount is not the account that was asked for")
        }
        for (key, oldValue) in before where key != Self.oauthAccountKey {
            guard let newValue = after[key],
                  NSDictionary(dictionary: [key: oldValue]).isEqual(to: [key: newValue]) else {
                throw SwitchError.configFailed("wrote \(url.lastPathComponent) but the key \"\(key)\" changed")
            }
        }
        let expectedCount = before[Self.oauthAccountKey] == nil ? before.count + 1 : before.count
        guard after.count == expectedCount else {
            throw SwitchError.configFailed("wrote \(url.lastPathComponent) but its top-level keys changed count")
        }
    }

    /// Puts a backup back after a later step failed, with the same atomic write.
    func restore(from backup: URL) throws {
        let data = try Data(contentsOf: backup)
        try writeAtomically(data)
    }
}
