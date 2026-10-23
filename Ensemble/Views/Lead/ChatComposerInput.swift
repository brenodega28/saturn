import AppKit
import EnsembleCore
import EnsembleUI
import SwiftUI
import UniformTypeIdentifiers

struct ChatComposerInput: View {
    @Environment(AppModel.self) private var model
    @Binding var text: String
    @Binding var attachments: [ChatAttachment]
    @Binding var isDropTargeted: Bool
    let placeholder: String
    let accessibilityLabel: String
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !attachments.isEmpty {
                ChatAttachmentStrip(attachments: $attachments)
            }
            ComposerTextView(
                text: $text,
                placeholder: placeholder,
                accessibilityLabel: accessibilityLabel,
                onPaste: paste,
                onDropTargeted: { isDropTargeted = $0 },
                onDrop: drop,
                onSubmit: onSubmit
            )
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 14))
                        .foregroundStyle(Color(nsColor: .placeholderTextColor))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func paste(_ pasteboard: NSPasteboard) -> Bool {
        switch ChatPasteboard.contents(of: pasteboard) {
        case .images(let images):
            add(images)
            return true
        case .text(let pasted) where ChatAttachment.shouldCollapse(pasted):
            attachments.append(.pastedText(id: UUID(), index: ChatAttachment.nextPasteIndex(after: attachments), text: pasted))
            return true
        case .text, .nonImageFiles, .nothing:
            return false
        }
    }

    private func drop(_ pasteboard: NSPasteboard) -> Bool {
        switch ChatPasteboard.contents(of: pasteboard) {
        case .images(let images):
            add(images)
            return true
        case .nonImageFiles(let names):
            reportNonImages(names)
            return true
        case .text, .nothing:
            return false
        }
    }

    private func add(_ images: [ChatPasteboard.Image]) {
        var failures: [String] = []
        for image in images {
            do {
                attachments.append(try image.attachment())
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if !failures.isEmpty {
            model.alert = AppAlert(title: "Couldn’t attach the image", message: failures.joined(separator: "\n"))
        }
    }

    private func reportNonImages(_ names: [String]) {
        model.alert = AppAlert(
            title: "Only images can be attached",
            message: names.map { ChatAttachmentError.notAnImage($0).localizedDescription }.joined(separator: "\n")
        )
    }
}

enum ChatPasteboard {
    enum Image {
        case file(URL)
        case data(Data, fileName: String)

        func attachment() throws -> ChatAttachment {
            switch self {
            case .file(let url): try ChatAttachment.image(contentsOf: url)
            case .data(let data, let fileName): try ChatAttachment.image(data: data, fileName: fileName)
            }
        }
    }

    enum Contents {
        case images([Image])
        case nonImageFiles([String])
        case text(String)
        case nothing
    }

    static let preferredImageTypes: [UTType] = [.png, .jpeg, .heic, .gif, .webP, .tiff]

    static func contents(of pasteboard: NSPasteboard) -> Contents {
        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !files.isEmpty {
            let images = files.filter(isImageFile)
            return images.isEmpty ? .nonImageFiles(files.map(\.lastPathComponent)) : .images(images.map(Image.file))
        }
        let string = pasteboard.string(forType: .string)
        if let image = imageData(in: pasteboard), string.map(isLink) ?? true {
            return .images([image])
        }
        if let string, !string.isEmpty { return .text(string) }
        return .nothing
    }

    static func hasAttachableContent(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return true }
        return pasteboard.string(forType: .string) == nil && imageType(in: pasteboard) != nil
    }

    private static func isImageFile(_ url: URL) -> Bool {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .image) == true
    }

    private static func isLink(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || (!trimmed.contains(where: \.isWhitespace) && URL(string: trimmed)?.scheme != nil)
    }

    private static func imageType(in pasteboard: NSPasteboard) -> UTType? {
        let available = (pasteboard.types ?? []).compactMap { UTType($0.rawValue) }.filter { $0.conforms(to: .image) }
        return preferredImageTypes.first { preferred in available.contains(preferred) } ?? available.first
    }

    private static func imageData(in pasteboard: NSPasteboard) -> Image? {
        guard let type = imageType(in: pasteboard),
              let data = pasteboard.data(forType: NSPasteboard.PasteboardType(type.identifier)) else { return nil }
        return .data(data, fileName: "Pasted image.\(type.preferredFilenameExtension ?? "png")")
    }
}

private struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String
    let onPaste: (NSPasteboard) -> Bool
    let onDropTargeted: (Bool) -> Void
    let onDrop: (NSPasteboard) -> Bool
    let onSubmit: () -> Void

    static let font = NSFont.systemFont(ofSize: 14)
    static let lineRange = 2...8

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        let textView = PastingTextView(frame: .zero, textContainer: container)
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.typingAttributes = [.font: Self.font, .foregroundColor: NSColor.labelColor]
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.registerForDraggedTypes([.fileURL, .png, .tiff, NSPasteboard.PasteboardType(UTType.image.identifier)])
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.setAccessibilityPlaceholderValue(placeholder)
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? PastingTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.setAccessibilityPlaceholderValue(placeholder)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.frame.width
        let lineHeight = NSLayoutManager().defaultLineHeight(for: Self.font)
        let measured = text.hasSuffix("\n") || text.isEmpty ? text + " " : text
        let height = NSAttributedString(string: measured, attributes: [.font: Self.font])
            .boundingRect(with: NSSize(width: width > 0 ? width : .greatestFiniteMagnitude, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
            .height
        let clamped = min(max(ceil(height), lineHeight * CGFloat(Self.lineRange.lowerBound)), lineHeight * CGFloat(Self.lineRange.upperBound))
        return CGSize(width: width, height: clamped)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

private final class PastingTextView: NSTextView {
    weak var coordinator: ComposerTextView.Coordinator?
    private var isDropTargeted = false

    override func paste(_ sender: Any?) {
        if coordinator?.parent.onPaste(.general) == true { return }
        super.paste(sender)
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            coordinator?.parent.onSubmit()
            return
        }
        super.keyDown(with: event)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard ChatPasteboard.hasAttachableContent(sender.draggingPasteboard) else { return super.draggingEntered(sender) }
        setDropTargeted(true)
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard ChatPasteboard.hasAttachableContent(sender.draggingPasteboard) else { return super.draggingUpdated(sender) }
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        setDropTargeted(false)
        super.draggingExited(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        setDropTargeted(false)
        guard ChatPasteboard.hasAttachableContent(sender.draggingPasteboard) else { return super.performDragOperation(sender) }
        return coordinator?.parent.onDrop(sender.draggingPasteboard) ?? false
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        setDropTargeted(false)
        super.concludeDragOperation(sender)
    }

    private func setDropTargeted(_ targeted: Bool) {
        guard isDropTargeted != targeted else { return }
        isDropTargeted = targeted
        coordinator?.parent.onDropTargeted(targeted)
    }
}

extension View {
    func chatAttachmentDrop(_ attachments: Binding<[ChatAttachment]>, isTargeted: Binding<Bool>, cornerRadius: CGFloat = 24) -> some View {
        modifier(ChatAttachmentDrop(attachments: attachments, isTargeted: isTargeted, cornerRadius: cornerRadius))
    }
}

private struct ChatAttachmentDrop: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var attachments: [ChatAttachment]
    @Binding var isTargeted: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.fileURL, .image], isTargeted: $isTargeted, perform: drop)
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Theme.accent.opacity(0.08))
                        .strokeBorder(Theme.accent, lineWidth: 2)
                        .overlay {
                            Label("Drop images to attach", systemImage: "photo.badge.plus")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        Task { @MainActor in
            var added: [ChatAttachment] = []
            var problems: [String] = []
            for provider in providers {
                do {
                    if let attachment = try await Self.attachment(from: provider) {
                        added.append(attachment)
                    } else {
                        problems.append(ChatAttachmentError.notAnImage(provider.suggestedName ?? "The dropped item").localizedDescription)
                    }
                } catch {
                    problems.append(error.localizedDescription)
                }
            }
            attachments.append(contentsOf: added)
            if !problems.isEmpty {
                model.alert = AppAlert(title: added.isEmpty ? "Only images can be attached" : "Some items weren’t attached", message: problems.joined(separator: "\n"))
            }
        }
        return true
    }

    private static func attachment(from provider: NSItemProvider) async throws -> ChatAttachment? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let data = try await loadData(provider, type: .fileURL)
            guard let url = URL(dataRepresentation: data, relativeTo: nil) else { return nil }
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension)
            guard type?.conforms(to: .image) == true else { return nil }
            return try await Task.detached { try ChatAttachment.image(contentsOf: url) }.value
        }
        let imageTypes = provider.registeredTypeIdentifiers.compactMap(UTType.init).filter { $0.conforms(to: .image) }
        guard let type = ChatPasteboard.preferredImageTypes.first(where: imageTypes.contains) ?? imageTypes.first else { return nil }
        let data = try await loadData(provider, type: type)
        let name = (provider.suggestedName ?? "Dropped image") + "." + (type.preferredFilenameExtension ?? "png")
        return try await Task.detached { try ChatAttachment.image(data: data, fileName: name) }.value
    }

    private static func loadData(_ provider: NSItemProvider, type: UTType) async throws -> Data {
        let name = provider.suggestedName ?? "item"
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(for: type) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? ChatAttachmentError.unreadable(name))
                }
            }
        }
    }
}

struct ChatAttachmentStrip: View {
    @Binding var attachments: [ChatAttachment]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    switch attachment {
                    case .image(let id, _, let fileName, let data):
                        PendingImage(id: id, data: data, name: fileName, onRemove: { remove(attachment) })
                    case .pastedText(_, _, let text):
                        PastedTextChip(label: attachment.label, text: text, onRemove: { remove(attachment) })
                    }
                }
            }
            .padding(.top, 6)
            .padding(.trailing, 6)
        }
        .scrollIndicators(.never)
    }

    private func remove(_ attachment: ChatAttachment) {
        attachments.removeAll { $0.id == attachment.id }
    }
}

private struct PendingImage: View {
    let id: UUID
    let data: Data
    let name: String
    let onRemove: () -> Void
    @State private var image: NSImage?

    var body: some View {
        ImageAttachmentThumbnail(image: image, name: name, onRemove: onRemove)
            .task(id: id) { image = NSImage(data: data) }
    }
}

struct ImageAttachmentThumbnail: View {
    let image: NSImage?
    let name: String
    var size: CGFloat = 56
    var onRemove: (() -> Void)?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.fill)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
        .overlay(alignment: .topTrailing) {
            if let onRemove {
                RemoveAttachmentButton(name: name, action: onRemove)
                    .offset(x: 6, y: -6)
            }
        }
        .help(name)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Image \(name)")
    }
}

struct PastedTextChip: View {
    let label: String
    let text: String
    var onRemove: (() -> Void)?
    @State private var isShowingText = false

    var body: some View {
        Button { isShowingText = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.plaintext")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityHidden(true)
                Text(label)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Theme.fillRaised, in: .rect(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
        }
        .buttonStyle(.plain)
        .help("Show the pasted text")
        .accessibilityLabel(label)
        .accessibilityHint("Shows the full pasted text")
        .overlay(alignment: .topTrailing) {
            if let onRemove {
                RemoveAttachmentButton(name: label, action: onRemove)
                    .offset(x: 6, y: -6)
            }
        }
        .popover(isPresented: $isShowingText, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                ScrollView {
                    Text(text)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .frame(width: 520, height: 360)
        }
    }
}

private struct RemoveAttachmentButton: View {
    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Color(white: 0.32), in: Circle())
                .overlay(Circle().strokeBorder(Color.black.opacity(0.35)))
        }
        .buttonStyle(.plain)
        .help("Remove")
        .accessibilityLabel("Remove \(name)")
    }
}
