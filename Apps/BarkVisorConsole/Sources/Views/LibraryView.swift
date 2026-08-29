import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                if model.images.isEmpty {
                    Text(CreateWorkload.emptyLibraryCopy)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.images) { image in
                        LibraryImageRow(image: image)
                    }
                }
            } header: {
                Text(Copy.library)
            } footer: {
                Text(libraryFooter)
            }

            if !model.catalogLoaded {
                Section("Catalog") {
                    ProgressView("Loading catalog…")
                }
            } else if model.catalogGroups.isEmpty {
                Section("Catalog") {
                    Text(LibraryCatalog.emptyCatalogMessage(fetchFailed: model.catalogFetchFailed))
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(model.catalogGroups) { group in
                    Section(group.repo.name) {
                        ForEach(group.images) { image in
                            CatalogImageRow(image: image)
                        }
                    }
                }
            }
        }
        .platformListStyle()
        .refreshable { await model.refreshLibrary() }
        .task { await model.refreshLibrary() }
        .task(id: libraryTransferIDs) {
            guard !libraryTransferIDs.isEmpty else { return }
            while !Task.isCancelled, model.images.contains(where: \.isTransferring) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await model.refreshLibraryImages()
            }
        }
        .createWorkloadEntry(
            allowsDevicePicker: false,
            images: model.images,
            enabled: model.selectedDevice?.isReachable == true && CreateWorkload.hasReadyImage(model.images),
        )
    }

    private var libraryFooter: String {
        let title = model.libraryDevice?.title
        if LibraryCatalog.preferSelfDevice {
            return "Downloads land on This \(Copy.device)."
        }
        if let title, !title.isEmpty {
            return "Downloads land on \(title)."
        }
        return "Downloads land on the selected \(Copy.device.lowercased())."
    }

    private var libraryTransferIDs: String {
        model.images.filter(\.isTransferring).map(\.id).sorted().joined(separator: ",")
    }
}

private struct LibraryImageRow: View {
    var image: LibraryImage

    var body: some View {
        LabeledContent {
            if image.isTransferring {
                if let progress = image.transferProgress {
                    ProgressView(value: progress)
                        .controlSize(.small)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text(image.status)
                .foregroundStyle(Color.status(image.status))
        } label: {
            Text(image.name)
            Text(detail)
            if let error = image.error, image.status == "error" {
                Text(error)
                    .foregroundStyle(.red)
            }
        }
    }

    private var detail: String {
        var parts = [image.imageType, image.arch]
        if let size = LibraryCatalog.sizeLabel(image.sizeBytes) { parts.append(size) }
        return parts.joined(separator: " · ")
    }
}

private struct CatalogImageRow: View {
    @Environment(AppModel.self) private var model
    var image: CatalogImage

    var body: some View {
        LabeledContent {
            if state.isBusy {
                if let progress = LibraryCatalog.libraryImage(for: image, in: model.images)?.transferProgress {
                    ProgressView(value: progress)
                        .controlSize(.small)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Button(state.buttonTitle) {
                Task { await model.downloadCatalogImage(image) }
            }
            .disabled(state == .ready || state.isBusy || !(model.libraryDevice?.isReachable ?? true))
        } label: {
            Text(image.name)
            Text(image.detailLine)
            if case let .failed(message) = state, let message, !message.isEmpty {
                Text(message)
                    .foregroundStyle(.red)
            }
        }
    }

    private var state: CatalogDownloadState {
        LibraryCatalog.downloadState(
            local: LibraryCatalog.libraryImage(for: image, in: model.images),
            starting: model.actionIDs.contains("catalog:\(image.id)"),
        )
    }
}

struct DisksView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.disks.isEmpty {
                ContentUnavailableView(
                    "No disks",
                    systemImage: "internaldrive",
                    description: Text("Disks created for workloads appear here."),
                )
            } else {
                List(model.disks) { disk in
                    LabeledContent {
                        Text(disk.status)
                    } label: {
                        Text(disk.name)
                        Text("\(disk.format) · \(ByteCountFormatter.string(fromByteCount: disk.sizeBytes, countStyle: .file))")
                    }
                }
                .platformListStyle()
            }
        }
    }
}

struct NetworksView: View {
    @Environment(AppModel.self) private var model
    @State private var applyBusy = false
    @State private var applyNote: String?

    var body: some View {
        List {
            if model.networks.isEmpty {
                Text("NAT, bridged, and isolated networks show up here.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.networks) { network in
                    LabeledContent {
                        Text(network.isDefault ? "\(network.mode) · Default" : network.mode)
                    } label: {
                        Text(network.name)
                    }
                }
            }
            if model.capabilities?.linuxHostBridgeApplySupported == true {
                Section("Host bridge") {
                    Text("Apply persists br0 on this Device. Equivalent commands stay in the web UI. Rollback is a host timer.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let applyNote {
                        Text(applyNote)
                            .font(.footnote)
                    }
                    Button("Apply br0") {
                        Task { await runBridge(action: "apply") }
                    }
                    .disabled(applyBusy)
                    Button("Revert BarkVisor files") {
                        Task { await runBridge(action: "revert") }
                    }
                    .disabled(applyBusy)
                }
            }
            if model.capabilities?.macosSocketVmnetSupported == true {
                Section("socket_vmnet") {
                    Text("The Device starts Homebrew socket_vmnet. NAT still works when the service is down.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let applyNote {
                        Text(applyNote)
                            .font(.footnote)
                    }
                    Button("Setup") {
                        Task { await runBridge(action: "setup") }
                    }
                    .disabled(applyBusy)
                    Button("Start") {
                        Task { await runBridge(action: "start") }
                    }
                    .disabled(applyBusy)
                    Button("Stop") {
                        Task { await runBridge(action: "stop") }
                    }
                    .disabled(applyBusy)
                }
            }
        }
        .platformListStyle()
    }

    private func runBridge(action: String) async {
        guard let client = model.client else { return }
        applyBusy = true
        defer { applyBusy = false }
        do {
            var result = try await client.applyHostBridge(interface: nil, action: action, confirm: false)
            if result.needsConfirm == true {
                result = try await client.applyHostBridge(interface: nil, action: action, confirm: true)
            }
            applyNote = result.message
            if let changes = result.changes, !changes.isEmpty {
                applyNote = ([result.message].compactMap { $0 } + changes).joined(separator: "\n")
            }
        } catch {
            applyNote = error.localizedDescription
        }
    }
}

struct LogsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.logs.isEmpty {
                ContentUnavailableView(
                    "No log lines",
                    systemImage: "doc.text",
                    description: Text("Logs stay on the connected Device."),
                )
            } else {
                List(Array(model.logs.enumerated()), id: \.offset) { _, entry in
                    LabeledContent {
                        Text(entry.ts)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    } label: {
                        Text(entry.msg)
                            .font(.body)
                        Text("\(entry.level) · \(entry.cat)")
                            .foregroundStyle(Color.status(entry.level))
                    }
                }
                .listStyle(.plain)
            }
        }
        .toolbar {
            if let url = model.connectedURL {
                ToolbarItem(placement: .primaryAction) {
                    Link("Open web logs", destination: url.appending(path: "logs"))
                }
            }
        }
        .task { await model.open(.logs) }
    }
}
