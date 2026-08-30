import SwiftUI

#if os(iOS)

struct FolderPickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var device: HomeDeviceHealthSnapshot?
    var onSelect: (String) -> Void

    @State private var currentPath = ""
    @State private var pendingPath = ""
    @State private var entries: [FolderEntry] = []
    @State private var loading = false
    @State private var creating = false
    @State private var error: String?
    @State private var newFolderName = ""

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Text(error).foregroundStyle(.red)
                }
                if loading, entries.isEmpty {
                    ProgressView("Loading folders…")
                } else {
                    ForEach(entries) { entry in
                        Button {
                            if entry.name != "..", !entry.path.isEmpty {
                                pendingPath = entry.path
                            }
                            Task { await browse(entry.path) }
                        } label: {
                            Label(entry.name, systemImage: entry.name == ".." ? "chevron.left" : "folder")
                        }
                    }
                }
                if !currentPath.isEmpty {
                    Section("New folder") {
                        TextField("Folder name", text: $newFolderName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button(creating ? "Creating…" : "Create folder") {
                            Task { await createFolder() }
                        }
                        .disabled(creating || loading || newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } else {
                    Section {
                        Text("Open a folder to create a subfolder inside it.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Select Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Select") {
                        let path = chosenPath
                        guard !path.isEmpty else { return }
                        onSelect(path)
                        dismiss()
                    }
                    .disabled(chosenPath.isEmpty)
                }
            }
            .safeAreaInset(edge: .top) {
                Text(currentPath.isEmpty ? "Places" : currentPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
        }
        .task { await browse("") }
    }

    private var chosenPath: String {
        let trimmed = currentPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return pendingPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func browse(_ path: String) async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            entries = try await model.browseFolders(path: path, on: device)
            currentPath = path
            if !path.isEmpty { pendingPath = path }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if !path.isEmpty {
                do {
                    entries = try await model.browseFolders(path: "", on: device)
                    currentPath = ""
                } catch {
                    entries = []
                }
            } else {
                entries = []
            }
        }
    }

    private func createFolder() async {
        let parent = currentPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !parent.isEmpty, !name.isEmpty else { return }
        creating = true
        error = nil
        defer { creating = false }
        do {
            let created = try await model.createBrowseFolder(parent: parent, name: name, on: device)
            newFolderName = ""
            pendingPath = created.path
            await browse(parent)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

#endif
