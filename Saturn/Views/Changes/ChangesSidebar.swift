import SaturnCore
import SaturnUI
import SwiftUI

enum ChangeGroup: CaseIterable {
    case review
    case working
    case merged
    case earlier

    var title: String {
        switch self {
        case .review: "Needs your review"
        case .working: "Waiting on workers"
        case .merged: "Merged · not pushed"
        case .earlier: "Earlier"
        }
    }

    static func of(_ run: Run, needsYou: Bool) -> ChangeGroup {
        if needsYou { return .review }
        if run.mergedAt != nil && run.pushedAt == nil { return .merged }
        switch run.status {
        case .running, .pending, .paused, .interrupted: return .working
        case .waitingOnYou: return .review
        case .succeeded, .failed, .cancelled: return .earlier
        }
    }
}

struct ChangesRunList: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let runs: [Run]
    let selected: Run
    let store: ChangesStore

    var body: some View {
        let grouped = Dictionary(grouping: runs) { ChangeGroup.of($0, needsYou: needsYou($0)) }
        ForEach(ChangeGroup.allCases, id: \.self) { group in
            if let runs = grouped[group], !runs.isEmpty {
                SectionGroupTitle(group.title)
                ForEach(runs) { run in row(run, group: group) }
            }
        }
    }

    private func needsYou(_ run: Run) -> Bool {
        workspace.holdsForApproval(run) || workspace.runNeedsYou(run)
    }

    private func row(_ run: Run, group: ChangeGroup) -> some View {
        let isCurrent = run.id == selected.id
        let status = status(of: run, in: group)
        return Button { store.select(run, replacing: selected) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(run.reviewTitle)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Tokens.text)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(status.text).foregroundStyle(status.color).lineLimit(1)
                    Spacer(minLength: 4)
                    lineCounts(run, isCurrent: isCurrent)
                }
                .font(.system(size: 12))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isCurrent ? Tokens.selection : .clear, in: .rect(cornerRadius: 10, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .help("Review \(run.reviewTitle)")
    }

    @ViewBuilder
    private func lineCounts(_ run: Run, isCurrent: Bool) -> some View {
        if isCurrent, store.loadedRunID == run.id, !store.allPaths.isEmpty {
            let additions = store.allPaths.reduce(0) { $0 + $1.additions }
            let deletions = store.allPaths.reduce(0) { $0 + $1.deletions }
            Text("+\(additions)").font(Tokens.mono(11.5)).foregroundStyle(Tokens.done)
            Text("−\(deletions)").font(Tokens.mono(11.5)).foregroundStyle(Tokens.danger)
        } else if let lines = run.linesChanged, lines > 0 {
            Text("\(lines) lines").font(Tokens.mono(11.5)).foregroundStyle(Tokens.text3)
        }
    }

    private func status(of run: Run, in group: ChangeGroup) -> (text: String, color: Color) {
        switch group {
        case .review:
            workspace.holdsForApproval(run) ? ("In review", Tokens.review) : ("Waiting on you", Tokens.need)
        case .working:
            (run.reviewMeta, run.status == .interrupted ? Tokens.stuck : Tokens.build)
        case .merged:
            ("Merged locally", Tokens.done)
        case .earlier:
            (run.reviewMeta, run.status == .failed ? Tokens.stuck : run.status == .succeeded ? Tokens.done : Tokens.text2)
        }
    }
}

struct ChangesPinList: View {
    let store: ChangesStore
    let context: ReviewContext
    let jump: (String) -> Void

    var body: some View {
        if !store.reviewPins.isEmpty {
            HStack {
                SectionGroupTitle("Pins on this change")
                Spacer()
                if !store.openPins.isEmpty {
                    Text("\(store.openPins.count) open")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Tokens.review)
                        .padding(.top, 8)
                        .padding(.trailing, 10)
                        .accessibilityLabel("\(store.openPins.count) open pins")
                }
            }
            ForEach(store.reviewPins) { pin in
                Button { jump(target(for: pin)) } label: { pinRow(pin) }
                    .buttonStyle(.plain)
                    .help("Jump to \(pin.file):\(pin.sideLineLabel)")
            }
        }
    }

    private func target(for pin: Pin) -> String {
        store.allPaths.first { ChangesStore.pin(pin, belongsTo: $0.path) }?.path ?? "unplaced-pins"
    }

    private func pinRow(_ pin: Pin) -> some View {
        let isOpen = pin.status == .open
        return HStack(alignment: .top, spacing: 10) {
            AgentAvatar(size: 20, appearance: pin.byUser ? .reviewer : context.appearance(pin.agentId)).shadow(radius: 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(pin.byUser ? pin.explanation : pin.title)
                    .font(.system(size: 12.5, weight: isOpen ? .semibold : .medium))
                    .foregroundStyle(isOpen ? Tokens.text : Tokens.text2)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("\(pin.byUser ? "Your comment · " : "")\((pin.file as NSString).lastPathComponent):\(pin.sideLineLabel)")
                    .font(Tokens.mono(11))
                    .foregroundStyle(Tokens.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            switch pin.status {
            case .approved:
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Tokens.done)
                    .accessibilityLabel("Approved")
            case .changeRequested:
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Tokens.need)
                    .accessibilityLabel("Change requested")
            case .open:
                EmptyView()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(isOpen ? Tokens.reviewBackground : .clear, in: .rect(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }
}
