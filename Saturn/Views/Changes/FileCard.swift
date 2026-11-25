import SaturnCore
import SaturnUI
import SwiftUI

struct ReviewContext {
    let project: Project
    let agentsByID: [Int64: Agent]
    let holdsApproval: Bool
    let appearance: (Int64?) -> RoleAppearance
}

struct FileCard: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let path: ChangedPath
    let pins: [Pin]
    let reviews: [FileReview]
    let context: ReviewContext
    let store: ChangesStore
    let run: Run

    static let lineLimit = 400

    var body: some View {
        let expanded = store.isExpanded(path)
        VStack(alignment: .leading, spacing: 0) {
            header(expanded: expanded)
            if expanded {
                expandedBody
            } else if path.isGenerated && !store.viewed.contains(path.path) {
                collapsedNote("Generated file — collapsed. Expand to see the diff.")
            }
        }
        .padding(.bottom, 10)
        .background(path.isConflicted ? Tokens.stuckBackground.opacity(0.5) : .clear)
        .overlay(alignment: .top) { Rectangle().fill(Tokens.hair).frame(height: 1) }
    }

    private func header(expanded: Bool) -> some View {
        HStack(spacing: 10) {
            Button {
                if !expanded && store.viewed.contains(path.path) {
                    workspace.setViewed(false, path: path, in: run)
                }
                withAnimation(.snappy(duration: 0.2)) { store.toggleExpanded(path) }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 0 : -90))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Tokens.text3)
            .accessibilityLabel(expanded ? "Collapse \(path.path)" : "Expand \(path.path)")
            .help(expanded ? "Collapse file" : "Expand file")

            Text(displayPath)
                .font(Tokens.mono(11.5))
                .foregroundStyle(Tokens.text2)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .layoutPriority(1)

            HStack(spacing: 6) {
                Text("+\(path.additions)").foregroundStyle(DiffPalette.addedSign)
                Text("−\(path.deletions)").foregroundStyle(DiffPalette.removedSign)
            }
            .font(Tokens.mono(11.5))
            .accessibilityLabel("\(path.additions) added, \(path.deletions) removed")

            badges

            ForEach(uniqueAuthors, id: \.id) { author in
                HStack(spacing: 6) {
                    AgentAvatar(size: 18, appearance: context.appearance(author.id)).shadow(radius: 0)
                    Text(author.name)
                }
                .font(.system(size: 12))
                .foregroundStyle(Tokens.text2)
            }

            Spacer(minLength: 8)
            TierBadge(tier: store.tier(of: path.path))
            ReviewedPill(reviews: reviews, project: context.project)
            viewedToggle
        }
        .padding(EdgeInsets(top: 10, leading: 10, bottom: 4, trailing: 18))
    }

    private var displayPath: String {
        guard let diff = path.diffs.first?.diff, diff.change == .renamed || diff.change == .copied, let old = diff.oldPath else {
            return path.path
        }
        return "\(old) → \(path.path)"
    }

    @ViewBuilder
    private var badges: some View {
        let changes = Set(path.diffs.map(\.diff.change))
        if changes.contains(.added) { Badge(text: "New", color: Theme.successText) }
        if changes.contains(.deleted) { Badge(text: "Deleted", color: DiffPalette.removedSign) }
        if path.isGenerated { Badge(text: "Generated", color: Theme.neutral) }
        if path.hasUncommittedChanges {
            Badge(text: "Uncommitted", color: Theme.warning)
                .help("Part of this change is still uncommitted in the agent’s worktree")
        }
        if path.isConflicted { Badge(text: "CONFLICT", color: DiffPalette.conflict) }
    }

    private var uniqueAuthors: [(id: Int64?, name: String)] {
        var seen = Set<String>()
        return path.diffs.compactMap { diff in
            seen.insert(diff.agentName).inserted ? (diff.agentId, workspace.displayName(of: diff)) : nil
        }
    }

    private var viewedToggle: some View {
        let isViewed = store.viewed.contains(path.path)
        return Toggle(isOn: Binding(
            get: { isViewed },
            set: { newValue in
                workspace.setViewed(newValue, path: path, in: run)
                withAnimation(.snappy(duration: 0.2)) {
                    if newValue {
                        store.viewed.insert(path.path)
                    } else {
                        store.viewed.remove(path.path)
                        store.collapsed.remove(path.path)
                    }
                }
            }
        )) {
            Text("Viewed").font(.system(size: 12))
        }
        .toggleStyle(.checkbox)
        .tint(Tokens.done)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(isViewed ? Tokens.doneBackground : .clear, in: Capsule())
        .overlay(Capsule().strokeBorder(Tokens.hair2))
        .help("Mark as viewed. It stays viewed until the diff changes.")
    }

    @ViewBuilder
    private var expandedBody: some View {
        let notes = reviews.flatMap { review in review.notes.map { (workspace.reviewerTitle(review, in: context.project), $0) } }
        if !notes.isEmpty {
            ReviewerNotes(notes: notes)
        }
        if path.isConflicted {
            ConflictPanel(path: path, context: context)
        } else if path.isOverlapping {
            OverlapNote(path: path)
        }
        ForEach(path.diffs) { entry in
            if path.diffs.count > 1 {
                BranchHeader(entry: entry, appearance: context.appearance(entry.agentId))
            }
            branchDiff(entry)
        }
    }

    @ViewBuilder
    private func branchDiff(_ entry: BranchFileDiff) -> some View {
        let entryPins = pinsFor(entry)
        let showsAll = store.fullyShown.contains(entry.id)
        let rows = DiffRows(diff: entry.diff, pins: entryPins, lineLimit: showsAll ? nil : Self.lineLimit)
        ForEach(rows.unplacedPins) { pin in pinCard(pin) }
        if entry.diff.isBinary {
            collapsedNote("Binary file — no preview.")
        } else if entry.diff.hunks.isEmpty {
            collapsedNote(emptyDiffMessage(entry.diff))
        } else {
            let selection = store.lineSelection(for: entry.id)
            DiffBodyView(
                rows: rows,
                layout: store.layout,
                language: CodeLanguage(path: entry.diff.path),
                selection: selection,
                onSelectLine: { target, extending in store.selectLine(target, in: entry.id, extending: extending) },
                pinContent: { pin in pinCard(pin) },
                composer: {
                    if let selection {
                        NewLineComment(selection: selection, entry: entry, file: path.path, run: run, store: store)
                    }
                }
            )
            if !showsAll && rows.totalLines > Self.lineLimit {
                Button("Show all \(rows.totalLines) lines") { store.fullyShown.insert(entry.id) }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
    }

    private func pinsFor(_ entry: BranchFileDiff) -> [Pin] {
        guard path.diffs.count > 1 else { return pins }
        let authorIDs = Set(path.diffs.compactMap(\.agentId))
        return pins.filter { pin in
            if let agentId = pin.agentId, authorIDs.contains(agentId) { return agentId == entry.agentId }
            return entry.id == path.diffs.first?.id
        }
    }

    private func pinCard(_ pin: Pin) -> some View {
        PinCard(
            pin: pin,
            author: pin.agentId.flatMap { context.agentsByID[$0] },
            appearance: context.appearance(pin.agentId),
            compact: store.layout == .split,
            holdsApproval: context.holdsApproval
        )
        .id("pin-\(pin.id ?? 0)")
    }

    private func emptyDiffMessage(_ diff: FileDiff) -> String {
        switch diff.change {
        case .renamed: "Renamed without content changes."
        case .copied: "Copied without content changes."
        case .added: "New empty file."
        case .deleted: "Deleted an empty file."
        case .modified: diff.oldMode != diff.newMode ? "File mode changed from \(diff.oldMode ?? "?") to \(diff.newMode ?? "?")." : "No content changes."
        }
    }

    private func collapsedNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(Tokens.text2)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(color.opacity(0.14), in: Capsule())
    }
}

struct ReviewedPill: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let reviews: [FileReview]
    let project: Project

    var body: some View {
        let (text, color, background) = appearance
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(background, in: Capsule())
            .help(helpText)
    }

    private func names(_ state: FileReview.State) -> String {
        reviews.filter { $0.state == state }.map { workspace.reviewerTitle($0, in: project) }.joined(separator: ", ")
    }

    private var appearance: (String, Color, Color) {
        if reviews.contains(where: { $0.state == .changesRequested }) {
            return ("Changes requested by \(names(.changesRequested))", Tokens.need, Tokens.needBackground)
        }
        if reviews.contains(where: { $0.state == .reviewing }) {
            return ("\(names(.reviewing)) reviewing…", Tokens.review, Tokens.reviewBackground)
        }
        if reviews.contains(where: { $0.state == .approved }) {
            return ("✓ Reviewed by \(names(.approved))", Tokens.done, Tokens.doneBackground)
        }
        return ("Not reviewed yet", Tokens.text2, Tokens.fill)
    }

    private var helpText: String {
        guard !reviews.isEmpty else { return "No review or QA step has looked at this run yet" }
        return reviews.map { review in
            let state = switch review.state {
            case .approved: "approved"
            case .changesRequested: "requested changes"
            case .reviewing: "is reviewing"
            }
            return "\(workspace.reviewerTitle(review, in: project)) (\(review.stepId)) \(state)"
        }.joined(separator: "\n")
    }
}

struct ReviewerNotes: View {
    let notes: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                HStack(alignment: .top, spacing: 10) {
                    AgentAvatar(size: 22, appearance: .reviewer).shadow(radius: 0)
                    Text("\(Text(note.0).fontWeight(.bold)) · \(note.1)")
                        .font(.system(size: 12.5))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DiffPalette.pinCard, in: .rect(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DiffPalette.pinLine))
            }
        }
        .padding(EdgeInsets(top: 4, leading: 18, bottom: 8, trailing: 18))
    }
}

struct BranchHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let entry: BranchFileDiff
    let appearance: RoleAppearance

    var body: some View {
        HStack(spacing: 8) {
            AgentAvatar(size: 18, appearance: appearance).shadow(radius: 0)
            Text(workspace.displayName(of: entry)).fontWeight(.semibold)
            Spacer(minLength: 8)
            Text(entry.branch)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .background(Tokens.fill)
    }
}

struct OverlapNote: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let path: ChangedPath

    var body: some View {
        Label("\(path.diffs.map { workspace.displayName(of: $0) }.joined(separator: " and ")) both change this file. Their changes merge cleanly.", systemImage: "arrow.triangle.merge")
            .font(.system(size: 12.5))
            .foregroundStyle(Tokens.need)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ConflictPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let path: ChangedPath
    let context: ReviewContext
    @State private var sentTo: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(DiffPalette.conflict)
                    .accessibilityHidden(true)
                Text("\(Text(headline).fontWeight(.bold).foregroundStyle(DiffPalette.conflict)) These can’t merge as they are. Ask an agent to combine them, or send the run back.")
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                ForEach(askTargets, id: \.id) { target in
                    Button("Ask \(target.name) to combine") {
                        sentTo = workspace.askToCombine(path, agentID: target.id) ? target.name : nil
                    }
                    .buttonStyle(PillButtonStyle(target.id == askTargets.first?.id ? .primary : .secondary, height: 30))
                    .help("Sends \(target.name) a message describing the conflict")
                }
            }
            if let sentTo {
                Label("Sent to \(sentTo).", systemImage: "paperplane")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.stuckBackground)
    }

    private var headline: String {
        path.diffs.count > 1 ? "\(path.diffs.count) branches change the same lines." : "This branch conflicts with the base branch."
    }

    private var askTargets: [(id: Int64, name: String)] {
        var seen = Set<Int64>()
        return path.diffs.compactMap { entry in
            guard let id = entry.agentId, seen.insert(id).inserted else { return nil }
            return (id, workspace.displayName(of: entry))
        }
    }
}
