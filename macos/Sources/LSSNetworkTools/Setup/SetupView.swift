import AppKit
import CoreLocation
import SwiftUI

/// Setup & Permissions: one sheet that walks through everything this ad-hoc-signed,
/// personal-use build needs granted by hand — the command-line tool, the privileged
/// helper's Login Items approval, the administrator authentication, Location
/// Services and Local Network — with deep links to the matching System Settings panes.
/// Opened by `--setup`, the app menu, and on the first launch of each build
/// (`SetupModel.isFirstLaunch`); Done remembers the build.
struct SetupView: View {
    @Environment(AppModel.self) private var model

    static let width: CGFloat = 560
    static let fullHeight: CGFloat = 760
    static let minimumHeight: CGFloat = 480

    private let idealHeight: CGFloat

    init(idealHeight: CGFloat = SetupView.fullHeight) {
        self.idealHeight = min(Self.fullHeight, max(Self.minimumHeight, idealHeight))
    }

    /// Like `NewRunSheet.preferredHeight()`: the full height unless the window is smaller.
    @MainActor
    static func preferredHeight() -> CGFloat {
        let candidates = NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) && $0.sheetParent == nil }
        guard let window = candidates.first(where: \.isKeyWindow) ?? candidates.first else { return fullHeight }
        return min(fullHeight, max(minimumHeight, window.contentLayoutRect.height - NewRunSheet.windowMargin))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    CommandLineToolRow()
                    PrivilegedHelperRow()
                    AdministratorAuthenticationRow()
                    LocationServicesRow()
                    LocalNetworkRow()
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: Self.width)
        .frame(minHeight: Self.minimumHeight, idealHeight: idealHeight)
        .task {
            model.setup.refreshLocationStatus()
            await model.refreshHelper()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "checklist")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text("Setup & Permissions")
                    .font(.title2.weight(.semibold))
                markdownText("This app is ad-hoc signed for personal use. Grant each item once; after a rebuild, register the helper again (`make install` does it).")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Everything here can be changed later in Settings → Privileges and in System Settings → Privacy & Security.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Done") {
                model.setup.markSeen(build: model.guiBuild)
                model.setupPresented = false
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Row scaffold

/// One item: icon, title, a coloured status line, then the row's own buttons and captions.
private struct SetupRow<Content: View>: View {
    let title: String
    let symbol: String
    let status: String
    let statusColor: Color
    /// Tooltip on the status line (the full sentence behind a shortened status).
    var statusHelp: String?
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 24))
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                Text(status)
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .help(statusHelp ?? "")
                content
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct RowCaption: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        markdownText(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TerminalCommand: View {
    let command: String

    var body: some View {
        Text(command)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - 1. Command-line tool

private struct CommandLineToolRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SetupRow(title: "Command-line tool", symbol: "terminal", status: status.text, statusColor: status.color) {
            if let cli = model.cli {
                RowCaption("Script: `\(cli.scriptPath.path(percentEncoded: false))` — launcher: `\(cli.wrapperPath?.path(percentEncoded: false) ?? "/bin/bash <script>")`.")
            }
            if model.cli == nil {
                RowCaption("Install it from a Terminal (the app never installs the engine itself):")
                TerminalCommand(command: "git clone https://github.com/lssolutions-ie/lss-network-tools.git && cd lss-network-tools && sudo ./install.sh")
            } else if model.nonInteractiveGateMessage != nil {
                RowCaption("Update it from the repository root, or let the installed tool update itself:")
                TerminalCommand(command: "sudo ./install.sh")
                TerminalCommand(command: "sudo lss-network-tools --update")
            }
            HStack {
                Button("Re-detect") { Task { await model.refresh() } }
                    .disabled(model.isRefreshing)
                if model.isRefreshing {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    private var status: (text: String, color: Color) {
        guard model.cli != nil else {
            return ("Not installed — expected /usr/local/share/lss-network-tools/install.env", .orange)
        }
        let version = model.cliVersion ?? "unknown version"
        switch model.nonInteractiveSupport {
        case .unknown:
            return (model.isRefreshing ? "Installed (\(version)) — checking non-interactive support…" : "Installed (\(version)) — not checked", .secondary)
        case .supported:
            return ("Installed (\(version)) — non-interactive runs supported", .green)
        case .unsupported:
            return ("Installed (\(version)) — too old: no --run-task, runs cannot start", .orange)
        case .incompatible(let reasons):
            return ("Installed (\(version)) — supported, but the task list differs (\(reasons.count) difference\(reasons.count == 1 ? "" : "s"); see Settings)", .orange)
        }
    }
}

// MARK: - 2. Privileged helper

private struct PrivilegedHelperRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let installer = model.helperInstaller
        SetupRow(
            title: "Privileged helper",
            symbol: HelperStatusPresentation.symbol(for: installer.status),
            status: installer.statusText,
            statusColor: HelperStatusPresentation.color(for: installer.status)
        ) {
            Text(model.helperCheck.text)
                .font(.callout)
                .foregroundStyle(model.helperCheck.color)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let error = installer.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if installer.status == .enabled, case .unreachable = model.helperCheck {
                markdownText(HelperStatusPresentation.unreachableAfterRebuild)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if installer.status == .requiresApproval {
                RowCaption(HelperStatusPresentation.approvalCaption)
            }
            HStack {
                Button("Register") { model.registerHelper() }
                    .disabled(installer.status == .enabled || model.runCoordinator.isActive || model.isReregisteringHelper)
                if model.helperNeedsReregistration {
                    Button("Re-register") { Task { await model.reregisterHelper() } }
                        .disabled(model.runCoordinator.isActive || model.authorizationSession.isAuthenticating || model.isReregisteringHelper)
                }
                Button("Open Login Items") { installer.openLoginItems() }
                Spacer()
                Button("Check Again") { Task { await model.refreshHelper() } }
                    .disabled(model.helperCheck == .checking || model.isReregisteringHelper)
            }
        }
    }
}

// MARK: - 3. Administrator authentication

private struct AdministratorAuthenticationRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        SetupRow(title: "Administrator authentication", symbol: "person.badge.key", status: status.text, statusColor: status.color,
                 statusHelp: toolchainReason) {
            RowCaption("Runs through the helper ask for an administrator's credentials in the standard macOS dialog when the tool chain (nmap, jq, python3… — a Homebrew prefix owned by your account is the usual case) is not root-owned. Authenticate now shows that dialog once; nothing is run.")
            if let reason = toolchainReason {
                DisclosureGroup("Details") {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack {
                Button("Authenticate now") { Task { await model.setup.authenticateNow() } }
                    .disabled(model.authorizationSession.isAuthenticating || model.runCoordinator.isActive)
                if model.authorizationSession.isAuthenticating {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Lock now") { model.setup.lock() }
                    .disabled(!model.authorizationSession.isAuthenticated || model.authorizationSession.isAuthenticating)
            }
            if let outcome = outcomeText {
                Text(outcome.text)
                    .font(.caption)
                    .foregroundStyle(outcome.color)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("Run tasks with", selection: $model.privilegeMode) {
                ForEach(PrivilegeMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Picker("Ask for authentication", selection: $model.helperAuthenticationCadence) {
                ForEach(AuthorizationSession.Cadence.allCases) { cadence in
                    Text(cadence.title).tag(cadence)
                }
            }
        }
    }

    /// The validator's full `untrustedToolchain` sentence (tooltip and Details).
    private var toolchainReason: String? {
        if case .untrusted(let reason) = model.helperToolchain { return reason }
        return nil
    }

    private var status: (text: String, color: Color) {
        let session = model.authorizationSession
        if case .trusted = model.helperToolchain {
            return ("Not needed on this Mac — the helper's tool chain is root-owned", .green)
        }
        if session.isAuthenticating {
            return ("Authenticating…", .secondary)
        }
        if session.isAuthenticated, let at = session.authenticatedAt {
            return ("Authenticated at \(at.formatted(date: .omitted, time: .shortened))", .green)
        }
        switch model.helperToolchain {
        case .untrusted(let reason):
            // Same mapping as Settings → Privileges → Tool chain.
            return ("Not authenticated — \(HelperToolchainPresentation.userOwnedSummary(reason))", .orange)
        case .unusable(let reason):
            return ("The helper cannot run the tool chain: \(reason)", .red)
        case .trusted, .unknown:
            return ("Not authenticated — whether a run needs it is known once the helper answers", .secondary)
        }
    }

    private var outcomeText: (text: String, color: Color)? {
        switch model.setup.authenticationOutcome {
        case .none:
            return nil
        case .authenticated(let at):
            let time = at.formatted(date: .omitted, time: .shortened)
            if model.helperAuthenticationCadence == .everyRun {
                return ("Authenticated at \(time) — with “Every run” each run asks again", .green)
            }
            // A credential dropped since (Unregister, a run under "Every run") is gone;
            // the status line above already says "Not authenticated".
            return model.authorizationSession.isAuthenticated ? ("Authenticated at \(time)", .green) : nil
        case .cancelled:
            return ("Cancelled", .secondary)
        case .failed(let message):
            return (message, .red)
        }
    }
}

// MARK: - 4. Location Services

private struct LocationServicesRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let setup = model.setup
        SetupRow(title: "Location Services (Wi-Fi survey)", symbol: "location", status: status.text, statusColor: status.color) {
            RowCaption("CoreWLAN only reveals network names (SSIDs) and access points to location-authorised apps; Task 17's “Scan this room” needs it. No location data is stored.")
            HStack {
                Button("Request") { Task { await setup.requestLocation() } }
                    .disabled(setup.isRequestingLocation || setup.locationStatus != .notDetermined)
                if setup.isRequestingLocation {
                    ProgressView().controlSize(.small)
                }
                Button("Open Location Settings") { WiFiScanner.openLocationPrivacySettings() }
                Spacer()
                Button("Check Again") { setup.refreshLocationStatus() }
                    .disabled(setup.isRequestingLocation)
            }
        }
    }

    private var status: (text: String, color: Color) {
        if model.setup.isRequestingLocation {
            return ("Waiting for the Location prompt…", .secondary)
        }
        switch model.setup.locationStatus {
        case .notDetermined:
            if model.setup.locationRequestTimedOut {
                return ("No answer to the Location prompt within \(Int(WiFiScanner.authorizationTimeout.components.seconds)) s — it may still be open behind another window or on another space; answer it, then Check Again", .orange)
            }
            return ("Not requested yet", .secondary)
        case .authorizedAlways: return ("Allowed", .green)
        case .denied: return ("Denied — allow it in System Settings", .red)
        case .restricted: return ("Restricted", .orange)
        @unknown default:
            // 4 = authorizedWhenInUse, which macOS does not use; granted if ever reported.
            return model.setup.locationStatus.rawValue == 4 ? ("Allowed", .green) : ("Unknown state (\(model.setup.locationStatus.rawValue))", .orange)
        }
    }
}

// MARK: - 5. Local Network

private struct LocalNetworkRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let setup = model.setup
        SetupRow(title: "Local Network (scans)", symbol: "network", status: status.text, statusColor: status.color) {
            RowCaption("macOS 15 and later ask before an app may use the local network, and offer no way to read that choice back. Request browses for Bonjour services for three seconds so the prompt appears; the audit's scans (ARP, DHCP, DNS, printers, UniFi devices) run as root through the command-line tool afterwards.")
            if let probe = setup.localNetworkProbeState {
                Text(probe)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                Button("Request") { Task { await setup.requestLocalNetwork() } }
                    .disabled(setup.isRequestingLocalNetwork)
                if setup.isRequestingLocalNetwork {
                    ProgressView().controlSize(.small)
                }
                // No deep link reaches the Local Network sub-pane (see
                // `SetupModel.localNetworkSettingsURL`); the status line names it.
                Button("Open Privacy & Security") { SetupModel.openLocalNetworkSettings() }
            }
        }
    }

    private var status: (text: String, color: Color) {
        if model.setup.isRequestingLocalNetwork {
            return ("Requesting…", .secondary)
        }
        guard let at = model.setup.localNetworkRequestedAt else {
            return ("Not requested yet", .secondary)
        }
        return ("Requested at \(at.formatted(date: .omitted, time: .shortened)) — check System Settings → Privacy & Security, then Local Network", .primary)
    }
}
