import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    var compact: Bool
    @Binding var menuOpen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if !compact || menuOpen {
                nav
                Spacer(minLength: 12)
                bottom
                Text("Made with ♥ in SF")
                    .font(BVTheme.font(11))
                    .foregroundStyle(BVTheme.textDim)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }
        }
        .padding(.top, compact ? 10 : 20)
        .padding(.bottom, compact ? 8 : 12)
        .frame(width: compact ? nil : 200, alignment: .top)
        .frame(maxWidth: compact ? .infinity : 200, alignment: .top)
        .background(BVTheme.sidebarBg)
        .overlay(alignment: .trailing) {
            if !compact {
                Rectangle()
                    .fill(BVTheme.borderGlass)
                    .frame(width: 1)
            }
        }
        .overlay(alignment: .bottom) {
            if compact {
                Rectangle()
                    .fill(BVTheme.borderGlass)
                    .frame(height: 1)
            }
        }
        #if os(macOS)
        .padding(.top, 14)
        #endif
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image("Logo")
                .resizable()
                .scaledToFill()
                .frame(width: compact ? 32 : 40, height: compact ? 32 : 40)
                .clipShape(RoundedRectangle(cornerRadius: BVTheme.radius))
            Text("BarkVisor")
                .font(BVTheme.font(compact ? 14 : 15, weight: .bold))
                .foregroundStyle(BVTheme.text)
            Spacer()
            if compact {
                Button {
                    menuOpen.toggle()
                } label: {
                    Image(systemName: menuOpen ? "xmark" : "line.3.horizontal")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(BVTheme.textSecondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, compact ? 4 : 16)
    }

    private var nav: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(AppRoute.allCases) { item in
                navButton(item)
            }
        }
        .padding(.horizontal, 10)
    }

    private func navButton(_ item: AppRoute) -> some View {
        let active = model.route == item
        return Button {
            menuOpen = false
            Task { await model.open(item) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 22)
                Text(item.title)
                    .font(BVTheme.font(13, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(active ? BVTheme.accent : BVTheme.textDim)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(active ? BVTheme.accentMuted : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: BVTheme.radius)
                    .stroke(active ? BVTheme.accent.opacity(0.15) : Color.clear, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: BVTheme.radius))
            .shadow(color: active ? BVTheme.accentGlow : .clear, radius: 8)
        }
        .buttonStyle(.plain)
    }

    private var bottom: some View {
        VStack(spacing: 4) {
            Button {
                model.logout()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 22)
                    Text("Logout")
                        .font(BVTheme.font(13, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(BVTheme.textDim)
                .padding(.horizontal, 12)
                .frame(height: 40)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
    }
}

extension AppRoute {
    var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .devices: "externaldrive.connected.to.line.below"
        case .workloads: "display"
        case .library: "opticaldisc"
        case .disks: "internaldrive"
        case .networks: "globe"
        case .logs: "doc.text"
        case .settings: "gearshape"
        }
    }
}
