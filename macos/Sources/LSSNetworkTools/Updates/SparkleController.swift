import Foundation
import Observation
import Sparkle

/// In-app updates from the committed appcast (PLAN §9, contract 07 §7).
///
/// Sparkle runs only when the build carries `SUPublicEDKey` (injected by
/// `scripts/build-app.sh` from `SPARKLE_PUBLIC_ED_KEY`): an unkeyed build
/// creates the updater controller but never starts it, so no feed is fetched,
/// nothing is scheduled and "Check for Updates…" stays disabled.
///
/// One instance per process, as `static let shared`: Sparkle allows a single
/// updater per host bundle (a second one would share its user defaults and
/// schedule a competing update cycle), and it is needed by two scenes that
/// have no common owner except the `App` struct — the app menu's command and
/// the Settings window. `LSSNetworkToolsApp` touches `shared` when it is
/// created, so a configured build starts Sparkle at launch.
@MainActor
@Observable
final class SparkleController {
    static let shared = SparkleController()

    /// Shown in Settings and as the disabled menu item's help text.
    static let notConfiguredExplanation =
        "Updates are not configured in this build — the app was built without SPARKLE_PUBLIC_ED_KEY."

    /// `SUPublicEDKey` is present and non-empty, so Sparkle was started.
    let isEnabled: Bool
    /// `SUFeedURL` from Info.plist.
    let feedURL: URL?
    /// Mirrors `SPUUpdater.canCheckForUpdates` (false while a check runs, and always false when disabled).
    private(set) var canCheckForUpdates = false
    /// Mirrors `SPUUpdater.lastUpdateCheckDate`.
    private(set) var lastUpdateCheckDate: Date?
    private var automaticChecks: Bool

    private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// Sparkle's own setting (`SUEnableAutomaticChecks` in Info.plist, then
    /// the user's choice in Sparkle's defaults). Read-only while disabled.
    var automaticChecksEnabled: Bool {
        get { automaticChecks }
        set {
            guard isEnabled else { return }
            controller.updater.automaticallyChecksForUpdates = newValue
            automaticChecks = controller.updater.automaticallyChecksForUpdates
        }
    }

    private init() {
        let info = Bundle.main
        let key = (info.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let enabled = !key.isEmpty
        isEnabled = enabled
        feedURL = (info.object(forInfoDictionaryKey: "SUFeedURL") as? String).flatMap { URL(string: $0) }

        controller = SPUStandardUpdaterController(startingUpdater: enabled, updaterDelegate: nil, userDriverDelegate: nil)
        let updater = controller.updater
        automaticChecks = updater.automaticallyChecksForUpdates
        lastUpdateCheckDate = updater.lastUpdateCheckDate
        canCheckForUpdates = enabled && updater.canCheckForUpdates
        guard enabled else { return }

        // Sparkle changes these on the main thread; the KVO callbacks arrive there.
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
                guard let value = change.newValue else { return }
                MainActor.assumeIsolated { self?.canCheckForUpdates = value }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? nil
                MainActor.assumeIsolated { self?.lastUpdateCheckDate = value }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, change in
                guard let value = change.newValue else { return }
                MainActor.assumeIsolated { self?.automaticChecks = value }
            },
        ]
    }

    /// Sparkle's standard "Check for Updates" flow (progress and result windows).
    func checkForUpdates() {
        guard isEnabled, canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }
}
