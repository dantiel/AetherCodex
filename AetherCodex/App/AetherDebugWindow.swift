import AppKit
import SwiftUI

// MARK: - Æther-Debug-Fenster (ZIEL B)
//
// A small non-activating utility panel that mirrors the Ruby daemon's stderr
// (`RubyBridge.daemonLog`) live. It never steals editor focus — clicks in the
// main window keep flowing — and offers daemon-admin controls (restart, clear,
// copy, auto-scroll) as liquid-glass glyph buttons.
//
// The daemon-stderr drain (`daemonLog` + `startErrorReader`) is NOT duplicated
// here; this window only consumes what RubyBridge already publishes.

final class AetherDebugWindowController: NSWindowController, NSWindowDelegate {

    static let shared = AetherDebugWindowController()

    private var panel: NSPanel?

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 480),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Æther Debug"
        // The native titlebar dissolves: the Æther Debug header (green lamp)
        // replaces it as the window's identity — content extends to the top edge.
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = NSHostingView(rootView: AetherDebugView())
        panel.center()
        self.panel = panel
        super.init(window: panel)
        // Delegate wiring must happen after super.init — referencing the
        // singleton inside its own initializer would recurse forever.
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Show or hide the panel. `orderOut` (instead of close) keeps the
    /// controller's state warm for an instant re-show.
    func toggle() {
        guard let panel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    /// Closing hides instead of destroying the panel — the window is a
    /// familiar, not a visitor.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

// MARK: - Debug view

private struct AetherDebugView: View {
    @ObservedObject private var bridge = RubyBridge.shared
    @State private var autoScroll = true
    @State private var isNearBottom = true
    @State private var sentinelMinY: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    /// Tags unchecked in the filter menu — lines carrying any of these (or a
    /// descendant tag) are folded out of the live log.
    @State private var hiddenTags: Set<String> = []

    /// How far below the viewport fold the live edge may drift before the
    /// reader owns the scroll position and the jump-to-bottom arrow appears.
    private let proximityThreshold: CGFloat = 48

    var body: some View {
        logList
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            .ignoresSafeArea(.container, edges: [.top, .bottom])
            .safeAreaBar(edge: .top, spacing: 0) {
                header
            }
            .background(glassBackground)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Æther Debug")
                    .font(.system(size: 12, weight: .semibold))
                statusDot
                Spacer(minLength: 0)
                filterMenuButton
                controlButton(systemName: "arrow.clockwise", help: "Restart daemon") {
                    restartDaemon()
                }
                controlButton(systemName: "trash", help: "Clear log") {
                    bridge.clearDaemonLog()
                }
                controlButton(systemName: "doc.on.doc", help: "Copy log") {
                    copyLog()
                }
                controlButton(
                    systemName: autoScroll ? "lock.fill" : "lock.open",
                    help: autoScroll ? "Auto-scroll locked to bottom" : "Auto-scroll unlocked"
                ) {
                    autoScroll.toggle()
                }
                .foregroundStyle(autoScroll ? .white : .secondary)
            }
            // Clear the floating traffic-light close button (fullSizeContentView
            // dissolves the titlebar, so the light parks over the header).
            .padding(.leading, 58)
            .padding(.trailing, 12)
            .padding(.vertical, 8)
            Divider().opacity(0.4)
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(bridge.isRunning ? Color.green : Color.orange)
            .frame(width: 7, height: 7)
            .shadow(color: (bridge.isRunning ? Color.green : Color.orange).opacity(0.55), radius: 3)
            .help(bridge.isRunning ? "Daemon running" : "Daemon stopped")
    }

    private func controlButton(systemName: String, help: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .help(help)
    }

    // MARK: - Log list

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if bridge.daemonLog.isEmpty {
                        Text("— the æther is silent —")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.top, 30)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(visibleEntries) { entry in
                        Text(highlightLogLine(entry.line))
                            .font(.system(size: 10.5, design: .monospaced))
                            .lineSpacing(1.5)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("debugBottom")
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: DebugSentinelKey.self,
                                    value: geo.frame(in: .named("debugScroll")).minY
                                )
                            }
                        )
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .coordinateSpace(name: "debugScroll")
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: DebugViewportKey.self, value: geo.size.height)
                }
            )
            .onPreferenceChange(DebugSentinelKey.self) { minY in
                sentinelMinY = minY
                updateProximity()
            }
            .onPreferenceChange(DebugViewportKey.self) { h in
                viewportHeight = h
                updateProximity()
            }
            .onChange(of: bridge.daemonLog) { _, _ in
                // Follow the live edge only while the reader is parked near
                // the bottom — same position-aware contract as MessageList.
                guard autoScroll, isNearBottom else { return }
                proxy.scrollTo("debugBottom", anchor: .bottom)
            }
            .onAppear {
                proxy.scrollTo("debugBottom", anchor: .bottom)
            }
            .overlay(alignment: .bottomTrailing) {
                if !isNearBottom {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("debugBottom", anchor: .bottom)
                        }
                        isNearBottom = true
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 26, height: 26)
                            .contentShape(Circle())
                            .glassEffect(.regular.interactive(), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .padding(.trailing, 12)
                    .padding(.bottom, 10)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isNearBottom)
        }
    }

    /// Glass depth: the desktop breathes through the panel, tinted by the
    /// active theme's editor background (chrome.theme.sidebarMaterial spirit).
    private var glassBackground: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Rectangle()
                .fill(Color(nsColor: ThemeRegistry.shared.current.editorBackground).opacity(0.45))
        }
        .ignoresSafeArea()
    }

    private func updateProximity() {
        let near = sentinelMinY <= viewportHeight + proximityThreshold
        if isNearBottom != near {
            isNearBottom = near
        }
    }

    // MARK: - Daemon admin

    private func restartDaemon() {
        Task {
            do {
                try await RubyBridge.shared.restart()
            } catch {
                NSLog("[AetherDebug] daemon restart failed: \(error)")
            }
        }
    }

    private func copyLog() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(bridge.daemonLog.joined(separator: "\n"), forType: .string)
    }

    // MARK: - Tagged log: filter + highlighting

    /// A filter funnel that folds whole instrument families out of the log —
    /// one checkbox per tag, hierarchical (a parent's toggle also toggles its
    /// descendants). Each tag wears its own deterministic hue.
    private var filterMenuButton: some View {
        Menu {
            if hiddenTags.isEmpty {
                Text("All tags visible").foregroundStyle(.secondary)
            } else {
                Button {
                    hiddenTags.removeAll()
                } label: {
                    Label("Show all (\(hiddenTags.count) hidden)", systemImage: "eye")
                }
            }
            Divider()
            ForEach(flattenedTagTree) { item in
                Toggle(isOn: binding(for: item.name)) {
                    Label {
                        Text(String(repeating: "    ", count: item.depth) + item.name)
                    } icon: {
                        Circle()
                            .fill(tagColor(item.name))
                            .frame(width: 8, height: 8)
                    }
                }
            }
        } label: {
            Image(systemName: hiddenTags.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .foregroundStyle(hiddenTags.isEmpty ? .white : Color.yellow)
        .help(hiddenTags.isEmpty ? "Filter log by tag" : "\(hiddenTags.count) tag(s) hidden")
    }

    /// Live entries after tag filtering — the newest line stays at the bottom,
    /// untouched by the fold (the present instrument is always expanded).
    private var visibleEntries: [DebugLogEntry] {
        bridge.daemonLog.enumerated().compactMap { pair -> DebugLogEntry? in
            let line = DebugLogLine.parse(pair.element)
            let hidden = line.tags.contains { hiddenTags.contains($0) }
            return hidden ? nil : DebugLogEntry(index: pair.offset, line: line)
        }
    }

    /// Tag forest built from co-occurrence nesting: `[A][B][C]` makes B a child
    /// of A and C a child of B, merged across every line in the log.
    private var tagTree: [TagNode] {
        var childrenMap: [String: [String]] = [:]
        var order: [String] = []
        var seen: Set<String> = []
        for raw in bridge.daemonLog {
            let tags = DebugLogLine.parse(raw).tags
            for (i, tag) in tags.enumerated() {
                if !seen.contains(tag) { seen.insert(tag); order.append(tag) }
                if i > 0 {
                    let parent = tags[i - 1]
                    if childrenMap[parent] == nil { childrenMap[parent] = [] }
                    if !childrenMap[parent]!.contains(tag) { childrenMap[parent]!.append(tag) }
                }
            }
        }
        var hasParent: Set<String> = []
        for (_, kids) in childrenMap { for k in kids { hasParent.insert(k) } }
        func build(_ name: String) -> TagNode {
            TagNode(name: name, children: (childrenMap[name] ?? []).map(build))
        }
        return order.filter { !hasParent.contains($0) }.map(build)
    }

    /// Depth-first flatten of the forest, carrying each tag's nesting depth for
    /// indented checkboxes.
    private var flattenedTagTree: [TagMenuEntry] {
        var out: [TagMenuEntry] = []
        func walk(_ node: TagNode, _ depth: Int) {
            out.append(TagMenuEntry(name: node.name, depth: depth))
            for child in node.children { walk(child, depth + 1) }
        }
        for root in tagTree { walk(root, 0) }
        return out
    }

    private var tagNodeMap: [String: TagNode] {
        var map: [String: TagNode] = [:]
        func walk(_ node: TagNode) {
            map[node.name] = node
            node.children.forEach(walk)
        }
        tagTree.forEach(walk)
        return map
    }

    private func descendants(of tag: String) -> Set<String> {
        var result: Set<String> = [tag]
        func walk(_ name: String) {
            guard let node = tagNodeMap[name] else { return }
            for child in node.children {
                result.insert(child.name)
                walk(child.name)
            }
        }
        walk(tag)
        return result
    }

    private func toggleTag(_ tag: String, on: Bool) {
        let affected = descendants(of: tag)
        if on { hiddenTags.subtract(affected) } else { hiddenTags.formUnion(affected) }
    }

    private func binding(for tag: String) -> Binding<Bool> {
        Binding(
            get: { !hiddenTags.contains(tag) },
            set: { toggleTag(tag, on: $0) }
        )
    }

    /// Render one log line with its leading `[TAG]` tokens colored by their
    /// deterministic hue, then light token highlighting over the message body.
    private func highlightLogLine(_ line: DebugLogLine) -> AttributedString {
        let theme = ThemeRegistry.shared.current
        let palette = theme.pythia
        let bodyColor = palette.codeForeground
        let mono = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        let tagFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold)

        let result = NSMutableAttributedString()
        for tag in line.tags {
            result.append(NSAttributedString(
                string: "[\(tag)]",
                attributes: [.font: tagFont, .foregroundColor: tagNSColor(tag)]
            ))
        }
        if !line.separator.isEmpty {
            result.append(NSAttributedString(
                string: line.separator,
                attributes: [.font: mono, .foregroundColor: bodyColor.withAlphaComponent(0.55)]
            ))
        }
        let body = NSMutableAttributedString(
            string: line.body,
            attributes: [.font: mono, .foregroundColor: bodyColor]
        )
        applyLogBodyHighlighting(body, body: line.body)
        result.append(body)
        return AttributedString(result)
    }

    private func applyLogBodyHighlighting(_ attr: NSMutableAttributedString, body: String) {
        let theme = ThemeRegistry.shared.current
        let palette = theme.pythia
        let stringColor = theme.style(for: .string).foreground ?? palette.complementary
        let numberColor = theme.style(for: .number).foreground ?? palette.complementary
        let constColor = theme.style(for: .constant).foreground ?? palette.accent
        let warnColor = theme.style(for: .invalid).foreground ?? NSColor.systemRed
        let ns = body as NSString
        func paint(_ pattern: String, _ color: NSColor, options: NSRegularExpression.Options = []) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            for m in re.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
                attr.addAttribute(.foregroundColor, value: color, range: m.range)
            }
        }
        paint("\"[^\"]*\"|'[^']*'", stringColor)
        paint("\\b\\d+(?:\\.\\d+)?\\b", numberColor)
        paint("\\b(?:true|false|nil|null|undefined|NaN)\\b", constColor, options: .caseInsensitive)
        paint("\\b(?:error|failed|failure|exception|fatal|abort|crash|panic)\\b", warnColor, options: .caseInsensitive)
        paint("/[A-Za-z0-9_./-]{2,}", palette.shine)
    }

    /// Deterministic per-tag hue — stable across launches and theme switches.
    private func tagNSColor(_ tag: String) -> NSColor {
        let appearance = ThemeRegistry.shared.current.appearance
        var hash: UInt64 = 5381
        for byte in tag.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        // Top bits spread more uniformly than low bits across short ASCII tags.
        let hue = CGFloat((hash >> 8) % 1000) / 1000.0
        let saturation: CGFloat = 0.62
        let brightness: CGFloat = appearance == .dark ? 0.90 : 0.46
        return NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
    }

    private func tagColor(_ tag: String) -> Color { Color(nsColor: tagNSColor(tag)) }
}

// MARK: - Tagged-log model

/// One parsed daemon log line: leading `[TAG]` tokens, the separator between
/// them and the message (`: `, ` `, or empty), and the raw body.
private struct DebugLogLine {
    let tags: [String]
    let separator: String
    let body: String

    static func parse(_ raw: String) -> DebugLogLine {
        var tags: [String] = []
        var idx = raw.startIndex
        while idx < raw.endIndex, raw[idx] == "[" {
            guard let close = raw[idx...].firstIndex(of: "]"),
                  close > raw.index(after: idx) else { break }
            tags.append(String(raw[raw.index(after: idx)..<close]))
            idx = raw.index(after: close)
        }
        var separator = ""
        if idx < raw.endIndex, raw[idx] == ":" {
            separator = ":"
            idx = raw.index(after: idx)
            if idx < raw.endIndex, raw[idx] == " " {
                separator += " "
                idx = raw.index(after: idx)
            }
        } else if idx < raw.endIndex, raw[idx] == " " {
            separator = " "
            idx = raw.index(after: idx)
        }
        return DebugLogLine(tags: tags, separator: separator, body: String(raw[idx...]))
    }
}

private struct DebugLogEntry: Identifiable {
    let index: Int
    let line: DebugLogLine
    var id: Int { index }
}

private struct TagNode {
    let name: String
    var children: [TagNode]
}

private struct TagMenuEntry: Identifiable {
    let name: String
    let depth: Int
    var id: String { name }
}

// MARK: - Scroll sentinel preference keys
// (PythiaPanel's keys are file-private; the debug window carries its own pair.)

private struct DebugSentinelKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct DebugViewportKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}