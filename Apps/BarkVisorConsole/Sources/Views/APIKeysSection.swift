import SwiftUI
#if os(iOS)
    import UIKit
#endif
#if os(macOS)
    import AppKit
#endif

enum Clipboard {
    static func copy(_ text: String) {
        #if os(iOS)
            UIPasteboard.general.string = text
        #elseif os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

struct APIKeysSection: View {
    @Environment(AppModel.self) private var model
    @State private var keys: [APIKeyResponse] = []
    @State private var forbidden: String?
    @State private var loading = false
    @State private var showCreate = false
    @State private var minted: APIKeyCreateResponse?
    @State private var pendingMinted: APIKeyCreateResponse?
    @State private var revokeTarget: APIKeyResponse?

    var body: some View {
        Section {
            if let forbidden {
                Text(forbidden)
                    .foregroundStyle(.red)
            } else if loading, keys.isEmpty {
                ProgressView("Loading API keys…")
            } else if keys.isEmpty {
                Text("No API keys yet. Create an inference key for Ollama list and chat completions.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(keys) { key in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(key.name)
                                .fontWeight(.medium)
                            Spacer()
                            Text(key.kindBadge)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary)
                                .clipShape(Capsule())
                        }
                        LabeledContent("Created", value: APIKeyDisplay.createdLabel(key.createdAt))
                        LabeledContent("Expires", value: APIKeyDisplay.expiryLabel(key.expiresAt))
                        LabeledContent("Last used", value: APIKeyDisplay.usedLabel(key.lastUsedAt))
                        Button("Revoke", role: .destructive) {
                            revokeTarget = key
                        }
                    }
                }
            }
            if forbidden == nil {
                Button("Create key") { showCreate = true }
            }
        } header: {
            Text("API keys")
        } footer: {
            Text("The plaintext secret is shown once on create. The list never includes it.")
        }
        .task { await loadKeys() }
        .sheet(isPresented: $showCreate, onDismiss: presentMintedIfNeeded) {
            NavigationStack {
                CreateAPIKeySheet { created in
                    pendingMinted = created
                    showCreate = false
                    Task { await loadKeys() }
                }
            }
        }
        .sheet(item: $minted) { secret in
            NavigationStack {
                MintedAPIKeySheet(secret: secret) {
                    minted = nil
                }
            }
        }
        .alert(
            revokeTitle,
            isPresented: Binding(
                get: { revokeTarget != nil },
                set: { if !$0 { revokeTarget = nil } },
            ),
        ) {
            Button("Revoke", role: .destructive) {
                Task { await revoke() }
            }
            Button("Cancel", role: .cancel) { revokeTarget = nil }
        } message: {
            Text("Any tools using this key lose access immediately.")
        }
    }

    private var revokeTitle: String {
        if let name = revokeTarget?.name {
            return "Revoke \(name)?"
        }
        return "Revoke API key?"
    }

    private func presentMintedIfNeeded() {
        if let pending = pendingMinted {
            minted = pending
            pendingMinted = nil
        }
    }

    private func loadKeys() async {
        guard let client = model.client else { return }
        loading = true
        defer { loading = false }
        do {
            keys = try await client.listAPIKeys()
            forbidden = nil
        } catch {
            if let message = APIKeyDisplay.forbiddenMessage(from: error) {
                forbidden = message
                keys = []
                return
            }
            model.banner = error.localizedDescription
        }
    }

    private func revoke() async {
        guard let target = revokeTarget, let client = model.client else { return }
        revokeTarget = nil
        do {
            try await client.revokeAPIKey(id: target.id)
            await loadKeys()
        } catch {
            if let message = APIKeyDisplay.forbiddenMessage(from: error) {
                forbidden = message
                return
            }
            model.banner = error.localizedDescription
        }
    }
}

private struct CreateAPIKeySheet: View {
    var onCreated: (APIKeyCreateResponse) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind = APIKeyKindOption.createDefault
    @State private var expiresIn = APIKeyDisplay.defaultExpiry
    @State private var creating = false
    @State private var localError: String?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                #endif
                Picker("Kind", selection: $kind) {
                    ForEach(APIKeyKindOption.allCases) { option in
                        Text(option.pickerLabel).tag(option)
                    }
                }
                Picker("Expires", selection: $expiresIn) {
                    ForEach(APIKeyDisplay.expiryChoices, id: \.self) { value in
                        Text(expiryPickerLabel(value)).tag(value)
                    }
                }
            } footer: {
                Text(APIKeyDisplay.inferenceCopy)
            }
            if let localError {
                Section {
                    Text(localError)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Create API key")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if creating {
                        ProgressView()
                    } else {
                        Button("Create") {
                            Task { await submit() }
                        }
                        .disabled(!canSubmit)
                    }
                }
            }
            .disabled(creating)
        #if os(iOS)
            .presentationDetents([.medium, .large])
        #endif
    }

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func expiryPickerLabel(_ value: String) -> String {
        switch value {
        case "30d": "30 days"
        case "90d": "90 days"
        case "1y": "1 year"
        case "never": "Never"
        default: value
        }
    }

    private func submit() async {
        guard let client = model.client else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        creating = true
        defer { creating = false }
        do {
            let created = try await client.createAPIKey(
                name: trimmed,
                expiresIn: expiresIn,
                kind: kind.rawValue,
            )
            onCreated(created)
        } catch {
            if let message = APIKeyDisplay.forbiddenMessage(from: error) {
                localError = message
                return
            }
            localError = error.localizedDescription
        }
    }
}

private struct MintedAPIKeySheet: View {
    var secret: APIKeyCreateResponse
    var onDone: () -> Void
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Text(secret.key)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                ShareLink(item: secret.key)
                Button(copied ? "Copied" : "Copy") {
                    Clipboard.copy(secret.key)
                    copied = true
                }
            } footer: {
                Text("Copy this key now. It will not be shown again.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("API key created")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDone() }
                }
            }
            .interactiveDismissDisabled()
    }
}
