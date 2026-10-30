import Foundation
import Security

enum ReputationError: LocalizedError, Equatable {
    case invalidInput
    case notPublic(String)
    case missingKey
    case invalidKey
    case http(Int)
    case rateLimited(String?)
    case invalidResponse
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidInput: return "Enter a valid IPv4 or IPv6 address (or CIDR)."
        case .notPublic(let reason): return "Reputation is available only for public IP addresses (\(reason))."
        case .missingKey: return "Save your AbuseIPDB API key below before checking reputation."
        case .invalidKey: return "The API key must contain only printable ASCII characters without spaces."
        case .http(401), .http(403): return "AbuseIPDB rejected the API key. Check your key and account permissions."
        case .http(let status): return "AbuseIPDB request failed (HTTP \(status))."
        case .rateLimited(let retry):
            return "AbuseIPDB API quota exceeded." + (retry.map { " Retry after \($0)." } ?? " Try again later.")
        case .invalidResponse: return "AbuseIPDB returned an invalid or mismatched response."
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "OSStatus \(status)"
            return "Could not access the API key in Keychain: \(detail)"
        }
    }
}

struct ReputationResult: Decodable, Equatable {
    let ipAddress: String
    let isPublic: Bool
    let abuseConfidenceScore: Int
    let totalReports: Int
    let numDistinctUsers: Int
    let lastReportedAt: String?
    let countryCode: String?
    let usageType: String?
    let isp: String?
    let domain: String?
    let isWhitelisted: Bool?
    let isTor: Bool?

    var rows: [SubnetRow] {
        var rows = [
            SubnetRow(label: "IP address", value: ipAddress),
            SubnetRow(label: "Abuse confidence", value: "\(abuseConfidenceScore)%"),
            SubnetRow(label: "Reports (last 90 days)", value: "\(totalReports)"),
            SubnetRow(label: "Distinct reporters", value: "\(numDistinctUsers)"),
            SubnetRow(label: "Last reported", value: lastReportedAt ?? "Never")
        ]
        for (label, value) in [("Country", countryCode), ("Usage", usageType), ("ISP", isp), ("Domain", domain)] {
            if let value, !value.isEmpty { rows.append(SubnetRow(label: label, value: value)) }
        }
        if let isWhitelisted { rows.append(SubnetRow(label: "Allowlisted", value: isWhitelisted ? "Yes" : "No")) }
        if let isTor { rows.append(SubnetRow(label: "Tor exit node", value: isTor ? "Yes" : "No")) }
        return rows
    }

    var summaryText: String {
        (["Source: AbuseIPDB"] + rows.map { "\($0.label): \($0.value)" }).joined(separator: "\n")
    }
}

enum ReputationRequest {
    static func validatedKey(_ raw: String) throws -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ReputationError.missingKey }
        guard key.utf8.allSatisfy({ (33...126).contains($0) }) else { throw ReputationError.invalidKey }
        return key
    }

    static func address(_ input: String) throws -> IPAddress {
        guard let ip = LookupQuery(input)?.address else { throw ReputationError.invalidInput }
        if let reason = GeoParser.nonPublicReason(ip) { throw ReputationError.notPublic(reason) }
        return ip
    }

    static func build(input: String, apiKey: String) throws -> URLRequest {
        let ip = try address(input)
        let key = try validatedKey(apiKey)
        var url = URLComponents(string: "https://api.abuseipdb.com/api/v2/check")!
        url.queryItems = [
            URLQueryItem(name: "ipAddress", value: ip.description),
            URLQueryItem(name: "maxAgeInDays", value: "90")
        ]
        var request = URLRequest(url: url.url!)
        request.setValue(key, forHTTPHeaderField: "Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("IPToolkit/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func decode(_ data: Data, response: HTTPURLResponse, expectedIP: IPAddress) throws -> ReputationResult {
        switch response.statusCode {
        case 200: break
        case 429: throw ReputationError.rateLimited(response.value(forHTTPHeaderField: "Retry-After"))
        default: throw ReputationError.http(response.statusCode)
        }
        struct Envelope: Decodable { let data: ReputationResult }
        let result: ReputationResult
        do { result = try JSONDecoder().decode(Envelope.self, from: data).data }
        catch { throw ReputationError.invalidResponse }
        guard IPAddress(result.ipAddress) == expectedIP, result.isPublic,
              (0...100).contains(result.abuseConfidenceScore),
              result.totalReports >= 0, result.numDistinctUsers >= 0 else {
            throw ReputationError.invalidResponse
        }
        return result
    }
}

// Never forward the API key to a redirected endpoint.
private final class ReputationSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor ReputationClient {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: configuration, delegate: ReputationSessionDelegate(), delegateQueue: nil)
        }
    }

    func check(_ input: String, apiKey: String) async throws -> ReputationResult {
        let request = try ReputationRequest.build(input: input, apiKey: apiKey)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw ReputationError.invalidResponse }
        return try ReputationRequest.decode(data, response: http, expectedIP: ReputationRequest.address(input))
    }
}

struct ReputationKeyStore {
    private let service = "local.mmacneill.iptoolkit.abuseipdb"
    private let account = "api-key"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ReputationError.keychain(status) }
        guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            throw ReputationError.keychain(errSecDecode)
        }
        return key
    }

    func save(_ raw: String) throws {
        let key = try ReputationRequest.validatedKey(raw)
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var request = query.merging(attributes) { _, new in new }
            request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(request as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw ReputationError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw ReputationError.keychain(status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ReputationError.keychain(status) }
    }
}
