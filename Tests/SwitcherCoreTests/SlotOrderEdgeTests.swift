import Foundation
import Testing
@testable import SwitcherCore

/// The edges of the dragged order: names the keychain no longer has, and a rename
/// onto one of them.  The row index this list produces is what the policy breaks a
/// tie by, so a place given to the wrong account decides a switch.
@Suite("Account order edges")
struct SlotOrderEdgeTests {
    @Test("a rename onto a name the list still remembers leaves one place, not two")
    func renameOntoARememberedName() {
        // "old" was removed from the keychain but is still in the stored list.
        let order = SlotOrder(["pro", "old", "perso"])
        let renamed = order.renamed("perso", to: "old")
        #expect(renamed.names == ["pro", "old"])
        // The renamed account keeps the place it had rather than inheriting a dead one.
        #expect(renamed.rank(of: "old") == 1)
        #expect(renamed.sorted(["old", "pro"]) == ["pro", "old"])
    }

    @Test("the stored list can be pruned of names that no longer exist")
    func pruning() {
        let order = SlotOrder(["pro", "gone", "perso"])
        #expect(order.keeping(["perso", "pro"]).names == ["pro", "perso"])
        #expect(order.keeping([]).names.isEmpty)
        // Pruning changes nothing for the accounts that are still there.
        #expect(order.keeping(["perso", "pro"]).sorted(["perso", "pro"])
                == order.sorted(["perso", "pro"]))
    }

    @Test("a stored name that is gone cannot take a live account's place")
    func deadNamesDoNotSort() {
        let order = SlotOrder(["ghost", "pro", "perso"])
        #expect(order.sorted(["perso", "pro", "new"]) == ["pro", "perso", "new"])
        #expect(order.rank(of: "ghost") == 0)
        #expect(order.rank(of: "new") == nil)
    }

    @Test("the same name twice in one list still gives two rows")
    func duplicateIncoming() {
        // A rename that failed after its copy leaves the keychain holding both.
        #expect(SlotOrder(["a"]).sorted(["b", "a", "a"]) == ["a", "a", "b"])
    }
}
