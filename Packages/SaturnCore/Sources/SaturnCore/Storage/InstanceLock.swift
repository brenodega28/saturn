import Darwin
import Foundation

public enum InstanceLockError: Error, LocalizedError, Equatable {
    case alreadyRunning(pid: Int32?)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning(let pid):
            let holder = pid.map { " (process \($0))" } ?? ""
            return "Saturn is already running with this data folder\(holder). Quit the other copy first."
        case .unavailable(let reason):
            return "Saturn couldn’t lock its data folder: \(reason)"
        }
    }
}

public final class InstanceLock: @unchecked Sendable {
    public let url: URL
    private var descriptor: Int32

    private init(url: URL, descriptor: Int32) {
        self.url = url
        self.descriptor = descriptor
    }

    deinit {
        release()
    }

    public static func lockFile(in paths: AppPaths) -> URL {
        paths.root.appending(path: "saturn.lock")
    }

    public static func acquire(paths: AppPaths) throws -> InstanceLock {
        do {
            try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        } catch {
            throw InstanceLockError.unavailable(error.localizedDescription)
        }
        let url = lockFile(in: paths)
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw InstanceLockError.unavailable(String(cString: strerror(errno))) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            let holder = readPID(descriptor)
            close(descriptor)
            if failure == EWOULDBLOCK { throw InstanceLockError.alreadyRunning(pid: holder) }
            throw InstanceLockError.unavailable(String(cString: strerror(failure)))
        }
        writePID(getpid(), to: descriptor)
        return InstanceLock(url: url, descriptor: descriptor)
    }

    public func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    private static func readPID(_ descriptor: Int32) -> Int32? {
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = pread(descriptor, &buffer, buffer.count, 0)
        guard count > 0 else { return nil }
        let text = String(decoding: buffer[0..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Int32(text)
    }

    private static func writePID(_ pid: Int32, to descriptor: Int32) {
        let bytes = Array("\(pid)\n".utf8)
        ftruncate(descriptor, 0)
        _ = bytes.withUnsafeBufferPointer { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
    }
}
