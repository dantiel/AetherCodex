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
                    ForEach(Array(bridge.daemonLog.enumerated()), id: \.offset) { _, line in
                        Text(highlightCode(line, language: ""))
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