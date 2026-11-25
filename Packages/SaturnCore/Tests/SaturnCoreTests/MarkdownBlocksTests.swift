import Foundation
import Testing
@testable import SaturnCore

@Suite struct MarkdownBlocksTests {
    @Test func parsesHeadingsParagraphsAndRules() {
        let blocks = MarkdownParser.blocks("# Title\n\nFirst line\nsecond line\n\n---\n### Sub ###")

        #expect(blocks == [
            .heading(level: 1, text: "Title"),
            .paragraph("First line\nsecond line"),
            .rule,
            .heading(level: 3, text: "Sub"),
        ])
    }

    @Test func parsesNestedBulletAndNumberedLists() {
        let blocks = MarkdownParser.blocks("- one\n  - nested\n- two\n\n1. first\n2) second\n   continued")

        #expect(blocks == [
            .list(ordered: false, items: [
                MarkdownListItem(text: "one", depth: 0),
                MarkdownListItem(text: "nested", depth: 1),
                MarkdownListItem(text: "two", depth: 0),
            ]),
            .list(ordered: true, items: [
                MarkdownListItem(text: "first", number: 1),
                MarkdownListItem(text: "second\ncontinued", number: 2),
            ]),
        ])
    }

    @Test func keepsLooseListsTogetherAndReadsTaskBoxes() {
        let blocks = MarkdownParser.blocks("- [x] done\n\n- [ ] todo\n\nAfter")

        #expect(blocks == [
            .list(ordered: false, items: [
                MarkdownListItem(text: "done", isChecked: true),
                MarkdownListItem(text: "todo", isChecked: false),
            ]),
            .paragraph("After"),
        ])
    }

    @Test func readsTaskBoxesInOrderedAndNestedLists() {
        let blocks = MarkdownParser.blocks("1. [X] shipped\n   - [ ] follow up\n2. plain")

        #expect(blocks == [
            .list(ordered: true, items: [
                MarkdownListItem(text: "shipped", number: 1, isChecked: true),
                MarkdownListItem(text: "follow up", depth: 1, isChecked: false),
                MarkdownListItem(text: "plain", number: 2),
            ]),
        ])
    }

    @Test func plainListItemsAndLookalikesAreNotTasks() {
        let blocks = MarkdownParser.blocks("- item\n- [link](https://example.com)\n- [x]\n- []  empty")

        #expect(blocks == [
            .list(ordered: false, items: [
                MarkdownListItem(text: "item"),
                MarkdownListItem(text: "[link](https://example.com)"),
                MarkdownListItem(text: "[x]"),
                MarkdownListItem(text: "[]  empty"),
            ]),
        ])
    }

    @Test func splitsFrontMatterScalarsAndLists() {
        let split = MarkdownFrontMatter.split("---\ntitle: \"Spec: viewer\"\nstatus: draft\nlinked_runs:\n  - 12\n  - '14'\ntags: [ui, markdown]\nempty:\n---\n\n# Body\ntext")

        #expect(split.fields.map(\.key) == ["title", "status", "linked_runs", "tags", "empty"])
        #expect(split.fields.map(\.value) == ["Spec: viewer", "draft", "12, 14", "ui, markdown", ""])
        #expect(split.body == "# Body\ntext")
    }

    @Test func textWithoutFrontMatterIsUnchanged() {
        let text = "# Title\n\n---\nkey: value\n---"
        let split = MarkdownFrontMatter.split(text)

        #expect(split.fields.isEmpty)
        #expect(split.body == text)
    }

    @Test func unterminatedFrontMatterIsLeftAsBody() {
        let text = "---\ntitle: Draft\nstatus: draft\n\n# Body"
        let split = MarkdownFrontMatter.split(text)

        #expect(split.fields.isEmpty)
        #expect(split.body == text)
    }

    @Test func leadingRuleAroundProseIsNotFrontMatter() {
        let text = "---\nJust a paragraph between rules.\n---\nMore"
        let split = MarkdownFrontMatter.split(text)

        #expect(split.fields.isEmpty)
        #expect(split.body == text)
    }

    @Test func boldLineIsNotAListItem() {
        #expect(MarkdownParser.blocks("**Bold** start") == [.paragraph("**Bold** start")])
    }

    @Test func parsesFencedCodeWithLanguage() {
        let blocks = MarkdownParser.blocks("Look:\n```swift\nlet a = 1\n\nlet b = 2\n```\nDone")

        #expect(blocks == [
            .paragraph("Look:"),
            .code(language: "swift", code: "let a = 1\n\nlet b = 2", isClosed: true),
            .paragraph("Done"),
        ])
    }

    @Test func toleratesAnUnclosedFenceWhileStreaming() {
        let blocks = MarkdownParser.blocks("Here:\n```py\nprint(1)\n# not a heading")

        #expect(blocks == [
            .paragraph("Here:"),
            .code(language: "py", code: "print(1)\n# not a heading", isClosed: false),
        ])
    }

    @Test func fenceNeedsAMatchingClosingRun() {
        let blocks = MarkdownParser.blocks("````\n```\ninner\n```\n````")

        #expect(blocks == [.code(language: nil, code: "```\ninner\n```", isClosed: true)])
    }

    @Test func parsesBlockQuotesRecursively() {
        let blocks = MarkdownParser.blocks("> # Note\n> - a\n>\n> text\nafter")

        #expect(blocks == [
            .quote([.heading(level: 1, text: "Note"), .list(ordered: false, items: [MarkdownListItem(text: "a")]), .paragraph("text")]),
            .paragraph("after"),
        ])
    }

    @Test func parsesTablesWithAlignmentAndRaggedRows() {
        let blocks = MarkdownParser.blocks("| Name | Count | Note |\n|:-----|------:|:----:|\n| a | 1 |\n| b \\| c | 2 | x | extra |\n\nEnd")

        #expect(blocks == [
            .table(
                header: ["Name", "Count", "Note"],
                alignments: [.leading, .trailing, .center],
                rows: [["a", "1", ""], ["b | c", "2", "x"]]
            ),
            .paragraph("End"),
        ])
    }

    @Test func tableHeaderWithoutDelimiterYetStaysAParagraph() {
        #expect(MarkdownParser.blocks("| a | b |") == [.paragraph("| a | b |")])
    }

    @Test func paragraphStopsAtABlockStart() {
        let blocks = MarkdownParser.blocks("Intro\n- item\n```\ncode")

        #expect(blocks == [
            .paragraph("Intro"),
            .list(ordered: false, items: [MarkdownListItem(text: "item")]),
            .code(language: nil, code: "code", isClosed: false),
        ])
    }

    @Test func emptyTextHasNoBlocks() {
        #expect(MarkdownParser.blocks("").isEmpty)
        #expect(MarkdownParser.blocks("\n  \n").isEmpty)
    }
}
