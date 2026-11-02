# IP Toolkit for macOS

A separate Windows desktop implementation is available in [Windows/README.md](Windows/README.md).

A native macOS 13+ app (Apple Silicon and Intel) with five tools for an IPv4/IPv6
address or CIDR:

- **IP Lookup:** shows the registered owner, every CIDR block registered to
  that owner, and the estimated geographic location with a map.
- **Subnet Calculator:** offline subnet math and splitting.
- **Reputation:** checks AbuseIPDB abuse confidence and community reports using
  your API key, stored in macOS Keychain.
- **Network:** runs ping, traceroute, or an nmap port scan against an address,
  hostname, or (for port scans) a small CIDR range, with live output.
- **Speed Test:** estimates this Mac's internet download/upload speeds and HTTPS
  latency using Cloudflare, without installing extra tools.

## Use

Open `dist/IP Toolkit.app` (copy it to Applications if desired). Enter an
address such as `8.8.8.8`, `2001:4860:4860::8888`, or a CIDR such as
`193.0.0.0/21`, then press Return or click **Look Up**.

The window shows:

- The owner (registrant organization), its registry handle, and the registry.
- The network block that contains your input.
- A table of every CIDR registered to that owner, with network names and handles.
  **Copy CIDRs** puts the list on the clipboard, one per line.
- Estimated geolocation and a map, on the same tab. Ownership and geolocation
  load independently; either result remains available if the other service fails.

### Open at login

Check **Open at login** in the main window (or right-click the menu bar icon →
**Open at Login**) to start IP Toolkit automatically when you log in. When started
at login with **Show as menu bar icon when minimized** on, the app goes straight
to the menu bar without opening a window.

The setting uses macOS's login items (System Settings → General → Login Items),
which also show and control it. macOS may ask you to allow the item there first.
The login item points to the app's current location, so if you move the app
(for example into Applications), turn the option off and on again.

### My IP

The **My IP** button next to the input box (in every tool, including the menu bar
box) finds this Mac's public internet address. It fills it in and runs the
current tool, so you can see your own owner, subnet, location, or reputation in one click.
In **Network** the address is only filled in, not started. Your public IPv4 and IPv6
addresses are shown under the input with copy buttons. "no IPv6" means your
network doesn't have IPv6 internet access.

The addresses come from [ipify](https://www.ipify.org), falling back to
[icanhazip](https://icanhazip.com). These services see your IP address when you
use the button, which is unavoidable for this kind of lookup.

### Menu bar mode

With **Show as menu bar icon when minimized** checked (the default), the
minimize button (or ⌘M) hides the window and Dock icon. A magnifying glass with
"IP" appears in the menu bar instead:

- **Click** the icon for a small input box. Type an IP or CIDR and press Return
  to see the result for the selected tool in place.
- **Open Window** (or right-click the icon → *Open IP Toolkit*) restores the
  full window and Dock icon.
- Right-click → **Quit** exits.

The icon is placed at the right end of the menu bar (next to the system icons)
so it isn't lost behind the camera notch or the active app's menus on a crowded
menu bar. ⌘-drag it to move it; that position is remembered. If you still can't
see it, open IP Toolkit again from Finder or Spotlight to bring the window back,
and check **System Settings → Menu Bar** that IP Toolkit is allowed.

Uncheck the option to minimize to the Dock normally. Closing the window quits the app.

### Subnet calculator

Switch the segmented control at the top of the window or the menu bar input box
to **Subnet Calculator**. Results update as you type, and work entirely offline.
The input box is shared, so switching modes keeps what you typed.

Accepted input: `192.168.1.10/24`, `10.0.0.1 255.255.255.0`, `10.0.0.1/255.255.255.0`,
`2001:db8::1/48`, or a bare address (treated as /32 or /128).

To calculate a different subnet around the same IP, select a prefix in the
**CIDR** picker, or enter a dotted IPv4 mask (`255.255.255.192`) or prefix
(`/26` or `26`) in the **Mask or CIDR** field and choose **Calculate** (or press
Return in that field). IPv6 uses prefix lengths from /0 to /128; IPv4 supports
/0 to /32 and contiguous netmasks. The original host address is preserved,
results update immediately, and any previous split selection is reset.
Invalid masks show an error without replacing the current calculation.
These controls are also available in the menu bar popover.

- **IPv4:** network, netmask, wildcard mask, broadcast, first/last usable host,
  total addresses, usable hosts, address type, legacy class, and binary
  address/netmask. /31 (point-to-point, RFC 3021) and /32 are handled.
- **IPv6:** expanded address, network, first/last address, total addresses,
  number of /64s, and address type.
- **Address type** identifies private (RFC 1918), CGNAT, loopback, link-local,
  documentation, multicast, unique-local, and other IANA special-purpose ranges.
- **Split into** divides the network into smaller subnets of a chosen prefix
  length. Up to 1,024 subnets are listed.
- **Copy Details** and **Copy Subnets** copy the results as plain text.

### IP Lookup: owner and geolocation

Switch to **IP Lookup**, enter a public IPv4 or IPv6 address (a CIDR is located
by its network address), and press Return or click **Look Up**. Alongside the
owner and registered CIDRs, the geolocation result shows
city, region, country, postal code, coordinates, time zone, organization, ASN,
and hostname, plus a map pin. **Open in Maps** opens the location in Apple Maps;
**Copy** copies the details.

- Data comes from [ipinfo.io](https://ipinfo.io) and falls back to
  [ipwho.is](https://ipwho.is) if ipinfo is unavailable or rate-limited.
  Both free tiers are rate-limited and need no API key.
- **Privacy:** the address you geolocate is sent to these third-party services.
  Owner lookups go only to the regional internet registries; the subnet
  calculator makes no network requests. Ping and traceroute send packets
  directly to the target from your Mac.
- IP geolocation is an estimate, usually accurate to city or region at best.
  Anycast addresses (for example `8.8.8.8`, `1.1.1.1`) are served from many sites;
  the app flags these.
- Geolocation rejects private, loopback, link-local, documentation, and other
  non-public addresses locally without contacting a geolocation service.

### IP reputation

Switch to **Reputation** in the window or menu bar input box. Get an API key
from [your AbuseIPDB account](https://www.abuseipdb.com/account/api), paste it in
the secure field, and choose **Save Key**. Enter a public IP and choose **Check**.
The key is saved in macOS Keychain (not preferences or source files), reused on
future launches, and never displayed again. **Save Key** replaces it;
**Remove Key** deletes it and cancels a running check. macOS may prompt for
Keychain access, especially after changing the app's signing identity.

- Shows AbuseIPDB's abuse confidence (0–100%), reports in the last 90 days,
  distinct reporters, last report timestamp, and available ISP/domain/country,
  usage type, allowlist and Tor information. **Copy** copies these details.
- IPv4 and IPv6 are supported. A CIDR checks **only its network address**,
  not the reputation of the entire network. Invalid and non-public inputs are
  rejected locally.
- A zero score or no reports does **not** prove an address is safe. Scores
  reflect community reports and can change; they are not a definitive verdict.
- **Privacy:** a check sends the queried IP and your API key to AbuseIPDB over
  HTTPS. The key is sent in a header, not a URL; redirects are not followed.
  Checks are read-only: the app never submits abuse reports.
- Your account's API quotas apply. Authentication, rate-limit, network and
  response errors are shown explicitly. Reputation is not automatically checked
  when using **IP Lookup**, so ordinary lookups do not consume this quota.

### Speed Test

Select **Speed Test**, then **Start Speed Test**. No target address, API key,
or additional installation is needed. The tab is also available in the menu bar
popover; switching tabs does not stop a test. **Stop** cancels the active test,
and **Copy Results** copies a completed result with its timestamp.

Each completed test transfers approximately **36 MB** of payload (30 MB
download and 6 MB upload), plus protocol overhead. Avoid testing on metered
connections. Tests never start automatically when you open the tab or use My IP.
Cloudflare sees your public IP and test traffic at `speed.cloudflare.com`.
Uploads contain generated test data, never local files.

This is a lightweight, single-connection HTTPS estimate, **not** the official
Cloudflare browser speed-test implementation. It warms up the connection,
measures median latency across five small HTTPS requests, then averages
throughput over three 10 MB downloads and three 2 MB uploads using total transfer
time. Results include HTTP overhead, so fast connections may be understated.
Latency is HTTP request/response time, not ICMP ping. VPNs, Wi-Fi, and competing
traffic affect results. Progress counts completed requests, not elapsed time;
each request has a 30-second total timeout. Failed transfers show an error,
not a completed result.

Speed-test regression tests use mock HTTP responses. To explicitly run a real
Cloudflare test (approximately 36 MB), use `bash test.sh --speedtest-live`.

### Network: Ping, Traceroute and Port Scan

Switch to **Network**, enter an IP address or hostname (for a CIDR, the
address before the slash is used), pick **Ping** or **Traceroute**, and press
Return or click **Start**. The button becomes **Stop** while it runs.

- **Ping:** choose a count (4–100) or **Continuous**. A live summary shows sent,
  received, loss, and min/avg/max round-trip time; stopping prints ping's
  final statistics.
- **Traceroute:** ICMP probes, one per hop with a 2-second wait, up to 15/30/64 hops.
  The main window shows a hop table (address, hostname, time); the menu bar box
  shows the raw output.
- **Resolve names** turns on reverse-DNS names (slower); off by default.
- **Copy Output** copies the raw text. The exact command run is shown underneath.

These run the system tools `/sbin/ping`, `/sbin/ping6`, `/usr/sbin/traceroute`,
and `/usr/sbin/traceroute6`, so no extra privileges are needed. IPv6 literals use
the IPv6 tools; hostnames are resolved over IPv4. Many networks drop ICMP, so
`*`/timeout hops and unanswered pings don't necessarily mean a host is down.

#### Port Scan (nmap)

> Only scan hosts and networks you own or have permission to scan.

**Port Scan** runs [nmap](https://nmap.org), which must be installed separately
(`brew install nmap` or the installer from nmap.org). The app looks for it in
`/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin` and `/usr/bin`.

- **Target:** an IP address, hostname, or CIDR range up to `/20` for IPv4 (4,096
  addresses) or `/120` for IPv6.
- **Ports:** Top 100 (default), Top 1,000, All 65,535, or **Custom** (for example
  `22,80,443,8000-8100`).
- **Service versions** (`-sV --version-light`) identifies the software on open ports.
- **Open only** (`--open`) hides closed and filtered ports.
- **Assume up** (`-Pn`) scans a single host even if it doesn't answer discovery
  probes. Ranges always use host discovery so empty addresses are skipped.

The main window shows a Host / Port / State / Service / Version table and the
scan's progress; the menu bar box shows nmap's raw output. Scans run without
root, so nmap uses TCP connect scans (`-sT`). SYN, UDP and OS detection scans
need root and aren't offered.

## Data sources

Owner lookups use public, unauthenticated HTTPS services. No API keys are needed.

1. The [IANA RDAP bootstrap registry](https://data.iana.org/rdap/) selects the
   authoritative regional registry (ARIN, RIPE NCC, APNIC, LACNIC, AFRINIC).
2. An RDAP IP query (RFC 9083) finds the network and its *registrant* entity.
3. The registrant's RDAP entity record supplies its other networks. For RIPE NCC,
   the RIPE Database inverse search is also used, because RIPE's RDAP lists only
   top-level networks.

Limitations:

- "Owned" means registered to the same registrant handle in the registry. It is
  not BGP routing data. Blocks a provider reassigned to a customer are listed under
  that customer, and an organization may hold resources under several handles.
- Registries can truncate very large lists; the app shows a note if they do.
- Some national registries (for example NIC.br) do not publish an owner's network
  list; the app reports this.
- Private and reserved ranges (for example `10.0.0.0/8`) have no registry owner.

## Build and test

Requires Xcode or the Xcode Command Line Tools.

### Xcode

Open [IP Toolkit.xcodeproj](./IP%20Toolkit.xcodeproj) in full Xcode, select the
**IP Toolkit** scheme and **My Mac**, then press **Run** (Command-R).
The project references the existing sources directly; no source export or copy
is needed. Debug builds target the current Mac; Release builds and
**Product > Archive** produce a universal Apple Silicon/Intel app for macOS 13+.

The project uses the existing Info.plist and generates the magnifying-glass/IP
icon with the same drawing code as the command-line build. Signing defaults to
local ad-hoc signing, with no Apple Developer account required. For Developer ID
distribution, configure your signing identity/team and notarization separately.
App Sandbox is off so the existing ping, traceroute and nmap subprocesses work.
Build-script sandboxing is off because icon generation invokes the Swift compiler
and reads the installed SDK.

You can also build from Terminal with full Xcode selected:

```sh
xcodebuild -project "IP Toolkit.xcodeproj" -scheme "IP Toolkit" \
  -configuration Release -derivedDataPath build/Xcode build
```

The app is then at `build/Xcode/Build/Products/Release/IP Toolkit.app`.
If `xcode-select -p` points to Command Line Tools instead of full Xcode, prefix
the command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
(adjust for your Xcode installation).

The existing tests remain a command-line harness, not an XCTest target; run
`bash test.sh` or `bash test.sh --live` from the project directory.

### Command-line scripts

The original build and test scripts remain available without full Xcode:

```sh
bash build.sh        # builds dist/IP Toolkit.app and a ZIP
bash test.sh         # offline unit tests + bundle checks
bash test.sh --live  # also queries live registries, geolocation, ping, traceroute and nmap (localhost)
```

Reputation tests use mocked HTTP responses with a dummy key; they do not need
an AbuseIPDB account or consume its quota.

The app is ad-hoc signed, which is suitable for local use. On another Mac,
Gatekeeper may require right-click → **Open** the first time.
