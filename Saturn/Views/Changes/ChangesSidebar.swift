import SaturnCore
import SaturnUI
import SwiftUI

struct ChangesSidebar: View {
    let store: ChangesStore
    let context: ReviewContext
    let jump: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !store.reviewPins.isEmpty {
                    pinSection
                }
                fileSection
            }
            .padding(.bottom, 96)
        }
        .scrollIndicators(.never)
    }

    private var pinSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Needs your eyes").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(store.openPins.count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(hex: 0x2A2300))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(DiffPalette.pin, in: Capsule())
                    .accessibilityLabel("\(store.openPins.count) open pins")
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 6)
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
                    .foregroundStyle(isOpen ? Color.white : Theme.secondaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("\(pin.byUser ? "Your comment · " : "")\((pin.file as NSString).lastPathComponent):\(pin.sideLineLabel)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            switch pin.status {
            case .approved:
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.successText)
                    .accessibilityLabel("Approved")
            case .changeRequested:
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.warning)
                    .accessibilityLabel("Change requested")
            case .open:
                EmptyView()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(isOpen ? DiffPalette.pin.opacity(0.08) : .clear, in: .rect(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Files").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 4).padding(.bottom, 6)
            if store.allPaths.isEmpty {
                Text(store.changeSet == nil ? "Loading…" : "No changed files")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 8)
            }
            ForEach(store.visiblePaths) { path in
                Button { jump(path.path) } label: { fileRow(path) }
                    .buttonStyle(.plain)
                    .help(path.path)
            }
        }
    }

    private func fileRow(_ path: ChangedPath) -> some View {
        let viewed = store.viewed.contains(path.path)
        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(context.appearance(path.diffs.first?.agentId).palette.gradient)
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
            Text(path.path.split(separator: "/").suffix(2).joined(separator: "/"))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(viewed ? Theme.tertiaryText : Color.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
            if path.isConflicted {
                Badge(text: "CONFLICT", color: DiffPalette.conflict)
            }
            if viewed {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(Theme.successText)
                    .accessibilityLabel("Viewed")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .contentShape(Rectangle())
    }
}

struct ReviewBar: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let run: Run
    let store: ChangesStore
    let holdsApproval: Bool

    var body: some View {
        let open = store.openPins.count
        let requested = store.changeRequests
        HStack(spacing: 12) {
            Image(systemName: "pin.fill")
                .foregroundStyle(open > 0 ? DiffPalette.pin : Theme.successText)
                .accessibilityHidden(true)
            Text(title(open: open, requested: requested.count)).font(.system(size: 13.5, weight: .semibold))
            Text(subtitle(requested: requested.count))
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 8)
            if holdsApproval && !requested.isEmpty {
                Button("Send changes back") { workspace.sendChangesBack(in: run, pins: store.pins) }
                    .buttonStyle(PillButtonStyle(.primary, height: 36))
                    .help("Sends the \(requested.count) requested change\(requested.count == 1 ? "" : "s") back to the authors’ workflow step")
            } else if open > 0 || holdsApproval {
                let unreadCore = store.unviewedCoreFiles.count
                Button(holdsApproval ? "Approve all & continue run" : "Approve all pins") { workspace.approveAllPins(in: run) }
                    .buttonStyle(PillButtonStyle(.primary, height: 36))
                    .disabled(unreadCore > 0)
                    .help(unreadCore > 0
                        ? "Read and mark the \(unreadCore) core file\(unreadCore == 1 ? "" : "s") as viewed first"
                        : holdsApproval ? "Approves every open pin and lets the run continue" : "Approves every open pin. The run continues when it reaches your approval step.")
            }
        }
        .padding(EdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 10))
        .frame(maxWidth: 920)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Tokens.menu, in: Capsule())
        .overlay(Capsule().strokeBorder(Tokens.hair2))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 14)
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }

    private func title(open: Int, requested: Int) -> String {
        let requests = "\(requested) change request\(requested == 1 ? "" : "s")"
        if open > 0 {
            let pins = "\(open) open pin\(open == 1 ? "" : "s")"
            return requested > 0 ? "\(pins) · \(requests)" : pins
        }
        if requested > 0 { return requests }
        return store.reviewPins.isEmpty ? "No pins" : "All pins reviewed"
    }

    private func subtitle(requested: Int) -> String {
        var parts: [String] = []
        let conflicts = store.changeSet?.conflictingPaths.count ?? 0
        if conflicts > 0 { parts.append("\(conflicts) conflict\(conflicts == 1 ? "" : "s")") }
        let unreadCore = store.unviewedCoreFiles.count
        if unreadCore > 0 { parts.append("\(unreadCore) core file\(unreadCore == 1 ? "" : "s") to read line by line") }
        let unviewed = store.allPaths.filter { !store.viewed.contains($0.path) }.count
        if unviewed > 0 { parts.append("\(unviewed) file\(unviewed == 1 ? "" : "s") not viewed") }
        if store.hiddenPinCount > 0 { parts.append("\(store.hiddenPinCount) low-confidence comment\(store.hiddenPinCount == 1 ? "" : "s") hidden") }
        if requested > 0 && !holdsApproval { parts.append("\(requested) change request\(requested == 1 ? "" : "s") wait for your approval step") }
        if parts.isEmpty, let step = run.currentStep { parts.append("Run is at \(step.capitalized)") }
        return parts.joined(separator: " · ")
    }
}
