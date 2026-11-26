import Foundation
import Testing
@testable import SaturnCore

@MainActor
@Suite(.serialized, .timeLimit(.minutes(3))) struct RemoteAccessBridgeTests {
    @Test func framesCarryOneProtocolMessageEachFromHelloToLiveChanges() async throws {
        let h = try await DaemonHarness.make()
        let port = try await h.enableRemoteAccess()
        let (token, _) = try h.pairedToken()
        let socket = h.remoteSocket(port: port, token: token)
        let messages = try await socket.handshake()

        guard case .welcome(let welcome) = messages.first else { Issue.record("Expected welcome first, got \(messages)"); return }
        #expect(welcome.daemon.id == h.host.identity.id)
        guard case .snapshotBegin(let begin) = messages[1] else { Issue.record("Expected snapshotBegin, got \(messages[1])"); return }
        let chunks = messages.compactMap { message -> Data? in
            if case .snapshotChunk(let chunk) = message { return chunk.data }
            return nil
        }
        #expect(Int64(chunks.reduce(0) { $0 + $1.count }) == begin.size)
        #expect(messages.contains { if case .snapshotEnd = $0 { return true } else { return false } })
        guard case .live = messages.last else { Issue.record("Expected live last"); return }
        #expect(socket.frames.allSatisfy { !$0.contains("\n") })
        #expect(socket.frames.count == messages.count)

        let project = try await h.host.perform(ProjectCommands.Open(path: h.repo.root.path))
        let projectID = try #require(project.id)
        var changed: [RowChange] = []
        while !changed.contains(where: { $0.table == "project" && $0.rowID == projectID }) {
            if case .changes(let batch) = try await socket.next() { changed += batch.changes }
        }

        let result = try await socket.perform(ChatCommands.CreateEmpty(projectID: projectID, title: "From the phone", body: "Hi"))
        let chat = try CommandCoding.response(of: ChatCommands.CreateEmpty.self, from: result)
        #expect(chat.title == "From the phone")
        #expect(try h.host.database.task(id: chat.id!)?.title == "From the phone")

        socket.close()
        _ = try await socket.closeCode()
        try await waitUntil { h.host.status().clients == 0 }
        await h.cleanUp()
    }

    @Test func prettyPrintedFramesStillArriveAsOneLine() async throws {
        let h = try await DaemonHarness.make()
        let port = try await h.enableRemoteAccess()
        let (token, _) = try h.pairedToken()
        let socket = h.remoteSocket(port: port, token: token)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let hello = String(decoding: try encoder.encode(ProtocolMessage.hello(Hello(clientID: UUID()))), as: UTF8.self)
        #expect(hello.contains("\n"))
        socket.sendRaw(hello)
        guard case .welcome = try await socket.next() else { Issue.record("Expected welcome"); return }
        socket.sendRaw("not json")
        var refused = false
        while !refused {
            if case .refused(let refusal) = try await socket.next() { refused = refusal.code == .badRequest }
        }
        socket.close()
        await h.cleanUp()
    }

    @Test func remoteClientsCantRunCommandsOutsideTheAllowlist() async throws {
        let h = try await DaemonHarness.make()
        let port = try await h.enableRemoteAccess()
        let project = try await h.host.perform(ProjectCommands.Open(path: h.repo.root.path))
        let projectID = try #require(project.id)
        let (token, device) = try h.pairedToken()
        let socket = h.remoteSocket(port: port, token: token)
        try await socket.handshake()

        let scratch = DaemonTestPaths.shortDirectory("rf")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let written = scratch.appending(path: "written.txt")
        let kept = scratch.appending(path: "kept.txt")
        try "keep me".write(to: kept, atomically: true, encoding: .utf8)
        let gitTarget = scratch.appending(path: "repo", directoryHint: .isDirectory)

        func expectForbidden<C: DaemonCommand>(_ command: C) async throws {
            let result = try await socket.perform(command)
            #expect(result.ok == nil, "\(C.name)")
            #expect(result.error?.code == .forbidden, "\(C.name): \(String(describing: result.error))")
        }

        try await expectForbidden(CodeCommands.Exec(projectID: projectID, arguments: ["init", gitTarget.path], directory: scratch.path))
        try await expectForbidden(CodeCommands.WriteFile(path: written.path, data: Data("pwned".utf8)))
        try await expectForbidden(CodeCommands.RemoveItem(path: kept.path))
        try await expectForbidden(SettingsCommands.SaveAPIKey(key: "sk-ant-remote"))
        try await expectForbidden(SettingsCommands.Shutdown())
        try await expectForbidden(RemoteAccessCommands.Status())
        try await expectForbidden(RemoteAccessCommands.SetEnabled(enabled: false))
        try await expectForbidden(RemoteAccessCommands.BeginPairing())
        try await expectForbidden(RemoteAccessCommands.Revoke(deviceID: device.id))
        try await expectForbidden(ChatCommands.Delete(chatID: 1))
        try await expectForbidden(ProjectCommands.Open(path: scratch.path))

        try await Task.sleep(for: .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: gitTarget.appending(path: ".git").path))
        #expect(!FileManager.default.fileExists(atPath: written.path))
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(try h.host.secrets.read(.anthropicAPIKey) == nil)
        #expect(!h.host.isStopped)
        #expect(h.remote.isListening)
        #expect(h.remote.devices.map(\.id) == [device.id])

        let status = try await socket.perform(SettingsCommands.Status())
        #expect(status.error == nil)
        let secret = scratch.appending(path: "id_ed25519")
        try "PRIVATE KEY".write(to: secret, atomically: true, encoding: .utf8)
        let read = try await socket.perform(CodeCommands.ReadFile(path: secret.path))
        #expect(read.ok == nil)
        #expect(read.error?.code == .forbidden)
        #expect(!socket.frames.contains { $0.contains(Data("PRIVATE KEY".utf8).base64EncodedString()) })
        let localRead = try await h.host.perform(CodeCommands.ReadFile(path: secret.path))
        #expect(localRead == Data("PRIVATE KEY".utf8))

        let local = try await h.host.perform(CodeCommands.FileExists(path: kept.path))
        #expect(local)
        socket.close()
        await h.cleanUp()
    }

    @Test func remoteClientsOnlyStreamAllowedFiles() async throws {
        let h = try await DaemonHarness.make()
        let port = try await h.enableRemoteAccess()
        let (token, _) = try h.pairedToken()
        let socket = h.remoteSocket(port: port, token: token)
        try await socket.handshake()
        let forbidden = FileRequest(kind: .agentFile, id: "1/memory.md")
        try socket.send(.file(forbidden))
        while true {
            guard case .fileChunk(let chunk) = try await socket.next(), chunk.requestID == forbidden.requestID else { continue }
            #expect(chunk.end)
            #expect(chunk.error?.contains("remote") == true)
            break
        }
        let allowed = FileRequest(kind: .transcript, id: "999999")
        try socket.send(.file(allowed))
        while true {
            guard case .fileChunk(let chunk) = try await socket.next(), chunk.requestID == allowed.requestID else { continue }
            #expect(chunk.error == "The file doesn’t exist.")
            break
        }
        socket.close()
        await h.cleanUp()
    }

    @Test func localClientsKeepEveryCommand() async throws {
        let h = try await DaemonHarness.make()
        let client = try await h.connectedClient()
        defer { client.stop() }
        let scratch = DaemonTestPaths.shortDirectory("rl")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appending(path: "local.txt")
        try await client.send(CodeCommands.WriteFile(path: file.path, data: Data("ok".utf8)))
        #expect(FileManager.default.fileExists(atPath: file.path))
        let status = try await client.send(RemoteAccessCommands.Status())
        #expect(!status.enabled)
        await h.cleanUp()
    }
}
