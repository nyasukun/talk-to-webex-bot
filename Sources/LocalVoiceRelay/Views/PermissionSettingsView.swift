import SwiftUI
import RelayCore

struct PermissionSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            SettingsIntro(section: .permissions, description: "使い始める前に、このMacのアクセス権限を確認します。")
            Section {
                LabeledContent("マイク", value: model.permissionSnapshot.microphone.rawValue)
                Button("マイクの許可を設定") { Task { await model.configureMicrophonePermission() } }
                    .disabled(!model.canConfigure || model.permissionSnapshot.microphone == .allowed)
            } footer: { Text("合言葉・指示の入力と、参照音声の録音に使います。") }
            Section {
                LabeledContent("画面収録", value: model.permissionSnapshot.screen ? "許可済み" : model.settings.includeScreen ? "未許可" : "不要 · スクショはオフ")
                Button("画面収録の許可を設定") { model.requestScreenPermission() }
                    .disabled(!model.canConfigure || !model.settings.includeScreen || model.permissionSnapshot.screen)
            } footer: { Text("スクショ・OCRを使う場合に必要です。macOSの設定を変更したら、アプリを終了して開き直してください。") }
            Section { Button("権限を再確認", systemImage: "arrow.clockwise") { model.refreshPermissions() } }
        }.formStyle(.grouped)
    }
}
