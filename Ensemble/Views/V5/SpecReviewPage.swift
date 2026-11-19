import AppKit
import EnsembleCore
import EnsembleUI
import SwiftUI
import WebKit

struct SpecReviewPage: View {
    @Environment(AppModel.self) private var model
    let path: String
    let project: Project
    @State private var review: SpecReviewStatus?

    var body: some View {
        let _ = model.leadChatRevision
        let document = model.specDocument(atPath: path)
        Group {
            if let link = review?.url.flatMap(URL.init(string:)) {
                SpecWebView(content: .link(link))
                    .id(link)
            } else if let review {
                VStack(alignment: .leading, spacing: 0) {
                    ReadOnlyNotice(reason: review.reason ?? "The spec is read-only.")
                    SpecWebView(content: .html(document.map { SpecPageRenderer().render($0) } ?? ""))
                        .id("read-only")
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: ReviewKey(path: path, status: document?.status)) { await load() }
    }

    private struct ReviewKey: Hashable {
        let path: String
        let status: SpecStatus?
    }

    private func load() async {
        guard let chatID = model.specChatID(atPath: path) else {
            review = SpecReviewStatus(reason: "This spec isn’t linked to a chat, so it opens read-only.")
            return
        }
        review = await model.specReview(chatID: chatID, in: project)
    }
}

private struct ReadOnlyNotice: View {
    let reason: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye").foregroundStyle(Tokens.text2).accessibilityHidden(true)
            Text(reason).foregroundStyle(Tokens.text2).lineLimit(2)
        }
        .font(.system(size: 12.5))
        .padding(EdgeInsets(top: 2, leading: 22, bottom: 10, trailing: 16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Read-only: \(reason)")
    }
}

struct SpecWebView: NSViewRepresentable {
    enum Content: Equatable {
        case link(URL)
        case html(String)
    }

    let content: Content

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if case .html = content { configuration.defaultWebpagePreferences.allowsContentJavaScript = false }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        context.coordinator.show(content, in: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.show(content, in: view)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private var shown: Content?

        func show(_ content: Content, in view: WKWebView) {
            guard content != shown else { return }
            shown = content
            switch content {
            case .link(let url): view.load(URLRequest(url: url))
            case .html(let html): view.loadHTMLString(html, baseURL: nil)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard action.navigationType == .linkActivated, action.targetFrame?.isMainFrame ?? true,
                  let url = action.request.url, !Self.isLocal(url) else {
                decisionHandler(.allow)
                return
            }
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url { NSWorkspace.shared.open(url) }
            return nil
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
            let alert = NSAlert()
            alert.messageText = message
            alert.runModal()
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }

        static func isLocal(_ url: URL) -> Bool {
            ["127.0.0.1", "localhost", "::1"].contains(url.host() ?? "") || url.scheme == "about"
        }
    }
}
