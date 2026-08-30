import SwiftUI

/// Settings row pushing the read-only audit log. Admin-only on the server.
struct AuditLogSection: View {
    var body: some View {
        Section {
            NavigationLink("Audit log") {
                AuditLogView()
            }
        } footer: {
            Text("Activity log of API actions on this \(Copy.home). Entries older than 90 days are pruned.")
        }
    }
}

private struct AuditLogView: View {
    @Environment(AppModel.self) private var model
    @State private var entries: [AuditLogEntry] = []
    @State private var total = 0
    @State private var page = 0
    @State private var forbidden: String?
    @State private var loading = false
    @State private var actionDraft = ""
    @State private var actionFilter: String?

    var body: some View {
        Form {
            if let forbidden {
                Section {
                    Text(forbidden)
                        .foregroundStyle(.red)
                }
            } else {
                Section {
                    TextField("Filter by action", text: $actionDraft)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    #endif
                        .onSubmit { applyFilter() }
                        .disabled(loading)
                    if actionFilter != nil {
                        Button("Clear filter") {
                            actionDraft = ""
                            applyFilter()
                        }
                        .disabled(loading)
                    }
                }
                Section {
                    if loading, entries.isEmpty {
                        ProgressView("Loading audit log…")
                    } else if entries.isEmpty {
                        Text(AuditLogDisplay.emptyCopy(filtered: actionFilter != nil))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(entries) { entry in
                            AuditLogRow(entry: entry)
                        }
                    }
                } header: {
                    Text("Entries")
                } footer: {
                    if forbidden == nil, !entries.isEmpty {
                        pagingFooter
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Audit log")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
    }

    private var pagingFooter: some View {
        HStack {
            Text("\(total) entries")
            Spacer()
            Button("Prev") { turn(to: page - 1) }
                .disabled(loading || page == 0)
            Text("Page \(page + 1) of \(AuditLogDisplay.pageCount(total: total))")
            Button("Next") { turn(to: page + 1) }
                .disabled(loading || page >= AuditLogDisplay.pageCount(total: total) - 1)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private func applyFilter() {
        let trimmed = actionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = trimmed.isEmpty ? nil : trimmed
        guard next != actionFilter else { return }
        actionFilter = next
        page = 0
        Task { await load() }
    }

    private func turn(to next: Int) {
        guard next >= 0, next < AuditLogDisplay.pageCount(total: total) else { return }
        page = next
        Task { await load() }
    }

    private func load() async {
        guard let client = model.client else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await client.auditLog(
                limit: AuditLogDisplay.pageSize,
                offset: page * AuditLogDisplay.pageSize,
                action: actionFilter,
            )
            entries = result.entries
            total = result.total
            forbidden = nil
        } catch {
            if let message = AuditLogDisplay.forbiddenMessage(from: error) {
                forbidden = message
                entries = []
                total = 0
                return
            }
            model.banner = error.localizedDescription
        }
    }
}

private struct AuditLogRow: View {
    let entry: AuditLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.action)
                    .fontWeight(.medium)
                Spacer()
                Text(AuditLogDisplay.timestampLabel(entry.timestamp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("User", value: entry.username ?? "-")
            if let resource = AuditLogDisplay.resourceLabel(entry) {
                LabeledContent("Resource", value: resource)
            }
            if let detail = entry.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
