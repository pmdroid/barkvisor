import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(
                title: Copy.library,
                subtitle: "Images on \(model.selectedDevice?.title ?? Copy.device)"
            ) {
                DevicePicker()
            }

            if model.images.isEmpty {
                EmptyPanel(
                    title: "Library is empty",
                    message: "Download images from the web UI Repositories page."
                )
            } else {
                VStack(spacing: 0) {
                    header(["Name", "Type", "Arch", "Status", "Size"])
                    ForEach(model.images) { image in
                        row([
                            image.name,
                            image.imageType,
                            image.arch,
                            image.status,
                            ByteCountFormatter.string(fromByteCount: image.sizeBytes ?? 0, countStyle: .file),
                        ], leadingTone: image.status == "ready" ? BVTheme.green : BVTheme.amber)
                    }
                }
                .background(BVTheme.bgCard)
                .overlay(
                    RoundedRectangle(cornerRadius: BVTheme.radius)
                        .stroke(BVTheme.borderGlass, lineWidth: 1)
                )
            }
        }
    }
}

struct DisksView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Disks", subtitle: "Storage on the selected \(Copy.device.lowercased())") {
                DevicePicker()
            }
            if model.disks.isEmpty {
                EmptyPanel(title: "No disks", message: "Disks created for workloads appear here.")
            } else {
                VStack(spacing: 0) {
                    header(["Name", "Format", "Size", "Status"])
                    ForEach(model.disks) { disk in
                        row([
                            disk.name,
                            disk.format,
                            ByteCountFormatter.string(fromByteCount: disk.sizeBytes, countStyle: .file),
                            disk.status,
                        ])
                    }
                }
                .background(BVTheme.bgCard)
                .overlay(
                    RoundedRectangle(cornerRadius: BVTheme.radius)
                        .stroke(BVTheme.borderGlass, lineWidth: 1)
                )
            }
        }
    }
}

struct NetworksView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Networks", subtitle: "Modes on the selected \(Copy.device.lowercased())") {
                DevicePicker()
            }
            if model.networks.isEmpty {
                EmptyPanel(title: "No networks", message: "NAT, bridged, and isolated networks show up here.")
            } else {
                VStack(spacing: 0) {
                    header(["Name", "Mode", "Default"])
                    ForEach(model.networks) { network in
                        row([network.name, network.mode, network.isDefault ? "Yes" : ""])
                    }
                }
                .background(BVTheme.bgCard)
                .overlay(
                    RoundedRectangle(cornerRadius: BVTheme.radius)
                        .stroke(BVTheme.borderGlass, lineWidth: 1)
                )
            }
        }
    }
}

struct LogsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Logs", subtitle: "Recent Device logs from the connected server") {
                if let url = model.connectedURL {
                    Link("Open web logs", destination: url.appending(path: "logs"))
                        .buttonStyle(BVButtonStyle(kind: .ghost))
                }
            }
            if model.logs.isEmpty {
                EmptyPanel(title: "No log lines", message: "Logs stay on the connected Device.")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.logs.enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .top, spacing: 10) {
                            Text(entry.ts)
                                .foregroundStyle(BVTheme.textDim)
                                .frame(width: 170, alignment: .leading)
                            Text(entry.level)
                                .foregroundStyle(levelColor(entry.level))
                                .frame(width: 56, alignment: .leading)
                            Text(entry.cat)
                                .foregroundStyle(BVTheme.textSecondary)
                                .frame(width: 90, alignment: .leading)
                            Text(entry.msg)
                                .foregroundStyle(BVTheme.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                }
                .background(BVTheme.bgCard)
                .overlay(
                    RoundedRectangle(cornerRadius: BVTheme.radius)
                        .stroke(BVTheme.borderGlass, lineWidth: 1)
                )
            }
        }
        .task { await model.open(.logs) }
    }

    private func levelColor(_ level: String) -> Color {
        switch level.lowercased() {
        case "error": BVTheme.red
        case "warn", "warning": BVTheme.amber
        default: BVTheme.textSecondary
        }
    }
}

@ViewBuilder
func header(_ columns: [String]) -> some View {
    HStack {
        ForEach(columns, id: \.self) { column in
            Text(column.uppercased())
                .font(BVTheme.font(11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(BVTheme.textDim)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(Color.white.opacity(0.02))
}

func row(_ columns: [String], leadingTone: Color? = nil) -> some View {
    HStack {
        ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
            Text(column)
                .font(BVTheme.font(13))
                .foregroundStyle(index == 0 ? (leadingTone ?? BVTheme.text) : BVTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .overlay(alignment: .bottom) {
        Rectangle().fill(BVTheme.borderGlass.opacity(0.5)).frame(height: 1)
    }
}
