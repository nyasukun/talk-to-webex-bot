import SwiftUI
import RelayCore

struct TokenRenewalView: View {
    @ObservedObject var model: AppModel
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "key.fill").font(.system(size: 25)).foregroundStyle(.white)
                    .frame(width: 56, height: 56).background(.teal.gradient, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.tokenRecovery.needsRenewal ? "Webexの認証を更新" : "Webexに接続").font(.title2.bold())
                    Text("新しいAPI Keyを入力してください。").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("1. 取得ページにWebexアカウントでサインインします。")
                Text("2. Personal Access Tokenをコピーします。")
                Text("3. 下の入力欄へ貼り付けて、接続を確認します。")
                Button("取得ページをブラウザで開く", systemImage: "arrow.up.right.square") { model.openTokenPortal() }
                if !model.tokenBrowserOpened { Text("ブラウザを開けませんでした。もう一度上のボタンを押してください。").font(.caption).foregroundStyle(.orange) }
            }.font(.callout).padding(16).frame(maxWidth: .infinity, alignment: .leading).relayCard()
            VStack(alignment: .leading, spacing: 8) {
                Text("Webex API Key（個人アクセストークン）").font(.callout.weight(.medium))
                SecureField("取得したトークンを貼り付け", text: $model.tokenInput).textFieldStyle(.roundedBorder).focused($focused)
                    .onSubmit { if !model.busy { Task { await model.saveToken() } } }
                Text("キーチェーンに保存します。ログには記録しません。").font(.caption).foregroundStyle(.secondary)
                if !model.tokenStatus.isEmpty { Text(model.tokenStatus).font(.caption).foregroundStyle(model.tokenValid ? Color.teal : Color.orange).fixedSize(horizontal: false, vertical: true) }
            }
            Divider()
            HStack {
                Button("あとで") {
                    model.tokenInput = ""
                    model.showTokenRenewal = false
                }.keyboardShortcut(.cancelAction).disabled(model.busy)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("保存して接続確認") { Task { await model.saveToken() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(model.busy || model.tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 510).fixedSize(horizontal: false, vertical: true)
            .interactiveDismissDisabled(model.busy).onAppear { focused = true }.onDisappear { model.tokenInput = "" }
    }
}
