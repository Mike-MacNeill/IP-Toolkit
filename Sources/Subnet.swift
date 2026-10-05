import Foundation

extension U128 {
    /// 2^n for n in 0..<128.
    static func powerOfTwo(_ n: Int) -> U128? { n >= 0 && n < 128 ? U128.lowBits(n).incremented() : nil }

    func decremented() -> U128? {
        if lo != 0 { return U128(hi: hi, lo: lo - 1) }
        if hi != 0 { return U128(hi: hi - 1, lo: .max) }
        return nil
    }

    func divided(by d: UInt64) -> (quotient: U128, remainder: UInt64) {
        let (qhi, rhi) = hi.quotientAndRemainder(dividingBy: d)
        let (qlo, r) = d.dividingFullWidth((high: rhi, low: lo))
        return (U128(hi: qhi, lo: qlo), r)
    }

    var decimalString: String {
        if hi == 0 { return String(lo) }
        var digits: [Character] = []
        var v = self
        while v != .zero {
            let (q, r) = v.divided(by: 10)
            digits.append(Character(String(r)))
            v = q
        }
        return String(digits.reversed())
    }
}

enum NumberText {
    static func grouped(_ digits: String) -> String {
        var out: [Character] = []
        for (i, c) in digits.reversed().enumerated() {
            if i > 0 && i % 3 == 0 { out.append(",") }
            out.append(c)
        }
        return String(out.reversed())
    }

    /// 2^bits as a grouped decimal string (bits 0...128).
    static func powerOfTwo(_ bits: Int) -> String {
        if bits == 128 { return "340,282,366,920,938,463,463,374,607,431,768,211,456" }
        return grouped(U128.powerOfTwo(bits)!.decimalString)
    }

    /// Compact count for menus: exact up to 2^32, otherwise "2^n".
    static func shortPowerOfTwo(_ bits: Int) -> String { bits <= 32 ? powerOfTwo(bits) : "2^\(bits)" }
}

struct SubnetRow: Identifiable, Hashable {
    let label: String
    let value: String
    var id: String { label }
}

struct SubnetInfo {
    let address: IPAddress
    let network: CIDR

    var family: IPAddress.Family { address.family }
    var prefixLength: Int { network.prefixLength }
    var bitWidth: Int { address.bitWidth }

    /// Accepts "addr", "addr/len", "addr/netmask", or "addr netmask" (IPv4 netmasks must be contiguous).
    init?(_ text: String) {
        guard let (ip, len) = Self.parse(text), let cidr = CIDR(address: ip, prefixLength: len) else { return nil }
        address = ip
        network = cidr
    }

    static func parse(_ text: String) -> (IPAddress, Int)? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts: [String]
        if s.contains("/") {
            parts = s.split(separator: "/", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { return nil }
        } else {
            parts = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count == 1 || parts.count == 2 else { return nil }
        }
        guard let ip = IPAddress(parts[0]) else { return nil }
        if parts.count == 1 { return (ip, ip.bitWidth) }

        let suffix = parts[1]
        if !suffix.isEmpty, suffix.count <= 3, suffix.allSatisfy({ $0.isASCII && $0.isNumber }), let len = Int(suffix) {
            return len <= ip.bitWidth ? (ip, len) : nil
        }
        guard ip.family == .v4, let mask = IPAddress(suffix), mask.family == .v4,
              let len = prefixLength(fromNetmask: mask) else { return nil }
        return (ip, len)
    }

    static func prefixLength(fromNetmask mask: IPAddress) -> Int? {
        let host = ~mask.value.lo & 0xFFFF_FFFF
        guard host & (host + 1) == 0 else { return nil }
        return 32 - host.nonzeroBitCount
    }

    var netmask: IPAddress { IPAddress(family: family, value: ~U128.lowBits(bitWidth - prefixLength)) }
    var wildcard: IPAddress { IPAddress(family: family, value: U128.lowBits(bitWidth - prefixLength)) }

    /// IPv4 broadcast; nil for IPv6 and for /31 and /32.
    var broadcast: IPAddress? { family == .v4 && prefixLength <= 30 ? network.lastAddress : nil }

    var firstHost: IPAddress {
        if family == .v4 && prefixLength <= 30 {
            return IPAddress(family: family, value: network.address.value.incremented()!)
        }
        return network.address
    }

    var lastHost: IPAddress {
        if family == .v4 && prefixLength <= 30 {
            return IPAddress(family: family, value: network.lastAddress.value.decremented()!)
        }
        return network.lastAddress
    }

    var totalAddresses: String { NumberText.powerOfTwo(bitWidth - prefixLength) }

    var usableHosts: String {
        guard family == .v4 else { return totalAddresses }
        switch prefixLength {
        case 32: return "1"
        case 31: return "2"
        default: return NumberText.grouped(String((UInt64(1) << UInt64(32 - prefixLength)) - 2))
        }
    }

    var legacyClass: String {
        let first = address.value.lo >> 24
        switch first {
        case 0..<128: return "A"
        case 128..<192: return "B"
        case 192..<224: return "C"
        case 224..<240: return "D (multicast)"
        default: return "E (reserved)"
        }
    }

    var addressType: String { Self.classify(network) }

    static func binary(_ ip: IPAddress) -> String {
        (0..<4).map { i in
            let octet = String((ip.value.lo >> UInt64(24 - 8 * i)) & 0xFF, radix: 2)
            return String(repeating: "0", count: 8 - octet.count) + octet
        }.joined(separator: ".")
    }

    static func expanded(_ ip: IPAddress) -> String {
        (0..<8).map { i in
            let word = i < 4 ? ip.value.hi >> UInt64(48 - 16 * i) : ip.value.lo >> UInt64(48 - 16 * (i - 4))
            return String(format: "%04x", UInt16(truncatingIfNeeded: word))
        }.joined(separator: ":")
    }

    var rows: [SubnetRow] {
        var r: [SubnetRow] = [SubnetRow(label: "Address", value: address.description)]
        switch family {
        case .v4:
            let noBroadcast = prefixLength == 31 ? "None (point-to-point, RFC 3021)" : "None (single host)"
            r += [
                SubnetRow(label: "Network", value: network.description),
                SubnetRow(label: "Netmask", value: netmask.description),
                SubnetRow(label: "Wildcard mask", value: wildcard.description),
                SubnetRow(label: "Broadcast", value: broadcast?.description ?? noBroadcast),
                SubnetRow(label: "First usable host", value: firstHost.description),
                SubnetRow(label: "Last usable host", value: lastHost.description),
                SubnetRow(label: "Total addresses", value: totalAddresses),
                SubnetRow(label: "Usable hosts", value: usableHosts),
                SubnetRow(label: "Address type", value: addressType),
                SubnetRow(label: "Legacy class", value: legacyClass),
                SubnetRow(label: "Binary address", value: Self.binary(address)),
                SubnetRow(label: "Binary netmask", value: Self.binary(netmask)),
            ]
        case .v6:
            r += [
                SubnetRow(label: "Expanded", value: Self.expanded(address)),
                SubnetRow(label: "Network", value: network.description),
                SubnetRow(label: "First address", value: network.address.description),
                SubnetRow(label: "Last address", value: network.lastAddress.description),
                SubnetRow(label: "Total addresses",
                          value: "\(totalAddresses)" + (bitWidth - prefixLength >= 20 ? " (2^\(bitWidth - prefixLength))" : "")),
            ]
            if prefixLength < 64 {
                r.append(SubnetRow(label: "/64 subnets", value: NumberText.powerOfTwo(64 - prefixLength)))
            }
            r.append(SubnetRow(label: "Address type", value: addressType))
        }
        return r
    }

    var summaryText: String { rows.map { "\($0.label): \($0.value)" }.joined(separator: "\n") }

    /// Prefix lengths this network can be split into.
    var splitOptions: ClosedRange<Int>? { prefixLength < bitWidth ? (prefixLength + 1)...bitWidth : nil }

    /// The first `limit` subnets of length `newPrefix`, in address order.
    func subnets(prefix newPrefix: Int, limit: Int) -> [CIDR] {
        guard newPrefix > prefixLength, newPrefix <= bitWidth, limit > 0 else { return [] }
        var out: [CIDR] = []
        var current = network.address.value
        let end = network.lastAddress.value
        while out.count < limit {
            let block = CIDR(address: IPAddress(family: family, value: current), prefixLength: newPrefix)!
            out.append(block)
            let last = block.lastAddress.value
            guard last < end, let next = last.incremented() else { break }
            current = next
        }
        return out
    }

    // MARK: Special-purpose ranges (IANA special-purpose registries, RFC 6890)

    private static let v4Special: [(CIDR, String)] = [
        ("0.0.0.0/8", "This network (RFC 1122)"),
        ("10.0.0.0/8", "Private (RFC 1918)"),
        ("100.64.0.0/10", "Shared address space / CGNAT (RFC 6598)"),
        ("127.0.0.0/8", "Loopback (RFC 1122)"),
        ("169.254.0.0/16", "Link-local (RFC 3927)"),
        ("172.16.0.0/12", "Private (RFC 1918)"),
        ("192.0.0.0/24", "IETF protocol assignments (RFC 6890)"),
        ("192.0.2.0/24", "Documentation, TEST-NET-1 (RFC 5737)"),
        ("192.88.99.0/24", "6to4 relay anycast, deprecated (RFC 7526)"),
        ("192.168.0.0/16", "Private (RFC 1918)"),
        ("198.18.0.0/15", "Benchmarking (RFC 2544)"),
        ("198.51.100.0/24", "Documentation, TEST-NET-2 (RFC 5737)"),
        ("203.0.113.0/24", "Documentation, TEST-NET-3 (RFC 5737)"),
        ("224.0.0.0/4", "Multicast (RFC 5771)"),
        ("240.0.0.0/4", "Reserved (RFC 1112)"),
        ("255.255.255.255/32", "Limited broadcast (RFC 919)"),
    ].map { (CIDR($0.0)!, $0.1) }

    private static let v6Special: [(CIDR, String)] = [
        ("::/128", "Unspecified (RFC 4291)"),
        ("::1/128", "Loopback (RFC 4291)"),
        ("::ffff:0:0/96", "IPv4-mapped (RFC 4291)"),
        ("64:ff9b::/96", "NAT64 well-known prefix (RFC 6052)"),
        ("64:ff9b:1::/48", "Local-use NAT64 (RFC 8215)"),
        ("100::/64", "Discard-only (RFC 6666)"),
        ("2000::/3", "Global unicast (RFC 4291)"),
        ("2001::/32", "Teredo (RFC 4380)"),
        ("2001:db8::/32", "Documentation (RFC 3849)"),
        ("2002::/16", "6to4 (RFC 3056)"),
        ("3fff::/20", "Documentation (RFC 9637)"),
        ("fc00::/7", "Unique local (RFC 4193)"),
        ("fe80::/10", "Link-local unicast (RFC 4291)"),
        ("ff00::/8", "Multicast (RFC 4291)"),
    ].map { (CIDR($0.0)!, $0.1) }

    static func classify(_ network: CIDR) -> String {
        let table = network.family == .v4 ? v4Special : v6Special
        let enclosing = table.filter { $0.0.prefixLength <= network.prefixLength && $0.0.contains(network.address) }
        let innermost = enclosing.max { $0.0.prefixLength < $1.0.prefixLength }
        let containsSpecial = table.contains { entry in
            entry.0.prefixLength > network.prefixLength && network.contains(entry.0.address)
                && (innermost == nil || entry.1 != innermost!.1)
        }
        if containsSpecial { return "Mixed (contains special-purpose ranges)" }
        if let innermost { return innermost.1 }
        return network.family == .v4 ? "Public (globally routable)" : "Reserved by IETF"
    }
}
