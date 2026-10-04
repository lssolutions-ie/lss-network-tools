import AppKit
import CoreLocation
import Foundation
import Observation
import OSLog
import LSSCore

/// What the Task 17 panel shows after a scan.
struct WiFiScanSummary: Equatable, Sendable {
    var networkCount: Int
    /// Distinct network names, `"(hidden)"` not counted.
    var distinctSSIDCount: Int
    var hiddenCount: Int
    var strongestRSSI: Int?
    var strongestSSID: String?
    var interfaceName: String
    var scannedAt: Date
    var usedCachedResults: Bool

    init(_ outcome: WiFiScanOutcome, scannedAt: Date = .now) {
        let networks = outcome.networks
        networkCount = networks.count
        let names = Set(networks.map(\.ssid))
        distinctSSIDCount = names.subtracting([WiFiNetworkRecord.hiddenSSID]).count
        hiddenCount = networks.filter { $0.ssid == WiFiNetworkRecord.hiddenSSID }.count
        let strongest = networks.filter { $0.rssiDBM != nil }.max { ($0.rssiDBM ?? .min) < ($1.rssiDBM ?? .min) }
        strongestRSSI = strongest?.rssiDBM
        strongestSSID = strongest?.ssid
        interfaceName = outcome.interfaceName
        self.scannedAt = scannedAt
        usedCachedResults = outcome.usedCachedResults
    }

    /// Every network came back without a name: CoreWLAN redacts SSIDs for
    /// apps without effective Location authorisation.
    var allNamesHidden: Bool { networkCount > 0 && hiddenCount == networkCount }
}

/// A finished scan: the file for `--wifi-scan-json` and its summary.
struct WiFiScanResult: Equatable, Sendable {
    var url: URL
    var summary: WiFiScanSummary
}

/// Wireless site survey (Task 17) scanning from the GUI (PLAN §8.3, contract
/// 07 §6): asks for Location authorisation (CoreWLAN only reveals SSIDs and
/// BSSIDs to location-authorised apps), scans with CoreWLAN and writes the
/// helper-shaped JSON array the engine reads with `--wifi-scan-json`.
@MainActor
@Observable
final class WiFiScanner {
    enum State: Equatable {
        case idle
        case requestingAuthorization
        case scanning
        case scanned(WiFiScanSummary)
        case denied
        case failed(String)
    }

    private(set) var state: State = .idle
    /// The file written by the last successful scan.
    private(set) var lastResultURL: URL?
    /// The interface asked for by the scan in progress (nil = CoreWLAN's default).
    private(set) var requestedInterface: String?

    /// How long the Location prompt may stay unanswered.
    static let authorizationTimeout: Duration = .seconds(60)
    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!

    private let authorizer = LocationAuthorizer()
    private let log = Logger(subsystem: "ie.lssolutions.lss-network-tools", category: "wifi")

    var isBusy: Bool {
        switch state {
        case .requestingAuthorization, .scanning: true
        default: false
        }
    }

    /// Authorises, scans and writes the scan file. Returns nil (with `state`
    /// explaining why) when authorisation is denied or times out, or the scan
    /// or the write fails. `interface` nil → CoreWLAN's default interface.
    @discardableResult
    func scan(interface: String?) async -> WiFiScanResult? {
        guard !isBusy else { return nil }
        requestedInterface = interface
        state = .requestingAuthorization
        log.notice("Wi-Fi scan requested (interface: \(interface ?? "default", privacy: .public))")

        let status = await authorizer.authorize(timeout: Self.authorizationTimeout)
        switch status {
        case .authorizedAlways:
            break
        case .denied, .restricted:
            log.notice("Location authorisation denied or restricted (status \(status.rawValue, privacy: .public))")
            state = .denied
            return nil
        case .notDetermined:
            log.notice("Location prompt not answered within 60 s")
            state = .failed("The Location prompt was not answered within 60 seconds. Allow LSS Network Tools in System Settings › Privacy & Security › Location Services, then scan again.")
            return nil
        @unknown default:
            // 4 = .authorizedWhenInUse, which macOS does not use; treat it as
            // granted should it ever be reported.
            guard status.rawValue == 4 else {
                log.error("Unknown Location authorisation status \(status.rawValue, privacy: .public)")
                state = .failed("macOS reported an unknown Location authorisation state (\(status.rawValue)).")
                return nil
            }
        }

        state = .scanning
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let outcome = try WiFiScanEngine.scan(interfaceName: interface)
                let url = try WiFiScanStore.write(outcome.networks)
                return WiFiScanResult(url: url, summary: WiFiScanSummary(outcome))
            }.value
            let summary = result.summary
            log.notice("Wi-Fi scan on \(summary.interfaceName, privacy: .public): \(summary.networkCount, privacy: .public) networks, \(summary.distinctSSIDCount, privacy: .public) SSIDs, \(summary.hiddenCount, privacy: .public) hidden, cache \(summary.usedCachedResults, privacy: .public)")
            lastResultURL = result.url
            state = .scanned(summary)
            return result
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log.error("Wi-Fi scan failed: \(message, privacy: .public)")
            state = .failed(message)
            return nil
        }
    }

    /// Forgets the outcome of the last attempt (the panel shows its idle text).
    func reset() {
        guard !isBusy else { return }
        state = .idle
    }

    /// System Settings › Privacy & Security › Location Services.
    static func openLocationPrivacySettings() {
        NSWorkspace.shared.open(privacySettingsURL)
    }

    /// The app's Location authorisation as macOS reports it now, without prompting.
    static func locationAuthorizationStatus() -> CLAuthorizationStatus {
        CLLocationManager().authorizationStatus
    }

    /// Shows the Location prompt when the user has not decided yet and returns the
    /// resulting status (`.notDetermined` when the prompt is not answered within
    /// `timeout`). Used by the Setup sheet; the scanner itself goes through the same
    /// `LocationAuthorizer`.
    static func requestLocationAuthorization(timeout: Duration = WiFiScanner.authorizationTimeout) async -> CLAuthorizationStatus {
        let authorizer = LocationAuthorizer()
        return await authorizer.authorize(timeout: timeout)
    }

    /// The device to scan for a run on `device`: the device itself when its
    /// hardware port is Wi-Fi (or AirPort on older systems), otherwise nil so
    /// CoreWLAN picks its default Wi-Fi interface.
    static func wifiInterface(for device: String, in interfaces: [NetworkInterface]) -> String? {
        guard let port = interfaces.first(where: { $0.device == device })?.hardwarePort else { return nil }
        let isWireless = port.localizedCaseInsensitiveContains("Wi-Fi") || port.localizedCaseInsensitiveContains("AirPort")
        return isWireless ? device : nil
    }

    // MARK: Automation

    /// `--wifi-autoscan` (with `--view new-run --task 17`): the Task 17 panel
    /// starts one scan as soon as it appears, so the flow — including the
    /// Location prompt — can be exercised and captured without clicking.
    static func consumeAutomationAutoScan() -> Bool {
        guard !automationAutoScanConsumed, CommandLine.arguments.contains("--wifi-autoscan") else { return false }
        automationAutoScanConsumed = true
        return true
    }

    private static var automationAutoScanConsumed = false
}

/// `CLLocationManager` authorisation as one async call. The manager is created
/// on the main thread, so CoreLocation delivers the delegate callbacks there.
@MainActor
final class LocationAuthorizer: NSObject, CLLocationManagerDelegate {
    private var manager: CLLocationManager?
    private var continuation: CheckedContinuation<CLAuthorizationStatus, Never>?
    private var timeoutTask: Task<Void, Never>?

    /// The current status, prompting first when the user has not decided yet.
    /// Returns `.notDetermined` when the prompt is not answered within `timeout`.
    func authorize(timeout: Duration) async -> CLAuthorizationStatus {
        let manager = manager ?? CLLocationManager()
        self.manager = manager
        manager.delegate = self
        let status = manager.authorizationStatus
        guard status == .notDetermined else { return status }
        return await withCheckedContinuation { continuation in
            // Never orphan an earlier waiter (WiFiScanner does not overlap calls).
            finish(.notDetermined)
            self.continuation = continuation
            manager.requestWhenInUseAuthorization()
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.finish(.notDetermined)
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            // CoreLocation reports the current state (.notDetermined) as soon as
            // the delegate is set, while the prompt is still on screen: ignore
            // it and keep waiting for the user's answer.
            guard status != .notDetermined else { return }
            finish(status)
        }
    }

    private func finish(_ status: CLAuthorizationStatus) {
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation?.resume(returning: status)
        continuation = nil
    }
}
