import SwiftUI
import Cocoa

/// Search pane of the left sidebar — quiet, inline, project-scoped.
/// The search field lives in the pane's top safe-area bar (below the shared
/// folder row); results stream into the scroll body, capped at 50, ranked by
/// the same engine the ⌘T Go-To-File panel uses. The magnifier button opens
/// the full spotlight-style panel for deep dives.
@MainActor
final class SidebarSearchModel: ObservableObject {
    /// Project root to search — mirrors the sidebar file browser's folder.
    @Published var root: URL?
    @Published var query: String = ""
    @Published var results: [GoToFileMatch] = []
    @Published var searching = false

    /// Open a matched file (wired to MainWindowController.openFileInTab).
    var open: (URL) -> Void = { _ in }

    private var searchTask: Task<Void, Never>?

    /// Debounced re-search (180 ms) — enumeration happens off the main actor.
    func queryChanged() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard let root, !trimmed.isEmpty else {
            results = []
            searching = false
            return
        }
        searching = true
        searchTask = Task { [weak self] in
            let files = await Task.detached(priority: .userInitiated) {
                GoToFileEngine.enumerate(root: root)
            }.value
            guard !Task.isCancelled else { return }
            let matches = GoToFileEngine.matches(query: trimmed, files: files, currentURL: nil)
            guard !Task.isCancelled, let self else { return }
            self.results = Array(matches.prefix(50))
            self.searching = false
        }
    }

    /// Open the full Go-To-File panel (spotlight style) over the current root.
    func openPanel() {
        guard let root else { return }
        let opener = open
        GoToFilePanel.show(projectRoot: root, onSelect: opener)
    }
}

@available(macOS 26.0, *)
struct SidebarSearchView: View {
    @ObservedObject var model: SidebarSearchModel
    @ObservedObject var chrome: EditorChromeState
    @FocusState private var fieldFocused: Bool
    @State private var queryProxy: String = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    emptyHint
                } else if model.results.isEmpty && !model.searching {
                    Text("Nothing found")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                } else {
                    ForEach(model.results) { match in
                        resultRow(match)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .safeAreaBar(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                // Traffic lights + the shared folder row live in the enclosing
                // sidebar safe-area bar; this pane reserves that band.
                Color.clear.frame(height: 46)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("Search files…", text: $queryProxy)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($fieldFocused)
                        .onSubmit { commit() }
                        .onChange(of: queryProxy) { newValue in
                            model.query = newValue
                            model.queryChanged()
                        }
                    if model.searching {
                        ProgressView().controlSize(.mini)
                    }
                    Button {
                        model.openPanel()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(model.root == nil)
                    .help("Open Go-To-File panel")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                Divider().opacity(0.4)
            }
        }
        .sidebarTabBar(chrome)
        .onAppear {
            queryProxy = model.query
            fieldFocused = true
        }
    }

    private func commit() {
        model.query = queryProxy
        model.queryChanged()
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Search the project by filename.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Prefix fragments rank first — “pyth pan” finds PythiaPanel.swift. The magnifier opens the full Go-To-File panel.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private func resultRow(_ match: GoToFileMatch) -> some View {
        Button {
            model.open(match.url)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: FileIcon.symbol(for: match.url))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(match.fileName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(match.displayDirectory)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}