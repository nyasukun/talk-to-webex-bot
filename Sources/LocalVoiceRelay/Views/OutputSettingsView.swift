import SwiftUI
import RelayCore

struct OutputSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Group {
                SettingsIntro(section: .output, description: L10n.text("声の種類・音量・音質と、返信を待つ間の動作を設定します。"))
                Section {
                    HStack {
                        Text(L10n.text("読み上げ音量"))
                        Spacer()
                        Slider(value: $model.settings.speechVolume, in: 0...1, step: 0.01)
                            .frame(maxWidth: 220).accessibilityLabel(L10n.text("読み上げ音量"))
                        Text(model.settings.speechVolume, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                    if model.settings.ttsEngine == "system" {
                        NumberSetting(title: L10n.text("話す速さ"), unit: L10n.text("語/分"), value: $model.settings.systemSpeechRate)
                        Text(L10n.text("速さは0で声の標準速度、80〜400で指定速度になります。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text(L10n.text("音量と速さ")) } footer: {
                    Text(L10n.text("読み上げ音量は両方の音声方式に適用します。0%で消音、初期値は100%です。Mac全体とソナーの音量は変えません。"))
                }.disabled(!model.canConfigure)
                Section {
                    Toggle(L10n.text("レスポンスを読み上げる"), isOn: $model.settings.readReplies).disabled(!model.canConfigure)
                    Picker(L10n.text("読み上げ方式"), selection: $model.settings.ttsEngine) {
                        Text(L10n.text("Mac標準音声")).tag("system")
                        Text(L10n.text("Qwen3-TTS · 自分の声を再現")).tag("qwen")
                    }.disabled(!model.canConfigure)
                    if model.settings.ttsEngine == "system" {
                        Picker(L10n.text("日本語の声"), selection: $model.settings.systemVoiceID) {
                            Text(L10n.text("自動選択")).tag("")
                            ForEach(SpeechOutput.voices(for: model.settings.language), id: \.identifier) { Text(SpeechOutput.name($0)).tag($0.identifier) }
                        }.disabled(!model.canConfigure)
                        Text(L10n.text("自動選択は取得済みの最も高品質なKyokoを使います。システム設定 → アクセシビリティ → 読み上げコンテンツで「拡張」「プレミアム」の日本語音声を取得すると、ここに表示されます。"))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ReferenceSettings(model: model, kind: .voice)
                        TextSetting(title: L10n.text("参照録音で実際に読んだ全文"), text: $model.settings.referenceText, height: 85).disabled(!model.canConfigure)
                        Toggle(L10n.text("参照音声の背景ノイズを軽減"), isOn: $model.settings.reduceReferenceNoise).disabled(!model.canConfigure)
                        Text(L10n.text("声と一緒に再現される背景音を抑えます。声の響きが気になる場合は、オフの音声と比べてください。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text(L10n.text("読み上げる声")) } footer: { Text(L10n.text("Qwenは10〜20秒の参照音声から声を再現します。参照本文は録音の全文と一致させてください。追加学習は行いません。参照音声はメモリ上で整えてから使います（低域の除去、ノイズ軽減、音量の統一。録音の長さは変えません）。返信のMarkdownや絵文字・URLは読み上げ用に言い換え、画面の表示は変えません。")) }
                if model.settings.ttsEngine == "qwen" {
                    SpeechQualitySettingsView(model: model).disabled(!model.canConfigure)
                }
                Section {
                    TextSetting(title: L10n.text("試聴する文章"), text: $model.speechTestText, height: 105)
                    Button(L10n.text("この設定で読み上げを試す"), systemImage: "play.fill") { model.testSpeech() }.disabled(!model.canConfigure)
                } header: { Text(L10n.text("声を試す")) } footer: { Text(L10n.text("この試聴はWebexへ送信しません。Qwenは冒頭を短く区切り、音声ができ次第読み始めます。その後は改行に沿って読み上げ、再生中も次の行を準備します。")) }.disabled(!model.canConfigure)
                Section {
                    Toggle(L10n.text("返信待ちにソナー音を流す"), isOn: $model.settings.waitingSound)
                    HStack {
                        Text(L10n.text("ソナー音量"))
                        Slider(value: $model.settings.waitingSoundVolume, in: 0...1).frame(maxWidth: 220)
                    }.disabled(!model.settings.waitingSound)
                    Toggle(L10n.text("返信待ちに音声モデルを準備する"), isOn: $model.settings.hotStandby)
                } header: { Text(L10n.text("返信待ち")) } footer: { Text(L10n.text("約3秒ごとのソナー音が、読み上げ開始と同時に止まります。ホットスタンバイではモデルと参照音声を先に準備します。")) }.disabled(!model.canConfigure)
                Section {
                    NumberSetting(title: L10n.text("返信の監視間隔"), unit: "ms", value: $model.settings.replyPollMilliseconds)
                    NumberSetting(title: L10n.text("本文更新が止まってから待つ時間"), unit: L10n.text("秒"), value: $model.settings.replySettleSeconds)
                    NumberSetting(title: L10n.text("返信の待ち時間"), unit: L10n.text("秒"), value: $model.settings.replyTimeoutSeconds)
                    DisclosureGroup(L10n.text("返信の判定条件")) {
                        Toggle(L10n.text("送信へのスレッド返信だけを読む"), isOn: $model.settings.requireThreadedReply)
                        TextSetting(title: L10n.text("途中表示の先頭フレーズ（1行ずつ）"), text: $model.settings.busyPatterns)
                    }
                } header: { Text(L10n.text("返信の確認")) } footer: { Text(L10n.text("監視は100〜30,000ms、更新停止は2〜60秒、返信の待ち時間は30〜900秒。期限後は再送せず、次の合言葉の待受へ戻ります。最終回答の判定は更新停止に基づく推定です。")) }.disabled(!model.canConfigure)
            }.disabled(!model.canConfigure && !model.referenceRecording)
        }.formStyle(.grouped)
    }
}
