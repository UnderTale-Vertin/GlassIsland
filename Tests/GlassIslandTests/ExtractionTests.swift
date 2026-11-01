import XCTest
@testable import GlassIsland

/// Ports of the original tests/tasks.test.mjs cases, driven through the same
/// markdown-it + tasks.js logic the app uses (via JavaScriptCore).
/// The transport-hex case is Windows-specific and intentionally not ported.
final class ExtractionTests: XCTestCase {
    private var bridge: MarkdownBridge!

    override func setUpWithError() throws {
        bridge = try MarkdownBridge()
    }

    private func extract(_ source: String) throws -> [TaskItem] {
        try bridge.extractTasks(from: source, vault: "FixtureVault", noteFile: "Inbox/任务收件箱.md")
    }

    private func renderInline(_ body: String) throws -> String {
        let items = try extract("- [ ] \(body)")
        return try XCTUnwrap(items.first).html
    }

    func testRendersEmphasisCodeWikiAliasesAndSafeLinks() throws {
        let html = try renderInline("**重点** `#todo` [[Projects/中文|笔记]] [网页](https://example.com) #todo")
        XCTAssertTrue(html.contains("<strong>重点</strong>"), html)
        XCTAssertTrue(html.contains("<code>#todo</code>"), html)
        XCTAssertTrue(html.range(of: "obsidian://open\\?vault=FixtureVault&amp;file=Projects%2F", options: .regularExpression) != nil, html)
        XCTAssertTrue(html.contains(">笔记</a>"), html)
        XCTAssertTrue(html.contains("href=\"https://example.com\""), html)
        // The `#todo` inside the inline code survives; the bare tag is hidden.
        XCTAssertEqual(html.components(separatedBy: "#todo").count - 1, 1, html)
    }

    func testRejectsHTMLExecutableProtocolsAndExternalImages() throws {
        let html = try renderInline("<img src=x onerror=alert(1)> [bad](javascript:alert(1)) ![说明](https://external.test/x.png)")
        XCTAssertNil(html.range(of: "<img|href=\"javascript:|onerror=\"|<script", options: .regularExpression), html)
        XCTAssertTrue(html.contains("&lt;img"), html)
        XCTAssertTrue(html.contains("说明"), html)
    }

    func testPreservesPhysicalLinesAndIgnoresCompletedTasksAndFencedExamples() throws {
        let text = "\u{FEFF}# 收件箱\r\n\r\n- [ ] **中文** #todo\r\n  换行描述\r\n- [x] 完成\r\n```md\r\n- [ ] 假任务\r\n```\r\n- 项目\r\n  - [ ] 子任务\r\n"
        let tasks = try extract(text)
        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(tasks[0].lineNumber, 2)
        XCTAssertEqual(tasks[0].line, "- [ ] **中文** #todo")
        XCTAssertTrue(tasks[0].html.range(of: "<br>\n换行描述", options: .regularExpression) != nil, tasks[0].html)
        XCTAssertEqual(tasks[1].lineNumber, 9)
    }

    func testWikiLabelsAreEscapedAndCodeDoesNotBecomeALink() throws {
        let html = try renderInline("`[[note]]` [[note|<img src=x>]]")
        XCTAssertFalse(html.contains("<img"), html)
        let code = try renderInline("`[[note]]`")
        XCTAssertTrue(code.contains("<code>[[note]]</code>"), code)
        let heading = try renderInline("[[#段落|这里]]")
        XCTAssertTrue(heading.contains("file=Inbox%2F"), heading)
    }

    func testRelativeMarkdownLinksOpenInObsidian() throws {
        let html = try renderInline("[笔记](next.md) [#todo](https://example.com)")
        XCTAssertTrue(html.contains("file=Inbox%2Fnext.md"), html)
        XCTAssertTrue(html.contains(">#todo</a>"), html)
    }
}
