import SwiftUI

struct CreateWorkloadSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var allowsDevicePicker: Bool
    var initialImages: [LibraryImage]
    var onCreated: (HomeWorkloadRow) -> Void

    @State private var name = ""
    @State private var deviceID = ""
    @State private var imageID = ""
    @State private var images: [LibraryImage] = []
    @State private var loadingImages = false
    @State private var imageLoadID = 0
    @State private var creating = false
    @State private var localError: String?
    @State private var workloadClass = "house"
    @State private var openaiPreset = "home-ollama"
    @State private var byoOpenAIURL = CodingAgentImage.homeOllamaGrantURL
    @State private var byoOpenAIAPIKey = ""
    @State private var networks: [NetworkRecord] = []
    @State private var networkID = ""
    @State private var addressing = GuestAddressingDraft()

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                #endif

                if allowsDevicePicker {
                    Picker(Copy.device, selection: $deviceID) {
                        ForEach(reachableDevices) { item in
                            Text(item.isSelf ? "This \(Copy.device)" : item.title).tag(item.hostId)
                        }
                    }
                } else if let device {
                    LabeledContent(
                        Copy.device,
                        value: device.isSelf ? "This \(Copy.device)" : device.title,
                    )
                }

                if loadingImages {
                    ProgressView("Loading Library…")
                } else if readyImages.isEmpty {
                    Text(CreateWorkload.emptyLibraryCopy)
                        .foregroundStyle(.secondary)
                    if let url = model.connectedURL {
                        Link("Open catalog in the web UI", destination: url.appending(path: "registry"))
                    }
                } else {
                    Picker("Library image", selection: $imageID) {
                        Text("Choose an image").tag("")
                        ForEach(readyImages) { image in
                            Text("\(image.name) · \(image.arch)").tag(image.id)
                        }
                    }
                }

                Picker("Class", selection: $workloadClass) {
                    Text("House").tag("house")
                    Text("Agent").tag("agent")
                }

                if isCodingAgent {
                    Picker("OPENAI_BASE_URL", selection: $openaiPreset) {
                        Text("Home Ollama grant").tag("home-ollama")
                        Text("Bring your own").tag("byo")
                    }
                    if openaiPreset == "byo" {
                        TextField("https://api.example/v1", text: $byoOpenAIURL)
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        #endif
                        SecureField("OPENAI_API_KEY", text: $byoOpenAIAPIKey)
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        #endif
                    }
                }
            } footer: {
                Text(footerCopy)
            }

            if !bridgedNetworks.isEmpty {
                Section {
                    Picker("Network", selection: $networkID) {
                        Text("Shared (NAT)").tag("")
                        ForEach(bridgedNetworks) { network in
                            Text(network.name).tag(network.id)
                        }
                    }
                    if selectedNetwork != nil {
                        if cloudInitCapable {
                            Picker("Addressing", selection: $addressing.mode) {
                                Text("DHCP (LAN)").tag(GuestAddressingDraft.modeDHCP)
                                Text("Static IPv4").tag(GuestAddressingDraft.modeStatic)
                            }
                            if addressing.isStatic {
                                TextField("IPv4", text: $addressing.ipv4, prompt: Text("192.168.1.40"))
                                #if os(iOS)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .keyboardType(.numbersAndPunctuation)
                                #endif
                                Stepper(
                                    "Prefix: \(addressing.prefixLength ?? GuestAddressingDraft.defaultPrefixLength)",
                                    value: addressingPrefix,
                                    in: 1 ... 32,
                                )
                                TextField("Gateway", text: $addressing.gateway, prompt: Text("192.168.1.1"))
                                #if os(iOS)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .keyboardType(.numbersAndPunctuation)
                                #endif
                                TextField("DNS", text: $addressing.nameservers, prompt: Text("1.1.1.1, 8.8.8.8"))
                                #if os(iOS)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .keyboardType(.numbersAndPunctuation)
                                #endif
                            }
                        }
                    }
                } header: {
                    Text("Network")
                } footer: {
                    Text(networkFooterCopy)
                }
            }

            if let localError {
                Section {
                    Text(localError)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Create Workload")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if creating {
                        ProgressView()
                    } else {
                        Button("Create") {
                            Task { await submit() }
                        }
                        .disabled(!canSubmit)
                    }
                }
            }
            .disabled(creating)
            .task { await bootstrap() }
            .task(id: deviceID) { await loadImages() }
            .task(id: deviceID) { await loadNetworks() }
            .onChange(of: imageID) { _, _ in applyCodingAgentDefaults() }
            .onChange(of: networkID) { _, _ in
                if selectedNetwork == nil { addressing.mode = GuestAddressingDraft.modeDHCP }
            }
        #if os(iOS)
            .presentationDetents([.medium, .large])
        #endif
    }

    private var reachableDevices: [HomeDeviceHealthSnapshot] {
        model.devices.filter(\.isReachable)
    }

    private var device: HomeDeviceHealthSnapshot? {
        CreateWorkload.resolvedDevice(
            deviceID: deviceID,
            reachable: reachableDevices,
            selected: model.selectedDevice,
        )
    }

    private var readyImages: [LibraryImage] {
        CreateWorkload.ready(images)
    }

    private var selectedImage: LibraryImage? {
        readyImages.first { $0.id == imageID }
    }

    private var isCodingAgent: Bool {
        CodingAgentImage.matches(name: selectedImage?.name)
    }

    private var bridgedNetworks: [NetworkRecord] {
        networks.filter { $0.mode.lowercased() == GuestAddressingDraft.networkModeBridged }
    }

    /// Nil means implicit NAT (networkId omitted), same as before this picker existed.
    private var selectedNetwork: NetworkRecord? {
        bridgedNetworks.first { $0.id == networkID }
    }

    /// Cloud images run cloud-init; installer ISOs do not, so static stays off there.
    private var cloudInitCapable: Bool {
        selectedImage.map { !CreateWorkload.isISO($0) } ?? false
    }

    private var addressingPrefix: Binding<Int> {
        Binding(
            get: { addressing.prefixLength ?? GuestAddressingDraft.defaultPrefixLength },
            set: { addressing.prefixLength = $0 },
        )
    }

    private var networkFooterCopy: String {
        if selectedNetwork == nil {
            return "NAT out with port forwards. \(CreateWorkload.webEditCopy)"
        }
        if cloudInitCapable {
            return "Default is DHCP from your router. The Workload MAC is shown after create for a reservation."
        }
        return "After create, copy the Workload MAC and set the address in the guest or on the router. BarkVisor does not configure installer ISOs."
    }

    private var footerCopy: String {
        if isCodingAgent {
            let url = openaiPreset == "byo" ? byoOpenAIURL : CodingAgentImage.homeOllamaGrantURL
            return "Agent cage. OPENAI_BASE_URL \(url). Presets share this Library image. \(CreateWorkload.webEditCopy)"
        }
        return workloadClass == "agent"
            ? "\(CreateWorkload.agentGrantCopy) NAT out only; no USB. \(CreateWorkload.webEditCopy)"
            : "Default disk and implicit NAT. \(CreateWorkload.webEditCopy)"
    }

    private var canSubmit: Bool {
        CreateWorkload.canSubmit(name: name, image: selectedImage, loadingImages: loadingImages)
            && device != nil
    }

    private func bootstrap() async {
        if deviceID.isEmpty {
            deviceID = device?.hostId ?? ""
        }
    }

    private func loadImages() async {
        imageLoadID += 1
        let loadID = imageLoadID
        guard let device else {
            images = []
            imageID = ""
            loadingImages = false
            return
        }
        if loadID == 1 {
            images = initialImages
            imageID = CreateWorkload.ready(initialImages).first?.id ?? ""
        } else {
            images = []
            imageID = ""
        }
        loadingImages = true
        defer {
            if loadID == imageLoadID {
                loadingImages = false
            }
        }
        let loaded = await model.libraryImages(on: device)
        guard CreateWorkload.shouldApplyLibraryLoad(
            loadID: loadID,
            currentID: imageLoadID,
            cancelled: Task.isCancelled,
        ) else { return }
        images = loaded ?? []
        imageID = CreateWorkload.ready(loaded ?? []).first?.id ?? ""
        applyCodingAgentDefaults()
    }

    private func applyCodingAgentDefaults() {
        workloadClass = CodingAgentImage.defaultClass(forName: selectedImage?.name)
        if !CodingAgentImage.matches(name: selectedImage?.name) {
            openaiPreset = "home-ollama"
        }
    }

    private func loadNetworks() async {
        guard let device else {
            networks = []
            networkID = ""
            return
        }
        let loaded = await model.networkList(on: device)
        guard !Task.isCancelled else { return }
        networks = loaded ?? []
        if !networkID.isEmpty, !(loaded ?? []).contains(where: { $0.id == networkID }) {
            networkID = ""
        }
    }

    private func submit() async {
        guard !loadingImages, let device, let selectedImage else { return }
        creating = true
        localError = nil
        defer { creating = false }
        let openaiURL = isCodingAgent
            ? (openaiPreset == "byo" ? byoOpenAIURL : CodingAgentImage.homeOllamaGrantURL)
            : nil
        let openaiKey = isCodingAgent && openaiPreset == "byo" ? byoOpenAIAPIKey : nil
        guard let created = await model.createWorkload(
            name: name,
            image: selectedImage,
            on: device,
            workloadClass: workloadClass,
            openaiBaseURL: openaiURL,
            openaiAPIKey: openaiKey,
            network: selectedNetwork,
            addressing: addressing,
        ) else {
            localError = model.banner ?? "Could not create the Workload"
            return
        }
        onCreated(HomeWorkloadRow(workload: created, device: device))
        dismiss()
    }
}

extension View {
    func createWorkloadEntry(allowsDevicePicker: Bool, images: [LibraryImage], enabled: Bool) -> some View {
        modifier(
            CreateWorkloadEntryModifier(
                allowsDevicePicker: allowsDevicePicker,
                images: images,
                enabled: enabled,
            ),
        )
    }
}

private struct CreateWorkloadEntryModifier: ViewModifier {
    var allowsDevicePicker: Bool
    var images: [LibraryImage]
    var enabled: Bool
    @State private var showCreate = false
    @State private var created: HomeWorkloadRow?

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Create Workload", systemImage: "plus") {
                        showCreate = true
                    }
                    .disabled(!enabled)
                }
            }
            .sheet(isPresented: $showCreate) {
                NavigationStack {
                    CreateWorkloadSheet(
                        allowsDevicePicker: allowsDevicePicker,
                        initialImages: images,
                    ) { row in
                        created = row
                    }
                }
            }
            .navigationDestination(item: $created) { row in
                WorkloadDetailView(row: row)
            }
    }
}
