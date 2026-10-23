import EnsembleCore
import EnsembleUI
import SwiftUI

enum DiffPalette {
    static let addedBackground = Color(red: 46 / 255, green: 160 / 255, blue: 67 / 255).opacity(0.14)
    static let addedGutter = Color(red: 46 / 255, green: 160 / 255, blue: 67 / 255).opacity(0.24)
    static let removedBackground = Color(red: 248 / 255, green: 81 / 255, blue: 73 / 255).opacity(0.13)
    static let removedGutter = Color(red: 248 / 255, green: 81 / 255, blue: 73 / 255).opacity(0.22)
    static let addedSign = Color(hex: 0x4BD97B)
    static let removedSign = Color(hex: 0xFF7A85)
    static let emptySide = Color.white.opacity(0.025)
    static let hunkText = Color(red: 160 / 255, green: 190 / 255, blue: 1).opacity(0.85)
    static let hunkBackground = Color(red: 56 / 255, green: 139 / 255, blue: 253 / 255).opacity(0.08)
    static let pin = Color(hex: 0xFFD60A)
    static let pinTitle = Color(hex: 0xFFE266)
    static let pinCard = Color(hex: 0x24231C)
    static let lineNumber = Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(0.45)
    static let cardBackground = Color(hex: 0x141417)
    static let conflict = Color(hex: 0xFF8A80)

    static func background(_ kind: PatchLine.Kind) -> Color {
        switch kind {
        case .added: addedBackground
        case .removed: removedBackground
        case .context: .clear
        }
    }

    static func gutter(_ kind: PatchLine.Kind) -> Color {
        switch kind {
        case .added: addedGutter
        case .removed: removedGutter
        case .context: .clear
        }
    }

    static func sign(_ kind: PatchLine.Kind) -> (String, Color) {
        switch kind {
        case .added: ("+", addedSign)
        case .removed: ("−", removedSign)
        case .context: ("", .clear)
        }
    }
}

struct DiffBodyView<PinContent: View>: View {
    let rows: DiffRows
    let layout: DiffLayout
    let language: CodeLanguage
    @ViewBuilder let pinContent: (Pin) -> PinContent

    private static var codeFont: Font { .system(size: 12.5, design: .monospaced) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch layout {
            case .unified:
                ForEach(rows.unified) { row in unifiedRow(row) }
            case .split:
                ForEach(rows.split) { row in splitRow(row) }
            }
        }
        .font(Self.codeFont)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func unifiedRow(_ row: UnifiedRow) -> some View {
        switch row.content {
        case .hunk(let header):
            hunkHeader(header)
        case .pin(let pin):
            pinContent(pin)
        case .line(let line, let pinned):
            HStack(alignment: .top, spacing: 0) {
                lineNumber(line.oldLine, kind: line.kind, width: 52)
                lineNumber(line.newLine, kind: line.kind, width: 52)
                signView(line.kind, width: 24)
                codeText(line)
            }
            .background(DiffPalette.background(line.kind))
            .overlay(alignment: .leading) { marker(pinned) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText(line))
        }
    }

    @ViewBuilder
    private func splitRow(_ row: SplitRow) -> some View {
        switch row.content {
        case .hunk(let header):
            hunkHeader(header)
        case .pin(let pin):
            pinContent(pin)
        case .pair(let left, let right):
            HStack(alignment: .top, spacing: 0) {
                splitSide(left, isLeft: true)
                Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1)
                splitSide(right, isLeft: false)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func splitSide(_ side: SplitSide?, isLeft: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if let side {
                lineNumber(isLeft ? side.line.oldLine : side.line.newLine, kind: side.line.kind, width: 48)
                signView(side.line.kind, width: 22)
                codeText(side.line)
            } else {
                Color.clear.frame(width: 70)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(side.map { DiffPalette.background($0.line.kind) } ?? DiffPalette.emptySide)
        .overlay(alignment: .leading) { marker(side?.pinned == true) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(side.map { accessibilityText($0.line) } ?? "No line")
    }

    private func hunkHeader(_ header: String) -> some View {
        Text(header)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(DiffPalette.hunkText)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DiffPalette.hunkBackground)
    }

    private func lineNumber(_ number: Int?, kind: PatchLine.Kind, width: CGFloat) -> some View {
        Text(number.map(String.init) ?? "")
            .foregroundStyle(DiffPalette.lineNumber)
            .padding(.trailing, 10)
            .frame(width: width, alignment: .trailing)
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.vertical, 2)
            .background(DiffPalette.gutter(kind))
            .accessibilityHidden(true)
    }

    private func signView(_ kind: PatchLine.Kind, width: CGFloat) -> some View {
        let (sign, color) = DiffPalette.sign(kind)
        return Text(sign)
            .foregroundStyle(color)
            .frame(width: width)
            .padding(.vertical, 2)
            .accessibilityHidden(true)
    }

    private func codeText(_ line: PatchLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(line.text.isEmpty ? AttributedString(" ") : CodeStyle.highlighted(line.text, language: language))
                .fixedSize(horizontal: false, vertical: true)
            if line.missingNewlineAtEnd {
                Image(systemName: "return")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DiffPalette.removedSign)
                    .help("No newline at end of file")
                    .accessibilityLabel("No newline at end of file")
            }
        }
        .padding(.vertical, 2)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func marker(_ pinned: Bool) -> some View {
        if pinned {
            Rectangle().fill(DiffPalette.pin).frame(width: 3)
        }
    }

    private func accessibilityText(_ line: PatchLine) -> String {
        let prefix = switch line.kind {
        case .added: "Added line \(line.newLine ?? 0)"
        case .removed: "Removed line \(line.oldLine ?? 0)"
        case .context: "Line \(line.newLine ?? 0)"
        }
        return "\(prefix): \(line.text)"
    }
}
