import Foundation
import RelayCore

enum IssueReport {
    static let formURL = URL(string: "https://github.com/nyasukun/talk-to-webex-bot/issues/new?template=bug_report.yml")!

    static func version(_ value: String?) -> String {
        guard let value, !value.isEmpty, value.count <= 32,
              value.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else { return "開発版" }
        return value
    }

    /// Explicit projection: adding a setting never silently adds it to a public report.
    static func draft(settings: Settings, phase: AppModel.Phase, permissions: PermissionSnapshot,
                      entries: [LogEntry], bundle: Bundle = .main) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let onOff: (Bool) -> String = { $0 ? "オン" : "オフ" }
        let engine = settings.ttsEngine == "qwen" ? "Qwen（ローカル）" : settings.ttsEngine == "system" ? "Mac標準" : "未選択"
        let metrics = Set(LogMetric.allCases.map(\.rawValue))
        let recent = entries.suffix(30).map { entry in
            let safe = LogEntry(id: entry.id, date: entry.date, category: entry.category, level: entry.level, event: entry.event,
                                metrics: entry.metrics.filter { metrics.contains($0.key) && $0.value.isFinite })
            return "[\(safe.level.rawValue)] [\(safe.category.rawValue)] \(safe.event.message) \(safe.details)"
        }.joined(separator: "\n")
        #if arch(arm64)
        let architecture = "Apple Silicon"
        #else
        let architecture = "Intel"
        #endif
        return """
        ## 起きたこと
        （期待した動作と、実際に起きたことを記入）

        ## 再現手順・頻度
        1.
        2.
        頻度：

        ## 環境
        - アプリ: \(version(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String))（ビルド \(version(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String))）
        - macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) / \(architecture)
        - 状態: \(phase.rawValue)
        - マイク許可: \(permissions.microphone == .allowed ? "許可済み" : "未許可")
        - 画面収録許可: \(permissions.screen ? "許可済み" : "未許可")
        - スクショ・OCR: \(onOff(settings.includeScreen)) / 送信前確認: \(onOff(settings.confirmBeforeSending))
        - 返信読み上げ: \(onOff(settings.readReplies)) / 音声方式: \(engine)
        - 話者判定: \(onOff(settings.speakerVerification))

        ## 試した対処
        （実施したものだけ記入）

        ## 診断イベント（直近30件、古い順）
        ```text
        \(recent.isEmpty ? "記録なし" : recent)
        ```
        """
    }
}
