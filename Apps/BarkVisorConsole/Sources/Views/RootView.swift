import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .launching:
                ProgressView("Opening BarkVisor…")
            case .connect:
                ConnectView()
            case .login:
                LoginView()
            case .setupRequired:
                SetupRequiredView()
            case .ready:
                AppShell()
            }
        }
    }
}
