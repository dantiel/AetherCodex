import SwiftUI

@main
struct ScrollEdgeSwiftUIApp: App {
    @State private var searchText = ""
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 600, minHeight: 400)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
    }
}

struct ContentView: View {
    @State private var text: String = {
        (1...200).map { "Line \($0): The quick brown fox jumps over the lazy dog. ◼︎" }.joined(separator: "\n")
    }()
    
    var body: some View {
        ScrollView {
            TextEditor(text: .constant(text))
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: CGFloat(text.split(separator: "\n").count) * 22)
                .scrollDisabled(true)
                .background(.windowBackground)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .ignoresSafeArea(.container, edges: .top)
        .safeAreaBar(edge: .top, spacing: 0) {
            HStack {
                Button(action: {}) {
                    Image(systemName: "sidebar.left")
                }
                Spacer()
                Text("ScrollEdgeSwiftUIDemo")
                    .font(.headline)
            }
            .padding(.horizontal)
            .frame(height: 44)
        }
    }
}