import Foundation
import Testing
@testable import SaturnCore

@Suite struct CodeSyntaxTests {
    func kinds(_ line: String, _ language: CodeLanguage) -> [String: CodeToken.Kind] {
        Dictionary(CodeTokenizer.tokens(line, language: language).map { ($0.text, $0.kind) }, uniquingKeysWith: { first, _ in first })
    }

    @Test func languagesComeFromTheFileName() {
        #expect(CodeLanguage(path: "orders/views.py") == .python)
        #expect(CodeLanguage(path: "frontend/src/RefundDrawer.tsx") == .typescript)
        #expect(CodeLanguage(path: "Sources/App.swift") == .swift)
        #expect(CodeLanguage(path: "Makefile") == .shell)
        #expect(CodeLanguage(path: "LICENSE") == .plain)
    }

    @Test func pythonLinesAreHighlighted() {
        let tokens = kinds("    def refunds(self, request, pk=None):  # money", .python)
        #expect(tokens["def"] == .keyword)
        #expect(tokens["refunds"] == .function)
        #expect(tokens["None"] == .keyword)
        #expect(tokens["# money"] == .comment)
        #expect(kinds("@action(detail=True)", .python)["@action"] == .decorator)
        #expect(kinds("x = \"it's \\\"quoted\\\"\" + 42", .python)["\"it's \\\"quoted\\\"\""] == .string)
        #expect(kinds("x = 42", .python)["42"] == .number)
        #expect(kinds("class Refund(models.Model):", .python)["Refund"] == .type)
    }

    @Test func tokensRebuildTheLineExactly() {
        for line in ["    return Response(RefundSerializer(refund).data, status=201)  # ok", "const max = order.total - 1; /* c */ x", "", "\t\tlet a = \"unterminated"] {
            #expect(CodeTokenizer.tokens(line, language: line.contains("return") ? .python : .typescript).map(\.text).joined() == line)
        }
    }

    @Test func markdownAndTomlHaveTheirOwnRules() {
        #expect(CodeTokenizer.tokens("## Run it", language: .markdown).map(\.kind) == [.heading])
        #expect(CodeTokenizer.tokens("- uv sync", language: .markdown).map(\.kind) == [.keyword, .plain])
        #expect(CodeTokenizer.tokens("[project]", language: .toml).map(\.kind) == [.type])
        #expect(CodeTokenizer.tokens("name = \"shop\"", language: .toml).map(\.kind) == [.function, .punctuation, .string])
    }

    @Test func outlinesListClassesFunctionsAndHeadings() {
        let python = ["class OrdersViewSet(viewsets.ModelViewSet):", "    def get_queryset(self):", "        pass", "async def main():"]
        #expect(CodeOutline.symbols(python, language: .python) == [
            CodeSymbol(name: "OrdersViewSet", line: 1, kind: .type, depth: 0),
            CodeSymbol(name: "get_queryset", line: 2, kind: .function, depth: 1),
            CodeSymbol(name: "main", line: 4, kind: .function, depth: 0),
        ])
        let tsx = ["type Props = { a: number };", "export function RefundDrawer({ order }: Props) {", "export const useThing = async () => 1"]
        #expect(CodeOutline.symbols(tsx, language: .typescript).map(\.name) == ["Props", "RefundDrawer", "useThing"])
        #expect(CodeOutline.symbols(["# shop", "## Run it"], language: .markdown).map(\.depth) == [0, 1])
        #expect(CodeOutline.symbols(["    public func load() async {", "private struct Row: View {"], language: .swift).map(\.name) == ["load", "Row"])
    }

    @Test func fuzzyMatchingSkipsLettersAndPrefersFileNames() throws {
        let match = try #require(FuzzyMatch.match("ordser", in: "orders/serializers.py"))
        #expect(match.positions == [0, 1, 2, 5, 8, 9])
        #expect(FuzzyMatch.match("xyz", in: "orders/views.py") == nil)
        let name = try #require(FuzzyMatch.match("views", in: "orders/views.py"))
        let scattered = try #require(FuzzyMatch.match("views", in: "very/important/emails/workers/settings.py"))
        #expect(name.score > scattered.score)
    }
}

@Suite struct CodeWorkspaceTests {
    func write(_ text: String, _ path: String, in repo: TestRepository) throws {
        let url = repo.root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func aWorktreeSnapshotMarksChangesAgainstItsBaseBranch() async throws {
        let repo = try await TestRepository.make()
        defer { repo.delete() }
        try write("a\nb\nc\nd\n", "orders/views.py", in: repo)
        try write("ignored\n", "build/out.txt", in: repo)
        try write("build/\n", ".gitignore", in: repo)
        try await repo.git.run(["add", "."], in: repo.root)
        try await repo.git.run(["commit", "-m", "Base"], in: repo.root)
        try await repo.git.run(["checkout", "-b", "crew/dev/task"], in: repo.root)
        try write("a\nB\nc\nd\ne\n", "orders/views.py", in: repo)
        try write("x\ny\n", "orders/tests/test_refunds.py", in: repo)
        try await repo.git.run(["add", "."], in: repo.root)
        try await repo.git.run(["commit", "-m", "Work"], in: repo.root)
        try write("draft\n", "notes.md", in: repo)

        let snapshot = try await CodeWorkspace(root: repo.root, baseBranch: "main", git: repo.git).snapshot()

        #expect(snapshot.files == [".gitignore", "README.md", "notes.md", "orders/tests/test_refunds.py", "orders/views.py"])
        #expect(snapshot.changes["orders/views.py"] == CodeFileChange(status: .modified, lines: [2...2, 5...5]))
        #expect(snapshot.changes["orders/tests/test_refunds.py"] == CodeFileChange(status: .added, lines: [1...2]))
        #expect(snapshot.changes["notes.md"] == CodeFileChange(status: .added, lines: [1...1]))
        #expect(snapshot.changes["README.md"] == nil)
        #expect(snapshot.changes["orders/views.py"]?.addedLineCount == 2)
    }

    @Test func theMainCheckoutShowsUncommittedChanges() async throws {
        let repo = try await TestRepository.make()
        defer { repo.delete() }
        try write("hello\nworld\n", "README.md", in: repo)
        let snapshot = try await CodeWorkspace(root: repo.root, baseBranch: nil, git: repo.git).snapshot()
        #expect(snapshot.changes == ["README.md": CodeFileChange(status: .modified, lines: [2...2])])
    }

    @Test func documentsAreTextBinaryOrTooLarge() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "code-docs-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "one\r\ntwo\n".write(to: folder.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x00, 0x01]).write(to: folder.appending(path: "b.png"))
        try Data(count: CodeWorkspace.maxDocumentBytes + 1).write(to: folder.appending(path: "c.bin"))

        #expect(CodeWorkspace.document(at: folder.appending(path: "a.txt")) == .text(lines: ["one", "two"]))
        #expect(CodeWorkspace.document(at: folder.appending(path: "b.png")) == .binary)
        #expect(CodeWorkspace.document(at: folder.appending(path: "c.bin")) == .tooLarge(bytes: CodeWorkspace.maxDocumentBytes + 1))
        #expect(CodeWorkspace.document(at: folder.appending(path: "nope")) == .missing)
    }

    @Test func textSearchFindsLinesCaseInsensitively() async throws {
        let repo = try await TestRepository.make()
        defer { repo.delete() }
        try write("x = 1\n    gateway.refund(order)\n", "views.py", in: repo)
        let hits = await CodeWorkspace(root: repo.root, baseBranch: nil, git: repo.git).search("REFUND", in: ["README.md", "views.py"])
        #expect(hits == [CodeSearchHit(path: "views.py", line: 2, text: "gateway.refund(order)", matchStart: 8, matchLength: 6)])
    }

    @Test func unifiedDiffHunksBecomeAddedLineRanges() {
        let diff = """
        diff --git a/a.py b/a.py
        --- a/a.py
        +++ b/a.py
        @@ -3 +3,2 @@ def x():
        @@ -10,2 +11,0 @@
        @@ -20 +20 @@
        diff --git a/gone.py b/gone.py
        --- a/gone.py
        +++ /dev/null
        @@ -1,3 +0,0 @@
        """
        #expect(CodeWorkspace.addedLines(inUnifiedDiff: diff) == ["a.py": [3...4, 20...20]])
    }
}

@Suite struct CodeTreeTests {
    @Test func rowsShowFoldersFirstAndOnlyInsideExpandedFolders() {
        let tree = CodeTree(files: ["b.py", "orders/views.py", "orders/tests/test_a.py", "a.md", "payments/gateway.py", "orders/__init__.py"])

        #expect(tree.rows(expanded: []).map(\.id) == ["d:orders", "d:payments", "f:a.md", "f:b.py"])
        #expect(tree.rows(expanded: ["orders", "orders/tests"]).map(\.id) == [
            "d:orders", "d:orders/tests", "f:orders/tests/test_a.py", "f:orders/__init__.py", "f:orders/views.py",
            "d:payments", "f:a.md", "f:b.py",
        ])
        #expect(tree.rows(expanded: ["orders/tests"]).map(\.id) == ["d:orders", "d:payments", "f:a.md", "f:b.py"])
        #expect(tree.rows(expanded: ["orders"]).first { $0.path == "orders/views.py" }?.depth == 1)
    }
}

