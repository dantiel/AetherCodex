import SwiftUI
import AppKit

// MARK: - Match

/// One incremental-search hit. `range` is UTF-16 within the live editor string,
/// `line` is 1-based (drives the gutter highlight + scroll reveal).
struct QuickMatch: Equatable {
    let range: NSRange
    let line: Int
}

// MARK: - Model

/// Single source of truth for TextMate-style Ctrl+S incremental search.
/// Owned by `EditorViewController` (so AppKit key monitoring and menu items can
/// reach it), observed by the SwiftUI `TextKit2ScrollSurface` which renders the
/// bar and performs the scroll reveal.
@MainActor
final class QuickSearchModel: ObservableObject {
    @Published var isVisible = false
    @Published var query = ""
    @Published var ignoreCase = true
    @Published var wrapAround = true

    @Published private(set) var matches: [QuickMatch] = []
    @Published private(set) var currentIndex: Int = 0

    /// Line to scroll into view (1-based), plus a monotonically-increasing token
    /// so SwiftUI can react even when two consecutive matches land on one line.
    @Published var pendingRevealLine: Int? = nil
    @Published var revealToken: Int = 0

    /// Bumped whenever a non-empty query finds nothing — the bar shakes. An
    /// integer token, not a flag: every new failure is a fresh increment, so the
    /// shake replays even while the previous one is still settling.
    @Published private(set) var notFoundToken: Int = 0

    weak var textView: NSTextView?

    /// Captured selection when the bar opened — Esc restores it.
    private var originRange: NSRange?
    /// Captured multiple selections (carets) when the bar opened — Esc restores them.
    private var originRanges: [NSRange]?

    var sourceString: String { textView?.string ?? "" }

    /// True when the editor is in multi-caret/multi-selection mode.
    var isMultiCaret: Bool { (textView?.selectedRanges.count ?? 0) > 1 }

    /// Ctrl+S: open the bar, or navigate to the next match when already open.
    func toggle() {
        if isVisible { next() } else { show() }
    }

    func show() {
        guard !isVisible else { return }
        let ranges = textView?.selectedRanges.map { $0.rangeValue } ?? []
        if ranges.count > 1 {
            originRanges = ranges
            originRange = nil
        } else {
            originRange = textView?.selectedRange()
            originRanges = nil
        }
        isVisible = true
        if !query.isEmpty { search() }
    }

    /// Esc — return to the pre-search selection and fold the bar away.
    func cancel() {
        dismiss(restore: true)
    }

    /// Return — accept the current match and fold away, leaving the selection.
    func confirm() {
        dismiss(restore: false)
    }

    func next() { step(1) }
    func previous() { step(-1) }

    func setQuery(_ newQuery: String) {
        query = newQuery
        search()
    }

    /// Re-run the search with the current query + options (used by the Aa toggle).
    func reSearch() {
        search()
    }

    // MARK: - Internals

    private func dismiss(restore: Bool) {
        guard isVisible else { return }
        isVisible = false
        if restore, let tv = textView {
            if let origins = originRanges, origins.count > 1 {
                let valid = origins.filter { NSMaxRange($0) <= tv.string.count }
                if !valid.isEmpty {
                    tv.setSelectedRanges(valid.map { NSValue(range: $0) },
                                         affinity: .upstream, stillSelecting: false)
                }
            } else if let origin = originRange, NSMaxRange(origin) <= tv.string.count {
                tv.setSelectedRange(origin)
            }
        }
        matches = []
        currentIndex = 0
        pendingRevealLine = nil
        originRange = nil
        originRanges = nil
        if let tv = textView {
            tv.window?.makeFirstResponder(tv)
        }
    }

    private func search() {
        guard let tv = textView else {
            matches = []
            currentIndex = 0
            pendingRevealLine = nil
            return
        }
        let string = tv.string as NSString
        guard !query.isEmpty, string.length > 0 else {
            matches = []
            currentIndex = 0
            pendingRevealLine = nil
            return
        }

        var opts: NSString.CompareOptions = [.literal]
        if ignoreCase { opts.insert(.caseInsensitive) }
        matches = Self.scan(string, query: query, options: opts)

        guard !matches.isEmpty else {
            currentIndex = 0
            pendingRevealLine = nil
            notFoundToken += 1          // typed query, nothing in the code → shake
            return
        }

        if isMultiCaret {
            // Fan out: every caret jumps to its own next match of the fresh query.
            applyMultiSearch()
        } else {
            // First match at/after the origin (TextMate semantics).
            let origin = originRange?.location ?? 0
            let idx = matches.firstIndex { $0.range.location >= origin } ?? 0
            currentIndex = idx
            applyCurrent()
        }
    }

    private func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        if isMultiCaret {
            applyMultiStep(delta: delta)
            return
        }
        let n = matches.count
        if wrapAround {
            currentIndex = (currentIndex + delta + n) % n
        } else {
            currentIndex = min(max(currentIndex + delta, 0), n - 1)
        }
        applyCurrent()
    }

    private func applyCurrent() {
        guard !matches.isEmpty, currentIndex < matches.count else { return }
        let m = matches[currentIndex]
        if let tv = textView, NSMaxRange(m.range) <= tv.string.count {
            tv.setSelectedRange(m.range)
        }
        pendingRevealLine = m.line
        revealToken += 1
    }

    /// Multi-caret, query (re)search: each caret selects the first match at or
    /// after its own position — one independent fundstelle per caret.
    private func applyMultiSearch() {
        guard let tv = textView, !matches.isEmpty else { return }
        let selections = tv.selectedRanges.map { $0.rangeValue }
        guard selections.count > 1 else { return }
        var found: [QuickMatch] = []
        for sel in selections {
            let anchor = sel.location
            let idx = matches.firstIndex { $0.range.location >= anchor } ?? 0
            found.append(matches[idx])
        }
        applyMultiRanges(found)
    }

    /// Multi-caret, next/previous navigation: each caret advances independently
    /// to its own next (`delta >= 0`) or previous (`delta < 0`) match.
    private func applyMultiStep(delta: Int) {
        guard let tv = textView, !matches.isEmpty else { return }
        let selections = tv.selectedRanges.map { $0.rangeValue }
        guard selections.count > 1 else { return }
        var found: [QuickMatch] = []
        for sel in selections {
            let idx: Int
            if delta >= 0 {
                if sel.length > 0 {
                    let start = NSMaxRange(sel)
                    idx = matches.firstIndex { $0.range.location >= start } ?? 0
                } else {
                    idx = matches.firstIndex { $0.range.location > sel.location } ?? 0
                }
            } else {
                idx = matches.lastIndex { $0.range.location < sel.location } ?? (matches.count - 1)
            }
            found.append(matches[idx])
        }
        applyMultiRanges(found)
    }

    /// Commit a set of independent matches as simultaneous selections, deduped
    /// and ordered by location, then reveal the first one.
    private func applyMultiRanges(_ found: [QuickMatch]) {
        guard let tv = textView, !found.isEmpty else { return }
        var seen = Set<Int>()
        var ordered: [QuickMatch] = []
        for m in found where NSMaxRange(m.range) <= tv.string.count {
            if seen.insert(m.range.location).inserted {
                ordered.append(m)
            }
        }
        guard !ordered.isEmpty else { NSSound.beep(); return }
        ordered.sort { $0.range.location < $1.range.location }

        tv.setSelectedRanges(ordered.map { NSValue(range: $0.range) },
                             affinity: .upstream, stillSelecting: false)

        if let first = ordered.first,
           let idx = matches.firstIndex(where: { $0.range.location >= first.range.location }) {
            currentIndex = idx
        }
        pendingRevealLine = ordered[0].line
        revealToken += 1
        tv.scrollRangeToVisible(ordered[0].range)
    }

    /// Exact vertical center of the current match's line, in the adopted text
    /// view's top-down coordinate space (Y = 0 at the top of the document).
    /// Measured from the live layout manager, so it is immune to line-height
    /// drift and soft-wrap folding that a `(line - 1) * lineHeight` estimate
    /// cannot see. Nil while the layout is not ready — callers fall back to the
    /// arithmetic estimate.
    var currentMatchCenterY: CGFloat? {
        guard !matches.isEmpty, currentIndex < matches.count,
              let tv = textView, let lm = tv.layoutManager,
              let tc = lm.textContainers.first else { return nil }
        let m = matches[currentIndex]
        let charIndex = min(m.range.location, tv.string.count)
        if lm.numberOfGlyphs == 0 { lm.ensureLayout(for: tc) }
        let glyphIndex = lm.glyphIndexForCharacter(at: charIndex)
        guard glyphIndex != NSNotFound, glyphIndex < lm.numberOfGlyphs else { return nil }
        let rect = lm.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        guard rect.height > 0 else { return nil }
        return rect.midY
    }

    /// Scans all matches and tracks 1-based line numbers in a single pass —
    /// O(document) total, never O(document × matches).
    private static func scan(_ string: NSString,
                             query: String,
                             options: NSString.CompareOptions) -> [QuickMatch] {
        var result: [QuickMatch] = []
        var searchRange = NSRange(location: 0, length: string.length)
        var line = 1
        var lastIndex = 0
        while true {
            let r = string.range(of: query, options: options, range: searchRange)
            if r.location == NSNotFound { break }
            while lastIndex < r.location {
                if string.character(at: lastIndex) == 0x0A { line += 1 }
                lastIndex += 1
            }
            result.append(QuickMatch(range: r, line: line))
            let nextLoc = r.location + r.length
            if nextLoc >= string.length { break }
            searchRange = NSRange(location: nextLoc, length: string.length - nextLoc)
        }
        return result
    }
}

// MARK: - Bar

/// Liquid-glass incremental search bar, centered near the editor bottom —
/// TextMate's Ctrl+S surface, re-woven in SwiftUI.
struct QuickSearchBar: View {
    @ObservedObject var model: QuickSearchModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .focused($focused)
                .onChange(of: model.query) { _, newValue in
                    model.setQuery(newValue)
                }
                .onSubmit { model.confirm() }

            if !model.matches.isEmpty {
                Text("\(model.currentIndex + 1)/\(model.matches.count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            Button(action: { model.previous() }) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(model.matches.isEmpty)

            Button(action: { model.next() }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(model.matches.isEmpty)

            Button(action: {
                model.ignoreCase.toggle()
                model.reSearch()
            }) {
                Text("Aa")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.ignoreCase ? .secondary : .primary)

            Button(action: { model.cancel() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .frame(width: 480)
        // Reveal / fold: the bar does not slide in from an edge, it *condenses*
        // out of blur — materializing where the eye already looks. The dock row
        // above animates the height; these three animate the substance.
        .blur(radius: model.isVisible ? 0 : 20)
        .opacity(model.isVisible ? 1 : 0)
        .scaleEffect(model.isVisible ? 1.0 : 1.4)
        // Negative feedback: a query that matches nothing shakes the bar. Driven
        // by the token, so consecutive misses each replay the same 3 half-cycles.
        .modifier(ShakeEffect(animatableData: CGFloat(model.notFoundToken)))
        .animation(.spring(response: 0.30, dampingFraction: 0.80), value: model.isVisible)
        .animation(.linear(duration: 0.40), value: model.notFoundToken)
        .onChange(of: model.isVisible) { _, visible in
            if visible {
                // Delay one runloop so the TextField is committed to the hierarchy
                // before SwiftUI tries to move first-responder to it.
                DispatchQueue.main.async { focused = true }
            } else if let tv = model.textView {
                tv.window?.makeFirstResponder(tv)
            }
        }
    }
}

// MARK: - Shake

/// Horizontal shake used as negative feedback when an incremental-search query
/// matches nothing. Driven by an integer token: each increment animates the
/// transform through `shakesPerUnit` half-cycles and settles back at zero.
struct ShakeEffect: GeometryEffect {
    var amount: CGFloat = 7
    var shakesPerUnit: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(
            CGAffineTransform(translationX: amount * sin(animatableData * .pi * shakesPerUnit), y: 0)
        )
    }
}