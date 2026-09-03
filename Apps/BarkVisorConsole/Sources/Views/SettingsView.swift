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

            if model.client != nil {
                APIKeysSection()
                AuditLogSection()
                RemoteAccessSection()
                DeviceUpdatesSection()
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

private struct DeviceUpdatesSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            if model.capabilities?.inAppUpdateSupported != true {
                Text(model.capabilities?.inAppUpdateExplanation
                    ?? "In-app updates run on a root Ubuntu/Debian .deb or Apple Silicon .pkg Device.")
                    .foregroundStyle(.secondary)
            } else if let check = model.updateCheck {
                LabeledContent("Current", value: "v\(check.currentVersion)")
                if let update = check.update {
                    LabeledContent("Available", value: "v\(update.version) (\(update.packageKind))")
                    if !update.changelog.isEmpty {
                        Text(update.changelog)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Install v\(update.version)") {
                        Task { _ = await model.applyUpdate(update.version) }
                    }
                    .disabled(model.updateBusy)
                } else {
                    Text("This Device is on the latest version.")
                        .foregroundStyle(.secondary)
                }
                if !model.updatePhase.isEmpty {
                    Text(model.updatePhase)
                        .foregroundStyle(.secondary)
                }
                Button("Check for updates") {
                    Task { await model.refreshUpdates() }
                }
                .disabled(model.updateBusy)
            } else {
                Text("Could not load updates for this Device.")
                    .foregroundStyle(.secondary)
                Button("Check for updates") {
                    Task { await model.refreshUpdates() }
                }
            }
        } header: {
            Text("Updates")
        }
        .task {
            if model.capabilities?.inAppUpdateSupported == true {
                await model.refreshUpdates()
            }
        }
    }
}

private struct RemoteAccessSection: View {
    @Environment(AppModel.self) private var model
    @State private var selectedHost = ""
    @State private var customHost = ""
    @State private var saving = false

    var body: some View {
        Section {
            Text(
                "Pairing, sign-in QRs, and Models inference use this host. Pick a detected host or enter a custom hostname, MagicDNS name, or tailnet IP.",
            )
            .foregroundStyle(.secondary)
            if let status = model.remoteAccess {
                if !displayedURL(status).isEmpty {
                    Text(displayedURL(status))
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
                Picker("Device URL", selection: $selectedHost) {
                    ForEach(status.advertisedHosts, id: \.self) { host in
                        let label = DeviceURL.formatHomeDeviceURL(host)
                        Text(label.isEmpty ? host : label).tag(host)
                    }
                    Text("Other / DNS name…").tag(PairingAdvertisedHost.customSentinel)
                }
                .pickerStyle(.menu)
                .disabled(saving)
                if selectedHost == PairingAdvertisedHost.customSentinel {
                    TextField("hostname, MagicDNS, or tailnet IP", text: $customHost)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    #endif
                        .disabled(saving)
                }
                Button("Save") { save() }
                    .disabled(saving)
            } else {
                Text("Could not load Device URL.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Device URL")
        }
        .task {
            await model.loadRemoteAccess()
            syncPicker()
        }
        .onChange(of: model.remoteAccess, initial: true) { _, _ in
            syncPicker()
        }
    }

    private func displayedURL(_ status: RemoteAccessStatus) -> String {
        let saved = DeviceURL.formatHomeDeviceURL(status.deviceUrl)
        if !saved.isEmpty { return saved }
        guard status.tailscale.available else { return "" }
        return DeviceURL.formatHomeDeviceURL(status.tailscale.dnsName)
    }

    private func syncPicker() {
        guard let status = model.remoteAccess else { return }
        let picker = PairingAdvertisedHost.syncAdvertisePicker(
            deviceUrl: status.deviceUrl,
            listedHosts: status.advertisedHosts,
        )
        selectedHost = picker.selectedHost
        customHost = picker.customHost
    }

    private func save() {
        if selectedHost != PairingAdvertisedHost.customSentinel {
            if PairingAdvertisedHost.applyListedHost(selectedHost, currentIssued: nil) == .rejectedHost {
                model.banner = PairingAdvertisedHost.rejectedMessage
                return
            }
        } else {
            let trimmed = customHost.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty,
               PairingAdvertisedHost.applyCustomHost(trimmed, currentIssued: nil) == .rejectedHost {
                model.banner = PairingAdvertisedHost.rejectedMessage
                return
            }
        }
        let host = PairingAdvertisedHost.hostForOffer(selectedHost: selectedHost, customHost: customHost) ?? ""
        saving = true
        Task {
            _ = await model.saveRemoteAccess(
                RemoteAccessUpdate(deviceUrl: host),
            )
            saving = false
            syncPicker()
        }
    }
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
                    PairingOfferQR(payload: pairing.qrPayload, expiresAt: pairing.expiresAt)
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

    /// Renders the offer QR once per payload. `TimelineView` only ticks expiry.
    private struct PairingOfferQR: View {
        let payload: String
        let expiresAt: String
        private let qr: CGImage?

        init(payload: String, expiresAt: String) {
            self.payload = payload
            self.expiresAt = expiresAt
            qr = PairingQR.image(payload: payload)
        }

        var body: some View {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 8) {
                    if PairingExpiry.isActive(expiresAt: expiresAt, now: context.date), let qr {
                        Image(decorative: qr, scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 196, height: 196)
                            .padding(8)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .accessibilityLabel("Pairing offer QR")
                    }
                    LabeledContent("Expires", value: PairingExpiry.label(expiresAt: expiresAt, now: context.date))
                }
            }
        }
    }
#endif
