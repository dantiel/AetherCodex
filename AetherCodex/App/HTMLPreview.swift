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
    /// Chrome height the page must clear at rest. The page still scrolls up
    /// beneath the frosted bar, so this is a content offset, not a crop.
    var topContentInset: CGFloat = 0

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(model: model)
        coordinator.topContentInset = topContentInset
        return coordinator
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        // macOS WebKit exposes no scroll-view API (the iOS `scrollView` property
        // does not exist here), so the chrome band cannot be a native content
        // inset: it is written into the page by `applyInset`.
        context.coordinator.applyInset(to: webView)
        context.coordinator.load(in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.topContentInset = topContentInset
        context.coordinator.applyInset(to: webView)
        context.coordinator.load(in: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var model: HTMLPreviewModel?
        var lastToken = -1
        var topContentInset: CGFloat = 0
        /// Inset already written into the current document. Reset on navigation:
        /// a new document arrives with none of our styles.
        private var appliedInset: CGFloat?

        init(model: HTMLPreviewModel) { self.model = model }

        /// Idempotent, and reapplied after every load: the inset lives in the
        /// page (a top band on the root element), so every fresh document has to
        /// be taught the chrome height again. Public WebKit only — no private
        /// `_scrollView` reach-through.
        func applyInset(to webView: WKWebView) {
            guard appliedInset != topContentInset else { return }
            appliedInset = topContentInset
            let band = Int(topContentInset.rounded())
            let source = """
            (() => {
              const id = 'aether-chrome-inset';
              let style = document.getElementById(id);
              if (!style) {
                style = document.createElement('style');
                style.id = id;
                (document.head || document.documentElement).appendChild(style);
              }
              style.textContent =
                'html { padding-top: \(band)px !important;' +
                ' scroll-padding-top: \(band)px !important; }';
            })();
            """
            webView.evaluateJavaScript(source, completionHandler: nil)
        }

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
            appliedInset = nil              // the finished document carries no band yet
            applyInset(to: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            model?.isLoading = false
        }
    }
}

// MARK: - Surface

/// WebKit preview for HTML documents: a live render plus a controls row that
/// lives in the same top bar as the rest of the editor's surfaces.
struct HTMLPreviewSurface: View {
    @ObservedObject var model: HTMLPreviewModel
    let theme: SyntaxTheme
    /// Extra chrome height above the surface (the editor tab strip), added to
    /// the shared bar the page is inset beneath.
    var topInset: CGFloat = 0
    var onShowSource: () -> Void

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .topTrailing) {
                theme.editorBackgroundColor.ignoresSafeArea()
                if model.url != nil {
                    HTMLWebView(model: model,
                                topContentInset: EditorChromeMetrics
                                    .scrollEdgeBarHeight(topInset: topInset))
                }
                // No SwiftUI scroll view to hang a `safeAreaBar` on, so the
                // frost is drawn here instead: same band, same ramp, page
                // travelling underneath it.
                FrostedTopVeil(height: EditorChromeMetrics
                    .scrollEdgeBarHeight(topInset: topInset))
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
        }
        .padding(.leading, 40)
        .padding(.trailing, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Frosted bar for non-ScrollView content

/// Progressive frost for a surface whose content is not a SwiftUI `ScrollView`.
/// Same geometry as the native scroll edge effect: an opaque band across the
/// chrome stack, then a short ramp so the content dissolves instead of being
/// cut off by a hard edge.
private struct FrostedTopVeil: View {
    let height: CGFloat
    var ramp: CGFloat = 22

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .frame(height: height)
            Rectangle()
                .fill(.ultraThinMaterial)
                .frame(height: ramp)
                .mask {
                    LinearGradient(colors: [.black, .clear],
                                   startPoint: .top, endPoint: .bottom)
                }
        }
        .allowsHitTesting(false)
    }
}