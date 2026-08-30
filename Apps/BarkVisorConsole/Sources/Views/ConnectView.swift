import SwiftUI

struct ConnectView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    TextField("Device URL", text: $model.serverURLText, prompt: Text("http://192.168.30.1:7777"))
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    #endif
                } header: {
                    Text("Connect")
                } footer: {
                    Text("Paste a Device origin including http:// or https://, or a web /login URL. Default port is 7777.")
                }

                Section {
                    Button("Continue") {
                        Task { await model.connect() }
                    }
                    .disabled(model.busy || model.serverURLText.trimmingCharacters(in: .whitespaces).isEmpty)
                    #if os(iOS)
                        NavigationLink("Scan QR") {
                            LoginQRScanner(
                                onCode: { uri in
                                    Task { await model.redeemLoginURI(uri) }
                                },
                                onFailure: { model.banner = $0 },
                            )
                        }
                    #endif
                    if model.busy {
                        ProgressView()
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("BarkVisor")
            .alert(
                "Could not connect",
                isPresented: Binding(
                    get: { model.banner != nil },
                    set: { if !$0 { model.banner = nil } },
                ),
            ) {
                Button("OK", role: .cancel) { model.banner = nil }
            } message: {
                Text(model.banner ?? "")
            }
        }
    }
}

struct LoginView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Field?

    private enum Field { case user, password }

    private var passkeyHint: String? {
        guard let url = try? DeviceURL.normalize(model.serverURLText) else { return nil }
        return PasskeySupport.passkeyBlock(for: url)?.message
    }

    private var passkeyBlocked: Bool {
        passkeyHint != nil
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Device", value: model.serverURLText)
                    TextField("Username", text: $model.username)
                        .textContentType(.username)
                        .focused($focused, equals: .user)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    #endif
                    SecureField("Password", text: $model.password)
                        .textContentType(.password)
                        .focused($focused, equals: .password)
                        .onSubmit { Task { await model.signIn() } }
                } header: {
                    Text("Sign In")
                } footer: {
                    Text("Same admin user as the web UI on this Device.")
                }

                Section {
                    Button("Sign In") {
                        Task { await model.signIn() }
                    }
                    .disabled(model.busy || model.username.isEmpty || model.password.isEmpty)
                    #if os(iOS) || os(macOS)
                        Button("Sign in with passkey") {
                            Task { await model.signInWithPasskey() }
                        }
                        .disabled(model.busy || passkeyBlocked)
                        if let passkeyHint {
                            Text(passkeyHint)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    #endif
                    #if os(iOS)
                        NavigationLink("Scan QR") {
                            LoginQRScanner(
                                onCode: { uri in
                                    Task { await model.redeemLoginURI(uri) }
                                },
                                onFailure: { model.banner = $0 },
                            )
                        }
                    #endif
                    if model.busy {
                        ProgressView()
                    }
                    Button("Use a different Device URL") {
                        model.disconnect()
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Sign In")
            .onAppear { focused = model.username.isEmpty ? .user : .password }
            .alert(
                "Sign in failed",
                isPresented: Binding(
                    get: { model.banner != nil },
                    set: { if !$0 { model.banner = nil } },
                ),
            ) {
                Button("OK", role: .cancel) { model.banner = nil }
            } message: {
                Text(model.banner ?? "")
            }
        }
    }
}

struct SetupRequiredView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Finish setup", systemImage: "wrench.and.screwdriver")
            } description: {
                Text("This \(Copy.device.lowercased()) has not completed first-run setup. Open the web UI, then return here to sign in.")
            } actions: {
                if let url = model.connectedURL {
                    Link("Open web UI", destination: url.appending(path: "setup"))
                }
                Button("Back") { model.disconnect() }
            }
            .navigationTitle("BarkVisor")
        }
    }
}
