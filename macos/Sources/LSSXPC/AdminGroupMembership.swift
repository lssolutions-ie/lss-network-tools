import Darwin
import Foundation

/// Membership in the `admin` group (gid 80) — the rule the helper applies to every
/// connection before it serves it. The helper is a password-less stand-in for `sudo`,
/// whose default macOS policy is `%admin ALL=(ALL) ALL`, so it keeps sudo's rule: a
/// standard (non-administrator) account gets no root from it either.
///
/// Uses the Open Directory membership API from `<membership.h>` (`mbr_uid_to_uuid`,
/// `mbr_gid_to_uuid`, `mbr_check_membership`), which honours nested groups and
/// directory-service accounts, unlike `getgrgid(80)->gr_mem`. The header is not part
/// of Swift's Darwin module, so the three functions are resolved from libSystem with
/// `dlsym` at first use. Every failure — a missing symbol, an unknown uid, an error
/// from the API — is reported as `.failed` and treated as "not an administrator".
///
/// Shared by the helper (enforcement) and the app (to explain a refused connection);
/// it lives in LSSXPC so the unit tests can exercise it.
public enum AdminGroupMembership {
    /// `admin` on macOS.
    public static let adminGroupID: gid_t = 80

    public enum Outcome: Equatable, Sendable {
        case member
        case notMember
        /// The question could not be answered; callers fail closed.
        case failed(String)
    }

    /// Whether `uid` belongs to `groupID` (default: `admin`), fail-closed.
    public static func check(uid: uid_t, groupID: gid_t = adminGroupID) -> Outcome {
        guard let api = MembershipAPI.shared else { return .failed("membership API unavailable") }
        var user = [UInt8](repeating: 0, count: 16)
        var group = [UInt8](repeating: 0, count: 16)
        var status = user.withUnsafeMutableBufferPointer { api.uidToUUID(uid, $0.baseAddress!) }
        guard status == 0 else { return .failed("mbr_uid_to_uuid(\(uid)) failed: \(Self.describe(status))") }
        status = group.withUnsafeMutableBufferPointer { api.gidToUUID(groupID, $0.baseAddress!) }
        guard status == 0 else { return .failed("mbr_gid_to_uuid(\(groupID)) failed: \(Self.describe(status))") }
        var isMember: Int32 = 0
        status = user.withUnsafeBufferPointer { userPointer in
            group.withUnsafeBufferPointer { groupPointer in
                api.checkMembership(userPointer.baseAddress!, groupPointer.baseAddress!, &isMember)
            }
        }
        guard status == 0 else { return .failed("mbr_check_membership failed: \(Self.describe(status))") }
        return isMember != 0 ? .member : .notMember
    }

    /// `check(uid:) == .member`; anything else (including an error) is false.
    public static func isAdministrator(uid: uid_t) -> Bool {
        check(uid: uid) == .member
    }

    /// One line for the user when a connection was refused for this reason.
    public static let refusalExplanation = "The privileged helper only serves administrator accounts (members of the admin group), like sudo."

    private static func describe(_ status: Int32) -> String {
        "\(String(cString: strerror(status))) (\(status))"
    }

    /// The three functions, looked up once. `nil` when any symbol is missing.
    private struct MembershipAPI: @unchecked Sendable {
        typealias UIDToUUID = @convention(c) (uid_t, UnsafeMutablePointer<UInt8>) -> Int32
        typealias GIDToUUID = @convention(c) (gid_t, UnsafeMutablePointer<UInt8>) -> Int32
        typealias CheckMembership = @convention(c) (UnsafePointer<UInt8>, UnsafePointer<UInt8>, UnsafeMutablePointer<Int32>) -> Int32

        let uidToUUID: UIDToUUID
        let gidToUUID: GIDToUUID
        let checkMembership: CheckMembership

        static let shared: MembershipAPI? = {
            // RTLD_DEFAULT: search every image already loaded (libSystem is).
            let handle = UnsafeMutableRawPointer(bitPattern: -2)
            func symbol<T>(_ name: String, as type: T.Type) -> T? {
                guard let pointer = dlsym(handle, name) else { return nil }
                return unsafeBitCast(pointer, to: type)
            }
            guard let uidToUUID = symbol("mbr_uid_to_uuid", as: UIDToUUID.self),
                  let gidToUUID = symbol("mbr_gid_to_uuid", as: GIDToUUID.self),
                  let checkMembership = symbol("mbr_check_membership", as: CheckMembership.self) else { return nil }
            return MembershipAPI(uidToUUID: uidToUUID, gidToUUID: gidToUUID, checkMembership: checkMembership)
        }()
    }
}
