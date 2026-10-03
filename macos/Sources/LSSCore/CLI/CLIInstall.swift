import Foundation

/// Where the installed command-line tool lives. Resolved from `install.env`
/// (written by install.sh), falling back to the wrapper script, then to a
/// developer override. The GUI never bundles its own copy of the engine.
public struct CLIInstall: Sendable, Hashable {
    public enum Source: String, Sendable {
        case installEnv = "install.env"
        case wrapper = "wrapper"
        case override = "override"
    }

    public let appRoot: URL
    public let dataRoot: URL
    public let scriptPath: URL
    /// `/usr/local/bin/lss-network-tools` when present and executable. Preferred
    /// launcher because it exports the Homebrew-first PATH.
    public let wrapperPath: URL?
    public let source: Source

    public static let scriptName = "lss-network-tools.sh"
    public static let defaultAppRoot = URL(filePath: "/usr/local/share/lss-network-tools", directoryHint: .isDirectory)
    public static let defaultInstallEnv = defaultAppRoot.appending(path: "install.env")
    public static let defaultWrapper = URL(filePath: "/usr/local/bin/lss-network-tools")

    public init(appRoot: URL, dataRoot: URL, scriptPath: URL, wrapperPath: URL?, source: Source) {
        self.appRoot = appRoot
        self.dataRoot = dataRoot
        self.scriptPath = scriptPath
        self.wrapperPath = wrapperPath
        self.source = source
    }

    /// `$DATA_ROOT/output` — one sub-directory per run.
    public var outputDirectory: URL { dataRoot.appending(path: "output", directoryHint: .isDirectory) }
    public var programDefaultsFile: URL { dataRoot.appending(path: "program-defaults.json") }
    public var pdfGenerator: URL { appRoot.appending(path: "generate_pdf_report.py") }

    /// Executable and leading arguments that launch the CLI. The wrapper is
    /// preferred (PATH); otherwise the script is run through /bin/bash.
    public var launchCommand: (executable: String, arguments: [String]) {
        if let wrapperPath { return (wrapperPath.path(percentEncoded: false), []) }
        return ("/bin/bash", [scriptPath.path(percentEncoded: false)])
    }

    // MARK: Detection

    public static func detect(
        installEnv: URL = defaultInstallEnv,
        wrapper: URL = defaultWrapper,
        overrideAppRoot: String? = nil,
        fileManager fm: FileManager = .default
    ) -> CLIInstall? {
        // 1. install.env — the authoritative record written by install.sh.
        if let text = try? String(contentsOf: installEnv, encoding: .utf8) {
            let values = parseInstallEnv(text)
            if let app = values["APP_ROOT"], !app.isEmpty {
                let appURL = URL(filePath: app, directoryHint: .isDirectory)
                let script = appURL.appending(path: scriptName)
                if fm.isReadableFile(atPath: script.path(percentEncoded: false)) {
                    let data = values["DATA_ROOT"].flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) } ?? appURL
                    let wrap = values["INSTALL_WRAPPER_PATH"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) } ?? wrapper
                    let usableWrapper = fm.isExecutableFile(atPath: wrap.path(percentEncoded: false)) ? wrap : nil
                    return CLIInstall(appRoot: appURL, dataRoot: data, scriptPath: script, wrapperPath: usableWrapper, source: .installEnv)
                }
            }
        }
        // 2. The wrapper's `exec "<script>"` line.
        if let text = try? String(contentsOf: wrapper, encoding: .utf8), let scriptString = parseWrapper(text) {
            let script = URL(filePath: scriptString)
            let app = script.deletingLastPathComponent()
            if fm.isReadableFile(atPath: script.path(percentEncoded: false)) {
                return CLIInstall(appRoot: app, dataRoot: app, scriptPath: script, wrapperPath: wrapper, source: .wrapper)
            }
        }
        // 3. Developer override (portable checkout).
        if let overrideAppRoot, !overrideAppRoot.isEmpty {
            let app = URL(filePath: overrideAppRoot, directoryHint: .isDirectory)
            let script = app.appending(path: scriptName)
            if fm.isReadableFile(atPath: script.path(percentEncoded: false)) {
                return CLIInstall(appRoot: app, dataRoot: app, scriptPath: script, wrapperPath: nil, source: .override)
            }
        }
        return nil
    }

    /// Parses `NAME="value"` lines (quotes optional, `#` comments ignored).
    public static func parseInstallEnv(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard key.range(of: "^[A-Z_][A-Z0-9_]*$", options: .regularExpression) != nil else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        return values
    }

    /// Finds the quoted path in the wrapper's `exec "<path>" "$@"` line.
    public static func parseWrapper(_ text: String) -> String? {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("exec ") else { continue }
            if let range = line.range(of: "\"[^\"]+\"", options: .regularExpression) {
                return String(line[range]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }
}

/// Reads the installed CLI version by running `--version` (no root needed; the
/// script exits before touching any file).
public enum CLIVersionProbe {
    public static func version(of install: CLIInstall) async -> String? {
        let command = install.launchCommand
        guard let result = try? await ProcessRunner.run(command.executable, command.arguments + ["--version"]) else {
            return nil
        }
        // Output is exactly `lss-network-tools vX.Y.Z`.
        let line = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = line.range(of: "v[0-9]+\\.[0-9]+\\.[0-9]+", options: .regularExpression) else { return nil }
        return String(line[range])
    }

    /// Compares two `vX.Y.Z` strings numerically.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".").map { Int($0) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
