import Foundation

public enum SlotEditError: Error, Equatable, CustomStringConvertible {
    case busy(String)
    case badName(String)
    case unchanged(String)
    case noSuchSlot(String)
    case nameTaken(String, email: String?)
    /// A service name outside the login prefix, or the live item itself.
    case protectedService(String)
    /// Removing this one would leave the live login with nowhere to be saved.
    case holdsLiveLogin(String, why: String)
    case copyFailed(String, String)
    /// The new item did not read back as what was written; the old one is untouched.
    case verifyFailed(String, String)
    case markerFailed(String, String)
    case deleteFailed(String, String)

    public var description: String {
        switch self {
        case .busy(let why): return "a switch is already running: \(why)"
        case .badName(let name): return "\"\(name)\" is not a usable slot name (letters, digits, . _ -)"
        case .unchanged(let name): return "\"\(name)\" is already its name"
        case .noSuchSlot(let name): return "no slot named \"\(name)\""
        case .nameTaken(let name, let email):
            return "\"\(name)\" is already an account here\(email.map { " (\($0))" } ?? "")"
                + " — pick another name"
        case .protectedService(let service):
            return "refused: \"\(service)\" is not one of this app's login slots"
        case .holdsLiveLogin(let name, let why):
            return "\"\(name)\" cannot be removed: \(why). Switch to another account first"
        case .copyFailed(let name, let why):
            return "\"\(name)\" was not renamed (\(why)) — nothing was changed"
        case .verifyFailed(let name, let why):
            return "the new item \"\(name)\" did not read back as what was written (\(why))"
        case .markerFailed(let name, let why):
            return "the active-login marker could not be moved to \"\(name)\" (\(why))"
        case .deleteFailed(let name, let why): return "\"\(name)\" was not removed: \(why)"
        }
    }
}

/// What a rename did.
public struct RenameResult: Equatable, Sendable {
    public var from: String
    public var to: String
    public var byteCount: Int
    /// The renamed slot was the active login, so the marker moved with it.
    public var movedMarker: Bool
    /// The copy is stored and proved; only the old item's delete failed.
    public var oldItemLeftBehind: Bool

    public init(from: String, to: String, byteCount: Int, movedMarker: Bool,
                oldItemLeftBehind: Bool = false) {
        self.from = from
        self.to = to
        self.byteCount = byteCount
        self.movedMarker = movedMarker
        self.oldItemLeftBehind = oldItemLeftBehind
    }
}

/// What a removal deleted.
public struct RemovalResult: Equatable, Sendable {
    public var name: String
    public var email: String?
    public var byteCount: Int

    public init(name: String, email: String? = nil, byteCount: Int = 0) {
        self.name = name
        self.email = email
        self.byteCount = byteCount
    }
}

// MARK: - Renaming and removing

extension Switcher {
    /// `loginPrefix + name`, refused if that is not one of this app's slots.  The
    /// switcher's writer can reach the live item, and only `switchTo` may use that.
    func slotService(_ name: String) throws -> String {
        let service = loginPrefix + name
        guard !loginPrefix.isEmpty, service.hasPrefix(loginPrefix), service != liveService else {
            throw SlotEditError.protectedService(service)
        }
        return service
    }

    /// A slot's name is its keychain service, so a rename is a write under the new name
    /// and a delete of the old — in that order, and the delete only once the new item has
    /// been read back byte for byte.  A failure anywhere before that leaves the account
    /// where it was.  Renaming the active slot moves the marker too: a marker naming a
    /// slot that no longer exists would leave the next switch's write-back homeless.
    @discardableResult
    public func rename(_ old: String, to new: String) throws -> RenameResult {
        guard Self.isValidName(old) else { throw SlotEditError.badName(old) }
        guard Self.isValidName(new) else { throw SlotEditError.badName(new) }
        guard old != new else { throw SlotEditError.unchanged(new) }
        let oldService = try slotService(old)
        let newService = try slotService(new)

        let lock = try FileLock(url: paths.lock)
        guard lock.tryLock() else {
            throw SlotEditError.busy("another switch holds \(paths.lock.lastPathComponent)")
        }
        defer { lock.unlock() }

        let data: Data
        do {
            data = try reader.data(forService: oldService)
        } catch KeychainError.itemNotFound {
            throw SlotEditError.noSuchSlot(old)
        } catch {
            throw SlotEditError.copyFailed(old, "cannot read the slot: \(error)")
        }
        try refuseIfTaken(new, service: newService)

        do {
            try writer.write(data, service: newService,
                             label: "Claude Code login snapshot for \(new)")
        } catch {
            throw SlotEditError.copyFailed(old, "cannot write \"\(newService)\": \(error)")
        }
        do {
            let readBack = try reader.data(forService: newService)
            guard readBack == data else {
                throw SlotEditError.verifyFailed(
                    new, "\(readBack.count) bytes back, \(data.count) written")
            }
        } catch {
            try? writer.delete(service: newService)
            throw (error as? SlotEditError)
                ?? SlotEditError.verifyFailed(new, "cannot read it back: \(error)")
        }

        var movedMarker = false
        if activeSlotName() == old {
            do {
                try writeMarker(new)
            } catch {
                try? writer.delete(service: newService)
                throw SlotEditError.markerFailed(new, "\(error) — \"\(old)\" is untouched")
            }
            movedMarker = true
        }

        // The account is safe under the new name by now: a delete that fails leaves a
        // duplicate, which is a mess, not a loss.
        var leftBehind = false
        do {
            try writer.delete(service: oldService)
            leftBehind = (try? reader.data(forService: oldService)) != nil
        } catch {
            leftBehind = true
        }
        return RenameResult(from: old, to: new, byteCount: data.count,
                            movedMarker: movedMarker, oldItemLeftBehind: leftBehind)
    }

    private func refuseIfTaken(_ name: String, service: String) throws {
        let existing: Data
        do {
            existing = try reader.data(forService: service)
        } catch KeychainError.itemNotFound {
            return
        } catch {
            // Something is under that name that this app cannot read: not a free name.
            throw SlotEditError.nameTaken(name, email: nil)
        }
        throw SlotEditError.nameTaken(
            name, email: (try? CredentialPayload.parse(existing))?.account?.emailAddress)
    }

    /// Deletes one slot's keychain item and nothing else: not the live item, not
    /// `.claude.json`, not the marker.  The live login is refused — its slot is where the
    /// next switch saves the rotated credentials — whether the marker or the stored email
    /// says so.
    @discardableResult
    public func remove(_ name: String) throws -> RemovalResult {
        guard Self.isValidName(name) else { throw SlotEditError.badName(name) }
        let service = try slotService(name)

        let lock = try FileLock(url: paths.lock)
        guard lock.tryLock() else {
            throw SlotEditError.busy("a switch holds \(paths.lock.lastPathComponent)")
        }
        defer { lock.unlock() }

        if activeSlotName() == name {
            throw SlotEditError.holdsLiveLogin(name, why: "it is the active login")
        }

        var payload: CredentialPayload?
        var byteCount = 0
        do {
            let data = try reader.data(forService: service)
            byteCount = data.count
            payload = try? CredentialPayload.parse(data)
        } catch KeychainError.itemNotFound {
            throw SlotEditError.noSuchSlot(name)
        } catch {
            // A slot this app cannot read is exactly the kind worth deleting.
        }

        if let email = payload?.account?.emailAddress, email == liveAccountEmail() {
            throw SlotEditError.holdsLiveLogin(
                name, why: "it holds \(email), the login Claude Code is using now")
        }

        do {
            try writer.delete(service: service)
        } catch {
            throw SlotEditError.deleteFailed(name, "\(error)")
        }
        guard (try? reader.data(forService: service)) == nil else {
            throw SlotEditError.deleteFailed(name, "the keychain still has \"\(service)\"")
        }
        return RemovalResult(name: name, email: payload?.account?.emailAddress,
                             byteCount: byteCount)
    }

    /// The account `.claude.json` says is live, when it can be read.
    private func liveAccountEmail() -> String? {
        guard let data = try? config.read() else { return nil }
        return config.decodedAccount(in: data)?.emailAddress
    }
}
