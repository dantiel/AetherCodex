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
    /// Oracle-only mode: the whole window flips like a card, revealing Pythia
    /// alone on the reverse face — the editor chrome folds away entirely.
    @Published var oracleOnly: Bool = false
    @Published var sidebarWidth: CGFloat = 180
    @Published var pythiaWidth: CGFloat = 280
    @Published var title: String = "Untitled"
    /// Active theme — drives the SwiftUI editor background material + tint.
    @Published var theme: SyntaxTheme = ThemeRegistry.shared.current
    
    /// Callback to reposition traffic lights when sidebar visibility changes
    var onSidebarVisibilityChange: ((Bool) -> Void)?
    /// Callback to fold away AppKit overlays (status bar, tab bar) when the
    /// window flips into oracle-only mode.
    var onOracleOnlyChange: ((Bool) -> Void)?
    
    init() {
        // Observe sidebar visibility changes to trigger animations
        $sidebarVisible
            .removeDuplicates()
            .sink { [weak self] visible in
                self?.onSidebarVisibilityChange?(visible)
            }
            .store(in: &cancellables)
        
        $oracleOnly
            .removeDuplicates()
            .sink { [weak self] oracleOnly in
                self?.onOracleOnlyChange?(oracleOnly)
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
                            .overlay(Color(nsColor: chrome.theme.pythia.background)
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

// MARK: - Oracle flip card

/// The window's true content — a flip card. Front face = the code editor
/// (chrome and all); reverse face = Pythia alone. `oracleOnly` turns the card
/// over: the editor does not slide or maximize, it *turns away*.
@available(macOS 26.0, *)
struct OracleFlipRoot: View {
    let editor: EditorViewController
    let sidebar: NSView
    @ObservedObject var pythiaModel: PythiaChatModel
    @ObservedObject var chrome: EditorChromeState
    @ObservedObject var document: EditorDocumentModel

    /// 0 = editor facing forward, 180 = oracle facing forward.
    @State private var degrees: Double = 0

    var body: some View {
        ZStack {
            // Front face: the code editor with all its chrome. Fades to the
            // reverse side as it turns past edge-on.
            EditorContainerView(editor: editor, sidebar: sidebar,
                                pythiaModel: pythiaModel, chrome: chrome,
                                document: document)
                .rotation3DEffect(.degrees(degrees), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
                .opacity(degrees > 90 ? 0 : 1)
                .allowsHitTesting(!chrome.oracleOnly)

            // Reverse face: Pythia alone. Both faces stay mounted so the turn
            // reads as one continuous card; only the visible side takes input.
            OracleOnlyView(pythiaModel: pythiaModel, chrome: chrome)
                .rotation3DEffect(.degrees(degrees - 180), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
                .opacity(degrees > 90 ? 1 : 0)
                .allowsHitTesting(chrome.oracleOnly)
        }
        .onChange(of: chrome.oracleOnly) { _, flipped in
            withAnimation(.easeInOut(duration: 0.62)) {
                degrees = flipped ? 180 : 0
            }
        }
    }
}

/// The reverse face of the flip card — Pythia stands alone, filling the window.
@available(macOS 26.0, *)
private struct OracleOnlyView: View {
    @ObservedObject var pythiaModel: PythiaChatModel
    @ObservedObject var chrome: EditorChromeState

    private var palette: PythiaPalette { chrome.theme.pythia }

    var body: some View {
        ZStack(alignment: .topLeading) {
            WindowBackdrop(strength: ThemeSettings.shared.resolvedGlassBlurStrength(for: chrome.theme))
                .overlay(chrome.theme.editorGlassTintColor)
                .overlay(Color(nsColor: chrome.theme.pythia.background)
                    .opacity(ThemeSettings.shared.resolvedSidebarBackgroundOpacity(for: chrome.theme)))

            PythiaPanel(model: pythiaModel)
                .environment(\.markdownThemeName, chrome.theme.name)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            flipBackButton
        }
        .ignoresSafeArea(.container, edges: [.top, .leading, .trailing])
    }

    private var flipBackButton: some View {
        Button {
            chrome.oracleOnly = false
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.foregroundColor)
        .help("Return to Editor")
        .padding(.leading, 80)
        .padding(.top, 8)
    }
}

private struct EditorModeSurface: View {
    let editor: EditorViewController
    let theme: SyntaxTheme
    @ObservedObject var document: EditorDocumentModel
    @ObservedObject var rich: RichTextDocument
    @ObservedObject var imageModel: ImagePreviewModel
    @ObservedObject var htmlModel: HTMLPreviewModel
    var leading: CGFloat
    var trailing: CGFloat

    init(editor: EditorViewController, theme: SyntaxTheme, document: EditorDocumentModel,
          leading: CGFloat = 0, trailing: CGFloat = 0) {
        self.editor = editor
        self.theme = theme
        self.document = document
        self.rich = editor.richDocument
        self.imageModel = editor.imagePreview
        self.htmlModel = editor.htmlPreview
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        if imageModel.isActive {
            ImagePreviewSurface(model: imageModel, theme: theme)
                .padding(.leading, leading).padding(.trailing, trailing)
        } else if htmlModel.isActive {
            HTMLPreviewSurface(model: htmlModel, theme: theme, onShowSource: editor.showHTMLSource)
                .padding(.leading, leading).padding(.trailing, trailing)
        } else if rich.active {
            RichTextSurface(document: rich, theme: theme, showSource: editor.showMarkdownSource, sidebarClosed: leading == 0)
                .padding(.leading, leading).padding(.trailing, trailing)
        } else {
            TextKit2ScrollSurface(attributedString: document.attributedString,
                                 backgroundColor: theme.editorBackgroundColor,
                                 gutter: EditorContainerView.makeGutter(document: document, theme: theme),
                                 leadingChromeWidth: leading, trailingChromeWidth: trailing,
                                 sharedTextStorage: editor.textStorage, existingEditor: editor.textView)
                .scrollEdgeEffectStyle(.soft, for: [.top, .leading, .trailing])
                .overlay(alignment: .topTrailing) {
                    VStack(alignment: .trailing, spacing: 8) {
                        if editor.supportsRichText {
                            Button("Text view", action: editor.showRichText)
                                .buttonStyle(.bordered)
                        }
                        if editor.supportsHTML {
                            Button("Preview", action: editor.previewHTML)
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(.top, 48).padding(.trailing, trailing + 20)
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

            PythiaControlGroup(chrome: chrome)
        }
        .padding(.leading, 80)
        .padding(.trailing, 12)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .offset(y: -28)
    }
}

/// Combined titlebar group for Pythia: one toggle for the sidebar, one for the
/// card flip (oracle-only). Lives in the titlebar so the flip stays reachable
/// even when the Pythia sidebar is folded away.
private struct PythiaControlGroup: View {
    @ObservedObject var chrome: EditorChromeState

    var body: some View {
        HStack(spacing: 2) {
            pythiaToggle
            flipButton
        }
        .padding(2)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }

    private var pythiaToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) { chrome.pythiaVisible.toggle() }
        } label: {
            Image(systemName: chrome.pythiaVisible ? "sidebar.right" : "rectangle.righthalf.inset.filled")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 24)
                .contentShape(Circle())
                .background(chrome.pythiaVisible
                            ? AnyShapeStyle(.regularMaterial)
                            : AnyShapeStyle(.clear), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(chrome.pythiaVisible
                         ? chrome.theme.pythia.accentColor
                         : Color.secondary)
        .help(chrome.pythiaVisible ? "Close Pythia" : "Open Pythia")
    }

    private var flipButton: some View {
        Button {
            chrome.oracleOnly = true
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(chrome.theme.pythia.accentColor)
        .help("Oracle Only (flip window)")
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