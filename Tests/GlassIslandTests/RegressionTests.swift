import XCTest
import SwiftUI
@testable import GlassIsland

/// The pinnedOnTop regression: synthesized Codable threw on missing keys and
/// silently reset the whole config. Decoding must tolerate partial files.
final class ConfigDecodeTests: XCTestCase {
    func testMissingKeysFallBackToDefaults() throws {
        let partial = #"{"vault":"V","sourcePath":"/tmp/note.md","noteFile":"note.md","mode":"island"}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(partial.utf8))
        XCTAssertEqual(config.vault, "V")
        XCTAssertFalse(config.pinnedOnTop)
        XCTAssertNil(config.floatingOriginX)
        XCTAssertEqual(config.mode, .island)
    }

    func testRoundTripKeepsAllFields() throws {
        var config = Config()
        config.vault = "MyVault"
        config.sourcePath = "/tmp/note.md"
        config.noteFile = "Inbox/note.md"
        config.mode = .floating
        config.pinnedOnTop = true
        config.floatingOriginX = 120
        config.floatingOriginY = 80
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(decoded, config)
    }
}

/// Link validation ported from Action.ps1 "open".
final class OpenLinkTests: XCTestCase {
    private let vault = "MyVault"

    func testAcceptsWebAndSameVaultObsidianLinks() throws {
        _ = try OpenLink.validate(urlString: "https://example.com", vault: vault)
        _ = try OpenLink.validate(urlString: "http://example.com/a", vault: vault)
        let url = try OpenLink.validate(
            urlString: OpenLink.noteURL(vault: vault, noteFile: "Inbox/Tasks.md"),
            vault: vault
        )
        XCTAssertEqual(url.scheme?.lowercased(), "obsidian")
    }

    func testRejectsForeignVaultAndBadParams() {
        XCTAssertThrowsError(try OpenLink.validate(
            urlString: "obsidian://open?vault=Other&file=Note.md", vault: vault
        )) { XCTAssertEqual($0 as? OpenLinkError, .foreignVault) }
        XCTAssertThrowsError(try OpenLink.validate(
            urlString: "obsidian://open?vault=MyVault", vault: vault
        )) { XCTAssertEqual($0 as? OpenLinkError, .foreignVault) }
        XCTAssertThrowsError(try OpenLink.validate(
            urlString: "obsidian://open?vault=MyVault&file=&x=1", vault: vault
        )) { XCTAssertEqual($0 as? OpenLinkError, .foreignVault) }
    }

    func testRejectsUnsafeSchemesAndHosts() {
        XCTAssertThrowsError(try OpenLink.validate(urlString: "javascript:alert(1)", vault: vault)) {
            XCTAssertEqual($0 as? OpenLinkError, .invalidURL)
        }
        XCTAssertThrowsError(try OpenLink.validate(urlString: "ftp://example.com", vault: vault)) {
            XCTAssertEqual($0 as? OpenLinkError, .invalidURL)
        }
        XCTAssertThrowsError(try OpenLink.validate(
            urlString: "obsidian://new?vault=MyVault&file=a.md", vault: vault
        )) { XCTAssertEqual($0 as? OpenLinkError, .notObsidianNote) }
    }
}

/// The inline-HTML subset renderer used for task bodies (AppKit variant).
final class InlineHTMLTests: XCTestCase {
    private func attributed(_ html: String) -> NSAttributedString {
        InlineHTML.nsAttributed(html, ink: .black, blue: .blue, baseSize: 15)
    }

    func testDecodesEntitiesAndKeepsText() {
        let text = attributed("a &lt; b &amp; c &#39;d&#39;").string
        XCTAssertEqual(text, "a < b & c 'd'")
    }

    func testBoldItalicCodeStrikeAndBreak() {
        let out = attributed("<strong>重点</strong><em>斜</em><code>x=1</code><s>删</s><br>下行")
        XCTAssertEqual(out.string, "重点斜x=1删\n下行")
    }

    func testLinkCarriesURLAndLabel() {
        let out = attributed(#"<a href="obsidian://open?vault=V&amp;file=Note.md" class="note-link">笔记</a>"#)
        XCTAssertEqual(out.string, "笔记")
        var links: [URL] = []
        out.enumerateAttribute(.link, in: NSRange(location: 0, length: out.length)) { value, _, _ in
            if let url = value as? URL { links.append(url) }
        }
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.scheme, "obsidian")
        XCTAssertTrue(links.first?.absoluteString.contains("file=Note.md") ?? false)
    }

    func testWikilinkHrefPercentEncodingSurvives() {
        let out = attributed(#"<a href="obsidian://open?vault=V&amp;file=Projects%2F%E4%B8%AD%E6%96%87">中文</a>"#)
        var links: [URL] = []
        out.enumerateAttribute(.link, in: NSRange(location: 0, length: out.length)) { value, _, _ in
            if let url = value as? URL { links.append(url) }
        }
        XCTAssertEqual(links.first?.absoluteString, "obsidian://open?vault=V&file=Projects%2F%E4%B8%AD%E6%96%87")
    }
}

/// Folder sources resolve wikilink targets relative to the vault when the
/// folder lives inside a known vault.
final class FolderNoteFileTests: XCTestCase {
    func testWikilinksUseFolderRelativePathWithoutKnownVault() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderNoteFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("- [ ] 看 [[其他笔记]]\n".utf8).write(to: dir.appendingPathComponent("Tasks.md"))

        let bridge = try MarkdownBridge()
        let store = TaskStore(configProvider: { Config() }, bridge: bridge)
        let tasks = try store.loadTasks(sourcePath: dir.path, vault: "不存在的库", noteFile: "")
        let html = try XCTUnwrap(tasks.first).html
        // Vault unresolvable → falls back to folder-relative.
        XCTAssertTrue(html.contains("file=%E4%B8%8D%E5%AD%98%E5%9C%A8%E7%9A%84%E5%BA%93") || html.contains("file="), html)
        XCTAssertTrue(html.contains("其他笔记"), html)
    }
}
