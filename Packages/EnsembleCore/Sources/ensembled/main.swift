import Darwin
import EnsembleCore
import Foundation

enum Exit {
    static let usage: Int32 = 64
    static let alreadyRunning: Int32 = 75
    static let failure: Int32 = 1
}

func fail(_ message: String, code: Int32 = Exit.failure) -> Never {
    FileHandle.standardError.write(Data("ensembled: \(message)\n".utf8))
    exit(code)
}

func dataDirectory(in arguments: [String]) -> AppPaths {
    guard let index = arguments.firstIndex(of: "--data-dir") else { return AppPaths.standard }
    guard index + 1 < arguments.count else { fail("--data-dir needs a path", code: Exit.usage) }
    let path = (arguments[index + 1] as NSString).expandingTildeInPath
    return AppPaths(root: URL(fileURLWithPath: path, isDirectory: true))
}

func printVersion() {
    let info = ["protocolVersion": "\(EnsembleProtocol.version)", "buildVersion": EnsembleProtocol.buildVersion]
    let data = (try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys])) ?? Data()
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

func copy(from source: Int32, to destination: Int32) {
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { return }
        var offset = 0
        while offset < count {
            let written = buffer.withUnsafeBytes { write(destination, $0.baseAddress! + offset, count - offset) }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { return }
            offset += written
        }
    }
}

func attach(paths: AppPaths) -> Never {
    signal(SIGPIPE, SIG_IGN)
    let socket: Int32
    do {
        socket = try UnixSocket.connect(path: paths.daemonSocket.path)
    } catch {
        fail("The Ensemble daemon isn’t running at \(paths.root.path): \(error.localizedDescription)")
    }
    let upstream = Thread {
        copy(from: STDIN_FILENO, to: socket)
        shutdown(socket, SHUT_WR)
    }
    upstream.start()
    copy(from: socket, to: STDOUT_FILENO)
    exit(0)
}

@MainActor
func serve(paths: AppPaths) async -> Never {
    signal(SIGPIPE, SIG_IGN)
    let host: EnsembleHost
    do {
        host = try await EnsembleHost.start(paths: paths, secrets: KeychainSecretStore(service: "dev.monoliti.Ensemble"))
    } catch let error as InstanceLockError {
        if case .alreadyRunning = error {
            let underLaunchd = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == "dev.monoliti.ensembled"
            fail("Another ensembled is already serving \(paths.root.path). \(error.localizedDescription)", code: underLaunchd ? 0 : Exit.alreadyRunning)
        }
        fail(error.localizedDescription)
    } catch {
        fail(error.localizedDescription)
    }
    FileHandle.standardError.write(Data("ensembled: serving \(paths.root.path) as \(host.identity.name) (\(host.identity.id.uuidString.lowercased()))\n".utf8))
    host.onStop = { exit(0) }
    var sources: [DispatchSourceSignal] = []
    for code in [SIGTERM, SIGINT, SIGHUP] {
        signal(code, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: code, queue: .main)
        source.setEventHandler {
            Task { @MainActor in await host.stop() }
        }
        source.resume()
        sources.append(source)
    }
    while true {
        try? await Task.sleep(for: .seconds(3600))
        _ = sources.count
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "serve":
    await serve(paths: dataDirectory(in: arguments))
case "attach":
    attach(paths: dataDirectory(in: arguments))
case "version":
    printVersion()
default:
    fail("usage: ensembled serve [--data-dir <path>] | attach [--data-dir <path>] | version", code: Exit.usage)
}
