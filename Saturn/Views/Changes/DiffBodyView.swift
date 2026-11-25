import SaturnCore
import SaturnUI
import SwiftUI

enum DiffPalette {
    static let addedBackground = Tokens.doneBackground
    static let removedBackground = Tokens.stuckBackground
    static let addedSign = Tokens.done
    static let removedSign = Tokens.danger
    static let emptySide = Tokens.hover
    static let hunkText = Tokens.text3
    static let hunkBackground = Tokens.fill
    static let pin = Tokens.review
    static let pinTitle = Tokens.review
    static let pinCard = Tokens.reviewBackground
    static let pinLine = Tokens.review.opacity(0.3)
    static let lineNumber = Tokens.text3
    static let cardBackground = Tokens.raised
    static let conflict = Tokens.danger
    static let selection = Tokens.selection

    static func background(_ kind: PatchLine.Kind) -> Color {
        switch kind {
        case .added: addedBackground
        case .removed: removedBackground
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

struct DiffBodyView<PinContent: View, ComposerContent: View>: View {
    let rows: DiffRows
    let layout: DiffLayout
    let language: CodeLanguage
    let selection: LineSelection?
    let onSelectLine: (LineTarget, Bool) -> Void
    @ViewBuilder let pinContent: (Pin) -> PinContent
    @ViewBuilder let composer: () -> ComposerContent

    private static var codeFont: Font { Tokens.mono(12) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch layout {
            case .unified:
                let composerRowID = lastSelectedUnifiedRowID
                ForEach(rows.unified) { row in
                    unifiedRow(row)
                    if row.id == composerRowID { composer() }
                }
            case .split:
                let composerRowID = lastSelectedSplitRowID
                ForEach(rows.split) { row in
                    splitRow(row)
                    if row.id == composerRowID { composer() }
                }
            }
        }
        .font(Self.codeFont)
        .textSelection(.enabled)
    }

    private var lastSelectedUnifiedRowID: Int? {
        guard let selection else { return nil }
        return rows.unified.last { row in
            if case .line(let line, _) = row.content { return selection.contains(line) }
            return false
        }?.id
    }

    private var lastSelectedSplitRowID: Int? {
        guard let selection else { return nil }
        return rows.split.last { row in
            if case .pair(let left, let right) = row.content {
                return [left, right].contains { side in side.map { selection.contains($0.line) } ?? false }
            }
            return false
        }?.id
    }

    private func isSelected(_ line: PatchLine) -> Bool {
        selection?.contains(line) ?? false
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
                lineNumber(line.kind == .removed ? line.oldLine : line.newLine, width: 48)
                    .modifier(LineGutterTap(target: line.commentTarget, onSelect: onSelectLine))
                signView(line.kind, width: 16)
                codeText(line)
            }
            .background(DiffPalette.background(line.kind))
            .background(isSelected(line) ? DiffPalette.selection : .clear)
            .overlay(alignment: .leading) { marker(pinned) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText(line))
            .accessibilityAddTraits(isSelected(line) ? .isSelected : [])
            .accessibilityAction(named: "Comment on this line") {
                if let target = line.commentTarget { onSelectLine(target, false) }
            }
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
                Rectangle().fill(Tokens.hair).frame(width: 1)
                splitSide(right, isLeft: false)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func splitSide(_ side: SplitSide?, isLeft: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if let side {
                lineNumber(isLeft ? side.line.oldLine : side.line.newLine, width: 48)
                    .modifier(LineGutterTap(target: side.line.commentTarget, onSelect: onSelectLine))
                signView(side.line.kind, width: 16)
                codeText(side.line)
            } else {
                Color.clear.frame(width: 64)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(side.map { DiffPalette.background($0.line.kind) } ?? DiffPalette.emptySide)
        .background(side.map { isSelected($0.line) } == true ? DiffPalette.selection : .clear)
        .overlay(alignment: .leading) { marker(side?.pinned == true) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(side.map { accessibilityText($0.line) } ?? "No line")
        .accessibilityAddTraits(side.map { isSelected($0.line) } == true ? .isSelected : [])
        .accessibilityAction(named: "Comment on this line") {
            if let target = side?.line.commentTarget { onSelectLine(target, false) }
        }
    }

    private func hunkHeader(_ header: String) -> some View {
        Text(header)
            .font(Tokens.mono(11.5))
            .foregroundStyle(DiffPalette.hunkText)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, 64)
            .padding(.trailing, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DiffPalette.hunkBackground)
    }

    private func lineNumber(_ number: Int?, width: CGFloat) -> some View {
        Text(number.map(String.init) ?? "")
            .foregroundStyle(DiffPalette.lineNumber)
            .padding(.trailing, 10)
            .frame(width: width, alignment: .trailing)
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.vertical, 3)
            .accessibilityHidden(true)
    }

    private func signView(_ kind: PatchLine.Kind, width: CGFloat) -> some View {
        let (sign, color) = DiffPalette.sign(kind)
        return Text(sign)
            .foregroundStyle(color)
            .frame(width: width, alignment: .leading)
            .padding(.vertical, 3)
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
        .padding(.vertical, 3)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func marker(_ pinned: Bool) -> some View {
        if pinned {
            Rectangle().fill(DiffPalette.pin).frame(width: 2)
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

struct LineGutterTap: ViewModifier {
    let target: LineTarget?
    let onSelect: (LineTarget, Bool) -> Void

    func body(content: Content) -> some View {
        if let target {
            content
                .contentShape(Rectangle())
                .textSelection(.disabled)
                .onTapGesture { onSelect(target, NSEvent.modifierFlags.contains(.shift)) }
                .pointerStyle(.link)
                .help("Click to comment on this line. Shift-click to extend the selection.")
        } else {
            content
        }
    }
}
