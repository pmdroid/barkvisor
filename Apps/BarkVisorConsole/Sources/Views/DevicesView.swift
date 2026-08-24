import SwiftUI

struct DevicesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.devices.isEmpty {
                ContentUnavailableView(
                    "No Devices yet",
                    systemImage: "externaldrive.badge.questionmark",
                    description: Text("This \(Copy.home.lowercased()) only lists Devices after the connected \(Copy.device.lowercased()) answers.")
                )
            } else {
                List(model.devices) { device in
                    NavigationLink {
                        DeviceDetailView(deviceID: device.hostId, fallbackDevice: device)
                    } label: {
                        DeviceRow(device: device, selected: device.hostId == model.selectedDeviceID)
                    }
                }
                .platformListStyle()
            }
        }
        .refreshable { await model.refreshPhoneDevices() }
        #if os(macOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add a \(Copy.device)", systemImage: "plus") {
                    Task { await model.open(.settings) }
                }
            }
        }
        #endif
    }
}

struct DeviceRow: View {
    var device: HomeDeviceHealthSnapshot
    var selected: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(device.title)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.secondary)
            }
            StatusLabel.reachability(device)
        }
    }

    private var subtitle: String {
        var parts = [device.isSelf ? "This \(Copy.device)" : Copy.device, device.platformLabel, device.workloadLine]
        if let resources = device.resourcesLine {
            parts.append(resources)
        }
        return parts.joined(separator: " · ")
    }
}
