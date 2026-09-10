import SwiftUI
import RelayCore

struct AdvancedSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Group {
                SettingsIntro(section: .advanced, description: L10n.text("ローカル音声環境と、モデルの保存先を管理します。"))
                Section {
                    TextField(L10n.text("Pythonの絶対パス"), text: $model.settings.pythonPath)
                    TextField(L10n.text("Whisperモデルの絶対パス"), text: $model.settings.asrModelPath)
                    TextField(L10n.text("Qwenモデルの絶対パス"), text: $model.settings.ttsModelPath)
                    Button(L10n.text("ローカル環境を診断"), systemImage: "stethoscope") { Task { await model.checkLocal() } }.disabled(!model.canConfigure)
                } header: { Text(L10n.text("取得済みのローカル環境")) } footer: { Text(L10n.text("結果はログ画面で確認できます。モデルが未配置の場合は案内を表示し、自動で取得しません。Qwenの標準は models/voice-1.7b（1.7B・8bit）です。以前の models/voice（0.6B・4bit）は省メモリ用に残せます。")) }
                Section {
                    Text(L10n.text("初回だけ、リポジトリで次のコマンドを実行します。"))
                    Text(L10n.text("scripts/setup-runtime.sh\nscripts/download-models.sh asr\n\n自分の声を再現する場合：\nscripts/setup-runtime.sh --voice\nscripts/download-models.sh voice\n\n16GBのMacなど省メモリで使う場合：\nscripts/download-models.sh voice-small"))
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                } header: { Text(L10n.text("初回セットアップ")) } footer: { Text(L10n.text("依存関係とモデルの取得はセットアップ時だけ通信します。通常の音声処理はMac内で完結します。")) }
                Section {
                    LabeledContent(L10n.text("設定と参照音声"), value: L10n.text("このMacのアプリ用フォルダ"))
                    LabeledContent(L10n.text("認証情報"), value: L10n.text("macOSキーチェーン"))
                    LabeledContent(L10n.text("診断ログ"), value: L10n.text("このMacに直近500件"))
                } header: { Text(L10n.text("データの保存")) } footer: { Text(L10n.text("ログには処理の種類と診断の数値を記録します。トークン・会話本文・宛先・画像・録音は記録しません。")) }
            }.disabled(!model.canConfigure)
        }.formStyle(.grouped)
    }
}
