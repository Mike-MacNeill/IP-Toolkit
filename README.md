# IP Toolkit for macOS

A native macOS 13+ app (Apple Silicon and Intel) with four tools for an IPv4/IPv6
address or CIDR:

- **Owner Lookup:** shows who it is registered to and lists every CIDR block
  registered to that same owner.
- **Subnet Calculator:** offline subnet math and splitting.
- **Geolocate:** estimates the address's physical location and shows it on a map.
- **Ping / Trace:** runs ping or traceroute against an address or hostname with live output.

## Use

Open `dist/IP Toolkit.app` (copy it to Applications if desired). Enter an
address such as `8.8.8.8`, `2001:4860:4860::8888`, or a CIDR such as
`193.0.0.0/21`, then press Return or click **Look Up**.

The window shows:

- The owner (registrant organization), its registry handle, and the registry.
- The network block that contains your input.
- A table of every CIDR registered to that owner, with network names and handles.
  **Copy CIDRs** puts the list on the clipboard, one per line.

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
current tool, so you can see your own owner, subnet, or location in one click.
Ping / Trace is only filled in, not started. Your public IPv4 and IPv6
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

### Geolocate

Switch to **Geolocate**, enter a public IPv4 or IPv6 address (a CIDR is located
by its network address), and press Return or click **Locate**. The result shows
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
- Private, loopback, link-local, documentation, and other non-public addresses
  are rejected locally without contacting any service.

### Ping / Trace

Switch to **Ping / Trace**, enter an IP address or hostname (for a CIDR, the
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

```sh
bash build.sh        # builds dist/IP Toolkit.app and a ZIP
bash test.sh         # offline unit tests + bundle checks
bash test.sh --live  # also queries live registries, geolocation, ping and traceroute
```

The app is ad-hoc signed, which is suitable for local use. On another Mac,
Gatekeeper may require right-click → **Open** the first time.
