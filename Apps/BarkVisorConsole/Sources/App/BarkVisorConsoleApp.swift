import SwiftUI

@main
struct BarkVisorConsoleApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.bootstrap() }
                .onOpenURL { url in
                    Task { await model.handleOpenURL(url) }
                }
        }
        #if os(macOS)
        .defaultSize(width: 1_100, height: 720)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        #endif
    }
}
