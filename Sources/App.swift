import AppKit
import MapKit
import SwiftUI

enum Settings {
    static let menuBarWhenMinimizedKey = "menuBarWhenMinimized"
    static let modeKey = "mode"
    static var menuBarWhenMinimized: Bool { UserDefaults.standard.bool(forKey: menuBarWhenMinimizedKey) }
}

enum AppMode: String, CaseIterable, Identifiable {
    case lookup, subnet, geolocate, network
    var id: Self { self }

    var title: String {
        switch self {
        case .lookup: return "Owner Lookup"
        case .subnet: return "Subnet Calculator"
        case .geolocate: return "Geolocate"
        case .network: return "Ping / Trace"
        }
    }
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

@MainActor
final class LookupModel: ObservableObject {
    @Published var query = ""
    @Published var splitPrefix = 0
    @Published private(set) var isLoading = false
    @Published private(set) var result: LookupResult?
    @Published private(set) var errorMessage: String?

    @Published private(set) var isLocating = false
    @Published private(set) var geoResult: GeoResult?
    @Published private(set) var geoError: String?

    @Published var netTool: NetTool = .ping
    @Published var netOptions = NetToolOptions()
    @Published private(set) var netLines: [String] = []
    @Published private(set) var netRunning = false
    @Published private(set) var netError: String?
    @Published private(set) var netCommandText: String?
    @Published private(set) var netRanTool: NetTool = .ping
    private var netRunner: NetCommandRunner?
    private var netRunID = 0
    private static let maxNetLines = 5000

    private let client = RDAPClient()
    private let geoClient = GeoClient()

    @Published private(set) var isFindingMyIP = false
    @Published private(set) var myIP: MyIPResult?
    @Published private(set) var myIPError: String?
    private let myIPClient = MyIPClient()
    private var myIPTask: Task<Void, Never>?
    private var task: Task<Void, Never>?
    private var geoTask: Task<Void, Never>?

    func run(_ mode: AppMode) {
        switch mode {
        case .lookup: lookup()
        case .geolocate: locate()
        case .network: startNetTool()
        case .subnet: break
        }
    }

    func isBusy(_ mode: AppMode) -> Bool {
        mode == .lookup ? isLoading : (mode == .geolocate ? isLocating : false)
    }

    /// Finds this Mac's public IP, puts it in the query field, and runs the current tool with it.
    /// Ping/traceroute is only filled in, not started, since probing your own address is rarely intended.
    func findMyIP(then mode: AppMode) {
        myIPTask?.cancel()
        isFindingMyIP = true
        myIPError = nil
        myIPTask = Task { [weak self] in
            guard let self else { return }
            do {
                let r = try await myIPClient.fetch()
                guard !Task.isCancelled else { return }
                myIP = r
                if let ip = r.preferred {
                    query = ip
                    if mode != .network { run(mode) }
                }
            } catch {
                guard !Task.isCancelled else { return }
                myIP = nil
                myIPError = error.localizedDescription
            }
            isFindingMyIP = false
        }
    }

    func dismissMyIP() {
        myIPTask?.cancel()
        isFindingMyIP = false
        myIP = nil
        myIPError = nil
    }

    var pingStats: PingStats { NetOutputParser.ping(netLines) }
    var traceHops: [TraceHop] { NetOutputParser.traceroute(netLines) }
    var netOutputText: String { netLines.joined(separator: "\n") }

    func toggleNetTool() {
        if netRunning { stopNetTool() } else { startNetTool() }
    }

    func startNetTool() {
        stopNetTool()
        netError = nil
        let target: NetTarget
        do { target = try NetTarget.parse(query) } catch {
            netError = error.localizedDescription
            return
        }
        let (exe, args) = NetCommand.build(netTool, target, netOptions)
        netRunID += 1
        let id = netRunID
        let runner = NetCommandRunner(executable: exe, arguments: args)
        netLines = []
        netRanTool = netTool
        netCommandText = ([exe.lastPathComponent] + args).joined(separator: " ")
        do {
            try runner.start(
                onLine: { [weak self] line in
                    Task { @MainActor in
                        guard let self, self.netRunID == id else { return }
                        self.netLines.append(line)
                        if self.netLines.count > Self.maxNetLines {
                            self.netLines.removeFirst(self.netLines.count - Self.maxNetLines)
                        }
                    }
                },
                onExit: { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.netRunID == id else { return }
                        self.netRunning = false
                        self.netRunner = nil
                    }
                })
            netRunner = runner
            netRunning = true
        } catch {
            netError = error.localizedDescription
        }
    }

    func stopNetTool() {
        netRunner?.stop()
    }

    func clearNetOutput() {
        guard !netRunning else { return }
        netLines = []
        netCommandText = nil
        netError = nil
    }

    func locate() {
        let input = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        geoTask?.cancel()
        isLocating = true
        geoError = nil
        geoTask = Task { [weak self] in
            guard let self else { return }
            do {
                let r = try await geoClient.locate(input)
                guard !Task.isCancelled else { return }
                geoResult = r
            } catch {
                guard !Task.isCancelled else { return }
                geoResult = nil
                geoError = error.localizedDescription
            }
            isLocating = false
        }
    }

    func lookup() {
        let input = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        task?.cancel()
        isLoading = true
        errorMessage = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let r = try await client.lookup(input)
                guard !Task.isCancelled else { return }
                result = r
            } catch {
                guard !Task.isCancelled else { return }
                result = nil
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    func copyCIDRs() {
        guard let result else { return }
        copyToPasteboard(result.cidrListText)
    }
}

// MARK: - Views

struct ModePicker: View {
    @Binding var mode: AppMode

    var body: some View {
        Picker("Mode", selection: $mode) {
            ForEach(AppMode.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

/// One input shared by all modes, so switching modes keeps what was typed.
struct QueryField: View {
    @ObservedObject var model: LookupModel
    let mode: AppMode
    var focusOnAppear = false
    @FocusState private var focused: Bool

    private var placeholder: String {
        switch mode {
        case .lookup: return "IP address or CIDR, e.g. 8.8.8.8 or 2001:db8::/32"
        case .subnet: return "e.g. 192.168.1.10/24, 10.0.0.1 255.255.255.0, 2001:db8::/48"
        case .geolocate: return "IP address, e.g. 8.8.8.8 or 2606:4700:4700::1111"
        case .network: return "IP address or hostname, e.g. 8.8.8.8 or apple.com"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            inputRow
            MyIPBanner(model: model)
        }
        .onAppear {
            if focusOnAppear { DispatchQueue.main.async { focused = true } }
        }
    }

    private var inputRow: some View {
        HStack {
            TextField(placeholder, text: $model.query)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .focused($focused)
                .onSubmit { model.run(mode) }
            if mode == .network {
                Button(model.netRunning ? "Stop" : "Start") { model.toggleNetTool() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.netRunning && model.query.trimmingCharacters(in: .whitespaces).isEmpty)
            } else if mode != .subnet {
                Button(mode == .lookup ? "Look Up" : "Locate") { model.run(mode) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy(mode) || model.query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Button { model.findMyIP(then: mode) } label: { Label("My IP", systemImage: "house") }
                .help("Fill in this Mac's public (internet) IP address")
                .disabled(model.isFindingMyIP || model.netRunning)
        }
    }
}

/// Shows this Mac's public addresses after "My IP" is used.
struct MyIPBanner: View {
    @ObservedObject var model: LookupModel

    var body: some View {
        if model.isFindingMyIP {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Finding your public IP address…").foregroundStyle(.secondary)
            }
            .font(.callout)
        } else if let error = model.myIPError {
            HStack(alignment: .firstTextBaseline) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                dismissButton
            }
            .font(.callout)
        } else if let ip = model.myIP {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "house").foregroundStyle(.secondary)
                Text("Your public IP:").foregroundStyle(.secondary)
                address("IPv4", ip.ipv4)
                address("IPv6", ip.ipv6)
                Spacer(minLength: 0)
                dismissButton
            }
            .font(.callout)
        }
    }

    @ViewBuilder private func address(_ label: String, _ value: String?) -> some View {
        if let value {
            HStack(spacing: 3) {
                Text(verbatim: value).font(.callout.monospaced()).textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
                Button { copyToPasteboard(value) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy \(label) address")
            }
        } else {
            Text("no \(label)").foregroundStyle(.tertiary)
        }
    }

    private var dismissButton: some View {
        Button { model.dismissMyIP() } label: { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Hide")
    }
}

struct StatusView: View {
    @ObservedObject var model: LookupModel

    var body: some View {
        if model.isLoading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Querying registry…").foregroundStyle(.secondary)
            }
        } else if let error = model.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct OwnerSummary: View {
    let result: LookupResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.ownerDisplayName).font(.title3.bold()).textSelection(.enabled)
            Group {
                if let handle = result.owner?.handle { Text("Owner handle: \(handle)") }
                Text("Registry: \(result.registry)")
                Text("\(result.query) is in \(networkText)")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            ForEach(result.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var networkText: String {
        let cidrs = result.network.cidrs.map(\.description).joined(separator: ", ")
        let label = [result.network.name, result.network.handle].compactMap { $0 }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: " / ")
        return label.isEmpty ? cidrs : "\(cidrs) (\(label))"
    }
}

struct OwnedListHeader: View {
    @ObservedObject var model: LookupModel
    let result: LookupResult

    var body: some View {
        HStack {
            Text("CIDRs owned by \(result.ownerDisplayName) (\(result.ownedNetworks.count))")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button { model.copyCIDRs() } label: { Label("Copy CIDRs", systemImage: "doc.on.doc") }
        }
    }
}

struct SubnetCalculatorView: View {
    @ObservedObject var model: LookupModel
    let compact: Bool

    private static let subnetLimit = 1024

    var body: some View {
        let text = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            placeholder("Enter an address with a prefix length or netmask, such as 192.168.1.10/24, 10.0.0.1 255.255.255.0, or 2001:db8::/48.")
        } else if let info = SubnetInfo(text) {
            if compact {
                details(info)
            } else {
                ScrollView { details(info).padding(.trailing, 12) }
            }
        } else {
            Label("“\(text)” is not a valid address, CIDR, or address with netmask.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            if !compact { Spacer() }
        }
    }

    @ViewBuilder private func placeholder(_ message: String) -> some View {
        if compact {
            Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            Spacer()
            Text(message).foregroundStyle(.secondary).frame(maxWidth: .infinity).multilineTextAlignment(.center)
            Spacer()
        }
    }

    private func details(_ info: SubnetInfo) -> some View {
        let options = info.splitOptions
        let effective = options?.contains(model.splitPrefix) == true ? model.splitPrefix : 0
        let selection = Binding(get: { effective }, set: { model.splitPrefix = $0 })
        let subnets = info.subnets(prefix: effective, limit: Self.subnetLimit)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(info.network.description).font(.title3.bold()).textSelection(.enabled)
                Spacer()
                Button { copyToPasteboard(info.summaryText) } label: { Label("Copy Details", systemImage: "doc.on.doc") }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: compact ? 3 : 5) {
                ForEach(info.rows) { row in
                    GridRow {
                        Text(row.label).foregroundStyle(.secondary)
                        Text(row.value).font(.system(compact ? .callout : .body, design: .monospaced)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .font(compact ? .callout : .body)

            if let options {
                Divider()
                HStack {
                    Picker("Split into", selection: selection) {
                        Text("—").tag(0)
                        ForEach(Array(options), id: \.self) { p in
                            Text("/\(p)  (\(NumberText.shortPowerOfTwo(p - info.prefixLength)) subnets)").tag(p)
                        }
                    }
                    .fixedSize()
                    Spacer()
                    if effective > 0 {
                        Button { copyToPasteboard(subnets.map(\.description).joined(separator: "\n")) } label: {
                            Label("Copy Subnets", systemImage: "doc.on.doc")
                        }
                    }
                }
                if effective > 0 {
                    let total = effective - info.prefixLength
                    if total > 10 {
                        Text("Showing the first \(subnets.count) of \(NumberText.powerOfTwo(total)) subnets.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    subnetList(subnets)
                }
            }
        }
    }

    @ViewBuilder private func subnetList(_ subnets: [CIDR]) -> some View {
        let rows = LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(subnets, id: \.self) { subnet in
                HStack {
                    Text(subnet.description)
                    Spacer()
                    Text(verbatim: "\(subnet.address) – \(subnet.lastAddress)").foregroundStyle(.secondary)
                }
                .font(.system(compact ? .callout : .body, design: .monospaced))
                .lineLimit(1)
                .textSelection(.enabled)
            }
        }
        if compact {
            ScrollView { rows.padding(.trailing, 12) }
                .frame(height: min(CGFloat(subnets.count) * 20 + 4, 180))
        } else {
            rows
        }
    }
}

struct GeolocateView: View {
    @ObservedObject var model: LookupModel
    let compact: Bool

    var body: some View {
        if model.isLocating {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Locating…").foregroundStyle(.secondary)
            }
        } else if let error = model.geoError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let geo = model.geoResult {
            if !compact { Divider() }
            details(geo)
        } else if !compact {
            Spacer()
            Text("Enter a public IPv4 or IPv6 address to estimate its geographic location.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    private func details(_ geo: GeoResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(geo.placeText).font(.title3.bold()).textSelection(.enabled)
                Spacer()
                if let url = geo.mapsURL {
                    Button { NSWorkspace.shared.open(url) } label: { Label("Open in Maps", systemImage: "map") }
                }
                Button { copyToPasteboard(geo.summaryText) } label: { Label("Copy", systemImage: "doc.on.doc") }
            }
            if geo.anycast {
                Label("Anycast address: the same IP is served from many locations, so this is only one of them.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if compact {
                rowsGrid(geo)
                if let lat = geo.latitude, let lon = geo.longitude {
                    MapPinView(latitude: lat, longitude: lon, title: geo.placeText).frame(height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    rowsGrid(geo).frame(minWidth: 260, alignment: .topLeading)
                    if let lat = geo.latitude, let lon = geo.longitude {
                        MapPinView(latitude: lat, longitude: lon, title: geo.placeText)
                            .frame(minHeight: 260)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            Text("Location is estimated by \(geo.provider) and is often only accurate to the city or region.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func rowsGrid(_ geo: GeoResult) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: compact ? 3 : 5) {
            ForEach(geo.rows) { row in
                GridRow {
                    Text(row.label).foregroundStyle(.secondary)
                    Text(row.value).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(compact ? .callout : .body)
    }
}

/// MapKit map centered on a single pin.
struct MapPinView: NSViewRepresentable {
    let latitude: Double
    let longitude: Double
    let title: String

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.showsZoomControls = true
        update(map)
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        let current = map.annotations.first?.coordinate
        if current?.latitude != latitude || current?.longitude != longitude { update(map) }
    }

    private func update(_ map: MKMapView) {
        map.removeAnnotations(map.annotations)
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let pin = MKPointAnnotation()
        pin.coordinate = coordinate
        pin.title = title
        map.addAnnotation(pin)
        map.setRegion(MKCoordinateRegion(center: coordinate, latitudinalMeters: 60_000, longitudinalMeters: 60_000),
                      animated: false)
    }
}

struct NetToolView: View {
    @ObservedObject var model: LookupModel
    let compact: Bool

    private static let pingCounts = [4, 5, 10, 20, 50, 100, 0]
    private static let hopLimits = [15, 30, 64]

    var body: some View {
        controls
        status
        if !model.netLines.isEmpty {
            if !compact { Divider() }
            results
        } else if !compact {
            Spacer()
            Text("Enter an IP address or hostname, choose Ping or Traceroute, and press Start.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Tool", selection: $model.netTool) {
                ForEach(NetTool.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if model.netTool == .ping {
                Picker("Count", selection: $model.netOptions.pingCount) {
                    ForEach(Self.pingCounts, id: \.self) { Text($0 == 0 ? "Continuous" : "\($0)").tag($0) }
                }
                .fixedSize()
            } else {
                Picker("Max hops", selection: $model.netOptions.maxHops) {
                    ForEach(Self.hopLimits, id: \.self) { Text("\($0)").tag($0) }
                }
                .fixedSize()
            }
            Toggle("Resolve names", isOn: $model.netOptions.resolveNames)
                .toggleStyle(.checkbox)
            Spacer(minLength: 0)
        }
        .controlSize(compact ? .small : .regular)
        .disabled(model.netRunning)
    }

    @ViewBuilder private var status: some View {
        if let error = model.netError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.netRunning {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(model.netRanTool == .ping && model.netOptions.pingCount == 0
                     ? "Pinging continuously; press Stop to finish…" : "Running \(model.netRanTool.title.lowercased())…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var results: some View {
        HStack(alignment: .firstTextBaseline) {
            summary
            Spacer()
            Button { copyToPasteboard(model.netOutputText) } label: { Label("Copy Output", systemImage: "doc.on.doc") }
            Button("Clear") { model.clearNetOutput() }.disabled(model.netRunning)
        }
        .controlSize(compact ? .small : .regular)
        if model.netRanTool == .traceroute && !compact {
            Table(model.traceHops) {
                TableColumn("Hop") { Text("\($0.number)").monospacedDigit() }.width(40)
                TableColumn("Address") { hop in
                    Text(hop.address ?? "*").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                .width(min: 120, ideal: 200)
                TableColumn("Hostname") { Text($0.hostname ?? "") }
                TableColumn("Time") { hop in
                    Text(hop.times.isEmpty ? "timeout" : hop.times.map { String(format: "%.1f ms", $0) }.joined(separator: ", "))
                        .foregroundStyle(hop.times.isEmpty ? .secondary : .primary)
                }
                .width(min: 80, ideal: 110)
            }
            .frame(minHeight: 200)
        } else {
            output
        }
        if let cmd = model.netCommandText {
            Text(verbatim: "$ " + cmd).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    @ViewBuilder private var summary: some View {
        if model.netRanTool == .ping {
            let stats = model.pingStats
            Text(verbatim: stats.summaryText)
                .font(compact ? .callout.bold() : .headline)
                .foregroundStyle(stats.transmitted > 0 && stats.received == 0 ? .red : .primary)
        } else {
            let hops = model.traceHops
            let reached = model.netRunning ? "" : hops.last.map {
                $0.times.isEmpty ? "destination did not reply" : "reached \($0.hostname ?? $0.address ?? "")"
            } ?? ""
            Text(verbatim: "\(hops.count) hop\(hops.count == 1 ? "" : "s")\(reached.isEmpty ? "" : " · " + reached)")
                .font(compact ? .callout.bold() : .headline)
        }
    }

    private var output: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(verbatim: model.netOutputText)
                    .font(.system(compact ? .caption : .callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                Color.clear.frame(height: 1).id("end")
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            .frame(height: compact ? 220 : nil)
            .frame(minHeight: compact ? nil : 200)
            .onChange(of: model.netLines.count) { _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

struct MainView: View {
    @ObservedObject var model: LookupModel
    @AppStorage(Settings.menuBarWhenMinimizedKey) private var menuBarWhenMinimized = true
    @AppStorage(Settings.modeKey) private var mode: AppMode = .lookup

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ModePicker(mode: $mode)
            QueryField(model: model, mode: mode, focusOnAppear: true)
            Toggle("Show as menu bar icon when minimized", isOn: $menuBarWhenMinimized)
                .toggleStyle(.checkbox)
            if mode == .subnet {
                Divider()
                SubnetCalculatorView(model: model, compact: false)
            } else if mode == .geolocate {
                GeolocateView(model: model, compact: false)
            } else if mode == .network {
                NetToolView(model: model, compact: false)
            } else {
                lookupContent
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 420)
    }

    @ViewBuilder private var lookupContent: some View {
        StatusView(model: model)
        if let result = model.result {
            Divider()
            OwnerSummary(result: result)
            OwnedListHeader(model: model, result: result)
            Table(result.ownedNetworks) {
                TableColumn("CIDR") { Text($0.cidrText).font(.system(.body, design: .monospaced)) }
                    .width(min: 160, ideal: 220)
                TableColumn("Network Name") { Text($0.networkName ?? "") }
                TableColumn("Handle") { Text($0.handle ?? "") }
            }
        } else {
            Spacer()
            Text("Enter an IPv4/IPv6 address or CIDR to find its registered owner and every network block registered to that owner.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }
}

struct PopoverView: View {
    @ObservedObject var model: LookupModel
    @AppStorage(Settings.modeKey) private var mode: AppMode = .lookup
    let openWindow: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModePicker(mode: $mode).controlSize(.small)
            QueryField(model: model, mode: mode, focusOnAppear: true)
            if mode == .subnet {
                SubnetCalculatorView(model: model, compact: true)
            } else if mode == .geolocate {
                GeolocateView(model: model, compact: true)
            } else if mode == .network {
                NetToolView(model: model, compact: true)
            } else {
                StatusView(model: model)
                if let result = model.result {
                    OwnerSummary(result: result)
                    OwnedListHeader(model: model, result: result)
                    List(result.ownedNetworks) { row in
                        HStack {
                            Text(row.cidrText).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            Spacer()
                            Text(row.networkName ?? "").foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(height: min(CGFloat(result.ownedNetworks.count) * 24 + 12, 260))
                }
            }
            HStack {
                Button("Open Window", action: openWindow)
                Spacer()
                Button("Quit", action: quit)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 480)
    }
}

// MARK: - AppKit shell

/// Window whose minimize button hides it to the menu bar when that option is enabled.
final class MainWindow: NSWindow {
    var hideToMenuBar: (() -> Void)?

    override func miniaturize(_ sender: Any?) {
        if Settings.menuBarWhenMinimized, let hideToMenuBar {
            hideToMenuBar()
        } else {
            super.miniaturize(sender)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = LookupModel()
    private var window: MainWindow!
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private static let statusItemName = "IPToolkitStatusItem"

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [Settings.menuBarWhenMinimizedKey: true])
        NSApp.mainMenu = buildMainMenu()

        window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable],
                            backing: .buffered, defer: false)
        window.title = "IP Toolkit"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: MainView(model: model))
        window.setContentSize(NSSize(width: 680, height: 560))
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.hideToMenuBar = { [weak self] in self?.enterMenuBarMode() }

        popover.behavior = .transient
        popover.animates = true

        window.makeKeyAndOrderFront(nil)
        activate()
    }

    /// Closing the window quits, but hiding it to the menu bar must not: AppKit treats ordering out
    /// the last visible window like closing it and would otherwise terminate the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { statusItem == nil }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopNetTool()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    // MARK: Menu bar mode

    private func enterMenuBarMode() {
        if statusItem == nil {
            // New status items are inserted at the left end, which on a crowded or notched menu bar is
            // hidden behind the notch or the active app's menus. Ask for the right end instead, unless
            // the user has already ⌘-dragged the icon somewhere (macOS then stores its own position).
            let positionKey = "NSStatusItem Preferred Position \(Self.statusItemName)"
            if UserDefaults.standard.double(forKey: positionKey) <= 0 {
                UserDefaults.standard.set(1.0, forKey: positionKey)
            }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.autosaveName = Self.statusItemName
            if !item.isVisible { item.isVisible = true }
            item.button?.image = IPIcon.menuBarImage()
            item.button?.toolTip = "IP Toolkit"
            item.button?.target = self
            item.button?.action = #selector(statusItemClicked(_:))
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            statusItem = item
        }
        window.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func showMainWindow() {
        popover.performClose(nil)
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        NSApp.setActivationPolicy(.regular)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        activate()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            let menu = NSMenu()
            menu.addItem(withTitle: "Open IP Toolkit", action: #selector(showMainWindow), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
            return
        }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // A fresh hosting controller each time so the text field receives focus on every open.
        let host = NSHostingController(rootView: PopoverView(
            model: model,
            openWindow: { [weak self] in self?.showMainWindow() },
            quit: { NSApp.terminate(nil) }))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        activate()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func activate() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: Main menu (needed for Cmd-C/V/X/A and Cmd-M in a programmatic app)

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About IP Toolkit",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide IP Toolkit", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit IP Toolkit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = appMenu

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        return main
    }
}
