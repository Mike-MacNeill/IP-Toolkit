import Foundation

struct GeoResult: Equatable {
    var ip: String
    var city: String?
    var region: String?
    var countryCode: String?
    var countryName: String?
    var postal: String?
    var latitude: Double?
    var longitude: Double?
    var timezone: String?
    var organization: String?
    var asn: String?
    var hostname: String?
    var anycast = false
    var provider: String

    var placeText: String {
        let parts = [city, region, countryName ?? countryCode].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "Unknown location" : parts.joined(separator: ", ")
    }

    var coordinateText: String? {
        guard let latitude, let longitude else { return nil }
        return String(format: "%.4f, %.4f", latitude, longitude)
    }

    var rows: [SubnetRow] {
        var r: [SubnetRow] = [SubnetRow(label: "IP address", value: ip)]
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { r.append(SubnetRow(label: label, value: value)) }
        }
        add("City", city)
        add("Region", region)
        add("Country", countryName.map { name in countryCode.map { "\(name) (\($0))" } ?? name } ?? countryCode)
        add("Postal code", postal)
        add("Coordinates", coordinateText)
        add("Time zone", timezone)
        add("Organization", organization)
        add("ASN", asn)
        add("Hostname", hostname)
        add("Source", provider)
        return r
    }

    var summaryText: String { rows.map { "\($0.label): \($0.value)" }.joined(separator: "\n") }

    var mapsURL: URL? {
        guard let latitude, let longitude else { return nil }
        var c = URLComponents(string: "https://maps.apple.com/")!
        c.queryItems = [URLQueryItem(name: "ll", value: "\(latitude),\(longitude)"),
                        URLQueryItem(name: "q", value: placeText)]
        return c.url
    }
}

enum GeoError: LocalizedError, Equatable {
    case invalidInput(String)
    case notPublic(String, String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let s):
            return "“\(s)” is not a valid IPv4 or IPv6 address."
        case .notPublic(let ip, let type):
            return "\(ip) is not a public address (\(type)), so it has no geographic location."
        case .failed(let detail):
            return "Geolocation failed: \(detail)"
        }
    }
}

/// Pure parsing helpers for the geolocation providers, kept separate from networking for testing.
enum GeoParser {
    /// Parses an ipinfo.io /json response. Returns nil for bogon or error responses.
    static func ipinfo(_ obj: [String: Any]) -> GeoResult? {
        guard obj["error"] == nil, obj["bogon"] as? Bool != true, let ip = obj["ip"] as? String else { return nil }
        var r = GeoResult(ip: ip, provider: "ipinfo.io")
        r.city = nonEmpty(obj["city"])
        r.region = nonEmpty(obj["region"])
        r.countryCode = nonEmpty(obj["country"])
        r.countryName = r.countryCode.flatMap { Locale(identifier: "en_US").localizedString(forRegionCode: $0) }
        r.postal = nonEmpty(obj["postal"])
        r.timezone = nonEmpty(obj["timezone"])
        r.hostname = nonEmpty(obj["hostname"])
        r.anycast = obj["anycast"] as? Bool ?? false
        if let loc = nonEmpty(obj["loc"]) {
            let parts = loc.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2 { r.latitude = parts[0]; r.longitude = parts[1] }
        }
        // "org" is "AS15169 Google LLC"; split out the ASN.
        if let org = nonEmpty(obj["org"]) {
            if org.hasPrefix("AS"), let space = org.firstIndex(of: " ") {
                r.asn = String(org[..<space])
                r.organization = String(org[org.index(after: space)...])
            } else {
                r.organization = org
            }
        }
        return r
    }

    /// Parses an ipwho.is response. Returns nil when `success` is false.
    static func ipwhois(_ obj: [String: Any]) -> GeoResult? {
        guard obj["success"] as? Bool == true, let ip = obj["ip"] as? String else { return nil }
        var r = GeoResult(ip: ip, provider: "ipwho.is")
        r.city = nonEmpty(obj["city"])
        r.region = nonEmpty(obj["region"])
        r.countryCode = nonEmpty(obj["country_code"])
        r.countryName = nonEmpty(obj["country"])
        r.postal = nonEmpty(obj["postal"])
        r.latitude = (obj["latitude"] as? NSNumber)?.doubleValue
        r.longitude = (obj["longitude"] as? NSNumber)?.doubleValue
        r.timezone = nonEmpty((obj["timezone"] as? [String: Any])?["id"])
        if let conn = obj["connection"] as? [String: Any] {
            r.organization = nonEmpty(conn["org"]) ?? nonEmpty(conn["isp"])
            if let asn = (conn["asn"] as? NSNumber)?.intValue, asn > 0 { r.asn = "AS\(asn)" }
        }
        return r
    }

    /// Returns a reason when the address is in a non-public range, or nil when it can be geolocated.
    static func nonPublicReason(_ ip: IPAddress) -> String? {
        let type = SubnetInfo.classify(CIDR(address: ip, prefixLength: ip.bitWidth)!)
        let ok = ip.family == .v4 ? "Public (globally routable)" : "Global unicast (RFC 4291)"
        return type == ok ? nil : type
    }

    private static func nonEmpty(_ any: Any?) -> String? {
        guard let s = any as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// Geolocates via ipinfo.io, falling back to ipwho.is if ipinfo.io fails or is rate-limited.
actor GeoClient {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpAdditionalHeaders = ["User-Agent": "IPToolkit/1.0 (macOS)", "Accept": "application/json"]
        session = URLSession(configuration: config)
    }

    /// Accepts an address, or a CIDR (its network address is located).
    func locate(_ input: String) async throws -> GeoResult {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ip = LookupQuery(trimmed)?.address else { throw GeoError.invalidInput(trimmed) }
        if let reason = GeoParser.nonPublicReason(ip) { throw GeoError.notPublic(ip.description, reason) }

        var failures: [String] = []
        do {
            let obj = try await fetch("https://ipinfo.io/\(ip)/json")
            if let r = GeoParser.ipinfo(obj) { return r }
            failures.append("ipinfo.io had no data")
        } catch {
            failures.append("ipinfo.io: \(error.localizedDescription)")
        }
        do {
            let obj = try await fetch("https://ipwho.is/\(ip)")
            if let r = GeoParser.ipwhois(obj) { return r }
            failures.append("ipwho.is: \((obj["message"] as? String) ?? "no data")")
        } catch {
            failures.append("ipwho.is: \(error.localizedDescription)")
        }
        throw GeoError.failed(failures.joined(separator: "; "))
    }

    private struct FetchError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func fetch(_ urlString: String) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FetchError(message: http.statusCode == 429 ? "rate limited" : "HTTP \(http.statusCode)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError(message: "unreadable response")
        }
        return obj
    }
}
