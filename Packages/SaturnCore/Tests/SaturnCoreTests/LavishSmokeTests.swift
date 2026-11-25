import Foundation
import Testing
@testable import SaturnCore

@MainActor
@Suite struct LavishSmokeTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["LAVISH_SMOKE"] == "1"

    @Test(.enabled(if: enabled)) func theBundledLavishReviewsARenderedSpecOnLoopback() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "lavish-smoke-\(UUID().uuidString)", directoryHint: .isDirectory)
        let paths = AppPaths(root: root)
        let store = SpecStore(paths: paths)
        let draft = store.draftURL(projectId: 1, taskId: 7)
        let document = SpecDocument(title: "Smoke spec", summary: "Check Lavish.", acceptanceCriteria: [SpecCriterion(text: "alpha exists"), SpecCriterion(text: "beta exists")])
        try store.write(document, to: draft)
        let page = SpecPageRenderer.pageURL(for: draft)
        let lavish = try LavishRuntime.locate(paths: paths, environment: ToolLocator().environment())

        var delivered: [[LavishPrompt]] = []
        let session = SpecReviewSession(taskId: 7, file: page, lavish: lavish) { delivered.append($0) }
        let url = try await session.open()
        #expect(url.host() == LavishRuntime.loopback && url.port == lavish.port)
        let (_, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        session.listen()
        try await Task.sleep(for: .seconds(1))

        let listeners = try await CommandRunner().run(URL(fileURLWithPath: "/usr/sbin/lsof"), ["-nP", "-a", "-iTCP:\(lavish.port)", "-sTCP:LISTEN"])
        let addresses = listeners.standardOutput.split(separator: "\n").dropFirst().compactMap { $0.split(separator: " ").dropLast().last }
        #expect(!addresses.isEmpty && addresses.allSatisfy { $0 == "127.0.0.1:\(lavish.port)" })

        let base = "http://127.0.0.1:\(lavish.port)"
        var request = URLRequest(url: URL(string: "\(base)/api/\(url.lastPathComponent)/prompts")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(base, forHTTPHeaderField: "origin")
        let id = SpecPageRenderer.criterionID("beta exists")
        request.httpBody = Data(#"{"prompts":[{"uid":"1","prompt":"Make it measurable","selector":"li#criterion-\#(id) > span","tag":"span","text":"beta exists"}]}"#.utf8)
        _ = try await URLSession.shared.data(for: request)
        try await waitUntil { !delivered.isEmpty }
        #expect(SpecFeedback.message(for: delivered[0], document: document)?.contains("On criterion 2 “beta exists”: Make it measurable") == true)

        try await session.reply("Made it measurable.")
        #expect(session.isListening)
        await session.end()
        #expect(!session.isListening && session.url == nil)
        try? FileManager.default.removeItem(at: root)
    }
}
