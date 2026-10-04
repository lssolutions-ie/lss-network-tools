import Foundation
import Testing
@testable import LSSCore

/// The `group` strings of contract §1.3.
private let groupNames: [TaskGroup: String] = [.coreAudit: "core", .customTarget: "custom", .specialist: "specialist"]

/// Builds the `--run-task list` JSON from the app's own catalog, then lets a
/// test mutate the entries before serialising.
private func listingData(version: String? = "v1.2.249", mutate: (inout [[String: Any]]) -> Void = { _ in }) throws -> Data {
    var tasks: [[String: Any]] = TaskID.allCases.map { task in
        ["id": task.rawValue, "title": task.title, "file": task.outputFile, "multi": task.isMultiEntry, "group": groupNames[task.group]!]
    }
    mutate(&tasks)
    var root: [String: Any] = ["tasks": tasks]
    if let version { root["version"] = version }
    return try JSONSerialization.data(withJSONObject: root)
}

@Suite("CLITaskListing")
struct CLITaskListingTests {
    @Test("the contract sample built from the catalog parses and shows no drift")
    func noDrift() throws {
        let listing = try CLITaskListing.parse(listingData())
        #expect(listing.version == "v1.2.249")
        #expect(listing.tasks.count == TaskID.allCases.count)
        #expect(listing.tasks.first == CLITaskListing.Entry(id: 1, title: "Interface Network Info", file: "interface-network-info.json", multi: false, group: "core"))
        #expect(listing.tasks.map(\.id) == Array(1...20))
        #expect(listing.tasks.filter(\.multi).map(\.id) == [10, 13, 14, 15, 16])
        #expect(listing.tasks.filter { $0.group == "custom" }.map(\.id) == Array(13...16))
        #expect(listing.tasks.filter { $0.group == "specialist" }.map(\.id) == Array(17...20))
        #expect(listing.drift(against: TaskID.allCases).isEmpty)
    }

    @Test("the literal contract §1.3 line parses")
    func contractLine() throws {
        let data = Data(#"{"version":"v1.2.249","tasks":[{"id":1,"title":"Interface Network Info","file":"interface-network-info.json","multi":false,"group":"core"}]}"#.utf8)
        let listing = try CLITaskListing.parse(data)
        #expect(listing.tasks.count == 1)
        let drift = listing.drift(against: TaskID.allCases)
        #expect(drift.count == 19, "every other catalog task is missing from the listing")
        #expect(drift.allSatisfy { $0.hasPrefix("The CLI does not list task ") })
    }

    @Test("a changed title is reported for that task only")
    func titleDrift() throws {
        let listing = try CLITaskListing.parse(listingData { $0[0]["title"] = "Interface Info" })
        let drift = listing.drift(against: TaskID.allCases)
        #expect(drift.count == 1)
        #expect(drift[0].contains("Task 1"))
        #expect(drift[0].contains("Interface Info"))
        #expect(drift[0].contains("Interface Network Info"))
    }

    @Test("a changed output file is reported")
    func fileDrift() throws {
        let listing = try CLITaskListing.parse(listingData { $0[3]["file"] = "dhcp.json" })
        let drift = listing.drift(against: TaskID.allCases)
        #expect(drift.count == 1)
        #expect(drift[0].contains("Task 4"))
        #expect(drift[0].contains("dhcp.json"))
        #expect(drift[0].contains("dhcp-scan.json"))
    }

    @Test("a flipped multi flag is reported")
    func multiDrift() throws {
        let listing = try CLITaskListing.parse(listingData { $0[9]["multi"] = false })
        let drift = listing.drift(against: TaskID.allCases)
        #expect(drift.count == 1)
        #expect(drift[0].contains("Task 10"))
        #expect(drift[0].contains("multi"))
    }

    @Test("a changed group is reported")
    func groupDrift() throws {
        let listing = try CLITaskListing.parse(listingData { $0[16]["group"] = "core" })
        let drift = listing.drift(against: TaskID.allCases)
        #expect(drift.count == 1)
        #expect(drift[0].contains("Task 17"))
        #expect(drift[0].contains("specialist"))
    }

    @Test("missing, extra and duplicated ids are reported")
    func idDrift() throws {
        let listing = try CLITaskListing.parse(listingData { tasks in
            tasks.removeLast() // drop 20
            tasks.append(["id": 21, "title": "Coffee Break", "file": "coffee.json", "multi": false, "group": "specialist"])
            tasks.append(tasks[0]) // duplicate 1
        })
        let drift = listing.drift(against: TaskID.allCases)
        #expect(drift.count == 3)
        #expect(drift.contains { $0.contains("task 1 more than once") })
        #expect(drift.contains { $0.contains("task 21") && $0.contains("Coffee Break") })
        #expect(drift.contains { $0.contains("does not list task 20") && $0.contains("Find Device by MAC") })
    }

    @Test("version is optional; invalid JSON throws")
    func parsing() throws {
        let listing = try CLITaskListing.parse(listingData(version: nil))
        #expect(listing.version == nil)
        #expect(throws: (any Error).self) { try CLITaskListing.parse(Data("not json".utf8)) }
        #expect(throws: (any Error).self) { try CLITaskListing.parse(Data(#"{"tasks":[{"id":"one"}]}"#.utf8)) }
    }
}
