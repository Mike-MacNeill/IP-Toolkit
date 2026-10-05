import Foundation

/// Minimal unsigned 128-bit value, sufficient for IPv4/IPv6 prefix arithmetic on macOS 13.
struct U128: Hashable, Comparable {
    var hi: UInt64
    var lo: UInt64

    static let zero = U128(hi: 0, lo: 0)

    /// A value with the lowest `count` bits set (0...128).
    static func lowBits(_ count: Int) -> U128 {
        switch count {
        case ..<1: return .zero
        case 1..<64: return U128(hi: 0, lo: (UInt64(1) << UInt64(count)) - 1)
        case 64: return U128(hi: 0, lo: .max)
        case 65..<128: return U128(hi: (UInt64(1) << UInt64(count - 64)) - 1, lo: .max)
        default: return U128(hi: .max, lo: .max)
        }
    }

    static func & (a: U128, b: U128) -> U128 { U128(hi: a.hi & b.hi, lo: a.lo & b.lo) }
    static func | (a: U128, b: U128) -> U128 { U128(hi: a.hi | b.hi, lo: a.lo | b.lo) }
    static prefix func ~ (a: U128) -> U128 { U128(hi: ~a.hi, lo: ~a.lo) }
    static func < (a: U128, b: U128) -> Bool { a.hi != b.hi ? a.hi < b.hi : a.lo < b.lo }

    var trailingZeroBitCount: Int {
        lo != 0 ? lo.trailingZeroBitCount : (hi != 0 ? 64 + hi.trailingZeroBitCount : 128)
    }

    /// Adds one, returning nil on overflow past 2^128 - 1.
    func incremented() -> U128? {
        if lo != .max { return U128(hi: hi, lo: lo + 1) }
        if hi != .max { return U128(hi: hi + 1, lo: 0) }
        return nil
    }
}

struct IPAddress: Hashable, Comparable, CustomStringConvertible {
    enum Family: Int, Hashable { case v4 = 4, v6 = 6 }

    let family: Family
    let value: U128

    var bitWidth: Int { family == .v4 ? 32 : 128 }

    init(family: Family, value: U128) {
        self.family = family
        self.value = value & U128.lowBits(family == .v4 ? 32 : 128)
    }

    init?(_ text: String) {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains("%") else { return nil }
        var a4 = in_addr()
        if inet_pton(AF_INET, s, &a4) == 1 {
            self.init(family: .v4, value: U128(hi: 0, lo: UInt64(UInt32(bigEndian: a4.s_addr))))
            return
        }
        var a6 = in6_addr()
        if inet_pton(AF_INET6, s, &a6) == 1 {
            let bytes = withUnsafeBytes(of: &a6) { Array($0) }
            var hi: UInt64 = 0, lo: UInt64 = 0
            for i in 0..<8 { hi = (hi << 8) | UInt64(bytes[i]) }
            for i in 8..<16 { lo = (lo << 8) | UInt64(bytes[i]) }
            self.init(family: .v6, value: U128(hi: hi, lo: lo))
            return
        }
        return nil
    }

    var description: String {
        switch family {
        case .v4:
            var a4 = in_addr(s_addr: UInt32(truncatingIfNeeded: value.lo).bigEndian)
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &a4, &buf, socklen_t(buf.count))
            return String(cString: buf)
        case .v6:
            var a6 = in6_addr()
            withUnsafeMutableBytes(of: &a6) { raw in
                for i in 0..<8 { raw[i] = UInt8(truncatingIfNeeded: value.hi >> UInt64(56 - 8 * i)) }
                for i in 0..<8 { raw[8 + i] = UInt8(truncatingIfNeeded: value.lo >> UInt64(56 - 8 * i)) }
            }
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &a6, &buf, socklen_t(buf.count))
            return String(cString: buf)
        }
    }

    static func < (a: IPAddress, b: IPAddress) -> Bool {
        a.family != b.family ? a.family.rawValue < b.family.rawValue : a.value < b.value
    }
}

struct CIDR: Hashable, Comparable, CustomStringConvertible {
    let address: IPAddress
    let prefixLength: Int

    /// Creates a CIDR, zeroing any host bits of `address`.
    init?(address: IPAddress, prefixLength: Int) {
        guard (0...address.bitWidth).contains(prefixLength) else { return nil }
        let host = U128.lowBits(address.bitWidth - prefixLength)
        self.address = IPAddress(family: address.family, value: address.value & ~host)
        self.prefixLength = prefixLength
    }

    /// Parses "a.b.c.d/n" or "x::/n". Host bits are zeroed.
    init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let ip = IPAddress(String(parts[0])),
              !parts[1].isEmpty, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
              parts[1].count <= 3, let len = Int(parts[1]) else { return nil }
        self.init(address: ip, prefixLength: len)
    }

    var family: IPAddress.Family { address.family }
    var description: String { "\(address)/\(prefixLength)" }

    var lastAddress: IPAddress {
        IPAddress(family: family, value: address.value | U128.lowBits(address.bitWidth - prefixLength))
    }

    func contains(_ ip: IPAddress) -> Bool {
        ip.family == family && address.value <= ip.value && ip.value <= lastAddress.value
    }

    static func < (a: CIDR, b: CIDR) -> Bool {
        a.address != b.address ? a.address < b.address : a.prefixLength < b.prefixLength
    }

    /// The minimal list of CIDR blocks exactly covering the inclusive range start...end.
    static func covering(from start: IPAddress, to end: IPAddress) -> [CIDR] {
        guard start.family == end.family, start.value <= end.value else { return [] }
        let width = start.bitWidth
        var blocks: [CIDR] = []
        var current = start.value
        while true {
            var prefix = width - min(current.trailingZeroBitCount, width)
            while prefix < width && end.value < (current | U128.lowBits(width - prefix)) { prefix += 1 }
            let block = CIDR(address: IPAddress(family: start.family, value: current), prefixLength: prefix)!
            blocks.append(block)
            let last = block.lastAddress.value
            guard last < end.value, let next = last.incremented() else { break }
            current = next
        }
        return blocks
    }
}

/// User input: either a single address or a CIDR block.
enum LookupQuery: Equatable {
    case address(IPAddress)
    case network(CIDR)

    init?(_ text: String) {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.contains("/") {
            guard let cidr = CIDR(s) else { return nil }
            self = .network(cidr)
        } else {
            guard let ip = IPAddress(s) else { return nil }
            self = .address(ip)
        }
    }

    var address: IPAddress {
        switch self {
        case .address(let ip): return ip
        case .network(let cidr): return cidr.address
        }
    }

    /// RDAP path (RFC 9082 section 3.1.1).
    var rdapPath: String {
        switch self {
        case .address(let ip): return "ip/\(ip)"
        case .network(let cidr): return "ip/\(cidr.address)/\(cidr.prefixLength)"
        }
    }

    var displayText: String {
        switch self {
        case .address(let ip): return ip.description
        case .network(let cidr): return cidr.description
        }
    }
}
