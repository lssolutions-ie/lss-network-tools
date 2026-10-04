import Foundation

/// Everything the GUI knows about one non-interactive run before it starts.
/// Turned into argv by `ArgumentBuilder` (contract: docs/research/06-m3-execution-contract.md §2).
public struct RunTaskRequest: Sendable, Hashable {
    public enum Selection: Sendable, Hashable {
        /// `--run-task 000` — the core audit (tasks 1–12).
        case fullAudit
        /// `--run-task 1,3,5` — the builder sorts and de-duplicates.
        case tasks([TaskID])

        /// The tasks that will actually run, ascending.
        public var taskIDs: [TaskID] {
            switch self {
            case .fullAudit: TaskID.auditTasks
            case .tasks(let ids): Array(Set(ids)).sorted()
            }
        }
    }

    public enum Context: Sendable, Hashable {
        /// `--client --location [--note]` — a new run directory.
        case newRun(client: String, location: String, note: String)
        /// `--run-dir` — continue an existing run directory.
        case existingRun(directory: URL)
    }

    /// Task 17: one room per invocation (PLAN §7.6).
    public struct WirelessRoom: Sendable, Hashable {
        public var building: String
        public var floor: String
        public var room: String
        public var accessPointPresent: Bool
        public var accessPointLabel: String?
        public var wifiInterface: String?
        /// `--wifi-scan-json` (M4: the app scans with CoreWLAN and hands the JSON over).
        public var scanJSON: URL?

        public init(building: String, floor: String, room: String, accessPointPresent: Bool = false,
                    accessPointLabel: String? = nil, wifiInterface: String? = nil, scanJSON: URL? = nil) {
            self.building = building
            self.floor = floor
            self.room = room
            self.accessPointPresent = accessPointPresent
            self.accessPointLabel = accessPointLabel
            self.wifiInterface = wifiInterface
            self.scanJSON = scanJSON
        }
    }

    /// Task 19. The SSH password never enters the request; it travels in the
    /// child's environment as `LSS_SSH_PASSWORD`.
    public struct UniFiAdoption: Sendable, Hashable {
        public var controllerHost: String?
        public var controllerPort: Int?
        public var https: Bool?
        public var sshUser: String
        public var sshPasswordProvided: Bool

        public init(controllerHost: String? = nil, controllerPort: Int? = nil, https: Bool? = nil,
                    sshUser: String, sshPasswordProvided: Bool) {
            self.controllerHost = controllerHost
            self.controllerPort = controllerPort
            self.https = https
            self.sshUser = sshUser
            self.sshPasswordProvided = sshPasswordProvided
        }
    }

    public var selection: Selection
    public var context: Context
    public var interface: String?
    public var preparedBy: String?
    public var skipPDF: Bool
    /// `--yes`: explicit consent for stress tests (10, 14, full audit).
    public var stressConsent: Bool
    /// Tasks 13–16.
    public var targetIP: String?
    /// Task 20.
    public var macAddress: String?
    /// Task 17.
    public var wireless: WirelessRoom?
    /// Task 19.
    public var unifi: UniFiAdoption?
    public var debug: Bool

    public init(selection: Selection, context: Context, interface: String? = nil, preparedBy: String? = nil,
                skipPDF: Bool = false, stressConsent: Bool = false, targetIP: String? = nil, macAddress: String? = nil,
                wireless: WirelessRoom? = nil, unifi: UniFiAdoption? = nil, debug: Bool = false) {
        self.selection = selection
        self.context = context
        self.interface = interface
        self.preparedBy = preparedBy
        self.skipPDF = skipPDF
        self.stressConsent = stressConsent
        self.targetIP = targetIP
        self.macAddress = macAddress
        self.wireless = wireless
        self.unifi = unifi
        self.debug = debug
    }

    /// Full audit, or a selection containing a stress test (10 or 14).
    public var requiresConsent: Bool {
        if case .fullAudit = selection { return true }
        return selection.taskIDs.contains { $0.isStressTest }
    }

    /// Any of tasks 13–16.
    public var requiresTarget: Bool { selection.taskIDs.contains { $0.needsTargetIP } }
    /// Task 20.
    public var requiresMAC: Bool { selection.taskIDs.contains(.findByMAC) }
    /// Task 17.
    public var requiresWireless: Bool { selection.taskIDs.contains(.wirelessSurvey) }
    /// Task 19.
    public var requiresUniFi: Bool { selection.taskIDs.contains(.unifiAdoption) }
}

/// `--build-report <run-dir>`.
public struct BuildReportRequest: Sendable, Hashable {
    public var runDirectory: URL
    public var preparedBy: String?
    public var skipPDF: Bool
    /// `--output DIR` (default: inside the run directory).
    public var outputDirectory: URL?

    public init(runDirectory: URL, preparedBy: String? = nil, skipPDF: Bool = false, outputDirectory: URL? = nil) {
        self.runDirectory = runDirectory
        self.preparedBy = preparedBy
        self.skipPDF = skipPDF
        self.outputDirectory = outputDirectory
    }
}
