import Foundation
import Security
import LSSXPC
import os

/// The helper's side of the tool-chain gate (contract §11.2, S2–S3, S6).
///
/// * `ensureRights` defines `HelperAuthorization.rights` in the policy database with the
///   explicit dictionary rule (`allow-root = false`, `shared = false`, …). It runs as root
///   at helper start, before the listener resumes, and again on demand; it is idempotent
///   and never shows a dialog (`config.modify.` delegates to `is-root`).
/// * `verify` checks the external form a request carries: the credential must satisfy
///   the **one right the request names** **without** `kAuthorizationFlagInteractionAllowed`
///   — the helper never triggers a dialog; an expired credential simply fails — and the
///   ref is released with `AuthorizationFree(ref, [])`, never `.destroyRights`, which
///   would destroy the app's cached credential through the shared authorization token.
///   Credentials are per token, not per right: a credential obtained for the 300 s right
///   would satisfy the session right too (and the other way round), so trying "any
///   right" would let the longer timeout win whatever cadence the user chose. Checking
///   only the named right is what makes the right's `timeout` the bound the helper
///   enforces for that request.
/// * Nothing here logs the external form; outcomes are logged by name and status code.
enum AuthorizationGate {
    enum VerifyFailure: Error, Equatable {
        /// Not exactly `kAuthorizationExternalFormLength` bytes, or not internalisable.
        case malformed
        /// The request named a right outside `HelperAuthorization.rights`.
        case unknownRight
        /// `AuthorizationCopyRights` denied the named right (status).
        case notAuthorized(OSStatus)
        /// A right is missing from the policy database or differs from S3; without the
        /// definition the default rule would decide, which could let root through.
        case rightsMissing
    }

    /// Defines or repairs both rights. True when both match S3 afterwards.
    @discardableResult
    static func ensureRights(logger: Logger) -> Bool {
        var reference: AuthorizationRef?
        let created = AuthorizationCreate(nil, nil, [], &reference)
        guard created == errAuthorizationSuccess, let reference else {
            logger.error("authorization rights: AuthorizationCreate failed (\(created)); the gate is unavailable")
            return false
        }
        defer { _ = AuthorizationFree(reference, []) }

        var installed = true
        for right in HelperAuthorization.rights {
            if let existing = currentRule(for: right), HelperAuthorization.ruleMatches(existing, right: right) {
                logger.notice("authorization right \(right, privacy: .public): unchanged")
                continue
            }
            let rule = HelperAuthorization.rule(for: right) as CFDictionary
            let status = right.withCString { name in
                AuthorizationRightSet(reference, name, rule, HelperAuthorization.dialogDescription as CFString, nil, nil)
            }
            guard status == errAuthorizationSuccess else {
                logger.error("authorization right \(right, privacy: .public): AuthorizationRightSet failed (\(status))")
                installed = false
                continue
            }
            // Read back: the database may have normalised or rejected a key silently.
            if let readBack = currentRule(for: right), HelperAuthorization.ruleMatches(readBack, right: right) {
                logger.notice("authorization right \(right, privacy: .public): installed")
            } else {
                logger.error("authorization right \(right, privacy: .public): written, but the definition read back differs from the rule")
                installed = false
            }
        }
        return installed
    }

    /// Per right: defined in the policy database with exactly the S3 rule. Readable by
    /// any user (`--diagnose`), and checked before every verification.
    static func rightsInstalled() -> [String: Bool] {
        var result: [String: Bool] = [:]
        for right in HelperAuthorization.rights {
            result[right] = currentRule(for: right).map { HelperAuthorization.ruleMatches($0, right: right) } ?? false
        }
        return result
    }

    static var allRightsInstalled: Bool {
        rightsInstalled().values.allSatisfy { $0 }
    }

    /// S2: `right` when the external form's credential satisfies exactly that right
    /// (one of `HelperAuthorization.rights`), or why not.
    static func verify(externalForm: Data, right: String) -> Result<String, VerifyFailure> {
        guard HelperAuthorization.rights.contains(right) else { return .failure(.unknownRight) }
        guard HelperAuthorization.isWellFormed(externalForm: externalForm) else { return .failure(.malformed) }
        // Without our definitions the default rule would judge the request; fail closed.
        guard allRightsInstalled else { return .failure(.rightsMissing) }

        // The 32 bytes are copied into the C struct (never reinterpreted in place).
        var form = AuthorizationExternalForm()
        let copied = withUnsafeMutableBytes(of: &form) { buffer in externalForm.copyBytes(to: buffer) }
        guard copied == HelperAuthorization.externalFormLength else { return .failure(.malformed) }
        var reference: AuthorizationRef?
        let created = AuthorizationCreateFromExternalForm(&form, &reference)
        guard created == errAuthorizationSuccess, let reference else { return .failure(.malformed) }
        // No `.destroyRights`: the app keeps its credential for the cadence it chose.
        defer { _ = AuthorizationFree(reference, []) }

        // Only the named right: the credential is per token, so the right name is the
        // one thing that selects which `timeout` applies. `name` must stay valid for the
        // whole call, hence the nesting.
        let status: OSStatus = right.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPointer in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                // `.extendRights` lets a pre-authorised credential be applied; no
                // `.interactionAllowed`: the helper never asks the user anything.
                return AuthorizationCopyRights(reference, &rights, nil, [.extendRights], nil)
            }
        }
        return status == errAuthorizationSuccess ? .success(right) : .failure(.notAuthorized(status))
    }

    /// The right's current definition, or nil when it is not defined.
    private static func currentRule(for right: String) -> [String: Any]? {
        var definition: CFDictionary?
        let status = right.withCString { name in AuthorizationRightGet(name, &definition) }
        guard status == errAuthorizationSuccess, let definition else { return nil }
        return (definition as NSDictionary) as? [String: Any]
    }
}
