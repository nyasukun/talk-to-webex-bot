import Foundation

public enum MessageTemplate {
    public static let englishSpeechInstructions = """
    Your replies will be read aloud by a speech model. Reply in English using short sentences, one sentence per line.
    Express symbols, formatting, and numbers in natural spoken English so their meaning is clear when read aloud.
    """

    public static func defaultValue(for language: AppLanguage) -> String {
        guard language == .english else { return defaultValue }
        return """
        {{#screen}}The attachment is a screenshot of the user's current window.
        Here is the OCR text from the screenshot:
        ```
        {{ocr}}
        ```

        {{/screen}}The user's spoken request is:
        ```
        {{transcript}}
        ```

        Follow the user's spoken instructions using the context above. Respond as if you are having a conversation with the user.
        \(englishSpeechInstructions)
        """
    }

    public static func defaultReplyValue(for language: AppLanguage) -> String {
        guard language == .english else { return defaultReplyValue }
        return """
        This is the user's follow-up to the previous bot reply in the same thread.
        The user's spoken reply is:
        ```
        {{transcript}}
        ```

        Continue the previous topic using the conversation context and this reply. Address any additions, corrections, or further instructions conversationally.
        \(englishSpeechInstructions)
        """
    }

    public static let numberInstructions = "二桁以上の数字は、桁を一つずつ読ませず、意味に合った読みをひらがなで表現してください。全角数字も同様です。例：13時・１３時は「じゅうさんじ」、25分は「にじゅうごふん」、100は「ひゃく」と記載してください。"
    public static let speechInstructions = """
    あなたの返信は音声生成モデルで読み上げられます。日本語で返答を生成し、英語はその読みをカタカナで記載ください。また、短い一文として、改行して返信してください。
    記号や装飾も、読み上げて意味が伝わる日本語に言い換えてください。
    """
    public static let defaultValue = """
    {{#screen}}添付は現在ユーザが表示しているスクリーンショットです。
    このスクリーンショットのOCR文字列です:
    ```
    {{ocr}}
    ```

    {{/screen}}ユーザの音声発話です：
    ```
    {{transcript}}
    ```

    以上のコンテキストから、ユーザ音声発話の指示に従ってください。返答はユーザと会話しているように返答してください。
    \(speechInstructions)
    \(numberInstructions)
    """
    public static let defaultReplyValue = """
    これは同じスレッド内での、直前のボット回答に対するユーザからの追加返信です。
    ユーザの音声による返信です：
    ```
    {{transcript}}
    ```

    以上の会話のコンテキストとユーザ返信を踏まえ、直前の話題を引き継いで、補足・修正・追加の指示に対応してください。ユーザと会話しているように返答してください。
    \(speechInstructions)
    \(numberInstructions)
    """
    // Render tokens once: user text containing token syntax never becomes template code.
    public static func render(_ template: String, transcript: String, ocr: String?, screen: Bool) throws -> String {
        guard template.contains("{{transcript}}") else {
            throw RelayError.message(L10n.text("テンプレートに {{transcript}} が必要です。"))
        }
        var output = "", rest = template[...], inScreen = false, renderedTranscript = false
        while !rest.isEmpty {
            guard let open = rest.range(of: "{{") else {
                if !inScreen || screen { output += rest }
                break
            }
            if !inScreen || screen { output += rest[..<open.lowerBound] }
            guard let close = rest[open.upperBound...].range(of: "}}") else {
                throw RelayError.message(L10n.text("テンプレートの括弧が閉じていません。"))
            }
            let token = String(rest[open.upperBound..<close.lowerBound])
            switch token {
            case "#screen":
                guard !inScreen else { throw RelayError.message(L10n.text("screen条件は入れ子にできません。")) }
                inScreen = true
            case "/screen":
                guard inScreen else { throw RelayError.message(L10n.text("screen条件の開始がありません。")) }
                inScreen = false
            case "transcript":
                if !inScreen || screen {
                    output += transcript
                    renderedTranscript = true
                }
            case "ocr": if screen { output += ocr ?? "" }
            default: throw RelayError.message(L10n.text("未対応のテンプレート変数です: \(token)"))
            }
            rest = rest[close.upperBound...]
        }
        guard !inScreen else { throw RelayError.message(L10n.text("screen条件が閉じていません。")) }
        guard renderedTranscript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RelayError.message(L10n.text("送信する音声文字起こしが空です。"))
        }
        guard output.utf8.count <= 7000 else {
            throw RelayError.message(L10n.text("メッセージが長すぎます（上限7,000 UTF-8バイト）。発話・OCR・テンプレートを短くしてください。送信はしていません。"))
        }
        return output
    }
}

public enum WakeMatcher {
    public static func overlaps(_ left: String, _ right: String) -> Bool {
        let a = left.split(separator: "\n").map { canonical($0.map(normalized).joined()) }
        let b = right.split(separator: "\n").map { canonical($0.map(normalized).joined()) }
        return a.contains { x in b.contains { y in x.hasPrefix(y) || y.hasPrefix(x) } }
    }
    static func normalized(_ character: Character) -> String {
        String(character).precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars.compactMap { scalar -> String? in
            if CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols).contains(scalar) { return nil }
            if (0x30A1...0x30F6).contains(scalar.value), let kana = UnicodeScalar(scalar.value - 0x60) { return String(kana) }
            return String(scalar)
        }.joined()
    }
    public static func command(in text: String, phrases: String) -> String? {
        let normalizedText = canonical(text.map(normalized).joined())
        for phrase in phrases.split(separator: "\n") {
            let key = canonical(phrase.map(normalized).joined())
            guard key.count >= 4, normalizedText.hasPrefix(key) else { continue }
            var prefix = "", boundary = text.startIndex
            for index in text.indices {
                prefix += normalized(text[index])
                boundary = text.index(after: index)
                if canonical(prefix).count >= key.count { break }
            }
            return String(text[boundary...]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        }
        return nil
    }
    private static func canonical(_ text: String) -> String {
        // Only normalize a common leading acknowledgment; retain arbitrary user phrase text.
        for prefix in ["おっけー", "おっけい", "おーけー", "おーけい", "okay", "ok"] where text.hasPrefix(prefix) {
            return "おっけー" + text.dropFirst(prefix.count)
        }
        return text
    }
    public static func isValid(_ phrases: String) -> Bool {
        let entries = phrases.split(separator: "\n")
        return !entries.isEmpty && entries.allSatisfy { $0.map(normalized).joined().count >= 4 }
    }
}
