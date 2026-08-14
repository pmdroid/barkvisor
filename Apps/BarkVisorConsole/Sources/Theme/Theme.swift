import SwiftUI

/// BarkVisor identity on top of system materials (iOS / macOS 26 glass when available).
enum BVTheme {
    static let accent = Color(red: 0, green: 144 / 255, blue: 248 / 255)
    static let green = Color(red: 52 / 255, green: 211 / 255, blue: 153 / 255)
    static let red = Color(red: 248 / 255, green: 113 / 255, blue: 113 / 255)
    static let amber = Color(red: 251 / 255, green: 191 / 255, blue: 36 / 255)
    static let gray = Color.secondary
}

extension View {
    @ViewBuilder
    func bvListStyle() -> some View {
        #if os(iOS)
        self.listStyle(.insetGrouped)
        #else
        self.listStyle(.inset)
        #endif
    }

    @ViewBuilder
    func bvGlass(in shape: some Shape = RoundedRectangle(cornerRadius: 20, style: .continuous)) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }

    @ViewBuilder
    func bvProminentButton() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func bvGlassButton() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}
