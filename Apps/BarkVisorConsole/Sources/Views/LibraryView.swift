import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.images.isEmpty {
                ContentUnavailableView(
                    "Library is empty",
                    systemImage: "opticaldisc",
                    description: Text("Download images from the web UI Repositories page.")
                )
            } else {
                List(model.images) { image in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(image.name)
                            .font(.headline)
                            .foregroundStyle(image.status == "ready" ? BVTheme.green : .primary)
                        Text("\(image.imageType) · \(image.arch) · \(image.status) · \(ByteCountFormatter.string(fromByteCount: image.sizeBytes ?? 0, countStyle: .file))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .bvListStyle()
            }
        }
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
                    description: Text("Disks created for workloads appear here.")
                )
            } else {
                List(model.disks) { disk in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(disk.name)
                            .font(.headline)
                        Text("\(disk.format) · \(ByteCountFormatter.string(fromByteCount: disk.sizeBytes, countStyle: .file)) · \(disk.status)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .bvListStyle()
            }
        }
    }
}

struct NetworksView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.networks.isEmpty {
                ContentUnavailableView(
                    "No networks",
                    systemImage: "globe",
                    description: Text("NAT, bridged, and isolated networks show up here.")
                )
            } else {
                List(model.networks) { network in
                    LabeledContent(network.name) {
                        Text(network.isDefault ? "\(network.mode) · Default" : network.mode)
                            .foregroundStyle(.secondary)
                    }
                }
                .bvListStyle()
            }
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
                    description: Text("Logs stay on the connected Device.")
                )
            } else {
                List(Array(model.logs.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.level.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(levelColor(entry.level))
                            Text(entry.cat)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(entry.ts)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.msg)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
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

    private func levelColor(_ level: String) -> Color {
        switch level.lowercased() {
        case "error": BVTheme.red
        case "warn", "warning": BVTheme.amber
        default: .secondary
        }
    }
}
