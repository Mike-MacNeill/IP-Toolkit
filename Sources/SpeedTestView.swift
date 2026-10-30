import SwiftUI

struct SpeedTestView: View {
    @ObservedObject var model: LookupModel
    let compact: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Internet Speed Test").font(.title2.bold())
                Text("Tests this Mac's current internet connection to Cloudflare. No IP address or extra installation is needed.")
                    .foregroundStyle(.secondary)
                Label("Uses approximately 36 MB of test data plus protocol overhead per completed test. Avoid on metered connections.",
                      systemImage: "info.circle")
                    .font(.callout)
                HStack {
                    Button(model.speedRunning ? "Stop" : "Start Speed Test") {
                        if model.speedRunning { model.stopSpeedTest() } else { model.startSpeedTest() }
                    }
                    .keyboardShortcut(.defaultAction)
                    if let result = model.speedResult {
                        Button { copyToPasteboard(result.summaryText) } label: {
                            Label("Copy Results", systemImage: "doc.on.doc")
                        }
                    }
                    Spacer()
                }
                if model.speedRunning {
                    ProgressView(value: model.speedProgress.fraction)
                    Text(model.speedProgress.phase).foregroundStyle(.secondary)
                } else if model.speedProgress.phase == "Stopped" {
                    Text("Test stopped. No completed result.").foregroundStyle(.secondary)
                }
                if let error = model.speedError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).textSelection(.enabled)
                }
                if let result = model.speedResult {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                        metric("Download", String(format: "%.2f Mbps", result.downloadMbps))
                        metric("Upload", String(format: "%.2f Mbps", result.uploadMbps))
                        metric("HTTP latency", String(format: "%.1f ms", result.latencyMS))
                    }
                    Text("Completed \(result.completedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Text("Source: speed.cloudflare.com. Cloudflare sees your public IP and test traffic. This is a lightweight, single-connection HTTPS estimate, not the official Cloudflare browser test. Results include request overhead and may understate fast connections. VPNs, Wi-Fi, and other traffic affect results.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Latency is the median of five small HTTPS requests after warmup. Download and upload use three fixed-size transfers each. Progress tracks completed requests, not elapsed time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 8)
        }
        .frame(maxHeight: compact ? 460 : .infinity)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().bold()).textSelection(.enabled)
        }
    }
}
