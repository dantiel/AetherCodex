import SwiftUI
import AegisProtocol

/// One facet of the Ægis — a kind of light the shield can reflect. The grant
/// state is a live reading (screen, hand) or a persisted memory (voice, archive).
struct AegisFacetModel: Identifiable {
    let id: AegisFacet
    let glyph: String
    let name: String
    let light: String          // the kind of light this facet reflects
    let blurb: String          // what the oracle may do when the light reflects

    static let all: [AegisFacetModel] = [
        AegisFacetModel(
            id: .screenRecording, glyph: "👁", name: "Screen Recording",
            light: "the light of what is seen",
            blurb: "The oracle may behold the screen and bear it into memory."
        ),
        AegisFacetModel(
            id: .accessibility, glyph: "✋", name: "Accessibility",
            light: "the light of the hand",
            blurb: "The oracle may move the cursor, click, and type on your behalf."
        ),
        AegisFacetModel(
            id: .appleEvents, glyph: "🗣", name: "Automation",
            light: "the light of the voice",
            blurb: "The oracle may speak to other apps and command them."
        ),
        AegisFacetModel(
            id: .fullDiskAccess, glyph: "📜", name: "Full Disk Access",
            light: "the light of the archive",
            blurb: "The oracle may read and write every file of the work."
        ),
        AegisFacetModel(
            id: .notifications, glyph: "🔔", name: "Notifications",
            light: "the light of the announcement",
            blurb: "The oracle may ring the bell when it pauses to consult you."
        ),
    ]
}