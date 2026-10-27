import EnsembleCore
import EnsembleUI
import SwiftUI

extension AppModel {
    func navigatorProjects(_ scope: NavigatorScope) -> [Project] {
        if scope == .all { return openProjects }
        return currentProject.map { [$0] } ?? []
    }

    func runs(in projects: [Project]) -> [Run] {
        projects.compactMap(\.id).flatMap { (try? database.runs(projectId: $0)) ?? [] }
    }

    func steps(of runs: [Run]) -> [Int64: [RunStep]] {
        Dictionary(uniqueKeysWithValues: runs.compactMap { run in
            run.id.map { ($0, (try? database.runSteps(runId: $0)) ?? []) }
        })
    }
}

struct NavigatorSection<Content: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                Spacer(minLength: 0)
                if let count {
                    Text("\(count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.tertiaryText)
                }
            }
            .padding(EdgeInsets(top: 10, leading: 8, bottom: 4, trailing: 8))
            .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

struct NavigatorRow<Leading: View>: View {
    let title: String
    var detail: String = ""
    var badge: String = ""
    var badgeColor: Color = Theme.secondaryText
    var isSelected = false
    var monospacedTitle = false
    let action: () -> Void
    @ViewBuilder let leading: Leading

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                leading
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 12.5, weight: .semibold, design: monospacedTitle ? .monospaced : .default))
                            .lineLimit(2)
                        if !badge.isEmpty {
                            Text(badge).font(.system(size: 11.5)).foregroundStyle(badgeColor).lineLimit(1)
                        }
                    }
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isSelected ? Theme.accent.opacity(0.22) : .clear, in: .rect(cornerRadius: 8, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct NavigatorEmpty: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 12.5, weight: .semibold))
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.top, 36)
        .frame(maxWidth: .infinity)
    }
}

struct NavigatorList<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }
}

struct StateGlyph: View {
    let systemImage: String
    let color: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 18, height: 18)
            .background(color.opacity(0.18), in: .circle)
            .accessibilityHidden(true)
    }
}
