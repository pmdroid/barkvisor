import SwiftUI

struct AppShell: View {
    var body: some View {
        #if os(iOS)
        PhoneAppShell()
        #else
        MacAppShell()
        #endif
    }
}

#if os(iOS)
struct PhoneAppShell: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.phoneTab) {
            Tab(value: PhoneTab.home) {
                NavigationStack {
                    HomeView()
                        .navigationTitle(Copy.home)
                }
            } label: {
                Label(Copy.home, systemImage: "house")
            }
            if model.showsChat {
                Tab(value: PhoneTab.chat) {
                    NavigationStack {
                        ChatView()
                            .navigationTitle("Chat")
                    }
                } label: {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right")
                }
            }
            Tab(value: PhoneTab.library) {
                NavigationStack {
                    LibraryView()
                        .navigationTitle(Copy.library)
                }
            } label: {
                Label(Copy.library, systemImage: "opticaldisc")
            }
            Tab(value: PhoneTab.models) {
                NavigationStack {
                    ModelsView()
                        .navigationTitle(AppRoute.models.title)
                }
            } label: {
                Label(AppRoute.models.title, systemImage: AppRoute.models.symbol)
            }
            Tab(value: PhoneTab.devices) {
                NavigationStack {
                    DevicesView()
                        .navigationTitle(Copy.devices)
                }
            } label: {
                Label(Copy.devices, systemImage: "externaldrive.connected.to.line.below")
            }
            .badge(model.unreachablePairedDeviceCount)
            Tab(value: PhoneTab.settings) {
                NavigationStack {
                    SettingsView()
                        .navigationTitle("Settings")
                }
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .sessionBanner()
        .onChange(of: model.phoneTab) { _, next in
            Task { await model.openPhoneTab(next) }
        }
    }
}
#endif

#if os(macOS)
struct MacAppShell: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $model.route) {
                Section {
                    ForEach(AppRoute.allCases.filter { $0 != .settings && shows($0) }, id: \.self) { item in
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
        .sessionBanner()
        .onChange(of: model.route) { _, next in
            Task { await model.open(next) }
        }
    }

    private func shows(_ route: AppRoute) -> Bool {
        if route == .chat { return model.showsChat }
        return true
    }

    @ViewBuilder
    private var detail: some View {
        switch model.route {
        case .dashboard: DashboardView()
        case .chat: ChatView()
        case .devices: DevicesView()
        case .workloads: WorkloadsView()
        case .models: ModelsView()
        case .library: LibraryView()
        case .disks: DisksView()
        case .networks: NetworksView()
        case .logs: LogsView()
        case .settings: SettingsView()
        }
    }
}
#endif

private extension View {
    func sessionBanner() -> some View {
        modifier(SessionBannerModifier())
    }
}

private struct SessionBannerModifier: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.alert(
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
    }
}
