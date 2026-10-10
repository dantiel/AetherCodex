import Cocoa
import SwiftUI

final class FileBrowserScrollModel: ObservableObject {
    @Published var root: FileItem?
    @Published var selection: URL?
    @Published var revision = 0
    @Published var foreground: NSColor = .labelColor
    @Published var accent: NSColor = .controlAccentColor
    /// Expanded directory paths — the single source of truth for node disclosure.
    /// (A per-node `@State` could not be driven from outside the view tree.)
    @Published var expandedPaths: Set<String> = []
    /// Path to scroll into view once the tree has realized it (reveal target).
    @Published var revealID: String?
    /// Lift the veil — show dotfiles in the tree (wired to FileItem.showsHiddenFiles).
    @Published var showsHidden = false
    var open: (URL) -> Void = { _ in }

    /// Action bar handlers — wired by FileBrowserViewController (the SwiftUI
    /// surface has no AppKit knowledge, so the controller lends its hands).
    var reload: () -> Void = {}
    var collapseAll: () -> Void = {}
    var openFolder: () -> Void = {}
    var goToFile: () -> Void = {}

    func isExpanded(_ url: URL) -> Bool { expandedPaths.contains(url.path) }

    func toggle(_ url: URL) {
        if expandedPaths.contains(url.path) { expandedPaths.remove(url.path) }
        else { expandedPaths.insert(url.path) }
    }

    /// Reveal a file *inside the current root* — expand every ancestor folder,
    /// select the file, and request a scroll-to. The root is never re-homed;
    /// files outside the root are ignored (the caller falls back to openFolder).
    func reveal(_ url: URL) {
        guard let root = root else { return }
        let rootPath = root.url.path
        let filePath = url.path
        guard filePath != rootPath, filePath.hasPrefix(rootPath + "/") else { return }

        var ancestorDirs: [URL] = []
        var dir = url.deletingLastPathComponent()
        while dir.path != rootPath, dir.path.hasPrefix(rootPath + "/") {
            ancestorDirs.append(dir)
            dir = dir.deletingLastPathComponent()
        }
        ancestorDirs.reverse()

        var node = root
        var newExpanded = expandedPaths
        for dirURL in ancestorDirs {
            node.loadChildren()
            newExpanded.insert(dirURL.path)
            if let child = node.children?.first(where: { $0.url.path == dirURL.path }) {
                node = child
            } else {
                let placeholder = FileItem(url: dirURL, isDirectory: true)
                node.children = (node.children ?? []) + [placeholder]
                node = placeholder
            }
        }
        node.loadChildren()

        expandedPaths = newExpanded
        selection = url
        revealID = filePath
    }
}

/// SwiftUI owns this scroller and its bar in the same hosting graph, allowing
/// the system to render the native scroll-edge effect behind the controls.
@available(macOS 26.0, *)
private struct FileBrowserScrollContent: View {
    @ObservedObject var model: FileBrowserScrollModel
    @ObservedObject var chrome: EditorChromeState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(model.root?.children ?? [], id: \.url) { item in
                        FileBrowserNode(item: item, model: model)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            .onChange(of: model.revealID) { id in
                guard let id else { return }
                // Let the expanded ancestors realize their rows before scrolling;
                // a lazy stack cannot jump to a row it has not materialized yet.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .safeAreaBar(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                // The breadcrumb + sidebar toggle live in the enclosing sidebar
                // safe-area bar; this column reserves the traffic-light band
                // and the header height so scroll rows begin below both.
                Color.clear.frame(height: 46)
                HStack(spacing: 2) {
                    actionButton(model.showsHidden ? "eye" : "eye.slash",
                                 help: model.showsHidden ? "Hide hidden files" : "Show hidden files (the Veil)",
                                 active: model.showsHidden) {
                        model.showsHidden.toggle()
                        model.reload()
                    }
                    actionButton("arrow.clockwise", help: "Refresh file list", disabled: model.root == nil) {
                        model.reload()
                    }
                    actionButton("rectangle.compress.vertical", help: "Collapse all folders") {
                        model.collapseAll()
                    }
                    actionButton("folder.badge.plus", help: "Open folder…") {
                        model.openFolder()
                    }
                    actionButton("magnifyingglass", help: "Go to file…", disabled: model.root == nil) {
                        model.goToFile()
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                Divider().opacity(0.4)
            }
        }
        .sidebarTabBar(chrome)
    }

    /// A quiet square action in the pane's top bar — secondary by default,
    /// accent when active (the veil lifted), disabled dims to a whisper.
    private func actionButton(_ symbol: String, help: String,
                              disabled: Bool = false, active: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? Color.secondary.opacity(0.35)
                                 : active ? Color(nsColor: model.accent) : Color.secondary)
        .disabled(disabled)
        .help(help)
    }
}

@available(macOS 26.0, *)
private struct FileBrowserNode: View {
    let item: FileItem
    @ObservedObject var model: FileBrowserScrollModel
    @State private var hovered = false

    private var isSelected: Bool { model.selection == item.url }
    private var isExpanded: Bool { model.isExpanded(item.url) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                if item.isDirectory {
                    item.loadChildren()
                    model.toggle(item.url)
                } else {
                    model.selection = item.url
                    model.open(item.url)
                }
            } label: {
                HStack(spacing: 8) {
                    if item.isDirectory {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color(nsColor: model.accent).opacity(0.8))
                            .frame(width: 12)
                        Image(systemName: isExpanded ? "folder.fill" : "folder")
                            .font(.system(size: 14))
                            .foregroundStyle(Color(nsColor: model.accent))
                    } else {
                        Image(systemName: FileIcon.symbol(for: item.url))
                            .font(.system(size: 14))
                            .foregroundStyle(Color(nsColor: model.foreground).opacity(0.7))
                            .frame(width: 18)
                    }
                    Text(item.name)
                        .fontWeight(item.isDirectory ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 13))
                .foregroundStyle(Color(nsColor: model.foreground))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(Color(nsColor: model.accent).opacity(isSelected ? 0.20 : hovered ? 0.08 : 0),
                            in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            if isExpanded {
                ForEach(item.children ?? [], id: \.url) { child in
                    FileBrowserNode(item: child, model: model)
                }
                .padding(.leading, 16)
            }
        }
        .id(item.url.path)
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

    /// Shared chrome — the SwiftUI pane docks the sidebar's floating tab bar in
    /// its own hosting graph, so it needs the roster and the selection. Injected
    /// by the window controller before the view is loaded.
    var chrome: EditorChromeState!

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

    /// Forget every loaded child in the tree (recursively) — refresh and the
    /// veil toggle call this so the next expansion re-reads the disk.
    private func invalidateTree(_ node: FileItem?) {
        guard let node else { return }
        let kids = node.children
        node.invalidate()
        for child in kids ?? [] { invalidateTree(child) }
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
            scrollModel.reload = { [weak self] in
                guard let self else { return }
                FileItem.showsHiddenFiles = self.scrollModel.showsHidden
                let tree = self.scrollModel.root
                self.invalidateTree(tree)
                self.reloadOutline()
            }
            scrollModel.collapseAll = { [weak self] in
                self?.scrollModel.expandedPaths = []
            }
            scrollModel.openFolder = { [weak self] in
                self?.browseForFolder()
            }
            scrollModel.goToFile = { [weak self] in
                guard let self, let root = self.scrollModel.root?.url else { return }
                let opener = self.scrollModel.open
                GoToFilePanel.show(projectRoot: root, onSelect: opener)
            }
            let host = NSHostingView(rootView: FileBrowserScrollContent(model: scrollModel, chrome: chrome))
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
        scrollView.contentInsets = NSEdgeInsets(top: 28, left: 10, bottom: 0, right: 10)
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

    /// Reveal a file inside the current root without re-homing the sidebar:
    /// expand its ancestor folders, select it, and scroll it into view. Returns
    /// false when the file lives outside the current root (caller should fall
    /// back to `openFolder`).
    @discardableResult
    func revealFile(_ url: URL) -> Bool {
        guard let root = rootItem else { return false }
        let rootPath = root.url.path
        let filePath = url.path
        guard filePath.hasPrefix(rootPath + "/") else { return false }
        scrollModel.reveal(url)
        return true
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
        guard row >= 0, let item = outlineView.item(atRow: row) as? FileItem else { return }
        if item.isDirectory {
            // Double-clicking a folder drills into it: it becomes the browser's
            // top level and the breadcrumb's current (topmost) location.
            openFolder(item.url)
        } else {
            onFileOpen?(item.url)
        }
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
            // Shared registry — the same glyph the tab strip and window title use.
            let symbol = FileIcon.symbol(for: fileItem.url)
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