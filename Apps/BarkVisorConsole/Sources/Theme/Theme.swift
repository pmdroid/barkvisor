import SwiftUI

extension View {
    /// Grouped settings-style lists on iOS; inset lists on Mac.
    @ViewBuilder
    func platformListStyle() -> some View {
        #if os(iOS)
        self.listStyle(.insetGrouped)
        #else
        self.listStyle(.inset)
        #endif
    }
}

extension Color {
    static func status(_ key: String) -> Color {
        switch key.lowercased() {
        case "running", "guest_ready", "reachable", "ready": .green
        case "failed", "error", "unreachable": .red
        case "starting", "stopping", "provisioning", "deleting", "degraded", "warn", "warning",
             "downloading", "decompressing", "uploading": .orange
        default: .secondary
        }
    }
}
