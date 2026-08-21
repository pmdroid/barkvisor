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
                MacPairingSection()

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

#if os(macOS)
    private struct MacPairingSection: View {
        @Environment(AppModel.self) private var model
        @State private var selectedHost = ""
        @State private var customHost = ""
        @State private var pairingBusy = false
        @State private var copied = false

        var body: some View {
            Section {
                Text(
                    "Add a \(Copy.device) to this \(Copy.home). On the new \(Copy.device), open setup and choose Join an existing \(Copy.home), then scan the QR or paste this pairing code.",
                )
                .foregroundStyle(.secondary)
                if let pairing = model.pairing {
                    Text("1. Pick the address the new \(Copy.device) can reach (LAN IP or DNS name).")
                        .foregroundStyle(.secondary)
                    Text("2. Scan the QR or copy the full barkvisor:// offer, not only the short code.")
                        .foregroundStyle(.secondary)
                    Text(
                        "3. On the new \(Copy.device), choose Join an existing \(Copy.home) or run barkvisor join --code.",
                    )
                    .foregroundStyle(.secondary)
                    Text("4. The offer expires. Revoke it if you are not going to use it.")
                        .foregroundStyle(.secondary)
                    Picker("Address in this offer", selection: $selectedHost) {
                        ForEach(pairing.advertisedHosts, id: \.self) { host in
                            Text(host).tag(host)
                        }
                        Text("Other / DNS name…").tag(PairingAdvertisedHost.customSentinel)
                    }
                    .pickerStyle(.menu)
                    .disabled(pairingBusy)
                    .onChange(of: selectedHost) { _, host in
                        listedHostChanged(host)
                    }
                    if selectedHost == PairingAdvertisedHost.customSentinel {
                        TextField("hostname or DNS name", text: $customHost)
                            .disabled(pairingBusy)
                            .onSubmit { applyCustomHost() }
                        Button("Use this address") { applyCustomHost() }
                            .disabled(pairingBusy)
                    }
                    LabeledContent("Code") {
                        Text(pairing.code)
                            .font(.title2.monospaced().weight(.bold))
                            .textSelection(.enabled)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .leading, spacing: 8) {
                            if PairingExpiry.isActive(expiresAt: pairing.expiresAt, now: context.date),
                               let qr = PairingQR.image(payload: pairing.qrPayload) {
                                Image(decorative: qr, scale: 1)
                                    .interpolation(.none)
                                    .resizable()
                                    .frame(width: 196, height: 196)
                                    .padding(8)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .accessibilityLabel("Pairing offer QR")
                            }
                            LabeledContent("Expires", value: PairingExpiry.label(expiresAt: pairing.expiresAt, now: context.date))
                        }
                    }
                    Text("Changing the address issues a new code and offer. This \(Copy.device) still runs if that \(Copy.device) is unreachable.")
                        .foregroundStyle(.secondary)
                    Text(pairing.qrPayload)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                    Button(copied ? "Copied" : "Copy URI") { copyURI(pairing.qrPayload) }
                        .disabled(pairingBusy)
                    Button("Revoke", role: .destructive) {
                        runPairing { await model.revokePairing() }
                    }
                    .disabled(pairingBusy)
                } else {
                    Text("No pairing code yet. Add a \(Copy.device) to invite another machine into this \(Copy.home).")
                        .foregroundStyle(.secondary)
                    Button("Add a \(Copy.device)") {
                        runPairing { await model.issuePairing() }
                    }
                    .disabled(pairingBusy)
                }
            } header: {
                Text("Add a \(Copy.device)")
            }
            .task {
                await model.loadPairing()
                // Same Hashable offer does not fire onChange; restore after load like web.
                syncPicker(from: model.pairing)
            }
            .onChange(of: model.pairing, initial: true) { _, offer in
                syncPicker(from: offer)
            }
        }

        private func listedHostChanged(_ host: String) {
            if pairingBusy { return }
            let current = model.pairing.flatMap(PairingAdvertisedHost.issuedHost)
            switch PairingAdvertisedHost.applyListedHost(host, currentIssued: current) {
            case .skip:
                return
            case let .issue(advertisedHost):
                runPairing { await model.issuePairing(advertisedHost: advertisedHost) }
            case .needCustomHost:
                model.banner = PairingAdvertisedHost.needCustomMessage
            case .rejectedHost:
                model.banner = PairingAdvertisedHost.rejectedMessage
                syncPicker(from: model.pairing)
            }
        }

        private func applyCustomHost() {
            let current = model.pairing.flatMap(PairingAdvertisedHost.issuedHost)
            switch PairingAdvertisedHost.applyCustomHost(customHost, currentIssued: current) {
            case .skip:
                return
            case let .issue(advertisedHost):
                runPairing { await model.issuePairing(advertisedHost: advertisedHost) }
            case .needCustomHost:
                model.banner = PairingAdvertisedHost.needCustomMessage
            case .rejectedHost:
                model.banner = PairingAdvertisedHost.rejectedMessage
            }
        }

        private func runPairing(_ work: @escaping () async -> Void) {
            pairingBusy = true
            Task {
                await work()
                pairingBusy = false
                syncPicker(from: model.pairing)
            }
        }

        private func syncPicker(from offer: PairingIssue?) {
            let picker = PairingAdvertisedHost.syncPicker(from: offer)
            selectedHost = picker.selectedHost
            customHost = picker.customHost
        }

        private func copyURI(_ text: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        }
    }
#endif
