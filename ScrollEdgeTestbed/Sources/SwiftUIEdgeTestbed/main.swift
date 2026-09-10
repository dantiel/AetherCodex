// ── SwiftUIEdgeTestbed ──────────────────────────────────────────────
// Pure-SwiftUI mirror of the Landmarks detail-view pattern:
//   ScrollView + .toolbar + .ignoresSafeArea(edges: .top)
// Title KEPT (user directive: don't hide it until the blur works).
// Blue content, white monospaced text, 300 rows, scrolled to row 60 so
// text genuinely passes beneath the unified toolbar.
import SwiftUI

@main
struct SwiftUIEdgeTestbedApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 560, minHeight: 700)
        }
    }
}

struct ContentView: View {
    @State private var position: Int? = 60

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(1...300, id: \.self) { i in
                    Text("LINE \(i)    THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG")
                        .font(.system(size: 18, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 3)
                        .id(i)
                }
            }
            .background(Color.blue)
        }
        .scrollPosition(id: $position)
        .toolbar {
            ToolbarItem {
                Label("Editor", systemImage: "curlybraces")
            }
        }
        .ignoresSafeArea(edges: .top)
        .navigationTitle("ScrollEdge SwiftUI Test")
    }
}
