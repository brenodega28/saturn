import EnsembleCore
import EnsembleUI
import SwiftUI

struct CodePage: View {
    @Environment(AppModel.self) private var model
    let pageID: UUID
    let project: Project
    let path: String

    var body: some View {
        let browser = model.codeReader(for: pageID, in: project)
        let relative = browser.activePath
        VStack(spacing: 0) {
            PageHeader {
                Text(relative ?? (path as NSString).lastPathComponent)
                    .font(Tokens.mono(12.5))
                    .foregroundStyle(Tokens.text)
                    .lineLimit(1)
                    .truncationMode(.head)
                if let relative, isNewInChat(relative, browser: browser) {
                    Text("New in this chat")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Tokens.build)
                        .padding(.horizontal, 8)
                        .frame(height: 18)
                        .background(Tokens.buildBackground, in: Capsule())
                }
                Spacer(minLength: 8)
                if let branch = browser.source?.branch {
                    Text(branch).font(Tokens.mono(12.5)).lineLimit(1).truncationMode(.middle)
                }
                Text("· read-only")
            }
            CodeReader(browser: browser, project: project, showsTabs: false)
                .background(CodeStyle.background)
        }
        .overlay {
            if browser.isFinderPresented {
                CodeFinder(browser: browser) { file, line in
                    let root = browser.source?.root ?? project.url
                    model.openFile(root.appending(path: file).path, in: project, line: line)
                }
            }
        }
        .task(id: path) {
            await browser.show(file: path, line: model.pendingCodeLines.removeValue(forKey: path))
        }
    }

    private func isNewInChat(_ relative: String, browser: CodeBrowser) -> Bool {
        guard browser.change(for: relative)?.status == .added, let agent = browser.source?.agent else { return false }
        return model.chat(of: agent) != nil
    }
}

extension AppModel {
    func codeReader(for pageID: UUID, in project: Project) -> CodeBrowser {
        if let browser = codePages[pageID] { return browser }
        let browser = CodeBrowser.standalone(for: project, model: self)
        codePages[pageID] = browser
        return browser
    }
}
