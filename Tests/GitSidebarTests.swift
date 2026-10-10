import XCTest
@testable import AetherCodex

final class GitSidebarTests: XCTestCase {
    func testPorcelainNamesAndRename() {
        let changes = GitChange.parse(" M file with spaces.swift\0R  renamed.swift\0original.swift\0?? odd\nname.txt\0UU conflict.txt\0")
        XCTAssertEqual(changes.count, 4)
        XCTAssertEqual(changes[0].path, "file with spaces.swift")
        XCTAssertEqual(changes[1].paths, ["renamed.swift", "original.swift"])
        XCTAssertTrue(changes[1].staged)
        XCTAssertTrue(changes[2].pending)
        XCTAssertTrue(changes[3].conflict)
    }

    func testReadAndStageInIsolatedRepository() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aether-git-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try GitCommand.run(root, ["init", "-q"])
        let name = "a file [literal].txt"
        try Data("hello\n".utf8).write(to: root.appendingPathComponent(name))
        let before = GitChange.parse(try GitCommand.run(root, ["status", "--porcelain=v1", "-z"]))
        XCTAssertEqual(before.first?.path, name)
        _ = try GitCommand.run(root, ["add", "--", name])
        let after = GitChange.parse(try GitCommand.run(root, ["status", "--porcelain=v1", "-z"]))
        XCTAssertEqual(after.first?.index, "A")
        let diff = try GitCommand.run(root, ["diff", "--cached", "--no-ext-diff", "--no-textconv"])
        XCTAssertTrue(diff.contains("+hello"))
        _ = try GitCommand.run(root, ["rm", "--cached", "--", name])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
    }
}
