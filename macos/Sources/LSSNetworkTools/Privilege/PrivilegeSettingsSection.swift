import SwiftUI
import ServiceManagement
import LSSXPC

/// Settings → Privileges: helper registration, its health, its tool-chain verdict,
/// how runs get root, and the administrator-authentication cadence (contract §11.2).
struct PrivilegeSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let installer = model.helperInstaller
        Section {
            LabeledContent("Helper") {
                Label(installer.statusText, systemImage: HelperStatusPresentation.symbol(for: installer.status))
                    .foregroundStyle(HelperStatusPresentation.color(for: installer.status))
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Check") {
                Text(model.helperCheck.text)
                    .foregroundStyle(model.helperCheck.color)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            LabeledContent("Tool chain") {
                toolchainText
            }
            if let error = installer.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if installer.status == .requiresApproval {
                Text("An administrator must allow “LSS Network Tools” in System Settings → General → Login Items & Extensions (Allow in the Background), then choose Check Again.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if installer.status == .enabled, case .unreachable = model.helperCheck {
                markdownText(HelperStatusPresentation.unreachableAfterRebuild)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Register") { model.registerHelper() }
                    .disabled(installer.status == .enabled || model.runCoordinator.isActive || model.isReregisteringHelper)
                Button("Unregister") { model.unregisterHelper() }
                    .disabled(installer.status == .notRegistered || model.runCoordinator.isActive || model.authorizationSession.isAuthenticating || model.isReregisteringHelper)
                Button("Open Login Items") { installer.openLoginItems() }
                if model.helperNeedsReregistration {
                    Button("Re-register") { Task { await model.reregisterHelper() } }
                        .disabled(model.runCoordinator.isActive || model.authorizationSession.isAuthenticating || model.isReregisteringHelper)
                }
                Spacer()
                Button("Check Again") { Task { await model.refreshHelper() } }
                    .disabled(model.helperCheck == .checking || model.isReregisteringHelper)
            }
            Picker("Run tasks with", selection: $model.privilegeMode) {
                ForEach(PrivilegeMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Text(modeFootnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Ask for authentication", selection: $model.helperAuthenticationCadence) {
                ForEach(AuthorizationSession.Cadence.allCases) { cadence in
                    Text(cadence.title).tag(cadence)
                }
            }
            Text("Applies when the helper runs a user-owned tool chain. Every five minutes matches sudo; once per app session asks at the first run and not again until you quit or lock.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("Authentication") {
                HStack(spacing: 12) {
                    Text(authenticationText)
                        .foregroundStyle(model.authorizationSession.isAuthenticated ? .primary : .secondary)
                    Button("Lock now") { model.authorizationSession.lock() }
                        .disabled(!model.authorizationSession.isAuthenticated || model.authorizationSession.isAuthenticating)
                }
            }
            Text("The helper serves administrator accounts only — the same rule as sudo; a standard account is refused. It runs only the installed lss-network-tools command-line tool, as root, with the same checked flags the app would give sudo. The script and its launcher must be root-owned and not writable by other users, or the helper refuses the run. When the tools it needs (nmap, jq, python3, tcpdump, speedtest-cli…) and the folders on the way to them are root-owned as well, runs start without a password. When any tool or folder is user-owned — a Homebrew prefix owned by your account is the usual case — the standard macOS authentication dialog asks for an administrator's credentials before the run, at the cadence chosen above; the helper verifies that authentication itself and never runs a user-owned tool chain without it. It cannot start other programs, accept paths outside the tool's output folder (apart from reading your own Wi-Fi scan files), or read the app's settings. Runs that need the engine's own Wi-Fi helper (Task 17 without a CoreWLAN scan from the New Run sheet) never take the helper route.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Privileges")
        }
        .task { await model.refreshHelper() }
    }

    @ViewBuilder
    private var toolchainText: some View {
        switch model.helperToolchain {
        case .trusted:
            Text(HelperToolchainPresentation.rootOwned)
                .foregroundStyle(.green)
                .multilineTextAlignment(.trailing)
        case .untrusted(let reason):
            // One plain line; the validator's full sentence sits in the tooltip and
            // behind "Details" — correct, but too technical for the status row.
            // Neutral colour on purpose: a user-owned Homebrew is the normal state of
            // this Mac, not a warning — the helper works, it asks for authentication.
            VStack(alignment: .trailing, spacing: 4) {
                Text(HelperToolchainPresentation.userOwnedSummary(reason))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("Details") {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .help(reason)
        case .unusable(let reason):
            // No "authentication required" line: no dialog can clear this one.
            Text("Cannot run: \(reason)")
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .unknown:
            Text("Known once the helper answers")
                .foregroundStyle(.secondary)
        }
    }

    private var authenticationText: String {
        guard model.authorizationSession.isAuthenticated, let at = model.authorizationSession.authenticatedAt else {
            return model.authorizationSession.isAuthenticating ? "Authenticating…" : "Not authenticated"
        }
        return "Authenticated at \(at.formatted(date: .omitted, time: .shortened))"
    }

    private var modeFootnote: String {
        switch model.privilegeMode {
        case .helper:
            guard model.isHelperReady else {
                return "Until the helper is enabled and answers, runs fall back to sudo in the terminal pane."
            }
            switch model.helperToolchain {
            case .trusted:
                return "Runs start without a password; their output still appears in the terminal pane. Task 17 then needs the CoreWLAN scan from the New Run sheet."
            case .untrusted:
                return "Runs ask for administrator authentication in the standard macOS dialog before they start, at the cadence below; their output appears in the terminal pane. Task 17 then needs the CoreWLAN scan from the New Run sheet."
            case .unusable:
                return "The helper cannot run the command-line tool as its tool chain stands (see Tool chain above); fix the install or choose “sudo in the terminal pane”."
            case .unknown:
                return "Runs start through the helper; whether one asks for administrator authentication first depends on the tool chain the helper reports. Task 17 then needs the CoreWLAN scan from the New Run sheet."
            }
        case .sudoTerminal:
            return "Each run asks for your administrator password in the terminal pane."
        }
    }
}

/// Texts and colours for the helper's state, shared by Settings → Privileges and the
/// Setup & Permissions sheet so both say the same thing.
extension AppModel.HelperCheck {
    var text: String {
        switch self {
        case .unknown: return "Not checked yet"
        case .checking: return "Checking…"
        case .notEnabled: return "Available once the helper is enabled"
        case .ready(let info):
            let build = info.version == LSSHelperBuildVersion ? "" : " (this app is \(LSSHelperBuildVersion))"
            return "Helper \(info.version), protocol \(info.protocolVersion) — ready\(build)"
        case .incompatible(let info):
            return "Helper \(info.version) speaks protocol \(info.protocolVersion); this app needs \(LSSHelperProtocolVersion). Unregister and register again."
        case .unreachable(let message):
            return message
        }
    }

    var color: Color {
        switch self {
        case .ready: .green
        case .incompatible, .unreachable: .red
        case .unknown, .checking, .notEnabled: .secondary
        }
    }
}

/// Texts for the helper's tool-chain verdict, shared by Settings → Privileges and
/// the Setup & Permissions sheet so both say the same thing.
enum HelperToolchainPresentation {
    static let rootOwned = "Root-owned — runs need no password"

    /// One line for an `untrustedToolchain` reason. The validator's sentence names
    /// the search-path entry and the owning uid ("… is owned by uid 501, not root");
    /// the usual case — a Homebrew prefix at /opt/homebrew owned by the current
    /// user — gets a plain-language line, a prefix owned by another account says
    /// so (the current user cannot fix it by chown-ing "their" prefix), anything
    /// else the generic one. The full reason belongs in a tooltip or a "Details"
    /// disclosure next to it.
    static func userOwnedSummary(_ reason: String, currentUID: uid_t = getuid()) -> String {
        guard reason.contains("/opt/homebrew") else {
            return "Tools are user-owned — runs ask for administrator authentication"
        }
        let owner = reason.contains("uid \(currentUID),") || reason.hasSuffix("uid \(currentUID)")
            ? "your account"
            : "another user account"
        return "Homebrew tools under /opt/homebrew belong to \(owner) — runs ask for administrator authentication"
    }
}

enum HelperStatusPresentation {
    static func symbol(for status: SMAppService.Status) -> String {
        switch status {
        case .enabled: "checkmark.shield.fill"
        case .requiresApproval: "hand.raised.fill"
        case .notFound: "exclamationmark.triangle.fill"
        default: "shield.slash"
        }
    }

    static func color(for status: SMAppService.Status) -> Color {
        switch status {
        case .enabled: .green
        case .requiresApproval: .orange
        case .notFound: .red
        default: .secondary
        }
    }

    /// The caption Settings and Setup show when the helper is enabled in launchd but
    /// does not answer: the rebuilt-app case (ad-hoc builds change with every rebuild).
    static let unreachableAfterRebuild = "The helper is enabled but does not answer. The usual cause: after this app was rebuilt or moved, launchd still refers to the old copy (ad-hoc builds change with every rebuild) — register it again (Re-register, or `make install` from the checkout). It also looks like this when the helper refused the caller: it serves administrator accounts only, and the message above says so when that is the case."
    /// Where the approval lives.
    static let approvalCaption = "In System Settings → General → Login Items & Extensions, allow “LSS Network Tools” under Allow in the Background, then choose Check Again."
}
