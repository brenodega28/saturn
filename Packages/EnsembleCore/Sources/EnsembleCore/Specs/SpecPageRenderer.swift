import CryptoKit
import Foundation

public struct SpecPageRenderer: Sendable {
    public let template: String

    public init(template: String = SpecPageRenderer.bundledTemplate) {
        self.template = template
    }

    public static var bundledTemplate: String {
        guard let root = Bundle.module.url(forResource: "Templates", withExtension: nil),
              let text = try? String(contentsOf: root.appending(path: "spec-page/page.html"), encoding: .utf8) else { return fallbackTemplate }
        return text
    }

    static let fallbackTemplate = """
        <!doctype html><html><head><meta charset="utf-8"><title>{{title}}</title>
        <style>body{background:#fff;color:#111;font:15px/1.6 system-ui;max-width:860px;margin:0 auto;padding:32px}
        @media (prefers-color-scheme: dark){body{background:#18181a;color:#eee}}</style></head>
        <body><main>{{content}}</main></body></html>
        """

    public func render(_ document: SpecDocument) -> String {
        template
            .replacingOccurrences(of: "{{title}}", with: Self.escape(document.title))
            .replacingOccurrences(of: "{{content}}", with: content(document))
    }

    public static func pageURL(for draft: URL) -> URL {
        draft.deletingPathExtension().appendingPathExtension("html")
    }

    public static func criterionID(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(SpecCriteria.normalized(text).utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    public static func sectionID(_ heading: String) -> String {
        "section-" + (Slug.make(heading).nilIfEmpty ?? "notes")
    }

    func content(_ document: SpecDocument) -> String {
        var parts = [header(document)]
        if !document.summary.isEmpty { parts.append(section("Summary", Self.blocks(document.summary))) }
        if !document.interfaces.isEmpty { parts.append(section("Interfaces", Self.list(document.interfaces))) }
        if !document.outOfScope.isEmpty { parts.append(section("Out of scope", Self.list(document.outOfScope))) }
        parts.append(section("Acceptance criteria", criteria(document.acceptanceCriteria)))
        if !document.verification.isEmpty { parts.append(section("Verification", Self.blocks(document.verification))) }
        if !document.workers.isEmpty { parts.append(section("Workers", workers(document.workers))) }
        for extra in document.extraSections where !extra.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(section(extra.heading, Self.blocks(extra.body)))
        }
        return parts.joined(separator: "\n")
    }

    private func header(_ document: SpecDocument) -> String {
        let count = document.acceptanceCriteria.count
        return """
            <header id="spec-header">
            <h1>\(Self.escape(document.title))</h1>
            <div class="meta"><span class="badge status-\(document.status.rawValue)">\(document.status.title)</span><span>Version \(document.version)</span><span>\(document.checkedCount)/\(count) criteri\(count == 1 ? "on" : "a") met</span>\(document.owner.isEmpty ? "" : "<span>Owner: \(Self.escape(document.owner))</span>")</div>
            </header>
            """
    }

    private func section(_ heading: String, _ body: String) -> String {
        "<section id=\"\(Self.sectionID(heading))\" data-section=\"\(Self.escape(heading))\">\n<h2>\(Self.escape(heading))</h2>\n\(body)\n</section>"
    }

    public static func criterionIDs(_ criteria: [SpecCriterion]) -> [String] {
        var seen: [String: Int] = [:]
        return criteria.map { criterion in
            let id = criterionID(criterion.text)
            seen[id, default: 0] += 1
            let count = seen[id] ?? 1
            return count > 1 ? "\(id)-\(count)" : id
        }
    }

    private func criteria(_ items: [SpecCriterion]) -> String {
        guard !items.isEmpty else { return "<p>No acceptance criteria yet.</p>" }
        let rows = zip(items, Self.criterionIDs(items)).map { item, id in
            let state = item.checked ? " class=\"checked\"" : ""
            return "<li id=\"criterion-\(id)\" data-criterion=\"\(id)\"\(state)><span class=\"text\">\(Self.inline(item.text))</span></li>"
        }
        return "<ol class=\"criteria\">\n" + rows.joined(separator: "\n") + "\n</ol>"
    }

    private func workers(_ items: [SpecWorker]) -> String {
        let rows = items.map { worker in
            let role = worker.role.isEmpty ? "" : " <span class=\"role\">\(Self.escape(worker.role))</span>"
            let reason = worker.reason.map { " · <span class=\"reason\">\(Self.inline($0))</span>" } ?? ""
            return "<li><strong>\(Self.escape(worker.name))</strong>\(role)\(reason)</li>"
        }
        return "<ul class=\"workers\">\n" + rows.joined(separator: "\n") + "\n</ul>"
    }

    static func list(_ items: [String]) -> String {
        "<ul>\n" + items.map { "<li>\(inline($0))</li>" }.joined(separator: "\n") + "\n</ul>"
    }

    static func blocks(_ text: String) -> String {
        var output: [String] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { output.append("<p>\(inline(paragraph.joined(separator: " ")))</p>") }
            if !bullets.isEmpty { output.append(list(bullets)) }
            paragraph = []
            bullets = []
        }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = code {
                    output.append("<pre><code>\(escape(lines.joined(separator: "\n")))</code></pre>")
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(line)
            } else if trimmed.isEmpty {
                flush()
            } else if let item = ["- ", "* "].first(where: trimmed.hasPrefix) {
                if !paragraph.isEmpty { flush() }
                bullets.append(String(trimmed.dropFirst(item.count)))
            } else {
                if !bullets.isEmpty { flush() }
                paragraph.append(trimmed)
            }
        }
        if let lines = code { output.append("<pre><code>\(escape(lines.joined(separator: "\n")))</code></pre>") }
        flush()
        return output.joined(separator: "\n")
    }

    static func inline(_ text: String) -> String {
        let pieces = text.components(separatedBy: "`")
        return pieces.enumerated().map { index, piece in
            let escaped = escape(piece)
            if index % 2 == 1, index < pieces.count - 1 { return "<code>\(escaped)</code>" }
            return emphasis(index % 2 == 1 ? "`" + escaped : escaped)
        }.joined()
    }

    static func emphasis(_ text: String) -> String {
        let pieces = text.components(separatedBy: "**")
        guard pieces.count >= 3 else { return text }
        return pieces.enumerated().map { index, piece in
            index % 2 == 1 && index < pieces.count - 1 ? "<strong>\(piece)</strong>" : (index % 2 == 1 ? "**" + piece : piece)
        }.joined()
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
