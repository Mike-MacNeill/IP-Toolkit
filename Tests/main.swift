import Foundation

var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if !condition() {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}
func json(_ s: String) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: s.data(using: .utf8)!) as! [String: Any]
}

// MARK: Address parsing and formatting
check(IPAddress("8.8.8.8")?.description == "8.8.8.8", "IPv4 round trip")
check(IPAddress(" 2001:DB8::1 ")?.description == "2001:db8::1", "IPv6 normalisation")
check(IPAddress("::ffff:1.2.3.4")?.family == .v6, "IPv4-mapped IPv6 is v6")
check(IPAddress("256.1.1.1") == nil, "Reject octet > 255")
check(IPAddress("1.2.3") == nil, "Reject short IPv4")
check(IPAddress("fe80::1%en0") == nil, "Reject zone ID")
check(IPAddress("hello") == nil, "Reject garbage")
check(IPAddress("1.2.3.4")! < IPAddress("::1")!, "IPv4 sorts before IPv6")
check(IPAddress("10.0.0.2")! < IPAddress("10.0.0.10")!, "Numeric IPv4 ordering")

// MARK: CIDR parsing
check(CIDR("192.0.2.77/24")?.description == "192.0.2.0/24", "Host bits zeroed")
check(CIDR("2001:db8:abcd::/32")?.description == "2001:db8::/32", "IPv6 host bits zeroed")
check(CIDR("0.0.0.0/0")?.lastAddress.description == "255.255.255.255", "IPv4 /0 last address")
check(CIDR("::/0")?.lastAddress.description == "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "IPv6 /0 last address")
check(CIDR("2001:db8::/64")?.lastAddress.description == "2001:db8::ffff:ffff:ffff:ffff", "IPv6 /64 last address")
check(CIDR("10.0.0.0/33") == nil, "Reject IPv4 prefix > 32")
check(CIDR("2001:db8::/129") == nil, "Reject IPv6 prefix > 128")
check(CIDR("10.0.0.0/") == nil && CIDR("10.0.0.0/-1") == nil && CIDR("10.0.0.0/+8") == nil, "Reject bad lengths")
check(CIDR("10.0.0.0/8")!.contains(IPAddress("10.255.1.1")!), "Contains")
check(!CIDR("10.0.0.0/8")!.contains(IPAddress("11.0.0.0")!), "Does not contain")

// MARK: Range -> CIDR
func covering(_ a: String, _ b: String) -> [String] {
    CIDR.covering(from: IPAddress(a)!, to: IPAddress(b)!).map(\.description)
}
check(covering("193.0.0.0", "193.0.23.255") == ["193.0.0.0/20", "193.0.16.0/21"], "RIPE-style range")
check(covering("93.175.144.0", "93.175.158.255") == ["93.175.144.0/21", "93.175.152.0/22", "93.175.156.0/23", "93.175.158.0/24"], "Uneven range")
check(covering("0.0.0.0", "255.255.255.255") == ["0.0.0.0/0"], "Whole IPv4 space")
check(covering("10.0.0.5", "10.0.0.5") == ["10.0.0.5/32"], "Single address")
check(covering("10.0.0.1", "10.0.0.6") == ["10.0.0.1/32", "10.0.0.2/31", "10.0.0.4/31", "10.0.0.6/32"], "Unaligned range")
check(covering("::", "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff") == ["::/0"], "Whole IPv6 space")
check(covering("2001:db8::", "2001:db9:ffff:ffff:ffff:ffff:ffff:ffff") == ["2001:db8::/31"], "IPv6 range")
check(covering("10.0.0.9", "10.0.0.1").isEmpty, "Reversed range is empty")

// MARK: Query parsing
check(LookupQuery("8.8.8.8")?.rdapPath == "ip/8.8.8.8", "IP path")
check(LookupQuery("8.8.8.77/24")?.rdapPath == "ip/8.8.8.0/24", "CIDR path normalised")
check(LookupQuery("2001:db8::/32")?.rdapPath == "ip/2001:db8::/32", "IPv6 CIDR path")
check(LookupQuery("not an ip") == nil, "Invalid query")

// MARK: RDAP parsing
let lacnicNetwork = json("""
{"handle":"200.3.12.0/22","name":"LACNIC","cidr0_cidrs":[{"v4prefix":"200.3.12.0","length":"22"}],
 "entities":[
   {"handle":"AIL","roles":["administrative","technical"],"vcardArray":["vcard",[["fn",{},"text","Admin Person"]]]},
   {"handle":"UY-LACN-LACNIC","roles":["registrant"],"vcardArray":["vcard",[["version",{},"text","4.0"],["fn",{},"text","LACNIC"]]],
    "links":[{"rel":"self","href":"https://rdap.lacnic.net/rdap/entity/UY-LACN-LACNIC"}]}]}
""")
let parsed = RDAPParser.parseNetwork(lacnicNetwork)
check(parsed.cidrs.map(\.description) == ["200.3.12.0/22"], "cidr0 with string length")
let owner = RDAPParser.selectOwner(lacnicNetwork)
check(owner?.handle == "UY-LACN-LACNIC" && owner?.name == "LACNIC", "Registrant selection")
check(owner?.selfURL?.absoluteString == "https://rdap.lacnic.net/rdap/entity/UY-LACN-LACNIC", "Self link")

let ripeNetwork = json("""
{"startAddress":"193.0.0.0","endAddress":"193.0.7.255","entities":[
  {"handle":"RIPE-NCC-MNT","roles":["registrant"],"vcardArray":["vcard",[["fn",{},"text","RIPE-NCC-MNT"]]]},
  {"handle":"ORG-RIEN1-RIPE","roles":["registrant"],"vcardArray":["vcard",[["fn",{},"text","RIPE NCC"],["kind",{},"text","org"]]]}]}
""")
check(RDAPParser.parseNetwork(ripeNetwork).cidrs.map(\.description) == ["193.0.0.0/21"], "Range fallback")
check(RDAPParser.selectOwner(ripeNetwork)?.handle == "ORG-RIEN1-RIPE", "Prefer org over maintainer")
check(RDAPParser.selectOwner(json(#"{"entities":[{"handle":"X","roles":["abuse"]}]}"#)) == nil, "No registrant")

let entity = json("""
{"handle":"GOGL","networks":[
  {"handle":"NET-8-8-8-0-2","name":"GOGL","cidr0_cidrs":[{"v4prefix":"8.8.8.0","length":24}]},
  {"handle":"NET6-2001-4860-1","name":"GOOGLE-IPV6","cidr0_cidrs":[{"v6prefix":"2001:4860::","length":32}]},
  {"handle":"NET-8-34-208-0-1","name":"GOOGLE","startAddress":"8.34.208.0","endAddress":"8.34.223.255"}],
 "notices":[{"title":"Result set truncated due to limits"}]}
""")
let nets = RDAPParser.entityNetworks(entity)!
check(nets.count == 3, "Entity networks count")
check(RDAPParser.isTruncated(entity), "Truncation notice detected")
check(!RDAPParser.isTruncated(lacnicNetwork), "No truncation notice")
check(RDAPParser.entityNetworks(json(#"{"handle":"X"}"#)) == nil, "Missing networks key")

let merged = RDAPParser.mergeOwned([NetworkRecord(handle: "NET-8-8-8-0-2", name: "dup", cidrs: [CIDR("8.8.8.0/24")!])] + nets)
check(merged.map(\.cidrText) == ["8.8.8.0/24", "8.34.208.0/20", "2001:4860::/32"], "Merge, dedupe, sort")
check(merged.first?.networkName == "dup", "First record wins on duplicate")

let ripeSearch = json("""
{"objects":{"object":[
  {"type":"inetnum","attributes":{"attribute":[{"name":"inetnum","value":"193.0.0.0 - 193.0.23.255"},{"name":"netname","value":"RIPE-NCC"}]}},
  {"type":"inet6num","attributes":{"attribute":[{"name":"inet6num","value":"2001:67c:2e8::/48"},{"name":"netname","value":"RIPE-NCC"}]}}]}}
""")
check(RDAPParser.ripeSearchNetworks(ripeSearch).flatMap(\.cidrs).map(\.description)
      == ["193.0.0.0/20", "193.0.16.0/21", "2001:67c:2e8::/48"], "RIPE REST parsing")

let bootstrap = json("""
{"services":[[["8.0.0.0/8","2.0.0.0/8"],["http://rdap.example/","https://rdap.example/rdap"]]]}
""")
let entries = RDAPParser.bootstrapEntries(bootstrap)
check(entries.count == 2 && entries[0].1.absoluteString == "https://rdap.example/rdap/", "Bootstrap prefers https, adds slash")
check(RDAPClient.baseURL(from: URL(string: "https://rdap.db.ripe.net/ip/193.0.6.139")!)?.absoluteString
      == "https://rdap.db.ripe.net/", "Base URL derivation")

// MARK: Subnet calculator
func row(_ info: SubnetInfo?, _ label: String) -> String? { info?.rows.first { $0.label == label }?.value }

let s24 = SubnetInfo("192.168.1.10/24")
check(s24?.network.description == "192.168.1.0/24", "Subnet network")
check(row(s24, "Address") == "192.168.1.10", "Original address kept")
check(row(s24, "Netmask") == "255.255.255.0" && row(s24, "Wildcard mask") == "0.0.0.255", "Netmask / wildcard")
check(row(s24, "Broadcast") == "192.168.1.255", "Broadcast")
check(row(s24, "First usable host") == "192.168.1.1" && row(s24, "Last usable host") == "192.168.1.254", "Host range")
check(row(s24, "Total addresses") == "256" && row(s24, "Usable hosts") == "254", "Counts")
check(row(s24, "Address type") == "Private (RFC 1918)" && row(s24, "Legacy class") == "C", "Type and class")
check(row(s24, "Binary netmask") == "11111111.11111111.11111111.00000000", "Binary netmask")
check(row(s24, "Binary address") == "11000000.10101000.00000001.00001010", "Binary address")

check(SubnetInfo("10.0.0.1 255.255.240.0")?.network.description == "10.0.0.0/20", "Space netmask")
check(SubnetInfo("10.0.0.1/255.255.255.128")?.network.description == "10.0.0.0/25", "Slash netmask")
check(SubnetInfo("10.0.0.1 255.0.255.0") == nil, "Reject non-contiguous mask")
check(SubnetInfo("10.0.0.1/33") == nil && SubnetInfo("10.0.0.1/") == nil && SubnetInfo("x/24") == nil, "Reject bad input")
check(SubnetInfo("2001:db8::1 ffff::") == nil, "No netmask syntax for IPv6")
check(SubnetInfo("8.8.8.8")?.network.description == "8.8.8.8/32", "Bare IPv4 is /32")
check(row(SubnetInfo("8.8.8.8"), "Address type") == "Public (globally routable)", "Public type")

let s31 = SubnetInfo("10.0.0.0/31"), s32 = SubnetInfo("10.0.0.7/32")
check(row(s31, "Usable hosts") == "2" && row(s31, "First usable host") == "10.0.0.0"
      && row(s31, "Broadcast")?.hasPrefix("None") == true, "/31 point-to-point")
check(row(s32, "Usable hosts") == "1" && row(s32, "Last usable host") == "10.0.0.7", "/32 single host")
let s0 = SubnetInfo("0.0.0.0/0")
check(row(s0, "Total addresses") == "4,294,967,296" && row(s0, "Usable hosts") == "4,294,967,294", "/0 counts")
check(row(s0, "Address type")?.hasPrefix("Mixed") == true, "/0 is mixed")
check(row(SubnetInfo("100.64.1.1/16"), "Address type")?.contains("CGNAT") == true, "CGNAT inside /10")

let v6 = SubnetInfo("2001:db8:abcd:12::1/48")
check(v6?.network.description == "2001:db8:abcd::/48", "IPv6 network")
check(row(v6, "Expanded") == "2001:0db8:abcd:0012:0000:0000:0000:0001", "IPv6 expanded")
check(row(v6, "Last address") == "2001:db8:abcd:ffff:ffff:ffff:ffff:ffff", "IPv6 last")
check(row(v6, "/64 subnets") == "65,536", "/64 count")
check(row(v6, "Address type") == "Documentation (RFC 3849)", "IPv6 doc type")
check(row(v6, "Total addresses") == "1,208,925,819,614,629,174,706,176 (2^80)", "IPv6 big count")
check(row(SubnetInfo("::/0"), "Total addresses") == "340,282,366,920,938,463,463,374,607,431,768,211,456 (2^128)", "2^128")
check(row(SubnetInfo("2606:4700::/32"), "Address type") == "Global unicast (RFC 4291)", "Global unicast")
check(row(SubnetInfo("fd12:3456::/48"), "Address type") == "Unique local (RFC 4193)", "ULA")

check(s24!.subnets(prefix: 26, limit: 100).map(\.description)
      == ["192.168.1.0/26", "192.168.1.64/26", "192.168.1.128/26", "192.168.1.192/26"], "Split /24 into /26")
check(SubnetInfo("10.0.0.0/8")!.subnets(prefix: 24, limit: 1024).count == 1024, "Split limit")
check(SubnetInfo("10.0.0.0/8")!.subnets(prefix: 24, limit: 1024).last?.description == "10.3.255.0/24", "Split order")
check(SubnetInfo("255.255.255.252/30")!.subnets(prefix: 32, limit: 10).count == 4, "Split at top of space")
check(s24!.subnets(prefix: 24, limit: 10).isEmpty && s32!.splitOptions == nil, "No-op splits")
check(NumberText.shortPowerOfTwo(40) == "2^40" && NumberText.shortPowerOfTwo(10) == "1,024", "Short counts")

// MARK: Geolocation parsing
let ipinfoObj = json("""
{"ip":"8.8.8.8","hostname":"dns.google","city":"Mountain View","region":"California","country":"US",
 "loc":"38.0088,-122.1175","org":"AS15169 Google LLC","postal":"94043","timezone":"America/Los_Angeles","anycast":true}
""")
let g1 = GeoParser.ipinfo(ipinfoObj)
check(g1?.city == "Mountain View" && g1?.countryName == "United States" && g1?.countryCode == "US", "ipinfo place")
check(g1?.latitude == 38.0088 && g1?.longitude == -122.1175, "ipinfo coordinates")
check(g1?.asn == "AS15169" && g1?.organization == "Google LLC", "ipinfo org split")
check(g1?.anycast == true && g1?.hostname == "dns.google" && g1?.provider == "ipinfo.io", "ipinfo extras")
check(g1?.placeText == "Mountain View, California, United States", "Place text")
check(g1?.rows.first { $0.label == "Country" }?.value == "United States (US)", "Country row")
check(g1?.mapsURL?.absoluteString.hasPrefix("https://maps.apple.com/?ll=38.0088,-122.1175") == true, "Maps URL")
check(GeoParser.ipinfo(json(#"{"ip":"10.1.2.3","bogon":true}"#)) == nil, "ipinfo bogon")
check(GeoParser.ipinfo(json(#"{"status":404,"error":{"title":"Wrong ip"}}"#)) == nil, "ipinfo error")
check(GeoParser.ipinfo(json(#"{"ip":"1.2.3.4","org":"Some Org"}"#))?.organization == "Some Org", "Org without ASN")
check(GeoParser.ipinfo(json(#"{"ip":"1.2.3.4"}"#))?.placeText == "Unknown location", "Empty location")

let ipwhoisObj = json("""
{"ip":"2606:4700:4700::1111","success":true,"country":"United States","country_code":"US","region":"California",
 "city":"San Francisco","latitude":37.774926,"longitude":-122.4194208,"postal":"94119",
 "connection":{"asn":13335,"org":"Cloudflare, Inc.","isp":"Cloudflare"},"timezone":{"id":"America/Los_Angeles"}}
""")
let g2 = GeoParser.ipwhois(ipwhoisObj)
check(g2?.city == "San Francisco" && g2?.asn == "AS13335" && g2?.organization == "Cloudflare, Inc.", "ipwhois parse")
check(g2?.latitude == 37.774926 && g2?.timezone == "America/Los_Angeles" && g2?.provider == "ipwho.is", "ipwhois extras")
check(GeoParser.ipwhois(json(#"{"ip":"10.1.2.3","success":false,"message":"Reserved range"}"#)) == nil, "ipwhois failure")

check(GeoParser.nonPublicReason(IPAddress("8.8.8.8")!) == nil, "Public v4 allowed")
check(GeoParser.nonPublicReason(IPAddress("2606:4700::1")!) == nil, "Global v6 allowed")
check(GeoParser.nonPublicReason(IPAddress("192.168.0.1")!) == "Private (RFC 1918)", "Private v4 rejected")
check(GeoParser.nonPublicReason(IPAddress("127.0.0.1")!) != nil, "Loopback rejected")
check(GeoParser.nonPublicReason(IPAddress("fe80::1")!) != nil && GeoParser.nonPublicReason(IPAddress("2001:db8::1")!) != nil,
      "Link-local / documentation v6 rejected")

// MARK: Ping / traceroute
check(try! NetTarget.parse(" 8.8.8.8 ") == NetTarget(host: "8.8.8.8", isIPv6: false), "Target v4")
check(try! NetTarget.parse("2001:4860:4860:0::8888") == NetTarget(host: "2001:4860:4860::8888", isIPv6: true), "Target v6 normalized")
check(try! NetTarget.parse("[::1]") == NetTarget(host: "::1", isIPv6: true), "Target bracketed v6")
check(try! NetTarget.parse("192.168.1.0/24").host == "192.168.1.0", "Target CIDR uses address")
check(try! NetTarget.parse("Apple.COM.").host == "apple.com.", "Target hostname")
for bad in ["", "-c 99 8.8.8.8", "-oops", "bad host", "a..b", "x;rm -rf", "999.1.1.1", "exa_mple.com"] {
    check((try? NetTarget.parse(bad)) == nil, "Rejects target \(bad)")
}
do {
    let v4 = NetTarget(host: "8.8.8.8", isIPv6: false), v6 = NetTarget(host: "::1", isIPv6: true)
    let (p1, a1) = try! NetCommand.build(.ping, v4, NetToolOptions())
    check(p1.path == "/sbin/ping" && a1 == ["-c", "5", "-n", "8.8.8.8"], "Ping args \(a1)")
    let (p2, a2) = try! NetCommand.build(.ping, v6, NetToolOptions(pingCount: 0, resolveNames: true))
    check(p2.path == "/sbin/ping6" && a2 == ["::1"], "Continuous ping6 args \(a2)")
    let (p3, a3) = try! NetCommand.build(.traceroute, v4, NetToolOptions(maxHops: 15))
    check(p3.path == "/usr/sbin/traceroute" && a3 == ["-I", "-q", "1", "-w", "2", "-m", "15", "-n", "8.8.8.8"], "Trace args \(a3)")
    check(try! NetCommand.build(.traceroute, v6, NetToolOptions()).0.path == "/usr/sbin/traceroute6", "traceroute6")
}
let pingOut = """
PING 8.8.8.8 (8.8.8.8): 56 data bytes
64 bytes from 8.8.8.8: icmp_seq=0 ttl=117 time=41.046 ms
Request timeout for icmp_seq 1
64 bytes from 8.8.8.8: icmp_seq=2 ttl=117 time=36.296 ms
""".components(separatedBy: "\n")
let live = NetOutputParser.ping(pingOut)
check(live.transmitted == 3 && live.received == 2 && live.min == 36.296 && live.max == 41.046, "Live ping stats \(live)")
let done = NetOutputParser.ping(pingOut + ["", "--- 8.8.8.8 ping statistics ---",
    "4 packets transmitted, 2 packets received, 50.0% packet loss",
    "round-trip min/avg/max/stddev = 36.296/38.671/41.046/2.375 ms"])
check(done.transmitted == 4 && done.received == 2 && done.avg == 38.671 && done.stddev == 2.375, "Final ping stats")
check(done.summaryText == "4 sent, 2 received, 50.0% loss · min/avg/max 36.3/38.7/41.0 ms", "Ping summary \(done.summaryText)")
let hops = NetOutputParser.traceroute("""
traceroute to apple.com (17.253.144.10), 30 hops max, 72 byte packets
 1  router.local (10.52.23.1)  33.086 ms
 2  *
 3  74.125.233.144  37.097 ms !H
 4  2001:db8::1  5.5 ms
""".components(separatedBy: "\n"))
check(hops.count == 4, "Trace hop count")
check(hops[0] == TraceHop(number: 1, address: "10.52.23.1", hostname: "router.local", times: [33.086]), "Named hop")
check(hops[1].address == nil && hops[1].times.isEmpty, "Silent hop")
check(hops[2].address == "74.125.233.144" && hops[2].hostname == nil && hops[2].times == [37.097], "Numeric hop")
check(hops[3].address == "2001:db8::1", "IPv6 hop")

// MARK: nmap port scan
check(try! NetTarget.parseScanTarget("10.0.0.0/24") == NetTarget(host: "10.0.0.0/24", isIPv6: false, prefixLength: 24), "Scan CIDR kept")
check(try! NetTarget.parseScanTarget("10.0.0.7/24").host == "10.0.0.0/24", "Scan CIDR normalized")
check(try! NetTarget.parseScanTarget("10.0.0.7/32") == NetTarget(host: "10.0.0.7", isIPv6: false), "Scan /32 is a host")
check(try! NetTarget.parseScanTarget("2001:db8::/120").prefixLength == 120, "Scan v6 /120")
check(try! NetTarget.parseScanTarget("scanme.nmap.org").host == "scanme.nmap.org", "Scan hostname")
for bad in ["10.0.0.0/19", "10.0.0.0/8", "2001:db8::/64", "10.0.0.0/33", "-sS 1.2.3.4", "x/24"] {
    check((try? NetTarget.parseScanTarget(bad)) == nil, "Rejects scan target \(bad)")
}
check(try! NetCommand.normalizedPorts("22, 80,443,8000-8100") == "22,80,443,8000-8100", "Ports normalized")
for bad in ["", "0", "65536", "80-22", "22,,80", "-p 80", "80;ls", "+80", "1-2-3", "abc"] {
    check((try? NetCommand.normalizedPorts(bad)) == nil, "Rejects ports \(bad)")
}
do {
    let nmap = URL(fileURLWithPath: "/opt/homebrew/bin/nmap")
    let host = NetTarget(host: "192.0.2.5", isIPv6: false)
    let (exe, a1) = try! NetCommand.build(.portScan, host, NetToolOptions(), nmap: nmap)
    check(exe == nmap && a1 == ["-sT", "-T4", "--stats-every", "5s", "-F", "-sV", "--version-light", "--open", "-Pn", "-n", "192.0.2.5"], "nmap default args \(a1)")
    var o = NetToolOptions(resolveNames: true)
    o.scanPorts = .custom; o.customPorts = "22,443"; o.serviceVersions = false; o.openOnly = false
    let a2 = try! NetCommand.nmapArguments(NetTarget(host: "2001:db8::/120", isIPv6: true, prefixLength: 120), o)
    check(a2 == ["-sT", "-T4", "--stats-every", "5s", "-6", "-p", "22,443", "2001:db8::/120"], "nmap custom v6 range args \(a2)")
    o.scanPorts = .all
    check(try! NetCommand.nmapArguments(host, o).contains("-p-"), "nmap all ports")
    do { _ = try NetCommand.build(.portScan, host, NetToolOptions(), nmap: nil); check(false, "nmap missing should throw") }
    catch { check((error as? NetToolError) == .nmapNotFound, "nmap missing error") }
}
let scan = NmapOutputParser.parse("""
Starting Nmap 7.98 ( https://nmap.org ) at 2025-01-01 10:00 EST
Stats: 0:00:03 elapsed; 0 hosts completed (1 up), 1 undergoing Connect Scan
Connect Scan Timing: About 42.50% done; ETC: 10:00 (0:00:04 remaining)
Nmap scan report for router.local (192.168.1.1)
Host is up (0.0040s latency).
Not shown: 97 closed tcp ports (conn-refused)
PORT    STATE SERVICE VERSION
22/tcp  open  ssh     OpenSSH 9.6 (protocol 2.0)
80/tcp  open  http    nginx
443/tcp filtered https

Nmap scan report for 192.168.1.20
Host is up (0.010s latency).
PORT     STATE SERVICE
8080/tcp open  http-proxy

Service detection performed. Please report any incorrect results at https://nmap.org/submit/ .
Nmap done: 256 IP addresses (2 hosts up) scanned in 12.34 seconds
""".components(separatedBy: "\n"))
check(scan.hostsUp == ["router.local (192.168.1.1)", "192.168.1.20"], "Scan hosts \(scan.hostsUp)")
check(scan.ports.count == 4 && scan.openCount == 3, "Scan port counts")
check(scan.ports[0] == ScanPort(host: "router.local (192.168.1.1)", port: 22, proto: "tcp", state: "open", service: "ssh", version: "OpenSSH 9.6 (protocol 2.0)"), "Scan port with version")
check(scan.ports[2].state == "filtered" && scan.ports[2].version == "", "Filtered port")
check(scan.progress == nil && scan.doneLine?.hasPrefix("Nmap done: 256") == true, "Scan done line")
check(NmapOutputParser.parse(["Connect Scan Timing: About 42.50% done; ETC: 10:00"]).progress == 42.5, "Scan progress")

// MARK: My IP
check(MyIPParser.address(from: "144.125.244.139\n", family: .v4) == "144.125.244.139", "My IP v4 parse")
check(MyIPParser.address(from: " 2001:DB8:0::1 ", family: .v6) == "2001:db8::1", "My IP v6 normalized")
check(MyIPParser.address(from: "144.125.244.139", family: .v6) == nil, "My IP wrong family rejected")
check(MyIPParser.address(from: "<html>error</html>", family: .v4) == nil, "My IP junk rejected")
check(MyIPParser.address(from: "", family: .v4) == nil, "My IP empty rejected")
check(MyIPResult(ipv4: nil, ipv6: "2001:db8::1").preferred == "2001:db8::1", "My IP prefers v6 when no v4")
check(MyIPResult(ipv4: "1.2.3.4", ipv6: "2001:db8::1").preferred == "1.2.3.4", "My IP prefers v4")
check(MyIPResult(ipv4: "1.2.3.4", ipv6: nil).summaryText == "IPv4: 1.2.3.4", "My IP summary")

// MARK: Live registry checks (network required): run with --live
if CommandLine.arguments.contains("--live") {
    let client = RDAPClient()
    let cases: [(String, String, String)] = [
        ("8.8.8.8", "GOGL", "8.8.8.0/24"),
        ("193.0.6.139", "ORG-RIEN1-RIPE", "193.0.0.0/21"),
        ("1.1.1.1", "ORG-ARAD1-AP", "1.1.1.0/24"),
        ("200.3.14.10", "UY-LACN-LACNIC", "200.3.12.0/22"),
        ("196.216.2.1", "ORG-AFNC1-AFRINIC", "196.216.2.0/23"),
        ("2001:4860:4860::8888", "GOGL", "2001:4860::/32"),
        ("8.8.8.0/24", "GOGL", "8.8.8.0/24"),
    ]
    let done = DispatchSemaphore(value: 0)
    Task {
        for (input, handle, expected) in cases {
            do {
                let r = try await client.lookup(input)
                print("LIVE \(input): \(r.ownerDisplayName) [\(r.owner?.handle ?? "-")] \(r.ownedNetworks.count) CIDRs via \(r.registry)")
                r.notes.forEach { print("   note: \($0)") }
                check(r.owner?.handle == handle, "\(input) owner handle \(r.owner?.handle ?? "nil")")
                check(r.ownedNetworks.contains { $0.cidrText == expected }, "\(input) owned list contains \(expected)")
                check(r.ownedNetworks.count > 1, "\(input) owner has multiple CIDRs")
            } catch {
                check(false, "\(input) threw \(error.localizedDescription)")
            }
        }
        do {
            _ = try await client.lookup("10.1.2.3")
            check(false, "Private address should fail")
        } catch {
            check((error as? LookupError) == .noRegistry("10.1.2.3"), "Private address error: \(error)")
        }
        let geo = GeoClient()
        for input in ["8.8.8.8", "2606:4700:4700::1111", "193.0.6.0/24"] {
            do {
                let g = try await geo.locate(input)
                print("LIVE geo \(input): \(g.placeText) [\(g.coordinateText ?? "-")] \(g.organization ?? "") via \(g.provider)")
                check(g.countryCode != nil && g.latitude != nil, "\(input) geolocated with coordinates")
            } catch {
                check(false, "geo \(input) threw \(error.localizedDescription)")
            }
        }
        do {
            _ = try await geo.locate("192.168.1.1")
            check(false, "Private geolocation should fail")
        } catch {
            check((error as? GeoError) == .notPublic("192.168.1.1", "Private (RFC 1918)"), "Private geo error: \(error)")
        }
        done.signal()
    }
    done.wait()

    // Real ping/traceroute through the same runner the app uses.
    func runTool(_ tool: NetTool, _ host: String, _ opts: NetToolOptions, stopAfter: Double? = nil) -> [String] {
        let target = tool == .portScan ? try! NetTarget.parseScanTarget(host) : try! NetTarget.parse(host)
        let (exe, args) = try! NetCommand.build(tool, target, opts)
        let runner = NetCommandRunner(executable: exe, arguments: args)
        final class Lines: @unchecked Sendable { let lock = NSLock(); var all: [String] = [] }
        let box = Lines()
        let finished = DispatchSemaphore(value: 0)
        try! runner.start(onLine: { l in box.lock.lock(); box.all.append(l); box.lock.unlock() }, onExit: { _ in finished.signal() })
        if let stopAfter { Thread.sleep(forTimeInterval: stopAfter); runner.stop() }
        _ = finished.wait(timeout: .now() + 120)
        box.lock.lock(); defer { box.lock.unlock() }
        return box.all
    }
    do {
        let mine = DispatchSemaphore(value: 0)
        Task {
            do {
                let r = try await MyIPClient().fetch()
                print("LIVE my IP: \(r.ipv4 ?? "no IPv4") / \(r.ipv6 ?? "no IPv6")")
                check(r.preferred.flatMap(IPAddress.init) != nil, "My IP is a valid address")
                if let v4 = r.ipv4 { check(GeoParser.nonPublicReason(IPAddress(v4)!) == nil, "My IPv4 is public") }
            } catch {
                check(false, "My IP lookup threw \(error)")
            }
            mine.signal()
        }
        mine.wait()
    }
    let pingLines = runTool(.ping, "8.8.8.8", NetToolOptions(pingCount: 3))
    let ps = NetOutputParser.ping(pingLines)
    print("LIVE ping: \(ps.summaryText)")
    check(ps.transmitted == 3 && ps.received > 0 && ps.avg != nil, "Live ping 8.8.8.8")
    let contLines = runTool(.ping, "127.0.0.1", NetToolOptions(pingCount: 0), stopAfter: 2.5)
    let cs = NetOutputParser.ping(contLines)
    print("LIVE continuous ping stopped: \(cs.summaryText)")
    check(contLines.contains { $0.contains("packets transmitted") } && cs.received >= 2, "Stopping continuous ping prints summary")
    let traceLines = runTool(.traceroute, "8.8.8.8", NetToolOptions())
    let th = NetOutputParser.traceroute(traceLines)
    print("LIVE traceroute: \(th.count) hops, last \(th.last?.address ?? "*")")
    check(th.last?.address == "8.8.8.8", "Traceroute reaches 8.8.8.8")

    if NmapLocator.find() != nil {
        var o = NetToolOptions()
        o.scanPorts = .custom; o.customPorts = "22,80,443"; o.openOnly = false; o.serviceVersions = false
        let scanLines = runTool(.portScan, "127.0.0.1", o)
        let s = NmapOutputParser.parse(scanLines)
        print("LIVE nmap: \(s.hostsUp) \(s.ports.map { "\($0.port)/\($0.state)" }) \(s.doneLine ?? "-")")
        check(s.hostsUp.count == 1 && s.ports.count == 3 && s.doneLine != nil, "nmap scans localhost")
    } else {
        print("LIVE nmap: skipped (nmap not installed)")
    }
}

if failures > 0 {
    print("\(failures) test(s) failed")
    exit(1)
}
print("PASS: all tests")
