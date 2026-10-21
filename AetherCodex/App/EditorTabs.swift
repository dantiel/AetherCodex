import SwiftUI
import AppKit

// MARK: - Editor tab

/// One open document: its own `EditorViewController` (the AppKit controller that
/// owns `textStorage`, the live `NSTextView`, search, fold, and highlight state)
/// plus its own `EditorDocumentModel` (the SwiftUI-observable bridge feeding the
/// TextKit 2 surface). Keeping one controller per tab means a tab's entire state —
/// scroll, selection, undo stack, language, dirty flag — survives switching.
final class EditorTab: Identifiable, ObservableObject {
    let id = UUID()
    let controller: EditorViewController
    let document: EditorDocumentModel

    /// Title already carries TextMate's dirty convention ("name •"), published
    /// from `EditorViewController.onTitleChange`.
    @Published var title: String = "Untitled"
    /// Live dirty flag, published from `onStatusChange` (fires on edit + save).
    @Published var isDirty: Bool = false

    /// Forwarded from `controller.onStatusChange`; `TabsModel` wires it on the
    /// active tab only, so the bottom status strip mirrors the visible document
    /// (a background tab must never write it).
    var onStatusChange: ((String, String, String, Bool) -> Void)?

    /// Forwarded from `controller.onTitleChange` so `TabsModel` can push the
    /// active tab's title to the window chrome. Kept separate from `title` so the
    /// tab bar and the window title never fight over the same closure.
    var onTitleChange: ((String) -> Void)?

    init() {
        controller = EditorViewController()
        document = EditorDocumentModel()
        _ = controller.view  // force-load so viewDidLoad wires the text view + storage

        controller.onDocumentChange = { [weak self] attributedString in
            guard let self else { return }
            self.document.attributedString = attributedString
            self.document.revision += 1
        }
        controller.onDocumentMetricsChange = { [weak self] lineCount, maxLineWidth in
            guard let self else { return }
            // Runs on *every* keystroke. An @Published write emits objectWillChange
            // whether or not the value changed, so assigning unconditionally
            // re-evaluated the whole editor surface (gutter, overlays, scroll
            // extent) per character. Publish only a real shape change.
            if self.document.lineCount != lineCount { self.document.lineCount = lineCount }
            if self.document.maxLineWidth != maxLineWidth { self.document.maxLineWidth = maxLineWidth }
        }
        controller.onTitleChange = { [weak self] title in
            self?.title = title
            self?.onTitleChange?(title)
        }
        controller.onStatusChange = { [weak self] lineCol, tabInfo, language, dirty in
            guard let self else { return }
            // @Published emits objectWillChange even on an equal write; the
            // editor posts status on every caret move, so guard the flag.
            if self.isDirty != dirty { self.isDirty = dirty }
            self.onStatusChange?(lineCol, tabInfo, language, dirty)
        }
    }

    var isUntitled: Bool { controller.currentFile == nil }

    /// Seed the initial (untitled/flash) document. Mirrors the old single-editor
    /// bootstrap: the AppKit view is never laid out in the SwiftUI hierarchy, so
    /// `newDocument()` must run explicitly or the surface starts empty.
    /// `conjure` = true only for a window's *first* tab — the only place the
    /// Flash code-poetry setting applies. A new tab (⌘⇧N) seeds blank.
    func seedIfEmpty(conjure: Bool = true) {
        if controller.highlightedDocument().length == 0 {
            controller.newDocument(conjure: conjure)
        }
    }
}

// MARK: - Tabs model

/// Manages the open tabs of one window. A single source of truth for the tab
/// strip, the active document, and the window title — the SwiftUI chrome observes
/// this object, while `MainWindowController` drives it.
final class TabsModel: ObservableObject {
    @Published var tabs: [EditorTab] = []
    @Published var activeTabId: UUID?

    /// Aggregated status of the active document — observed by the bottom strip.
    let status = EditorStatusModel()

    /// Pushed whenever the active tab's title changes or the active tab switches.
    var onActiveTitleChange: ((String) -> Void)?

    /// Fired whenever the active tab switches (file/entity/diff). Distinct from
    /// `onActiveTitleChange` so the file browser can follow the active document's
    /// folder without reacting to per-keystroke dirty-marker title updates.
    var onActiveTabChange: (() -> Void)?

    var activeTab: EditorTab? {
        tabs.first { $0.id == activeTabId } ?? tabs.first
    }
    var activeEditor: EditorViewController? { activeTab?.controller }
    var activeDocument: EditorDocumentModel? { activeTab?.document }

    // MARK: Entity tabs (Magnum Opus tasks + Salomo seals)

    /// Entity documents (tasks / seals) opened as first-class tabs beside files.
    @Published var entityTabs: [EntityDocumentTab] = []
    @Published var activeEntityTabId: UUID?

    var activeEntityTab: EntityDocumentTab? {
        entityTabs.first { $0.id == activeEntityTabId }
    }

    // MARK: Diff tabs (unified git diffs opened in the main editor area)

    @Published var diffTabs: [DiffTab] = []
    @Published var activeDiffTabId: UUID?

    var activeDiffTab: DiffTab? {
        diffTabs.first { $0.id == activeDiffTabId }
    }

    /// The tab strip shows whenever there is more than one document of any kind.
    var showsTabBar: Bool {
        tabs.count + entityTabs.count + diffTabs.count > 1 || GeneralSettings.shared.alwaysShowTabBar
    }

    init() {
        let first = EditorTab()
        first.seedIfEmpty(conjure: true)
        tabs = [first]
        activeTabId = first.id
        attachTitleHook(first)
        refreshStatus()
    }

    @discardableResult
    func newTab() -> EditorTab {
        let tab = EditorTab()
        tab.seedIfEmpty(conjure: false)
        tabs.append(tab)
        attachTitleHook(tab)
        select(tab.id)
        return tab
    }

    func select(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        activeTabId = id
        activeEntityTabId = nil
        activeDiffTabId = nil
        onActiveTitleChange?(tab.title)
        onActiveTabChange?()
        refreshStatus()
    }

    func selectNext() {
        guard tabs.count > 1, let cur = activeTab,
              let idx = tabs.firstIndex(where: { $0.id == cur.id }) else { return }
        select(tabs[(idx + 1) % tabs.count].id)
    }

    func selectPrevious() {
        guard tabs.count > 1, let cur = activeTab,
              let idx = tabs.firstIndex(where: { $0.id == cur.id }) else { return }
        select(tabs[(idx - 1 + tabs.count) % tabs.count].id)
    }

    func close(_ id: UUID) {
        guard tabs.count > 1, let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: idx)
        if activeTabId == id {
            let next = tabs[max(0, idx - 1)]
            activeTabId = next.id
            onActiveTitleChange?(next.title)
            onActiveTabChange?()
        }
        refreshStatus()
    }

    /// Open an entity (task or seal) as a tab. Reuses an existing tab for the
    /// same entity, otherwise appends a fresh one and selects it.
    @discardableResult
    func openEntityTab(_ kind: EntityTabKind, title: String) -> EntityDocumentTab {
        if let existing = entityTabs.first(where: { $0.kind == kind }) {
            selectEntity(existing.id)
            return existing
        }
        let tab = EntityDocumentTab(kind: kind, title: title)
        entityTabs.append(tab)
        selectEntity(tab.id)
        return tab
    }

    func selectEntity(_ id: UUID) {
        guard let tab = entityTabs.first(where: { $0.id == id }) else { return }
        activeEntityTabId = id
        activeDiffTabId = nil
        onActiveTitleChange?(tab.title)
        onActiveTabChange?()
        refreshStatus()
    }

    // MARK: Diff tab management

    /// Open a unified diff as a first-class tab and make it visible.
    @discardableResult
    func openDiffTab(title: String, subtitle: String = "", diff: String,
                     filePath: URL? = nil, repoRoot: URL? = nil) -> DiffTab {
        let tab = DiffTab(title: title, subtitle: subtitle, diff: diff,
                          filePath: filePath, repoRoot: repoRoot)
        diffTabs.append(tab)
        selectDiff(tab.id)
        return tab
    }

    func selectDiff(_ id: UUID) {
        guard let tab = diffTabs.first(where: { $0.id == id }) else { return }
        activeDiffTabId = id
        activeEntityTabId = nil
        onActiveTitleChange?(tab.title)
        onActiveTabChange?()
        refreshStatus()
    }

    func closeDiff(_ id: UUID) {
        guard let idx = diffTabs.firstIndex(where: { $0.id == id }) else { return }
        diffTabs.remove(at: idx)
        if activeDiffTabId == id {
            activeDiffTabId = nil
            onActiveTitleChange?(activeTab?.title ?? "Untitled")
            onActiveTabChange?()
        }
        refreshStatus()
    }

    func closeEntity(_ id: UUID) {
        guard let idx = entityTabs.firstIndex(where: { $0.id == id }) else { return }
        entityTabs.remove(at: idx)
        if activeEntityTabId == id {
            activeEntityTabId = nil
            onActiveTitleChange?(activeTab?.title ?? "Untitled")
            onActiveTabChange?()
        }
        refreshStatus()
    }

    /// Reuse the active tab when it is a clean, untitled document (the first file
    /// you open fills the empty tab), otherwise open a fresh tab — the TextMate
    /// behaviour for a tabbed editor.
    @discardableResult
    func tabForOpening(_ url: URL) -> EditorTab {
        let tab: EditorTab
        if let active = activeTab, active.isUntitled && !active.isDirty {
            tab = active
        } else {
            tab = newTab()
        }
        if activeTabId != tab.id { select(tab.id) }
        return tab
    }

    private func attachTitleHook(_ tab: EditorTab) {
        tab.onTitleChange = { [weak self] title in
            guard let self, self.activeTabId == tab.id else { return }
            self.onActiveTitleChange?(title)
        }
    }

    /// Mirror the *visible* document into the bottom status strip. Only the
    /// active tab forwards: entity/diff tabs own no caret, so they speak a
    /// language and nothing else, and a hidden file tab keeps its hook unwired
    /// (its own `isDirty` still tracks, the strip simply does not listen).
    private func refreshStatus() {
        if activeDiffTab != nil {
            status.set(language: "Diff")
            return
        }
        if activeEntityTab != nil {
            status.set(language: "Æther")
            return
        }
        guard let tab = activeTab else {
            status.set(language: "Plain Text")
            return
        }
        tab.onStatusChange = { [weak self] lineCol, tabInfo, language, dirty in
            self?.status.update(position: lineCol, tabInfo: tabInfo,
                                language: language, isDirty: dirty)
        }
        // Re-publish the freshly wired tab's current state at once — the editor
        // only posts on the next caret move otherwise, and the strip would show
        // the previous tab's language while the new one is already on screen.
        tab.controller.updateStatusBar()
    }
}