import SwiftUI

@main
struct BarkVisorConsoleApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(BVTheme.accent)
                .task { await model.bootstrap() }
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 760)
        .windowStyle(.hiddenTitleBar)
        #endif
    }
}
