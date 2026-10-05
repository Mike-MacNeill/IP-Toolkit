import Foundation

struct MyIPResult: Equatable {
    let ipv4: String?
    let ipv6: String?

    /// The address to put in the query field: IPv4 if available, otherwise IPv6.
    var preferred: String? { ipv4 ?? ipv6 }

    var summaryText: String {
        [ipv4.map { "IPv4: \($0)" }, ipv6.map { "IPv6: \($0)" }].compactMap { $0 }.joined(separator: "\n")
    }
}

enum MyIPError: Error, LocalizedError, Equatable {
    case unavailable

    var errorDescription: String? {
        "Could not determine your public IP address. Check your internet connection and try again."
    }
}

enum MyIPParser {
    /// Accepts a plain-text echo-service response, returning the address only if it is the expected family.
    static func address(from body: String, family: IPAddress.Family) -> String? {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ip = IPAddress(text), ip.family == family else { return nil }
        return ip.description
    }
}

/// Finds this Mac's public (internet-facing) addresses using plain-text "what is my IP" services.
/// The IPv4-only and IPv6-only hostnames force the connection over that address family.
actor MyIPClient {
    static let ipv4Sources = [URL(string: "https://api.ipify.org")!, URL(string: "https://ipv4.icanhazip.com")!]
    static let ipv6Sources = [URL(string: "https://api6.ipify.org")!, URL(string: "https://ipv6.icanhazip.com")!]

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 10
        config.httpAdditionalHeaders = ["User-Agent": "IPToolkit/1.0"]
        session = URLSession(configuration: config)
    }

    func fetch() async throws -> MyIPResult {
        async let v4 = first(Self.ipv4Sources, family: .v4)
        async let v6 = first(Self.ipv6Sources, family: .v6)
        let result = MyIPResult(ipv4: await v4, ipv6: await v6)
        guard result.preferred != nil else { throw MyIPError.unavailable }
        return result
    }

    private func first(_ urls: [URL], family: IPAddress.Family) async -> String? {
        for url in urls {
            guard !Task.isCancelled else { return nil }
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let ip = MyIPParser.address(from: String(decoding: data, as: UTF8.self), family: family)
            else { continue }
            return ip
        }
        return nil
    }
}
