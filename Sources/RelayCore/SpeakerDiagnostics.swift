import Foundation

/// Parses the speaker-verification fields of a worker result once and renders the diagnostics text shown in the UI.
public struct SpeakerDiagnostics {
    public let note: String
    public let similarity: Double?
    public let overall: Double?
    /// nil when `speaker_windows` is absent; an empty array when it is present but empty.
    public let rawWindows: [[String: Any]]?
    public init(result: [String: Any]) {
        note = result["speaker_note"] as? String ?? ""
        similarity = result["similarity"] as? Double
        overall = result["overall_similarity"] as? Double
        rawWindows = result["speaker_windows"] as? [[String: Any]]
    }
    /// Valid windows with their original enumerated index (invalid entries still consume an index).
    public var windows: [(index: Int, seconds: Double, similarity: Double)] {
        (rawWindows ?? []).enumerated().compactMap { index, window in
            guard let seconds = window["seconds"] as? Double, let value = window["similarity"] as? Double else { return nil }
            return (index: index, seconds: seconds, similarity: value)
        }
    }
    public func summary(mode: String, threshold: Double, language: AppLanguage? = nil) -> String {
        guard let similarity else { return note }
        if mode == "prefer" {
            return note + String(format: L10n.text("\n話者類似度 %.3f（参考値・単独発話を拒否するしきい値ではありません）", language: language), similarity)
        }
        var text = String(format: L10n.text("話者類似度 %.3f（しきい値 %.3f）", language: language), similarity, threshold)
        if let overall {
            text += String(format: L10n.text(" / 発話全体 %.3f", language: language), overall)
        }
        if rawWindows != nil {
            let values = windows.map { String(format: L10n.text("%.2f秒: %.3f", language: language), $0.seconds, $0.similarity) }
            text += L10n.text("\n区間別: ", language: language) + values.joined(separator: (language ?? L10n.language) == .japanese ? "、" : ", ")
        }
        return text
    }
}
