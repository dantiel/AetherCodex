import XCTest
@testable import AetherCodex

/// Port-verification tests mirroring TextMate 2's `Frameworks/text/tests/t_ranker.cc`.
final class GoToFileRankerTests: XCTestCase {

    func testNormalizeFilter() {
        XCTAssertEqual(TextMateRanker.normalizeFilter("t d l"), "tdl")
        XCTAssertEqual(TextMateRanker.normalizeFilter("td l"), "tdl")
        XCTAssertEqual(TextMateRanker.normalizeFilter("TDL"), "tdl")
        XCTAssertEqual(TextMateRanker.normalizeFilter("TD L"), "tdl")
        XCTAssertEqual(TextMateRanker.normalizeFilter("TD l"), "tdl")
    }

    func testCapitalCoverage() {
        XCTAssertLessThan(
            TextMateRanker.rank("otv", "OTVStatusBar.mm").score,
            TextMateRanker.rank("otv", "OakTextView.mm").score
        )
    }

    func testDistanceToStart() {
        XCTAssertLessThan(
            TextMateRanker.rank("doc", "OakDocument.mm").score,
            TextMateRanker.rank("doc", "document.cc").score
        )
    }

    func testSubstring() {
        XCTAssertLessThan(
            TextMateRanker.rank("paste", "Encrypt With Password … Text").score,
            TextMateRanker.rank("paste", "Paste Selection Online … TextMate").score
        )
    }

    func testFullmatch() {
        XCTAssertLessThan(
            TextMateRanker.rank("rmate", "RMateServer.cc").score,
            TextMateRanker.rank("rmate", "rmate").score
        )
    }

    func testRanker() {
        let files = ["OakTabBarView.mm", "OakTabBarView.h", "OakTextView.mm", "OakTextView.h"]
        let matched = files.filter { TextMateRanker.rank("otbv", $0).score > 0 }
        XCTAssertEqual(matched.count, 2)
    }

    func testRankerPreference() {
        XCTAssertLessThan(
            TextMateRanker.rank("oakfilechooser", "OakFinderLabelChooser").score,
            TextMateRanker.rank("oakfilechooser", "OakFileChooser").score
        )
    }

    func testHighlightRange() {
        let result = TextMateRanker.rank("HTo", "HTMLOutput.h")
        XCTAssertGreaterThan(result.score, 0.0)
        XCTAssertLessThan(result.score, 1.0)
        XCTAssertEqual(result.ranges.count, 2)
        XCTAssertEqual(result.ranges[0], 0..<2)
        XCTAssertEqual(result.ranges[1], 4..<5)
    }

    func testFilenameMatchBeatsPathMatch() {
        // A filename match always ranks ahead of a directory-only match
        // because of the +1 bonus in GoToFileEngine.match.
        let root = URL(fileURLWithPath: "/tmp")
        let nameFile = IndexedFile(url: URL(fileURLWithPath: "/tmp/FooBar.swift"), fileName: "FooBar.swift", directory: "", relativePath: "FooBar.swift")
        let pathFile = IndexedFile(url: URL(fileURLWithPath: "/tmp/foobar/Baz.swift"), fileName: "Baz.swift", directory: "foobar", relativePath: "foobar/Baz.swift")

        let nameMatch = GoToFileEngine.match(nameFile, filter: "fb", currentURL: nil)
        let pathMatch = GoToFileEngine.match(pathFile, filter: "fb", currentURL: nil)

        XCTAssertNotNil(nameMatch)
        XCTAssertNotNil(pathMatch)
        XCTAssertLessThan(nameMatch!.rank, pathMatch!.rank)
    }
}
