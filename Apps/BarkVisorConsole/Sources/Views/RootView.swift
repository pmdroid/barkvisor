import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            BVTheme.bg.ignoresSafeArea()
            switch model.phase {
            case .launching:
                ProgressView()
                    .tint(BVTheme.accent)
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
        .foregroundStyle(BVTheme.text)
    }
}
