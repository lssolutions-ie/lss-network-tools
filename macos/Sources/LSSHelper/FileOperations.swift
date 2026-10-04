import Darwin
import Foundation
import LSSCore

/// A root-only copy of the caller's Wi-Fi scan file.
///
/// The validator checked the file by path, but the caller owns the `scans/` folder and
/// could swap the file for a symlink to a root-only file before the CLI (running as root)
/// reads it. The helper therefore re-opens it with `O_NOFOLLOW`, re-checks the open
/// descriptor (regular file, owned by the caller, < 2 MB), copies the bytes into a fresh
/// `mkdtemp` folder (0700, root) and hands the CLI that copy instead.
struct StagedScanFile: Sendable {
    let directory: String
    let path: String

    func remove() {
        unlink(path)
        rmdir(directory)
    }
}

struct FileOperationError: Error, CustomStringConvertible {
    let description: String
}

enum ScanFileStager {
    static func stage(_ path: String, ownerUID: uid_t) throws -> StagedScanFile {
        let source = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard source >= 0 else { throw FileOperationError(description: "The Wi-Fi scan file cannot be opened (\(String(cString: strerror(errno))))") }
        defer { close(source) }
        var info = stat()
        guard fstat(source, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == ownerUID, info.st_nlink == 1,
              Int64(info.st_size) < RequestValidator.maximumScanFileSize else {
            throw FileOperationError(description: "The Wi-Fi scan file changed after it was validated")
        }
        let limit = Int(RequestValidator.maximumScanFileSize)
        var contents = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(source, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw FileOperationError(description: "The Wi-Fi scan file cannot be read (\(String(cString: strerror(errno))))")
            }
            contents.append(contentsOf: buffer[0..<count])
            guard contents.count < limit else { throw FileOperationError(description: "The Wi-Fi scan file grew past 2 MB") }
        }

        var template = Array((NSTemporaryDirectory() + "lss-helper-scan-XXXXXX").utf8CString)
        let created = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress) }
        guard created != nil else { throw FileOperationError(description: "Cannot create a private folder for the Wi-Fi scan (\(String(cString: strerror(errno))))") }
        let directory = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        let target = directory + "/scan.json"
        let destination = open(target, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard destination >= 0 else {
            rmdir(directory)
            throw FileOperationError(description: "Cannot write the private Wi-Fi scan copy (\(String(cString: strerror(errno))))")
        }
        defer { close(destination) }
        var offset = 0
        while offset < contents.count {
            let written = contents.withUnsafeBytes { bytes in
                Darwin.write(destination, bytes.baseAddress! + offset, contents.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                let reason = String(cString: strerror(errno))
                unlink(target)
                rmdir(directory)
                throw FileOperationError(description: "Cannot write the private Wi-Fi scan copy (\(reason))")
            }
            offset += written
        }
        return StagedScanFile(directory: directory, path: target)
    }
}

/// `repairRunPermissions`: `chmod 0644` on the regular `*.json` files directly inside one
/// validated run directory. Everything goes through descriptors (`openat(O_NOFOLLOW)`,
/// `fstat`, `fchmod`), so a symlink or a swapped entry is never followed.
enum PermissionRepair {
    /// Number of files whose mode changed.
    static func repair(directory: String) throws -> Int32 {
        let directoryDescriptor = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryDescriptor >= 0 else {
            throw FileOperationError(description: "Cannot open \(directory) (\(String(cString: strerror(errno))))")
        }
        defer { close(directoryDescriptor) }

        var names: [String] = []
        let listing = dup(directoryDescriptor)
        guard listing >= 0, let stream = fdopendir(listing) else {
            if listing >= 0 { close(listing) }
            throw FileOperationError(description: "Cannot list \(directory) (\(String(cString: strerror(errno))))")
        }
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            if name.hasSuffix(".json"), !name.hasPrefix(".") { names.append(name) }
        }
        closedir(stream)

        var changed: Int32 = 0
        for name in names {
            let descriptor = openat(directoryDescriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { continue } // a symlink (ELOOP) or an entry that vanished
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { continue }
            if info.st_mode & 0o7777 != 0o644, fchmod(descriptor, 0o644) == 0 {
                changed += 1
            }
        }
        return changed
    }
}
