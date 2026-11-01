import XCTest
@testable import GlassIsland

/// The Obsidian-source picker: window-title parsing, vault registry
/// resolution and note lookup inside a vault tree.
final class ObsidianSupportTests: XCTestCase {
    func testParsesWindowTitle() {
        let source = ObsidianSupport.parseWindowTitle("任务收件箱 - MyVault - Obsidian")
        XCTAssertEqual(source?.noteName, "任务收件箱")
        XCTAssertEqual(source?.vaultName, "MyVault")
        // Notes whose own title contains " - " still parse correctly.
        let nested = ObsidianSupport.parseWindowTitle("项目 - 草稿 - MyVault - Obsidian")
        XCTAssertEqual(nested?.noteName, "项目 - 草稿")
        XCTAssertEqual(nested?.vaultName, "MyVault")
        XCTAssertNil(ObsidianSupport.parseWindowTitle("Obsidian"))
        XCTAssertNil(ObsidianSupport.parseWindowTitle("设置 - Obsidian"))
    }

    func testVaultRegistryParsing() {
        let json = #"{"vaults":{"a":{"path":"/Users/x/Notes/MyVault","ts":1},"b":{"path":"/tmp/Work Vault","ts":2}}}"#
        let paths = ObsidianSupport.vaultPaths(from: Data(json.utf8))
        XCTAssertEqual(paths["MyVault"], "/Users/x/Notes/MyVault")
        XCTAssertEqual(paths["Work Vault"], "/tmp/Work Vault")
        XCTAssertEqual(ObsidianSupport.vaultPaths(from: Data("{}".utf8)), [:])
    }

    func testResolvesNoteInsideVaultTree() throws {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObsidianSupportTests-\(UUID().uuidString)", isDirectory: true)
        let inbox = vault.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try Data("# x\n".utf8).write(to: vault.appendingPathComponent("其他.md"))
        try Data("- [ ] a\n".utf8).write(to: inbox.appendingPathComponent("任务收件箱.md"))
        defer { try? FileManager.default.removeItem(at: vault) }

        let resolved = ObsidianSupport.resolveNote(
            noteName: "任务收件箱",
            vaultName: "MyVault",
            vaults: ["MyVault": vault.path]
        )
        XCTAssertEqual(
            URL(fileURLWithPath: resolved?.path ?? "").resolvingSymlinksInPath().path,
            inbox.resolvingSymlinksInPath().appendingPathComponent("任务收件箱.md").path
        )
        XCTAssertEqual(resolved?.vaultPath, vault.path)
        // Unknown vault or missing note resolve to nothing.
        XCTAssertNil(ObsidianSupport.resolveNote(noteName: "任务收件箱", vaultName: "别的库", vaults: ["MyVault": vault.path]))
        XCTAssertNil(ObsidianSupport.resolveNote(noteName: "不存在", vaultName: "MyVault", vaults: ["MyVault": vault.path]))
    }
}

/// Folder sources: aggregate tasks from every Markdown file and write back
/// to the file each task came from.
final class FolderSourceTests: XCTestCase {
    private var dir: URL!
    private var store: TaskStore!
    private var configFile: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderSourceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Inbox", isDirectory: true), withIntermediateDirectories: true)
        try Data("# 今日\n\n- [ ] 甲任务\n".utf8).write(to: dir.appendingPathComponent("Tasks.md"))
        try Data("- [ ] 乙任务\n".utf8).write(to: dir.appendingPathComponent("Inbox/More.md"))
        try Data("不是笔记".writeData()).write(to: dir.appendingPathComponent("忽略.txt"))

        configFile = dir.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: configFile)
        let bridge = try MarkdownBridge()
        store = TaskStore(configProvider: { Config() }, bridge: bridge)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    func testAggregatesTasksFromAllMarkdownFiles() throws {
        let tasks = try store.loadTasks(sourcePath: dir.path, vault: "V", noteFile: "")
        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(
            URL(fileURLWithPath: tasks.first?.filePath ?? "").resolvingSymlinksInPath().path,
            dir.resolvingSymlinksInPath().appendingPathComponent("Inbox/More.md").path
        )
        XCTAssertEqual(
            URL(fileURLWithPath: tasks.last?.filePath ?? "").resolvingSymlinksInPath().path,
            dir.resolvingSymlinksInPath().appendingPathComponent("Tasks.md").path
        )
        // Ids are unique across files even with identical line numbers.
        XCTAssertNotEqual(tasks[0].id, tasks[1].id)
    }

    func testToggleWritesBackIntoTheRightFile() throws {
        let tasks = try store.loadTasks(sourcePath: dir.path, vault: "V", noteFile: "")
        let more = try XCTUnwrap(tasks.first { $0.filePath.hasSuffix("More.md") })
        let tasksFile = try XCTUnwrap(tasks.first { $0.filePath.hasSuffix("Tasks.md") })

        let result = try TaskWriter.toggle(sourcePath: more.filePath, line: more.line, lineNumber: more.lineNumber, done: true)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("Inbox/More.md")), Data("- [x] 乙任务\n".utf8))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("Tasks.md")), Data("# 今日\n\n- [ ] 甲任务\n".utf8))

        let undone = try TaskWriter.toggle(sourcePath: tasksFile.filePath, line: tasksFile.line, lineNumber: tasksFile.lineNumber, done: true)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("Tasks.md")), Data("# 今日\n\n- [x] 甲任务\n".utf8))
        _ = undone
        _ = result
    }

    func testHiddenFoldersAreSkipped() throws {
        let hidden = dir.appendingPathComponent(".obsidian", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data("- [ ] 不应出现\n".utf8).write(to: hidden.appendingPathComponent("workspace.md"))
        let tasks = try store.loadTasks(sourcePath: dir.path, vault: "V", noteFile: "")
        XCTAssertFalse(tasks.contains { $0.body.contains("不应出现") })
    }
}

private extension String {
    func writeData() -> Data { Data(utf8) }
}
