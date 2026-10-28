import EnsembleCore
import EnsembleUI
import SwiftUI

struct SpecDraftCard: View {
    @Environment(AppModel.self) private var model
    let spec: SpecFile
    let project: Project

    var body: some View {
        let document = spec.document
        let status = document?.status ?? .draft
        HStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 15))
                .foregroundStyle(Theme.link)
                .frame(width: 30, height: 30)
                .background(Theme.link.opacity(0.14), in: .rect(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(status == .draft ? "Spec draft" : "Spec").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                    Text(status.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(status.color)
                }
                Text(document?.title ?? "Unreadable spec draft")
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                Text(detail(document))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { model.openSpec(spec, in: project) } label: { Label("Open", systemImage: "arrow.up.forward.square") }
                .buttonStyle(PillButtonStyle(height: 28))
                .help(status == .draft ? "Open the draft in the editor to read and edit it" : "Open the spec")
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .background(Color.white.opacity(0.04), in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
        .accessibilityElement(children: .combine)
    }

    private func detail(_ document: SpecDocument?) -> String {
        guard let document else { return "Open it to fix the front matter" }
        let count = document.acceptanceCriteria.count
        var parts = ["\(count) acceptance criteri\(count == 1 ? "on" : "a")"]
        if document.status != .draft { parts.append("\(document.checkedCount)/\(count) checked") }
        if let path = spec.relativePath { parts.append(path) }
        return parts.joined(separator: " · ")
    }
}
