import EnsembleCore
import EnsembleUI
import SwiftUI

struct RequestListView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all
        case open
        case closed

        var id: Self { self }

        var title: String {
            switch self {
            case .all: "All"
            case .open: "Open"
            case .closed: "Closed"
            }
        }
    }

    @Environment(AppModel.self) private var model
    let project: Project
    @State private var query = ""
    @State private var filter: Filter = .all

    var body: some View {
        let requests = LeadRequest.partition(model.leadRequests(in: project))
        let open = filter == .closed ? [] : requests.open.filter(matchesQuery)
        let closed = filter == .open ? [] : requests.closed.filter(matchesQuery)
        let needsYouTaskIDs = model.needsYouTaskIDs()
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("Requests")
                    .font(.system(size: 15, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button {
                    model.startNewLeadRequest(in: project)
                } label: {
                    Label("New request", systemImage: "plus")
                }
                .buttonStyle(PillButtonStyle(height: 28))
                .fixedSize()
                .help("Start a new conversation with the lead")
            }
            HStack(spacing: 10) {
                searchField
                CapsuleTabs(Filter.allCases, selection: $filter, title: \.title)
                    .fixedSize()
            }
            if open.isEmpty && closed.isEmpty {
                EmptyState("No requests", message: emptyMessage(hasRequests: !requests.open.isEmpty || !requests.closed.isEmpty))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        section("Open", requests: open, needsYouTaskIDs: needsYouTaskIDs)
                        section("Closed", requests: closed, needsYouTaskIDs: needsYouTaskIDs)
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .accessibilityHidden(true)
            TextField("Search requests", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiaryText)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Theme.fillRaised, in: .rect(cornerRadius: 10, style: .continuous))
    }

    private func matchesQuery(_ request: Chat) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || request.title.localizedCaseInsensitiveContains(trimmed)
    }

    private func emptyMessage(hasRequests: Bool) -> String {
        guard hasRequests else { return "Start a new request to talk with the lead." }
        return query.isEmpty ? "There are no \(filter.title.lowercased()) requests." : "No requests match “\(query)”."
    }

    @ViewBuilder
    private func section(_ title: String, requests: [Chat], needsYouTaskIDs: Set<Int64>) -> some View {
        if !requests.isEmpty {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text("\(requests.count)").font(.system(size: 12)).foregroundStyle(Theme.tertiaryText)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            ForEach(requests) { request in
                row(request, needsYouTaskIDs: needsYouTaskIDs)
            }
        }
    }

    private func row(_ request: Chat, needsYouTaskIDs: Set<Int64>) -> some View {
        let run = model.latestRun(of: request)
        let title = request.title.isEmpty ? "Request #\(request.id ?? 0)" : request.title
        let status = model.requestStatusLabel(of: request, latestRun: run, needsYouTaskIDs: needsYouTaskIDs)
        let detail = run.map { "\(status) · \($0.costUSD.formatted(.currency(code: "USD")))" } ?? status
        return Button {
            model.showRequest(request)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusDot(model.statusColor(of: request, latestRun: run, needsYouTaskIDs: needsYouTaskIDs))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let reason = request.closeReason {
                    CloseReasonBadge(reason: reason)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Theme.fill, in: .rect(cornerRadius: 10, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu { RequestCloseMenu(request: request, project: project) }
        .help("Open in chat")
        .accessibilityLabel([title, detail, request.closeReason.map { "Closed as \($0.title)" }].compactMap(\.self).joined(separator: ", "))
        .accessibilityHint("Opens the request in chat")
    }
}
