import AppKit
import SwiftUI
import Combine

// MARK: - Find & Replace window (TextMate-style)

/// A single floating panel, shared by every editor tab, that hosts the find &
/// replace UI. The active editor's model is rebound on each ⌘F / ⌘⌥F; the panel
/// never holds a tab's model beyond the time it is visible, so closing a tab
/// cannot leak its find state.
///
/// The panel is deliberately a *window*, not an in-editor bar: project-wide
/// search and long result lists belong in their own surface, leaving the code
/// view unobstructed — exactly the TextMate geometry the quick-search bar (which
/// stays docked in the bottom safe-area band) must never share.

// MARK: - SwiftUI content

/// The Find & Replace scene's content.
///
/// The bound model lives on `AppScene`, which is also what folds the window away
/// once the model reports itself invisible — Esc, the close button, or a
/// `cancel()` from the responder chain. Closing the window is that same gesture
/// seen from the other side, so it cancels too: the pre-search selection is
/// restored and the editor takes focus back.
@MainActor
struct FindReplaceScene: View {
    @ObservedObject private var scene = AppScene.shared

    var body: some View {
        Group {
            if let model = scene.findModel {
                FindReplaceWindowView(model: model)
            } else {
                Color.clear
            }
        }
        .onDisappear {
            // Deferred: cancelling publishes, and `onDisappear` runs while
            // SwiftUI is still tearing the window down.
            DispatchQueue.main.async { scene.findModel?.cancel() }
        }
    }
}

private struct FindReplaceWindowView: View {
    @ObservedObject var model: FindReplaceModel
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            results
            Divider().opacity(0.5)
            footer
        }
        // The fill wears the window's silhouette — a `UtilityWindow` scene, so the
        // utility radius, not the window's. The frame is rounded by the window
        // server; a material at its own curvature leaves the seam mismatched.
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: EditorChromeMetrics.utilityWindowCornerRadius,
                                         style: .continuous))
        .frame(minWidth: 480, minHeight: 220)
        .onExitCommand { model.cancel() }
        .onAppear {
            DispatchQueue.main.async { queryFocused = true }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField("Find", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($queryFocused)
                    .onChange(of: model.query) { _, newValue in model.setQuery(newValue) }
                    .onSubmit { model.next() }

                optionToggle("Aa", value: $model.ignoreCase)
                optionToggle(".*", value: $model.regularExpression)
                optionToggle("W", value: $model.wholeWord)
                optionToggle("↩︎", value: $model.wrapAround)
            }

            if model.isReplaceMode && model.scope != .project {
                HStack(spacing: 8) {
                    TextField("Replace", text: $model.replacement)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .onSubmit { model.replaceCurrent() }

                    Button("Replace") { model.replaceCurrent() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(model.matches.isEmpty)

                    Button("All") { model.replaceAll() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.matches.isEmpty)
                }
            }

            HStack(spacing: 12) {
                Picker("Scope", selection: $model.scope) {
                    ForEach(FindReplaceModel.Scope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: model.scope) { _, _ in model.search() }

                Spacer()

                if model.isSearchingProject {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(12)
    }

    // MARK: Results

    @ViewBuilder
    private var results: some View {
        if model.scope == .project {
            projectResults
        } else if !model.rows.isEmpty {
            fileResults
        } else {
            Spacer(minLength: 0)
        }
    }

    private var fileResults: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(model.rows) { row in
                    Button {
                        model.select(rowIndex: row.index)
                    } label: {
                        rowLabel(row, current: row.index == model.currentIndex)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        row.index == model.currentIndex
                            ? Color.accentColor.opacity(0.14)
                            : Color.clear
                    )
                    .id(row.index)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onChange(of: model.currentIndex) { _, index in
                proxy.scrollTo(index, anchor: .center)
            }
        }
    }

    private var projectResults: some View {
        List {
            ForEach(model.projectMatches) { match in
                Button {
                    model.openFile?(match.url, match.line)
                } label: {
                    HStack(spacing: 8) {
                        Text(match.url.lastPathComponent)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(":\(match.line)")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(match.lineText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func rowLabel(_ row: FindResultRow, current: Bool) -> some View {
        HStack(spacing: 8) {
            Text("\(row.line)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(current ? Color.accentColor : Color.secondary)
                .frame(width: 44, alignment: .trailing)
            Text(highlighted(row))
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
    }

    private func highlighted(_ row: FindResultRow) -> AttributedString {
        var s = AttributedString(row.text)
        let ns = row.text as NSString
        let loc = min(row.localRange.location, ns.length)
        let len = min(row.localRange.length, ns.length - loc)
        guard loc >= 0, len > 0 else { return s }
        let start = s.index(s.startIndex, offsetByCharacters: loc)
        let end = s.index(start, offsetByCharacters: len)
        s[start..<end].foregroundColor = Color.accentColor
        s[start..<end].font = .system(size: 12, weight: .bold)
        return s
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text(model.resultSummary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            if model.scope != .project && !model.matches.isEmpty {
                Text("\(model.currentIndex + 1)/\(model.matches.count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)

                if model.rows.count < model.matches.count {
                    Text("· first \(model.rows.count) shown")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if model.scope != .project {
                Button { model.previous() } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                .disabled(model.matches.isEmpty)

                Button { model.next() } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
                .disabled(model.matches.isEmpty)
            }

            Button { model.cancel() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func optionToggle(_ label: String, value: Binding<Bool>) -> some View {
        Button {
            value.wrappedValue.toggle()
            model.search()
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(value.wrappedValue ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
    }
}