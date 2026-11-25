import Foundation
import Testing
@testable import SaturnCore

@Suite struct InstanceLockTests {
    private func temporaryPaths() -> AppPaths {
        AppPaths(root: FileManager.default.temporaryDirectory.appending(path: "saturn-lock-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    @Test func secondAcquireOnTheSameRootThrowsWithTheHolderPID() throws {
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let first = try InstanceLock.acquire(paths: paths)
        #expect(first.url == paths.root.appending(path: "saturn.lock"))
        #expect(throws: InstanceLockError.alreadyRunning(pid: getpid())) {
            try InstanceLock.acquire(paths: paths)
        }
        first.release()
    }

    @Test func acquireSucceedsAfterRelease() throws {
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let first = try InstanceLock.acquire(paths: paths)
        first.release()
        let second = try InstanceLock.acquire(paths: paths)
        second.release()
    }

    @Test func droppingTheLockReleasesIt() throws {
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var first: InstanceLock? = try InstanceLock.acquire(paths: paths)
        #expect(first != nil)
        first = nil
        let second = try InstanceLock.acquire(paths: paths)
        second.release()
    }

    @Test func differentRootsAreIndependent() throws {
        let one = temporaryPaths()
        let two = temporaryPaths()
        defer {
            try? FileManager.default.removeItem(at: one.root)
            try? FileManager.default.removeItem(at: two.root)
        }
        let first = try InstanceLock.acquire(paths: one)
        let second = try InstanceLock.acquire(paths: two)
        first.release()
        second.release()
    }

    @Test func lockHeldByAnotherProcessBlocksAcquire() throws {
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let lockFile = InstanceLock.lockFile(in: paths)
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        holder.arguments = [
            "-e",
            "use Fcntl qw(:flock); open(my $f, '>>', $ARGV[0]) or die; flock($f, LOCK_EX) or die; $| = 1; print \"locked\\n\"; sleep 30;",
            lockFile.path,
        ]
        let output = Pipe()
        holder.standardOutput = output
        try holder.run()
        defer {
            if holder.isRunning {
                holder.terminate()
                holder.waitUntilExit()
            }
        }
        let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        #expect(line.hasPrefix("locked"))

        #expect {
            try InstanceLock.acquire(paths: paths)
        } throws: { error in
            if case InstanceLockError.alreadyRunning = error { return true }
            return false
        }

        holder.terminate()
        holder.waitUntilExit()
        let after = try InstanceLock.acquire(paths: paths)
        after.release()
    }
}
