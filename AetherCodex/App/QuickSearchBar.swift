import SwiftUI
import AppKit

// MARK: - Match

/// One incremental-search hit. `range` is UTF-16 within the live editor string,
/// `line` is 1-based (drives the gutter highlight + scroll reveal).
struct QuickMatch: Equatable {
    let range: NSRange
    let line: Int
}

/// Where the current hit actually sits, in the adopted text view's coordinate
/// space (origin top-leading, `textContainerOrigin` and inset included).
struct QuickMatchHighlight: Equatable {
    let rect: CGRect
    let line: Int
}

extension NSTextView {
    /// Where `range` actually sits, in this text view's coordinate space.
    /// Forces layout for the hit alone: a range outside the laid-out window
    /// otherwise answers with a rect from whatever happened to be measured,
    /// which is what makes a reveal land at a near-random offset. Shared by
    /// incremental search and find/replace so no reveal can drift from its hit.
    func matchHighlight(for range: NSRange, line: Int) -> QuickMatchHighlight? {
        guard let lm = layoutManager, let tc = lm.textContainers.first,
              range.location != NSNotFound,
              NSMaxRange(range) <= string.count else { return nil }
        lm.ensureLayout(forCharacterRange: range)
        let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        guard rect.height > 0 else { return nil }
        // Text-container space + origin (leading padding, container inset) lands
        // in text-view space — the space the SwiftUI overlay draws in.
        return QuickMatchHighlight(
            rect: rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y),
            line: line
        )
    }
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

    /// Geometry of the current hit, measured once per jump. The surface hangs
    /// both the reveal anchor and the attention halo off this single rect, so a
    /// jump can never scroll to one place and glow at another. Never computed in
    /// a view body: the layout query is the expensive part.
    @Published private(set) var highlight: QuickMatchHighlight? = nil

    /// The only reveal signal: a monotonic jump token. The surface scrolls to
    /// `highlight` on each bump, so two consecutive hits on one line still
    /// replay. No measured rect means no jump — never a line-number estimate.
    @Published var revealToken: Int = 0

    /// True while the search TextField owns focus. Drives Ctrl+S re-focus: when
    /// the bar is open but the editor (or chrome) regained the responder, Ctrl+S
    /// yanks focus back into the field instead of advancing to the next match.
    @Published var isFieldFocused = false
    /// Bumped to pull focus into the search field (Ctrl+S while the bar is open
    /// but unfocused). A token so repeated re-focus requests replay cleanly.
    @Published var refocusToken = 0

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

    /// True while the editor's own text view owns the responder chain — the user
    /// clicked back into the code. `@FocusState` is unreliable across the
    /// AppKit/SwiftUI boundary (a click into the NSTextView does not always flip
    /// the SwiftUI field's focus state), so Ctrl+S reads the AppKit truth here.
    var editorHasFocus: Bool {
        guard let tv = textView, let window = tv.window else { return false }
        return window.firstResponder === tv
    }

    /// Ctrl+S: open the bar; when already open, navigate next — unless the
    /// editor regained focus (user clicked the code), in which case Ctrl+S yanks
    /// focus back into the search field first.
    func toggle() {
        if isVisible {
            editorHasFocus ? refocus() : next()
        } else {
            show()
        }
    }

    /// Yank focus back into the search field without touching the current match.
    func refocus() {
        guard isVisible else { return }
        refocusToken += 1
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
        highlight = nil
        isFieldFocused = false
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
            highlight = nil
            return
        }
        let string = tv.string as NSString
        guard !query.isEmpty, string.length > 0 else {
            matches = []
            currentIndex = 0
            highlight = nil
            return
        }

        var opts: NSString.CompareOptions = [.literal]
        if ignoreCase { opts.insert(.caseInsensitive) }
        matches = Self.scan(string, query: query, options: opts)

        guard !matches.isEmpty else {
            currentIndex = 0
            highlight = nil
            notFoundToken += 1
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
            highlight = tv.matchHighlight(for: m.range, line: m.line)
        } else {
            highlight = nil
        }
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
        // The surface owns the scroll now: a `scrollRangeToVisible` here would
        // race the animated centring and land somewhere between the two.
        highlight = textView?.matchHighlight(for: ordered[0].range, line: ordered[0].line)
        revealToken += 1
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

// MARK: - Attention halo

/// The halo around the current incremental-search hit.
///
/// Deliberately stronger than the native selection: a tinted plate, a rim and a
/// glow the system selection cannot produce, plus a one-shot ripple. The caller
/// hands it `.id(revealToken)`, so every jump remounts the view and the ripple
/// replays — the eye is pulled to the new hit instead of hunting for it.
struct QuickSearchMatchHighlight: View {
    let rect: CGRect
    var tint: Color = .accentColor

    @State private var ripple: CGFloat = 0
    @State private var settle: CGFloat = 0

    var body: some View {
        let plate = RoundedRectangle(cornerRadius: 3, style: .continuous)

        plate
            .fill(tint.opacity(0.32))
            .overlay(plate.strokeBorder(tint, lineWidth: 1.5))
            .shadow(color: tint.opacity(0.9), radius: 6)
            .overlay {
                plate.strokeBorder(tint, lineWidth: 2)
                    .scaleEffect(1 + 0.6 * ripple, anchor: .center)
                    .opacity(0.95 * (1 - ripple))
            }
            .frame(width: max(rect.width, 2), height: max(rect.height, 2))
            // Attention: the plate zooms *into* its exact size and place on every
            // jump — a spring from slightly enlarged to exact — so the eye is led
            // to the new hit rather than left to hunt for it.
            .scaleEffect(1 + 0.3 * (1 - settle), anchor: .center)
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
            .onAppear {
                ripple = 0
                settle = 0
                withAnimation(.easeOut(duration: 0.55)) { ripple = 1 }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { settle = 1 }
            }
    }
}

// MARK: - Bar

/// Incremental-search bar — a floating glass pill that hovers above the status
/// strip (TextMate's Ctrl+S surface, re-woven in SwiftUI). It dissolves in and
/// out with a scale + fade rather than reading as a full-width chrome band.
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Floating pill: its own glass, rounded corners, and a soft shadow — the
        // bar hovers above the status strip instead of continuing its chrome.
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.14), radius: 4, y: 1)
        .blur(radius: model.isVisible ? 0 : 8)
        .opacity(model.isVisible ? 1 : 0)
        .scaleEffect(model.isVisible ? 1 : 0.92, anchor: .bottom)
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
        .onChange(of: focused) { _, nowFocused in
            model.isFieldFocused = nowFocused
        }
        .onChange(of: model.refocusToken) { _, _ in
            // Ctrl+S arrived while the bar was open but the editor/chrome owned
            // the responder chain — pull focus back into the field.
            DispatchQueue.main.async { focused = true }
        }
    }
}

// MARK: - Floating dock

/// The floating quick-search pill. It hovers over the code column — an overlay
/// on the editor surface, never a reserved band — so the scroll view keeps its
/// full height and the text travels beneath the pill's glass and the bottom
/// edge blur. It stays mounted for the life of a code tab so the reveal can
/// play in *and* out; folded, it takes no clicks.
struct QuickSearchDock: View {
    @ObservedObject var model: QuickSearchModel

    var body: some View {
        QuickSearchBar(model: model)
            .frame(width: EditorChromeMetrics.quickSearchBarWidth,
                   height: EditorChromeMetrics.quickSearchBarHeight)
            .padding(.bottom, EditorChromeMetrics.quickSearchBarLift)
            .frame(maxWidth: .infinity)
            .allowsHitTesting(model.isVisible)
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