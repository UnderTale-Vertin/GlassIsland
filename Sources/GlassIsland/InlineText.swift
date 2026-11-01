import AppKit

/// Renders the small inline-HTML subset markdown-it emits into an
/// NSAttributedString for AppKit text views. Same parser as before, AppKit
/// attributes instead of SwiftUI.
enum InlineHTML {
    private struct Style {
        var bold = false
        var italic = false
        var code = false
        var strike = false
        var link: String?
    }

    static func nsAttributed(_ html: String, ink: NSColor, blue: NSColor, baseSize: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var stack: [Style] = [Style()]

        func append(_ raw: String) {
            guard !raw.isEmpty else { return }
            let style = stack.last ?? Style()
            var font = NSFont.systemFont(ofSize: baseSize)
            if style.bold { font = NSFont.boldSystemFont(ofSize: baseSize) }
            if style.italic {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            if style.code {
                font = NSFont.monospacedSystemFont(ofSize: baseSize * 0.87, weight: .regular)
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 6
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .paragraphStyle: paragraph,
            ]
            if let link = style.link, let url = URL(string: decodeEntities(link)) {
                attributes[.foregroundColor] = blue
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.link] = url
            } else {
                attributes[.foregroundColor] = ink
            }
            if style.code {
                attributes[.backgroundColor] = NSColor.white.withAlphaComponent(0.09)
            }
            if style.strike {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            out.append(NSAttributedString(string: decodeEntities(raw), attributes: attributes))
        }

        var cursor = html.startIndex
        while let lt = html[cursor...].firstIndex(of: "<") {
            if lt > cursor {
                append(String(html[cursor..<lt]))
            }
            let after = html.index(after: lt)
            let end = html[after...].firstIndex(of: ">") ?? html.endIndex
            let tag = String(html[after..<end]).trimmingCharacters(in: .whitespaces)
            let name = tag.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? tag
            let closing = name.hasPrefix("/")
            let base = name.dropFirst(closing ? 1 : 0).lowercased()

            switch base {
            case "br":
                append("\n")
            case "a", "strong", "b", "em", "i", "code", "s", "del", "strike":
                if closing {
                    if stack.count > 1 { stack.removeLast() }
                } else {
                    var style = stack.last ?? Style()
                    switch base {
                    case "a": style.link = href(in: tag)
                    case "strong", "b": style.bold = true
                    case "em", "i": style.italic = true
                    case "code": style.code = true
                    default: style.strike = true
                    }
                    stack.append(style)
                }
            default:
                break
            }
            cursor = end == html.endIndex ? html.endIndex : html.index(after: end)
        }
        if cursor < html.endIndex {
            append(String(html[cursor...]))
        }
        return out
    }

    private static func href(in tag: String) -> String? {
        guard let range = tag.range(of: "href\\s*=\\s*\"([^\"]*)\"", options: .regularExpression) else { return nil }
        let inner = tag[range]
        guard let valueStart = inner.firstIndex(of: "\""),
              let valueEnd = inner.lastIndex(of: "\""),
              valueStart < valueEnd else { return nil }
        return String(inner[inner.index(after: valueStart)..<valueEnd])
    }

    /// Decodes the HTML entities markdown-it escapes (and numeric ones).
    /// `&amp;` resolves last so double escapes resolve in one pass.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var scanner = Substring(text)
        while let amp = scanner.firstIndex(of: "&") {
            result += String(scanner[scanner.startIndex..<amp])
            let rest = scanner[amp...]
            if let semi = rest.firstIndex(of: ";"), amp < semi {
                let entity = String(rest[rest.startIndex..<rest.index(after: semi)])
                if let decoded = namedEntity(entity) {
                    result += decoded
                    scanner = rest[rest.index(after: semi)...]
                    continue
                }
                if entity.hasPrefix("&#"), let value = numericValue(of: entity),
                   let scalar = Unicode.Scalar(value), !CharacterSet.newlines.contains(scalar) {
                    result += String(Character(scalar))
                    scanner = rest[rest.index(after: semi)...]
                    continue
                }
            }
            result += "&"
            scanner = rest[rest.index(after: amp)...]
        }
        result += String(scanner)
        return result
    }

    private static func namedEntity(_ entity: String) -> String? {
        switch entity {
        case "&lt;": return "<"
        case "&gt;": return ">"
        case "&quot;": return "\""
        case "&apos;": return "'"
        case "&#39;", "&#x27;": return "'"
        case "&nbsp;": return "\u{00A0}"
        case "&amp;": return "&"
        default: return nil
        }
    }

    private static func numericValue(of entity: String) -> UInt32? {
        guard entity.hasPrefix("&#"), entity.hasSuffix(";") else { return nil }
        let body = entity.dropFirst(2).dropLast()
        if body.hasPrefix("x") || body.hasPrefix("X") {
            return UInt32(body.dropFirst(), radix: 16)
        }
        return UInt32(body, radix: 10)
    }
}
