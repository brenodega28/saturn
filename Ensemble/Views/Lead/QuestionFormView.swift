import EnsembleCore
import EnsembleUI
import SwiftUI

struct QuestionFormView<Accessory: View>: View {
    let form: QuestionForm
    let recipient: String?
    var compact = false
    let send: (String) -> Void
    @ViewBuilder let accessory: Accessory

    @State private var step = 0
    @State private var answers: [String] = []
    @FocusState private var isAnswerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !form.intro.isEmpty {
                Text(form.intro)
                    .font(.system(size: compact ? 12.5 : 13))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if form.isMultiStep {
                progress
            }
            if let question = form.questions[safe: step] {
                Text(question.question)
                    .font(.system(size: compact ? 13 : 13.5, weight: form.isMultiStep ? .medium : .regular))
                    .foregroundStyle(form.isMultiStep ? Theme.primaryText : Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .id(step)
                if !question.options.isEmpty {
                    options(question.options)
                }
            }
            answerRow
        }
        .onAppear { answers = Array(repeating: "", count: form.questions.count) }
    }

    private var progress: some View {
        HStack(spacing: 10) {
            Text("Question \(step + 1) of \(form.questions.count)")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .monospacedDigit()
            HStack(spacing: 4) {
                ForEach(form.questions.indices, id: \.self) { index in
                    Button { go(to: index) } label: {
                        Capsule()
                            .fill(segmentColor(index))
                            .frame(width: index == step ? 22 : 14, height: 5)
                            .contentShape(Rectangle().inset(by: -6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Question \(index + 1)\(isAnswered(index) ? ", answered" : "")")
                    .help("Go to question \(index + 1)")
                }
            }
            .animation(.snappy(duration: 0.2), value: step)
            Spacer(minLength: 0)
        }
    }

    private func options(_ options: [String]) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(options, id: \.self) { option in
                let isSelected = answer == option
                Button { answer = isSelected ? "" : option } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 11))
                            .foregroundStyle(isSelected ? Theme.accent : Theme.tertiaryText)
                        Text(option)
                            .font(.system(size: 12.5))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(isSelected ? Theme.accent.opacity(0.16) : Color.white.opacity(0.06), in: .rect(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(isSelected ? Theme.accent.opacity(0.7) : Theme.hairline))
                    .contentShape(.rect(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    private var answerRow: some View {
        let height: CGFloat = compact ? 28 : 30
        let hasOptions = !(form.questions[safe: step]?.options.isEmpty ?? true)
        return HStack(alignment: .bottom, spacing: 8) {
            TextField(
                "Answer",
                text: Binding(get: { answer }, set: { answer = $0 }),
                prompt: Text(hasOptions ? "Pick an option or write your own answer" : "Reply\(recipient.map { " to \($0)" } ?? "")"),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .lineLimit(1...5)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.black.opacity(0.25), in: .rect(cornerRadius: 10, style: .continuous))
            .focused($isAnswerFocused)
            .onSubmit(advance)
            .accessibilityLabel(form.isMultiStep ? "Answer to question \(step + 1)" : "Answer")
            if form.isMultiStep && step > 0 {
                Button("Back") { go(to: step - 1) }
                    .buttonStyle(PillButtonStyle(height: height))
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                    .help("Previous question")
            }
            Button(primaryTitle, action: advance)
                .buttonStyle(PillButtonStyle(.primary, height: height))
                .disabled(!form.isMultiStep && answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(primaryHelp)
            accessory
        }
    }

    private var isLastStep: Bool { step >= form.questions.count - 1 }

    private var primaryTitle: String {
        guard form.isMultiStep else { return "Send" }
        if isLastStep { return "Send \(form.questions.count) answers" }
        return answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Skip" : "Next"
    }

    private var primaryHelp: String {
        guard form.isMultiStep, !isLastStep else {
            return "Send your answers\(recipient.map { " to \($0)" } ?? "")"
        }
        return "Go to question \(step + 2); a skipped question tells the agent to use its judgment"
    }

    private var answer: String {
        get { answers[safe: step] ?? "" }
        nonmutating set {
            guard answers.indices.contains(step) else { return }
            answers[step] = newValue
        }
    }

    private func isAnswered(_ index: Int) -> Bool {
        !(answers[safe: index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func segmentColor(_ index: Int) -> Color {
        if index == step { return Theme.accent }
        return isAnswered(index) ? Theme.accent.opacity(0.45) : Color.white.opacity(0.14)
    }

    private func go(to index: Int) {
        guard form.questions.indices.contains(index) else { return }
        step = index
        isAnswerFocused = true
    }

    private func advance() {
        if form.isMultiStep && !isLastStep {
            go(to: step + 1)
            return
        }
        let reply = form.reply(answers)
        guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        send(reply)
    }
}

extension QuestionFormView where Accessory == EmptyView {
    init(form: QuestionForm, recipient: String?, compact: Bool = false, send: @escaping (String) -> Void) {
        self.init(form: form, recipient: recipient, compact: compact, send: send) { EmptyView() }
    }
}
