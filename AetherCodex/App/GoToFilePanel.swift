import Cocoa

// MARK: - Go to File Panel (Cmd+T)

/// A floating panel for fuzzy file search within the project. Invoked via Cmd+T.
final class GoToFilePanel: NSWindowController {

    /// A single fuzzy match result.
    private struct FileMatch {
        let url: URL
        let relativePath: String
        let score: Double
    }

    // MARK: - UI Elements

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var matches: [FileMatch] = []
    private var allFiles: [URL] = []
    private var debounceTimer: Timer?
    private var projectRoot: URL!
    private var onSelect: ((URL) -> Void)?

    // MARK: - Public API

    /// Show the Go to File panel for the given project.
    static func show(projectRoot: URL, onSelect: @escaping (URL) -> Void) {
        let panel = GoToFilePanel()
        panel.projectRoot = projectRoot
        panel.onSelect = onSelect
        panel.buildUI()
        panel.enumerateFiles()
        panel.showWindow(nil)
        panel.window?.makeKeyAndOrderFront(nil)
        // Retain self — released on close
        objc_setAssociatedObject(panel.window as Any, "GoToFilePanel.owner", panel, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    // MARK: - Setup

    private func buildUI() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 320),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .borderless, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Go to File"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.center()
        panel.isReleasedWhenClosed = false
        self.window = panel

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 12
        visualEffect.layer?.masksToBounds = true
        panel.contentView = visualEffect

        // Search field
        searchField.placeholderString = "Go to File"
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchTextChanged(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.focusRingType = .none
        searchField.bezelStyle = .roundedBezel
        visualEffect.addSubview(searchField)

        // Status label
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.stringValue = "Indexing…"
        visualEffect.addSubview(statusLabel)

        // Table view
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.title = ""
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(acceptSelection(_:))
        tableView.backgroundColor = .clear
        tableView.appearance = NSAppearance(named: .darkAqua)  // HUD style

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.automaticallyAdjustsContentInsets = false
        visualEffect.addSubview(scrollView)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: visualEffect.topAnchor, constant: 16),
            searchField.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor, constant: -16),

            statusLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor, constant: -12),
        ])

        // Handle Esc key via cancelOperation
        panel.initialFirstResponder = searchField
    }

    override func cancelOperation(_ sender: Any?) {
        dismiss()
    }

    private func dismiss() {
        window?.close()
        // Break retain cycle from objc_setAssociatedObject
        objc_setAssociatedObject(window as Any, "GoToFilePanel.owner", nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    // MARK: - File Enumeration

    /// Returns the canonical (realpath-resolved) path string for a URL,
    /// ensuring consistency with the paths returned by FileManager.enumerator
    /// which internally resolves /var → /private/var symlinks.
    private static func canonicalPath(for url: URL) -> String {
        url.path.withCString { Darwin.realpath($0, nil).map { String(cString: $0) } } ?? url.path
    }

    private func enumerateFiles() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, let root = self.projectRoot else { return }
            let files = self.recursiveEnumeration(from: root, maxDepth: 6)
            DispatchQueue.main.async {
                self.allFiles = files
                self.statusLabel.stringValue = "\(files.count) files indexed — type to search"
                self.searchTextChanged(self.searchField)
            }
        }
    }

    private func recursiveEnumeration(from root: URL, maxDepth: Int) -> [URL] {
        var results: [URL] = []
        let fm = FileManager.default
        let rootPath = Self.canonicalPath(for: root) + "/"  // Compute once, not per-file
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return results }

        for case let fileURL as URL in enumerator {
            // Skip symlinks — prevents traversal outside project root
            if (try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                if fileURL.hasDirectoryPath { enumerator.skipDescendants() }
                continue
            }
            // Skip .git and other hidden dirs at depth
            let relative = fileURL.path.replacingOccurrences(of: rootPath, with: "")
            let components = relative.components(separatedBy: "/")
            if components.contains(where: { $0.hasPrefix(".") || $0 == "node_modules" }) {
                // Skip hidden directories (but don't skip the enumerator — just don't add)
                if fileURL.hasDirectoryPath {
                    enumerator.skipDescendants()
                }
                continue
            }
            // Depth check
            if components.count > maxDepth {
                if fileURL.hasDirectoryPath { enumerator.skipDescendants() }
                continue
            }
            if !fileURL.hasDirectoryPath {
                results.append(fileURL)
            }
        }
        return results
    }

    // MARK: - Fuzzy Matching

    @objc private func searchTextChanged(_ sender: Any) {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            self?.performSearch()
        }
    }

    private func performSearch() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            matches = []
            statusLabel.stringValue = "\(allFiles.count) files indexed — type to search"
            tableView.reloadData()
            return
        }

        let rootPath = Self.canonicalPath(for: projectRoot) + "/"
        let q = query.lowercased()

        var results: [FileMatch] = []

        for url in allFiles {
            let relative = url.path.replacingOccurrences(of: rootPath, with: "")
            let lower = relative.lowercased()
            if let score = fuzzyScore(query: q, candidate: lower) {
                results.append(FileMatch(url: url, relativePath: relative, score: score))
            }
        }

        results.sort { $0.score > $1.score }
        matches = Array(results.prefix(30))

        if matches.isEmpty {
            statusLabel.stringValue = "No matches"
        } else {
            statusLabel.stringValue = "\(matches.count) match\(matches.count == 1 ? "" : "es")"
        }

        tableView.reloadData()
        if !matches.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    /// Simple character-scanning fuzzy matcher: all query chars must appear in order.
    /// Scores consecutive matches, early position bias, and shorter paths higher.
    private func fuzzyScore(query: String, candidate: String) -> Double? {
        var score = 0.0
        var qi = query.startIndex
        var ci = candidate.startIndex
        var lastMatchIdx = -1
        var consecutiveBonus = 0.0

        while qi < query.endIndex, ci < candidate.endIndex {
            if query[qi] == candidate[ci] {
                let idx = candidate.distance(from: candidate.startIndex, to: ci)
                // Position bonus: earlier matches score higher
                score += 1.0 / Double(idx + 1)
                // Consecutive bonus
                if idx == lastMatchIdx + 1 {
                    consecutiveBonus += 2.0
                    score += consecutiveBonus
                } else {
                    consecutiveBonus = 0.0
                }
                lastMatchIdx = idx
                qi = query.index(after: qi)
            }
            ci = candidate.index(after: ci)
        }

        if qi < query.endIndex { return nil } // not all chars matched

        // Shorter paths are better
        score += 1.0 / Double(candidate.count + 1) * 0.5

        return score
    }

    // MARK: - Selection

    @objc private func acceptSelection(_ sender: Any) {
        guard tableView.selectedRow >= 0, tableView.selectedRow < matches.count else { return }
        let match = matches[tableView.selectedRow]
        onSelect?(match.url)
        dismiss()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36: // Enter
            acceptSelection(self)
        case 53: // Esc
            dismiss()
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - NSTableViewDataSource

extension GoToFilePanel: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return matches.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard row < matches.count else { return nil }
        return matches[row].relativePath
    }
}

// MARK: - NSTableViewDelegate

extension GoToFilePanel: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < matches.count else { return nil }

        let id = NSUserInterfaceItemIdentifier("FileCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id

            let icon = NSImageView()
            icon.imageScaling = .scaleProportionallyDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.setContentHuggingPriority(.required, for: .horizontal)
            cell.addSubview(icon)
            cell.imageView = icon

            let label = NSTextField(labelWithString: "")
            label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label

            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 18),
                icon.heightAnchor.constraint(equalToConstant: 18),

                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        let match = matches[row]
        cell.textField?.stringValue = match.relativePath
        cell.imageView?.image = NSWorkspace.shared.icon(forFile: match.url.path)

        return cell
    }
}