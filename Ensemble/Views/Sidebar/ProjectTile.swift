import EnsembleCore
import EnsembleUI
import SwiftUI

struct ProjectTile: View {
    let project: Project
    var size: CGFloat = 20

    private static let palette: [(top: UInt32, bottom: UInt32)] = [
        (0x4A90FF, 0x1F5FD1),
        (0xB57BFF, 0x7B3FD9),
        (0x5AD8C4, 0x1A8F80),
        (0xFFB547, 0xD9822B),
        (0xFF7A9A, 0xD13F63),
    ]

    var body: some View {
        let colors = Self.palette[Int(abs(project.id ?? 0) % Int64(Self.palette.count))]
        Text(project.name.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: letterSize, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [Color(hex: colors.top), Color(hex: colors.bottom)], startPoint: .top, endPoint: .bottom),
                in: .rect(cornerRadius: cornerRadius, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    private var letterSize: CGFloat {
        size < 20 ? 9.5 : size > 20 ? 12 : 11
    }

    private var cornerRadius: CGFloat {
        size < 20 ? 4 : size > 20 ? 7 : 6
    }
}

extension ProjectOutline.Tone {
    var color: Color {
        switch self {
        case .quiet: Theme.tertiaryText
        case .warning: Theme.warning
        case .danger: Theme.danger
        }
    }
}
