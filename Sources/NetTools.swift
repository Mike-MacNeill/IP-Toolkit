import Foundation

enum NetTool: String, CaseIterable, Identifiable {
    case ping, traceroute, portScan
    var id: Self { self }
    var title: String {
        switch self {
        case .ping: return "Ping"
        case .traceroute: return "Traceroute"
        case .portScan: return "Port Scan"
        }
    }
}

enum NetToolError: Error, LocalizedError, Equatable {
    case invalidTarget(String)
    case launchFailed(String)
    case nmapNotFound
    case rangeTooLarge(String, Int)
    case invalidPorts(String)

    var errorDescription: String? {
        switch self {
        case .invalidTarget(let s): return "“\(s)” is not a valid IP address or hostname."
        case .launchFailed(let s): return "Could not start the command: \(s)"
        case .nmapNotFound:
            return "nmap is not installed. Install it with Homebrew (brew install nmap) or from nmap.org, then try again."
        case .rangeTooLarge(let s, let min):
            return "\(s) is too large to scan. Use a /\(min) or smaller range."
        case .invalidPorts(let s):
            return "“\(s)” is not a valid port list. Use ports and ranges such as 22,80,443 or 8000-8100."
        }
    }
}

/// A validated ping/traceroute destination. A CIDR is reduced to the address typed before the slash.
struct NetTarget: Equatable {
    let host: String
    let isIPv6: Bool
    /// Set only for port-scan targets given as a CIDR range.
    var prefixLength: Int? = nil

    /// Smallest prefix (largest range) a port scan accepts: 4,096 IPv4 or 256 IPv6 addresses.
    static let minScanPrefixV4 = 20
    static let minScanPrefixV6 = 120

    /// Like `parse`, but keeps a CIDR range so nmap can scan every address in it.
    static func parseScanTarget(_ raw: String) throws -> NetTarget {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains("/") else { return try parse(raw) }
        guard let cidr = CIDR(text) else { throw NetToolError.invalidTarget(raw) }
        let isV6 = cidr.family == .v6
        let minPrefix = isV6 ? minScanPrefixV6 : minScanPrefixV4
        guard cidr.prefixLength >= minPrefix else { throw NetToolError.rangeTooLarge(cidr.description, minPrefix) }
        if cidr.prefixLength == cidr.address.bitWidth { return NetTarget(host: cidr.address.description, isIPv6: isV6) }
        return NetTarget(host: cidr.description, isIPv6: isV6, prefixLength: cidr.prefixLength)
    }

    static func parse(_ raw: String) throws -> NetTarget {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("["), text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        guard !text.isEmpty else { throw NetToolError.invalidTarget(raw) }
        if let ip = IPAddress(text) { return NetTarget(host: ip.description, isIPv6: ip.family == .v6) }
        guard isHostname(text) else { throw NetToolError.invalidTarget(raw) }
        return NetTarget(host: text.lowercased(), isIPv6: false)
    }

    /// RFC 1123 hostname; never starts with "-", so it can't be mistaken for a command-line option.
    static func isHostname(_ s: String) -> Bool {
        let name = s.hasSuffix(".") ? String(s.dropLast()) : s
        guard !name.isEmpty, name.count <= 253 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        for label in name.split(separator: ".", omittingEmptySubsequences: false) {
            guard (1...63).contains(label.count), !label.hasPrefix("-"), !label.hasSuffix("-"),
                  label.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        }
        // All-numeric dotted names would be misread as (invalid) IPv4 addresses.
        return !name.split(separator: ".").allSatisfy { $0.allSatisfy(\.isNumber) }
    }
}

enum ScanPorts: String, CaseIterable, Identifiable {
    case quick, top1000, all, custom
    var id: Self { self }
    var title: String {
        switch self {
        case .quick: return "Top 100"
        case .top1000: return "Top 1,000"
        case .all: return "All 65,535"
        case .custom: return "Custom"
        }
    }
}

struct NetToolOptions: Equatable {
    /// 0 means continuous until stopped.
    var pingCount = 5
    var maxHops = 30
    var resolveNames = false

    var scanPorts: ScanPorts = .quick
    var customPorts = "22,80,443"
    var serviceVersions = true
    var openOnly = true
    /// Treat hosts as up (-Pn). Unprivileged host discovery only probes ports 80/443, so it often
    /// wrongly reports firewalled hosts as down; ranges default to discovery so empty addresses are skipped.
    var skipHostDiscovery = true
}

enum NmapLocator {
    /// GUI apps don't inherit the shell PATH, so check the usual install locations directly.
    static let candidates = ["/opt/homebrew/bin/nmap", "/usr/local/bin/nmap", "/opt/local/bin/nmap", "/usr/bin/nmap"]

    static func find(fileManager: FileManager = .default) -> URL? {
        candidates.first { fileManager.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}

enum NetCommand {
    static func build(_ tool: NetTool, _ target: NetTarget, _ options: NetToolOptions,
                      nmap: URL? = NmapLocator.find()) throws -> (URL, [String]) {
        switch tool {
        case .portScan:
            guard let nmap else { throw NetToolError.nmapNotFound }
            return (nmap, try nmapArguments(target, options))
        case .ping:
            var args: [String] = []
            if options.pingCount > 0 { args += ["-c", String(options.pingCount)] }
            if !options.resolveNames { args.append("-n") }
            return (URL(fileURLWithPath: target.isIPv6 ? "/sbin/ping6" : "/sbin/ping"), args + [target.host])
        case .traceroute:
            // ICMP probes (-I) reach more destinations than the UDP default; one probe per hop keeps it quick.
            var args = ["-I", "-q", "1", "-w", "2", "-m", String(options.maxHops)]
            if !options.resolveNames { args.append("-n") }
            return (URL(fileURLWithPath: target.isIPv6 ? "/usr/sbin/traceroute6" : "/usr/sbin/traceroute"),
                    args + [target.host])
        }
    }
}

extension NetCommand {
    /// Validates "22,80,443" / "1-1024,8080" style lists so nothing else reaches nmap's -p.
    static func normalizedPorts(_ text: String) throws -> String {
        let cleaned = text.replacingOccurrences(of: " ", with: "")
        let items = cleaned.split(separator: ",", omittingEmptySubsequences: false)
        guard !cleaned.isEmpty, items.count <= 100 else { throw NetToolError.invalidPorts(text) }
        for item in items {
            let bounds = item.split(separator: "-", omittingEmptySubsequences: false)
            let values = bounds.compactMap { $0.count <= 5 && $0.allSatisfy { ("0"..."9").contains($0) } ? Int($0) : nil }
            guard (1...2).contains(bounds.count), values.count == bounds.count,
                  values.allSatisfy({ (1...65535).contains($0) }), values[0] <= values[values.count - 1]
            else { throw NetToolError.invalidPorts(text) }
        }
        return cleaned
    }

    static func nmapArguments(_ target: NetTarget, _ options: NetToolOptions) throws -> [String] {
        // TCP connect scan works without root; -T4 is nmap's recommended "aggressive" timing for decent links.
        var args = ["-sT", "-T4", "--stats-every", "5s"]
        if target.isIPv6 { args.append("-6") }
        switch options.scanPorts {
        case .quick: args.append("-F")
        case .top1000: break
        case .all: args.append("-p-")
        case .custom: args += ["-p", try normalizedPorts(options.customPorts)]
        }
        if options.serviceVersions { args += ["-sV", "--version-light"] }
        if options.openOnly { args.append("--open") }
        if options.skipHostDiscovery && target.prefixLength == nil { args.append("-Pn") }
        if !options.resolveNames { args.append("-n") }
        return args + [target.host]
    }
}

struct PingStats: Equatable {
    var transmitted = 0
    var received = 0
    var min: Double?
    var avg: Double?
    var max: Double?
    var stddev: Double?
    var lossPercent: Double { transmitted == 0 ? 0 : Double(transmitted - received) / Double(transmitted) * 100 }

    var summaryText: String {
        var s = "\(transmitted) sent, \(received) received, \(String(format: "%.1f", lossPercent))% loss"
        if let min, let avg, let max {
            s += String(format: " · min/avg/max %.1f/%.1f/%.1f ms", min, avg, max)
        }
        return s
    }
}

struct TraceHop: Equatable, Identifiable {
    let number: Int
    var address: String?
    var hostname: String?
    var times: [Double]
    var id: Int { number }
}

struct ScanPort: Equatable, Identifiable {
    let host: String
    let port: Int
    let proto: String
    let state: String
    let service: String
    let version: String
    var id: String { "\(host) \(port)/\(proto)" }
}

struct ScanSummary: Equatable {
    var ports: [ScanPort] = []
    var hostsUp: [String] = []
    /// Latest "About N% done" from --stats-every.
    var progress: Double?
    var doneLine: String?
    var openCount: Int { ports.filter { $0.state == "open" }.count }
}

enum NmapOutputParser {
    static func parse(_ lines: [String]) -> ScanSummary {
        var summary = ScanSummary()
        var host: String?
        var hostIsListed = false
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Nmap scan report for ") {
                host = String(line.dropFirst("Nmap scan report for ".count))
                hostIsListed = false
            } else if line.hasPrefix("Host is up"), let host, !hostIsListed {
                summary.hostsUp.append(host)
                hostIsListed = true
            } else if line.hasPrefix("Nmap done:") {
                summary.doneLine = line
                summary.progress = nil
            } else if let r = line.range(of: "About "), let pct = line[r.upperBound...].split(separator: "%").first,
                      let value = Double(pct), line.contains("% done") {
                summary.progress = value
            } else if let host, let port = portLine(line, host: host) {
                summary.ports.append(port)
                if !hostIsListed { summary.hostsUp.append(host); hostIsListed = true }
            }
        }
        return summary
    }

    /// "22/tcp   open  ssh     OpenSSH 9.6 (protocol 2.0)"
    private static func portLine(_ line: String, host: String) -> ScanPort? {
        let cols = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).map(String.init)
        guard cols.count >= 2 else { return nil }
        let pp = cols[0].split(separator: "/")
        guard pp.count == 2, let port = Int(pp[0]), ["tcp", "udp", "sctp"].contains(String(pp[1])) else { return nil }
        let version = cols.count > 3 ? cols[3].trimmingCharacters(in: .whitespaces) : ""
        return ScanPort(host: host, port: port, proto: String(pp[1]), state: cols[1],
                        service: cols.count > 2 ? cols[2] : "", version: version)
    }
}

/// Parses ping/ping6/traceroute output incrementally, so stats are live while the command runs.
enum NetOutputParser {
    static func ping(_ lines: [String]) -> PingStats {
        var stats = PingStats()
        var times: [Double] = []
        var maxSeq = -1
        var summary: (Int, Int)?
        for line in lines {
            if let seq = value(after: "icmp_seq=", in: line) ?? value(after: "icmp_seq ", in: line) {
                maxSeq = Swift.max(maxSeq, Int(seq))
            }
            if line.contains("bytes from"), let t = value(after: "time=", in: line) {
                times.append(t)
            } else if line.contains("packets transmitted") {
                let nums = line.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                if nums.count >= 2 { summary = (nums[0], nums[1]) }
            } else if line.hasPrefix("round-trip") || line.hasPrefix("rtt"), let eq = line.firstIndex(of: "=") {
                let parts = line[line.index(after: eq)...].split(separator: "/")
                    .map { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: " ms"))) }
                if parts.count >= 3 { stats.min = parts[0]; stats.avg = parts[1]; stats.max = parts[2] }
                if parts.count >= 4 { stats.stddev = parts[3] }
            }
        }
        if let summary {
            (stats.transmitted, stats.received) = summary
        } else {
            stats.received = times.count
            stats.transmitted = Swift.max(maxSeq + 1, times.count)
        }
        if stats.avg == nil, !times.isEmpty {
            stats.min = times.min()
            stats.max = times.max()
            stats.avg = times.reduce(0, +) / Double(times.count)
        }
        return stats
    }

    static func traceroute(_ lines: [String]) -> [TraceHop] {
        var hops: [TraceHop] = []
        for line in lines {
            let tokens = line.split(separator: " ").map(String.init)
            if let first = tokens.first, let n = Int(first) {
                hops.append(TraceHop(number: n, address: nil, hostname: nil, times: []))
                apply(Array(tokens.dropFirst()), to: &hops[hops.count - 1])
            } else if !tokens.isEmpty, !line.hasPrefix("traceroute"), !hops.isEmpty {
                apply(tokens, to: &hops[hops.count - 1])
            }
        }
        return hops
    }

    private static func apply(_ tokens: [String], to hop: inout TraceHop) {
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if t == "ms" || t == "*" || t.hasPrefix("!") {
                // skip
            } else if let d = Double(t), i + 1 < tokens.count, tokens[i + 1] == "ms" {
                hop.times.append(d)
            } else if t.hasPrefix("("), t.hasSuffix(")") {
                hop.address = String(t.dropFirst().dropLast())
            } else if hop.address == nil {
                if IPAddress(t) != nil { hop.address = t } else { hop.hostname = t }
            }
            i += 1
        }
    }

    private static func value(after key: String, in line: String) -> Double? {
        guard let r = line.range(of: key) else { return nil }
        return Double(line[r.upperBound...].prefix { $0.isNumber || $0 == "." })
    }
}

/// Runs a command and streams its output line by line. Stopping sends SIGINT so ping prints its summary.
final class NetCommandRunner: @unchecked Sendable {
    private let process = Process()
    private let pipe = Pipe()
    private let lock = NSLock()
    private var buffer = Data()

    init(executable: URL, arguments: [String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        process.environment = env
    }

    func start(onLine: @escaping @Sendable (String) -> Void, onExit: @escaping @Sendable (Int32) -> Void) throws {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            for line in self.takeLines(data, flush: data.isEmpty) { onLine(line) }
            if data.isEmpty { handle.readabilityHandler = nil }
        }
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            let rest = self.pipe.fileHandleForReading.readDataToEndOfFile()
            self.pipe.fileHandleForReading.readabilityHandler = nil
            for line in self.takeLines(rest, flush: true) { onLine(line) }
            onExit(p.terminationStatus)
        }
        do { try process.run() } catch { throw NetToolError.launchFailed(error.localizedDescription) }
    }

    func stop() {
        guard process.isRunning else { return }
        process.interrupt()
        let p = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { p.terminate() } }
    }

    private func takeLines(_ data: Data, flush: Bool) -> [String] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        if flush, !buffer.isEmpty {
            lines.append(String(decoding: buffer, as: UTF8.self))
            buffer.removeAll()
        }
        return lines
    }
}
