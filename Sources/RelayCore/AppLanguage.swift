import Foundation

public enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case japanese = "ja"
    case english = "en"

    public var id: String { rawValue }
    public var name: String { self == .japanese ? "日本語" : "English" }
    public var locale: Locale { Locale(identifier: self == .japanese ? "ja_JP" : "en_US") }
    public static var system: AppLanguage { preferred(Locale.preferredLanguages) }

    /// Follow the first system language, not the region or a lower-priority Japanese fallback.
    public static func preferred(_ languages: [String]) -> AppLanguage {
        let primary = languages.first?.replacingOccurrences(of: "_", with: "-").split(separator: "-").first?.lowercased()
        return primary == "ja" ? .japanese : .english
    }

    public var wakePhrases: String { self == .japanese ? "オッケー、アシスタント" : "Okay, assistant" }
    public var replyWakePhrases: String { self == .japanese ? "オッケー、返信して" : "Okay, reply" }
    public var busyPatterns: String { self == .japanese ? "Working...\n考え中...\n処理中..." : "Working...\nThinking...\nProcessing..." }
}
