import AppKit
import EnsembleUI
import SwiftUI

enum V4 {
    static let container = Color(hex: 0x1A1A1E)
    static let sidebarFill = Color(red: 46 / 255, green: 47 / 255, blue: 52 / 255).opacity(0.6)
    static let logFill = Color(hex: 0x141417)
    static let label = Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255)
    static let secondary = label.opacity(0.62)
    static let selected = Color(hex: 0x0A84FF).opacity(0.24)
    static let blue = Color(hex: 0x0A84FF)
    static let link = Color(hex: 0x9CC6FF)
    static let orange = Color(hex: 0xFF7A2F)
    static let orangeText = Color(hex: 0xFF9A5C)
    static let onOrange = Color(hex: 0x1A0E05)
    static let green = Color(hex: 0x30D158)
    static let greenText = Color(hex: 0x4BD97B)
    static let onGreen = Color(hex: 0x04210D)
    static let red = Color(hex: 0xFF453A)
    static let stopFill = red.opacity(0.18)
    static let youGradient = LinearGradient(colors: [Color(hex: 0x8E96A8), Color(hex: 0x4D5466)], startPoint: .top, endPoint: .bottom)
    static let denied = Color(hex: 0xFF8A80)
    static let code = Color(hex: 0x111114)
    static let leadGradient = LinearGradient(colors: [Color(hex: 0xBE86FF), Color(hex: 0x7B3FD9)], startPoint: .top, endPoint: .bottom)
    static let railsGradient = LinearGradient(colors: [Color(hex: 0x5B6475), Color(hex: 0x2F3542)], startPoint: .top, endPoint: .bottom)
    static let mono = "JetBrains Mono"

    static func monospaced(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if NSFont(name: mono, size: size) != nil {
            return .custom(mono, size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .monospaced)
    }

    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold).width(.expanded)
    }
}

enum V4Glyph {
    case laptop
    case chat
    case inbox
    case changes
    case search
    case agents
    case tasks
    case workflows
    case code
    case usage
    case settings
    case back
    case send

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        var path = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }
        func line(_ points: (CGFloat, CGFloat)...) {
            guard let first = points.first else { return }
            path.move(to: point(first.0, first.1))
            for next in points.dropFirst() { path.addLine(to: point(next.0, next.1)) }
        }
        func circle(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) {
            path.addEllipse(in: CGRect(x: rect.minX + (x - radius) * scale, y: rect.minY + (y - radius) * scale, width: radius * 2 * scale, height: radius * 2 * scale))
        }
        func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
            path.addRect(CGRect(x: rect.minX + x * scale, y: rect.minY + y * scale, width: width * scale, height: height * scale))
        }
        func arc(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat, from start: Double, to end: Double) {
            path.addArc(center: point(x, y), radius: radius * scale, startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
        }
        switch self {
        case .laptop:
            box(4, 6, 16, 10)
            line((2, 19), (22, 19))
        case .chat:
            line((4, 5), (20, 5), (20, 16), (9, 16), (4, 20), (4, 5))
        case .inbox:
            line((3, 13), (6, 5), (18, 5), (21, 13), (21, 19), (3, 19), (3, 13))
            line((3, 13), (8, 13), (9, 15), (15, 15), (16, 13), (21, 13))
        case .changes:
            line((12, 4), (12, 12))
            line((8, 8), (16, 8))
            line((8, 18), (16, 18))
        case .search:
            circle(11, 11, 7)
            line((20, 20), (16, 16))
        case .agents:
            circle(9, 8, 3)
            path.move(to: point(3, 20))
            arc(9, 20, 6, from: 180, to: 360)
            path.move(to: point(16, 5.2))
            arc(16, 8, 2.8, from: -90, to: 90)
            path.move(to: point(17.5, 14.2))
            path.addQuadCurve(to: point(21, 20), control: point(21, 15.5))
        case .tasks:
            path.addRoundedRect(in: CGRect(x: rect.minX + 4 * scale, y: rect.minY + 4 * scale, width: 16 * scale, height: 16 * scale), cornerSize: CGSize(width: 3 * scale, height: 3 * scale))
            line((8.5, 12), (11, 14.5), (15.5, 9.5))
        case .workflows:
            box(4, 3, 6, 6)
            box(14, 15, 6, 6)
            line((7, 9), (7, 13), (17, 13), (17, 15))
        case .code:
            line((8, 7), (3, 12), (8, 17))
            line((16, 7), (21, 12), (16, 17))
        case .usage:
            line((4, 20), (4, 10))
            line((10, 20), (10, 4))
            line((16, 20), (16, 13))
            line((22, 20), (2, 20))
        case .settings:
            circle(12, 12, 3)
            line((12, 3), (12, 6))
            line((12, 18), (12, 21))
            line((3, 12), (6, 12))
            line((18, 12), (21, 12))
        case .back:
            line((15, 5), (8, 12), (15, 19))
        case .send:
            line((12, 19), (12, 5))
            line((5, 12), (12, 5), (19, 12))
        }
        return path
    }
}

struct V4Icon: View {
    let glyph: V4Glyph
    var size: CGFloat = 15
    var lineWidth: CGFloat = 1.8

    var body: some View {
        StrokedGlyph(glyph: glyph)
            .stroke(style: StrokeStyle(lineWidth: lineWidth * size / 24, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct StrokedGlyph: Shape {
    let glyph: V4Glyph

    func path(in rect: CGRect) -> Path {
        glyph.path(in: rect)
    }
}

struct V4Pill: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case orange
        case quiet
        case deny
    }

    var kind: Kind = .secondary
    var height: CGFloat = 30
    var horizontalPadding: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: weight))
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(background, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }

    private var weight: Font.Weight {
        switch kind {
        case .primary: .semibold
        case .orange: .bold
        case .secondary, .quiet, .deny: .regular
        }
    }

    private var foreground: Color {
        switch kind {
        case .orange: V4.onOrange
        case .deny: V4.denied
        case .primary, .secondary, .quiet: .white
        }
    }

    private var background: Color {
        switch kind {
        case .primary: V4.blue
        case .orange: V4.orange
        case .secondary: .white.opacity(0.1)
        case .quiet, .deny: .clear
        }
    }
}

struct V4StatusPill: View {
    let text: String
    let foreground: Color
    let background: Color
    var height: CGFloat = 30

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .frame(height: height)
            .background(background, in: Capsule())
    }
}
