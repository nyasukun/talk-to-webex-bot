import Foundation

public struct Room: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let type: String
    public let lastActivity: String?
    public init(id: String, title: String, type: String = "direct", lastActivity: String? = nil) {
        self.id = id
        self.title = title
        self.type = type
        self.lastActivity = lastActivity
    }
    public static func filtered(_ rooms: [Room], query: String) -> [Room] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = rooms.filter { $0.type == "direct" && (query.isEmpty || $0.title.localizedStandardContains(query)) }
        let dated: [(room: Room, date: Date)] = matches.map { ($0, parseDate($0.lastActivity) ?? .distantPast) }
        return dated.sorted { left, right in
            if left.date == right.date { return left.room.id < right.room.id }
            return left.date > right.date
        }.map { $0.room }
    }
}

public func parseDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
}

public struct Person: Codable, Sendable {
    public let id: String
    public let displayName: String?
}
public struct Message: Codable, Identifiable, Sendable {
    public let id: String
    public let roomId: String
    public let personId: String?
    public let text: String?
    public let markdown: String?
    public let created: String?
    public let updated: String?
    public let parentId: String?
    public var body: String { (text ?? markdown ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    public var speechBody: String {
        guard let markdown, let parsed = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return body }
        let candidate = String(parsed.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        func content(_ value: String) -> String { value.precomposedStringWithCanonicalMapping.filter { !$0.isWhitespace } }
        // Recover paragraph breaks only when the formatted version says exactly the same thing.
        guard text == nil || content(candidate) == content(body) else { return body }
        return candidate.components(separatedBy: .newlines).count > body.components(separatedBy: .newlines).count || text == nil ? candidate : body
    }
    public init(id: String, roomId: String, personId: String? = nil, text: String? = nil,
                markdown: String? = nil, created: String? = nil, updated: String? = nil, parentId: String? = nil) {
        self.id = id
        self.roomId = roomId
        self.personId = personId
        self.text = text
        self.markdown = markdown
        self.created = created
        self.updated = updated
        self.parentId = parentId
    }
}

public enum RelayError: LocalizedError {
    case message(String)
    case unauthorized
    case rateLimited(TimeInterval)
    case ambiguousSend
    case missingPermissions([String])
    public var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .unauthorized: return L10n.text("Webex認証が切れています。設定でトークンを更新してください。")
        case .rateLimited(let seconds):
            guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else {
                return L10n.text("Webexの呼び出し制限です。時間をおいて再実行してください。")
            }
            return L10n.text("Webexの呼び出し制限です。約\(Int(seconds))秒後に再実行してください。")
        case .ambiguousSend: return L10n.text("送信結果を確認できません。重複を避けるため自動再送しません。WebexのDMを確認してください。")
        case .missingPermissions(let names): return L10n.text("必要な権限がありません: \(names.joined(separator: "・"))。画面上部の「最初に権限を確認」で許可を設定し、再確認してください。画面収録を変更した場合はアプリを再起動してください。")
        }
    }
}

public struct Settings: Codable, Equatable, Sendable {
    public private(set) var language: AppLanguage = .japanese
    public var wakePhrases = "オッケー、アシスタント"
    public var replyWakePhrases = "オッケー、返信して"
    public var replyTemplate = MessageTemplate.defaultReplyValue
    public var replyTemplateVersion = 1
    public var roomID = ""
    public var roomTitle = ""
    public var includeScreen = false
    public var confirmBeforeSending = true
    public var readReplies = false
    public var waitingSound = true
    public var waitingSoundVolume = 0.2
    public var hotStandby = true
    public var preventIdleSleep = true
    public var speakerVerification = false
    public var speakerMode = "prefer"
    public var speakerThreshold = 0.76
    public var speakerAudioPath = ""
    public var silenceSeconds = 1.2
    public var commandWaitSeconds = 12.0
    public var minimumRMS = 0.008
    public var voiceProcessing = false
    public var replySettleSeconds = 6.0
    public var replyPollSeconds = 0.1
    public var replyPollVersion = 1
    public var replyPollMilliseconds: Double {
        get { replyPollSeconds * 1000 }
        set { replyPollSeconds = newValue / 1000 }
    }
    public var replyTimeoutSeconds = 180.0
    public var requireThreadedReply = false
    public var busyPatterns = "Working...\n考え中...\n処理中..."
    public var template = MessageTemplate.defaultValue
    public var speechTemplateVersion = 1
    public var numberTemplateVersion = 1
    public var tokenIssuedAt: Date? = nil
    public var asrModelPath = ""
    public var pythonPath = ""
    public var ttsEngine = "system"
    public var ttsModelPath = ""
    public var referenceAudioPath = ""
    public var referenceText = ""
    public var reduceReferenceNoise = true
    public var systemVoiceID = ""
    public var voiceModelVersion = 2
    public init(language: AppLanguage = .system) {
        self.language = language
        busyPatterns = language.busyPatterns
        resetLanguageDefaults()
    }

    public mutating func changeLanguage(to language: AppLanguage) {
        guard self.language != language else { return }
        if busyPatterns == self.language.busyPatterns { busyPatterns = language.busyPatterns }
        self.language = language
        resetLanguageDefaults()
        systemVoiceID = ""
    }

    private mutating func resetLanguageDefaults() {
        wakePhrases = language.wakePhrases
        replyWakePhrases = language.replyWakePhrases
        template = MessageTemplate.defaultValue(for: language)
        replyTemplate = MessageTemplate.defaultReplyValue(for: language)
    }

    /// Picks the voice model folder. `standard` is the 1.7B model that `download-models.sh voice` installs;
    /// `small` is the 0.6B folder of earlier builds. Saved settings from before the larger model move to it
    /// once, on the first launch where it is installed, and any later explicit choice is kept.
    public mutating func resolveVoiceModel(standard: String, small: String, standardExists: Bool, smallExists: Bool) {
        if ttsModelPath.isEmpty { ttsModelPath = standardExists || !smallExists ? standard : small }
        guard voiceModelVersion < 2 else { return }
        if ttsModelPath == small {
            guard standardExists else { return }
            ttsModelPath = standard
        }
        voiceModelVersion = 2
    }

    public func validate() throws {
        guard ["system", "qwen"].contains(ttsEngine) else { throw RelayError.message(L10n.text("読み上げの音声方式を選び直してください。")) }
        guard ["prefer", "strict"].contains(speakerMode) else { throw RelayError.message(L10n.text("声の判定方法を選び直してください。")) }
        guard WakeMatcher.isValid(wakePhrases) else { throw RelayError.message(L10n.text("合言葉を4文字以上で登録してください。複数候補は改行で分けます。")) }
        if !replyWakePhrases.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard WakeMatcher.isValid(replyWakePhrases), !WakeMatcher.overlaps(wakePhrases, replyWakePhrases) else {
                throw RelayError.message(L10n.text("返信用の合言葉は4文字以上にして、通常の合言葉と区別できるものを登録してください。"))
            }
        }
        let ranges: [(Double, ClosedRange<Double>, String)] = [
            (silenceSeconds, 0.3...4, L10n.text("発話を区切る無音は0.3〜4秒で指定してください。")),
            (commandWaitSeconds, 3...60, L10n.text("合言葉の後の受付時間は3〜60秒で指定してください。")),
            (minimumRMS, 0.001...0.1, L10n.text("入力音量のしきい値は0.001〜0.1で指定してください。")),
            (speakerThreshold, 0.5...0.99, L10n.text("類似度のしきい値は0.5〜0.99で指定してください。")),
            (replyPollSeconds, 0.1...30, L10n.text("返信の監視間隔は100〜30,000msで指定してください。")),
            (replySettleSeconds, 2...60, L10n.text("本文更新が止まってから待つ時間は2〜60秒で指定してください。")),
            (waitingSoundVolume, 0...1, L10n.text("ソナー音量は0〜1で指定してください。")),
            (replyTimeoutSeconds, 30...900, L10n.text("返信の待ち時間は30〜900秒で指定してください。"))
        ]
        for (value, range, message) in ranges where !range.contains(value) { throw RelayError.message(message) }
        guard replyTimeoutSeconds > replySettleSeconds else {
            throw RelayError.message(L10n.text("返信の待ち時間は、本文更新が止まってから待つ時間より長くしてください。"))
        }
        _ = try MessageTemplate.render(template, transcript: L10n.text("テスト"), ocr: L10n.text("テスト"), screen: true)
        _ = try MessageTemplate.render(template, transcript: L10n.text("テスト"), ocr: nil, screen: false)
        _ = try MessageTemplate.render(replyTemplate, transcript: L10n.text("テスト"), ocr: nil, screen: false)
    }
}

public enum TokenHealth: Equatable {
    case unknown, valid, expiring, expired
    public static func estimate(issuedAt: Date?, now: Date) -> TokenHealth {
        guard let issuedAt, issuedAt <= now else { return .unknown }
        let remaining = issuedAt.addingTimeInterval(12 * 3600).timeIntervalSince(now)
        return remaining <= 0 ? .expired : remaining <= 1800 ? .expiring : .valid
    }
}
