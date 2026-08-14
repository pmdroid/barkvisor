import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var sharePayload: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField("Device URL", text: $model.serverURLText)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    #endif
                Text("Default port is 7777. Sign out and reconnect after changing the URL.")
                    .foregroundStyle(.secondary)
                Button("Disconnect") { model.disconnect() }
                Button("Logout", role: .destructive) { model.logout() }
            } header: {
                Text("Connection")
            }

            Section {
                Text("Issue a pairing code on this \(Copy.home). The joining \(Copy.device.lowercased()) finishes setup in the web UI.")
                    .foregroundStyle(.secondary)
                if let pairing = model.pairing {
                    LabeledContent("Code") {
                        Text(pairing.code)
                            .font(.title2.monospaced().weight(.bold))
                            .textSelection(.enabled)
                    }
                    LabeledContent("Expires", value: expiry(pairing))
                    Text(pairing.qrPayload)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                    Button("Copy payload") { copy(pairing.qrPayload) }
                    #if os(iOS)
                    Button("Share") { sharePayload = pairing.qrPayload }
                    #endif
                    Button("Revoke", role: .destructive) {
                        Task { await model.revokePairing() }
                    }
                } else {
                    Button("Create pairing code") {
                        Task { await model.issuePairing() }
                    }
                    .bvProminentButton()
                }
            } header: {
                Text("Add a \(Copy.device)")
            }

            Section {
                LabeledContent("Console", value: "BarkVisor native console")
                if let about = model.about {
                    LabeledContent("Device version", value: about.version)
                    LabeledContent("Platform", value: "\(about.platform) · \(about.hostArch)")
                    LabeledContent("Accelerator", value: about.accelerator)
                    LabeledContent("Uptime", value: "\(about.processUptimeSeconds)s")
                } else {
                    Text("Could not load /api/system/about.")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Glossary", value: "Home / Device / Workload / Library")
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
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
