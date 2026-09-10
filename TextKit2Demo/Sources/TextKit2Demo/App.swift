import SwiftUI
import AppKit

final class DemoAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bare-executable launches (nohup … &) inherit a .prohibited activation
        // policy, leaving the window rendered but unable to take key/front.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct TextKit2DemoApp: App {
    @NSApplicationDelegateAdaptor(DemoAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 700, minHeight: 500)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
    }
}

struct ContentView: View {
    private let attributedString: NSAttributedString = DemoHighlighter.highlight(DemoContent.text)
    private let documentSize: CGSize

    init() {
        documentSize = TextKit2Layout.measure(attributedString, containerWidth: 0)
    }

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            TextKit2EditorRepresentable(attributedString: attributedString)
                .frame(width: max(documentSize.width, 1), height: max(documentSize.height, 1))
                .background(Color.clear)
        }
        .scrollEdgeEffectStyle(.soft, for: [.top, .leading, .trailing])
        .ignoresSafeArea(.container, edges: [.top, .leading, .trailing])
        .safeAreaBar(edge: .top, spacing: 0) {
            TopBar()
        }
        .safeAreaBar(edge: .leading, spacing: 0) {
            EdgeBar(label: "SIDEBAR")
        }
        .safeAreaBar(edge: .trailing, spacing: 0) {
            EdgeBar(label: "PYTHIA")
        }
    }
}

struct TopBar: View {
    var body: some View {
        HStack(spacing: 8) {
            Button(action: {}) {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.borderless)

            Spacer()

            Text("TextKit2Demo")
                .font(.headline)

            Spacer()

            Color.clear.frame(width: 24, height: 1)
        }
        .padding(.leading, 76)
        .padding(.trailing, 12)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
    }
}

/// Transparent edge bar content. No material/color/gradient — the native
/// scroll-edge fade is the only thing that should be visible here.
struct EdgeBar: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(90))
            .frame(width: 28)
            .frame(maxHeight: .infinity)
    }
}