import SwiftUI

#if os(iOS)

struct CreateVMWizardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var allowsDevicePicker: Bool
    var initialImages: [LibraryImage]
    var onCreated: (HomeWorkloadRow) -> Void

    @State private var step: CreateVMWizard.Step = .gallery
    @State private var kind: CreateVMWizard.GalleryKind?
    @State private var selectedTemplate: VMTemplateRecord?
    @State private var selectedImage: LibraryImage?
    @State private var templates: [VMTemplateRecord] = []
    @State private var images: [LibraryImage] = []
    @State private var sshKeys: [SSHKeyRecord] = []
    @State private var networks: [NetworkRecord] = []
    @State private var disks: [DiskRecord] = []
    @State private var deviceID = ""
    @State private var name = ""
    @State private var templateInputs: [String: String] = [:]
    @State private var sshKeyID = ""
    @State private var presetID = "medium"
    @State private var networkID = ""
    @State private var diskSource: CreateVMWizard.DiskSource = .new
    @State private var existingDiskID = ""
    @State private var workloadClass = "house"
    @State private var openaiPreset = "home-ollama"
    @State private var byoOpenAIURL = CodingAgentImage.homeOllamaGrantURL
    @State private var byoOpenAIAPIKey = ""
    @State private var loading = false
    @State private var creating = false
    @State private var localError: String?
    @State private var sharedPaths: [String] = []
    @State private var showFolderPicker = false

    var body: some View {
        VStack(spacing: 0) {
            wizardHeader
            Form {
                switch step {
                case .gallery: galleryStep
                case .configure: configureStep
                case .disk: diskStep
                }
                if let localError {
                    Section {
                        Text(localError).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .navigationTitle("Create Workload")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(step == .gallery ? "Cancel" : "Back") {
                    if step == .gallery { dismiss() } else { goBack() }
                }
            }
            if step != .gallery {
                ToolbarItem(placement: .confirmationAction) {
                    if creating {
                        ProgressView()
                    } else {
                        Button(step == .disk ? "Create" : "Next") {
                            Task {
                                if step == .disk { await submit() } else { goForward() }
                            }
                        }
                        .disabled(!canAdvance)
                    }
                }
            }
        }
        .disabled(creating || loading)
        .task { await bootstrap() }
        .task(id: deviceID) { await reloadDeviceData() }
        .sheet(isPresented: $showFolderPicker) {
            FolderPickerView(device: device) { path in
                if !sharedPaths.contains(path) {
                    sharedPaths.append(path)
                }
            }
        }
    }

    private var wizardHeader: some View {
        HStack(spacing: 8) {
            ForEach(CreateVMWizard.Step.allCases, id: \.rawValue) { item in
                Text(item.title)
                    .font(.caption.weight(item == step ? .semibold : .regular))
                    .foregroundStyle(item.rawValue <= step.rawValue ? Color.primary : Color.secondary)
                if item != .disk {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private var galleryStep: some View {
        Section {
            if loading && templates.isEmpty {
                ProgressView("Loading templates…")
            } else {
                ForEach(templates) { template in
                    galleryCard(title: template.name, subtitle: template.tagline, selected: kind == .template && selectedTemplate?.id == template.id) {
                        pickTemplate(template)
                    }
                }
            }
            if CreateVMWizard.codingAgentImage(in: images) != nil {
                galleryCard(title: "Coding Agent", subtitle: "Sandboxed dev environment", selected: kind == .codingAgent) {
                    pickCodingAgent()
                }
            }
            if CreateVMWizard.windowsImage(in: images) != nil {
                galleryCard(title: "Windows", subtitle: "Windows desktop from a ready ISO", selected: kind == .windows) {
                    pickWindows()
                }
            }
            galleryCard(title: "Use your own image", subtitle: "Pick a ready Library image", selected: kind == .custom) {
                kind = .custom
                selectedTemplate = nil
                selectedImage = nil
                step = .configure
            }
        } header: {
            Text("What do you want to run?")
        }
    }

    @ViewBuilder
    private var configureStep: some View {
        Section {
            TextField("Name", text: $name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if allowsDevicePicker {
                Picker(Copy.device, selection: $deviceID) {
                    ForEach(reachableDevices) { item in
                        Text(item.isSelf ? "This \(Copy.device)" : item.title).tag(item.hostId)
                    }
                }
            } else if let device {
                LabeledContent(Copy.device, value: device.isSelf ? "This \(Copy.device)" : device.title)
            }
        } header: {
            Text("Name and placement")
        }

        if kind == .template, let selectedTemplate {
            Section("Template") {
                ForEach(selectedTemplate.visibleInputs, id: \.id) { input in
                    TextField(input.label ?? input.id, text: binding(for: input.id))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
        }

        if kind == .custom {
            Section("Library image") {
                Picker("Image", selection: Binding(
                    get: { selectedImage?.id ?? "" },
                    set: { id in selectedImage = CreateWorkload.ready(images).first { $0.id == id } },
                )) {
                    Text("Choose").tag("")
                    ForEach(CreateWorkload.ready(images)) { image in
                        Text("\(image.name) · \(image.arch)").tag(image.id)
                    }
                }
            }
        }

        if requiresSSH {
            Section("SSH key") {
                Picker("Authorized key", selection: $sshKeyID) {
                    Text("Choose a key").tag("")
                    ForEach(sshKeys) { key in
                        Text(CreateVMWizard.sshKeyLabel(key, keyCount: sshKeys.count)).tag(key.id)
                    }
                }
            }
        }

        if kind == .codingAgent {
            Section("Agent") {
                Picker("OPENAI_BASE_URL", selection: $openaiPreset) {
                    Text("Home Ollama grant").tag("home-ollama")
                    Text("Bring your own").tag("byo")
                }
                if openaiPreset == "byo" {
                    TextField("https://api.example/v1", text: $byoOpenAIURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("OPENAI_API_KEY", text: $byoOpenAIAPIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
        } else if kind != .template {
            Picker("Class", selection: $workloadClass) {
                Text("House").tag("house")
                Text("Agent").tag("agent")
            }
        }

        Section("Size") {
            Picker("Preset", selection: $presetID) {
                ForEach(sizePresets) { preset in
                    Text("\(preset.label) · \(preset.cpu) CPU · \(preset.memoryMB / 1024) GB").tag(preset.id)
                }
            }
        }

        if !bridgedNetworks.isEmpty {
            Section("Network") {
                Picker("Mode", selection: $networkID) {
                    Text("Shared (NAT)").tag("")
                    ForEach(bridgedNetworks) { network in
                        Text(network.name).tag(network.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var diskStep: some View {
        Section {
            Picker("Disk", selection: $diskSource) {
                Text("New disk").tag(CreateVMWizard.DiskSource.new)
                Text("Existing disk").tag(CreateVMWizard.DiskSource.existing)
            }
            if diskSource == .new {
                Stepper("Size: \(selectedPreset.diskGB) GB", value: diskSizeBinding, in: 1 ... 2048)
            } else {
                Picker("Unused disk", selection: $existingDiskID) {
                    Text("Choose").tag("")
                    ForEach(unusedDisks) { disk in
                        Text(disk.name).tag(disk.id)
                    }
                }
                if unusedDisks.isEmpty {
                    Text("No unused disks on this \(Copy.device.lowercased()).")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Disk")
        }

        if showsSharedFolders {
            Section {
                ForEach(sharedPaths, id: \.self) { path in
                    HStack {
                        Text(path).font(.caption.monospaced()).lineLimit(1)
                        Spacer()
                        Button("Remove", role: .destructive) {
                            sharedPaths.removeAll { $0 == path }
                        }
                    }
                }
                Button("Add shared folder") {
                    showFolderPicker = true
                }
            } header: {
                Text("Shared folders")
            } footer: {
                Text("Optional host directories shared via virtio-9p.")
            }
        }
    }

    private var showsSharedFolders: Bool {
        kind != .codingAgent && workloadClass != "agent"
    }

    private func galleryCard(title: String, subtitle: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .listRowBackground(selected ? Color.accentColor.opacity(0.12) : nil)
    }

    private var reachableDevices: [HomeDeviceHealthSnapshot] {
        model.devices.filter(\.isReachable)
    }

    private var device: HomeDeviceHealthSnapshot? {
        CreateWorkload.resolvedDevice(deviceID: deviceID, reachable: reachableDevices, selected: model.selectedDevice)
    }

    private var sizePresets: [CreateVMWizard.SizePreset] {
        CreateVMWizard.clampedPresets(hostCPU: device?.resources?.cpuCount, hostMemoryMB: device?.resources?.memoryTotalMB)
    }

    private var selectedPreset: CreateVMWizard.SizePreset {
        sizePresets.first { $0.id == presetID } ?? sizePresets[1]
    }

    @State private var diskSizeGBOverride: Int?

    private var diskSizeBinding: Binding<Int> {
        Binding(
            get: { diskSizeGBOverride ?? selectedPreset.diskGB },
            set: { diskSizeGBOverride = $0 },
        )
    }

    private var requiresSSH: Bool {
        CreateVMWizard.requiresSSH(kind: kind ?? .custom, template: selectedTemplate, image: resolvedImage)
    }

    private var selectedSSHKey: SSHKeyRecord? {
        sshKeys.first { $0.id == sshKeyID }
    }

    private var resolvedImage: LibraryImage? {
        switch kind {
        case .windows: CreateVMWizard.windowsImage(in: images)
        case .codingAgent: CreateVMWizard.codingAgentImage(in: images)
        case .custom: selectedImage
        default: nil
        }
    }

    private var bridgedNetworks: [NetworkRecord] {
        networks.filter { $0.mode.lowercased() == "bridged" }
    }

    private var selectedNetwork: NetworkRecord? {
        bridgedNetworks.first { $0.id == networkID }
    }

    private var cloudInitCapable: Bool {
        switch kind {
        case .template: true
        case .custom: resolvedImage.map { !CreateWorkload.isISO($0) } ?? false
        case .codingAgent: true
        default: false
        }
    }

    private var unusedDisks: [DiskRecord] {
        CreateVMWizard.unusedDisks(disks)
    }

    private var canAdvance: Bool {
        switch step {
        case .gallery: false
        case .configure:
            CreateVMWizard.canProceedConfigure(
                kind: kind ?? .custom,
                name: name,
                device: device,
                template: selectedTemplate,
                templateInputs: templateInputs,
                image: resolvedImage,
                sshKey: selectedSSHKey,
                requiresSSH: requiresSSH,
            )
        case .disk:
            CreateVMWizard.canCreate(
                kind: kind ?? .custom,
                diskSource: diskSource,
                diskSizeGB: diskSizeGBOverride ?? selectedPreset.diskGB,
                existingDiskID: existingDiskID,
                unusedDisks: unusedDisks,
            )
        }
    }

    private func binding(for inputID: String) -> Binding<String> {
        Binding(
            get: { templateInputs[inputID, default: ""] },
            set: { templateInputs[inputID] = $0 },
        )
    }

    private func bootstrap() async {
        if deviceID.isEmpty { deviceID = device?.hostId ?? "" }
        images = initialImages
        loading = true
        defer { loading = false }
        templates = await model.templateList(on: device) ?? []
        sshKeys = await model.sshKeyList() ?? []
        if sshKeyID.isEmpty {
            sshKeyID = sshKeys.first(where: \.isDefault)?.id ?? sshKeys.first?.id ?? ""
        }
    }

    private func reloadDeviceData() async {
        guard let device else {
            networks = []
            disks = []
            templates = []
            return
        }
        loading = true
        defer { loading = false }
        async let nets = model.networkList(on: device)
        async let dsk = model.diskList(on: device)
        async let tpl = model.templateList(on: device)
        async let imgs = model.libraryImages(on: device)
        networks = await nets ?? []
        disks = await dsk ?? []
        templates = await tpl ?? []
        if let loaded = await imgs { images = loaded }
        if let selectedTemplate, let match = templates.first(where: { $0.slug == selectedTemplate.slug }) {
            self.selectedTemplate = match
            templateInputs = CreateVMWizard.seedTemplateInputs(match).merging(templateInputs) { _, kept in kept }
        }
        if !networkID.isEmpty, !networks.contains(where: { $0.id == networkID }) { networkID = "" }
    }

    private func pickTemplate(_ template: VMTemplateRecord) {
        kind = .template
        selectedTemplate = template
        selectedImage = nil
        name = CreateVMWizard.defaultName(for: .template, template: template)
        templateInputs = CreateVMWizard.seedTemplateInputs(template)
        presetID = CreateVMWizard.presets.first { $0.cpu == template.cpuCount && $0.memoryMB == template.memoryMB }?.id ?? "medium"
        step = .configure
    }

    private func pickWindows() {
        kind = .windows
        selectedTemplate = nil
        selectedImage = CreateVMWizard.windowsImage(in: images)
        name = CreateVMWizard.defaultName(for: .windows, template: nil)
        presetID = "medium"
        step = .configure
    }

    private func pickCodingAgent() {
        kind = .codingAgent
        selectedTemplate = nil
        selectedImage = CreateVMWizard.codingAgentImage(in: images)
        name = CreateVMWizard.defaultName(for: .codingAgent, template: nil)
        workloadClass = "agent"
        presetID = "medium"
        step = .configure
    }

    private func goBack() {
        localError = nil
        switch step {
        case .configure: step = .gallery
        case .disk: step = .configure
        default: break
        }
    }

    private func goForward() {
        localError = nil
        if step == .configure { step = .disk }
    }

    private func submit() async {
        guard let device, let kind else { return }
        creating = true
        localError = nil
        defer { creating = false }
        let preset = selectedPreset
        let diskGB = diskSizeGBOverride ?? preset.diskGB
        if let created = await model.createFromWizard(
            kind: kind,
            name: name,
            device: device,
            template: selectedTemplate,
            templateInputs: templateInputs,
            image: resolvedImage,
            sshKey: selectedSSHKey,
            preset: preset,
            network: selectedNetwork,
            diskSource: diskSource,
            diskSizeGB: diskGB,
            existingDiskID: existingDiskID,
            workloadClass: workloadClass,
            openaiBaseURL: kind == .codingAgent ? (openaiPreset == "byo" ? byoOpenAIURL : CodingAgentImage.homeOllamaGrantURL) : nil,
            openaiAPIKey: kind == .codingAgent && openaiPreset == "byo" ? byoOpenAIAPIKey : nil,
            sharedPaths: sharedPaths,
        ) {
            onCreated(HomeWorkloadRow(workload: created, device: device))
            dismiss()
        } else {
            localError = model.banner ?? "Could not create the Workload"
        }
    }
}

#endif
