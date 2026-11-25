import SwiftUI

public struct StatusDot: View {
    private let color: Color
    private let size: CGFloat

    public init(_ color: Color, size: CGFloat = 7) {
        self.color = color
        self.size = size
    }

    public var body: some View {
        Circle().fill(color).frame(width: size, height: size).accessibilityHidden(true)
    }
}

public struct SectionLabel: View {
    private let title: String

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.secondaryText)
    }
}

public struct CardBackground: ViewModifier {
    let cornerRadius: CGFloat

    public func body(content: Content) -> some View {
        content
            .background(Theme.fill, in: .rect(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Theme.hairline))
    }
}

extension View {
    public func card(cornerRadius: CGFloat = 20) -> some View {
        modifier(CardBackground(cornerRadius: cornerRadius))
    }
}

public struct CapsuleTabs<Tab: Hashable & Identifiable>: View {
    private let tabs: [Tab]
    private let title: (Tab) -> String
    @Binding private var selection: Tab
    @Namespace private var highlight

    public init(_ tabs: [Tab], selection: Binding<Tab>, title: @escaping (Tab) -> String) {
        self.tabs = tabs
        self._selection = selection
        self.title = title
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                let isSelected = tab == selection
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection = tab }
                } label: {
                    Text(title(tab))
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.white : Theme.secondaryText)
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background {
                            if isSelected {
                                Capsule().fill(Theme.fillSelected).matchedGeometryEffect(id: "highlight", in: highlight)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.fillRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.06)))
    }
}

public struct EmptyState<Actions: View>: View {
    private let title: String
    private let message: String
    private let actions: Actions

    public init(_ title: String, message: String, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title
        self.message = message
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                dashedTile(Color(hex: 0x3FD487))
                dashedTile(Color(hex: 0xBE86FF)).offset(y: -10)
                dashedTile(Color(hex: 0x5CCBF5))
            }
            .accessibilityHidden(true)
            Text(title).font(.system(size: 20, weight: .bold))
            Text(message)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 440)
            HStack(spacing: 8) { actions }
        }
        .padding(.vertical, 80)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func dashedTile(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(color.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .frame(width: 56, height: 56)
    }
}

public struct PillButtonStyle: ButtonStyle {
    public enum Kind: Sendable {
        case primary
        case secondary
    }

    private let kind: Kind
    private let height: CGFloat

    public init(_ kind: Kind = .secondary, height: CGFloat = 34) {
        self.kind = kind
        self.height = height
    }

    public func makeBody(configuration: Configuration) -> some View {
        PillButton(configuration: configuration, kind: kind, height: height)
    }

    private struct PillButton: View {
        let configuration: Configuration
        let kind: Kind
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: kind == .primary ? .semibold : .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(minHeight: height)
                .background(kind == .primary ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.1)), in: Capsule())
                .overlay(alignment: .top) {
                    if kind == .primary {
                        Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.25), .clear], startPoint: .top, endPoint: .center))
                    }
                }
                .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
                .contentShape(Capsule())
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    public static var pill: PillButtonStyle { PillButtonStyle() }
    public static var primaryPill: PillButtonStyle { PillButtonStyle(.primary) }
}
