import AppKit
import SaturnCore
import SaturnUI
import SwiftUI

struct ChangesView: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project
    @State private var store = ChangesStore()
    @State private var focusedPath: String?

    var body: some View {
        reviewContent
            .task(id: requestedRunID) {
                guard let requestedRunID, requestedRunID != store.selectedRunID else { return }
                store.select(runID: requestedRunID)
            }
    }

    private var requestedRunID: Int64? {
        project.id.flatMap { workspace.changesRunSelections[$0] }
    }

    @ViewBuilder
    private var reviewContent: some View {
        let runs = workspace.reviewableRuns(in: project)
        if let run = store.selectedRun(from: runs) {
            content(run: run, runs: runs)
                .task(id: reloadKey(run)) { await store.load(run, in: project, workspace: workspace) }
                .task(id: run.id) { await observePins(of: run) }
        } else {
            EmptyState("Nothing to review", message: "Diffs across a run’s branches and the pins agents flag for you appear here before anything reaches main. Ask the Lead in a chat to start a run.") {
                Button("New Chat") { workspace.newChat(in: project) }.buttonStyle(SectionButtonStyle(kind: .primary))
            }
        }
    }

    private func reloadKey(_ run: Run) -> String {
        [run.id.map(String.init), run.currentStep, run.status.rawValue, workspace.connection.waitingReason(runID: run.id ?? -1)?.reason.rawValue]
            .map { $0 ?? "-" }
            .joined(separator: "|")
    }

    private func observePins(of run: Run) async {
        guard let id = run.id else { return }
        do {
            for try await pins in workspace.database.pinUpdates(runId: id) where store.selectedRunID == id || store.selectedRunID == nil {
                store.pins = pins
            }
        } catch {
            store.pins = (try? workspace.database.pins(runId: id)) ?? []
        }
    }

    private func content(run: Run, runs: [Run]) -> some View {
        let agents = workspace.agents(inRun: run)
        let context = ReviewContext(
            project: project,
            agentsByID: Dictionary(agents.compactMap { agent in agent.id.map { ($0, agent) } }, uniquingKeysWith: { first, _ in first }),
            holdsApproval: workspace.holdsForApproval(run),
            appearance: { id in
                guard let id, let agent = agents.first(where: { $0.id == id }) else { return .claude }
                return RoleAppearance(role: workspace.role(for: agent, in: project))
            }
        )
        return ScrollViewReader { proxy in
            HStack(alignment: .top, spacing: 20) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ChangesRunList(runs: runs, selected: run, store: store)
                        ChangesPinList(store: store, context: context) { target in jump(to: target, proxy: proxy) }
                    }
                    .padding(.bottom, 20)
                }
                .scrollIndicators(.never)
                .frame(width: 280)
                VStack(spacing: 0) {
                    ChangesHeader(project: project, run: run, store: store, context: context)
                    if !store.visiblePaths.isEmpty {
                        FileChips(paths: store.visiblePaths, current: focusedPath) { path in jump(to: path, proxy: proxy) }
                    }
                    fileColumn(run: run, context: context)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .sectionCard()
                .clipShape(.rect(cornerRadius: 14, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func jump(to target: String, proxy: ScrollViewProxy) {
        focusedPath = target
        withAnimation(.snappy(duration: 0.25)) {
            store.reveal(target)
            proxy.scrollTo(target, anchor: .top)
        }
    }

    @ViewBuilder
    private func fileColumn(run: Run, context: ReviewContext) -> some View {
        if store.changeSet == nil || store.loadedRunID != run.id {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reading the run’s branches…").font(.system(size: 12.5)).foregroundStyle(Tokens.text2)
            }
            .frame(maxWidth: .infinity, minHeight: 240)
        } else if let changeSet = store.changeSet, changeSet.branches.isEmpty {
            EmptyState("No code changes yet", message: "This run hasn’t started any coding agents. Their branches show up here as soon as they begin work.")
                .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            let reviews = workspace.reviews(for: run)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        if let changeSet = store.changeSet {
                            ConflictBanner(changeSet: changeSet, run: run) {
                                Task { await store.load(run, in: project, workspace: workspace) }
                            }
                        }
                        if let gates = store.gates, !gates.findings.isEmpty {
                            GatesCard(report: gates)
                        }
                        if !store.evidence.isEmpty {
                            EvidenceCard(evidence: store.evidence, context: context)
                        }
                    }
                    .padding(.horizontal, 18)
                    if store.visiblePaths.isEmpty {
                        Text("No file changes on these branches yet.")
                            .font(.system(size: 13))
                            .foregroundStyle(Tokens.text2)
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
                .padding(.top, 4)
                .padding(.bottom, 14)
            }
            .scrollIndicators(.automatic)
        }
    }
}

struct ChangesHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project
    let run: Run
    let store: ChangesStore
    let context: ReviewContext

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(run.reviewTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Tokens.text)
                    .lineLimit(1)
                summary
                    .font(.system(size: 12.5))
                    .foregroundStyle(Tokens.text2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            controls
            requestButton
            approveButton
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .overlay(alignment: .bottom) { Rectangle().fill(Tokens.hair).frame(height: 1) }
    }

    private var summary: Text {
        var parts: [Text] = []
        if let branch = branchLabel { parts.append(Text(branch).font(Tokens.mono(12))) }
        if store.changeSet != nil {
            let files = store.allPaths.count
            parts.append(Text("\(files) file\(files == 1 ? "" : "s")"))
        }
        if let checks = checksLabel { parts.append(Text(checks.text).foregroundStyle(checks.color)) }
        if let pins = pinsLabel { parts.append(Text(pins.text).foregroundStyle(pins.color)) }
        return parts.dropFirst().reduce(parts.first ?? Text(run.reviewMeta)) { Text("\($0) · \($1)") }
    }

    private var branchLabel: String? {
        let branches = store.changeSet?.branches ?? []
        let base = run.baseBranch ?? branches.compactMap(\.base).first
        let head: String? = run.deliveryBranch ?? (branches.count == 1 ? branches.first?.branch : branches.isEmpty ? nil : "\(branches.count) branches")
        guard let head else { return nil }
        return base.map { "\(head) → \($0)" } ?? head
    }

    private var checksLabel: (text: String, color: Color)? {
        guard let gates = store.gates else { return nil }
        if !gates.criteria.isEmpty {
            let passed = gates.criteria.count { $0.status == .pass }
            let allPass = passed == gates.criteria.count
            return ("checks \(passed)/\(gates.criteria.count)\(allPass ? " ✓" : "")", allPass ? Tokens.done : Tokens.need)
        }
        if gates.passed { return ("checks passed ✓", Tokens.done) }
        return ("\(gates.blocking.count) check\(gates.blocking.count == 1 ? "" : "s") need you", Tokens.need)
    }

    private var pinsLabel: (text: String, color: Color)? {
        let open = store.openPins.count
        let requested = store.changeRequests.count
        if open > 0 { return ("\(open) open pin\(open == 1 ? "" : "s")", Tokens.review) }
        if requested > 0 { return ("\(requested) change request\(requested == 1 ? "" : "s")", Tokens.need) }
        return nil
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if store.codingAgents.count > 1 {
                Menu {
                    Button("All agents") { store.agentFilter = nil }
                    ForEach(store.codingAgents) { agent in
                        Button(workspace.displayName(of: agent, in: project)) { store.agentFilter = agent.id }
                    }
                } label: {
                    Text(store.codingAgents.first { $0.id == store.agentFilter }.map { workspace.displayName(of: $0, in: project) } ?? "All agents")
                }
                .menuStyle(.button)
                .buttonStyle(SectionButtonStyle())
                .fixedSize()
                .help("Only show one agent’s branch")
            }
            CapsuleTabs(DiffLayout.allCases, selection: Binding(get: { store.layout }, set: { store.layout = $0 }), title: \.title)
                .fixedSize()
                .help("Diff layout")
            Button {
                Task { await store.load(run, in: project, workspace: workspace) }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(SectionButtonStyle())
            .disabled(store.isLoading)
            .accessibilityLabel("Reload changes")
            .help("Read the branches again")
        }
    }

    private var requestButton: some View {
        let requested = store.changeRequests
        return Button("Request changes") { workspace.sendChangesBack(in: run, pins: store.pins) }
            .buttonStyle(SectionButtonStyle())
            .disabled(!context.holdsApproval || requested.isEmpty)
            .help(!context.holdsApproval
                ? "Available when the run reaches your approval step"
                : requested.isEmpty
                    ? "Use Request change on a pin, or comment on a line, first"
                    : "Sends the \(requested.count) requested change\(requested.count == 1 ? "" : "s") back to the authors’ workflow step")
    }

    private var approveButton: some View {
        let unreadCore = store.unviewedCoreFiles.count
        let canApprove = store.openPins.count > 0 || context.holdsApproval
        return Button(context.holdsApproval ? "Approve & merge" : "Approve all pins") { workspace.approveAllPins(in: run) }
            .buttonStyle(SectionButtonStyle(kind: .primary))
            .disabled(!canApprove || unreadCore > 0)
            .help(unreadCore > 0
                ? "Read and mark the \(unreadCore) core file\(unreadCore == 1 ? "" : "s") as viewed first"
                : context.holdsApproval
                    ? "Approves every open pin and lets the run continue to merge"
                    : canApprove ? "Approves every open pin. The run continues when it reaches your approval step." : "Nothing waits for your approval")
    }
}

struct FileChips: View {
    let paths: [ChangedPath]
    let current: String?
    let select: (String) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(paths) { path in
                    let isCurrent = path.path == current
                    Button { select(path.path) } label: {
                        HStack(spacing: 8) {
                            Text((path.path as NSString).lastPathComponent).foregroundStyle(Tokens.text)
                            if path.additions > 0 { Text("+\(path.additions)").foregroundStyle(Tokens.done) }
                            if path.deletions > 0 { Text("−\(path.deletions)").foregroundStyle(Tokens.danger) }
                        }
                        .font(Tokens.mono(11.5))
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(isCurrent ? Tokens.selection : .clear, in: .rect(cornerRadius: 7, style: .continuous))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(path.path)
                    .accessibilityAddTraits(isCurrent ? .isSelected : [])
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.never)
        .overlay(alignment: .bottom) { Rectangle().fill(Tokens.hair).frame(height: 1) }
    }
}

struct ConflictBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let changeSet: RunChangeSet
    let run: Run
    let reload: () -> Void
    @State private var busy = false
    @State private var note: String?

    var body: some View {
        let failures = changeSet.branches.filter { $0.error != nil }
        if !changeSet.conflicts.isEmpty || changeSet.conflictCheckError != nil || !failures.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !changeSet.conflicts.isEmpty {
                    Label(conflictTitle, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(DiffPalette.conflict)
                    ForEach(changeSet.conflicts) { conflict in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(conflict.branch) ↔ \(conflict.otherIsBase ? "\(conflict.other) (base)" : conflict.other): \(conflict.paths.joined(separator: ", "))")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("These can’t both merge as they are. Pick one, or send it back to be combined.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.secondaryText)
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 8) { conflictActions(conflict) }
                                VStack(alignment: .leading, spacing: 6) { conflictActions(conflict) }
                            }
                            .disabled(busy)
                        }
                    }
                    if let note {
                        Text(note).font(.system(size: 12)).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
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
                    Text("Couldn’t read \(workspace.displayName(of: branch.agent))’s branch \(branch.branch): \(branch.error ?? "")")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.stuckBackground, in: .rect(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Tokens.stuckLine))
        }
    }

    @ViewBuilder
    private func conflictActions(_ conflict: MergeConflict) -> some View {
        Button("Ask \(owner(of: conflict.branch)) to combine") {
            perform { name in "\(name) is merging the branches and resolving the conflict." } action: { try await workspace.send(RunCommands.AskToCombine(runID: run.id ?? -1, conflict: conflict)) }
        }
        .buttonStyle(SectionButtonStyle(kind: .primary, height: 28))
        .help("Merge the other side into \(conflict.branch) and send its author the conflict to resolve")
        Button("Keep \(owner(of: conflict.branch))’s") {
            perform { _ in "Kept \(conflict.branch)’s version." } action: { try await workspace.send(RunCommands.KeepBranch(runID: run.id ?? -1, winner: conflict.branch, conflict: conflict)); return "" }
        }
        .buttonStyle(SectionButtonStyle(height: 28))
        Button("Keep \(conflict.otherIsBase ? conflict.other : owner(of: conflict.other))’s") {
            perform { _ in "Kept \(conflict.other)’s version." } action: { try await workspace.send(RunCommands.KeepBranch(runID: run.id ?? -1, winner: conflict.other, conflict: conflict)); return "" }
        }
        .buttonStyle(SectionButtonStyle(height: 28))
        Button("Open in Merge Tool") {
            busy = true
            Task {
                defer { busy = false }
                do {
                    let staged = try await workspace.send(RunCommands.StageForMergeTool(runID: run.id ?? -1, conflict: conflict))
                    let worktree = URL(fileURLWithPath: staged.worktree, isDirectory: true)
                    if let builder = workspace.agents(inRun: run).first(where: { $0.worktreeURL?.path == staged.worktree }), workspace.isRemote(builder) {
                        workspace.openRemoteShell(at: worktree, forAgent: builder)
                    } else if let editor = ExternalApp.installed(ExternalApp.editorCandidates).first {
                        editor.open(worktree)
                    } else {
                        NSWorkspace.shared.activateFileViewerSelecting([worktree])
                    }
                    note = "Resolve \(staged.files.joined(separator: ", ")) in \(staged.worktree), then commit. Saturn picks it up when you reload."
                } catch {
                    model.alert = AppAlert(title: "Couldn’t stage the merge", message: error.localizedDescription)
                }
            }
        }
        .buttonStyle(SectionButtonStyle(height: 28))
        .help("Start the merge in the worktree and open it in your editor")
    }

    private func owner(of branch: String) -> String {
        changeSet.branches.first { $0.branch == branch }.map { workspace.displayName(of: $0.agent) } ?? branch
    }

    private func perform(_ message: @escaping (String) -> String, action: @escaping () async throws -> String) {
        busy = true
        Task {
            defer { busy = false }
            do {
                note = message(try await action())
                reload()
            } catch {
                model.alert = AppAlert(title: "Couldn’t resolve the conflict", message: error.localizedDescription)
            }
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Tokens.text2)
                .padding(EdgeInsets(top: 12, leading: 18, bottom: 4, trailing: 18))
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(pins) { pin in
                Text("\(pin.file):\(pin.sideLineLabel)")
                    .font(Tokens.mono(11.5))
                    .foregroundStyle(Tokens.text2)
                    .padding(.horizontal, 18)
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
        .overlay(alignment: .top) { Rectangle().fill(Tokens.hair).frame(height: 1) }
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
