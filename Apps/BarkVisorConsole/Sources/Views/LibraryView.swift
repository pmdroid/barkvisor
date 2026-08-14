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
                    LabeledContent {
                        Text(image.status)
                            .foregroundStyle(Color.status(image.status))
                    } label: {
                        Text(image.name)
                        Text("\(image.imageType) · \(image.arch) · \(ByteCountFormatter.string(fromByteCount: image.sizeBytes ?? 0, countStyle: .file))")
                    }
                }
                .platformListStyle()
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
                    LabeledContent {
                        Text(network.isDefault ? "\(network.mode) · Default" : network.mode)
                    } label: {
                        Text(network.name)
                    }
                }
                .platformListStyle()
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
