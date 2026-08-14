import SwiftUI

struct AppShell: View {
    @Environment(AppModel.self) private var model
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var mobileMenuOpen = false

    var body: some View {
        Group {
            #if os(iOS)
            if compactWidth {
                VStack(spacing: 0) {
                    SidebarView(compact: true, menuOpen: $mobileMenuOpen)
                    content
                }
            } else {
                HStack(spacing: 0) {
                    SidebarView(compact: false, menuOpen: $mobileMenuOpen)
                    content
                }
            }
            #else
            HStack(spacing: 0) {
                SidebarView(compact: false, menuOpen: $mobileMenuOpen)
                content
            }
            #endif
        }
        .background(BVTheme.bg.ignoresSafeArea())
        #if os(macOS)
        .ignoresSafeArea(edges: .top)
        #endif
    }

    private var content: some View {
        ZStack(alignment: .topLeading) {
            BVTheme.bg
            RadialGradient(
                colors: [BVTheme.mainGradient1, .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 520
            )
            RadialGradient(
                colors: [BVTheme.mainGradient2, .clear],
                center: .bottomLeading,
                startRadius: 20,
                endRadius: 420
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let banner = model.banner {
                        BannerView(text: banner)
                    }
                    switch model.route {
                    case .dashboard: DashboardView()
                    case .devices: DevicesView()
                    case .workloads: WorkloadsView()
                    case .library: LibraryView()
                    case .disks: DisksView()
                    case .networks: NetworksView()
                    case .logs: LogsView()
                    case .settings: SettingsView()
                    }
                }
                .padding(.horizontal, compactWidth ? 14 : 40)
                .padding(.vertical, compactWidth ? 16 : 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var compactWidth: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }
}
