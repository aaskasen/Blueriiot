import ServiceManagement
import SwiftUI

@main
struct PoolMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var controller = RefreshController.shared
    @State private var selectedMetric: Metric?

    init() {
        // Development aid: `PoolMonitor --render-previews <dir>` writes PNGs of every widget size/state.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-previews"), i + 1 < args.count {
            PreviewRenderer.renderAll(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
    }

    var body: some Scene {
        Window("Pool Monitor", id: "main") {
            ContentView(controller: controller, selectedMetric: $selectedMetric)
                .task { await controller.refreshIfStale() }
                .onOpenURL { url in
                    // poolmonitor://pool  |  poolmonitor://metric/<temperature|ph|orp|conductivity>
                    selectedMetric = url.host == "metric" ? Metric(rawValue: url.lastPathComponent) : nil
                }
        }
        .defaultSize(width: 944, height: 636)  // snug around the 2×2 card grid

        Settings {
            SettingsView(controller: controller)
        }

        MenuBarExtra("Pool", systemImage: "drop.halffull") {
            MenuBarContent(controller: controller)
        }
    }
}

struct MenuBarContent: View {
    let controller: RefreshController
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let s = controller.snapshot
        Text("\(s.poolName): \(Metric.temperature.format(s.temperatureC))°C · pH \(Metric.ph.format(s.ph))")
        Text(s.footerText(now: .now))
        Divider()
        Button(controller.isRefreshing ? "Refreshing…" : "Refresh now") { Task { await controller.refresh() } }
            .disabled(controller.isRefreshing)
        Button("Open Pool Monitor") { openWindow(id: "main"); NSApp.activate() }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }
}

/// "Open at login" is opt-in; the app then keeps refreshing from the menu bar.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// Starts background refreshing at launch, independent of any window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !CommandLine.arguments.contains("--render-previews") else { return }
        MainActor.assumeIsolated { RefreshController.shared.start() }
    }
}
