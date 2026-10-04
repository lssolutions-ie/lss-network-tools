import Darwin
import Foundation

/// Scan files handed to the engine with `--wifi-scan-json`:
/// `~/Library/Application Support/ie.lssolutions.lss-network-tools/scans/<uuid>.json`,
/// directory 0700, file 0600. The privileged helper (M4) only accepts a scan
/// file that resolves inside exactly this directory of the calling user, so
/// the path is fixed — it does not follow the bundle identifier.
enum WiFiScanStore {
    static let applicationFolder = "ie.lssolutions.lss-network-tools"
    /// Older scans are deleted when a new one is written. A scan is consumed
    /// when Task 17 runs (the networks are copied into wireless-survey.json),
    /// so a week leaves ample margin for a long queue.
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    static var directory: URL {
        URL.applicationSupportDirectory
            .appending(path: applicationFolder, directoryHint: .isDirectory)
            .appending(path: "scans", directoryHint: .isDirectory)
    }

    /// Writes `networks` as a JSON array (UTF-8, pretty-printed, sorted keys)
    /// to a new file and returns its URL.
    static func write(_ networks: [WiFiNetworkRecord]) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(networks)
        } catch {
            throw WiFiScanError.storeFailed(reason: error.localizedDescription)
        }

        let directory = try prepareDirectory()
        let url = directory.appending(path: UUID().uuidString + ".json", directoryHint: .notDirectory)
        let path = url.path(percentEncoded: false)
        // O_EXCL | O_NOFOLLOW: always a new regular file, created 0600 (never
        // briefly readable by others, unlike write-then-chmod).
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw WiFiScanError.storeFailed(reason: "\(path): \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw WiFiScanError.storeFailed(reason: error.localizedDescription)
        }
        pruneOldScans(keeping: url)
        return url
    }

    /// Deletes a scan file this app wrote (anything outside the scans
    /// directory is left alone).
    static func remove(_ url: URL) {
        let file = url.standardizedFileURL
        guard file.isFileURL, file.pathExtension == "json",
              normalizedPath(file.deletingLastPathComponent()) == normalizedPath(directory) else { return }
        try? FileManager.default.removeItem(at: file)
    }

    /// Standardised path without a trailing slash, for comparing directories.
    private static func normalizedPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Creates the directory (0700) or tightens an existing one to 0700.
    private static func prepareDirectory() throws -> URL {
        let directory = directory
        let fileManager = FileManager.default
        do {
            let values = try? directory.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                throw WiFiScanError.storeFailed(reason: "\(directory.path(percentEncoded: false)) is a symbolic link")
            }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path(percentEncoded: false))
        } catch let error as WiFiScanError {
            throw error
        } catch {
            throw WiFiScanError.storeFailed(reason: error.localizedDescription)
        }
        return directory
    }

    private static func pruneOldScans(keeping current: URL) {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
        let cutoff = Date.now.addingTimeInterval(-retention)
        for file in files where file.pathExtension == "json" && file.lastPathComponent != current.lastPathComponent {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified < cutoff else { continue }
            try? fileManager.removeItem(at: file)
        }
    }
}
