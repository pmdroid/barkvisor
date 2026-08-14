import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var sharePayload: String?
    #if os(macOS)
    @State private var copied = false
    #endif

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Settings", subtitle: "This console talks to one Device URL at a time.") { EmptyView() }

            section("Connection") {
                VStack(alignment: .leading, spacing: 10) {
                    FieldLabel(text: "Device URL")
                    TextField("http://host:7777", text: $model.serverURLText)
                        .textFieldStyle(.plain)
                        .font(BVTheme.font(13))
                        .bvField()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        #endif
                    Text("Default port is 7777. Sign out and reconnect after changing the URL.")
                        .font(BVTheme.font(12))
                        .foregroundStyle(BVTheme.textDim)
                    HStack {
                        Button("Disconnect") { model.disconnect() }
                            .buttonStyle(BVButtonStyle(kind: .ghost))
                        Button("Logout") { model.logout() }
                            .buttonStyle(BVButtonStyle(kind: .danger))
                    }
                }
            }

            section("Add a \(Copy.device)") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Issue a pairing code on this \(Copy.home). The joining \(Copy.device.lowercased()) finishes setup in the web UI.")
                        .font(BVTheme.font(13))
                        .foregroundStyle(BVTheme.textSecondary)
                    if let pairing = model.pairing {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(pairing.code)
                                .font(.system(size: 28, weight: .bold, design: .monospaced))
                                .foregroundStyle(BVTheme.text)
                            Text(expiry(pairing))
                                .font(BVTheme.font(12))
                                .foregroundStyle(BVTheme.textDim)
                            Text(pairing.qrPayload)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(BVTheme.textSecondary)
                                .textSelection(.enabled)
                            HStack {
                                Button("Copy payload") { copy(pairing.qrPayload) }
                                    .buttonStyle(BVButtonStyle(kind: .ghost))
                                #if os(iOS)
                                Button("Share") { sharePayload = pairing.qrPayload }
                                    .buttonStyle(BVButtonStyle(kind: .ghost))
                                #endif
                                Button("Revoke") {
                                    Task { await model.revokePairing() }
                                }
                                .buttonStyle(BVButtonStyle(kind: .warning))
                            }
                        }
                    } else {
                        Button("Create pairing code") {
                            Task { await model.issuePairing() }
                        }
                        .buttonStyle(BVButtonStyle(kind: .primary))
                    }
                }
            }

            section("About") {
                VStack(alignment: .leading, spacing: 8) {
                    aboutRow("Console", "BarkVisor native console")
                    if let about = model.about {
                        aboutRow("Device version", about.version)
                        aboutRow("Platform", "\(about.platform) · \(about.hostArch)")
                        aboutRow("Accelerator", about.accelerator)
                        aboutRow("Uptime", "\(about.processUptimeSeconds)s")
                    } else {
                        Text("Could not load /api/system/about.")
                            .font(BVTheme.font(13))
                            .foregroundStyle(BVTheme.textDim)
                    }
                    aboutRow("Glossary", "Home / Device / Workload / Library")
                }
            }
        }
        .task {
            await model.loadPairing()
        }
        #if os(iOS)
        .sheet(item: Binding(
            get: { sharePayload.map(IdentifiedString.init) },
            set: { sharePayload = $0?.value }
        )) { item in
            ShareSheet(items: [item.value])
        }
        #endif
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(BVTheme.font(16, weight: .semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .bvCard()
    }

    private func aboutRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
                .font(BVTheme.font(13))
                .foregroundStyle(BVTheme.textDim)
            Spacer()
            Text(value)
                .font(BVTheme.font(13, weight: .medium))
                .foregroundStyle(BVTheme.text)
        }
    }

    private func expiry(_ offer: PairingIssue) -> String {
        let seconds = max(0, offer.ttlSeconds)
        if seconds == 0 { return "Expired" }
        let minutes = Int(ceil(Double(seconds) / 60))
        return minutes == 1 ? "Expires in 1 minute" : "Expires in \(minutes) minutes"
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

private struct IdentifiedString: Identifiable {
    var id: String { value }
    var value: String
}
