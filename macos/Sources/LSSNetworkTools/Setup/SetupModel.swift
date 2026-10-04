import AppKit
import CoreLocation
import Foundation
import Network
import Observation
import OSLog
import Defaults

/// State behind the Setup & Permissions sheet (`SetupView`): the permissions this
/// ad-hoc-signed, personal-use build has to be granted by hand — Location for the
/// Wi-Fi survey, Local Network for the scans, the Login Items approval of the
/// privileged helper, the one-off administrator authentication — and the first-launch
/// rule. Everything about the command-line tool and the helper is read from
/// `AppModel`; this class only adds what the sheet needs on top.
///
/// Local Network has no permission API: the only way to make macOS 15+ show its prompt
/// is to use the network — a Bonjour browse for `_services._dns-sd._udp` does it
/// without touching any device — and the only state the app can keep is when it asked.
@MainActor
@Observable
final class SetupModel {
    @ObservationIgnored weak var model: AppModel?

    private let log = Logger(subsystem: "ie.lssolutions.lss-network-tools", category: "setup")

    // MARK: First launch

    /// True while this build's sheet has not been closed with Done.
    static func isFirstLaunch(ofBuild build: String) -> Bool {
        Defaults[.setupSeenForBuild] != build
    }

    /// Done: this build's sheet has been seen.
    func markSeen(build: String) {
        Defaults[.setupSeenForBuild] = build
    }

    // MARK: Location Services (Wi-Fi survey)

    private(set) var locationStatus: CLAuthorizationStatus = WiFiScanner.locationAuthorizationStatus()
    private(set) var isRequestingLocation = false
    /// True when a request ended without an answer (`WiFiScanner.authorizationTimeout`):
    /// the prompt was put up but may sit behind another window or on another space.
    private(set) var locationRequestTimedOut = false

    /// Re-reads the Location status (the user may have changed it in System Settings).
    func refreshLocationStatus() {
        locationStatus = WiFiScanner.locationAuthorizationStatus()
        if locationStatus != .notDetermined {
            locationRequestTimedOut = false
        }
    }

    /// Shows the Location prompt (when the user has not decided yet) and records the answer.
    func requestLocation() async {
        guard !isRequestingLocation else { return }
        isRequestingLocation = true
        defer { isRequestingLocation = false }
        locationStatus = await WiFiScanner.requestLocationAuthorization()
        locationRequestTimedOut = locationStatus == .notDetermined
        log.notice("Location authorisation after request: \(self.locationStatus.rawValue, privacy: .public)")
    }

    // MARK: Local Network (scans)

    /// The Privacy & Security pane. macOS exposes no `Privacy_LocalNetwork` anchor
    /// (checked against the anchors of `SecurityPrivacyExtension.appex` on macOS 26/27;
    /// the sub-pane's internal id `privacy-localnetwork` is not a URL anchor either), so
    /// the deep link stops at the pane and the row tells the user to pick Local Network.
    static let localNetworkSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security")!
    /// How long the Bonjour browse runs; the prompt appears within the first second.
    static let localNetworkProbeDuration: Duration = .seconds(3)
    static let bonjourServiceType = "_services._dns-sd._udp"

    private(set) var localNetworkRequestedAt: Date? = Defaults[.localNetworkRequestedAt]
    private(set) var isRequestingLocalNetwork = false
    /// What the browser reported last ("browsing", "waiting: …"); informational only.
    private(set) var localNetworkProbeState: String?

    /// Starts a Bonjour browse for three seconds, then cancels it. The browse itself
    /// finds nothing of interest; what matters is that macOS shows the Local Network
    /// prompt the first time an app uses the local network.
    func requestLocalNetwork() async {
        guard !isRequestingLocalNetwork else { return }
        isRequestingLocalNetwork = true
        defer { isRequestingLocalNetwork = false }
        localNetworkProbeState = "Browsing for Bonjour services…"
        let now = Date.now
        localNetworkRequestedAt = now
        Defaults[.localNetworkRequestedAt] = now
        let browser = NWBrowser(for: .bonjour(type: Self.bonjourServiceType, domain: nil), using: .tcp)
        // Callbacks arrive on the browse queue; only a String crosses to the main actor.
        browser.stateUpdateHandler = { state in
            let text = Self.describe(state)
            Task { @MainActor [weak self] in
                self?.localNetworkProbeState = text
            }
        }
        browser.start(queue: DispatchQueue(label: "ie.lssolutions.lss-network-tools.local-network-probe"))
        try? await Task.sleep(for: Self.localNetworkProbeDuration)
        browser.cancel()
        log.notice("Local Network probe finished: \(self.localNetworkProbeState ?? "no state", privacy: .public)")
    }

    private nonisolated static func describe(_ state: NWBrowser.State) -> String {
        switch state {
        case .setup: "Starting the Bonjour browse…"
        case .ready: "Browsing — the Local Network prompt appears the first time, otherwise macOS applied your earlier choice"
        case .waiting(let error): "Waiting: \(Self.describe(error))"
        case .failed(let error): "Failed: \(Self.describe(error))"
        case .cancelled: "Request finished"
        @unknown default: "Unknown browser state"
        }
    }

    /// `kDNSServiceErr_PolicyDenied` (-65570) is what a denied Local Network permission
    /// looks like from here.
    private nonisolated static func describe(_ error: NWError) -> String {
        if case .dns(let code) = error, code == -65570 {
            return "Local Network access is denied — allow LSS Network Tools in System Settings → Privacy & Security → Local Network"
        }
        return error.localizedDescription
    }

    static func openLocalNetworkSettings() {
        NSWorkspace.shared.open(localNetworkSettingsURL)
    }

    // MARK: Administrator authentication

    enum AuthenticationOutcome: Equatable {
        case none
        case authenticated(Date)
        case cancelled
        case failed(String)
    }

    private(set) var authenticationOutcome: AuthenticationOutcome = .none

    /// Lock now: drops the credential and the outcome line that described it.
    func lock() {
        model?.authorizationSession.lock()
        authenticationOutcome = .none
    }

    /// Shows the standard administrator-authentication dialog once, at the chosen
    /// cadence, so the user sees what a helper run on a user-owned tool chain asks for.
    /// The external form is discarded: nothing is sent anywhere. Under "Every run" the
    /// credential is dropped straight away, as a run would not reuse it either.
    func authenticateNow() async {
        guard let model else { return }
        do {
            let cadence = model.helperAuthenticationCadence
            _ = try await model.authorizationSession.externalForm(for: cadence)
            authenticationOutcome = .authenticated(model.authorizationSession.authenticatedAt ?? .now)
            if cadence == .everyRun {
                model.authorizationSession.lock()
            }
        } catch let error as AuthorizationSession.AuthorizationError {
            authenticationOutcome = error == .cancelled ? .cancelled : .failed(error.localizedDescription)
        } catch {
            authenticationOutcome = .failed(error.localizedDescription)
        }
    }
}
