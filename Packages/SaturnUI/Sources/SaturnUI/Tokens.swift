import CryptoKit
import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

public enum Appearance: String, CaseIterable, Identifiable, Sendable {
    case dark
    case light
    case system

    public static let storageKey = "appearance"

    nonisolated(unsafe) public static let defaults: UserDefaults = {
        let environment = ProcessInfo.processInfo.environment
        guard let custom = [environment["SATURN_DATA_DIR"], environment["ENSEMBLE_DATA_DIR"]].compactMap({ $0 }).first(where: { !$0.isEmpty }) else { return .standard }
        let root = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath).standardizedFileURL.path
        let digest = SHA256.hash(data: Data(root.utf8)).map { String(format: "%02x", $0) }.joined()
        return UserDefaults(suiteName: "dev.monoliti.Saturn.data-dir." + digest.prefix(16)) ?? .standard
    }()
    public static let fallback = Appearance.dark

    public var id: Self { self }

    public var title: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .system: "System"
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }
}

public struct AppearanceScheme: ViewModifier {
    @AppStorage(Appearance.storageKey, store: Appearance.defaults) private var appearance = Appearance.fallback

    public init() {}

    public func body(content: Content) -> some View {
        content.preferredColorScheme(appearance.colorScheme)
    }
}

extension View {
    public func followsAppearance() -> some View {
        modifier(AppearanceScheme())
    }
}

public enum Tokens {
    public static let desk = Color.adaptive(dark: 0x050506, light: 0xE8E8ED)
    public static let window = Color.adaptive(dark: 0x000000, light: 0xFFFFFF)
    public static let side = Color.adaptive(dark: 0x0A0A0C, light: 0xF5F5F7)
    public static let raised = Color.adaptive(dark: 0x121216, light: 0xFFFFFF)
    public static let card = Color.adaptive(dark: 0x0E0E11, light: 0xFFFFFF)
    public static let menu = Color.adaptive(dark: 0x1A1B20, light: 0xFFFFFF)
    public static let bubble = Color.adaptive(dark: 0x1B1C21, light: 0xEFEFF2)
    public static let code = Color.adaptive(dark: 0x0A0A0C, light: 0xF5F5F7)
    public static let hair = Color.adaptive(dark: (0xFFFFFF, 0.08), light: (0x000000, 0.08))
    public static let hair2 = Color.adaptive(dark: (0xFFFFFF, 0.12), light: (0x000000, 0.14))
    public static let text = Color.adaptive(dark: 0xF5F5F7, light: 0x1D1D1F)
    public static let text2 = Color.adaptive(dark: (0xEBEBF5, 0.62), light: (0x3C3C43, 0.74))
    public static let text3 = Color.adaptive(dark: (0xEBEBF5, 0.4), light: (0x3C3C43, 0.5))
    public static let selection = Color.adaptive(dark: (0x8EC5FF, 0.12), light: (0x000000, 0.06))
    public static let hover = Color.adaptive(dark: (0xFFFFFF, 0.05), light: (0x000000, 0.035))
    public static let fill = Color.adaptive(dark: (0xFFFFFF, 0.06), light: (0x000000, 0.05))
    public static let fill2 = Color.adaptive(dark: (0xFFFFFF, 0.12), light: (0x000000, 0.1))
    public static let tabOn = Color.adaptive(dark: (0x8EC5FF, 0.16), light: (0xFFFFFF, 1))
    public static let primaryBackground = Color.adaptive(dark: 0xF5F5F7, light: 0x1D1D1F)
    public static let primaryForeground = Color.adaptive(dark: 0x0A0A0C, light: 0xFFFFFF)
    public static let link = Color.adaptive(dark: 0x8EC5FF, light: 0x0066CC)
    public static let accent = Color.adaptive(dark: 0x8EC5FF, light: 0x0A84FF)
    public static let need = Color.adaptive(dark: 0xFF7EB3, light: 0xE7005F)
    public static let stuck = Color.adaptive(dark: 0xFF5C8A, light: 0xE80042)
    public static let build = Color.adaptive(dark: 0xA99BFF, light: 0x7059FF)
    public static let review = Color.adaptive(dark: 0xC9A7FF, light: 0x8F49FF)
    public static let done = Color.adaptive(dark: 0x4FD1C5, light: 0x228178)
    public static let idle = Color.adaptive(dark: 0x8C9BB8, light: 0x60759C)
    public static let needBackground = Color.adaptive(dark: (0xFF7EB3, 0.08), light: (0xE7005F, 0.07))
    public static let needLine = Color.adaptive(dark: (0xFF7EB3, 0.4), light: (0xE7005F, 0.38))
    public static let stuckBackground = Color.adaptive(dark: (0xFF5C8A, 0.09), light: (0xE80042, 0.06))
    public static let stuckLine = Color.adaptive(dark: (0xFF5C8A, 0.4), light: (0xE80042, 0.35))
    public static let buildBackground = Color.adaptive(dark: (0xA99BFF, 0.12), light: (0x7059FF, 0.08))
    public static let reviewBackground = Color.adaptive(dark: (0xC9A7FF, 0.11), light: (0x8F49FF, 0.1))
    public static let doneBackground = Color.adaptive(dark: (0x4FD1C5, 0.12), light: (0x228178, 0.08))
    public static let doneLine = Color.adaptive(dark: (0x4FD1C5, 0.35), light: (0x228178, 0.3))
    public static let danger = stuck
    public static let live = Color.adaptive(dark: 0x30D158, light: 0x28A745)
    public static let scrim = Color.adaptive(dark: (0x000000, 0.55), light: (0x000000, 0.22))
    public static let shadow = Color.adaptive(dark: (0x000000, 0.7), light: (0x000000, 0.16))

    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    public enum Radius {
        public static let window: CGFloat = 22
        public static let composer: CGFloat = 18
        public static let card: CGFloat = 16
        public static let popover: CGFloat = 14
        public static let row: CGFloat = 9
    }

    public enum Size {
        public static let sidebar: CGFloat = 316
        public static let chatCard: CGFloat = 300
        public static let chatCardReserve: CGFloat = 340
        public static let transcript: CGFloat = 760
        public static let workerPanel: CGFloat = 380
        public static let narrowWindow: CGFloat = 1180
    }
}

extension Color {
    public static func adaptive(dark: UInt32, light: UInt32) -> Color {
        adaptive(dark: (dark, 1), light: (light, 1))
    }

    public static func adaptive(dark: (hex: UInt32, alpha: Double), light: (hex: UInt32, alpha: Double)) -> Color {
        #if canImport(AppKit)
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return platformColor(isDark ? dark : light)
        })
        #else
        Color(uiColor: UIColor { traits in platformColor(traits.userInterfaceStyle == .dark ? dark : light) })
        #endif
    }

    #if canImport(AppKit)
    static func platformColor(_ value: (hex: UInt32, alpha: Double)) -> NSColor {
        NSColor(srgbRed: component(value.hex, 16), green: component(value.hex, 8), blue: component(value.hex, 0), alpha: value.alpha)
    }
    #else
    static func platformColor(_ value: (hex: UInt32, alpha: Double)) -> UIColor {
        UIColor(red: component(value.hex, 16), green: component(value.hex, 8), blue: component(value.hex, 0), alpha: value.alpha)
    }
    #endif

    static func component(_ hex: UInt32, _ shift: UInt32) -> CGFloat {
        CGFloat((hex >> shift) & 0xFF) / 255
    }
}
