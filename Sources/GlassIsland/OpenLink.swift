import AppKit

enum OpenLinkError: LocalizedError, Equatable {
    case invalidURL          // 此链接类型不受支持。
    case notObsidianNote     // 只支持打开 Obsidian 笔记。
    case foreignVault        // 此链接不属于当前笔记库。

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "此链接类型不受支持。"
        case .notObsidianNote: return "只支持打开 Obsidian 笔记。"
        case .foreignVault: return "此链接不属于当前笔记库。"
        }
    }
}

/// Port of the original Action.ps1 "open": only http(s) and obsidian links,
/// and obsidian links must point at the configured vault.
enum OpenLink {
    static func open(urlString: String, vault: String) throws {
        let url = try validate(urlString: urlString, vault: vault)
        NSWorkspace.shared.open(url)
    }

    /// Validation only (no side effects) — separately testable.
    static func validate(urlString: String, vault: String) throws -> URL {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased() else {
            throw OpenLinkError.invalidURL
        }
        guard scheme == "https" || scheme == "http" || scheme == "obsidian" else {
            throw OpenLinkError.invalidURL
        }
        if scheme == "obsidian" {
            guard url.host == "open" else { throw OpenLinkError.notObsidianNote }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            var query: [String: String] = [:]
            for item in items where query[item.name] == nil {
                query[item.name] = item.value ?? ""
            }
            let file = query["file"] ?? ""
            let extraKeys = query.keys.contains { $0 != "vault" && $0 != "file" }
            guard query["vault"] == vault, !file.isEmpty, !extraKeys else {
                throw OpenLinkError.foreignVault
            }
        }
        return url
    }

    static func noteURL(vault: String, noteFile: String) -> String {
        "obsidian://open?vault=\(urlEncode(vault))&file=\(urlEncode(noteFile))"
    }

    private static func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
