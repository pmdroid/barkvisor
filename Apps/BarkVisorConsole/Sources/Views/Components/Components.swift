import SwiftUI

struct StatusLabel: View {
    var text: String
    var key: String

    var body: some View {
        Label(text, systemImage: symbol)
            .foregroundStyle(Color.status(key))
            .labelStyle(.titleAndIcon)
            .font(.subheadline)
            .symbolRenderingMode(.hierarchical)
    }

    private var symbol: String {
        switch key.lowercased() {
        case "running", "guest_ready", "reachable", "ready": "checkmark.circle.fill"
        case "failed", "error", "unreachable": "exclamationmark.triangle.fill"
        case "starting", "stopping", "provisioning", "deleting", "degraded": "clock.fill"
        case "stopped": "pause.circle"
        default: "circle"
        }
    }

    static func health(_ raw: String) -> StatusLabel {
        StatusLabel(text: WorkloadHealth.label(raw), key: raw)
    }

    static func reachability(_ ok: Bool) -> StatusLabel {
        StatusLabel(text: ok ? "Reachable" : "Unreachable", key: ok ? "reachable" : "unreachable")
    }
}

struct DevicePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.devices.count > 1 {
            Picker(Copy.device, selection: Binding(
                get: { model.selectedDeviceID ?? "" },
                set: { next in
                    guard let device = model.devices.first(where: { $0.hostId == next }) else { return }
                    Task { await model.select(device) }
                }
            )) {
                ForEach(model.devices) { device in
                    Text(device.title).tag(device.hostId)
                }
            }
            .pickerStyle(.menu)
        }
    }
}

#if os(iOS)
struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
