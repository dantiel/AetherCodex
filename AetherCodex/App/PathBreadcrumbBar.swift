import SwiftUI
import AppKit

// MARK: - Breadcrumb model

/// One breadcrumb segment — display name, resolved URL, and directory flag.
struct BreadcrumbSegment: Identifiable {
    var id: String { url.path }
    let name: String
    let url: URL
    let isDirectory: Bool
}

/// A breadcrumb trail item — either a real segment or a collapsed ellipsis that
/// groups hidden ancestors so the trail never scrolls off either edge.
private enum TrailItem: Identifiable {
    case segment(BreadcrumbSegment)
    case ellipsis(hidden: [BreadcrumbSegment])

    var id: String {
        switch self {
        case .segment(let s): return s.id
        case .ellipsis: return "__ellipsis__"
        }
    }
}

/// Split a filesystem path into breadcrumb segments, root-first.
private func pathComponents(from path: String) -> [BreadcrumbSegment] {
    var result = [BreadcrumbSegment(name: "/", url: URL(fileURLWithPath: "/"), isDirectory: true)]
    var running = URL(fileURLWithPath: "/")
    for part in URL(fileURLWithPath: path).pathComponents.dropFirst() where part != "/" && !part.isEmpty {
        running.appendPathComponent(part)
        result.append(BreadcrumbSegment(name: part, url: running, isDirectory: true))
    }
    // Mark the final segment by actually resolving the filesystem.
    if var last = result.last, last.url.path != "/" {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: last.url.path, isDirectory: &isDir)
        last = BreadcrumbSegment(name: last.name, url: last.url, isDirectory: exists && isDir.boolValue)
        result[result.count - 1] = last
    }
    return result
}

/// Immediate children of a directory — folders first, then files, both sorted.
private func directoryChildren(of dir: String, limit: Int = .max) -> [BreadcrumbSegment] {
    let fm = FileManager.default
    let url = URL(fileURLWithPath: dir)
    let keys: [URLResourceKey] = [.isDirectoryKey]
    guard let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles]) else {
        return []
    }
    var dirs: [BreadcrumbSegment] = []
    var files: [BreadcrumbSegment] = []
    for child in contents {
        let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let seg = BreadcrumbSegment(name: child.lastPathComponent, url: child, isDirectory: isDir)
        if isDir { dirs.append(seg) } else { files.append(seg) }
    }
    let sort: (BreadcrumbSegment, BreadcrumbSegment) -> Bool = {
        $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
    let combined = dirs.sorted(by: sort) + files.sorted(by: sort)
    return limit == .max ? combined : Array(combined.prefix(limit))
}

// MARK: - Path breadcrumb bar

/// Glass path breadcrumb living in the titlebar. Shows the active document's
/// directory hierarchy (or the project root when no document is open). The root
/// stays anchored at the left and the current folder/file at the right; only the
/// middle collapses — first to middle-ellipses, then into a single "…" menu when
/// there are too many levels to fit. The trail never scrolls.
///
/// Each folder segment is a split control: the label navigates the sidebar to
/// that folder (a peek — the hierarchy never collapses), while the adjacent
/// chevron opens a combo menu of siblings so you can jump sideways.
struct PathBreadcrumbBar: View {
    @ObservedObject var chrome: EditorChromeState
    @ObservedObject var tabs: TabsModel
    @ObservedObject private var aetherContext = AetherContext.shared

    @State private var isEditing = false
    @State private var pathText = ""
    @State private var invalidPath = false
    /// Segment whose combo chevron is currently revealed (hover-only).
    @State private var hoveredID: String? = nil

    /// Cap for intermediate segment width — long folder names truncate to this.
    private let segmentMaxWidth: CGFloat = 96

    /// The folder the breadcrumb addresses — the sidebar's current folder, falling
    /// back to the project root, then home. (The address bar follows the project's
    /// navigation, not the active document.)
    private var currentURL: URL? {
        if let folder = chrome.currentFolder { return folder }
        if let root = aetherContext.root { return URL(fileURLWithPath: root) }
        return URL(fileURLWithPath: NSHomeDirectory())
    }

    private var projectRootURL: URL? {
        if let root = aetherContext.root { return URL(fileURLWithPath: root).standardizedFileURL }
        return nil
    }

    /// Segments pinned to the project root: when the current folder lives at or
    /// below the project root, the root is the first (anchor) segment — clicking
    /// it returns to the project — and deeper folders extend to its right. The
    /// project context is therefore never lost while navigating.
    private var components: [BreadcrumbSegment] {
        let currentPath = currentURL?.standardizedFileURL.path ?? NSHomeDirectory()
        guard let root = projectRootURL else {
            return pathComponents(from: currentPath)
        }
        let rootPath = root.path
        if currentPath == rootPath {
            // At the project root, still show the full absolute path — the address
            // bar is a hierarchy, never a lone name. The root is the last segment.
            return pathComponents(from: currentPath)
        }
        if currentPath.hasPrefix(rootPath + "/") {
            var segs = [BreadcrumbSegment(name: root.lastPathComponent, url: root, isDirectory: true)]
            var running = root
            let rel = currentPath.dropFirst(rootPath.count)   // e.g. "/sub/dir"
            for part in URL(fileURLWithPath: String(rel)).pathComponents where part != "/" && !part.isEmpty {
                running.appendPathComponent(part)
                segs.append(BreadcrumbSegment(name: part, url: running, isDirectory: true))
            }
            return segs
        }
        // Current folder is above the project root — show the full path; the root
        // still appears as a normal (clickable) segment within it.
        return pathComponents(from: currentPath)
    }

    /// With several levels, intermediate segments collapse to their icon so the
    /// trail stays dense; hovering a segment re-expands its title (see
    /// `segmentLabel`). The last segment and short trails always show names.
    private var isCompactTrail: Bool { components.count > 4 }

    var body: some View {
        Group {
            if isEditing {
                PathAutosuggestField(
                    text: $pathText,
                    invalid: invalidPath,
                    onCommit: { commitPath($0) },
                    onCancel: { isEditing = false }
                )
                .frame(maxWidth: 520)
                .transition(.opacity)
            } else {
                crumbTrail
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isEditing)
        .onChange(of: invalidPath) { _, invalid in
            guard invalid else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { invalidPath = false }
        }
    }

    // MARK: Breadcrumb trail

    private var crumbTrail: some View {
        ViewThatFits(in: .horizontal) {
            trail(trailing: 4)
            trail(trailing: 3)
            trail(trailing: 2)
            trail(trailing: 1)
        }
        .frame(height: 28)
    }

    /// The trail for a given number of trailing (right-most) segments. The root
    /// segment is always first and the current folder/file always last; the levels
    /// in between collapse into a single "…" menu when there are too many to fit.
    /// `ViewThatFits` walks the candidates widest-first, so the trail adapts to the
    /// available width instead of scrolling off either edge.
    private func trail(trailing: Int) -> some View {
        HStack(spacing: 2) {
            let items = visibleItems(trailing: trailing)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { breadcrumbDivider }
                switch item {
                case .segment(let comp):
                    segmentButton(comp, isLast: comp.id == components.last?.id)
                case .ellipsis(let hidden):
                    ellipsisButton(hidden)
                }
            }
        }
    }

    /// Collapse the trail to root + (optional "…") + the last `trailing` segments.
    private func visibleItems(trailing: Int) -> [TrailItem] {
        let all = components
        guard !all.isEmpty else { return [] }
        if all.count <= trailing + 1 {
            return all.map { .segment($0) }
        }
        let hidden = Array(all[1..<(all.count - trailing)])
        var items: [TrailItem] = [.segment(all[0])]
        if !hidden.isEmpty { items.append(.ellipsis(hidden: hidden)) }
        items += all.suffix(trailing).map { .segment($0) }
        return items
    }


    /// A single breadcrumb segment — a rounded tab whose label navigates the
    /// sidebar (a peek — the hierarchy never collapses) and whose trailing combo
    /// chevron (revealed only on hover, like a swift dipping its wing) opens a
    /// menu of siblings so you can jump sideways. Dividers live *between* tabs,
    /// never drawn on a segment.
    private func segmentButton(_ comp: BreadcrumbSegment, isLast: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return HStack(spacing: 2) {
            Button {
                navigate(comp)
            } label: {
                segmentLabel(comp, isLast: isLast)
            }
            .buttonStyle(.plain)
            .contextMenu { titleMenu }

            Menu {
                siblingMenu(comp)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            // Combo chevrons materialize only on hover. Reserved space keeps the
            // trail from re-flowing while preserving density.
            .opacity(hoveredID == comp.id ? 1 : 0)
            .scaleEffect(hoveredID == comp.id ? 1 : 0.4, anchor: .center)
        }
        .frame(height: 24)
        .background {
            shape.fill(.ultraThinMaterial)
            if hoveredID == comp.id {
                shape.fill(.white.opacity(0.07))
            }
        }
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .contentShape(shape)
        .onHover { hovering in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                hoveredID = hovering ? comp.id : nil
            }
        }
    }

    /// Collapsed-middle marker — a "…" menu listing the hidden ancestors so any
    /// elided level stays reachable.
    private func ellipsisButton(_ hidden: [BreadcrumbSegment]) -> some View {
        Menu {
            ForEach(hidden) { comp in
                Button { navigate(comp) } label: {
                    Label(comp.name, systemImage: comp.isDirectory ? "folder" : FileIcon.symbol(for: comp.url))
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .frame(height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        }
        .help("\(hidden.count) hidden levels")
    }

    @ViewBuilder
    private func segmentLabel(_ comp: BreadcrumbSegment, isLast: Bool) -> some View {
        if isLast {
            // Always full: the current folder/file keeps its icon + name so the
            // address is never ambiguous.
            HStack(spacing: 3) {
                Image(systemName: iconName(for: comp))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(comp.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: 200, alignment: .leading)
            .contentShape(Rectangle())
        } else if isCompactTrail && hoveredID != comp.id {
            // Tight trail: icon-only, title unfolds on hover.
            Image(systemName: iconName(for: comp))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .contentShape(Rectangle())
        } else {
            HStack(spacing: 3) {
                Image(systemName: iconName(for: comp))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(comp.name)
                    .font(.system(size: 11, weight: .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 5)
            .frame(maxWidth: segmentMaxWidth, alignment: .leading)
            .contentShape(Rectangle())
        }
    }

    /// Condensed directional divider — a single right-angle bracket that sits
    /// *between* tabs (never drawn on a segment), taking almost no horizontal
    /// space while preserving the trail's sense of direction.
    private var breadcrumbDivider: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 14, height: 24)
            .fixedSize()
    }

    // MARK: Menus & navigation

    @ViewBuilder
    private func siblingMenu(_ comp: BreadcrumbSegment) -> some View {
        let sibs = siblings(of: comp.url)
        if sibs.isEmpty {
            Text("No items").foregroundStyle(.secondary)
        } else {
            ForEach(sibs) { sib in
                Button {
                    navigate(sib)
                } label: {
                    Label(sib.name, systemImage: sib.isDirectory ? "folder" : FileIcon.symbol(for: sib.url))
                }
            }
        }
    }

    private func siblings(of url: URL) -> [BreadcrumbSegment] {
        directoryChildren(of: url.deletingLastPathComponent().path)
    }

    private func iconName(for comp: BreadcrumbSegment) -> String {
        comp.isDirectory ? "folder" : FileIcon.symbol(for: comp.url)
    }

    private func navigate(_ comp: BreadcrumbSegment) {
        if comp.isDirectory {
            chrome.navigateFolder?(comp.url)
        } else {
            chrome.openDocument?(comp.url)
        }
    }

    @ViewBuilder
    private var titleMenu: some View {
        if let url = currentURL {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Copy Path") { copyToPasteboard(url.path) }
            Button("Copy File Name") { copyToPasteboard(url.lastPathComponent) }
            Divider()
        }
        Button("New Tab") { tabs.newTab() }
        if tabs.tabs.count > 1, let id = tabs.activeTabId {
            Button("Close Tab") { tabs.close(id) }
        }
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func commitPath(_ raw: String) {
        var expanded = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if expanded.hasPrefix("~") {
            expanded = (expanded as NSString).expandingTildeInPath
        }
        let standardized = (expanded as NSString).standardizingPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized, isDirectory: &isDir), isDir.boolValue else {
            invalidPath = true
            return
        }
        invalidPath = false
        chrome.navigateFolder?(URL(fileURLWithPath: standardized))
        isEditing = false
    }
}

// MARK: - Path edit field (autosuggest + combobox)

/// A decorated path editor: monospaced, select-all friendly, with live
/// autosuggestion of directory children and a combobox dropdown of the same.
private struct PathAutosuggestField: View {
    @Binding var text: String
    let invalid: Bool
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @FocusState private var focused: Bool
    @State private var suggestions: [BreadcrumbSegment] = []

    var body: some View {
        fieldRow
            .overlay(alignment: .topLeading) {
                GeometryReader { geo in
                    if focused && !suggestions.isEmpty {
                        suggestionList
                            .frame(width: geo.size.width)
                            .offset(y: geo.size.height + 4)
                            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .zIndex(10)
            .animation(.easeInOut(duration: 0.15), value: focused)
            .animation(.easeInOut(duration: 0.15), value: suggestions.isEmpty)
            .onAppear { focused = true; refresh() }
            .onChange(of: text) { _, _ in refresh() }
    }

    private var fieldRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Path", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .focused($focused)
                .onSubmit { onCommit(text) }
                .onExitCommand { onCancel() }
            Menu {
                ForEach(suggestions) { sib in
                    Button { complete(with: sib) } label: {
                        Label(sib.name, systemImage: sib.isDirectory ? "folder" : FileIcon.symbol(for: sib.url))
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 18)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(invalid ? Color.red.opacity(0.6) : Color.white.opacity(0.12), lineWidth: 0.5)
        }
    }

    private var suggestionList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(suggestions) { sib in
                    Button { complete(with: sib) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: sib.isDirectory ? "folder" : FileIcon.symbol(for: sib.url))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(sib.name)
                                .font(.system(size: 11))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 150)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        }
        .padding(.top, 2)
        .zIndex(20)
    }

    // MARK: Suggestion engine

    private func refresh() {
        let trimmed = (text as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDir), isDir.boolValue {
            suggestions = directoryChildren(of: trimmed, limit: 60)
        } else {
            let dir = (trimmed as NSString).deletingLastPathComponent
            let prefix = (trimmed as NSString).lastPathComponent
            suggestions = directoryChildren(of: dir, limit: 120).filter {
                prefix.isEmpty || $0.name.lowercased().hasPrefix(prefix.lowercased())
            }
        }
    }

    private func complete(with sib: BreadcrumbSegment) {
        let trimmed = (text as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDir), isDir.boolValue {
            text = sib.url.path
        } else {
            let dir = (trimmed as NSString).deletingLastPathComponent
            text = (dir as NSString).appendingPathComponent(sib.name)
        }
        suggestions = []
    }
}