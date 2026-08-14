import SwiftUI

struct StatusPill: View {
    var label: String
    var tone: Tone

    enum Tone { case running, stopped, error, warning, unknown }

    var body: some View {
        Label {
            Text(label)
        } icon: {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
    }

    private var color: Color {
        switch tone {
        case .running: BVTheme.green
        case .stopped, .unknown: .secondary
        case .error: BVTheme.red
        case .warning: BVTheme.amber
        }
    }

    static func health(_ raw: String) -> StatusPill {
        let tone: Tone
        switch raw {
        case "running", "guest_ready": tone = .running
        case "failed", "error": tone = .error
        case "starting", "stopping", "provisioning", "deleting", "degraded": tone = .warning
        case "stopped": tone = .stopped
        default: tone = .unknown
        }
        return StatusPill(label: WorkloadHealth.label(raw), tone: tone)
    }

    static func reachability(_ ok: Bool) -> StatusPill {
        StatusPill(label: ok ? "Reachable" : "Unreachable", tone: ok ? .running : .error)
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
