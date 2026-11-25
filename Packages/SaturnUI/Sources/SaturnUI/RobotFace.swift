import SwiftUI

public struct RobotFace: View {
    public enum Kind: String, CaseIterable, Sendable {
        case lead
        case backend
        case frontend
        case cli
        case review

        public init(icon: String) {
            switch icon {
            case "lead", "compass": self = .lead
            case "reviewer", "review", "qa", "test": self = .review
            case "django", "database", "backend": self = .backend
            case "react", "frontend", "web": self = .frontend
            default: self = .cli
            }
        }

        public var body: Color {
            switch self {
            case .lead: Color(hex: 0x8E5BEA)
            case .backend: Color(hex: 0x26A866)
            case .frontend: Color(hex: 0x2F97CF)
            case .cli: Color(hex: 0xCF6E50)
            case .review: Color(hex: 0xE0952A)
            }
        }

        public var eyes: Color {
            switch self {
            case .lead: Color(hex: 0xE7D6FF)
            case .backend: Color(hex: 0xC9F7DD)
            case .frontend: Color(hex: 0xD3F2FF)
            case .cli: Color(hex: 0xFFE0D3)
            case .review: Color(hex: 0xFFEBC8)
            }
        }

        func badge(in path: inout Path) {
            switch self {
            case .lead:
                path.move(to: CGPoint(x: -3.6, y: 1.8))
                path.addLine(to: CGPoint(x: 0, y: -1.8))
                path.addLine(to: CGPoint(x: 3.6, y: 1.8))
            case .backend:
                path.addRect(CGRect(x: -2.6, y: -2.6, width: 5.2, height: 5.2))
            case .frontend:
                path.addEllipse(in: CGRect(x: -2.8, y: -2.8, width: 5.6, height: 5.6))
            case .cli:
                path.move(to: CGPoint(x: -1, y: -2.6))
                path.addLine(to: CGPoint(x: -3.4, y: 0))
                path.addLine(to: CGPoint(x: -1, y: 2.6))
                path.move(to: CGPoint(x: 1, y: -2.6))
                path.addLine(to: CGPoint(x: 3.4, y: 0))
                path.addLine(to: CGPoint(x: 1, y: 2.6))
            case .review:
                path.move(to: CGPoint(x: -3, y: 0.2))
                path.addLine(to: CGPoint(x: -1, y: 2.2))
                path.addLine(to: CGPoint(x: 3, y: -2))
            }
        }
    }

    public static let failing = Color(hex: 0xFF8A80)

    let kind: Kind
    let size: CGFloat
    let isFailing: Bool
    let lookingAside: Bool

    public init(kind: Kind, size: CGFloat = 20, isFailing: Bool = false, lookingAside: Bool = false) {
        self.kind = kind
        self.size = size
        self.isFailing = isFailing
        self.lookingAside = lookingAside
    }

    public var body: some View {
        Canvas { context, canvas in
            let scale = canvas.width / 64
            context.scaleBy(x: scale, y: scale)
            let shell = Path(roundedRect: CGRect(x: 5, y: 6, width: 54, height: 52), cornerRadius: 15)
            context.fill(shell, with: .color(isFailing ? Self.failing : kind.body))
            context.fill(shell, with: .linearGradient(
                Gradient(stops: [.init(color: .white.opacity(0.28), location: 0), .init(color: .white.opacity(0), location: 0.6)]),
                startPoint: CGPoint(x: 32, y: 6), endPoint: CGPoint(x: 32, y: 58)
            ))
            context.fill(Path(roundedRect: CGRect(x: 11, y: 12, width: 42, height: 30), cornerRadius: 8), with: .color(Color(hex: 0x0B1318)))
            let shift: CGFloat = lookingAside ? 2 : 0
            for x in [21.5, 37.5] {
                context.fill(Path(roundedRect: CGRect(x: x + shift, y: 22.5, width: 5, height: 7), cornerRadius: 2.5), with: .color(kind.eyes))
            }
            var mouth = Path()
            mouth.move(to: CGPoint(x: 28, y: 34.5))
            mouth.addLine(to: CGPoint(x: 36, y: 34.5))
            context.stroke(mouth, with: .color(kind.eyes.opacity(0.7)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            var badge = Path()
            kind.badge(in: &badge)
            context.stroke(
                badge.applying(CGAffineTransform(translationX: 32, y: 50)), with: .color(.white),
                style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
