import SwiftUI

/// Placeholder destination. The next slice fills VNC display for this Device.
struct DisplayView: View {
    var workloadID: String
    var deviceID: String
    var fallbackWorkload: Workload
    var fallbackDevice: HomeDeviceHealthSnapshot

    private var destinationID: String { "\(deviceID)/\(workloadID)" }

    var body: some View {
        ContentUnavailableView(
            "Display coming in the next slice",
            systemImage: "display",
            description: Text("Display for \(fallbackWorkload.name) on \(fallbackDevice.title) will land here. Member Display stays off until PAS-200.")
        )
        .accessibilityIdentifier(destinationID)
        .navigationTitle("Display")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
