import EnsembleCore
import EnsembleUI
import SwiftUI

struct TokenEditor: View {
    @Binding var items: [String]
    let placeholder: String
    let suggestions: [String]
    var missing: Set<String> = []
    @State private var entry = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !items.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(items, id: \.self) { item in
                        let isMissing = missing.contains(item)
                        HStack(spacing: 4) {
                            if isMissing {
                                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).accessibilityLabel("Missing")
                            }
                            Text(item).font(.system(size: 12, design: .monospaced))
                            Button {
                                items.removeAll { $0 == item }
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(item)")
                            .help("Remove \(item)")
                        }
                        .foregroundStyle(isMissing ? Color(hex: 0xFFC36B) : Theme.primaryText)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(isMissing ? Theme.warning.opacity(0.1) : Color.black.opacity(0.25), in: .rect(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(isMissing ? Theme.warning.opacity(0.4) : Color.white.opacity(0.1)))
                    }
                }
            }
            HStack(spacing: 6) {
                TextField(placeholder, text: $entry)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                let available = suggestions.filter { !items.contains($0) }
                if !available.isEmpty {
                    Menu {
                        ForEach(available, id: \.self) { suggestion in
                            Button(suggestion) { items.append(suggestion) }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Pick from the project")
                    .accessibilityLabel("Pick from the project")
                }
                Button("Add", action: add)
                    .disabled(entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func add() {
        let value = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !items.contains(value) else { return }
        items.append(value)
        entry = ""
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(width: width, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: width.isFinite ? width : widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = fittedSize(of: subviews[index], width: bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private func fittedSize(of subview: LayoutSubview, width: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        guard width.isFinite, ideal.width > width else { return ideal }
        return subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = fittedSize(of: subviews[index], width: width)
            if !current.indices.isEmpty, current.width + spacing + size.width > width {
                let next = current.y + current.height + spacing
                rows.append(current)
                current = Row(y: next)
            }
            current.width += (current.indices.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
