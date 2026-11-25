import Foundation
import Testing
@testable import SaturnCore

@Suite struct CommandRunnerTests {
    let shell = URL(fileURLWithPath: "/bin/sh")

    @Test func capturesOutputErrorAndExitCode() async throws {
        let result = try await CommandRunner().run(shell, ["-c", "echo out; echo err >&2; exit 4"])

        #expect(result == CommandResult(exitCode: 4, standardOutput: "out\n", standardError: "err\n"))
        #expect(!result.succeeded)
    }

    @Test func drainsLargeOutputWithoutDeadlocking() async throws {
        let result = try await CommandRunner().run(shell, ["-c", "head -c 1000000 /dev/zero | tr '\\0' a; head -c 200000 /dev/zero | tr '\\0' b >&2"])

        #expect(result.standardOutput.count == 1_000_000)
        #expect(result.standardError.count == 200_000)
    }

    @Test func runsInDirectoryWithEnvironment() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "saturn-cwd-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await CommandRunner(environment: ["GREETING": "hi"]).run(shell, ["-c", "echo $GREETING; basename \"$PWD\""], in: directory)

        #expect(result.standardOutput == "hi\n\(directory.lastPathComponent)\n")
    }

    @Test func checkedRunThrowsWithStandardErrorAsMessage() async {
        await #expect {
            try await CommandRunner().runChecked(shell, ["-c", "echo 'fatal: nope' >&2; exit 1"])
        } throws: { error in
            (error as? CommandError)?.errorDescription == "fatal: nope"
        }
    }
}
