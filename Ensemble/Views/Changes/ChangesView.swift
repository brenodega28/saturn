import EnsembleCore
import EnsembleUI
import SwiftUI

struct ChangesView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var store = ChangesStore()

    var body: some View {
        reviewContent
            .task(id: requestedRunID) {
                guard let requestedRunID, requestedRunID != store.selectedRunID else { return }
                store.select(runID: requestedRunID)
            }
    }

    private var requestedRunID: Int64? {
        project.id.flatMap { model.changesRunSelections[$0] }
    }

    @ViewBuilder
    private var reviewContent: some View {
        let runs = model.reviewableRuns(in: project)
        if let run = store.selectedRun(from: runs) {
            content(run: run, runs: runs)
                .task(id: reloadKey(run)) { await store.load(run, in: project, model: model) }
                .task(id: run.id) { await observePins(of: run) }
        } else {
            EmptyState("Nothing to review", message: "Diffs across a run’s branches and the pins agents flag for you appear here before anything reaches main. Start a run from Tasks or Lead.") {
                Button("Open Tasks") { model.setTab(.tasks, for: project) }.buttonStyle(.pill)
            }
        }
    }

    private func reloadKey(_ run: Run) -> String {
        [run.id.map(String.init), run.currentStep, run.status.rawValue, model.engine.waitingReason(runID: run.id ?? -1)?.reason.rawValue]
            .map { $0 ?? "-" }
            .joined(separator: "|")
    }

    private func observePins(of run: Run) async {
        guard let id = run.id else { return }
        do {
            for try await pins in model.database.pinUpdates(runId: id) where store.selectedRunID == id || store.selectedRunID == nil {
                store.pins = pins
            }
        } catch {
            store.pins = (try? model.database.pins(runId: id)) ?? []
        }
    }

    private func content(run: Run, runs: [Run]) -> some View {
        let agents = model.agents(inRun: run)
        let context = ReviewContext(
            project: project,
            agentsByID: Dictionary(agents.compactMap { agent in agent.id.map { ($0, agent) } }, uniquingKeysWith: { first, _ in first }),
            holdsApproval: model.holdsForApproval(run),
            appearance: { id in
                guard let id, let agent = agents.first(where: { $0.id == id }) else { return .claude }
                return RoleAppearance(role: model.role(for: agent, in: project))
            }
        )
        return VStack(alignment: .leading, spacing: 14) {
            ChangesToolbar(project: project, runs: runs, selected: run, store: store, context: context)
            ScrollViewReader { proxy in
                HStack(alignment: .top, spacing: 16) {
                    ChangesSidebar(store: store, context: context) { target in
                        withAnimation(.snappy(duration: 0.25)) {
                            store.reveal(target)
                            proxy.scrollTo(target, anchor: .top)
                        }
                    }
                    .frame(width: 236)
                    fileColumn(run: run, context: context)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .overlay(alignment: .bottom) {
            ReviewBar(run: run, store: store, holdsApproval: context.holdsApproval)
        }
    }

    @ViewBuilder
    private func fileColumn(run: Run, context: ReviewContext) -> some View {
        if store.changeSet == nil || store.loadedRunID != run.id {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reading the run’s branches…").font(.system(size: 12.5)).foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: 240)
        } else if let changeSet = store.changeSet, changeSet.branches.isEmpty {
            EmptyState("No code changes yet", message: "This run hasn’t started any coding agents. Their branches show up here as soon as they begin work.")
        } else {
            let reviews = model.reviews(for: run)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let changeSet = store.changeSet {
                        ConflictBanner(changeSet: changeSet)
                    }
                    if store.visiblePaths.isEmpty {
                        Text("No file changes on these branches yet.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(maxWidth: .infinity, minHeight: 160)
                    }
                    ForEach(store.visiblePaths) { path in
                        FileCard(path: path, pins: store.pins(for: path), reviews: reviews.reviews(for: path.path), context: context, store: store, run: run)
                            .id(path.path)
                    }
                    if !store.pinsOutsideChanges.isEmpty {
                        UnplacedPinsCard(pins: store.pinsOutsideChanges, context: context, compact: store.layout == .split)
                    }
                }
                .padding(.bottom, 96)
            }
            .scrollIndicators(.automatic)
        }
    }
}

struct ChangesToolbar: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let runs: [Run]
    let selected: Run
    let store: ChangesStore
    let context: ReviewContext

    static let visibleRunCount = 4

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                runChips
                divider
                agentChips
                Spacer(minLength: 12)
                trailingControls
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    runChips
                    Spacer(minLength: 12)
                    trailingControls
                }
                ScrollView(.horizontal) { HStack(spacing: 8) { agentChips } }.scrollIndicators(.never)
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 20).padding(.horizontal, 4).accessibilityHidden(true)
    }

    private var runChips: some View {
        HStack(spacing: 8) {
            Text("Run").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
            ForEach(chipRuns) { run in
                ChipButton(isSelected: run.id == selected.id, action: { store.select(run, replacing: selected) }) {
                    StatusDot(model.statusColor(of: run))
                    Text(run.reviewTitle).fontWeight(.semibold).lineLimit(1)
                    Text(run.reviewMeta).font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText)
                }
                .help("Review \(run.reviewTitle)")
            }
            if runs.count > chipRuns.count {
                Menu {
                    ForEach(runs) { run in
                        Button("\(run.reviewTitle) · \(run.reviewMeta)") { store.select(run, replacing: selected) }
                    }
                } label: {
                    Text("More runs")
                }
                .menuStyle(.button)
                .buttonStyle(PillButtonStyle(height: 32))
                .fixedSize()
                .help("Pick another run of this project")
            }
        }
    }

    private var chipRuns: [Run] {
        var shown = Array(runs.prefix(Self.visibleRunCount))
        if !shown.contains(where: { $0.id == selected.id }) {
            shown.removeLast()
            shown.append(selected)
        }
        return shown
    }

    private var agentChips: some View {
        HStack(spacing: 8) {
            ChipButton(isSelected: store.agentFilter == nil, height: 30, action: { store.agentFilter = nil }) {
                AgentAvatar(size: 20, appearance: RoleAppearance(palette: .neutral, symbol: "person.2")).shadow(radius: 0)
                Text("All agents")
            }
            .help("Show every branch in this run")
            ForEach(store.codingAgents) { agent in
                ChipButton(isSelected: store.agentFilter == agent.id, height: 30, action: { store.agentFilter = agent.id }) {
                    AgentAvatar(size: 20, appearance: context.appearance(agent.id)).shadow(radius: 0)
                    Text(model.displayName(of: agent, in: project))
                }
                .help("Only show \(model.displayName(of: agent, in: project))’s branch")
            }
        }
        .font(.system(size: 12))
    }

    private var trailingControls: some View {
        HStack(spacing: 10) {
            CapsuleTabs(DiffLayout.allCases, selection: Binding(get: { store.layout }, set: { store.layout = $0 }), title: \.title)
                .fixedSize()
                .help("Diff layout")
            Button {
                Task { await store.load(selected, in: project, model: model) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .background(Theme.fillRaised, in: Circle())
            .disabled(store.isLoading)
            .accessibilityLabel("Reload changes")
            .help("Read the branches again")
        }
    }
}

struct ChipButton<Label: View>: View {
    let isSelected: Bool
    var height: CGFloat = 32
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) { label() }
                .foregroundStyle(.white)
                .padding(.leading, height < 32 ? 4 : 12)
                .padding(.trailing, height < 32 ? 10 : 12)
                .frame(height: height)
                .background(isSelected ? Theme.accent.opacity(0.16) : Color.white.opacity(height < 32 ? 0 : 0.05), in: Capsule())
                .overlay(Capsule().strokeBorder(isSelected ? Theme.accent : Color.white.opacity(0.08), lineWidth: 1.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct ConflictBanner: View {
    @Environment(AppModel.self) private var model
    let changeSet: RunChangeSet

    var body: some View {
        let failures = changeSet.branches.filter { $0.error != nil }
        if !changeSet.conflicts.isEmpty || changeSet.conflictCheckError != nil || !failures.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !changeSet.conflicts.isEmpty {
                    Label(conflictTitle, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(DiffPalette.conflict)
                    ForEach(changeSet.conflicts) { conflict in
                        Text("\(conflict.branch) ↔ \(conflict.otherIsBase ? "\(conflict.other) (base)" : conflict.other): \(conflict.paths.joined(separator: ", "))")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Checked on committed work. Uncommitted changes in worktrees aren’t part of this check.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondaryText)
                }
                if let error = changeSet.conflictCheckError {
                    Text("Couldn’t check for merge conflicts: \(error)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.warning)
                }
                ForEach(failures) { branch in
                    Text("Couldn’t read \(model.displayName(of: branch.agent))’s branch \(branch.branch): \(branch.error ?? "")")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.danger.opacity(changeSet.conflicts.isEmpty ? 0.04 : 0.08), in: .rect(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.danger.opacity(0.35)))
        }
    }

    private var conflictTitle: String {
        let files = changeSet.conflictingPaths.count
        return "\(files) file\(files == 1 ? "" : "s") won’t merge cleanly — resolve before merging"
    }
}

struct UnplacedPinsCard: View {
    let pins: [Pin]
    let context: ReviewContext
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Pins on files without changes in this run")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.04))
            ForEach(pins) { pin in
                Text("\(pin.file):\(pin.sideLineLabel)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                PinCard(
                    pin: pin,
                    author: pin.agentId.flatMap { context.agentsByID[$0] },
                    appearance: context.appearance(pin.agentId),
                    compact: compact,
                    holdsApproval: context.holdsApproval
                )
                .id("pin-\(pin.id ?? 0)")
            }
        }
        .background(DiffPalette.cardBackground, in: .rect(cornerRadius: 16, style: .continuous))
        .clipShape(.rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.09)))
        .id("unplaced-pins")
    }
}

extension Run {
    var reviewTitle: String { title.isEmpty ? "Run #\(id ?? 0)" : title }

    var reviewMeta: String {
        switch status {
        case .running, .pending: currentStep?.capitalized ?? "Running"
        case .waitingOnYou: "Waiting on you"
        case .paused: "Paused"
        case .interrupted: "Interrupted"
        case .succeeded: "Done"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}
