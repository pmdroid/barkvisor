import SwiftUI

/// Placeholder destination. The next slice fills serial console for this Device.
struct SerialConsoleView: View {
    var workloadID: String
    var deviceID: String
    var fallbackWorkload: Workload
    var fallbackDevice: HomeDeviceHealthSnapshot

    private var destinationID: String { "\(deviceID)/\(workloadID)" }

    var body: some View {
        ContentUnavailableView(
            "Console coming in the next slice",
            systemImage: "apple.terminal",
            description: Text("Serial console for \(fallbackWorkload.name) on \(fallbackDevice.title) will land here. Member Console stays off until PAS-200.")
        )
        .accessibilityIdentifier(destinationID)
        .navigationTitle("Console")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
