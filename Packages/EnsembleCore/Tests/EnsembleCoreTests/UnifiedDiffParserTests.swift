import Foundation
import Testing
@testable import EnsembleCore

@Suite struct UnifiedDiffParserTests {
    @Test func parsesHunksWithOldAndNewLineNumbers() throws {
        let diff = """
        diff --git a/orders/views.py b/orders/views.py
        index 1111111..2222222 100644
        --- a/orders/views.py
        +++ b/orders/views.py
        @@ -41,3 +41,4 @@ class OrdersViewSet(viewsets.ModelViewSet):
             def get_queryset(self):
        -        return Order.objects.all()
        +        return Order.objects.filter(user=self.request.user)
        +        # scoped

        @@ -90 +91 @@ def other():
        -    pass
        +    return None

        """
        let files = UnifiedDiffParser.parse(diff)
        let file = try #require(files.first)
        #expect(files.count == 1)
        #expect(file.path == "orders/views.py")
        #expect(file.change == .modified)
        #expect(file.additions == 3)
        #expect(file.deletions == 2)
        #expect(file.hunks.count == 2)

        let first = file.hunks[0]
        #expect(first.section == "class OrdersViewSet(viewsets.ModelViewSet):")
        #expect(first.lines.map(\.kind) == [.context, .removed, .added, .added, .context])
        #expect(first.lines.map(\.oldLine) == [41, 42, nil, nil, 43])
        #expect(first.lines.map(\.newLine) == [41, nil, 42, 43, 44])
        #expect(first.lines[0].text == "    def get_queryset(self):")
        #expect(first.newLineRange == 41...44)

        let second = file.hunks[1]
        #expect((second.oldStart, second.oldCount, second.newStart, second.newCount) == (90, 1, 91, 1))
        #expect(second.lines.map(\.oldLine) == [90, nil])
        #expect(second.lines.map(\.newLine) == [nil, 91])
        #expect(file.patch.hasPrefix("diff --git a/orders/views.py"))
        #expect(!file.isGenerated)
    }

    @Test func parsesPureAndEditedRenames() throws {
        let diff = """
        diff --git a/old name.txt b/new name.txt
        similarity index 100%
        rename from old name.txt
        rename to new name.txt
        diff --git a/src/a.swift b/src/b.swift
        similarity index 88%
        rename from src/a.swift
        rename to src/b.swift
        index 1111111..2222222 100644
        --- a/src/a.swift
        +++ b/src/b.swift
        @@ -1,2 +1,2 @@
         let a = 1
        -let b = 2
        +let b = 3
        """
        let files = UnifiedDiffParser.parse(diff)
        #expect(files.count == 2)
        #expect(files[0].change == .renamed)
        #expect(files[0].oldPath == "old name.txt")
        #expect(files[0].newPath == "new name.txt")
        #expect(files[0].similarity == 100)
        #expect(files[0].hunks.isEmpty)
        #expect(files[1].change == .renamed)
        #expect(files[1].oldPath == "src/a.swift")
        #expect(files[1].path == "src/b.swift")
        #expect(files[1].similarity == 88)
        #expect(files[1].touchedPaths == ["src/a.swift", "src/b.swift"])
        #expect(files[1].additions == 1 && files[1].deletions == 1)
    }

    @Test func parsesBinaryNewAndDeletedFiles() {
        let diff = """
        diff --git a/logo.png b/logo.png
        new file mode 100644
        index 0000000..3333333
        Binary files /dev/null and b/logo.png differ
        diff --git a/notes/todo.md b/notes/todo.md
        new file mode 100644
        index 0000000..4444444
        --- /dev/null
        +++ b/notes/todo.md
        @@ -0,0 +1,2 @@
        +first
        +second
        diff --git a/legacy.py b/legacy.py
        deleted file mode 100644
        index 5555555..0000000
        --- a/legacy.py
        +++ /dev/null
        @@ -1 +0,0 @@
        -print("bye")
        diff --git a/icon.icns b/icon.icns
        index 6666666..7777777 100644
        GIT binary patch
        literal 4
        LcmZQzWMT#Y01f~L
        """
        let files = UnifiedDiffParser.parse(diff)
        #expect(files.map(\.path) == ["logo.png", "notes/todo.md", "legacy.py", "icon.icns"])
        #expect(files.map(\.change) == [.added, .added, .deleted, .modified])
        #expect(files.map(\.isBinary) == [true, false, false, true])
        #expect(files[0].oldPath == nil)
        #expect(files[0].newMode == "100644")
        #expect(files[1].hunks.first?.lines.map(\.newLine) == [1, 2])
        #expect(files[1].hunks.first?.lines.allSatisfy { $0.oldLine == nil } == true)
        #expect(files[2].newPath == nil)
        #expect(files[2].oldMode == "100644")
        #expect(files[2].hunks.first?.lines.map(\.oldLine) == [1])
        #expect(files[3].hunks.isEmpty)
    }

    @Test func flagsMissingNewlineAtEndOfFile() throws {
        let diff = """
        diff --git a/config.ini b/config.ini
        --- a/config.ini
        +++ b/config.ini
        @@ -1,2 +1,2 @@
         name = shop
        -debug = true
        \\ No newline at end of file
        +debug = false
        \\ No newline at end of file
        """
        let file = try #require(UnifiedDiffParser.parse(diff).first)
        let lines = try #require(file.hunks.first?.lines)
        #expect(lines.map(\.kind) == [.context, .removed, .added])
        #expect(lines.map(\.missingNewlineAtEnd) == [false, true, true])
        #expect(lines.map(\.text) == ["name = shop", "debug = true", "debug = false"])
    }

    @Test func treatsDashedContentInsideHunksAsLines() throws {
        let diff = """
        diff --git a/a.md b/a.md
        --- a/a.md
        +++ b/a.md
        @@ -1,2 +1,2 @@
        --- old rule
        +++ new rule
         unchanged
        """
        let file = try #require(UnifiedDiffParser.parse(diff).first)
        #expect(file.oldPath == "a.md")
        #expect(file.hunks.first?.lines.map(\.kind) == [.removed, .added, .context])
        #expect(file.hunks.first?.lines.map(\.text) == ["-- old rule", "++ new rule", "unchanged"])
    }

    @Test func unquotesEscapedPaths() {
        let diff = """
        diff --git "a/caf\\303\\251 \\"menu\\".txt" "b/caf\\303\\251 \\"menu\\".txt"
        new file mode 100644
        --- /dev/null
        +++ "b/caf\\303\\251 \\"menu\\".txt"
        @@ -0,0 +1 @@
        +espresso
        """
        let files = UnifiedDiffParser.parse(diff)
        #expect(files.first?.path == "café \"menu\".txt")
        #expect(files.first?.change == .added)
    }

    @Test func parsesEmptyInput() {
        #expect(UnifiedDiffParser.parse("").isEmpty)
    }
}

@Suite struct GeneratedFilesTests {
    @Test(arguments: [
        "package-lock.json", "web/yarn.lock", "Package.resolved", "App.xcodeproj/project.pbxproj",
        "App.xcworkspace/xcshareddata/swiftpm/Package.resolved", "dist/app.js", "web/build/index.html",
        "assets/vendor.min.js", "styles/site.min.css", "api/orders.pb.go", "proto/orders_pb2.py",
        "pkg/__pycache__/views.cpython-312.pyc", "go.sum", "Cargo.lock", "frontend/node_modules/react/index.js",
    ])
    func marksGeneratedPaths(_ path: String) {
        #expect(GeneratedFiles.isGenerated(path))
    }

    @Test(arguments: [
        "orders/views.py", "build.gradle", "src/builder.ts", "README.md", "package.json", "docs/distribution.md",
        "Sources/App/Lockfile.swift", "minimal.js",
    ])
    func keepsSourcePaths(_ path: String) {
        #expect(!GeneratedFiles.isGenerated(path))
    }

    @Test func parserMarksGeneratedFiles() {
        let diff = """
        diff --git a/package-lock.json b/package-lock.json
        --- a/package-lock.json
        +++ b/package-lock.json
        @@ -1 +1 @@
        -{}
        +{"lockfileVersion": 3}
        """
        #expect(UnifiedDiffParser.parse(diff).first?.isGenerated == true)
    }
}
