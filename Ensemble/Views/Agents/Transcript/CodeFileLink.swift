import AppKit
import EnsembleCore
import EnsembleUI
import SwiftUI

struct CodeFileOpener {
    let root: String?
    let open: (String) -> Void
}

extension EnvironmentValues {
    @Entry var codeFileOpener: CodeFileOpener?
}

extension View {
    func opensCodeFiles(in projectID: Int64?, root: String?, model: AppModel) -> some View {
        environment(\.codeFileOpener, projectID.map { projectID in
            CodeFileOpener(root: root) { path in
                if !model.openCodeFile(path, cwd: root, projectID: projectID) { NSSound.beep() }
            }
        })
    }
}

extension AppModel {
    @discardableResult
    func openCodeFile(_ path: String, cwd: String?, projectID: Int64) -> Bool {
        guard let project = openProjects.first(where: { $0.id == projectID }) else { return false }
        let sources = codeSources(for: project)
        guard let location = CodeFileLocator.locate(path, cwd: cwd, roots: sources.map(\.root.path)) else { return false }
        let source = sources[location.rootIndex]
        var isDirectory: ObjCBool = false
        let file = source.root.appending(path: location.relativePath)
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        let browser = codeBrowser(for: project)
        sidebarDestination = .section(project: projectID, tab: .code)
        Task {
            if browser.source?.id != source.id || browser.snapshot == nil {
                await browser.select(source)
            }
            browser.open(location.relativePath)
        }
        return true
    }
}

struct CodeFileLink: View {
    @Environment(\.codeFileOpener) private var opener
    let path: String
    var fontSize: CGFloat = 12

    var body: some View {
        let label = CodeFileLocator.displayPath(path, root: opener?.root)
        if let opener {
            Button { opener.open(path) } label: {
                Text(label)
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(Theme.link)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Open \(label) in Code")
            .accessibilityLabel("Open \(label) in Code")
        } else {
            Text(label)
                .font(.system(size: fontSize, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

struct ElapsedLabel: View {
    let start: Date
    var end: Date?
    var prefix = ""

    var body: some View {
        Group {
            if let end {
                Text(prefix + LiveFormat.elapsed(end.timeIntervalSince(start)))
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(prefix + LiveFormat.elapsed(context.date.timeIntervalSince(start)))
                }
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(Theme.tertiaryText)
    }
}
