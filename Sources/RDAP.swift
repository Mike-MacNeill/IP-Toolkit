import Foundation

struct NetworkRecord: Hashable {
    var handle: String?
    var name: String?
    var cidrs: [CIDR]
}

struct OwnerRecord: Hashable {
    var handle: String
    var name: String?
    var selfURL: URL?
}

struct OwnedNetwork: Identifiable, Hashable {
    let cidr: CIDR
    let networkName: String?
    let handle: String?
    var id: CIDR { cidr }
    var cidrText: String { cidr.description }
}

struct LookupResult {
    let query: String
    let registry: String
    let network: NetworkRecord
    let owner: OwnerRecord?
    let ownedNetworks: [OwnedNetwork]
    let notes: [String]

    var ownerDisplayName: String { owner?.name ?? owner?.handle ?? "Unknown owner" }
    var cidrListText: String { ownedNetworks.map(\.cidrText).joined(separator: "\n") }
}

enum LookupError: LocalizedError, Equatable {
    case invalidInput(String)
    case noRegistry(String)
    case notFound(String)
    case rateLimited(String)
    case http(Int, String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let s):
            return "“\(s)” is not a valid IPv4/IPv6 address or CIDR (for example 8.8.8.8 or 2001:db8::/32)."
        case .noRegistry(let s):
            return "\(s) is in a private, reserved, or special-purpose range that no Internet registry assigns."
        case .notFound(let s):
            return "The registry has no record for \(s)."
        case .rateLimited(let host):
            return "\(host) is rate-limiting requests. Wait a minute and try again."
        case .http(let code, let host):
            return "\(host) returned HTTP \(code)."
        case .badResponse(let host):
            return "\(host) returned a response that could not be read."
        }
    }
}

/// Pure parsing helpers for RDAP (RFC 9083) JSON, kept separate from networking for testing.
enum RDAPParser {
    static func parseNetwork(_ obj: [String: Any]) -> NetworkRecord {
        var cidrs: [CIDR] = []
        for entry in obj["cidr0_cidrs"] as? [[String: Any]] ?? [] {
            let prefix = (entry["v4prefix"] as? String) ?? (entry["v6prefix"] as? String)
            if let prefix, let ip = IPAddress(prefix), let len = intValue(entry["length"]),
               let cidr = CIDR(address: ip, prefixLength: len) {
                cidrs.append(cidr)
            }
        }
        if cidrs.isEmpty, let s = obj["startAddress"] as? String, let e = obj["endAddress"] as? String,
           let start = IPAddress(s), let end = IPAddress(e) {
            cidrs = CIDR.covering(from: start, to: end)
        }
        return NetworkRecord(handle: obj["handle"] as? String, name: obj["name"] as? String, cidrs: cidrs)
    }

    /// Picks the registrant entity, preferring organisations over maintainer objects.
    static func selectOwner(_ networkObj: [String: Any]) -> OwnerRecord? {
        let entities = networkObj["entities"] as? [[String: Any]] ?? []
        let registrants = entities.filter { ($0["roles"] as? [String] ?? []).contains("registrant") }
        func score(_ e: [String: Any]) -> Int {
            var s = 0
            if vcardValue(e, "kind")?.lowercased() == "org" { s += 2 }
            if let h = e["handle"] as? String, h.uppercased().hasSuffix("-MNT") { s -= 2 }
            return s
        }
        guard let best = registrants.enumerated()
            .max(by: { (score($0.element), -$0.offset) < (score($1.element), -$1.offset) })?.element,
            let handle = best["handle"] as? String else { return nil }
        return OwnerRecord(handle: handle, name: vcardValue(best, "fn"), selfURL: selfLink(best))
    }

    static func entityNetworks(_ entityObj: [String: Any]) -> [NetworkRecord]? {
        guard let nets = entityObj["networks"] as? [[String: Any]] else { return nil }
        return nets.map(parseNetwork)
    }

    static func isTruncated(_ obj: [String: Any]) -> Bool {
        let items = (obj["notices"] as? [[String: Any]] ?? []) + (obj["remarks"] as? [[String: Any]] ?? [])
        return items.contains { item in
            let text = [item["title"] as? String, item["type"] as? String].compactMap { $0 }
                + (item["description"] as? [String] ?? [])
            return text.contains { $0.lowercased().contains("truncated") }
        }
    }

    /// Parses RIPE Database REST inverse-search results (inetnum / inet6num objects).
    static func ripeSearchNetworks(_ obj: [String: Any]) -> [NetworkRecord] {
        let objects = (obj["objects"] as? [String: Any])?["object"] as? [[String: Any]] ?? []
        return objects.compactMap { object in
            let attrs = (object["attributes"] as? [String: Any])?["attribute"] as? [[String: Any]] ?? []
            func attr(_ name: String) -> String? {
                attrs.first { ($0["name"] as? String) == name }?["value"] as? String
            }
            var cidrs: [CIDR] = []
            if let range = attr("inetnum") {
                let ends = range.components(separatedBy: "-").map { $0.trimmingCharacters(in: .whitespaces) }
                if ends.count == 2, let s = IPAddress(ends[0]), let e = IPAddress(ends[1]) {
                    cidrs = CIDR.covering(from: s, to: e)
                }
            } else if let prefix = attr("inet6num"), let cidr = CIDR(prefix) {
                cidrs = [cidr]
            }
            guard !cidrs.isEmpty else { return nil }
            return NetworkRecord(handle: attr("inetnum") ?? attr("inet6num"), name: attr("netname"), cidrs: cidrs)
        }
    }

    /// Flattens, de-duplicates, and sorts networks into individual CIDR rows.
    static func mergeOwned(_ groups: [NetworkRecord]) -> [OwnedNetwork] {
        var seen: [CIDR: OwnedNetwork] = [:]
        for group in groups {
            for cidr in group.cidrs where seen[cidr] == nil {
                seen[cidr] = OwnedNetwork(cidr: cidr, networkName: group.name, handle: group.handle)
            }
        }
        return seen.values.sorted { $0.cidr < $1.cidr }
    }

    /// IANA RDAP bootstrap registry (RFC 9224) entries: prefix -> base URL.
    static func bootstrapEntries(_ obj: [String: Any]) -> [(CIDR, URL)] {
        var entries: [(CIDR, URL)] = []
        for service in obj["services"] as? [[Any]] ?? [] {
            guard service.count >= 2, let prefixes = service[0] as? [String],
                  let urls = service[1] as? [String] else { continue }
            guard let urlString = urls.first(where: { $0.hasPrefix("https://") }) ?? urls.first,
                  let url = URL(string: urlString.hasSuffix("/") ? urlString : urlString + "/") else { continue }
            for p in prefixes { if let cidr = CIDR(p) { entries.append((cidr, url)) } }
        }
        return entries
    }

    static func vcardValue(_ entity: [String: Any], _ property: String) -> String? {
        guard let vcard = entity["vcardArray"] as? [Any], vcard.count > 1,
              let props = vcard[1] as? [[Any]] else { return nil }
        for p in props where p.count >= 4 && (p[0] as? String) == property {
            if let s = p[3] as? String, !s.isEmpty { return s }
        }
        return nil
    }

    static func selfLink(_ obj: [String: Any]) -> URL? {
        for link in obj["links"] as? [[String: Any]] ?? [] where (link["rel"] as? String) == "self" {
            if let href = link["href"] as? String, let url = URL(string: href), url.scheme == "https" { return url }
        }
        return nil
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
}

actor RDAPClient {
    private let session: URLSession
    private var bootstrapCache: [IPAddress.Family: [(CIDR, URL)]] = [:]

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 45
            config.httpAdditionalHeaders = ["User-Agent": "IPToolkit/1.0 (macOS)"]
            self.session = URLSession(configuration: config)
        }
    }

    func lookup(_ input: String) async throws -> LookupResult {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let query = LookupQuery(trimmed) else { throw LookupError.invalidInput(trimmed) }

        let base = try await registryBase(for: query.address)
        guard let networkURL = URL(string: query.rdapPath, relativeTo: base)?.absoluteURL else {
            throw LookupError.invalidInput(trimmed)
        }
        let (networkObj, finalURL) = try await fetchJSON(networkURL, subject: query.displayText)
        let network = RDAPParser.parseNetwork(networkObj)
        let registry = (networkObj["port43"] as? String) ?? finalURL.host ?? base.host ?? "RDAP"
        var owner = RDAPParser.selectOwner(networkObj)
        var notes: [String] = []
        var groups: [NetworkRecord] = [network]

        if let current = owner {
            let answeringBase = Self.baseURL(from: finalURL) ?? base
            let entityURL = current.selfURL
                ?? URL(string: "entity/" + (current.handle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? current.handle),
                       relativeTo: answeringBase)!.absoluteURL
            do {
                let (entityObj, _) = try await fetchJSON(entityURL, subject: current.handle)
                if owner?.name == nil { owner?.name = RDAPParser.vcardValue(entityObj, "fn") }
                if let nets = RDAPParser.entityNetworks(entityObj), !nets.isEmpty {
                    groups += nets
                } else {
                    notes.append("\(registry) does not publish the other networks held by this owner.")
                }
                if RDAPParser.isTruncated(entityObj) {
                    notes.append("The registry truncated this owner's network list; some networks may be missing.")
                }
            } catch LookupError.notFound {
                notes.append("\(registry) does not publish the other networks held by this owner.")
            } catch {
                notes.append("Could not retrieve this owner's other networks: \(error.localizedDescription)")
            }

            if finalURL.host?.hasSuffix("ripe.net") == true, current.handle.uppercased().hasPrefix("ORG-") {
                groups += await ripeInverseSearch(orgHandle: current.handle, notes: &notes)
            }
        } else {
            notes.append("The registry did not identify a registrant for this network.")
        }

        return LookupResult(query: query.displayText, registry: registry, network: network, owner: owner,
                            ownedNetworks: RDAPParser.mergeOwned(groups), notes: notes)
    }

    /// RIPE's RDAP lists only top-level networks; its REST inverse search also returns nested ones.
    private func ripeInverseSearch(orgHandle: String, notes: inout [String]) async -> [NetworkRecord] {
        var components = URLComponents(string: "https://rest.db.ripe.net/search.json")!
        components.queryItems = [
            URLQueryItem(name: "query-string", value: orgHandle),
            URLQueryItem(name: "inverse-attribute", value: "org"),
            URLQueryItem(name: "type-filter", value: "inetnum"),
            URLQueryItem(name: "type-filter", value: "inet6num"),
            URLQueryItem(name: "flags", value: "r"),
        ]
        do {
            let (obj, _) = try await fetchJSON(components.url!, subject: orgHandle, accept: "application/json")
            return RDAPParser.ripeSearchNetworks(obj)
        } catch LookupError.notFound {
            return []
        } catch {
            notes.append("RIPE inverse search failed; nested networks may be missing.")
            return []
        }
    }

    private func registryBase(for ip: IPAddress) async throws -> URL {
        if bootstrapCache[ip.family] == nil {
            let file = ip.family == .v4 ? "ipv4.json" : "ipv6.json"
            let (obj, _) = try await fetchJSON(URL(string: "https://data.iana.org/rdap/\(file)")!,
                                               subject: "IANA bootstrap", accept: "application/json")
            bootstrapCache[ip.family] = RDAPParser.bootstrapEntries(obj)
        }
        let match = bootstrapCache[ip.family]!
            .filter { $0.0.contains(ip) }
            .max { $0.0.prefixLength < $1.0.prefixLength }
        guard let match else { throw LookupError.noRegistry(ip.description) }
        return match.1
    }

    private func fetchJSON(_ url: URL, subject: String,
                           accept: String = "application/rdap+json, application/json") async throws -> ([String: Any], URL) {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let host = response.url?.host ?? url.host ?? "registry"
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 404: throw LookupError.notFound(subject)
            case 429: throw LookupError.rateLimited(host)
            default: throw LookupError.http(http.statusCode, host)
            }
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LookupError.badResponse(host)
        }
        return (obj, response.url ?? url)
    }

    /// Derives the RDAP base URL (ending in "/") from a ".../ip/..." response URL.
    static func baseURL(from url: URL) -> URL? {
        let s = url.absoluteString
        guard let range = s.range(of: "/ip/", options: .backwards) else { return nil }
        return URL(string: String(s[..<range.lowerBound]) + "/")
    }
}
