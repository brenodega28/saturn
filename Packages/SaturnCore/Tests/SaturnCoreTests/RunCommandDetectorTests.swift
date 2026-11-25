import Foundation
import Testing
@testable import SaturnCore

@Suite struct RunCommandDetectorTests {
    struct Fixture {
        let folder: URL

        init(_ files: [String: String]) throws {
            folder = FileManager.default.temporaryDirectory.appending(path: "saturn-detect-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, contents) in files {
                try contents.write(to: folder.appending(path: name), atomically: true, encoding: .utf8)
            }
        }

        func delete() {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    static let package = #"{"name":"shop","scripts":{"dev":"vite","build":"vite build"}}"#

    @Test(arguments: [
        (nil, "npm"),
        ("pnpm-lock.yaml", "pnpm"),
        ("yarn.lock", "yarn"),
        ("bun.lockb", "bun"),
        ("bun.lock", "bun"),
    ] as [(String?, String)])
    func packageDevScriptUsesTheLockfilesTool(lockfile: String?, tool: String) throws {
        var files = ["package.json": Self.package]
        if let lockfile { files[lockfile] = "" }
        let fixture = try Fixture(files)
        defer { fixture.delete() }

        let detected = try #require(RunCommandDetector.detect(in: fixture.folder))
        #expect(detected.command == "\(tool) run dev")
        #expect(detected.source == .packageScript(tool: tool))
        #expect(detected.label == "\(tool) run dev")
    }

    @Test func packageWithoutDevScriptFallsThroughToMakefile() throws {
        let fixture = try Fixture([
            "package.json": #"{"scripts":{"start":"node server.js"}}"#,
            "Makefile": "build:\n\tgo build\n\ndev: build\n\t./server\n",
        ])
        defer { fixture.delete() }

        #expect(RunCommandDetector.detect(in: fixture.folder) == DetectedRunCommand(command: "make dev", source: .makefile))
    }

    @Test func makefileDevTarget() throws {
        let fixture = try Fixture(["Makefile": ".PHONY: dev\ndev:\n\tpython manage.py runserver\n"])
        defer { fixture.delete() }

        let detected = try #require(RunCommandDetector.detect(in: fixture.folder))
        #expect(detected.command == "make dev")
        #expect(detected.source == .makefile)
    }

    @Test func makefileWithoutDevTargetIsIgnored() throws {
        let fixture = try Fixture(["Makefile": "dev := 1\ndevelop:\n\techo no\nbuild:\n\techo build\n"])
        defer { fixture.delete() }

        #expect(RunCommandDetector.detect(in: fixture.folder) == nil)
    }

    @Test func procfileRunsEveryProcess() throws {
        let fixture = try Fixture(["Procfile": "# processes\nweb: bundle exec rails s -p $PORT\nworker: bundle exec sidekiq\n\n"])
        defer { fixture.delete() }

        let detected = try #require(RunCommandDetector.detect(in: fixture.folder))
        #expect(detected.source == .procfile)
        #expect(detected.label == "Procfile")
        #expect(detected.command == "(bundle exec rails s -p $PORT) &\n(bundle exec sidekiq) &\nwait")
    }

    @Test func nothingDetected() throws {
        let fixture = try Fixture(["README.md": "# hi"])
        defer { fixture.delete() }

        #expect(RunCommandDetector.detect(in: fixture.folder) == nil)
        #expect(RunCommandDetector.resolve(override: "  ", in: fixture.folder) == nil)
    }

    @Test func overrideWinsAndEmptyOverrideFallsBack() throws {
        let fixture = try Fixture(["package.json": Self.package])
        defer { fixture.delete() }

        #expect(RunCommandDetector.resolve(override: " ./bin/dev \n", in: fixture.folder) == DetectedRunCommand(command: "./bin/dev", source: .override))
        #expect(RunCommandDetector.resolve(override: "", in: fixture.folder)?.command == "npm run dev")
    }

    @Test func runCommandSettingDecodesWhenMissing() throws {
        let decoded = try JSONDecoder().decode(ProjectSettings.self, from: Data(#"{"maxConcurrentAgents":2}"#.utf8))
        #expect(decoded.runCommand == "")
        var settings = ProjectSettings()
        settings.runCommand = "make serve"
        let roundTrip = try JSONDecoder().decode(ProjectSettings.self, from: JSONEncoder().encode(settings))
        #expect(roundTrip.runCommand == "make serve")
    }

    @Test func serverOutputHelpers() {
        #expect(ServerOutput.clean("\u{1B}[32m  ➜  Local:\u{1B}[0m   http://localhost:\u{1B}[1m5173\u{1B}[22m/") == "➜  Local:   http://localhost:5173/")
        #expect(ServerOutput.localPort(in: "Local: http://localhost:5173/") == 5173)
        #expect(ServerOutput.localPort(in: "Starting development server at http://127.0.0.1:8000/") == 8000)
        #expect(ServerOutput.localPort(in: "Listening on 0.0.0.0:3000") == 3000)
        #expect(ServerOutput.localPort(in: "Serving at http://[::1]:4000") == 4000)
        #expect(ServerOutput.localPort(in: "Network: http://192.168.1.4:5173/") == nil)
        #expect(ServerOutput.looksLikeError("Error: listen EADDRINUSE"))
        #expect(!ServerOutput.looksLikeError("compiled in 120ms"))
    }
}
