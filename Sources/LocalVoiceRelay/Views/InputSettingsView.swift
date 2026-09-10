import SwiftUI
import RelayCore

struct InputSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            SettingsIntro(section: .input, description: "合言葉と、声の受け付け方を設定します。")
            Section {
                TextSetting(title: "通常の合言葉", text: $model.settings.wakePhrases).disabled(!model.canConfigure)
            } header: { Text("会話を始める") } footer: { Text("例：オッケー、アシスタント。別の表記は1行ずつ登録できます。合言葉は送信文から除きます。") }
            Section {
                TextSetting(title: "返信用の合言葉", text: $model.settings.replyWakePhrases).disabled(!model.canConfigure)
            } header: { Text("スレッドへ返信する") } footer: { Text("例：オッケー、返信して。直前に受け取った返信のスレッドへ送ります。空欄にすると無効になります。通常の合言葉とは別の言葉を登録してください。") }
            Section {
                Toggle("登録した声を優先する", isOn: $model.settings.speakerVerification).disabled(!model.canConfigure)
                Picker("声の判定方法", selection: $model.settings.speakerMode) {
                    Text("登録した声を優先").tag("prefer")
                    Text("厳格に本人照合").tag("strict")
                }.disabled(!model.settings.speakerVerification || !model.canConfigure)
                if model.settings.speakerMode == "strict" { NumberSetting(title: "類似度のしきい値", unit: "", value: $model.settings.speakerThreshold).disabled(!model.canConfigure) }
                ReferenceSettings(model: model, kind: .speaker)
            } header: { Text("話す人の優先") } footer: {
                Text("優先モードは短い発話も受け付けます。複数の声を区別できる場合だけ、登録した声を優先します。読み上げ用の声の再現とは別機能です。")
            }
            Section {
                NumberSetting(title: "発話を区切る無音", unit: "秒", value: $model.settings.silenceSeconds)
                NumberSetting(title: "合言葉の後の受付時間", unit: "秒", value: $model.settings.commandWaitSeconds)
                DisclosureGroup("マイクの詳細") {
                    NumberSetting(title: "入力音量のしきい値", unit: "", value: $model.settings.minimumRMS)
                    Toggle("Macの追加音声処理", isOn: $model.settings.voiceProcessing)
                    Text("入力できないときは追加音声処理をオフにしてください。マイクテストと診断結果は「ログ」にあります。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("発話の区切り") } footer: { Text("待受時間に上限はありません。無音は0.3〜4秒、合言葉の後の指示受付は3〜60秒です。25秒続く音声区間は破棄して待受を続けます。") }.disabled(!model.canConfigure)
            Section {
                Toggle("待受中の自動スリープを防ぐ", isOn: $model.settings.preventIdleSleep).disabled(!model.canConfigure)
            } header: { Text("常時待受") } footer: {
                Text("画面ロック中も待受を続けます。画面の消灯とロックは妨げません。Macの蓋を閉じた場合・手動スリープ・ログアウト中は動作しません。待受中は電力を使用します。")
            }
            Section {
                Text("今日は予定を確認します。必要な情報を整理して、順番に作業を進めます。画面に表示された内容を読み取り、分かりやすく説明してください。")
                    .textSelection(.enabled)
            } header: { Text("参照音声の録音例") } footer: { Text("静かな場所で、普段の声で10〜20秒かけて読んでください。") }
        }.formStyle(.grouped).disabled(!model.canConfigure && !model.referenceRecording)
    }
}
