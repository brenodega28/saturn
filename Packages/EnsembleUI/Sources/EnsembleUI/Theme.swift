import SwiftUI

public enum Theme {
    public static let accent = Color(hex: 0x0A84FF)
    public static let link = Tokens.link
    public static let windowBackground = Tokens.window
    public static let canvas = Tokens.desk
    public static let sidebarBackground = Tokens.side

    public static let primaryText = Tokens.text
    public static let secondaryText = Tokens.text2
    public static let tertiaryText = Tokens.text3

    public static let fill = Tokens.fill
    public static let fillRaised = Tokens.fill2
    public static let fillSelected = Tokens.tabOn
    public static let hairline = Tokens.hair

    public static let success = Color(hex: 0x30D158)
    public static let successText = Tokens.done
    public static let warning = Color(hex: 0xFF9F0A)
    public static let info = Color(hex: 0x409CFF)
    public static let paused = Color(hex: 0xFFD60A)
    public static let neutral = Color(hex: 0x98989F)
    public static let danger = Color(hex: 0xFF453A)
    public static let memory = Color(hex: 0xD9B3FF)

    public static let monospaced = Font.system(.footnote, design: .monospaced)
}

public enum RolePalette: String, CaseIterable, Sendable {
    case lead
    case scrum
    case django
    case react
    case claude
    case reviewer
    case qa
    case neutral

    public var gradient: LinearGradient {
        let (top, bottom) = stops
        return LinearGradient(colors: [Color(hex: top), Color(hex: bottom)], startPoint: .top, endPoint: .bottom)
    }

    private var stops: (UInt32, UInt32) {
        switch self {
        case .lead: (0xBE86FF, 0x7B3FD9)
        case .scrum: (0x5AD8C4, 0x1A8F80)
        case .django: (0x3FD487, 0x1E8F55)
        case .react: (0x5CCBF5, 0x1B78B3)
        case .claude: (0xE58A69, 0xB0532F)
        case .reviewer: (0xFFB547, 0xD9740A)
        case .qa: (0xFF708C, 0xCF2149)
        case .neutral: (0x8E8E96, 0x4A4A52)
        }
    }
}

extension Color {
    public init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
