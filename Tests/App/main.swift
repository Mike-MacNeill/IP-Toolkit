import AppKit
import SwiftUI

var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(message)")
    }
}

final class LookupMockProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let scenario = request.value(forHTTPHeaderField: "X-Test-Scenario") ?? ""
        let geo = ["ipinfo.io", "ipwho.is"].contains(url.host ?? "")
        let fails = geo ? scenario == "geo-fails" : scenario == "owner-fails"
        let body: String
        if geo {
            body = #"{"ip":"8.8.8.8","city":"Example City","region":"Example Region","country":"US","loc":"38.0,-122.0","org":"AS15169 Example ISP"}"#
        } else if url.host == "data.iana.org" {
            body = #"{"services":[[["0.0.0.0/0"],["https://rdap.example/"]]]}"#
        } else if url.path.hasPrefix("/entity/") {
            body = #"{"networks":[{"startAddress":"8.8.8.0","endAddress":"8.8.8.255","ipVersion":"v4","name":"EXAMPLE"}]}"#
        } else {
            body = #"{"startAddress":"8.8.8.0","endAddress":"8.8.8.255","ipVersion":"v4","name":"EXAMPLE","entities":[{"handle":"EXAMPLE-ORG","roles":["registrant"],"vcardArray":["vcard",[["fn",{},"text","Example Owner"]]]}]}"#
        }
        let response = HTTPURLResponse(url: url, statusCode: fails ? 503 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
func waitForLookup(_ model: LookupModel) async {
    for _ in 0..<500 {
        if !model.isBusy(.lookup) { return }
        do { try await Task.sleep(nanoseconds: 10_000_000) }
        catch {
            check(false, "Waiting for lookup was cancelled")
            return
        }
    }
    check(false, "Combined lookup completes within five seconds")
}

@MainActor
func snapshot<V: View>(_ view: V, width: CGFloat, name: String) {
    let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
    host.frame = NSRect(x: 0, y: 0, width: width, height: 650)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    window.orderFront(nil)
    host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        check(false, "Snapshot bitmap available")
        return
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    do {
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            check(false, "Snapshot PNG available")
            return
        }
        try data.write(to: URL(fileURLWithPath: "build/\(name).png"))
    } catch {
        check(false, "Saving snapshot: \(error.localizedDescription)")
    }
    window.orderOut(nil)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.appearance = NSAppearance(named: .aqua)
Task { @MainActor in
    check(AppMode.allCases.map(\.rawValue) == ["lookup", "subnet", "reputation", "network", "speedtest"],
          "Separate geolocation tab replaced with reputation")
    let suiteName = "IPToolkit.AppTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set("geolocate", forKey: Settings.modeKey)
    Settings.migrateMode(defaults: defaults)
    check(defaults.string(forKey: Settings.modeKey) == "lookup", "Saved geolocation mode migrates to combined lookup")
    defaults.set("network", forKey: Settings.modeKey)
    Settings.migrateMode(defaults: defaults)
    check(defaults.string(forKey: Settings.modeKey) == "network", "Migration preserves other saved modes")
    defaults.removePersistentDomain(forName: suiteName)
    for scenario in ["success", "owner-fails", "geo-fails"] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LookupMockProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Test-Scenario": scenario]
        let session = URLSession(configuration: configuration)
        let model = LookupModel(client: RDAPClient(session: session), geoClient: GeoClient(session: session))
        model.query = "8.8.8.8"
        model.run(.lookup)
        check(model.isLoading && model.isLocating, "Combined lookup starts both requests")
        await waitForLookup(model)
        check((model.result != nil) == (scenario != "owner-fails"), "Owner results independent: \(scenario)")
        check((model.geoResult != nil) == (scenario != "geo-fails"), "Geo results independent: \(scenario)")
        check((model.errorMessage != nil) == (scenario == "owner-fails"), "Owner errors explicit: \(scenario)")
        check((model.geoError != nil) == (scenario == "geo-fails"), "Geo errors explicit: \(scenario)")
        if scenario == "success" {
            check(model.result?.ownerDisplayName == "Example Owner", "Combined owner preserved")
            check(model.result?.ownedNetworks.count == 1, "Combined CIDR list preserved")
            check(model.geoResult?.city == "Example City", "Combined geolocation preserved")
            if CommandLine.arguments.contains("--snapshots") {
                snapshot(CombinedLookupView(model: model, compact: false), width: 680, name: "combined-window")
                snapshot(CombinedLookupView(model: model, compact: true), width: 452, name: "combined-popover")
            }
        }
        model.query = "invalid"
        model.run(.lookup)
        check(model.result == nil && model.geoResult == nil, "Old owner and geolocation cleared immediately")
        await waitForLookup(model)
        check(model.errorMessage != nil && model.geoError != nil, "Both input errors displayed")
        model.query = ""
        model.run(.lookup)
        await waitForLookup(model)
        check(model.errorMessage != nil && model.geoError != nil, "Empty input errors displayed")
        session.invalidateAndCancel()
    }
    let subnetModel = LookupModel()
    subnetModel.query = "192.168.1.200/24"
    subnetModel.splitPrefix = 28
    subnetModel.subnetMaskInput = "255.255.255.192"
    subnetModel.applySubnetNotation(subnetModel.subnetMaskInput)
    check(subnetModel.query == "192.168.1.200/26", "Mask control updates CIDR and preserves address")
    check(subnetModel.splitPrefix == 0 && subnetModel.subnetMaskInput.isEmpty && subnetModel.subnetMaskError == nil,
          "Successful recalculation clears draft, error and prior split")
    subnetModel.applySubnetNotation("255.0.255.0")
    check(subnetModel.query == "192.168.1.200/26" && subnetModel.subnetMaskError != nil,
          "Invalid mask shows error without changing result")
    subnetModel.applySubnetNotation("/16")
    check(subnetModel.query == "192.168.1.200/16" && subnetModel.subnetMaskError == nil, "CIDR control recalculates and clears error")
    subnetModel.query = "invalid"
    subnetModel.applySubnetNotation("/24")
    check(subnetModel.subnetMaskError != nil && subnetModel.query == "invalid", "Recalculation requires valid input address")
    subnetModel.query = "2001:db8:abcd:1234::99/48"
    subnetModel.applySubnetNotation("/64")
    check(subnetModel.query == "2001:db8:abcd:1234::99/64", "IPv6 CIDR control")
    if CommandLine.arguments.contains("--snapshots") {
        snapshot(SubnetCalculatorView(model: subnetModel, compact: false), width: 680, name: "subnet-window")
        subnetModel.query = "192.168.1.200/26"
        snapshot(SubnetCalculatorView(model: subnetModel, compact: true), width: 452, name: "subnet-popover")
    }
    let model = LookupModel()
    model.run(.speedtest)
    check(model.speedRunning, "Speed tab starts without an IP")
    model.stopSpeedTest()
    check(!model.speedRunning && model.speedProgress.phase == "Stopped" && model.speedResult == nil,
          "Stopping speed test clears running state without a success result")
    await Task.yield()
    check(model.speedError == nil && model.speedResult == nil, "Cancelled speed test has no late error or result")
    model.query = "10.0.0.1"
    model.run(.reputation)
    check(model.reputationError != nil && !model.isCheckingReputation, "Non-public reputation input rejected before Keychain/network")
    model.reputationKeyInput = "invalid key"
    model.saveReputationKey()
    check(model.reputationKeyError != nil && model.reputationKeyStatus == nil, "Invalid API key surfaced without saving")
    model.reputationKeyInput = ""
    if CommandLine.arguments.contains("--snapshots") {
        snapshot(SpeedTestView(model: model, compact: false), width: 680, name: "speed-window")
        snapshot(SpeedTestView(model: model, compact: true), width: 452, name: "speed-popover")
        snapshot(VStack {
            ModePicker(mode: .constant(.speedtest), compact: true).controlSize(.small)
            SpeedTestView(model: model, compact: true)
        }.padding(14), width: 480, name: "speed-tabs")
        snapshot(ReputationView(model: model, compact: false), width: 680, name: "reputation-window")
        snapshot(ReputationView(model: model, compact: true), width: 452, name: "reputation-popover")
    }
    print(failures == 0 ? "PASS: app model and combined lookup tests" : "\(failures) app test(s) failed")
    exit(failures == 0 ? 0 : 1)
}
app.run()
