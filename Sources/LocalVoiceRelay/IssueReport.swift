import Foundation
import RelayCore

enum IssueReport {
    static let formURL = URL(string: "https://github.com/nyasukun/talk-to-webex-bot/issues/new?template=bug_report.yml")!

    static func version(_ value: String?) -> String {
        guard let value, !value.isEmpty, value.count <= 32,
              value.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else { return L10n.text("開発版") }
        return value
    }

    /// Explicit projection: adding a setting never silently adds it to a public report.
    static func draft(settings: Settings, phase: AppModel.Phase, permissions: PermissionSnapshot,
                      entries: [LogEntry], bundle: Bundle = .main) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let onOff: (Bool) -> String = { $0 ? L10n.text("オン") : L10n.text("オフ") }
        // Only the model size is reported, never the folder path.
        let voiceModel = ["voice-1.7b": "1.7B", "voice": "0.6B"][URL(fileURLWithPath: settings.ttsModelPath).lastPathComponent] ?? L10n.text("カスタム")
        let engine = settings.ttsEngine == "qwen" ? L10n.text("Qwen（ローカル・\(voiceModel)）") : settings.ttsEngine == "system" ? L10n.text("Mac標準") : L10n.text("未選択")
        let metrics = Set(LogMetric.allCases.map(\.rawValue))
        let recent = entries.suffix(30).map { entry in
            let safe = LogEntry(id: entry.id, date: entry.date, category: entry.category, level: entry.level, event: entry.event,
                                metrics: entry.metrics.filter { metrics.contains($0.key) && $0.value.isFinite })
            return "[\(safe.level.title)] [\(safe.category.title)] \(safe.event.message) \(safe.details)"
        }.joined(separator: "\n")
        #if arch(arm64)
        let architecture = "Apple Silicon"
        #else
        let architecture = "Intel"
        #endif
        return L10n.text("""
        ## 起きたこと
        （期待した動作と、実際に起きたことを記入）

        ## 再現手順・頻度
        1.
        2.
        頻度：

        ## 環境
        - アプリ: \(version(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String))（ビルド \(version(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String))）
        - macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) / \(architecture)
        - 状態: \(phase.title)
        - マイク許可: \(permissions.microphone == .allowed ? L10n.text("許可済み") : L10n.text("未許可"))
        - 画面収録許可: \(permissions.screen ? L10n.text("許可済み") : L10n.text("未許可"))
        - スクショ・OCR: \(onOff(settings.includeScreen)) / 送信前確認: \(onOff(settings.confirmBeforeSending))
        - 返信読み上げ: \(onOff(settings.readReplies)) / 音声方式: \(engine)
        - 話者判定: \(onOff(settings.speakerVerification))

        ## 試した対処
        （実施したものだけ記入）

        ## 診断イベント（直近30件、古い順）
        ```text
        \(recent.isEmpty ? L10n.text("記録なし") : recent)
        ```
        """)
    }
}
