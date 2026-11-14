import EnsembleCore
import EnsembleUI
import SwiftUI

enum CodeStyle {
    static let background = Tokens.code
    static let fontSizeKey = "editor.fontSize"
    static let defaultFontSize = 12.5

    static var fontSize: Double {
        let stored = AppDefaults.store.double(forKey: fontSizeKey)
        return stored > 0 ? stored : defaultFontSize
    }

    static var codeFont: Font { Font.system(size: fontSize, design: .monospaced) }
    static var lineHeight: CGFloat { (fontSize * 1.68).rounded() }
    static let added = Color(hex: 0x7DB6FF)
    static let pin = Color(hex: 0xFF7A2F)
    static let match = Color(hex: 0x5AB0FF)

    static func color(_ kind: CodeToken.Kind) -> Color {
        switch kind {
        case .plain: Tokens.text
        case .keyword: Color.adaptive(dark: 0xFF7AB2, light: 0xAD3DA4)
        case .string: Color.adaptive(dark: 0xFF8170, light: 0xC41A16)
        case .comment: Color.adaptive(dark: 0x7F8C98, light: 0x5D6C79)
        case .number: Color.adaptive(dark: 0xD9C97C, light: 0x1C00CF)
        case .function: Color.adaptive(dark: 0x4EB0CC, light: 0x326D74)
        case .type: Color.adaptive(dark: 0xDABAFF, light: 0x703DAA)
        case .decorator: Color.adaptive(dark: 0xB281EB, light: 0x643820)
        case .heading: Tokens.text
        case .punctuation: Tokens.text2
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
        case "md": return ("MD", Color.white.opacity(0.8), Tokens.fill2)
        case "toml", "yml", "yaml", "json": return (ext.prefix(4).uppercased(), Color(hex: 0xE0A878), Color(red: 192 / 255, green: 138 / 255, blue: 90 / 255).opacity(0.22))
        case "": return ("•", Color.white.opacity(0.7), Tokens.fill2)
        default: return (String(ext.prefix(3)).uppercased(), .white, Tokens.fill2)
        }
    }
}
