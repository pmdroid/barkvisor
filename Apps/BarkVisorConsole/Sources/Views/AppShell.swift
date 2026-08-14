import SwiftUI

struct AppShell: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(AppRoute.allCases, selection: $model.route) { item in
                Label(item.title, systemImage: item.symbol)
                    .tag(item)
            }
            .navigationTitle("BarkVisor")
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") {
                    model.logout()
                }
                .bvGlassButton()
                .padding()
                .frame(maxWidth: .infinity)
            }
        } detail: {
            NavigationStack {
                detail
                    .navigationTitle(model.route.title)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            DevicePicker()
                        }
                    }
                    .safeAreaInset(edge: .top) {
                        if let banner = model.banner {
                            Text(banner)
                                .font(.subheadline)
                                .foregroundStyle(BVTheme.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(.red.opacity(0.12))
                        }
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: model.route) { _, next in
            Task { await model.open(next) }
        }
    }

    @ViewBuilder
    private var detail: some View {
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
}
