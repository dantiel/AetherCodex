import XCTest
@testable import AetherCodex

/// The broken invariant, pinned.
///
/// The unfolded Aegis mirror lives inside Pythia's bottom `safeAreaBar`, and a
/// `safeAreaBar` sizes itself to its content. Nothing inside the mirror caps its
/// own height — the detail is an unbounded `VStack` of orientation, course,
/// parameters and recalled notes. So the only defence against "unfold = the
/// chamber is gone" is the ceiling handed down from the pane's measured height.
/// These tests fix the shape of that ceiling, not its current value.
final class AegisLayoutTests: XCTestCase {

    private let panes: [CGFloat] = stride(from: 60, through: 3000, by: 20).map { $0 }

    /// The load-bearing rule: unfolding can never claim the majority of the
    /// chamber, so the message list and the input bar always survive.
    func testMirrorNeverClaimsHalfTheChamber() {
        for height in panes {
            let cap = AegisWidgetView.detailCap(forPaneHeight: height)
            XCTAssertLessThanOrEqual(
                cap, height * AegisWidgetView.detailMaxShare,
                "cap \(cap) exceeds half of a \(height)pt chamber"
            )
        }
    }

    /// A taller chamber may offer a taller mirror — never a shorter one. A
    /// non-monotone ceiling would make the mirror jump as the window resizes.
    func testCeilingIsMonotoneInThePane() {
        var previous: CGFloat = 0
        for height in panes {
            let cap = AegisWidgetView.detailCap(forPaneHeight: height)
            XCTAssertGreaterThanOrEqual(cap, previous, "ceiling fell at pane \(height)")
            previous = cap
        }
    }

    /// However tall the window grows, the mirror stays a mirror.
    func testCeilingIsAbsolutelyBounded() {
        for height in panes {
            XCTAssertLessThanOrEqual(
                AegisWidgetView.detailCap(forPaneHeight: height),
                AegisWidgetView.detailCeiling
            )
        }
    }

    /// Legibility sets the floor — but only while the floor fits the share.
    func testTypicalChamberUnfoldsToAReadableMirror() {
        let cap = AegisWidgetView.detailCap(forPaneHeight: 700)
        XCTAssertGreaterThanOrEqual(cap, AegisWidgetView.detailMinHeight)
        XCTAssertLessThan(cap, AegisWidgetView.detailCeiling)
    }

    /// Before the first geometry pass the pane is unmeasured; optimism there
    /// would overflow the user's window for one frame.
    func testUnmeasuredChamberStaysConservative() {
        XCTAssertEqual(
            AegisWidgetView.detailCap(forPaneHeight: 0),
            AegisWidgetView.detailMinHeight
        )
    }
}
