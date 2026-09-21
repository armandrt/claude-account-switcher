import Foundation

/// The last good reading per slot, on disk so a fresh process shows numbers straight away.
/// Holds percentages, reset times, severities, model names and the reading's time — no
/// tokens, no emails, no account identifiers.  0600 in a 0700 directory, replaced atomically.
public struct UsageCache: Sendable {
    public static var defaultDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Claude Account Switcher")
    }

    /// Bumped whenever the fields below stop meaning what they mean today.
    public static let version = 1

    public let fileURL: URL

    public init(directory: URL = UsageCache.defaultDirectory, fileName: String = "usage-cache.json") {
        self.fileURL = directory.appendingPathComponent(fileName)
    }

    /// Never throws: a cache that cannot be read is a cache miss.
    public func load() -> [String: UsageSnapshot] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(File.self, from: data) else { return [:] }
        // A file written by a later build may mean something else by the same field
        // names. An empty cache shows question marks, which is the honest answer.
        guard file.version <= Self.version else { return [:] }
        return file.slots
    }

    public func save(_ slots: [String: UsageSnapshot]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // The attribute above only applies when this call creates the directory;
        // one that was already there keeps whatever mode it was made with.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: directory.path)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(File(version: Self.version, slots: slots))

        let temporary = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString)")
        do {
            try data.write(to: temporary, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            guard rename(temporary.path, fileURL.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [
                    NSLocalizedDescriptionKey: "rename failed: \(String(cString: strerror(errno)))"])
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    struct File: Codable {
        var version: Int
        var slots: [String: UsageSnapshot]
    }
}
