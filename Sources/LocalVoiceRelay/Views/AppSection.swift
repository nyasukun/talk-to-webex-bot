import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case home = "ホーム"
    case webex = "Webex"
    case input = "音声入力"
    case output = "読み上げ・返信"
    case content = "送信内容"
    case permissions = "権限"
    case advanced = "詳細設定"
    case logs = "ログ"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .home: return "waveform"
        case .webex: return "bubble.left.and.bubble.right.fill"
        case .input: return "mic.fill"
        case .output: return "speaker.wave.2.fill"
        case .content: return "text.bubble.fill"
        case .permissions: return "hand.raised.fill"
        case .advanced: return "gearshape.fill"
        case .logs: return "list.bullet.rectangle"
        }
    }
    var color: Color {
        switch self {
        case .home, .webex: return .teal
        case .input: return .orange
        case .output: return .purple
        case .content: return .blue
        case .permissions: return .indigo
        case .advanced, .logs: return .gray
        }
    }
    var isSetting: Bool { self != .home && self != .logs }
    func matches(_ search: String) -> Bool {
        let terms: String
        switch self {
        case .home: terms = "開始 停止 待受 会話"
        case .webex: terms = "API Key パスワード キーチェーン トークン 認証 DM 宛先"
        case .input: terms = "合言葉 マイク 話者 録音 常時 ロック スリープ"
        case .output: terms = "TTS Qwen 声 再生 ソナー ポーリング 監視 タイムアウト"
        case .content: terms = "スクショ 画像 OCR プロンプト テンプレート スレッド 確認"
        case .permissions: terms = "許可 画面収録 マイク"
        case .advanced: terms = "Python モデル インストール 保存先 環境"
        case .logs: terms = "テスト エラー 診断 履歴 不具合 報告 Issue サポート"
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || (rawValue + " " + terms).localizedStandardContains(query)
    }
}
