import XCTest
@testable import AetherCodex

final class FileLinkResolverTests: XCTestCase {
    private func link(_ s: String) -> FileLink? {
        FileLinkResolver.parse(URL(string: s)!)
    }

    func testCanonicalQuery() {
        let l = link("aethercodex://open?path=A/B.swift&line=482&column=10")
        XCTAssertEqual(l?.path, "A/B.swift")
        XCTAssertEqual(l?.line, 482)
        XCTAssertEqual(l?.column, 10)
    }

    func testFragmentWinsOverQuery() {
        let l = link("aethercodex://open?path=A/B.swift&line=20&column=3#L42C8")
        XCTAssertEqual(l?.path, "A/B.swift")
        XCTAssertEqual(l?.line, 42)
        XCTAssertEqual(l?.column, 8)
    }

    func testLineCarriesColonColumn() {
        let l = link("aethercodex://open?path=A/B.swift&line=482:10")
        XCTAssertEqual(l?.line, 482)
        XCTAssertEqual(l?.column, 10)
    }

    func testPathSuffix() {
        let l = link("aethercodex://open?path=A/B.swift:482:10")
        XCTAssertEqual(l?.path, "A/B.swift")
        XCTAssertEqual(l?.line, 482)
        XCTAssertEqual(l?.column, 10)
    }

    func testExplicitColumnWinsOverPathSuffix() {
        let l = link("aethercodex://open?path=foo.swift:10:5&column=9")
        XCTAssertEqual(l?.path, "foo.swift")
        XCTAssertEqual(l?.line, 10)
        XCTAssertEqual(l?.column, 9)
    }

    func testNonAethercodexURLYieldsNil() {
        XCTAssertNil(FileLinkResolver.parse(URL(string: "https://example.com/x")!))
    }
}
