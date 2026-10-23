import CoreGraphics
import Foundation
import GRDB
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import EnsembleCore

enum TestImages {
    static func encoded(width: Int, height: Int, as type: UTType, noise: Bool = false) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        if noise, let pixels = context.data {
            let words = pixels.bindMemory(to: UInt64.self, capacity: width * height / 2)
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15
            for index in 0..<(width * height / 2) {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                words[index] = state | 0xFF00_0000_FF00_0000
            }
        } else {
            context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    static func pixelSize(of data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        return (properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }
}

enum StdinRecorder {
    static func install(in harness: AgentHarness) throws {
        let loop = "while IFS= read -r line; do\n"
        #expect(FakeClaude.script.contains(loop))
        let script = FakeClaude.script.replacingOccurrences(
            of: loop, with: loop + "  printf '%s\\n' \"$line\" >> \"$FAKE_DIR/stdin.log\"\n"
        )
        let url = harness.bin.appending(path: "claude")
        try "#!/bin/sh\n\(script)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    static func lines(in harness: AgentHarness) -> [JSONValue] {
        ((try? String(contentsOf: harness.bin.appending(path: "stdin.log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").compactMap { JSONValue.parse(String($0)) }
    }

    static func imageBlocks(_ line: JSONValue) -> [JSONValue] {
        (line["message"]?["content"]?.array ?? []).filter { $0["type"]?.string == "image" }
    }
}

@Suite struct ChatAttachmentTests {
    @Test func pastedTextExpandsAfterTheTypedTextInDelimitedBlocks() {
        let attachments: [ChatAttachment] = [
            .pastedText(id: UUID(), index: 1, text: "line one\nline two"),
            .image(id: UUID(), mediaType: "image/png", fileName: "shot.png", data: Data([1])),
            .pastedText(id: UUID(), index: 2, text: "second"),
        ]
        #expect(ChatAttachment.prompt(text: "  Review these  ", attachments: attachments) == """
            Review these

            <pasted-text number="1">
            line one
            line two
            </pasted-text>

            <pasted-text number="2">
            second
            </pasted-text>
            """)
        #expect(ChatAttachment.prompt(text: "", attachments: [attachments[2]]) == "<pasted-text number=\"2\">\nsecond\n</pasted-text>")
        #expect(ChatAttachment.prompt(text: "Just text", attachments: []) == "Just text")
        #expect(ChatAttachment.prompt(text: " ", attachments: [attachments[1]]) == "")
    }

    @Test func labelsCountLinesAndLargePastesCollapse() {
        let text = (1...42).map { "line \($0)" }.joined(separator: "\n") + "\n"
        #expect(ChatAttachment.pastedText(id: UUID(), index: 1, text: text).label == "Pasted text #1 · 42 lines")
        #expect(ChatAttachment.pastedText(id: UUID(), index: 3, text: "one").label == "Pasted text #3 · 1 line")
        #expect(ChatAttachment.image(id: UUID(), mediaType: "image/png", fileName: "shot.png", data: Data()).label == "shot.png")

        #expect(ChatAttachment.shouldCollapse(text))
        #expect(ChatAttachment.shouldCollapse(String(repeating: "a", count: 801)))
        #expect(!ChatAttachment.shouldCollapse(String(repeating: "a", count: 800)))
        #expect(!ChatAttachment.shouldCollapse((1...10).map(String.init).joined(separator: "\n")))
        #expect(ChatAttachment.shouldCollapse((1...11).map(String.init).joined(separator: "\n")))

        let existing: [ChatAttachment] = [.pastedText(id: UUID(), index: 1, text: "a"), .pastedText(id: UUID(), index: 4, text: "b")]
        #expect(ChatAttachment.nextPasteIndex(after: []) == 1)
        #expect(ChatAttachment.nextPasteIndex(after: existing) == 5)
    }

    @Test func smallPNGsPassThroughUnchanged() throws {
        let png = try TestImages.encoded(width: 40, height: 30, as: .png)
        let attachment = try ChatAttachment.image(data: png, fileName: "shot.png")
        guard case .image(_, let mediaType, let fileName, let data) = attachment else { Issue.record("expected an image"); return }
        #expect(mediaType == "image/png")
        #expect(fileName == "shot.png")
        #expect(data == png)
    }

    @Test func tiffIsReencodedAsPNG() throws {
        let tiff = try TestImages.encoded(width: 40, height: 30, as: .tiff)
        let normalized = try ChatImage.normalize(tiff, fileName: "scan.tiff")
        #expect(normalized.mediaType == "image/png")
        #expect(normalized.fileName == "scan.png")
        #expect(CGImageSourceCreateWithData(normalized.data as CFData, nil).flatMap(CGImageSourceGetType) as String? == UTType.png.identifier)
        #expect(TestImages.pixelSize(of: normalized.data)! == (40, 30))
    }

    @Test func heicIsReencoded() throws {
        let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        guard writable.contains(UTType.heic.identifier) else { return }
        let heic = try TestImages.encoded(width: 40, height: 30, as: .heic)
        let normalized = try ChatImage.normalize(heic, fileName: "IMG_0001.HEIC")
        #expect(normalized.mediaType == "image/png")
        #expect(normalized.fileName == "IMG_0001.png")
    }

    @Test func oversizedImagesAreDownscaledUnderTheSizeLimit() throws {
        let big = try TestImages.encoded(width: 4000, height: 3000, as: .png, noise: true)
        #expect(ChatImage.encodedSize(of: big.count) > ChatImage.maximumEncodedBytes)

        let normalized = try ChatImage.normalize(big, fileName: "photo.png")
        let (width, height) = try #require(TestImages.pixelSize(of: normalized.data))
        #expect(max(width, height) <= ChatImage.maximumPixelSize)
        #expect(width * 3 == height * 4)
        #expect(ChatImage.encodedSize(of: normalized.data.count) <= ChatImage.maximumEncodedBytes)
        #expect(["image/png", "image/jpeg"].contains(normalized.mediaType))
    }

    @Test func largeDimensionsAreDownscaledEvenWhenTheFileIsSmall() throws {
        let wide = try TestImages.encoded(width: 3000, height: 1000, as: .jpeg)
        let normalized = try ChatImage.normalize(wide, fileName: "wide.jpg")
        #expect(TestImages.pixelSize(of: normalized.data)! == (2000, 667) || TestImages.pixelSize(of: normalized.data)! == (2000, 666))
    }

    @Test func nonImagesAreRejected() {
        #expect(throws: ChatAttachmentError.notAnImage("notes.txt")) {
            try ChatAttachment.image(data: Data("hello".utf8), fileName: "notes.txt")
        }
        #expect(throws: ChatAttachmentError.notAnImage("empty.png")) {
            try ChatAttachment.image(data: Data(), fileName: "empty.png")
        }
    }

    @Test func userLinesWithImagesCarryContentBlocksAndParseBackToText() throws {
        let image = ChatAttachment.image(id: UUID(), mediaType: "image/png", fileName: "a.png", data: Data([0, 1, 2, 3]))
        let line = ClaudeEvent.userLine("Look at this", images: [image, image])
        let json = try #require(JSONValue.parse(line))
        let blocks = try #require(json["message"]?["content"]?.array)
        #expect(blocks.map { $0["type"]?.string } == ["text", "image", "image"])
        #expect(blocks[0]["text"]?.string == "Look at this")
        #expect(blocks[1]["source"] == .object(["type": .string("base64"), "media_type": .string("image/png"), "data": .string("AAECAw==")]))
        #expect(ClaudeEvent.parse(line: line) == [.userMessage("Look at this\n[image]\n[image]")])

        let redacted = try #require(JSONValue.parse(ClaudeEvent.userLine("Look at this", images: [image], includingImageData: false)))
        #expect(redacted["message"]?["content"]?.array?[1]["source"]?["data"]?.string == ClaudeEvent.omittedImageData)
        #expect(redacted["message"]?["content"]?.array?[1]["source"]?["media_type"]?.string == "image/png")

        let imageOnly = try #require(JSONValue.parse(ClaudeEvent.userLine("", images: [image])))
        #expect(imageOnly["message"]?["content"]?.array?.map { $0["type"]?.string } == ["image"])
        #expect(ClaudeEvent.parse(line: imageOnly.compactJSON) == [.userMessage("[image]")])

        #expect(ClaudeEvent.userLine("Plain", images: []) == ClaudeEvent.userLine("Plain"))
        #expect(Transcript(lines: [line]).entries.map(\.content) == [.user("Look at this\n[image]\n[image]")])
    }

    @Test func migrationAddsAttachmentColumnsToBothMessageTables() throws {
        let database = try AppDatabase.inMemory()
        let columns = try database.writer.read { db in
            try ["leadMessage", "directMessage"].map { table in try db.columns(in: table).first { $0.name == "attachments" } }
        }
        #expect(columns.map { $0?.type } == ["TEXT", "TEXT"])
        #expect(columns.allSatisfy { $0?.isNotNull == false })
    }
}

@MainActor
@Suite(.serialized) struct ChatAttachmentSessionTests {
    @Test func attachmentsAreStoredAsFilesAndDecodedForBothMessageTables() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        let store = ChatAttachmentStore(paths: harness.runtime.paths)
        let png = try TestImages.encoded(width: 8, height: 8, as: .png)
        let attachments: [ChatAttachment] = [
            .image(id: UUID(), mediaType: "image/png", fileName: "shot.png", data: png),
            .pastedText(id: UUID(), index: 1, text: "pasted\nlines"),
        ]
        let stored = try #require(try store.store(attachments))
        #expect(try store.store([]) == nil)

        let imageURL = try #require(stored[0].imageURL)
        #expect(imageURL.deletingLastPathComponent().standardizedFileURL == harness.runtime.paths.attachmentsDirectory.standardizedFileURL)
        #expect(imageURL.lastPathComponent == "\(attachments[0].id.uuidString.lowercased()).png")
        #expect(try Data(contentsOf: imageURL) == png)

        let projectId = try #require(harness.project.id)
        let task = try harness.database.insert(ProjectTask(projectId: projectId, title: "T", body: "", source: .chat, status: .incoming, createdAt: .now, updatedAt: .now))
        try harness.database.insert(LeadMessage(projectId: projectId, taskId: task.id!, kind: .user, text: "", createdAt: .now, attachments: stored))
        try harness.database.insert(LeadMessage(projectId: projectId, taskId: task.id!, kind: .lead, text: "Hi", createdAt: .now))
        let session = try await harness.spawn()
        try await waitUntil { session.agent.status == .idle }
        try harness.database.insert(DirectMessage(projectId: projectId, agentId: session.id, kind: .user, text: "Note", createdAt: .now, attachments: stored))

        let leadMessages = try harness.database.leadMessages(taskId: task.id!)
        #expect(leadMessages.map(\.chatAttachments) == [attachments, []])
        #expect(leadMessages[1].attachments == nil)
        #expect(try harness.database.directMessages(agentId: session.id).first?.chatAttachments == attachments)

        let raw = try await harness.database.writer.read { db in try String.fetchOne(db, sql: "SELECT attachments FROM leadMessage ORDER BY id LIMIT 1") }
        #expect(raw?.contains(imageURL.lastPathComponent) == true)
        #expect(raw?.contains(png.base64EncodedString()) == false)
    }

    @Test func imagesGoToTheProcessButTheTranscriptLogKeepsOnlyAPlaceholder() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        try StdinRecorder.install(in: harness)
        let session = try await harness.spawn()
        try await waitUntil { session.agent.status == .idle }

        let png = try TestImages.encoded(width: 16, height: 16, as: .png)
        let image = try ChatAttachment.image(data: png, fileName: "shot.png")
        session.send("What is this?", images: [image, .pastedText(id: UUID(), index: 1, text: "ignored")])
        try await waitUntil { session.agent.status == .idle && harness.launches().count == 2 }

        let sent = try #require(StdinRecorder.lines(in: harness).last)
        #expect(StdinRecorder.imageBlocks(sent).map { $0["source"]?["data"]?.string } == [png.base64EncodedString()])

        let log = try String(contentsOf: harness.runtime.paths.transcript(session.id), encoding: .utf8)
        #expect(!log.contains(png.base64EncodedString()))
        #expect(log.contains(#""data":"omitted","media_type":"image/png""#))
        let users = session.transcript.entries.compactMap { entry -> String? in
            if case .user(let text) = entry.content { return text }
            return nil
        }
        #expect(users.last == "What is this?\n[image]")
    }

    @Test func queuedMessagesKeepTheirImagesWhenJoined() async throws {
        let harness = try await AgentHarness.make(mode: "slow")
        defer { harness.cleanUp() }
        try StdinRecorder.install(in: harness)
        let session = try await harness.spawn()
        try await waitUntil { session.transcript.activeTool?.name == "Bash" }

        let first = try ChatAttachment.image(data: try TestImages.encoded(width: 4, height: 4, as: .png), fileName: "one.png")
        let second = try ChatAttachment.image(data: try TestImages.encoded(width: 6, height: 6, as: .png), fileName: "two.png")
        session.send("first note", images: [first])
        session.send("", images: [second])
        session.send("third note")
        #expect(session.queuedMessages == ["first note", "", "third note"])
        #expect(session.queuedTurns.map(\.images) == [[first], [second], []])

        try harness.setMode("normal")
        session.pause()
        try await waitUntil { session.agent.status == .paused }
        session.resume()
        try await waitUntil { session.agent.status == .idle && harness.launches().count == 3 }

        let sent = try #require(StdinRecorder.lines(in: harness).last)
        let blocks = try #require(sent["message"]?["content"]?.array)
        #expect(blocks.first?["text"]?.string == "first note\n\nthird note")
        #expect(StdinRecorder.imageBlocks(sent).count == 2)
        #expect(session.queuedTurns.isEmpty)
    }
}
