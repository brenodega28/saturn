import AppKit
import SwiftUI
import Testing
@testable import SaturnUI

@MainActor
struct TokensTests {
    func resolved(_ color: Color, _ name: NSAppearance.Name) -> (red: Int, green: Int, blue: Int, alpha: Double) {
        var result = (red: 0, green: 0, blue: 0, alpha: 0.0)
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            let rgb = NSColor(color).usingColorSpace(.sRGB)!
            result = (Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()), Double(rgb.alphaComponent))
        }
        return result
    }

    typealias RGBA = (red: Int, green: Int, blue: Int, alpha: Double)

    func rgba(_ hex: UInt32, _ alpha: Double = 1) -> RGBA {
        (Int((hex >> 16) & 0xFF), Int((hex >> 8) & 0xFF), Int(hex & 0xFF), alpha)
    }

    func matches(_ color: Color, dark: RGBA, light: RGBA) -> Bool {
        func same(_ a: RGBA, _ b: RGBA) -> Bool {
            a.red == b.red && a.green == b.green && a.blue == b.blue && abs(a.alpha - b.alpha) < 0.002
        }
        return same(resolved(color, .darkAqua), dark) && same(resolved(color, .aqua), light)
    }

    @Test func tokensMatchTheEclipseBlueTable() {
        let table: [(String, Color, RGBA, RGBA)] = [
            ("desk", Tokens.desk, rgba(0x050506), rgba(0xE8E8ED)),
            ("window", Tokens.window, rgba(0x000000), rgba(0xFFFFFF)),
            ("side", Tokens.side, rgba(0x0A0A0C), rgba(0xF5F5F7)),
            ("raised", Tokens.raised, rgba(0x121216), rgba(0xFFFFFF)),
            ("card", Tokens.card, rgba(0x0E0E11), rgba(0xFFFFFF)),
            ("menu", Tokens.menu, rgba(0x1A1B20), rgba(0xFFFFFF)),
            ("bubble", Tokens.bubble, rgba(0x1B1C21), rgba(0xEFEFF2)),
            ("code", Tokens.code, rgba(0x0A0A0C), rgba(0xF5F5F7)),
            ("hair", Tokens.hair, rgba(0xFFFFFF, 0.08), rgba(0x000000, 0.08)),
            ("hair2", Tokens.hair2, rgba(0xFFFFFF, 0.12), rgba(0x000000, 0.14)),
            ("text", Tokens.text, rgba(0xF5F5F7), rgba(0x1D1D1F)),
            ("text2", Tokens.text2, rgba(0xEBEBF5, 0.62), rgba(0x3C3C43, 0.74)),
            ("text3", Tokens.text3, rgba(0xEBEBF5, 0.4), rgba(0x3C3C43, 0.5)),
            ("selection", Tokens.selection, rgba(0x8EC5FF, 0.12), rgba(0x000000, 0.06)),
            ("hover", Tokens.hover, rgba(0xFFFFFF, 0.05), rgba(0x000000, 0.035)),
            ("fill", Tokens.fill, rgba(0xFFFFFF, 0.06), rgba(0x000000, 0.05)),
            ("fill2", Tokens.fill2, rgba(0xFFFFFF, 0.12), rgba(0x000000, 0.1)),
            ("tabOn", Tokens.tabOn, rgba(0x8EC5FF, 0.16), rgba(0xFFFFFF)),
            ("primaryBackground", Tokens.primaryBackground, rgba(0xF5F5F7), rgba(0x1D1D1F)),
            ("primaryForeground", Tokens.primaryForeground, rgba(0x0A0A0C), rgba(0xFFFFFF)),
            ("link", Tokens.link, rgba(0x8EC5FF), rgba(0x0066CC)),
            ("accent", Tokens.accent, rgba(0x8EC5FF), rgba(0x0A84FF)),
            ("need", Tokens.need, rgba(0xFF9F5A), rgba(0xC2410C)),
            ("stuck", Tokens.stuck, rgba(0xFF7B72), rgba(0xC7000F)),
            ("build", Tokens.build, rgba(0x8EC5FF), rgba(0x0058B8)),
            ("review", Tokens.review, rgba(0xF5D76E), rgba(0x946200)),
            ("done", Tokens.done, rgba(0x5CD68A), rgba(0x17803A)),
            ("needBackground", Tokens.needBackground, rgba(0xFF7A2F, 0.08), rgba(0xEA580C, 0.07)),
            ("needLine", Tokens.needLine, rgba(0xFF7A2F, 0.4), rgba(0xEA580C, 0.38)),
            ("stuckBackground", Tokens.stuckBackground, rgba(0xFF453A, 0.09), rgba(0xD70015, 0.06)),
            ("stuckLine", Tokens.stuckLine, rgba(0xFF453A, 0.4), rgba(0xD70015, 0.35)),
            ("buildBackground", Tokens.buildBackground, rgba(0x8EC5FF, 0.12), rgba(0x0066CC, 0.08)),
            ("reviewBackground", Tokens.reviewBackground, rgba(0xF5D76E, 0.11), rgba(0xCA8A04, 0.1)),
            ("doneBackground", Tokens.doneBackground, rgba(0x5CD68A, 0.12), rgba(0x17803A, 0.08)),
            ("doneLine", Tokens.doneLine, rgba(0x5CD68A, 0.35), rgba(0x17803A, 0.3)),
            ("danger", Tokens.danger, rgba(0xFF7B72), rgba(0xC7000F)),
            ("live", Tokens.live, rgba(0x30D158), rgba(0x28A745)),
            ("scrim", Tokens.scrim, rgba(0x000000, 0.55), rgba(0x000000, 0.22)),
            ("shadow", Tokens.shadow, rgba(0x000000, 0.7), rgba(0x000000, 0.16)),
        ]
        for (name, color, dark, light) in table {
            #expect(matches(color, dark: dark, light: light), "\(name)")
        }
    }

    @Test func themeAccentFollowsTheToken() {
        #expect(matches(Theme.accent, dark: rgba(0x8EC5FF), light: rgba(0x0A84FF)))
        #expect(matches(Theme.danger, dark: rgba(0xFF7B72), light: rgba(0xC7000F)))
    }

    @Test func monoIsSFMono() {
        #expect(Tokens.mono(12) == .system(size: 12, weight: .regular, design: .monospaced))
        #expect(Tokens.mono(13, weight: .semibold) == .system(size: 13, weight: .semibold, design: .monospaced))
    }

    @Test func appearanceMapsToAColorScheme() {
        #expect(Appearance.dark.colorScheme == .dark)
        #expect(Appearance.light.colorScheme == .light)
        #expect(Appearance.system.colorScheme == nil)
        #expect(Appearance(rawValue: "light") == .light)
    }
}

struct RobotFaceTests {
    @Test func roleIconsPickTheirFace() {
        #expect(RobotFace.Kind(icon: "lead") == .lead)
        #expect(RobotFace.Kind(icon: "django") == .backend)
        #expect(RobotFace.Kind(icon: "react") == .frontend)
        #expect(RobotFace.Kind(icon: "qa") == .review)
        #expect(RobotFace.Kind(icon: "terminal") == .cli)
        #expect(RobotFace.Kind(icon: "sparkle") == .cli)
    }
}

@MainActor
struct SaturnMarkTests {
    @Test func drawsTheEclipseOnItsTile() throws {
        let renderer = ImageRenderer(content: SaturnMark().frame(width: 200, height: 200))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        func pixel(_ x: Int, _ y: Int) -> NSColor { bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)! }

        #expect(pixel(0, 0).alphaComponent < 0.01)
        #expect(pixel(100, 100).brightnessComponent < 0.05)
        #expect(pixel(107, 121).brightnessComponent > 0.8)
        #expect(pixel(100, 190).alphaComponent > 0.99)
    }
}
