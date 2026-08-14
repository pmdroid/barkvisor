import SwiftUI

/// Tokens copied from `frontend/src/style.css` (SPA dark theme).
enum BVTheme {
    static let bg = Color(hex: 0x0A0E14)
    static let text = Color(hex: 0xE4E4E2)
    static let textSecondary = Color(hex: 0xB8B8B4)
    static let textDim = Color(hex: 0x6E6E6C)
    static let accent = Color(hex: 0x0090F8)
    static let accentHover = Color(hex: 0x2EA8FF)
    static let green = Color(hex: 0x34D399)
    static let red = Color(hex: 0xF87171)
    static let amber = Color(hex: 0xFBBF24)
    static let gray = Color(hex: 0x6B7280)
    static let radius: CGFloat = 2

    static let bgSurface = Color(red: 0, green: 144 / 255, blue: 248 / 255).opacity(0.03)
    static let bgCard = Color(red: 0, green: 144 / 255, blue: 248 / 255).opacity(0.05)
    static let bgHover = Color(red: 0, green: 144 / 255, blue: 248 / 255).opacity(0.08)
    static let bgInput = Color.black.opacity(0.35)
    static let sidebarBg = Color(red: 8 / 255, green: 12 / 255, blue: 18 / 255).opacity(0.92)
    static let borderGlass = Color(red: 184 / 255, green: 184 / 255, blue: 180 / 255).opacity(0.12)
    static let accentMuted = Color(red: 0, green: 144 / 255, blue: 248 / 255).opacity(0.12)
    static let accentGlow = Color(red: 0, green: 144 / 255, blue: 248 / 255).opacity(0.25)
    static let greenMuted = Color(red: 52 / 255, green: 211 / 255, blue: 153 / 255).opacity(0.10)
    static let redMuted = Color(red: 248 / 255, green: 113 / 255, blue: 113 / 255).opacity(0.10)
    static let amberMuted = Color(red: 251 / 255, green: 191 / 255, blue: 36 / 255).opacity(0.10)
    static let grayMuted = Color(red: 107 / 255, green: 114 / 255, blue: 128 / 255).opacity(0.10)
    static let mainGradient1 = Color(red: 0, green: 144 / 255, blue: 248 / 255).opacity(0.07)
    static let mainGradient2 = Color(red: 184 / 255, green: 184 / 255, blue: 180 / 255).opacity(0.04)

    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Inter", size: size).weight(weight)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

extension View {
    func bvCard() -> some View {
        padding(20)
            .background(BVTheme.bgCard)
            .overlay(
                RoundedRectangle(cornerRadius: BVTheme.radius, style: .continuous)
                    .stroke(BVTheme.borderGlass, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: BVTheme.radius, style: .continuous))
    }

    func bvField() -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(BVTheme.bgInput)
            .overlay(
                RoundedRectangle(cornerRadius: BVTheme.radius, style: .continuous)
                    .stroke(BVTheme.borderGlass, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: BVTheme.radius, style: .continuous))
    }
}

struct BVButtonStyle: ButtonStyle {
    enum Kind { case primary, ghost, danger, warning }

    var kind: Kind
    var fullWidth: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BVTheme.font(13, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: BVTheme.radius, style: .continuous)
                    .stroke(border, lineWidth: kind == .primary || kind == .danger ? 0 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: BVTheme.radius, style: .continuous))
            .shadow(color: glow, radius: configuration.isPressed ? 8 : 16)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
    }

    private var foreground: Color {
        switch kind {
        case .primary, .danger: .white
        case .ghost: BVTheme.textSecondary
        case .warning: BVTheme.amber
        }
    }

    private var background: Color {
        switch kind {
        case .primary: BVTheme.accent
        case .ghost: BVTheme.bgSurface
        case .danger: BVTheme.red
        case .warning: BVTheme.amber.opacity(0.15)
        }
    }

    private var border: Color {
        switch kind {
        case .ghost: BVTheme.borderGlass
        case .warning: BVTheme.amber.opacity(0.3)
        default: .clear
        }
    }

    private var glow: Color {
        switch kind {
        case .primary: BVTheme.accentGlow
        case .danger: BVTheme.red.opacity(0.15)
        default: .clear
        }
    }
}
