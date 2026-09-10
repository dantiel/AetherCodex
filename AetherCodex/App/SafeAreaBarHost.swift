import SwiftUI
import AppKit
import Combine

// MARK: - AppKit bridge

/// Hosts an existing AppKit view as SwiftUI content.
struct AppKitViewHost: NSViewRepresentable {
    let make: () -> NSView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        let hosted = make()
        hosted.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosted)
        NSLayoutConstraint.activate([
            hosted.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosted.topAnchor.constraint(equalTo: container.topAnchor),
            hosted.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Chrome state

/// Observable state driving the `safeAreaBar` chrome (sidebar + Pythia).
final class EditorChromeState: ObservableObject {
    @Published var sidebarVisible: Bool = true
    @Published var pythiaVisible: Bool = false
    @Published var sidebarWidth: CGFloat = 180
    @Published var pythiaWidth: CGFloat = 280
    @Published var title: String = "Untitled"
    /// Active theme — drives the SwiftUI editor background material + tint.
    @Published var theme: SyntaxTheme = ThemeRegistry.shared.current
    
    /// Callback to reposition traffic lights when sidebar visibility changes
    var onSidebarVisibilityChange: ((Bool) -> Void)?
    
    init() {
        // Observe sidebar visibility changes to trigger animations
        $sidebarVisible
            .removeDuplicates()
            .sink { [weak self] visible in
                self?.onSidebarVisibilityChange?(visible)
            }
            .store(in: &cancellables)
    }
    
    private var cancellables = Set<AnyCancellable>()
}

// MARK: - Theme → SwiftUI material mapping

extension SyntaxTheme {
    /// SwiftUI material for the editor background, derived from the resolved glass
    /// blur strength (0.0 = thinnest, 1.0 = heaviest). Replaces the AppKit
    /// `NSGlassEffectView` / `NSVisualEffectView` "material" system — SwiftUI
    /// materials give the same frosted-glass texture, adapt to light/dark
    /// automatically, and compose with `safeAreaBar` + `.scrollEdgeEffectStyle`.
    var editorMaterial: Material {
        let strength = ThemeSettings.shared.resolvedGlassBlurStrength(for: self)
        switch strength {
        case ..<0.2:  return .ultraThin
        case ..<0.4:  return .thin
        case ..<0.6:  return .regular
        case ..<0.8:  return .thick
        default:      return .ultraThick
        }
    }

    /// Tint layered over the editor material (glassTintColor × glassTint).
    var editorGlassTintColor: Color {
        let strength = ThemeSettings.shared.resolvedGlassTint(for: self)
        return Color(nsColor: glassTintColor).opacity(0.3 * strength)
    }

    /// Only the background is translucent; text retains its original opacity.
    var editorBackgroundColor: Color {
        Color(nsColor: editorBackground.withAlphaComponent(1))
            .opacity(ThemeSettings.shared.resolvedEditorBackgroundOpacity(for: self))
    }

    var sidebarMaterial: Material {
        switch ThemeSettings.shared.resolvedSidebarGlassBlurStrength(for: self) {
        case ..<0.2: return .ultraThin
        case ..<0.4: return .thin
        case ..<0.6: return .regular
        case ..<0.8: return .thick
        default: return .ultraThick
        }
    }
}

// MARK: - Editor container (safeAreaBar host)

/// The window's content, expressed in SwiftUI so we can use the native
/// `safeAreaBar(edge:)` API for the top bar, leading sidebar, and trailing
/// Pythia pane. `.scrollEdgeEffectStyle(.soft)` tells the compositor to blur
/// editor content progressively as it scrolls beneath each bar — the same
/// mechanism the `ScrollEdgeSwiftUIDemo` proved for the top edge, now applied
/// to leading/trailing too (which AppKit's `NSSplitViewItemAccessoryViewController`
/// cannot express: it is top/bottom only).
@available(macOS 26.0, *)
struct EditorContainerView: View {
    let editor: EditorViewController
    let sidebar: NSView
    @ObservedObject var pythiaModel: PythiaChatModel
    @ObservedObject var chrome: EditorChromeState
    @ObservedObject var document: EditorDocumentModel


    /// Resolves the line-number gutter geometry + colors from the active theme
    /// and the document's resolved editor font.
    static func makeGutter(document: EditorDocumentModel, theme: SyntaxTheme,
                           baseFont: NSFont = SyntaxOracle.shared.baseFont) -> EditorGutterStyle {
        let ns = document.attributedString
        let numberFont = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize * 0.85, weight: .regular)

        let lineCount = ns.string.components(separatedBy: "\n").count
        let digits = max(2, String(max(lineCount, 1)).count)
        let numberWidth = (String(repeating: "8", count: digits) as NSString)
            .size(withAttributes: [.font: numberFont]).width
        let width = ceil(14 + 6 + numberWidth + 12)

        return EditorGutterStyle(
            width: width,
            font: numberFont,
            lineHeight: baseFont.ascender + abs(baseFont.descender) + baseFont.leading,
            textColor: theme.rulerForeground,
            separatorColor: theme.rulerSeparator,
            backgroundColor: theme.rulerBackground,
            selectionBackground: theme.gutterSelectionBackground,
            selectionForeground: theme.gutterSelectionForeground
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let widths = EditorPanelWidths(available: geometry.size.width,
                                           sidebar: chrome.sidebarVisible ? chrome.sidebarWidth : nil,
                                           inspector: chrome.pythiaVisible ? chrome.pythiaWidth : nil)
            ZStack {
            WindowBackdrop(strength: ThemeSettings.shared.resolvedGlassBlurStrength(for: chrome.theme))
                .overlay(chrome.theme.editorGlassTintColor)
                EditorModeSurface(editor: editor, theme: chrome.theme, document: document,
                                  leading: widths.leading, trailing: widths.trailing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea(.container, edges: [.top, .leading, .trailing])
            .safeAreaBar(edge: .top, spacing: 0) {
                TopBar(chrome: chrome)
            }
            .safeAreaBar(edge: .leading, spacing: 0) {
                if chrome.sidebarVisible {
                    ZStack(alignment: .trailing) {
                        Rectangle().fill(.ultraThinMaterial)
                            .overlay(Color(nsColor: chrome.theme.rulerBackground.withAlphaComponent(1)).opacity(0.86))
                        GeometryReader { bounds in
                            let sheet = SidebarSheetGeometry.frame(in: bounds.size)
                            AppKitViewHost { sidebar }
                                .frame(width: sheet.width, height: sheet.height)
                                .background {
                                    Rectangle().fill(chrome.theme.sidebarMaterial)
                                        .overlay(Color(nsColor: chrome.theme.sidebarBackground ?? chrome.theme.rulerBackground)
                                            .opacity(ThemeSettings.shared.resolvedSidebarBackgroundOpacity(for: chrome.theme)))
                                }
                                .clipShape(.rect(cornerRadius: 18))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 18)
                                        .strokeBorder(.white.opacity(0.16), lineWidth: 0.75)
                                }
                                .shadow(color: .black.opacity(0.12), radius: 7, y: 2)
                                .position(x: sheet.midX, y: sheet.midY)
                        }
                        SidebarResizeHandle(width: Binding(
                            get: { widths.leading - SidebarSheetGeometry.horizontalInsets },
                            set: { chrome.sidebarWidth = $0 }),
                            limits: 180...widths.sidebarMaximum, direction: 1) {
                                SessionState.shared.sidebarWidth = Double($0)
                            }
                            .frame(width: 10)
                    }
                    .frame(width: widths.leading)
                    .frame(maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: .top)
                }
            }
            .safeAreaBar(edge: .trailing, spacing: 0) {
                if chrome.pythiaVisible {
                    ZStack(alignment: .leading) {
                        // Explicit opaque hit-test surface so clicks land on the
                        // inspector instead of falling through to the code editor's
                        // NSTextView behind it (which moves the caret / line number).
                        Rectangle()
                            .fill(chrome.theme.sidebarMaterial)
                            .overlay(Color(nsColor: chrome.theme.sidebarBackground ?? chrome.theme.rulerBackground)
                                .opacity(ThemeSettings.shared.resolvedSidebarBackgroundOpacity(for: chrome.theme)))
                        PythiaPanel(model: pythiaModel)
                            .environment(\.markdownThemeName, chrome.theme.name)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay(alignment: .leading) { Divider() }
                        SidebarResizeHandle(width: Binding(
                            get: { widths.trailing }, set: { chrome.pythiaWidth = $0 }),
                            limits: 220...widths.inspectorMaximum, direction: -1) {
                                SessionState.shared.pythiaWidth = Double($0)
                            }
                            .frame(width: 10)
                    }
                    .frame(width: widths.trailing)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .ignoresSafeArea(.container, edges: .top)
                }
            }
            .overlay(alignment: .topLeading) {
                // One persistent control: animate its position instead of
                // destroying one button and inserting another in a different bar.
                SidebarToggleButton(chrome: chrome)
                    .frame(width: 32, height: 32)
                    .offset(x: chrome.sidebarVisible
                            ? widths.leading - SidebarSheetGeometry.trailing - 10 - 32
                            : 80,
                            y: 16)
                    .animation(.easeInOut(duration: 0.25), value: chrome.sidebarVisible)
                .ignoresSafeArea(.container, edges: .top)
            }
        }
    }
}

private struct EditorModeSurface: View {
    let editor: EditorViewController
    let theme: SyntaxTheme
    @ObservedObject var document: EditorDocumentModel
    @ObservedObject var rich: RichTextDocument
    var leading: CGFloat
    var trailing: CGFloat

    init(editor: EditorViewController, theme: SyntaxTheme, document: EditorDocumentModel,
         leading: CGFloat = 0, trailing: CGFloat = 0) {
        self.editor = editor
        self.theme = theme
        self.document = document
        self.rich = editor.richDocument
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        if rich.active {
            RichTextSurface(document: rich, theme: theme, showSource: editor.showMarkdownSource)
                .padding(.leading, leading).padding(.trailing, trailing)
        } else {
            TextKit2ScrollSurface(attributedString: document.attributedString,
                                 backgroundColor: theme.editorBackgroundColor,
                                 gutter: EditorContainerView.makeGutter(document: document, theme: theme),
                                 leadingChromeWidth: leading, trailingChromeWidth: trailing,
                                 sharedTextStorage: editor.textStorage, existingEditor: editor.textView)
                .scrollEdgeEffectStyle(.soft, for: [.top, .leading, .trailing])
                .overlay(alignment: .topTrailing) {
                    if editor.supportsRichText {
                        Button("Text view", action: editor.showRichText)
                            .buttonStyle(.bordered).padding(.top, 48).padding(.trailing, trailing + 20)
                    }
                }
        }
    }
}

// MARK: - Top bar

/// Minimal toolbar-equivalent for the top `safeAreaBar`.
/// SwiftUI materials provide the glass blur (replacing the AppKit NSToolbar
/// title item + the removed floating-panel glass).
struct TopBar: View {
    @ObservedObject var chrome: EditorChromeState

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 32, height: 32)

            Spacer()

            Text(chrome.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)

            Spacer()

            // Visual balance opposite the sidebar toggle.
            Color.clear.frame(width: 24, height: 1)
        }
        .padding(.leading, 80)
        .padding(.trailing, 12)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .offset(y: -28)
    }
}

private struct SidebarToggleButton: View {
    @ObservedObject var chrome: EditorChromeState
    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) { chrome.sidebarVisible.toggle() }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .foregroundStyle(Color(nsColor: chrome.theme.sidebarAccent))
        .help("Toggle Sidebar")
    }
}