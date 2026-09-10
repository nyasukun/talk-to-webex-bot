import SwiftUI
import RelayCore

struct InputSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Group {
                SettingsIntro(section: .input, description: L10n.text("合言葉と、声の受け付け方を設定します。"))
                Section {
                    Picker("Language / 言語", selection: Binding(
                        get: { model.settings.language },
                        set: { model.changeLanguage(to: $0) }
                    )) {
                        ForEach(AppLanguage.allCases) { Text($0.name).tag($0) }
                    }
                } header: { Text(L10n.text("言語")) } footer: {
                    Text(L10n.text("言語を切り替えると、通常・返信用の合言葉と両方のテンプレートを初期値に戻します。変更を保存すると次回もこの言語を使います。"))
                }.disabled(!model.canConfigure)
                Section {
                    TextSetting(title: L10n.text("通常の合言葉"), text: $model.settings.wakePhrases).disabled(!model.canConfigure)
                } header: { Text(L10n.text("会話を始める")) } footer: { Text(L10n.text("例：オッケー、アシスタント。別の表記は1行ずつ登録できます。合言葉は送信文から除きます。")) }
                Section {
                    TextSetting(title: L10n.text("返信用の合言葉"), text: $model.settings.replyWakePhrases).disabled(!model.canConfigure)
                } header: { Text(L10n.text("スレッドへ返信する")) } footer: { Text(L10n.text("例：オッケー、返信して。直前に受け取った返信のスレッドへ送ります。空欄にすると無効になります。通常の合言葉とは別の言葉を登録してください。")) }
                Section {
                    Toggle(L10n.text("登録した声を優先する"), isOn: $model.settings.speakerVerification).disabled(!model.canConfigure)
                    Picker(L10n.text("声の判定方法"), selection: $model.settings.speakerMode) {
                        Text(L10n.text("登録した声を優先")).tag("prefer")
                        Text(L10n.text("厳格に本人照合")).tag("strict")
                    }.disabled(!model.settings.speakerVerification || !model.canConfigure)
                    if model.settings.speakerMode == "strict" { NumberSetting(title: L10n.text("類似度のしきい値"), unit: "", value: $model.settings.speakerThreshold).disabled(!model.canConfigure) }
                    ReferenceSettings(model: model, kind: .speaker)
                } header: { Text(L10n.text("話す人の優先")) } footer: {
                    Text(L10n.text("優先モードは短い発話も受け付けます。複数の声を区別できる場合だけ、登録した声を優先します。読み上げ用の声の再現とは別機能です。"))
                }
                Section {
                    NumberSetting(title: L10n.text("発話を区切る無音"), unit: L10n.text("秒"), value: $model.settings.silenceSeconds)
                    NumberSetting(title: L10n.text("追加発話をつなぐ無音"), unit: L10n.text("秒"), value: $model.settings.continuationSeconds)
                    NumberSetting(title: L10n.text("合言葉の後の受付時間"), unit: L10n.text("秒"), value: $model.settings.commandWaitSeconds)
                    DisclosureGroup(L10n.text("マイクの詳細")) {
                        NumberSetting(title: L10n.text("入力音量のしきい値"), unit: "", value: $model.settings.minimumRMS)
                        Toggle(L10n.text("Macの追加音声処理"), isOn: $model.settings.voiceProcessing)
                        Text(L10n.text("入力できないときは追加音声処理をオフにしてください。マイクテストと診断結果は「ログ」にあります。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text(L10n.text("発話の区切り")) } footer: {
                    Text(L10n.text("最後に声が出てから、初期値1.2秒の無音で一度送信します。初期値3.6秒までに話し始めたら、前の発話とつなげて再送します。送信前確認がONの場合は、つなげた全文を確認してから送信します。"))
                    Text(L10n.text("区切る無音は0.3〜4秒、つなぐ無音はそれより長い30秒以内、合言葉の後の受付は3〜60秒です。25秒続く音声区間は破棄して待受を続けます。"))
                }.disabled(!model.canConfigure)
                Section {
                    Toggle(L10n.text("待受中の自動スリープを防ぐ"), isOn: $model.settings.preventIdleSleep).disabled(!model.canConfigure)
                } header: { Text(L10n.text("常時待受")) } footer: {
                    Text(L10n.text("画面ロック中も待受を続けます。画面の消灯とロックは妨げません。Macの蓋を閉じた場合・手動スリープ・ログアウト中は動作しません。待受中は電力を使用します。"))
                }
                Section {
                    Text(L10n.text("今日は予定を確認します。必要な情報を整理して、順番に作業を進めます。画面に表示された内容を読み取り、分かりやすく説明してください。"))
                        .textSelection(.enabled)
                } header: { Text(L10n.text("参照音声の録音例")) } footer: { Text(L10n.text("静かな場所で、普段の声で10〜20秒かけて読んでください。")) }
            }.disabled(!model.canConfigure && !model.referenceRecording)
        }.formStyle(.grouped)
    }
}
