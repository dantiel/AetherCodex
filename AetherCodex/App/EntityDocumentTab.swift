import SwiftUI

// MARK: - Entity document tab

/// The kind of entity a tab can host — a Magnum Opus task or a Salomo Rex seal.
enum EntityTabKind: Equatable {
    case opusTask(Int)   // Magnum Opus task id
    case seal(Int)       // Salomo Rex seal id

    var glyph: String {
        switch self {
        case .opusTask: return "⚗️"
        case .seal: return "👑"
        }
    }
}

/// An entity (task or seal) opened as a first-class tab in the main editor area.
/// Unlike a file tab it owns no `EditorViewController`; its surface is a SwiftUI
/// view that reuses the same detail components as the sidebar overviews, so the
/// entity is *not* stored twice — one view, two hosting locations.
final class EntityDocumentTab: Identifiable, ObservableObject {
    let id = UUID()
    let kind: EntityTabKind
    @Published var title: String

    init(kind: EntityTabKind, title: String) {
        self.kind = kind
        self.title = title
    }
}

/// Payload posted as `.openEntityInTab` when a sidebar overview asks the window
/// to open an entity as a tab.
struct EntityTabRequest {
    let kind: EntityTabKind
    let title: String
}

extension Notification.Name {
    static let openEntityInTab = Notification.Name("openEntityInTab")
}

// MARK: - Entity tab surface

/// Renders the content of an entity tab by reusing the existing detail panels,
/// focused on the single entity. The full panel (header + picker) stays intact so
/// the tab remains a working surface — one may switch tasks/seals without leaving.
struct EntityTabSurface: View {
    @ObservedObject var tab: EntityDocumentTab

    var body: some View {
        switch tab.kind {
        case .opusTask(let id):
            // A task tab shows *only* that task — not the full sidebar panel with
            // its header + task strip. More tasks in the editor → the sidebar.
            MagnumOpusTaskView(taskId: id)
        case .seal(let id):
            SiegelPanel(initialSealId: id)
        }
    }
}