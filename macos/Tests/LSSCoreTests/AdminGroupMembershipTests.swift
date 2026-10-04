import Darwin
import Foundation
import Testing
import LSSXPC

/// The helper serves administrators only (`HelperService.listener(_:shouldAcceptNewConnection:)`);
/// this is the check it uses, exercised against the system accounts every Mac has.
@Suite("Admin group membership (helper caller rule)")
struct AdminGroupMembershipTests {
    @Test("system and unknown accounts are not administrators", arguments: [
        uid_t(1),                  // daemon
        uid_t(bitPattern: -2),     // nobody
        uid_t(777_777),            // no such account: a synthesised UUID, member of nothing
        uid_t(4_000_000_000),
    ])
    func notAdministrators(_ uid: uid_t) {
        #expect(AdminGroupMembership.check(uid: uid) == .notMember)
        #expect(!AdminGroupMembership.isAdministrator(uid: uid))
    }

    @Test("the membership API answers for real accounts (root and the test user)")
    func apiAnswers() {
        for uid in [uid_t(0), getuid()] {
            let outcome = AdminGroupMembership.check(uid: uid)
            #expect(outcome == .member || outcome == .notMember, "uid \(uid): \(outcome)")
            #expect(AdminGroupMembership.isAdministrator(uid: uid) == (outcome == .member))
        }
    }

    @Test("a user listed in the admin group record is reported as a member")
    func agreesWithGroupDatabase() {
        // gr_mem is flat (no nested groups), so only a positive listing is conclusive.
        guard let group = getgrgid(AdminGroupMembership.adminGroupID), let members = group.pointee.gr_mem,
              let account = getpwuid(getuid()), let name = account.pointee.pw_name else { return }
        let user = String(cString: name)
        var index = 0
        var listed = false
        while let member = members[index] {
            if String(cString: member) == user { listed = true }
            index += 1
        }
        if listed {
            #expect(AdminGroupMembership.check(uid: getuid()) == .member)
        }
        #expect(String(cString: group.pointee.gr_name) == "admin")
    }

    @Test("another group id gives an independent answer; the explanation names the rule")
    func otherGroup() {
        // Everyone belongs to `staff` (20) or `everyone` (12) on macOS; `wheel` (0) has root only.
        #expect(AdminGroupMembership.check(uid: 0, groupID: 0) == .member)
        #expect(AdminGroupMembership.check(uid: uid_t(bitPattern: -2), groupID: 0) == .notMember)
        #expect(AdminGroupMembership.refusalExplanation.contains("administrator"))
        #expect(AdminGroupMembership.adminGroupID == 80)
    }
}
