import SwiftUI

struct StatusPill: View {
    var label: String
    var tone: Tone

    enum Tone { case running, stopped, error, warning, unknown }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .shadow(color: color.opacity(0.8), radius: tone == .stopped || tone == .unknown ? 0 : 4)
            Text(label)
                .font(BVTheme.font(12, weight: .semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: BVTheme.radius, style: .continuous))
    }

    private var color: Color {
        switch tone {
        case .running: BVTheme.green
        case .stopped, .unknown: BVTheme.gray
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

struct PageHeader<Trailing: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(BVTheme.font(26, weight: .bold))
                    .foregroundStyle(BVTheme.text)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(BVTheme.font(13))
                        .foregroundStyle(BVTheme.textDim)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.bottom, 8)
    }
}

struct DevicePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.devices.count > 1 {
            Menu {
                ForEach(model.devices) { device in
                    Button {
                        Task { await model.select(device) }
                    } label: {
                        HStack {
                            Text(device.title)
                            if device.hostId == model.selectedDeviceID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(model.selectedDevice?.title ?? Copy.device)
                        .font(BVTheme.font(12, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(BVTheme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(BVTheme.bgSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: BVTheme.radius)
                        .stroke(BVTheme.borderGlass, lineWidth: 1)
                )
            }
            .menuStyle(.borderlessButton)
        }
    }
}

struct EmptyPanel: View {
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(BVTheme.font(16, weight: .semibold))
                .foregroundStyle(BVTheme.textSecondary)
            Text(message)
                .font(BVTheme.font(14))
                .foregroundStyle(BVTheme.textDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 72)
    }
}

struct BannerView: View {
    var text: String

    var body: some View {
        Text(text)
            .font(BVTheme.font(13, weight: .medium))
            .foregroundStyle(BVTheme.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(BVTheme.redMuted)
            .overlay(
                RoundedRectangle(cornerRadius: BVTheme.radius)
                    .stroke(BVTheme.red.opacity(0.3), lineWidth: 1)
            )
    }
}

struct FieldLabel: View {
    var text: String
    var body: some View {
        Text(text.uppercased())
            .font(BVTheme.font(11, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(BVTheme.textDim)
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
