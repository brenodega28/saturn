import Testing
@testable import SaturnCore

@Suite struct TempPathsTests {
    @Test func onlyPathsStrictlyBelowATempRootAreTemp() {
        for path in ["/tmp/x", "/private/tmp/a/b", "/var/folders/ab/T/x", "/private/var/folders/q", "/tmp/a/../b", "/tmp/x/*", "/tmp/x/"] {
            #expect(TempPaths.isTemp(path), "\(path)")
        }
        for path in ["/tmp", "/tmp/", "/private/tmp", "/var/folders", "/tmp/*", "/tmp/x*", "/tmp/..", "/tmp/../etc", "/tmp/x/../..", "/tmpfoo/x", "/var/tmp/x", "/Users/x", "~/tmp/x", "", "x"] {
            #expect(!TempPaths.isTemp(path), "\(path)")
        }
    }

    @Test func variablesExpandBeforeTheCheck() {
        let variables = ["S": "/private/tmp/scratch", "HOME_ISH": "/Users/me", "SPACED": "/tmp/a /etc", "GLOB": "/tmp/*"]
        #expect(TempPaths.isTemp("$S/data", variables: variables))
        #expect(TempPaths.isTemp("${S}/data", variables: variables))
        #expect(TempPaths.isTemp("$S", variables: variables))
        #expect(!TempPaths.isTemp("$S/../..", variables: variables))
        #expect(!TempPaths.isTemp("$HOME_ISH/tmp", variables: variables))
        #expect(!TempPaths.isTemp("$UNSET/x", variables: variables))
        #expect(!TempPaths.isTemp("$SPACED/x", variables: variables))
        #expect(!TempPaths.isTemp("$GLOB", variables: variables))
        #expect(!TempPaths.isTemp("${S:-/tmp/x}", variables: variables))
        #expect(!TempPaths.isTemp("$(…)/x", variables: variables))
        #expect(!TempPaths.isTemp("/tmp/x/`…`", variables: variables))
    }

    @Test func relativePathsAreTempOnlyUnderATempWorkingDirectory() {
        #expect(TempPaths.isTemp("c", cwd: "/tmp/q7"))
        #expect(TempPaths.isTemp("./c/d", cwd: "/private/tmp/q7"))
        #expect(!TempPaths.isTemp("..", cwd: "/tmp/q7"))
        #expect(!TempPaths.isTemp("c", cwd: "/tmp"))
        #expect(!TempPaths.isTemp("c", cwd: "/work/repo"))
        #expect(!TempPaths.isTemp("c", cwd: nil))
    }

    @Test func theAgentsOwnWorkspaceNeverCountsAsTemp() {
        let workspace = "/var/folders/ab/T/saturn-tests/repo"
        #expect(!TempPaths.isTemp("/private/var/folders/ab/T/saturn-tests/repo/Sources/a.swift", excluding: workspace))
        #expect(!TempPaths.isTemp("/var/folders/ab/T/saturn-tests", excluding: workspace))
        #expect(TempPaths.isTemp("/var/folders/ab/T/saturn-tests/other", excluding: workspace))
        #expect(TempPaths.isTemp("/tmp/x", excluding: "/work/repo"))
    }

    @Test func theShellContextTracksAssignmentsMktempAndCd() {
        func context(_ line: String) -> ShellContext {
            var context = ShellContext()
            ShellCommandLine(line).commands.forEach { context.record($0) }
            return context
        }
        #expect(context("S=/tmp/a").variables["S"] == "/tmp/a")
        #expect(context("export S=$TMPDIR/a").variables["S"] == "/tmp/a")
        #expect(context("D=$(mktemp -d)").isTemp("$D"))
        #expect(!context("D=$(date)").isTemp("$D"))
        #expect(!context("D=$(mktemp -d ~/x.XXXX)").isTemp("$D"))
        #expect(context("S=/tmp/a | cat").variables["S"] == nil)
        #expect(context("cd /tmp/q7 && ").cwd == "/tmp/q7")
        #expect(context("cd /tmp/q7").cwd == nil)
        #expect(context("cd /tmp/q7 && ls; ").cwd == nil)
    }
}
