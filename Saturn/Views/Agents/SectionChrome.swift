import SaturnUI
import SwiftUI

struct SectionIntro<Actions: View>: View {
    @Environment(\.showsScreenHeader) private var showsHeader
    let title: String
    let subtitle: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                if showsHeader {
                    Text(title)
                        .font(.system(size: 22, weight: .semibold))
                        .kerning(-0.3)
                        .accessibilityAddTraits(.isHeader)
                }
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Tokens.text2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) { actions }
                .fixedSize()
        }
    }
}

struct CompactPrimaryPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CompactPill(configuration: configuration, isPrimary: true)
    }
}

struct CompactSecondaryPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CompactPill(configuration: configuration, isPrimary: false)
    }
}

private struct CompactPill: View {
    @Environment(\.isEnabled) private var isEnabled
    let configuration: ButtonStyleConfiguration
    let isPrimary: Bool

    var body: some View {
        configuration.label
            .font(.system(size: 12.5, weight: isPrimary ? .semibold : .regular))
            .foregroundStyle(isPrimary ? Tokens.primaryForeground : Tokens.text)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(isPrimary ? Tokens.primaryBackground : (configuration.isPressed ? Tokens.hover : .clear), in: Capsule())
            .overlay { if !isPrimary { Capsule().strokeBorder(Tokens.hair2) } }
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(Capsule())
    }
}

struct FilterChip: View {
    let title: String
    let count: Int
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                Text("\(count)").foregroundStyle(Tokens.text3)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(isOn ? Tokens.accent : Tokens.text2)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(isOn ? Tokens.selection : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(isOn ? Tokens.accent.opacity(0.34) : Tokens.hair2))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct StatusPill: View {
    let text: String
    let color: Color
    let background: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(text).lineLimit(1)
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(background, in: Capsule())
        .fixedSize()
    }
}

struct TagPill: View {
    let text: String
    let color: Color
    let background: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(background, in: Capsule())
            .fixedSize()
    }
}

extension View {
    func raisedCard(cornerRadius: CGFloat = 14, isSelected: Bool = false) -> some View {
        background(isSelected ? Tokens.selection : Tokens.raised, in: .rect(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(isSelected ? Tokens.accent.opacity(0.34) : Tokens.hair))
    }
}
