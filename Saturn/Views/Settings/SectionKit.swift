import SaturnUI
import SwiftUI

struct SectionButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case dashed
    }

    var kind: Kind = .secondary
    var height: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        SectionButton(configuration: configuration, kind: kind, height: height)
    }

    private struct SectionButton: View {
        let configuration: Configuration
        let kind: Kind
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: height < 30 ? 12 : 12.5, weight: kind == .primary ? .semibold : .regular))
                .foregroundStyle(foreground)
                .lineLimit(1)
                .padding(.horizontal, kind == .dashed ? 10 : 13)
                .frame(height: height)
                .background(background, in: shape)
                .overlay { border }
                .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
                .contentShape(shape)
        }

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: kind == .dashed ? 7 : height / 2, style: .continuous)
        }

        private var foreground: Color {
            switch kind {
            case .primary: Tokens.primaryForeground
            case .secondary: Tokens.text
            case .dashed: Tokens.text2
            }
        }

        private var background: Color {
            switch kind {
            case .primary: Tokens.primaryBackground
            case .secondary, .dashed: configuration.isPressed ? Tokens.hover : .clear
            }
        }

        @ViewBuilder
        private var border: some View {
            switch kind {
            case .primary: EmptyView()
            case .secondary: shape.strokeBorder(Tokens.hair2)
            case .dashed: shape.strokeBorder(Tokens.hair2, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
    }
}

struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(Tokens.link)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(.rect)
    }
}

extension View {
    func sectionCard(radius: CGFloat = 14) -> some View {
        background(Tokens.raised, in: .rect(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Tokens.hair))
    }

    func sectionRow(isFirst: Bool) -> some View {
        padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) {
                if !isFirst { Rectangle().fill(Tokens.hair).frame(height: 1) }
            }
    }

    func sectionField(width: CGFloat? = 320, monospaced: Bool = false) -> some View {
        textFieldStyle(.plain)
            .font(monospaced ? Tokens.mono(12.5) : .system(size: 12.5))
            .padding(.horizontal, 10)
            .frame(width: width, height: 32)
            .background(Tokens.window, in: .rect(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Tokens.hair2))
    }
}

struct SectionSwitch: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Capsule()
                .fill(isOn ? Tokens.done : Tokens.fill2)
                .frame(width: 36, height: 22)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                        .padding(2)
                }
                .animation(.snappy(duration: 0.15), value: isOn)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

struct SectionSegments<Option: Hashable>: View {
    let label: String
    let options: [Option]
    let title: (Option) -> String
    @Binding var selection: Option

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let isOn = option == selection
                Button { selection = option } label: {
                    Text(title(option))
                        .font(.system(size: 12.5))
                        .foregroundStyle(isOn ? Tokens.text : Tokens.text2)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(isOn ? Tokens.raised : .clear, in: .rect(cornerRadius: 7, style: .continuous))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Tokens.fill, in: .rect(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

struct SectionGroupTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Tokens.text2)
            .padding(EdgeInsets(top: 12, leading: 10, bottom: 4, trailing: 10))
            .accessibilityAddTraits(.isHeader)
    }
}
