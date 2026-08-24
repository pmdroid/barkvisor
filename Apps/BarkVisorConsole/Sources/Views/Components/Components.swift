import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif
#if canImport(AppKit)
    import AppKit
#endif

enum ClipboardCopy {
    static func set(_ text: String) {
        #if os(iOS)
            UIPasteboard.general.string = text
        #else
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

struct CopyableSnippet: View {
    var title: String
    var text: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    ClipboardCopy.set(text)
                    copied = true
                }
                .buttonStyle(.borderless)
            }
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}

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
        case "starting", "stopping", "provisioning", "deleting", "degraded",
             "downloading", "decompressing", "uploading": "clock.fill"
        case "stopped": "pause.circle"
        default: "circle"
        }
    }

    static func health(_ raw: String) -> StatusLabel {
        StatusLabel(text: WorkloadHealth.label(raw), key: raw)
    }

    static func reachability(_ device: HomeDeviceHealthSnapshot) -> StatusLabel {
        StatusLabel(text: device.reachabilityLabel, key: device.reachabilityStatusKey)
    }
}

struct WorkloadRowPowerActions: ViewModifier {
    var actions: [WorkloadListAction]
    var onStart: () -> Void
    var onStop: () -> Void

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if actions.contains(.start) {
                    Button(WorkloadListAction.start.title, action: onStart)
                        .tint(.green)
                }
                if actions.contains(.acpiStop) {
                    Button(WorkloadListAction.acpiStop.title, action: onStop)
                }
            }
            .contextMenu {
                if actions.contains(.start) {
                    Button(WorkloadListAction.start.title, action: onStart)
                }
                if actions.contains(.acpiStop) {
                    Button(WorkloadListAction.acpiStop.title, action: onStop)
                }
            }
    }
}

extension View {
    func workloadRowPowerActions(
        _ actions: [WorkloadListAction],
        onStart: @escaping () -> Void,
        onStop: @escaping () -> Void,
    ) -> some View {
        modifier(WorkloadRowPowerActions(actions: actions, onStart: onStart, onStop: onStop))
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
                },
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
