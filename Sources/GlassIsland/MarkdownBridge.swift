import Foundation
import JavaScriptCore

struct TaskItem: Identifiable, Equatable {
    let lineNumber: Int
    let line: String
    let body: String
    let html: String

    var id: String { "\(lineNumber)|\(line)" }
}

/// Runs the original project's markdown-it extraction (Resources/vendor/tasks.js)
/// inside JavaScriptCore so task extraction is byte-for-byte on par with the
/// Windows version, including wikilinks, `#todo` hiding and code fences.
/// Confine each instance to one queue: JSContext is not thread-safe.
final class MarkdownBridge {
    enum BridgeError: LocalizedError {
        case missingResource(String)
        case jsError(String)

        var errorDescription: String? {
            switch self {
            case .missingResource(let name): return "缺少内置资源：\(name)"
            case .jsError(let message): return message
            }
        }
    }

    private let context: JSContext
    private let extract: JSValue

    init() throws {
        guard let context = JSContext() else {
            throw BridgeError.jsError("无法初始化 JavaScriptCore。")
        }
        self.context = context
        guard let mdSource = Res.string("vendor/markdown-it.min.js") else {
            throw BridgeError.missingResource("vendor/markdown-it.min.js")
        }
        guard let tasksSource = Res.string("vendor/tasks.js") else {
            throw BridgeError.missingResource("vendor/tasks.js")
        }
        context.evaluateScript(mdSource)
        context.evaluateScript(tasksSource)
        context.evaluateScript(
            "function extractNoteTasks(source, vault, noteFile) {" +
            "  const md = createMarkdown(markdownit, vault, noteFile);" +
            "  return extractTasks(source, md);" +
            "}"
        )
        guard let extract = context.objectForKeyedSubscript("extractNoteTasks"), !extract.isUndefined else {
            throw BridgeError.jsError("提取脚本加载失败。")
        }
        self.extract = extract
    }

    func extractTasks(from source: String, vault: String, noteFile: String) throws -> [TaskItem] {
        context.exception = nil
        let result = extract.call(withArguments: [source, vault, noteFile])
        if let exception = context.exception {
            throw BridgeError.jsError(exception.toString())
        }
        guard let array = result?.toArray() as? [[String: Any]] else { return [] }
        return array.compactMap { dict in
            guard let lineNumber = dict["lineNumber"] as? Int,
                  let line = dict["line"] as? String,
                  let body = dict["body"] as? String,
                  let html = dict["html"] as? String else { return nil }
            return TaskItem(lineNumber: lineNumber, line: line, body: body, html: html)
        }
    }
}
