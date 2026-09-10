import Cocoa
import SwiftUI

final class FileBrowserScrollModel: ObservableObject {
    @Published var root: FileItem?
    @Published var selection: URL?
    @Published var revision = 0
    @Published var foreground: NSColor = .labelColor
    @Published var accent: NSColor = .controlAccentColor
    var open: (URL) -> Void = { _ in }
    var navigate: (URL) -> Void = { _ in }
}

/// SwiftUI owns this scroller and its bar in the same hosting graph, allowing
/// the system to render the native scroll-edge effect behind the controls.
@available(macOS 26.0, *)
private struct FileBrowserScrollContent: View {
    @ObservedObject var model: FileBrowserScrollModel

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(model.root?.children ?? [], id: \.url) { item in
                    FileBrowserNode(item: item, model: model)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .safeAreaBar(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 64)
                PathBreadcrumbHeader(model: model)
                    .padding(.horizontal, 6)
                    .frame(height: 28)
            }
        }
    }
}

/// One breadcrumb segment — name plus the URL it resolves to.
private struct PathComponent: Identifiable {
    let id = UUID()
    let name: String
    let url: URL
}

/// Glass breadcrumb trail with an editable monospaced path field.
/// Pure SwiftUI — no AppKit controls.
@available(macOS 26.0, *)
private struct PathBreadcrumbHeader: View {
    @ObservedObject var model: FileBrowserScrollModel
    @State private var isEditing = false
    @State private var pathText = ""
    @State private var invalidPath = false
    @FocusState private var focused: Bool

    private func components(from path: String) -> [PathComponent] {
        var result = [PathComponent(name: "/", url: URL(fileURLWithPath: "/"))]
        var running = URL(fileURLWithPath: "/")
        for part in URL(fileURLWithPath: path).pathComponents.dropFirst() where part != "/" {
            running.appendPathComponent(part)
            result.append(PathComponent(name: part, url: running))
        }
        return result
    }

    private func navigateToPath() {
        var expanded = pathText.trimmingCharacters(in: .whitespacesAndNewlines)
        if expanded.hasPrefix("~") {
            expanded = (expanded as NSString).expandingTildeInPath
        }
        let standardized = (expanded as NSString).standardizingPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized, isDirectory: &isDir),
              isDir.boolValue else {
            invalidPath = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                invalidPath = false
            }
            return
        }
        // Clear any lingering error flash so a successful navigation followed
        // by a quick re-entry into edit mode never shows a stale red border.
        invalidPath = false
        model.navigate(URL(fileURLWithPath: standardized))
        isEditing = false
    }

    var body: some View {
        HStack(spacing: 6) {
            if isEditing {
                inputField
                    .transition(.opacity)
            } else {
                breadcrumbs
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isEditing)
        .onChange(of: isEditing) { _, editing in
            if editing {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    focused = true
                }
            }
        }
    }

    // MARK: Breadcrumb mode

    private var breadcrumbs: some View {
        HStack(spacing: 2) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        let comps = components(from: model.root?.url.path ?? "/")
                        ForEach(Array(comps.enumerated()), id: \.element.id) { index, comp in
                            let isLast = index == comps.count - 1
                            Button {
                                model.navigate(comp.url)
                            } label: {
                                Text(comp.name)
                                    .font(.system(size: 11, weight: isLast ? .bold : .medium))
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color(nsColor: model.foreground).opacity(isLast ? 1.0 : 0.85))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                            .id(comp.id)
                            if !isLast {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.trailing, 4)
                }
                .onChange(of: model.root?.url.path) { _, _ in
                    if let last = components(from: model.root?.url.path ?? "/").last {
                        proxy.scrollTo(last.id, anchor: .trailing)
                    }
                }
                .onAppear {
                    if let last = components(from: model.root?.url.path ?? "/").last {
                        proxy.scrollTo(last.id, anchor: .trailing)
                    }
                }
            }
            Button {
                pathText = model.root?.url.path ?? ""
                isEditing = true
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 9, weight: .medium))
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(nsColor: model.foreground).opacity(0.55))
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
            .help("Edit path")
        }
    }

    // MARK: Input mode

    private var inputField: some View {
        HStack(spacing: 4) {
            TextField("Path", text: $pathText)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .focused($focused)
                .onSubmit { navigateToPath() }
                .onExitCommand { isEditing = false }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(
                            invalidPath ? Color.red.opacity(0.85)
                                        : (focused ? Color.accentColor.opacity(0.6) : .white.opacity(0.18)),
                            lineWidth: invalidPath ? 1.0 : 0.75
                        )
                )
                .foregroundStyle(invalidPath ? .red : Color(nsColor: model.foreground))

            Button {
                navigateToPath()
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .background(.ultraThinMaterial, in: Circle())
            .help("Navigate to path")

            Button {
                isEditing = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(nsColor: model.foreground).opacity(0.6))
            .background(.ultraThinMaterial, in: Circle())
            .help("Cancel")
        }
    }
}

@available(macOS 26.0, *)
private struct FileBrowserNode: View {
    let item: FileItem
    @ObservedObject var model: FileBrowserScrollModel
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                if item.isDirectory {
                    item.loadChildren()
                    expanded.toggle()
                } else {
                    model.selection = item.url
                    model.open(item.url)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: item.isDirectory ? (expanded ? "chevron.down" : "chevron.right") : "doc.text")
                        .frame(width: 12)
                        .foregroundStyle(Color(nsColor: model.accent))
                    if item.isDirectory { Image(systemName: "folder").foregroundStyle(Color(nsColor: model.accent)) }
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: model.foreground))
                .padding(.horizontal, 6)
                .frame(height: 24)
                .contentShape(Rectangle())
                .background(model.selection == item.url ? Color(nsColor: model.accent).opacity(0.22) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(item.children ?? [], id: \.url) { child in
                    FileBrowserNode(item: child, model: model)
                }
                .padding(.leading, 14)
            }
        }
    }
}

/// Row view that never draws its own background — pure glass transparency.
private final class TransparentRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.3).setFill()
        dirtyRect.fill()
    }
    override var isEmphasized: Bool {
        get { false }
        set { super.isEmphasized = newValue }
    }
}

/// Minimal file browser — source-list sidebar extending from window edge.
final class FileBrowserViewController: NSViewController {
    private let scrollModel = FileBrowserScrollModel()

    // MARK: - Views

    @objc private(set) var outlineView: NSOutlineView!
    private(set) var scrollView: NSScrollView!
    private var headerLabel: NSTextField!

    // MARK: - State

    /// Reload the outline view data — safe for external callers (avoids KVC).
    func reloadOutline() {
        outlineView?.reloadData()
        scrollModel.revision += 1
    }
    
    /// Theme foreground color applied to sidebar text.
    private var themeForegroundColor: NSColor = .labelColor

    var rootItem: FileItem? {
        didSet {
            guard isViewLoaded, headerLabel != nil else { return }
            headerLabel.stringValue = rootItem?.url.path ?? rootItem?.name ?? "No Folder"
            if let root = rootItem {
                root.loadChildren()
            }
            outlineView.reloadData()
            scrollModel.root = rootItem
            if let url = rootItem?.url {
                onFolderOpen?(url)
            }
        }
    }

    /// Called when a file is double-clicked or selected via keyboard.
    var onFileOpen: ((URL) -> Void)?

    /// Called when a folder is opened (via openFolder or browseForFolder).
    var onFolderOpen: ((URL) -> Void)?

    /// Pending background color — set before viewDidLoad creates the subviews.
    /// Applied in viewDidLoad so .sourceList never gets a chance to paint.
    private var pendingThemeBackground: NSColor?

    /// Make the outline view and scroll view fully transparent so glass shows through.
    /// Used by the overlay panel which sits inside its own NSVisualEffectView.
    func setTransparentBackground() {
        pendingThemeBackground = nil
        outlineView?.backgroundColor = .clear
        scrollView?.drawsBackground = false
        scrollView?.backgroundColor = .clear
        view.layer?.backgroundColor = NSColor.clear.cgColor
    }
    
    /// Apply sidebar background color directly to the outline view.
    /// Stores the color even if subviews aren't loaded yet — viewDidLoad will apply it.
    func applyThemeBackground(_ color: NSColor) {
        pendingThemeBackground = color
        view.layer?.backgroundColor = color.cgColor
        guard scrollView != nil, outlineView != nil else { return }
        scrollView!.drawsBackground = true
        scrollView!.backgroundColor = color
        scrollView!.contentView.drawsBackground = false
        scrollView!.contentView.backgroundColor = .clear
        outlineView!.backgroundColor = color
    }
    
    /// Update text colors throughout the file browser to match theme foreground.
    func applyForegroundColor(_ color: NSColor, accent: NSColor = .controlAccentColor) {
        themeForegroundColor = color
        scrollModel.foreground = color
        scrollModel.accent = accent
        headerLabel?.textColor = color.withAlphaComponent(0.2)
        outlineView?.reloadData()
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
        // Apply any background color that was set before the subviews existed
        if let color = pendingThemeBackground {
            view.layer?.backgroundColor = color.cgColor
            scrollView.drawsBackground = true
            scrollView.backgroundColor = color
            scrollView.contentView.drawsBackground = false
            scrollView.contentView.backgroundColor = .clear
            outlineView.backgroundColor = color
        }
        // If rootItem was set before the view loaded, apply it now
        if let root = rootItem {
            headerLabel.stringValue = root.url.path
            root.loadChildren()
            outlineView.reloadData()
            onFolderOpen?(root.url)
        }
        if #available(macOS 26.0, *) {
            scrollModel.root = rootItem
            scrollModel.open = { [weak self] url in self?.onFileOpen?(url) }
            scrollModel.navigate = { [weak self] url in self?.openFolder(url) }
            let host = NSHostingView(rootView: FileBrowserScrollContent(model: scrollModel))
            host.translatesAutoresizingMaskIntoConstraints = false
            // Keep the old outline available to existing controller callers;
            // only the SwiftUI scroll surface participates in visible layout.
            scrollView.isHidden = true
            headerLabel.isHidden = true
            view.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                host.topAnchor.constraint(equalTo: view.topAnchor),
                host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
    }

    // MARK: - Setup

    private func setupViews() {
        // --- Header ---
        headerLabel = NSTextField(labelWithString: "No Folder")
        headerLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        // --- Outline ---
        outlineView = NSOutlineView()
        outlineView.style = .sourceList
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .small
        outlineView.indentationPerLevel = 14
        outlineView.indentationMarkerFollowsCell = false
        outlineView.backgroundColor = .clear
        outlineView.allowsMultipleSelection = false
        outlineView.autoresizesOutlineColumn = false
        outlineView.floatsGroupRows = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClicked(_:))
        outlineView.translatesAutoresizingMaskIntoConstraints = false

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("files"))
        col.title = ""
        col.minWidth = 80
        col.maxWidth = 1000
        outlineView.addTableColumn(col)
        outlineView.outlineTableColumn = col

        // --- Scroll ---
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.documentView = outlineView
        // The scroll view fills the sheet and travels underneath its SwiftUI
        // safe-area bar. Insets establish the resting position below the window
        // controls, sidebar button, and path label without clipping scrolling
        // rows at that boundary.
        scrollView.automaticallyAdjustsContentInsets = false
        // The enclosing SwiftUI safeAreaBar already contributes 64 pt. These
        // smaller internal insets account only for the path label and row gap.
        scrollView.contentInsets = NSEdgeInsets(top: 28, left: 0, bottom: 0, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        view.addSubview(scrollView)
        view.addSubview(headerLabel)

        NSLayoutConstraint.activate([
            headerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            headerLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            headerLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            headerLabel.heightAnchor.constraint(equalToConstant: 16),

            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Open Folder

    func openFolder(_ url: URL) {
        Task { @MainActor in AetherContext.shared.activate(for: url) }
        let item = FileItem(url: url, isDirectory: true)
        rootItem = item
    }

    /// Present an open-panel and set the root.
    func browseForFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a project folder"
        let result = panel.runModal()
        guard result == .OK, let url = panel.url else { return }
        openFolder(url)
    }

    // MARK: - Actions

    @objc private func doubleClicked(_ sender: Any) {
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? FileItem,
              !item.isDirectory else { return }
        onFileOpen?(item.url)
    }
}

// MARK: - NSOutlineViewDataSource

extension FileBrowserViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let root = rootItem else { return 0 }
        if item == nil {
            // Show root's children directly — no wrapper folder level.
            return root.children?.count ?? 0
        }
        guard let fileItem = item as? FileItem else { return 0 }
        if !fileItem.isLoaded { fileItem.loadChildren() }
        return fileItem.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            guard let children = rootItem?.children, index < children.count else {
                return FileItem(url: URL(fileURLWithPath: "/"), isDirectory: true)
            }
            return children[index]
        }
        guard let fileItem = item as? FileItem,
              let children = fileItem.children,
              index < children.count else {
            return FileItem(url: URL(fileURLWithPath: "/"), isDirectory: true)
        }
        return children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let fileItem = item as? FileItem else { return false }
        return fileItem.isDirectory
    }
}

// MARK: - NSOutlineViewDelegate

extension FileBrowserViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let fileItem = item as? FileItem else { return nil }
        let id = NSUserInterfaceItemIdentifier("FileCell")
        var cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
        if cell == nil {
            cell = NSTableCellView()
            cell!.identifier = id

            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageScaling = .scaleProportionallyDown
            cell!.addSubview(icon)

            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = NSFont.systemFont(ofSize: 12, weight: .regular)
            label.lineBreakMode = .byTruncatingTail
            cell!.addSubview(label)

            cell!.imageView = icon
            cell!.textField = label

            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell!.leadingAnchor, constant: 4),
                icon.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),

                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell!.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),
            ])
        }

        if fileItem.isDirectory {
            cell!.imageView?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "folder")
            cell!.imageView?.contentTintColor = .secondaryLabelColor
            cell!.textField?.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        } else {
            let ext = fileItem.url.pathExtension.lowercased()
            let symbol: String
            switch ext {
            case "swift": symbol = "swift"
            case "rb":    symbol = "ruby"
            case "py":    symbol = "py"
            case "js","ts": symbol = "js"
            case "c","h","cpp","hpp": symbol = "c"
            case "go":    symbol = "go"
            case "rs":    symbol = "rust"
            case "yaml","yml": symbol = "yaml"
            case "json","plist": symbol = "json"
            case "md","txt","rdoc": symbol = "doc.text"
            default:      symbol = "doc"
            }
            cell!.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "file")
            cell!.imageView?.contentTintColor = .tertiaryLabelColor
            cell!.textField?.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        }
        cell!.textField?.stringValue = fileItem.name
        cell!.textField?.textColor = themeForegroundColor

        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowView = TransparentRowView()
        return rowView
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let fileItem = item as? FileItem else { return false }
        if fileItem.isDirectory {
            // Toggle expand on single click
            if outlineView.isItemExpanded(item) {
                outlineView.collapseItem(item)
            } else {
                outlineView.expandItem(item)
            }
            return false
        }
        return true
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0,
              let item = outlineView.item(atRow: row) as? FileItem,
              !item.isDirectory else { return }
        onFileOpen?(item.url)
    }
}