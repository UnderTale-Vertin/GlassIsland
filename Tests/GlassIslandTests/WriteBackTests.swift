import XCTest
@testable import GlassIsland

/// TaskWriter semantics ported from the original Action.ps1 toggle contract:
/// exactly one byte flips in place; BOM, line endings and every other byte
/// survive; edited or ambiguous notes are never written.
final class WriteBackTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassIslandTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func noteURL(_ name: String = "note.md") -> URL {
        dir.appendingPathComponent(name)
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func testToggleFlipsExactlyOneByte() throws {
        let url = noteURL()
        try write("- [ ] 甲\n- [ ] 乙\n", to: url)
        let result = try TaskWriter.toggle(sourcePath: url.path, line: "- [ ] 甲", lineNumber: 0, done: true)
        XCTAssertEqual(result, ToggleResult(filePath: url.path, line: "- [x] 甲", lineNumber: 0))
        XCTAssertEqual(try read(url), Data("- [x] 甲\n- [ ] 乙\n".utf8))
    }

    func testUndoRestoresOriginalBytes() throws {
        let url = noteURL()
        let original = "- [ ] a\n- [ ] b\n"
        try write(original, to: url)
        let done = try TaskWriter.toggle(sourcePath: url.path, line: "- [ ] a", lineNumber: 0, done: true)
        _ = try TaskWriter.toggle(sourcePath: url.path, line: done.line, lineNumber: done.lineNumber, done: false)
        XCTAssertEqual(try read(url), Data(original.utf8))
    }

    func testRecoversWhenLinesDriftAbove() throws {
        let url = noteURL()
        try write("- [ ] a\n- [ ] b\n", to: url)
        let done = try TaskWriter.toggle(sourcePath: url.path, line: "- [ ] b", lineNumber: 1, done: true)
        XCTAssertEqual(done.lineNumber, 1)
        // The note is edited above: a heading shifts the recorded line number.
        try write("# 新标题\n- [ ] a\n- [x] b\n", to: url)
        // Undo uses the stale lineNumber 1 but the recorded line content is unique.
        let undone = try TaskWriter.toggle(sourcePath: url.path, line: done.line, lineNumber: 1, done: false)
        XCTAssertEqual(undone.lineNumber, 2)
        XCTAssertEqual(try read(url), Data("# 新标题\n- [ ] a\n- [ ] b\n".utf8))
    }

    func testDuplicateLinesRefuseToWrite() throws {
        let url = noteURL()
        let original = "- [ ] same\n- [ ] same\n"
        try write(original, to: url)
        XCTAssertThrowsError(try TaskWriter.toggle(sourcePath: url.path, line: "- [x] same", lineNumber: 9, done: false)) { error in
            XCTAssertEqual(error as? WriteBackError, .ambiguous)
        }
        XCTAssertEqual(try read(url), Data(original.utf8))
    }

    func testChangedLineRefusesToWrite() throws {
        let url = noteURL()
        let original = "- [ ] a\n- [ ] b\n"
        try write(original, to: url)
        // The line content changed on disk; neither index nor content match.
        XCTAssertThrowsError(try TaskWriter.toggle(sourcePath: url.path, line: "- [ ] 旧内容", lineNumber: 0, done: true)) { error in
            XCTAssertEqual(error as? WriteBackError, .ambiguous)
        }
        XCTAssertEqual(try read(url), Data(original.utf8))
    }

    func testStateMismatchRefusesToWrite() throws {
        let url = noteURL()
        try write("- [x] done\n", to: url)
        // Completing an already-completed task is rejected.
        XCTAssertThrowsError(try TaskWriter.toggle(sourcePath: url.path, line: "- [x] done", lineNumber: 0, done: true)) { error in
            XCTAssertEqual(error as? WriteBackError, .stateChanged)
        }
        XCTAssertEqual(try read(url), Data("- [x] done\n".utf8))
        // Unchecking a not-yet-completed task is rejected.
        try write("- [ ] pending\n", to: url)
        XCTAssertThrowsError(try TaskWriter.toggle(sourcePath: url.path, line: "- [ ] pending", lineNumber: 0, done: false)) { error in
            XCTAssertEqual(error as? WriteBackError, .stateChanged)
        }
        XCTAssertEqual(try read(url), Data("- [ ] pending\n".utf8))
    }

    func testNonTaskLineRefusesToWrite() throws {
        let url = noteURL()
        try write("- 普通列表项\n", to: url)
        XCTAssertThrowsError(try TaskWriter.toggle(sourcePath: url.path, line: "- 普通列表项", lineNumber: 0, done: true)) { error in
            XCTAssertEqual(error as? WriteBackError, .notATask)
        }
    }

    func testBOMAndCRLFSurvive() throws {
        let url = noteURL()
        try write("\u{FEFF}# 收件箱\r\n\r\n- [ ] **中文** #todo\r\n", to: url)
        let result = try TaskWriter.toggle(sourcePath: url.path, line: "- [ ] **中文** #todo", lineNumber: 2, done: true)
        XCTAssertEqual(result.line, "- [x] **中文** #todo")
        XCTAssertEqual(try read(url), Data("\u{FEFF}# 收件箱\r\n\r\n- [x] **中文** #todo\r\n".utf8))
    }

    func testMarkedTaskAcceptsUppercaseXOnUndo() throws {
        let url = noteURL()
        try write("- [X] 大写\n", to: url)
        let result = try TaskWriter.toggle(sourcePath: url.path, line: "- [X] 大写", lineNumber: 0, done: false)
        XCTAssertEqual(try read(url), Data("- [ ] 大写\n".utf8))
        _ = result
    }

    func testMissingNoteThrows() {
        XCTAssertThrowsError(try TaskWriter.toggle(sourcePath: dir.appendingPathComponent("不存在.md").path, line: "- [ ] a", lineNumber: 0, done: true)) { error in
            XCTAssertEqual(error as? WriteBackError, .noteMissing)
        }
    }
}
