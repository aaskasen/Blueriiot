import SwiftUI

struct SettingsView: View {
    let controller: RefreshController
    @State private var openAtLogin = LoginItem.isEnabled
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section("Account") {
                if controller.hasCredentials {
                    LabeledContent("BlueRiiot", value: "Signed in")
                    Button("Sign out", role: .destructive) { controller.signOut() }
                } else {
                    Text("Not signed in. Use the main window to connect.").foregroundStyle(.secondary)
                }
            }
            Section("Background refresh") {
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in
                        do { try LoginItem.set(on); loginItemError = nil }
                        catch { loginItemError = error.localizedDescription; openAtLogin = LoginItem.isEnabled }
                    }
                if let e = loginItemError { Text(e).font(.caption).foregroundStyle(PoolPalette.attention) }
                Text("While running, Pool Monitor refreshes every 30 minutes from the menu bar. macOS decides when desktop widgets redraw; the sensor measures about every 72 minutes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
