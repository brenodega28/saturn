import AppKit
import SwiftUI
import Testing
@testable import EnsembleUI

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

    @Test func tokensResolveToTheirDarkAndLightValues() {
        #expect(resolved(Tokens.window, .darkAqua) == (0, 0, 0, 1))
        #expect(resolved(Tokens.window, .aqua) == (255, 255, 255, 1))
        #expect(resolved(Tokens.text, .darkAqua) == (245, 245, 247, 1))
        #expect(resolved(Tokens.text, .aqua) == (29, 29, 31, 1))
        #expect(resolved(Tokens.need, .aqua) == (194, 65, 12, 1))
    }

    @Test func translucentTokensKeepTheirAlpha() {
        let dark = resolved(Tokens.selection, .darkAqua)
        let light = resolved(Tokens.selection, .aqua)
        #expect(dark.red == 255 && abs(dark.alpha - 0.08) < 0.001)
        #expect(light.red == 0 && abs(light.alpha - 0.06) < 0.001)
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
