import Foundation
import Testing
@testable import EnsembleCore

@Suite struct SpecDocumentTests {
    func sample() -> SpecDocument {
        SpecDocument(
            title: "Refunds API: partial", status: .inProgress, owner: "Sam", linkedRuns: [12, 14],
            created: SpecDocument.dayFormatter.date(from: "2026-10-28")!,
            summary: "Let support staff refund part of an order.\n\nRefunds never exceed what was captured.",
            interfaces: ["POST /refunds {order_id, amount}", "Refund.partial(amount:)"],
            outOfScope: ["Refunds in other currencies"],
            acceptanceCriteria: [SpecCriterion(text: "A refund over the captured total is rejected", checked: true), SpecCriterion(text: "Partial refunds show in the order history")],
            verification: "Run `make test`, then refund an order in the sandbox."
        )
    }

    @Test func serializesTheTemplateAndRoundTrips() throws {
        let document = sample()
        let markdown = document.markdown
        #expect(markdown.hasPrefix("---\ntitle: \"Refunds API: partial\"\nstatus: in-progress\nversion: 1\nowner: Sam\nlinked_runs: [12, 14]\ncreated: 2026-10-28\n---\n"))
        #expect(markdown.contains("## Summary\n\nLet support staff refund part of an order.\n\nRefunds never exceed what was captured.\n\n## Interfaces\n\n- POST /refunds {order_id, amount}\n- Refund.partial(amount:)"))
        #expect(markdown.contains("## Out of scope\n\n- Refunds in other currencies"))
        #expect(markdown.contains("## Acceptance criteria\n\n- [x] A refund over the captured total is rejected\n- [ ] Partial refunds show in the order history"))
        #expect(markdown.hasSuffix("## Verification\n\nRun `make test`, then refund an order in the sandbox.\n"))

        let parsed = try SpecDocument(markdown: markdown)
        #expect(parsed == document)
        #expect(parsed.markdown == markdown)
        #expect(parsed.checkedCount == 1)
    }

    @Test func workersAndTheVersionRoundTrip() throws {
        var document = sample()
        document.version = 3
        document.workers = [SpecWorker(role: "backend", name: "Django Dev 1"), SpecWorker(role: "review", name: "Reviewer: strict")]

        let markdown = document.markdown

        #expect(markdown.contains("version: 3\nworkers:\n  - {role: backend, name: Django Dev 1}\n  - {role: review, name: \"Reviewer: strict\"}\n"))
        let parsed = try SpecDocument(markdown: markdown)
        #expect(parsed.version == 3)
        #expect(parsed.workers == document.workers)
        #expect(parsed.extraFrontMatter.isEmpty)
    }

    @Test func workersWrittenByHandAsNamesOrBlockMapsAreRead() throws {
        let parsed = try SpecDocument(markdown: """
            ---
            title: Order export CSV
            workers:
              - React Dev
              - role: backend
                name: Django Dev 1
            ---
            """)
        #expect(parsed.workers == [SpecWorker(role: "", name: "React Dev"), SpecWorker(role: "backend", name: "Django Dev 1")])
        #expect(parsed.version == 1)
        #expect(SpecStatus(lenient: "rejected") == .rejected)
    }

    @Test func aDraftRequestCarriesItsWorkers() throws {
        let json = #"{"title": "CSV", "summary": "s", "acceptance_criteria": ["a"], "workers": [{"role": "frontend", "name": " React Dev "}, {"role": "x", "name": ""}]}"#
        let request = try JSONDecoder().decode(SpecDraftRequest.self, from: Data(json.utf8))
        #expect(request.workers == [SpecWorker(role: "frontend", name: "React Dev")])
    }

    @Test func mapsToThePlanSpec() {
        let spec = sample().planSpec
        #expect(spec.interfaces == ["POST /refunds {order_id, amount}", "Refund.partial(amount:)"])
        #expect(spec.outOfScope == ["Refunds in other currencies"])
        #expect(spec.acceptanceCriteria == ["A refund over the captured total is rejected", "Partial refunds show in the order history"])
        #expect(spec.verification == "Run `make test`, then refund an order in the sandbox.")
    }

    @Test func toleratesHandEdits() throws {
        let edited = """
            ---
            title: Dark mode
            status: In Progress
            owner: Alex
            linked_runs: 7, 9
            created: 2026-01-05
            reviewers: [ana, bo]
            ---

            # Dark mode

            Some notes before the sections.

            ## acceptance criteria
            * [X] Toggle lives in Settings
            - [ ] Colors follow the system
              when the toggle is off
            - Contrast passes WCAG AA

            ## Summary
            Adds a dark theme.

            ## Open questions
            - Do we theme the charts?

            ```
            ## not a heading
            ```

            ## Interfaces
            ThemeStore.current
            ThemeStore.set(_:)
            """
        let document = try SpecDocument(markdown: edited)
        #expect(document.title == "Dark mode")
        #expect(document.status == .inProgress)
        #expect(document.linkedRuns == [7, 9])
        #expect(SpecDocument.dayFormatter.string(from: document.created) == "2026-01-05")
        #expect(document.summary == "Adds a dark theme.")
        #expect(document.interfaces == ["ThemeStore.current", "ThemeStore.set(_:)"])
        #expect(document.acceptanceCriteria == [
            SpecCriterion(text: "Toggle lives in Settings", checked: true),
            SpecCriterion(text: "Colors follow the system when the toggle is off"),
            SpecCriterion(text: "Contrast passes WCAG AA"),
        ])
        #expect(document.extraSections.map(\.heading) == ["Open questions"])
        #expect(document.extraSections.first?.body.contains("## not a heading") == true)
        #expect(document.preamble == "# Dark mode\n\nSome notes before the sections.")
        #expect(document.extraFrontMatter == "reviewers: [ana, bo]")

        let rewritten = document.markdown
        #expect(rewritten.contains("reviewers: [ana, bo]\n---"))
        #expect(rewritten.contains("## Open questions\n\n- Do we theme the charts?\n\n```\n## not a heading\n```"))
        #expect(try SpecDocument(markdown: rewritten) == document)
    }

    @Test func missingSectionsAreEmpty() throws {
        let document = try SpecDocument(markdown: "---\ntitle: Tiny\n---\n\n## Summary\nJust a typo fix.\n")
        #expect(document.summary == "Just a typo fix.")
        #expect(document.status == .draft)
        #expect(document.owner.isEmpty && document.linkedRuns.isEmpty)
        #expect(document.interfaces.isEmpty && document.outOfScope.isEmpty && document.acceptanceCriteria.isEmpty && document.verification.isEmpty)
        #expect(document.planSpec.isEmpty)
        #expect(document.markdown.contains("## Acceptance criteria\n\n## Verification\n"))
    }

    @Test func aTitleIsRequiredAndBrokenFrontMatterIsReported() {
        #expect(throws: SpecDocumentError.missingTitle) { try SpecDocument(markdown: "## Summary\nNo title anywhere.") }
        #expect(throws: SpecDocumentError.self) { try SpecDocument(markdown: "---\ntitle: [unclosed\n---\n") }
        #expect((try? SpecDocument(markdown: "# Mission\n\nPlain notes."))?.title == "Mission")
    }

    @Test func fileNamesComeFromTheTitleAndAvoidCollisions() throws {
        let repository = FileManager.default.temporaryDirectory.appending(path: "spec-paths-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: repository) }
        try FileManager.default.createDirectory(at: repository.appending(path: "spec"), withIntermediateDirectories: true)

        #expect(SpecStore.availablePath(title: "Refunds API: partial!", folder: "spec", repository: repository) == "spec/refunds-api-partial.md")
        try "x".write(to: repository.appending(path: "spec/refunds-api-partial.md"), atomically: true, encoding: .utf8)
        #expect(SpecStore.availablePath(title: "Refunds API: partial!", folder: "spec", repository: repository) == "spec/refunds-api-partial-2.md")
        #expect(SpecStore.availablePath(title: "Refunds API partial", folder: "spec", repository: repository, taken: ["spec/refunds-api-partial-2.md"]) == "spec/refunds-api-partial-3.md")
        #expect(SpecStore.availablePath(title: "???", folder: "docs/specs", repository: repository) == "docs/specs/spec.md")
    }

    @Test func theSpecFolderIsConfigurablePerProject() throws {
        let repository = FileManager.default.temporaryDirectory.appending(path: "spec-config-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: repository) }
        try FileManager.default.createDirectory(at: ProjectConfig.directory(in: repository), withIntermediateDirectories: true)
        #expect(ProjectConfigLoader.load(repository: repository).specs.folder == "spec")

        try "folder: /docs/specs/\n".write(to: SpecsConfig.file(in: repository), atomically: true, encoding: .utf8)
        #expect(ProjectConfigLoader.load(repository: repository).specs.folder == "docs/specs")
        try ProjectConfigLoader.write(SpecsConfig(folder: "../../outside"), repository: repository)
        #expect(ProjectConfigLoader.loadSpecs(repository: repository).folder == "outside")
    }
}
