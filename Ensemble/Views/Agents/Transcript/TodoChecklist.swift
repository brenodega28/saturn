import EnsembleCore
import EnsembleUI
import SwiftUI

struct TodoChecklist: View {
    let todos: [TodoItem]
    @State private var isCollapsed = false

    var body: some View {
        let done = todos.filter { $0.status == .completed }.count
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isCollapsed.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checklist").font(.system(size: 12)).foregroundStyle(Theme.link).accessibilityHidden(true)
                    Text("Todos").font(.system(size: 12, weight: .semibold))
                    Text("\(done) of \(todos.count) done").font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Theme.secondaryText)
                    if isCollapsed, let current = todos.first(where: { $0.status == .inProgress }) {
                        Text("· \(current.activeForm ?? current.content)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                        .foregroundStyle(Theme.tertiaryText)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
            if !isCollapsed {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                            TodoRow(todo: todo)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: 16)
    }
}

private struct TodoRow: View {
    let todo: TodoItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon.frame(width: 14)
            Text(todo.status == .inProgress ? (todo.activeForm ?? todo.content) : todo.content)
                .font(.system(size: 12.5, weight: todo.status == .inProgress ? .semibold : .regular))
                .foregroundStyle(todo.status == .completed ? Theme.tertiaryText : Theme.primaryText)
                .strikethrough(todo.status == .completed, color: Theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(label)
    }

    @ViewBuilder
    private var icon: some View {
        switch todo.status {
        case .pending:
            Image(systemName: "circle").font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
        case .inProgress:
            Image(systemName: "circle.dotted.circle").font(.system(size: 11)).foregroundStyle(Theme.accent)
                .symbolEffect(.pulse)
        case .completed:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.successText)
        }
    }

    private var label: String {
        switch todo.status {
        case .pending: "Pending"
        case .inProgress: "In progress"
        case .completed: "Completed"
        }
    }
}
