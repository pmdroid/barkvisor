import SwiftUI

extension AppRoute {
    var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .chat: "bubble.left.and.bubble.right"
        case .devices: "externaldrive.connected.to.line.below"
        case .workloads: "display"
        case .library: "opticaldisc"
        case .disks: "internaldrive"
        case .networks: "globe"
        case .logs: "doc.text"
        case .settings: "gearshape"
        }
    }
}
