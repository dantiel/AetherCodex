import SwiftUI
import AppKit
import WebKit

// MARK: - File type detection

/// HTML document extensions routed to the WebKit preview instead of the code path.
enum HTMLFileType {
    static let extensions: Set<String> = ["html", "htm", "xhtml"]

    static func isHTML(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }
}

// MARK: - Model

/// State + logic for the WebKit HTML preview. Owned by `EditorViewController` so
/// the source/preview swap and the editor's title plumbing stay unified.
final class HTMLPreviewModel: ObservableObject {
    /// Source file (also the base for relative assets). Kept as the document
    /// identity for the title/status bar even in `loadHTML` (in-memory) mode.
    @Published var url: URL?
    /// When non-nil, render this in-memory string instead of re-reading disk —
    /// used for source→preview round-trips so unsaved edits are reflected.
    @Published var htmlString: String?
    /// Bumped to force the WebKit view to (re)load.
    @Published var reloadToken = 0
    @Published var isLoading = false

    var isActive: Bool { url != nil }

    /// Load a file from disk, resolving relative assets against its directory.
    func loadFile(url: URL) {
        self.url = url
        self.htmlString = nil
        self.reloadToken += 1
    }

    /// Load an in-memory HTML document. `baseURL` anchors relative asset lookups
    /// (its parent directory is used).
    func loadHTML(_ html: String, baseURL: URL) {
        self.url = baseURL
        self.htmlString = html
        self.reloadToken += 1
    }

    func clear() {
        url = nil
        htmlString = nil
        isLoading = false
    }

    func reload() {
        reloadToken += 1
    }
}

// MARK: - WebKit representable

private struct HTMLWebView: NSViewRepresentable {
    @ObservedObject var model: HTMLPreviewModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        context.coordinator.load(in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.load(in: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var model: HTMLPreviewModel?
        var lastToken = -1

        init(model: HTMLPreviewModel) { self.model = model }

        func load(in webView: WKWebView) {
            guard let model, model.reloadToken != lastToken else { return }
            lastToken = model.reloadToken
            if let html = model.htmlString {
                let base = model.url?.deletingLastPathComponent()
                webView.loadHTMLString(html, baseURL: base)
            } else if let url = model.url {
                webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            model?.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            model?.isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            model?.isLoading = false
        }
    }
}

// MARK: - Surface

/// WebKit preview for HTML documents: a live render plus a floating toolbar
/// (source/editor toggle, reload, open-in-browser).
struct HTMLPreviewSurface: View {
    @ObservedObject var model: HTMLPreviewModel
    let theme: SyntaxTheme
    var onShowSource: () -> Void

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .topTrailing) {
                theme.editorBackgroundColor.ignoresSafeArea()
                if model.url != nil {
                    HTMLWebView(model: model)
                }
                toolbar
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button(action: onShowSource) {
                Label("Editor", systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Show source in editor")

            Divider().frame(height: 14)

            Button { model.reload() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help("Reload")

            Button {
                if let url = model.url { NSWorkspace.shared.open(url) }
            } label: {
                Image(systemName: "safari")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help("Open in browser")

            Divider().frame(height: 14)

            if model.isLoading {
                ProgressView().controlSize(.small).frame(width: 14, height: 14)
            }

            Text(model.url?.lastPathComponent ?? "")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .padding(.top, 48)
        .padding(.trailing, 20)
    }
}
