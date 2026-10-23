import EnsembleCore
import EnsembleUI
import SwiftUI

enum CodeStyle {
    static let background = Color(hex: 0x141416)
    static let codeFont = Font.system(size: 12.5, design: .monospaced)
    static let lineHeight: CGFloat = 21
    static let added = Color(hex: 0x7DB6FF)
    static let pin = Color(hex: 0xFF7A2F)
    static let match = Color(hex: 0x5AB0FF)

    static func color(_ kind: CodeToken.Kind) -> Color {
        switch kind {
        case .plain: Color(hex: 0xE4E4E7)
        case .keyword: Color(hex: 0xFF7AB2)
        case .string: Color(hex: 0xFF8170)
        case .comment: Color(hex: 0x7F8C98)
        case .number: Color(hex: 0xD9C97C)
        case .function: Color(hex: 0x4EB0CC)
        case .type: Color(hex: 0xDABAFF)
        case .decorator: Color(hex: 0xB281EB)
        case .heading: .white
        case .punctuation: Color(hex: 0xE4E4E7).opacity(0.75)
        }
    }

    static func highlighted(_ line: String, language: CodeLanguage) -> AttributedString {
        var result = AttributedString()
        for token in CodeTokenizer.tokens(line, language: language) {
            var part = AttributedString(token.text)
            part.foregroundColor = color(token.kind)
            switch token.kind {
            case .keyword, .function, .heading: part.font = .system(size: 12.5, weight: .semibold, design: .monospaced)
            case .comment: part.font = .system(size: 12.5, design: .monospaced).italic()
            default: break
            }
            result += part
        }
        return result
    }

    static func marked(_ text: String, matches: [Int], base: Color, size: CGFloat) -> AttributedString {
        let set = Set(matches)
        var result = AttributedString()
        for (offset, character) in text.enumerated() {
            var part = AttributedString(String(character))
            let isMatch = set.contains(offset)
            part.foregroundColor = isMatch ? match : base
            part.font = .system(size: size, weight: isMatch ? .bold : .regular, design: .monospaced)
            result += part
        }
        return result
    }

    static func changeColor(_ status: CodeFileStatus) -> Color {
        status == .added ? added : Theme.successText
    }
}

struct FileBadge: View {
    let path: String
    var size: CGFloat = 16

    var body: some View {
        let style = Self.style(for: path)
        Text(style.label)
            .font(.system(size: size * 0.47, weight: .bold, design: .monospaced))
            .foregroundStyle(style.foreground)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(width: size, height: size)
            .background(style.background, in: .rect(cornerRadius: size / 4, style: .continuous))
            .accessibilityHidden(true)
    }

    static func style(for path: String) -> (label: String, foreground: Color, background: Color) {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "py": return ("PY", Color(hex: 0x7DB6FF), Color(red: 75 / 255, green: 139 / 255, blue: 190 / 255).opacity(0.25))
        case "ts", "tsx", "js", "jsx": return (ext.uppercased(), Color(hex: 0x5CCBF5), Color(red: 92 / 255, green: 203 / 255, blue: 245 / 255).opacity(0.2))
        case "swift": return ("SW", Color(hex: 0xFF8A5C), Color(hex: 0xFF8A5C).opacity(0.18))
        case "md": return ("MD", Color.white.opacity(0.8), Color.white.opacity(0.1))
        case "toml", "yml", "yaml", "json": return (ext.prefix(4).uppercased(), Color(hex: 0xE0A878), Color(red: 192 / 255, green: 138 / 255, blue: 90 / 255).opacity(0.22))
        case "": return ("•", Color.white.opacity(0.7), Color.white.opacity(0.1))
        default: return (String(ext.prefix(3)).uppercased(), .white, Color.white.opacity(0.1))
        }
    }
}
