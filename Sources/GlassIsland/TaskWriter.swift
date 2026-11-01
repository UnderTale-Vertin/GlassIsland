import Foundation

enum WriteBackError: LocalizedError, Equatable {
    case noteMissing        // 找不到任务收件箱。
    case invalidLineNumber  // 任务行号无效。
    case notUTF8            // 文件不是有效的 UTF-8。
    case notATask           // 这行不是可勾选的任务。
    case stateChanged       // 任务状态已经改变，请刷新后重试。
    case ambiguous          // 任务已被编辑或存在同名任务，未作修改。请刷新后重试。

    var errorDescription: String? {
        switch self {
        case .noteMissing: return "找不到任务收件箱。"
        case .invalidLineNumber: return "任务行号无效。"
        case .notUTF8: return "文件不是有效的 UTF-8，未作修改。"
        case .notATask: return "这行不是可勾选的任务。"
        case .stateChanged: return "任务状态已经改变，请刷新后重试。"
        case .ambiguous: return "任务已被编辑或存在同名任务，未作修改。请刷新后重试。"
        }
    }
}

struct ToggleResult: Equatable {
    let filePath: String
    let line: String
    let lineNumber: Int
}

/// Port of the original Action.ps1 "toggle": flips exactly one byte of the
/// checkbox in place (seek + write), preserving BOM, line endings and every
/// other byte of the file. Guards mirror the original so an edited or
/// ambiguous note is never written.
enum TaskWriter {
    static func toggle(sourcePath: String, line: String, lineNumber: Int, done: Bool) throws -> ToggleResult {
        guard !line.isEmpty else { throw WriteBackError.notATask }
        guard lineNumber >= 0 else { throw WriteBackError.invalidLineNumber }
        guard FileManager.default.fileExists(atPath: sourcePath),
              let handle = FileHandle(forUpdatingAtPath: sourcePath) else {
            throw WriteBackError.noteMissing
        }
        defer { try? handle.close() }
        let data = handle.readDataToEndOfFile()
        guard String(data: data, encoding: .utf8) != nil else { throw WriteBackError.notUTF8 }

        // Split lines while tracking byte offsets, exactly like Action.ps1:
        // the BOM is skipped, lines end at \n, and a trailing \r is excluded
        // from the text but stays inside the scanned span.
        let bytes = [UInt8](data)
        var start = 0
        if bytes.count >= 3, bytes[0] == 239, bytes[1] == 187, bytes[2] == 191 { start = 3 }
        var lines: [(offset: Int, text: String)] = []
        var lineStart = start
        var i = start
        while i <= bytes.count {
            if i == bytes.count || bytes[i] == 10 {
                var end = i
                if end > lineStart && bytes[end - 1] == 13 { end -= 1 }
                let text = String(decoding: bytes[lineStart..<end], as: UTF8.self)
                lines.append((offset: lineStart, text: text))
                lineStart = i + 1
            }
            if i >= bytes.count { break }
            i += 1
        }

        // Same checkbox pattern as the original.
        let pattern = "^(\\s*(?:[-*+]|\\d+[.)])\\s+\\[)([ xX])(\\])(?:[ \\t]+|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { throw WriteBackError.notATask }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              match.range(at: 2).location != NSNotFound,
              let prefixRange = Range(match.range(at: 1), in: line),
              let stateRange = Range(match.range(at: 2), in: line) else {
            throw WriteBackError.notATask
        }
        let stateChar = line[stateRange]
        if done && stateChar != " " { throw WriteBackError.stateChanged }
        if !done && stateChar != "x" && stateChar != "X" { throw WriteBackError.stateChanged }

        // Resolve the line: prefer the recorded index, fall back to a unique
        // identical line elsewhere in the file; ambiguity never writes.
        var index = lineNumber
        if index >= lines.count || lines[index].text != line {
            let candidates = lines.indices.filter { lines[$0].text == line }
            guard candidates.count == 1 else { throw WriteBackError.ambiguous }
            index = candidates[0]
        }

        // The prefix is pure ASCII (whitespace, list marker, "["), so the
        // character count equals the byte count.
        let prefix = String(line[prefixRange])
        let offset = lines[index].offset + prefix.utf8.count
        let newByte: UInt8 = done ? UInt8(ascii: "x") : UInt8(ascii: " ")
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: Data([newByte]))
        try handle.synchronize()

        let newLine = line.replacingCharacters(in: stateRange, with: done ? "x" : " ")
        return ToggleResult(filePath: sourcePath, line: newLine, lineNumber: index)
    }
}
