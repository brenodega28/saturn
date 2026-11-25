import SwiftUI

public struct SaturnMark: View {
    public init() {}

    public var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 100
            context.translateBy(x: (size.width - 100 * scale) / 2, y: (size.height - 100 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            Self.draw(in: context, glowRadius: 2.2 * scale)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Saturn")
    }

    static let rim = Gradient(stops: [
        .init(color: Color(hex: 0xFFFFFF), location: 0),
        .init(color: Color(hex: 0x9CC6FF).opacity(0.6), location: 0.45),
        .init(color: Color(hex: 0x9CC6FF).opacity(0), location: 1),
    ])

    static let planet = Path(ellipseIn: CGRect(x: 30, y: 30, width: 40, height: 40))

    static func ring(front: Bool) -> Path {
        Path { path in
            path.addArc(center: .zero, radius: 1, startAngle: .degrees(180), endAngle: .degrees(front ? 0 : 360), clockwise: front)
        }
        .applying(CGAffineTransform(translationX: 50, y: 50).scaledBy(x: 38, y: 11))
    }

    static func draw(in context: GraphicsContext, glowRadius: CGFloat) {
        let tile = Path(roundedRect: CGRect(x: 2, y: 2, width: 96, height: 96), cornerRadius: 22.5)
        context.fill(tile, with: .linearGradient(Gradient(colors: [Color(hex: 0x17171A), .black]), startPoint: CGPoint(x: 50, y: 2), endPoint: CGPoint(x: 50, y: 98)))
        context.stroke(Path(roundedRect: CGRect(x: 2.5, y: 2.5, width: 95, height: 95), cornerRadius: 22), with: .color(.white.opacity(0.14)), lineWidth: 1)

        var tilted = context
        tilted.translateBy(x: 50, y: 50)
        tilted.rotate(by: .degrees(-18))
        tilted.translateBy(x: -50, y: -50)
        let rimShading = GraphicsContext.Shading.linearGradient(rim, startPoint: CGPoint(x: 70, y: 30), endPoint: CGPoint(x: 30, y: 70))

        tilted.stroke(ring(front: false), with: .color(Color(hex: 0x9CC6FF).opacity(0.5)), lineWidth: 1.6)
        tilted.drawLayer { glow in
            glow.addFilter(.blur(radius: glowRadius))
            glow.stroke(planet, with: rimShading, lineWidth: 3)
        }
        tilted.fill(planet, with: .color(.black))
        tilted.stroke(planet, with: rimShading, lineWidth: 1.4)
        tilted.stroke(ring(front: true), with: .color(Color(hex: 0xCFE3FF)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
    }
}

public struct SaturnWordmark: View {
    private let size: CGFloat

    public init(size: CGFloat = 34) {
        self.size = size
    }

    public var body: some View {
        Text("Saturn")
            .font(.system(size: size, weight: .bold))
            .tracking(-0.03 * size)
    }
}
