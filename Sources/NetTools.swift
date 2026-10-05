import Foundation

enum NetTool: String, CaseIterable, Identifiable {
    case ping, traceroute
    var id: Self { self }
    var title: String { self == .ping ? "Ping" : "Traceroute" }
}

enum NetToolError: Error, LocalizedError, Equatable {
    case invalidTarget(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidTarget(let s): return "“\(s)” is not a valid IP address or hostname."
        case .launchFailed(let s): return "Could not start the command: \(s)"
        }
    }
}

/// A validated ping/traceroute destination. A CIDR is reduced to the address typed before the slash.
struct NetTarget: Equatable {
    let host: String
    let isIPv6: Bool

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

struct NetToolOptions: Equatable {
    /// 0 means continuous until stopped.
    var pingCount = 5
    var maxHops = 30
    var resolveNames = false
}

enum NetCommand {
    static func build(_ tool: NetTool, _ target: NetTarget, _ options: NetToolOptions) -> (URL, [String]) {
        switch tool {
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
