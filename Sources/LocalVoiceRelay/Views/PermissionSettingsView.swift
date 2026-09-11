import SwiftUI
import RelayCore

struct PermissionSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            SettingsIntro(section: .permissions, description: L10n.text("使い始める前に、このMacのアクセス権限を確認します。"))
            Section {
                LabeledContent(L10n.text("マイク"), value: model.permissionSnapshot.microphone.title)
                Button(L10n.text("マイクの許可を設定")) { Task { await model.configureMicrophonePermission() } }
                    .disabled(!model.canConfigure || model.permissionSnapshot.microphone == .allowed)
            } footer: { Text(L10n.text("合言葉・指示の入力と、参照音声の録音に使います。")) }
            Section {
                LabeledContent(L10n.text("画面収録"), value: model.permissionSnapshot.screen ? L10n.text("許可済み") : L10n.text("未許可"))
                Button(L10n.text("画面収録の許可を設定")) { model.requestScreenPermission() }
                    .disabled(!model.canConfigure || model.permissionSnapshot.screen)
            } footer: { Text(L10n.text("スクショ・OCRを使う場合に必要です。macOSの設定を変更したら、アプリを終了して開き直してください。")) }
            Section { Button(L10n.text("権限を再確認"), systemImage: "arrow.clockwise") { model.refreshPermissions() } }
        }.formStyle(.grouped)
    }
}
