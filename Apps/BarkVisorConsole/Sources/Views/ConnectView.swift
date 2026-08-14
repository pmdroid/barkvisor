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
                    Text("Paste a Device origin or a web /login URL. The console talks to port 7777.")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Connect")
                }

                if let banner = model.banner {
                    Section {
                        Text(banner)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await model.connect() }
                    } label: {
                        if model.busy {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Continue")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .bvProminentButton()
                    .disabled(model.busy || model.serverURLText.trimmingCharacters(in: .whitespaces).isEmpty)
                    .listRowBackground(Color.clear)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("BarkVisor")
        }
    }
}

struct LoginView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Field?

    private enum Field { case user, password }

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
                    Text("Sign in")
                } footer: {
                    Text("Same admin user as the web UI on this Device.")
                }

                if let banner = model.banner {
                    Section {
                        Text(banner)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await model.signIn() }
                    } label: {
                        if model.busy {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Sign In")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .bvProminentButton()
                    .disabled(model.busy || model.username.isEmpty || model.password.isEmpty)
                    .listRowBackground(Color.clear)

                    Button("Use a different Device URL") {
                        model.disconnect()
                    }
                    .bvGlassButton()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Sign In")
            .onAppear { focused = model.username.isEmpty ? .user : .password }
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
                        .bvProminentButton()
                }
                Button("Back") { model.disconnect() }
                    .bvGlassButton()
            }
            .navigationTitle("BarkVisor")
        }
    }
}
