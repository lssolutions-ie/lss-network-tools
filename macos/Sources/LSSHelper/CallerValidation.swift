import Foundation
import LSSXPC
import os
import Security

/// Decides which XPC clients may talk to the helper (contract §4.1).
///
/// * **Team ID present** (the helper's own signature, read once at launch): the
///   connection gets `anchor apple generic and identifier "<app>" and
///   certificate leaf[subject.OU] = "<team>"`. The XPC runtime evaluates it against the
///   audit token of every incoming message and invalidates the connection on a mismatch.
/// * **No Team ID** (ad-hoc builds): the requirement degrades to the app's identifier,
///   which anyone can claim with `codesign -s -`, so two more checks apply:
///   1. the requirement also pins the cdhash of the app bundle the helper lives in
///      (`SecStaticCodeCreateWithPath` on `<bundle>.app`, read per connection so a
///      rebuilt app is accepted without restarting the helper). This is enforced per
///      message by the runtime, i.e. against the audit token, so it is immune to pid
///      reuse;
///   2. the connecting process, looked up by pid (`SecCodeCopyGuestWithAttributes` +
///      `kSecGuestAttributePid`), must pass `SecCodeCheckValidity` against the same
///      requirement and `SecCodeCopyPath` must be that `.app`.
///
///   `kSecGuestAttributeAudit` would avoid the pid lookup, but `NSXPCConnection` exposes
///   no public audit token (`auditToken` is SPI), so step 2 is pid based: a process could
///   exit and its pid be reused between the lookup and the check (TOCTOU). Step 1 closes
///   that hole for every message actually delivered, which is why the cdhash pin matters.
///   Ad-hoc mode is for development; it cannot protect against an attacker who can
///   rewrite the app bundle on disk. The helper logs a fault at launch when it runs
///   without a Team ID.
struct CallerValidation: Sendable {
    let teamIdentifier: String?
    /// The `.app` that contains this helper (`<app>/Contents/MacOS/LSSHelper`).
    let appBundle: URL?

    private static let logger = Logger(subsystem: LSSHelperCodeIdentifier, category: "caller")

    init(teamIdentifier: String? = CallerValidation.ownTeamIdentifier(), appBundle: URL? = CallerValidation.enclosingAppBundle()) {
        self.teamIdentifier = teamIdentifier
        self.appBundle = appBundle
    }

    /// Logs the validation mode once; a missing Team ID is logged as a fault.
    func logMode() {
        if let teamIdentifier {
            Self.logger.notice("caller validation: Team ID \(teamIdentifier, privacy: .public), Developer ID requirement")
        } else {
            Self.logger.fault("""
                LSSHelper is running WITHOUT a Team ID (ad-hoc signature). Callers are checked by identifier, \
                the cdhash of the enclosing app bundle and its path only — development builds only.
                """)
        }
    }

    /// Configures `connection` and returns whether to accept it.
    func accept(_ connection: NSXPCConnection) -> Bool {
        guard let requirement = requirement() else {
            Self.logger.error("rejecting pid \(connection.processIdentifier): no usable code requirement (app bundle \(appBundle?.path(percentEncoded: false) ?? "unknown", privacy: .public))")
            return false
        }
        // setCodeSigningRequirement raises on a malformed string; it never is (inputs are
        // validated by LSSCodeRequirement), but parse it first anyway.
        guard let parsed = Self.parse(requirement) else {
            Self.logger.error("rejecting pid \(connection.processIdentifier): requirement does not parse")
            return false
        }
        connection.setCodeSigningRequirement(requirement)
        if teamIdentifier != nil { return true }

        let pid = connection.processIdentifier
        switch Self.check(pid: pid, requirement: parsed, appBundle: appBundle) {
        case .success:
            Self.logger.error("accepted pid \(pid) WITHOUT Team ID validation (ad-hoc build): \(requirement, privacy: .public)")
            return true
        case .failure(let reason):
            Self.logger.error("rejecting pid \(pid): \(reason, privacy: .public)")
            return false
        }
    }

    /// The requirement for this build (nil when an ad-hoc helper cannot locate its app).
    func requirement() -> String? {
        if let teamIdentifier {
            return LSSCodeRequirement.app(teamIdentifier: teamIdentifier, cdhash: nil)
        }
        // Without a cdhash the requirement would be the bare identifier, which any
        // ad-hoc signature can claim: refuse instead.
        guard let appBundle, let cdhash = Self.cdhash(of: appBundle) else { return nil }
        return LSSCodeRequirement.app(teamIdentifier: nil, cdhash: cdhash)
    }

    // MARK: - Security framework

    enum CheckResult: Equatable {
        case success
        case failure(String)
    }

    /// `SecCodeCopyGuestWithAttributes(pid)` → `SecCodeCheckValidity(requirement)` →
    /// `SecCodeCopyPath` must be `appBundle` (or inside it).
    static func check(pid: pid_t, requirement: SecRequirement, appBundle: URL?) -> CheckResult {
        guard let appBundle else { return .failure("the helper is not inside an app bundle") }
        var guest: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        var status = SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest)
        guard status == errSecSuccess, let guest else { return .failure("SecCodeCopyGuestWithAttributes failed (\(status))") }
        status = SecCodeCheckValidity(guest, [], requirement)
        guard status == errSecSuccess else { return .failure("SecCodeCheckValidity failed (\(status))") }
        var staticCode: SecStaticCode?
        status = SecCodeCopyStaticCode(guest, [], &staticCode)
        guard status == errSecSuccess, let staticCode else { return .failure("SecCodeCopyStaticCode failed (\(status))") }
        var pathURL: CFURL?
        status = SecCodeCopyPath(staticCode, [], &pathURL)
        guard status == errSecSuccess, let pathURL else { return .failure("SecCodeCopyPath failed (\(status))") }
        let callerPath = canonicalPath(pathURL as URL)
        let bundlePath = canonicalPath(appBundle)
        guard callerPath == bundlePath || callerPath.hasPrefix(bundlePath + "/") else {
            return .failure("caller \(callerPath) is not \(bundlePath)")
        }
        return .success
    }

    static func parse(_ requirement: String) -> SecRequirement? {
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess else { return nil }
        return parsed
    }

    /// `kSecCodeInfoTeamIdentifier` of this process's own signature (nil when ad hoc).
    static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return signingInformation(of: staticCode)?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Hex cdhash (`kSecCodeInfoUnique`) of the code at `url`, as the running system
    /// would select it (native slice of a universal binary).
    static func cdhash(of url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode,
              let unique = signingInformation(of: staticCode)?[kSecCodeInfoUnique as String] as? Data else { return nil }
        let hex = unique.map { String(format: "%02x", $0) }.joined()
        return LSSCodeRequirement.isValidCDHash(hex) ? hex : nil
    }

    private static func signingInformation(of code: SecStaticCode) -> [String: Any]? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &information) == errSecSuccess else {
            return nil
        }
        return information as? [String: Any]
    }

    /// `Bundle.main.executableURL` is `<app>/Contents/MacOS/<exe>` (for a tool inside an
    /// app's MacOS folder Bundle.main resolves to the app): the app is two levels above
    /// `Contents`. Falls back to this process's own code path.
    static func enclosingAppBundle() -> URL? {
        var candidates: [URL] = []
        if let executable = Bundle.main.executableURL { candidates.append(executable) }
        var code: SecCode?
        var staticCode: SecStaticCode?
        var pathURL: CFURL?
        if SecCodeCopySelf([], &code) == errSecSuccess, let code,
           SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
           SecCodeCopyPath(staticCode, [], &pathURL) == errSecSuccess, let pathURL {
            candidates.append(pathURL as URL)
        }
        for candidate in candidates {
            let resolved = URL(filePath: canonicalPath(candidate))
            if resolved.pathExtension == "app" { return resolved }
            let macOS = resolved.deletingLastPathComponent()
            let contents = macOS.deletingLastPathComponent()
            let app = contents.deletingLastPathComponent()
            if macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents", app.pathExtension == "app" {
                return app
            }
        }
        return nil
    }

    static func canonicalPath(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        guard let resolved = realpath(path, nil) else { return url.standardizedFileURL.path(percentEncoded: false) }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
