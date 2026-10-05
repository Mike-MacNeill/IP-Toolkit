import AppKit
import ServiceManagement
import SwiftUI

/// "Open at login" backed by SMAppService, so the state always reflects System Settings → General → Login Items.
@MainActor
final class LaunchAtLogin: ObservableObject {
    static let shared = LaunchAtLogin()

    @Published private(set) var isEnabled = false
    /// The user must approve the item in System Settings before it takes effect.
    @Published private(set) var needsApproval = false
    @Published private(set) var errorMessage: String?

    private init() {
        refresh()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LaunchAtLogin.shared.refresh() }
        }
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = "Could not \(enabled ? "turn on" : "turn off") Open at Login: \(error.localizedDescription)"
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// True when macOS started the app as a login item rather than the user opening it.
    static var launchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
    }
}

struct LaunchAtLoginToggle: View {
    @ObservedObject private var login = LaunchAtLogin.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Open at login", isOn: Binding(get: { login.isEnabled }, set: { login.setEnabled($0) }))
                .toggleStyle(.checkbox)
            if login.needsApproval {
                HStack(spacing: 6) {
                    Label("Allow IP Toolkit in Login Items to finish turning this on.", systemImage: "info.circle")
                        .foregroundStyle(.orange)
                    Button("Open Login Items…") { login.openLoginItemsSettings() }
                        .buttonStyle(.link)
                }
                .font(.caption)
            }
            if let error = login.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
