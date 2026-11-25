import SaturnUI
import SwiftUI

struct ProportionBar: View {
    let fraction: Double
    var color: Color = Theme.accent
    var height: CGFloat = 6

    var body: some View {
        Capsule()
            .fill(Tokens.fill2)
            .frame(height: height)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    let clamped = max(0, min(fraction, 1))
                    Capsule()
                        .fill(color)
                        .frame(width: clamped > 0 ? max(height, proxy.size.width * clamped) : 0)
                }
            }
            .clipShape(Capsule())
    }
}
