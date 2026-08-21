import SwiftUI
#if os(macOS)
    import AppKit
#endif

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var urlDraft = ""

    var body: some View {
        Form {
            Section {
                TextField("Device URL", text: $urlDraft)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                #endif
                    .onSubmit { applyURL() }
                Text("Include http:// or https://. Default port is 7777. Changing origin signs you out.")
                    .foregroundStyle(.secondary)
                Button("Disconnect") { applyThen { model.disconnect() } }
                Button("Logout", role: .destructive) { applyThen { model.logout() } }
            } header: {
                Text("Connection")
            }

            #if os(macOS)
                Section {
                    Text("Issue a pairing code on this \(Copy.home). The joining \(Copy.device.lowercased()) finishes setup in the web UI.")
                        .foregroundStyle(.secondary)
                    if let pairing = model.pairing {
                        LabeledContent("Code") {
                            Text(pairing.code)
                                .font(.title2.monospaced().weight(.bold))
                                .textSelection(.enabled)
                        }
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            LabeledContent("Expires", value: PairingExpiry.label(expiresAt: pairing.expiresAt, now: context.date))
                        }
                        Text(pairing.qrPayload)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                        Button("Copy payload") { copy(pairing.qrPayload) }
                        Button("Revoke", role: .destructive) {
                            Task { await model.revokePairing() }
                        }
                    } else {
                        Button("Create pairing code") {
                            Task { await model.issuePairing() }
                        }
                    }
                } header: {
                    Text("Add a \(Copy.device)")
                }

                Section {
                    Text("Sign in on the iPhone app. This is not pairing. Scan the QR in BarkVisor, or copy the sign-in URI.")
                        .foregroundStyle(.secondary)
                    if let offer = model.loginOffer {
                        LoginOfferQRView(uri: offer.uri)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            LabeledContent("Expires", value: PairingExpiry.label(expiresAt: offer.expiresAt, now: context.date))
                        }
                        Text(offer.uri)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                        Button("Copy URI") { copy(offer.uri) }
                        Button("Hide", role: .destructive) {
                            Task { await model.revokeLoginOffer() }
                        }
                    } else {
                        Button("Show sign-in QR") {
                            Task { await model.issueLoginOffer() }
                        }
                    }
                } header: {
                    Text("Phone sign-in")
                }
            #endif

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
        .onAppear { urlDraft = model.serverURLText }
        .onDisappear { applyURL() }
        .task {
            #if os(macOS)
                await model.loadPairing()
                await model.loadLoginOffer()
            #endif
        }
    }

    private func applyURL() {
        model.applyServerURL(urlDraft)
        urlDraft = model.serverURLText
    }

    /// Persist a visible URL edit before tearing Settings down. Skip the follow-up
    /// action when a different origin already signed the session out.
    private func applyThen(_ action: () -> Void) {
        applyURL()
        if model.phase == .ready { action() }
    }

    #if os(macOS)
        private func copy(_ text: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    #endif
}
