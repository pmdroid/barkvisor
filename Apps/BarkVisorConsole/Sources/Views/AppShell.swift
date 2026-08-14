import SwiftUI

struct AppShell: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $model.route) {
                Section {
                    ForEach(AppRoute.allCases.filter { $0 != .settings }, id: \.self) { item in
                        Label(item.title, systemImage: item.symbol)
                            .tag(item)
                    }
                }
                Section {
                    Label(AppRoute.settings.title, systemImage: AppRoute.settings.symbol)
                        .tag(AppRoute.settings)
                    Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        model.logout()
                    }
                }
            }
            .navigationTitle("BarkVisor")
            .listStyle(.sidebar)
        } detail: {
            NavigationStack {
                detail
                    .navigationTitle(model.route.title)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            DevicePicker()
                        }
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.banner != nil },
                set: { if !$0 { model.banner = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.banner = nil }
        } message: {
            Text(model.banner ?? "")
        }
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
