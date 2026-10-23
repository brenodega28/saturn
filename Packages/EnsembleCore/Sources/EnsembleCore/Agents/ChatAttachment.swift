import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ChatAttachmentError: Error, LocalizedError, Equatable {
    case notAnImage(String)
    case tooLarge(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .notAnImage(let name): "“\(name)” isn’t an image. Attach PNG, JPEG, GIF, WebP, HEIC or TIFF files."
        case .tooLarge(let name): "“\(name)” is too large to send, even after shrinking it."
        case .unreadable(let name): "Couldn’t read the image “\(name)”."
        }
    }
}

public enum ChatAttachment: Codable, Sendable, Hashable, Identifiable {
    case image(id: UUID, mediaType: String, fileName: String, data: Data)
    case pastedText(id: UUID, index: Int, text: String)

    public static let collapseCharacterCount = 800
    public static let collapseLineCount = 10
    public static let imagePlaceholder = "[image]"

    public var id: UUID {
        switch self {
        case .image(let id, _, _, _), .pastedText(let id, _, _): id
        }
    }

    public var isImage: Bool {
        if case .image = self { return true }
        return false
    }

    public var imageData: Data? {
        if case .image(_, _, _, let data) = self { return data }
        return nil
    }

    public var pastedText: String? {
        if case .pastedText(_, _, let text) = self { return text }
        return nil
    }

    public var lineCount: Int {
        switch self {
        case .image: 0
        case .pastedText(_, _, let text): Self.lineCount(of: text)
        }
    }

    public var label: String {
        switch self {
        case .image(_, _, let fileName, _):
            return fileName
        case .pastedText(_, let index, _):
            let lines = lineCount
            return "Pasted text #\(index) · \(lines) line\(lines == 1 ? "" : "s")"
        }
    }

    public static func lineCount(of text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return text.hasSuffix("\n") ? lines.count - 1 : lines.count
    }

    public static func shouldCollapse(_ text: String) -> Bool {
        text.count > collapseCharacterCount || lineCount(of: text) > collapseLineCount
    }

    public static func nextPasteIndex(after attachments: [ChatAttachment]) -> Int {
        (attachments.compactMap { attachment -> Int? in
            if case .pastedText(_, let index, _) = attachment { return index }
            return nil
        }.max() ?? 0) + 1
    }

    public static func prompt(text: String, attachments: [ChatAttachment]) -> String {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pastes = attachments.compactMap { attachment -> String? in
            guard case .pastedText(_, let index, let pasted) = attachment else { return nil }
            return "<pasted-text number=\"\(index)\">\n\(pasted)\n</pasted-text>"
        }
        return ([typed].filter { !$0.isEmpty } + pastes).joined(separator: "\n\n")
    }

    public static func image(data: Data, fileName: String) throws -> ChatAttachment {
        let normalized = try ChatImage.normalize(data, fileName: fileName)
        return .image(id: UUID(), mediaType: normalized.mediaType, fileName: normalized.fileName, data: normalized.data)
    }

    public static func image(contentsOf url: URL) throws -> ChatAttachment {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ChatAttachmentError.unreadable(url.lastPathComponent)
        }
        return try image(data: data, fileName: url.lastPathComponent)
    }
}

public enum ChatImage {
    public static let maximumPixelSize = 2000
    public static let maximumEncodedBytes = 5 * 1024 * 1024
    public static let passThroughTypes: [String: String] = [
        UTType.png.identifier: "image/png",
        UTType.jpeg.identifier: "image/jpeg",
        UTType.gif.identifier: "image/gif",
        UTType.webP.identifier: "image/webp",
    ]

    public struct Normalized: Sendable, Hashable {
        public let data: Data
        public let mediaType: String
        public let fileName: String
        public let pixelWidth: Int
        public let pixelHeight: Int
    }

    public static func encodedSize(of byteCount: Int) -> Int {
        (byteCount + 2) / 3 * 4
    }

    public static func normalize(_ data: Data, fileName: String) throws -> Normalized {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              CGImageSourceGetCount(source) > 0,
              UTType(type)?.conforms(to: .image) == true else {
            throw ChatAttachmentError.notAnImage(fileName)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0 else { throw ChatAttachmentError.unreadable(fileName) }

        if let mediaType = passThroughTypes[type], max(width, height) <= maximumPixelSize,
           encodedSize(of: data.count) <= maximumEncodedBytes {
            return Normalized(data: data, mediaType: mediaType, fileName: fileName, pixelWidth: width, pixelHeight: height)
        }

        var edge = min(maximumPixelSize, max(width, height))
        while edge > 0 {
            guard let image = thumbnail(of: source, maximumEdge: edge) else { throw ChatAttachmentError.unreadable(fileName) }
            for encoding in encodings {
                guard let encoded = encode(image, as: encoding.type, quality: encoding.quality) else { continue }
                if encodedSize(of: encoded.count) <= maximumEncodedBytes {
                    return Normalized(
                        data: encoded, mediaType: encoding.mediaType, fileName: renamed(fileName, extension: encoding.fileExtension),
                        pixelWidth: image.width, pixelHeight: image.height
                    )
                }
            }
            edge = edge * 3 / 4
        }
        throw ChatAttachmentError.tooLarge(fileName)
    }

    private struct Encoding {
        let type: UTType
        let mediaType: String
        let fileExtension: String
        let quality: Double?
    }

    private static let encodings = [Encoding(type: .png, mediaType: "image/png", fileExtension: "png", quality: nil)]
        + [0.85, 0.7, 0.5].map { Encoding(type: .jpeg, mediaType: "image/jpeg", fileExtension: "jpg", quality: $0) }

    private static func thumbnail(of source: CGImageSource, maximumEdge: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumEdge,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double?) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        var options: [CFString: Any] = [:]
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func renamed(_ fileName: String, extension fileExtension: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        return (base.isEmpty ? "image" : base) + "." + fileExtension
    }
}

public enum StoredChatAttachment: Codable, Sendable, Hashable, Identifiable {
    case image(id: UUID, mediaType: String, fileName: String, path: String)
    case pastedText(id: UUID, index: Int, text: String)

    public var id: UUID {
        switch self {
        case .image(let id, _, _, _), .pastedText(let id, _, _): id
        }
    }

    public var imageURL: URL? {
        if case .image(_, _, _, let path) = self { return URL(fileURLWithPath: path) }
        return nil
    }

    public var label: String {
        switch self {
        case .image(_, _, let fileName, _): fileName
        case .pastedText(let id, let index, let text): ChatAttachment.pastedText(id: id, index: index, text: text).label
        }
    }

    public var attachment: ChatAttachment? {
        switch self {
        case .image(let id, let mediaType, let fileName, let path):
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
            return .image(id: id, mediaType: mediaType, fileName: fileName, data: data)
        case .pastedText(let id, let index, let text):
            return .pastedText(id: id, index: index, text: text)
        }
    }
}

extension [StoredChatAttachment] {
    public var attachments: [ChatAttachment] { compactMap(\.attachment) }
}

public struct ChatAttachmentStore: Sendable {
    public let paths: AppPaths

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public func store(_ attachments: [ChatAttachment]) throws -> [StoredChatAttachment]? {
        guard !attachments.isEmpty else { return nil }
        return try attachments.map { attachment in
            switch attachment {
            case .image(let id, let mediaType, let fileName, let data):
                let url = paths.attachment(id, fileExtension: Self.fileExtension(for: mediaType))
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                return .image(id: id, mediaType: mediaType, fileName: fileName, path: url.path)
            case .pastedText(let id, let index, let text):
                return .pastedText(id: id, index: index, text: text)
            }
        }
    }

    static func fileExtension(for mediaType: String) -> String {
        UTType(mimeType: mediaType)?.preferredFilenameExtension ?? "img"
    }
}
