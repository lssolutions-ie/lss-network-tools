import Foundation
import Testing
@testable import LSSCore
@testable import LSSXPC

/// The helper's authentication gate as far as it can be tested without root and
/// without the Security framework (contract §11.2, S2–S3): right names, the dictionary
/// rules, the external-form length rule, the refusal envelope and the protocol-2 request.
@Suite("HelperAuthorization (helper authentication gate)")
struct HelperAuthorizationTests {
    @Test("right names")
    func rightNames() {
        #expect(HelperAuthorization.fiveMinuteRight == "ie.lssolutions.lss-network-tools.helper.run-with-user-owned-tools")
        #expect(HelperAuthorization.sessionRight == "ie.lssolutions.lss-network-tools.helper.run-with-user-owned-tools.session")
        #expect(HelperAuthorization.rights == [HelperAuthorization.fiveMinuteRight, HelperAuthorization.sessionRight])
        // Right names are ASCII (the policy database requires it) and carry no wildcard.
        for right in HelperAuthorization.rights {
            #expect(right.unicodeScalars.allSatisfy { $0.isASCII })
            #expect(!right.contains("*") && !right.hasSuffix("."))
        }
        // The helper accepts only these names from a request; anything else never matches
        // a rule (a typo or a future third right cannot fall back to the 300 s rule).
        #expect(!HelperAuthorization.rights.contains("ie.lssolutions.lss-network-tools.helper.run-with-user-owned-tools.forever"))
        #expect(!HelperAuthorization.ruleMatches(HelperAuthorization.rule(for: HelperAuthorization.fiveMinuteRight),
                                                 right: HelperAuthorization.fiveMinuteRight + ".typo"))
    }

    @Test("an external form is exactly 32 bytes", arguments: [0, 1, 31, 32, 33, 64])
    func externalFormLength(_ count: Int) {
        #expect(HelperAuthorization.externalFormLength == 32)
        #expect(HelperAuthorization.isWellFormed(externalForm: Data(count: count)) == (count == 32))
    }

    @Test("the dictionary rules carry exactly the S3 keys", arguments: HelperAuthorization.rights)
    func ruleKeys(_ right: String) throws {
        let rule = HelperAuthorization.rule(for: right)
        #expect(Set(rule.keys) == Set(HelperAuthorization.ruleKeys + ["comment"]))
        #expect(rule["class"] as? String == "user")
        #expect(rule["group"] as? String == "admin")
        #expect(rule["authenticate-user"] as? Bool == true)
        #expect(rule["allow-root"] as? Bool == false, "the helper is root: it must never satisfy its own right")
        #expect(rule["session-owner"] as? Bool == false)
        #expect(rule["shared"] as? Bool == false, "no reuse by other apps or AuthorizationRefs")
        #expect(rule["timeout"] as? Int == (right == HelperAuthorization.sessionRight ? 2_147_483_647 : 300))
        let comment = try #require(rule["comment"] as? String)
        #expect(!comment.isEmpty)
        // A `rule` key would delegate to a canned rule name, which S3 forbids.
        #expect(rule["rule"] == nil)

        // What `AuthorizationRightSet` receives is the dictionary bridged to CF types:
        // the policy database reads the flags as CFBoolean and `timeout` as CFNumber,
        // and silently applies the key's default when the type is wrong. `as? Bool`
        // alone would also accept an NSNumber 0/1, which bridges to a CFNumber.
        for key in ["authenticate-user", "allow-root", "session-owner", "shared"] {
            #expect(CFGetTypeID(rule[key] as AnyObject) == CFBooleanGetTypeID(), "\(key) must bridge to CFBoolean")
        }
        #expect(CFGetTypeID(rule["timeout"] as AnyObject) == CFNumberGetTypeID())
        #expect(CFGetTypeID(rule["timeout"] as AnyObject) != CFBooleanGetTypeID())
        for key in ["class", "group", "comment"] {
            #expect(CFGetTypeID(rule[key] as AnyObject) == CFStringGetTypeID(), "\(key) must bridge to CFString")
        }
        // The same bridging path `currentRule()` takes when reading the definition back.
        let readBack = try #require((rule as CFDictionary as NSDictionary) as? [String: Any])
        #expect(HelperAuthorization.ruleMatches(readBack, right: right))
    }

    @Test("ruleMatches accepts its own rule and the bridged forms the policy database returns", arguments: HelperAuthorization.rights)
    func ruleMatchesOwnRule(_ right: String) {
        let rule = HelperAuthorization.rule(for: right)
        #expect(HelperAuthorization.ruleMatches(rule, right: right))

        // What `AuthorizationRightGet` hands back: NSString / CFBoolean / CFNumber,
        // plus the bookkeeping keys the database adds.
        var bridged: [String: Any] = [
            "class": NSString(string: "user"),
            "group": NSString(string: "admin"),
            "authenticate-user": true as CFBoolean,
            "allow-root": false as CFBoolean,
            "session-owner": false as CFBoolean,
            "shared": NSNumber(value: false),
            "timeout": NSNumber(value: right == HelperAuthorization.sessionRight ? 2_147_483_647 : 300),
            "comment": NSString(string: "site administrator's note"),
            "created": NSNumber(value: 794_422_604.936),
            "modified": NSNumber(value: 794_422_604.936),
            "version": NSNumber(value: 1),
            "tries": NSNumber(value: 10_000),
        ]
        #expect(HelperAuthorization.ruleMatches(bridged, right: right))
        bridged["timeout"] = NSNumber(value: Int64(right == HelperAuthorization.sessionRight ? 2_147_483_647 : 300))
        #expect(HelperAuthorization.ruleMatches(bridged, right: right))
    }

    @Test("ruleMatches rejects a flipped allow-root, shared = true, another timeout and a missing key", arguments: HelperAuthorization.rights)
    func ruleMatchesRejects(_ right: String) {
        let rule = HelperAuthorization.rule(for: right)

        var flipped = rule
        flipped["allow-root"] = true
        #expect(!HelperAuthorization.ruleMatches(flipped, right: right))
        flipped["allow-root"] = true as CFBoolean
        #expect(!HelperAuthorization.ruleMatches(flipped, right: right))
        flipped["allow-root"] = NSNumber(value: 1)
        #expect(!HelperAuthorization.ruleMatches(flipped, right: right))

        var shared = rule
        shared["shared"] = true
        #expect(!HelperAuthorization.ruleMatches(shared, right: right))

        var timeout = rule
        timeout["timeout"] = 301
        #expect(!HelperAuthorization.ruleMatches(timeout, right: right))
        timeout["timeout"] = true // a boolean is not a number
        #expect(!HelperAuthorization.ruleMatches(timeout, right: right))
        timeout["timeout"] = "300"
        #expect(!HelperAuthorization.ruleMatches(timeout, right: right))

        var otherClass = rule
        otherClass["class"] = "rule"
        #expect(!HelperAuthorization.ruleMatches(otherClass, right: right))
        otherClass["class"] = "allow"
        #expect(!HelperAuthorization.ruleMatches(otherClass, right: right))

        var noAuthentication = rule
        noAuthentication["authenticate-user"] = false
        #expect(!HelperAuthorization.ruleMatches(noAuthentication, right: right))

        var otherGroup = rule
        otherGroup["group"] = "staff"
        #expect(!HelperAuthorization.ruleMatches(otherGroup, right: right))

        for key in HelperAuthorization.ruleKeys {
            var missing = rule
            missing.removeValue(forKey: key)
            #expect(!HelperAuthorization.ruleMatches(missing, right: right), "missing \(key)")
        }
        #expect(!HelperAuthorization.ruleMatches([:], right: right))

        // The other right's rule differs only in timeout, and must not pass as this one.
        let other = HelperAuthorization.rights.first { $0 != right }!
        #expect(!HelperAuthorization.ruleMatches(HelperAuthorization.rule(for: other), right: right))
    }

    @Test("a timeout that is a boolean is not a number, and a number that is not 0/1 is not a boolean")
    func bridging() {
        #expect(HelperAuthorization.int(true) == nil)
        #expect(HelperAuthorization.int(true as CFBoolean) == nil)
        #expect(HelperAuthorization.int(NSNumber(value: 300)) == 300)
        #expect(HelperAuthorization.int(300) == 300)
        #expect(HelperAuthorization.bool(NSNumber(value: 300)) == nil)
        #expect(HelperAuthorization.bool(NSNumber(value: 0)) == false)
        #expect(HelperAuthorization.bool(false) == false)
        #expect(HelperAuthorization.bool("true") == nil)
        #expect(HelperAuthorization.string(NSString(string: "admin")) == "admin")
        #expect(HelperAuthorization.string(1) == nil)
    }

    @Test("dialog text is set")
    func dialogDescription() {
        #expect(HelperAuthorization.dialogDescription == "LSS Network Tools wants to run a network audit as root.")
    }
}

@Suite("HelperRefusal envelope")
struct HelperRefusalTests {
    @Test("round trip through the reply string")
    func roundTrip() {
        let refusal = HelperRefusal(code: "authorizationRequired", message: "The privileged helper runs tools a non-root user can modify only after administrator authentication (search path: /opt/homebrew/bin passes through /opt/homebrew, which is owned by uid 501, not root).")
        let text = refusal.encoded()
        #expect(text.hasPrefix("{"))
        #expect(HelperRefusal.decode(text) == refusal)
        #expect(refusal.isAuthorizationRefusal)
        #expect(refusal.isClearedByAuthentication)
        // `authorizationUnavailable` is about the gate too, but no dialog can clear it:
        // the coordinator must not tell the user to authenticate for it.
        let unavailable = HelperRefusal(code: "authorizationUnavailable", message: "x")
        #expect(unavailable.isAuthorizationRefusal)
        #expect(!unavailable.isClearedByAuthentication)
        #expect(!HelperRefusal(code: "untrustedToolchain", message: "x").isAuthorizationRefusal)
        #expect(!HelperRefusal(code: "busy", message: "x").isAuthorizationRefusal)
        #expect(HelperRefusal(code: "cancelled", message: "x").isCancellation)
        #expect(HelperRefusal.cancelledCode == "cancelled")
        #expect(!refusal.isCancellation)
    }

    @Test("plain text (an older helper, or repairRunPermissions) decodes with code unknown",
          arguments: ["/etc is not a run folder of the CLI.", "", "{not json", "[1,2]", #"{"code":"busy"}"#])
    func plainText(_ text: String) {
        let decoded = HelperRefusal.decode(text)
        #expect(decoded.code == "unknown")
        #expect(decoded.message == text)
    }

    @Test("messages with quotes, newlines and non-ASCII survive")
    func awkwardMessages() {
        let message = "“quoted” — line\nbreak \\ back\u{0}slash ünïcödé"
        let refusal = HelperRefusal(code: "scanFile", message: message)
        #expect(HelperRefusal.decode(refusal.encoded()) == refusal)
    }
}

@Suite("HelperRunRequest (protocol 2)")
struct HelperRunRequestAuthorizationTests {
    @Test("the authorization blob and right round-trip through JSON and default to nil")
    func roundTrip() throws {
        let blob = Data((0..<32).map { UInt8(255 - $0) })
        let request = HelperRunRequest(arguments: ["--run-task", "1"], sshPassword: "pw", progressToken: "0123456789abcdef",
                                       callerUID: 501, authorization: blob, authorizationRight: HelperAuthorization.sessionRight)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(HelperRunRequest.self, from: data)
        #expect(decoded == request)
        #expect(decoded.authorization == blob)
        #expect(decoded.authorizationRight == HelperAuthorization.sessionRight)
        #expect(HelperRunRequest(arguments: []).authorization == nil)
        #expect(HelperRunRequest(arguments: []).authorizationRight == nil)

        // A protocol-1 document (no keys) still decodes.
        let legacy = Data(#"{"token":"ABC-123","arguments":["--run-task","list"]}"#.utf8)
        let legacyDecoded = try JSONDecoder().decode(HelperRunRequest.self, from: legacy)
        #expect(legacyDecoded.authorization == nil)
        #expect(legacyDecoded.authorizationRight == nil)
    }

    @Test("the helper accepts a right only from HelperAuthorization.rights",
          arguments: [nil, "", "ie.lssolutions.lss-network-tools.helper.run-with-user-owned-tools.forever", "system.privilege.admin", "allow"])
    func unknownRightIsRejected(_ right: String?) throws {
        // The rule the helper applies before `AuthorizationGate.verify`: a request on a
        // user-owned tool chain with an external form but no acceptable right name is
        // refused with `authorizationRequired`. The predicate is the same `contains`.
        let request = HelperRunRequest(arguments: ["--run-task", "1"], authorization: Data(count: 32), authorizationRight: right)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(HelperRunRequest.self, from: data)
        #expect(decoded.authorizationRight == right)
        let accepted = decoded.authorizationRight.map(HelperAuthorization.rights.contains) ?? false
        #expect(!accepted, "\(String(describing: right)) must not be accepted")
        for valid in HelperAuthorization.rights {
            #expect(HelperAuthorization.rights.contains(valid))
        }
    }

    @Test("the extra key does not break the validator's wire decoding")
    func wireDecoding() throws {
        // No install record at this path: a request that decodes reaches the install
        // check (installEnvUnreadable); one that does not would be malformedRequest.
        let missing = "/nonexistent/lss-\(UUID().uuidString)/install.env"
        let environment = RequestValidator.Environment(
            installEnvPath: missing,
            fileStatus: { _ in nil },
            resolvePath: { _ in nil },
            readFile: { _, _ in nil },
            homeDirectory: { _ in nil }
        )
        let validator = RequestValidator(environment: environment)
        let request = HelperRunRequest(arguments: ["--run-task", "1", "--interface", "en0", "--client", "A", "--location", "B"],
                                       authorization: Data(count: 32), authorizationRight: HelperAuthorization.fiveMinuteRight)
        #expect(throws: RequestValidator.Refusal.installEnvUnreadable("\(missing) does not exist")) {
            try validator.validate(requestJSON: JSONEncoder().encode(request), callerUID: 501, toolchainPolicy: .report)
        }
    }

    @Test("toolchainTrust verdict words")
    func toolchainVerdictWords() {
        #expect(HelperToolchainVerdict.trusted.rawValue == "trusted")
        #expect(HelperToolchainVerdict.authorizationRequired.rawValue == "authorizationRequired")
        #expect(HelperToolchainVerdict.unusable.rawValue == "unusable")
        #expect(HelperToolchainVerdict(rawValue: "TRUSTED") == nil, "an unknown word must not read as trusted")
    }

    @Test("protocol version 2 (S7)")
    func protocolVersion() {
        // The build version is pinned to macos/VERSION by VersionConsistencyTests.
        #expect(LSSHelperProtocolVersion == 2)
    }
}
