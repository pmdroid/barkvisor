import SwiftUI

struct ConnectView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack {
            Spacer()
            VStack(spacing: 0) {
                Image("Logo")
                    .resizable()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: BVTheme.radius))
                    .padding(.bottom, 20)
                    .accessibilityHidden(true)
                Text("BarkVisor")
                    .font(BVTheme.font(24, weight: .bold))
                    .padding(.bottom, 6)
                Text("Connect to a Device in your \(Copy.home)")
                    .font(BVTheme.font(13))
                    .foregroundStyle(BVTheme.textDim)
                    .padding(.bottom, 28)

                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "Device URL")
                    TextField("http://host:7777", text: $model.serverURLText)
                        .textFieldStyle(.plain)
                        .font(BVTheme.font(13))
                        .foregroundStyle(BVTheme.text)
                        .bvField()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        #endif
                }

                if let banner = model.banner {
                    BannerView(text: banner)
                        .padding(.top, 16)
                }

                Button {
                    Task { await model.connect() }
                } label: {
                    Text(model.busy ? "Connecting…" : "Connect")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(BVButtonStyle(kind: .primary, fullWidth: true))
                .disabled(model.busy || model.serverURLText.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding(.top, 16)
            }
            .padding(40)
            .frame(maxWidth: 400)
            .background(BVTheme.bgCard)
            .overlay(
                RoundedRectangle(cornerRadius: BVTheme.radius)
                    .stroke(BVTheme.borderGlass, lineWidth: 1)
            )
            Spacer()
        }
        .padding(24)
        .background(BVTheme.bg.ignoresSafeArea())
    }
}

struct LoginView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack {
            Spacer()
            VStack(spacing: 0) {
                Image("Logo")
                    .resizable()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: BVTheme.radius))
                    .padding(.bottom, 20)
                Text("BarkVisor")
                    .font(BVTheme.font(24, weight: .bold))
                    .padding(.bottom, 6)
                Text("Sign in to manage workloads on this \(Copy.device.lowercased())")
                    .font(BVTheme.font(13))
                    .foregroundStyle(BVTheme.textDim)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 8)
                Text(model.serverURLText)
                    .font(BVTheme.font(12, weight: .medium))
                    .foregroundStyle(BVTheme.accent)
                    .padding(.bottom, 20)

                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "Username")
                        TextField("admin", text: $model.username)
                            .textFieldStyle(.plain)
                            .font(BVTheme.font(13))
                            .bvField()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            #endif
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "Password")
                        SecureField("password", text: $model.password)
                            .textFieldStyle(.plain)
                            .font(BVTheme.font(13))
                            .bvField()
                    }
                }

                if let banner = model.banner {
                    BannerView(text: banner)
                        .padding(.top, 16)
                }

                Button {
                    Task { await model.signIn() }
                } label: {
                    Text(model.busy ? "Signing in…" : "Sign In")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(BVButtonStyle(kind: .primary, fullWidth: true))
                .disabled(model.busy || model.username.isEmpty || model.password.isEmpty)
                .padding(.top, 16)

                Button("Use a different Device URL") {
                    model.disconnect()
                }
                .buttonStyle(BVButtonStyle(kind: .ghost, fullWidth: true))
                .padding(.top, 8)
            }
            .padding(40)
            .frame(maxWidth: 400)
            .background(BVTheme.bgCard)
            .overlay(
                RoundedRectangle(cornerRadius: BVTheme.radius)
                    .stroke(BVTheme.borderGlass, lineWidth: 1)
            )
            Spacer()
        }
        .padding(24)
        .background(BVTheme.bg.ignoresSafeArea())
    }
}

struct SetupRequiredView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 16) {
                Text("Finish setup")
                    .font(BVTheme.font(24, weight: .bold))
                Text("This \(Copy.device.lowercased()) has not completed first-run setup. Open the web UI and finish SetupView, then return here to sign in. The native console does not reimplement the wizard.")
                    .font(BVTheme.font(13))
                    .foregroundStyle(BVTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.serverURLText)
                    .font(BVTheme.font(13, weight: .medium))
                    .foregroundStyle(BVTheme.accent)
                if let url = model.connectedURL {
                    Link("Open web UI", destination: url.appending(path: "setup"))
                        .buttonStyle(BVButtonStyle(kind: .primary))
                }
                Button("Back") { model.disconnect() }
                    .buttonStyle(BVButtonStyle(kind: .ghost))
            }
            .padding(36)
            .frame(maxWidth: 460)
            .background(BVTheme.bgCard)
            .overlay(
                RoundedRectangle(cornerRadius: BVTheme.radius)
                    .stroke(BVTheme.borderGlass, lineWidth: 1)
            )
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BVTheme.bg.ignoresSafeArea())
    }
}
