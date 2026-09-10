import Foundation

/// Rewrites a chat reply into text a voice can read aloud.
///
/// Markdown structure, links, code and pictographs are removed or replaced with short Japanese, symbols a
/// voice would spell out get their spoken form, and compatibility characters are normalized. Only the
/// spoken copy changes; the reply shown on screen stays as received.
public enum SpeechText {
    public static let unreadableNotice = "返信の本文は画面で確認してください。"
    public static let codeNotice = "コードは省略します。"
    public static let linkWord = "リンク"
    public static let emailWord = "メールアドレス"

    public static func forSpeech(_ text: String) -> String {
        let source = text.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines: [String] = []
        var fence: String?
        for raw in source.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let marker = fenceMarker(line) {
                if let open = fence {
                    if marker.first == open.first, marker.count >= open.count {
                        fence = nil
                        lines.append(codeNotice)
                    }
                } else {
                    fence = marker
                }
                continue
            }
            if fence != nil { continue }
            lines.append(contentsOf: blockLines(line))
        }
        if fence != nil { lines.append(codeNotice) }
        let spoken = lines.map(inlineSpeech).filter { !$0.isEmpty }
        return spoken.isEmpty ? unreadableNotice : spoken.joined(separator: "\n")
    }

    static func fenceMarker(_ line: String) -> String? {
        guard let match = line.firstMatch(of: #/^(`{3,}|~{3,})/#) else { return nil }
        return String(match.output.1)
    }

    /// Block-level Markdown: rules, tables, quotes, headings and list markers.
    static func blockLines(_ line: String) -> [String] {
        if line.contains(#/^([-*_])(\s*\1){2,}$/#) { return [] }
        let pipes = line.filter { $0 == "|" }.count
        if pipes >= 2, line.hasPrefix("|") || line.hasSuffix("|") || line.contains(" | ") {
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if cells.allSatisfy({ $0.contains(#/^:?-+:?$/#) }) { return [] }
            return [cells.joined(separator: "、")]
        }
        var text = Substring(line)
        while text.hasPrefix(">") {
            text = text.dropFirst().drop { $0 == " " || $0 == "\t" }
        }
        var result = String(text)
        result = result.replacing(#/^#{1,6}\s+/#, with: "").replacing(#/\s+#+$/#, with: "")
        result = result.replacing(#/^[-*+]\s+/#, with: "").replacing(#/^[・•●◦▪‣]\s*/#, with: "")
        result = result.replacing(#/^(\d{1,3})[.)]\s+/#) { "\($0.output.1)、" }
        result = result.replacing(#/^\[[ xX]\]\s*/#, with: "")
        return [result]
    }

    /// Inline Markdown, links, HTML, spoken forms of symbols, and pictographs.
    static func inlineSpeech(_ line: String) -> String {
        var text = line
        text = text.replacing(#/!\[([^\]]*)\]\([^)]*\)/#) { String($0.output.1) }
        text = text.replacing(#/\[([^\]]+)\]\([^)]*\)/#) { String($0.output.1) }
        text = text.replacing(#/\[([^\]]+)\]\[[^\]]*\]/#) { String($0.output.1) }
        text = text.replacing(#/<(https?://[^>\s]+)>/#) { String($0.output.1) }
        text = text.replacing(#/<\/?[A-Za-z][^>]*>/#, with: "")
        for (entity, value) in [("&nbsp;", " "), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        // URL characters only: Japanese text often follows a link without a space.
        text = text.replacing(#/https?:\/\/[A-Za-z0-9\-._~:\/?#@!$&'*+,;=%]+/#, with: linkWord)
        text = text.replacing(#/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/#, with: emailWord)
        text = text.replacing(#/`+([^`]+)`+/#) { String($0.output.1) }
        text = text.replacing(#/\*\*(.+?)\*\*/#) { String($0.output.1) }
        text = text.replacing(#/__(.+?)__/#) { String($0.output.1) }
        text = text.replacing(#/~~(.+?)~~/#) { String($0.output.1) }
        // Emphasis hugs its text; "2 * 3" keeps its spaced operator.
        text = text.replacing(#/\*([^*\s](?:[^*]*?[^*\s])?)\*/#) { String($0.output.1) }
        text = text.replacing(#/(^|[\s(（「])_([^_\s][^_]*?)_(?=$|[\s、。,.!?！？)）」])/#) { "\($0.output.1)\($0.output.2)" }
        text = text.replacing(#/(\d)\s*[~〜]\s*(?=\d)/#) { "\($0.output.1)から" }
        for (symbol, spoken) in [("°C", "度"), ("%", "パーセント"), ("&", "アンド"), ("→", "、"), ("⇒", "、"), ("➡", "、"), ("⇨", "、"), ("※", "")] {
            text = text.replacingOccurrences(of: symbol, with: spoken)
        }
        text = String(String.UnicodeScalarView(text.unicodeScalars.filter { !isPictograph($0) }))
        return text.replacing(#/[ \t\u{3000}]+/#, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isPictograph(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if [0x200B, 0x200C, 0x200D, 0x20E3, 0xFE0E, 0xFE0F, 0xFEFF].contains(value) { return true }
        let properties = scalar.properties
        if properties.isEmojiModifier || properties.isEmojiPresentation { return true }
        return properties.isEmoji && (value >= 0x1F000 || (0x2600...0x27BF).contains(value))
    }
}
