import Foundation
import Testing
@testable import LSSCore

/// Path of `lss-network-tools.sh` relative to this test file (macos/Tests/LSSCoreTests/).
private var scriptURL: URL {
    URL(filePath: #filePath)
        .deletingLastPathComponent() // LSSCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // macos
        .deletingLastPathComponent() // repo root
        .appending(path: "lss-network-tools.sh")
}

@Suite("TaskID mirrors TASKS_DATA")
struct TaskIDTests {
    @Test("Every TaskID matches the script's TASKS_DATA line")
    func tableMatchesScript() throws {
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let tasksData = try #require(TaskCatalog.extractTasksData(fromScript: script))
        let entries = TaskCatalog.parse(tasksData: tasksData)

        #expect(entries.count == TaskID.allCases.count)
        for entry in entries {
            let task = try #require(TaskID(rawValue: entry.id), "script lists task \(entry.id) but TaskID has no case")
            #expect(task.title == entry.title, "title drift for task \(entry.id)")
            #expect(task.outputFile == entry.outputFile, "output file drift for task \(entry.id)")
        }
    }

    @Test("Groups partition the tasks 1–12 / 13–16 / 17–20")
    func groups() {
        #expect(TaskGroup.coreAudit.tasks.map(\.rawValue) == Array(1...12))
        #expect(TaskGroup.customTarget.tasks.map(\.rawValue) == Array(13...16))
        #expect(TaskGroup.specialist.tasks.map(\.rawValue) == Array(17...20))
        #expect(TaskID.auditTasks.count == 12)
    }

    @Test("Multi-entry and stress flags")
    func flags() {
        #expect(TaskID.allCases.filter(\.isMultiEntry).map(\.rawValue) == [10, 13, 14, 15, 16])
        #expect(TaskID.allCases.filter(\.isStressTest).map(\.rawValue) == [10, 14])
        #expect(TaskID.gatewayStress.outputStem == "gateway-stress-test")
    }

    @Test("TASKS_DATA parser ignores malformed lines")
    func parserIgnoresJunk() {
        let parsed = TaskCatalog.parse(tasksData: "1|A|a.json\n\nnot a line\n2|B|b.json|extra\n3|C|c.json\n")
        #expect(parsed == [
            TaskCatalogEntry(id: 1, title: "A", outputFile: "a.json"),
            TaskCatalogEntry(id: 3, title: "C", outputFile: "c.json"),
        ])
    }
}

@Suite("CLI install discovery")
struct CLIInstallTests {
    @Test("install.env parsing")
    func installEnv() {
        let text = """
        # written by install.sh
        APP_ROOT="/usr/local/share/lss-network-tools"
        DATA_ROOT='/usr/local/share/lss-network-tools'
        INSTALL_WRAPPER_PATH=/usr/local/bin/lss-network-tools
        lower=ignored
        """
        let values = CLIInstall.parseInstallEnv(text)
        #expect(values["APP_ROOT"] == "/usr/local/share/lss-network-tools")
        #expect(values["DATA_ROOT"] == "/usr/local/share/lss-network-tools")
        #expect(values["INSTALL_WRAPPER_PATH"] == "/usr/local/bin/lss-network-tools")
        #expect(values["lower"] == nil)
    }

    @Test("wrapper parsing")
    func wrapper() {
        let text = """
        #!/usr/bin/env bash
        set -euo pipefail
        export PATH="/opt/homebrew/bin:${PATH:-}"
        exec "/usr/local/share/lss-network-tools/lss-network-tools.sh" "$@"
        """
        #expect(CLIInstall.parseWrapper(text) == "/usr/local/share/lss-network-tools/lss-network-tools.sh")
        #expect(CLIInstall.parseWrapper("echo nothing") == nil)
    }

    @Test("version comparison")
    func versions() {
        #expect(CLIVersionProbe.compare("v1.2.9", "v1.2.10") == .orderedAscending)
        #expect(CLIVersionProbe.compare("v1.2.248", "v1.2.248") == .orderedSame)
        #expect(CLIVersionProbe.compare("v2.0.0", "v1.9.9") == .orderedDescending)
    }

    @Test("detect falls back to the override when nothing is installed")
    func detectOverride() throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: "lss-cli-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try "#!/bin/bash\n".write(to: temp.appending(path: CLIInstall.scriptName), atomically: true, encoding: .utf8)

        let missing = temp.appending(path: "missing-install.env")
        let found = CLIInstall.detect(installEnv: missing, wrapper: missing, overrideAppRoot: temp.path(percentEncoded: false))
        #expect(found?.source == .override)
        #expect(found?.outputDirectory.lastPathComponent == "output")
        #expect(CLIInstall.detect(installEnv: missing, wrapper: missing, overrideAppRoot: nil) == nil)
    }
}

@Suite("Network interface parsing")
struct NetworkInterfacesTests {
    @Test("networksetup blocks")
    func hardwarePorts() {
        let text = """

        Hardware Port: Ethernet Adapter (en3)
        Device: en3
        Ethernet Address: c6:71:4f:cd:01:ab

        Hardware Port: Wi-Fi
        Device: en0
        Ethernet Address: fc:b2:14:9a:0b:d2

        Hardware Port: Thunderbolt Bridge
        Device: bridge0
        Ethernet Address: N/A
        """
        let parsed = NetworkInterfaces.parseHardwarePorts(text)
        #expect(parsed.map(\.device) == ["en3", "en0", "bridge0"])
        #expect(parsed[1].hardwarePort == "Wi-Fi")
        #expect(parsed[1].macAddress == "fc:b2:14:9a:0b:d2")
        #expect(parsed[2].macAddress == nil)
    }

    @Test("virtual interfaces are excluded from the audit list")
    func virtualFilter() {
        #expect(NetworkInterfaces.isVirtualOrTunnel("lo0"))
        #expect(NetworkInterfaces.isVirtualOrTunnel("utun3"))
        #expect(NetworkInterfaces.isVirtualOrTunnel("bridge0"))
        #expect(!NetworkInterfaces.isVirtualOrTunnel("en0"))
    }
}
