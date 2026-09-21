import Foundation

/// The order the owner dragged the accounts into: the list's order and the policy's
/// tie-breaker.  Names only, so it survives a slot that is missing for one read.
public struct SlotOrder: Equatable, Sendable {
    public private(set) var names: [String]

    public init(_ names: [String] = []) {
        // A name twice would give one account two positions; the first wins.
        var seen: Set<String> = []
        self.names = names.filter { seen.insert($0).inserted }
    }

    public func rank(of name: String) -> Int? { names.firstIndex(of: name) }

    /// Stored positions first, in their stored order; a name with no position sorts
    /// last, keeping the order it arrived in.
    public func sorted(_ incoming: [String]) -> [String] {
        incoming.enumerated().sorted { left, right in
            let a = rank(of: left.element) ?? Int.max
            let b = rank(of: right.element) ?? Int.max
            return a == b ? left.offset < right.offset : a < b
        }.map(\.element)
    }

    /// The whole list after dragging `name` onto `target`'s place: the dragged account
    /// takes that position and everything between shifts by one.
    public static func moving(_ name: String, onto target: String, in visible: [String]) -> [String] {
        guard name != target,
              let from = visible.firstIndex(of: name),
              let to = visible.firstIndex(of: target) else { return visible }
        var out = visible
        out.remove(at: from)
        out.insert(name, at: to)
        return out
    }

    /// A renamed account keeps its place.  One that never had a place does not gain one:
    /// it goes on sorting after the accounts that do.
    public func renamed(_ old: String, to new: String) -> SlotOrder {
        guard let index = rank(of: old) else { return self }
        var out = names
        out[index] = new
        // The new name can already hold a place of its own — a rename onto a name the
        // list still remembers from an account that is gone. The renamed account keeps
        // the place it had rather than inheriting a dead one.
        out = out.enumerated().filter { $0.offset == index || $0.element != new }.map(\.element)
        return SlotOrder(out)
    }

    public func without(_ name: String) -> SlotOrder {
        SlotOrder(names.filter { $0 != name })
    }

    /// The stored list with every name that no longer exists dropped. A list that only
    /// ever grows keeps places for accounts that were removed, and hands one back to
    /// whoever takes that name next.
    public func keeping(_ present: [String]) -> SlotOrder {
        let live = Set(present)
        return SlotOrder(names.filter { live.contains($0) })
    }
}
