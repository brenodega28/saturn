import Foundation
import Testing
@testable import EnsembleCore

struct ComposerCompletionTests {
    @Test func aLeadingSlashCompletesCommands() {
        #expect(ComposerCompletion.token(in: "/st") == .command("st"))
        #expect(ComposerCompletion.token(in: "/status now") == nil)
        #expect(ComposerCompletion.commands(matching: "st").map(\.name) == ["/status", "/stop"])
        #expect(ComposerCompletion.completing("/st", with: "/stop") == "/stop ")
    }

    @Test func aTrailingAtCompletesFiles() {
        #expect(ComposerCompletion.token(in: "look at @exp") == .file("exp"))
        #expect(ComposerCompletion.token(in: "look at @exp ") == nil)
        #expect(ComposerCompletion.token(in: "mail me@") == nil)
        #expect(ComposerCompletion.completing("look at @exp", with: "backend/orders/export.py") == "look at @backend/orders/export.py ")
        let paths = ["README.md", "backend/orders/export.py", "frontend/src/admin/ExportButton.tsx", "docs/exports.md"]
        let exports = ComposerCompletion.files(paths, matching: "export")
        #expect(exports.contains("backend/orders/export.py") && exports.contains("docs/exports.md"))
        #expect(!exports.contains("README.md"))
        #expect(ComposerCompletion.files(paths, matching: "", limit: 2) == ["README.md", "backend/orders/export.py"])
        #expect(ComposerCompletion.files(paths, matching: "zzz").isEmpty)
    }

    @Test func commandsAreParsedFromWhatYouSend() {
        #expect(ChatCommand.parse("/stop") == .stop)
        #expect(ChatCommand.parse("  /Retry please") == .retry)
        #expect(ChatCommand.parse("/unknown") == nil)
        #expect(ChatCommand.parse("stop") == nil)
        #expect(ChatCommand.stop.runsLocally && !ChatCommand.spec.runsLocally)
    }
}
