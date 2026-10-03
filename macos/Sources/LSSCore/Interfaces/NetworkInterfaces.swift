import Foundation
import Darwin

/// A network interface as the GUI presents it: BSD device name plus the
/// `networksetup` hardware-port name and the first IPv4 address, if any.
public struct NetworkInterface: Sendable, Hashable, Identifiable {
    public let device: String
    public let hardwarePort: String?
    public let macAddress: String?
    public var ipv4: String?

    public var id: String { device }

    public init(device: String, hardwarePort: String?, macAddress: String?, ipv4: String?) {
        self.device = device
        self.hardwarePort = hardwarePort
        self.macAddress = macAddress
        self.ipv4 = ipv4
    }

    /// e.g. `en0 · 192.168.1.20 (Wi-Fi)`
    public var displayName: String {
        var parts = [device]
        if let ipv4 { parts.append("· \(ipv4)") }
        if let hardwarePort { parts.append("(\(hardwarePort))") }
        return parts.joined(separator: " ")
    }
}

public enum NetworkInterfaces {
    /// Parses `networksetup -listallhardwareports` output:
    /// ```
    /// Hardware Port: Wi-Fi
    /// Device: en0
    /// Ethernet Address: fc:b2:14:9a:0b:d2
    /// ```
    public static func parseHardwarePorts(_ text: String) -> [NetworkInterface] {
        var result: [NetworkInterface] = []
        var port: String?
        var device: String?
        var mac: String?

        func flush() {
            if let device {
                result.append(NetworkInterface(device: device, hardwarePort: port, macAddress: mac, ipv4: nil))
            }
            port = nil
            device = nil
            mac = nil
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if let value = value(after: "Hardware Port:", in: line) {
                if device != nil { flush() }
                port = value
            } else if let value = value(after: "Device:", in: line) {
                device = value
            } else if let value = value(after: "Ethernet Address:", in: line) {
                mac = value == "N/A" ? nil : value
            }
        }
        flush()
        return result
    }

    private static func value(after prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    /// First IPv4 address per interface, via `getifaddrs`.
    public static func ipv4Addresses() -> [String: String] {
        var map: [String: String] = [:]
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let head = first else { return map }
        defer { freeifaddrs(first) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let entry = cursor {
            let ifa = entry.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: ifa.ifa_name)
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let rc = getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                if rc == 0, map[name] == nil {
                    let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                    map[name] = String(decoding: bytes, as: UTF8.self)
                }
            }
            cursor = ifa.ifa_next
        }
        return map
    }

    /// Interfaces the bash tool would never audit (mirrors `is_virtual_or_tunnel_interface`).
    public static func isVirtualOrTunnel(_ device: String) -> Bool {
        let prefixes = ["lo", "utun", "gif", "stf", "awdl", "llw", "anpi", "ap", "vmenet", "bridge", "tun", "tap"]
        return prefixes.contains { device.hasPrefix($0) }
    }

    /// Hardware ports from `networksetup` merged with live IPv4 addresses, plus
    /// any other interface that currently has an IPv4 address. Interfaces with
    /// an address sort first.
    public static func list() async -> [NetworkInterface] {
        let text = (try? await ProcessRunner.run("/usr/sbin/networksetup", ["-listallhardwareports"]).stdout) ?? ""
        var interfaces = parseHardwarePorts(text).filter { !isVirtualOrTunnel($0.device) }
        let addresses = ipv4Addresses()
        for index in interfaces.indices {
            interfaces[index].ipv4 = addresses[interfaces[index].device]
        }
        let known = Set(interfaces.map(\.device))
        for (device, ip) in addresses where !known.contains(device) && !isVirtualOrTunnel(device) {
            interfaces.append(NetworkInterface(device: device, hardwarePort: nil, macAddress: nil, ipv4: ip))
        }
        interfaces.sort { lhs, rhs in
            let l = (lhs.ipv4 == nil ? 1 : 0, lhs.device)
            let r = (rhs.ipv4 == nil ? 1 : 0, rhs.device)
            return l < r
        }
        return interfaces
    }

    /// Interface carrying the default route (`route -n get default`).
    public static func defaultRouteInterface() async -> String? {
        guard let output = try? await ProcessRunner.run("/sbin/route", ["-n", "get", "default"]).stdout else { return nil }
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("interface:") {
                return String(line.dropFirst("interface:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
