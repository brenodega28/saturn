import EnsembleCore
import EnsembleUI
import SwiftUI

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case project
    case skills
    case workflow
    case rails
    case review

    var id: Self { self }

    var name: String {
        switch self {
        case .project: "Project"
        case .skills: "Agents & skills"
        case .workflow: "Workflow"
        case .rails: "Rails"
        case .review: "Review"
        }
    }
}

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var draft: OnboardingDraft?
    @State private var step: OnboardingStep = .project
    @State private var isFinishing = false

    var body: some View {
        Group {
            if let draft = Binding($draft) {
                HStack(alignment: .top, spacing: 0) {
                    OnboardingNavigator(project: project, draft: draft.wrappedValue, step: $step, skip: skip)
                    main(draft)
                }
            } else {
                ProgressView("Looking through \(project.name)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(8)
        .background(Theme.windowBackground, in: .rect(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.white.opacity(0.09)))
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Backdrop())
        .task(id: project.id) { await scan() }
    }

    private func main(_ draft: Binding<OnboardingDraft>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.link)
                Text(title(draft.wrappedValue)).font(.system(size: 26, weight: .bold)).kerning(-0.4)
                Text(lede)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 640, alignment: .leading)
            }
            .padding(EdgeInsets(top: 28, leading: 32, bottom: 18, trailing: 32))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch step {
                    case .project: OnboardingProjectStep(draft: draft) { await scan() }
                    case .skills: OnboardingSkillsStep(draft: draft)
                    case .workflow: OnboardingWorkflowStep(draft: draft)
                    case .rails: OnboardingRailsStep(draft: draft)
                    case .review: OnboardingReviewStep(draft: draft.wrappedValue) { step = $0 }
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(EdgeInsets(top: 0, leading: 32, bottom: 24, trailing: 32))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer(draft.wrappedValue)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func footer(_ draft: OnboardingDraft) -> some View {
        HStack(spacing: 12) {
            if step != .project {
                Button("Back") { move(by: -1) }
                    .buttonStyle(PillButtonStyle(height: 34))
                    .keyboardShortcut(.leftArrow, modifiers: .command)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases) { item in
                    Capsule()
                        .fill(item.rawValue < step.rawValue ? Theme.success : item == step ? Theme.accent : Color.white.opacity(0.12))
                        .frame(width: item == step ? 22 : 8, height: 6)
                }
            }
            .accessibilityHidden(true)
            Spacer()
            if step == .review {
                Button {
                    finish(draft)
                } label: {
                    Text(isFinishing ? "Setting up…" : "Finish and open Chat").padding(.horizontal, 8)
                }
                .buttonStyle(PillButtonStyle(.primary, height: 34))
                .disabled(isFinishing)
                .keyboardShortcut(.return, modifiers: .command)
            } else {
                Button(step == .rails ? "Review" : "Continue") { move(by: 1) }
                    .buttonStyle(PillButtonStyle(.primary, height: 34))
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 32, bottom: 18, trailing: 32))
        .overlay(alignment: .top) { Divider().overlay(Theme.hairline) }
    }

    private func title(_ draft: OnboardingDraft) -> String {
        switch step {
        case .project: "Set up \(draft.name)"
        case .skills: "Who does the work?"
        case .workflow: "How work flows"
        case .rails: "Rails"
        case .review: "Ready to start"
        }
    }

    private var lede: String {
        switch step {
        case .project: "Ensemble scanned the folder. Check the basics."
        case .skills: "One Lead chats, plans and reviews. Builders write code in their own worktrees; checkers review and test from a fresh context. Expertise comes from skills the Lead gives each agent."
        case .workflow: "Every workflow ends the same way: checks, gates and an AI review that only comments, then your approval. Pick the default path."
        case .rails: "Ensemble runs these itself, outside the agent. Nothing reaches you until they pass. Limits and permissions apply to every agent."
        case .review: "Agents propose, the rails below verify, you approve. Finish to open Chat and scope the first change."
        }
    }

    private func move(by offset: Int) {
        guard let next = OnboardingStep(rawValue: step.rawValue + offset) else { return }
        step = next
    }

    private func scan() async {
        let scan = await ProjectScanner.scan(repository: project.url, git: model.git(for: project), files: project.filesRoot)
        let fresh = OnboardingDraft(project: project, scan: scan, pluginSkills: model.pluginSkills(for: project))
        if var existing = draft {
            existing.scan = scan
            draft = existing
        } else {
            draft = fresh
        }
    }

    private func skip() {
        guard let draft else { return }
        var recommended = OnboardingDraft(project: project, scan: draft.scan, pluginSkills: draft.installedSkills.filter { $0.source == .plugin }.map(\.name))
        recommended.name = draft.name
        finish(recommended)
    }

    private func finish(_ draft: OnboardingDraft) {
        isFinishing = true
        model.finishOnboarding(project, plan: draft.plan, name: draft.name, createAgentsFile: draft.createAgentsFile)
        isFinishing = false
    }
}

private struct OnboardingNavigator: View {
    let project: Project
    let draft: OnboardingDraft
    @Binding var step: OnboardingStep
    let skip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Text(String(draft.name.prefix(1)).uppercased())
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(LinearGradient(colors: [Color(hex: 0x4A90FF), Color(hex: 0x1F5FD1)], startPoint: .top, endPoint: .bottom), in: .rect(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(draft.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(project.path.abbreviatingHome)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.top, 8)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(OnboardingStep.allCases) { item in
                    stepButton(item)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 10) {
                Text("Everything here can be changed later in Settings. Nothing runs until you send the first task.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Skip and use recommended setup →", action: skip)
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.link)
                    .help("Use the workflows, skills, checks and limits Ensemble suggests for this folder")
            }
        }
        .padding(EdgeInsets(top: 14, leading: 12, bottom: 16, trailing: 12))
        .frame(width: 252, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(hex: 0x303036, opacity: 0.62), in: .rect(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline))
    }

    private func stepButton(_ item: OnboardingStep) -> some View {
        let isDone = item.rawValue < step.rawValue
        let isCurrent = item == step
        return Button {
            step = item
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(isDone ? Theme.success : isCurrent ? Theme.accent : .clear)
                    if !isDone && !isCurrent { Circle().strokeBorder(Theme.secondaryText, lineWidth: 1.5) }
                    Text(isDone ? "✓" : "\(item.rawValue + 1)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(isDone ? Color(hex: 0x0B1A10) : isCurrent ? .white : Theme.secondaryText)
                }
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(.system(size: 13, weight: isCurrent ? .semibold : .medium))
                    Text(draft.summary(of: item))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isCurrent ? Theme.accent.opacity(0.22) : .clear, in: .rect(cornerRadius: 11, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
