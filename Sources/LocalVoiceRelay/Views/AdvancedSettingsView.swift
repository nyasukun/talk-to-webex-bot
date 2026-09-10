import SwiftUI
import RelayCore

struct AdvancedSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            SettingsIntro(section: .advanced, description: "ローカル音声環境と、モデルの保存先を管理します。")
            Section {
                TextField("Pythonの絶対パス", text: $model.settings.pythonPath)
                TextField("Whisperモデルの絶対パス", text: $model.settings.asrModelPath)
                TextField("Qwenモデルの絶対パス", text: $model.settings.ttsModelPath)
                Button("ローカル環境を診断", systemImage: "stethoscope") { Task { await model.checkLocal() } }.disabled(!model.canConfigure)
            } header: { Text("取得済みのローカル環境") } footer: { Text("結果はログ画面で確認できます。モデルが未配置の場合は案内を表示し、自動で取得しません。") }
            Section {
                Text("初回だけ、リポジトリで次のコマンドを実行します。")
                Text("scripts/setup-runtime.sh\nscripts/download-models.sh asr\n\n自分の声を再現する場合：\nscripts/setup-runtime.sh --voice\nscripts/download-models.sh voice")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            } header: { Text("初回セットアップ") } footer: { Text("依存関係とモデルの取得はセットアップ時だけ通信します。通常の音声処理はMac内で完結します。") }
            Section {
                LabeledContent("設定と参照音声", value: "このMacのアプリ用フォルダ")
                LabeledContent("認証情報", value: "macOSキーチェーン")
                LabeledContent("診断ログ", value: "このMacに直近500件")
            } header: { Text("データの保存") } footer: { Text("ログには処理の種類と診断の数値を記録します。トークン・会話本文・宛先・画像・録音は記録しません。") }
        }.formStyle(.grouped).disabled(!model.canConfigure)
    }
}
