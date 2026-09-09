import SwiftUI
import AppKit
import RelayCore

struct SettingsIntro: View {
    let section: AppSection
    let description: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: section.symbol).font(.system(size: 23, weight: .medium)).foregroundStyle(.white)
                .frame(width: 50, height: 50).background(section.color.gradient, in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 5) {
                Text(section.rawValue).font(.title2.weight(.semibold))
                Text(description).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.vertical, 8)
    }
}
struct NumberSetting: View {
    let title: String
    let unit: String
    @Binding var value: Double
    var body: some View {
        HStack {
            Text(title); Spacer()
            TextField(title, value: $value, format: .number).multilineTextAlignment(.trailing).frame(width: 90)
            Text(unit).foregroundStyle(.secondary).frame(minWidth: 28, alignment: .leading)
        }
    }
}
struct TextSetting: View {
    let title: String
    @Binding var text: String
    var height: CGFloat = 70
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout)
            TextEditor(text: $text).font(.system(.body)).scrollContentBackground(.hidden)
                .padding(6).frame(height: height).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary))
                .accessibilityLabel(title)
        }.padding(.vertical, 4)
    }
}
struct ReferenceSettings: View {
    @ObservedObject var model: AppModel
    let kind: ReferenceKind
    private var registered: Bool { !model.settings[keyPath: kind.pathKeyPath].isEmpty }
    var body: some View {
        LabeledContent("参照音声") { Label(registered ? "登録済み" : "未登録", systemImage: registered ? "checkmark.circle.fill" : "waveform").foregroundStyle(registered ? Color.teal : Color.secondary) }
        HStack {
            if model.referenceRecording {
                Label("録音中です。普段の声で話してください。", systemImage: "record.circle").foregroundStyle(.red)
                Spacer()
                Button("録音終了") { model.finishReference() }.tint(.red)
            } else {
                Button("参照音声を録音", systemImage: "mic") { Task { await model.startReference(kind: kind) } }
                    .disabled(!model.canConfigure || model.permissionSnapshot.microphone != .allowed)
                Button("音声ファイルを選ぶ", systemImage: "folder") { model.chooseReference(kind: kind) }.disabled(!model.canConfigure)
            }
        }
    }
}
struct WebexSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            SettingsIntro(section: .webex, description: "認証と、声で話しかける相手を設定します。")
            Section {
                LabeledContent("認証状態") {
                    HStack {
                        if model.checkingToken || model.busy { ProgressView().controlSize(.small) }
                        Label(model.tokenValid ? "接続済み" : model.keychainNeedsAccess ? "アクセス確認が必要" : model.tokenRecovery.needsRenewal ? "更新が必要" : "未確認", systemImage: model.tokenValid ? "checkmark.circle.fill" : "key.fill").foregroundStyle(model.tokenValid ? Color.teal : Color.orange)
                    }
                }
                Text(model.tokenStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if model.keychainNeedsAccess {
                    Button("保存済みトークンを読み込む", systemImage: "key") { Task { await model.authorizeSavedToken() } }
                        .buttonStyle(.borderedProminent).disabled(!model.canConfigure)
                    Text("この操作でmacOSのアクセス確認を許可します。「有効性を確認」はパスワード画面を出しません。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(model.tokenRecovery.needsRenewal ? "API Keyを更新" : "API Keyを入力") { model.presentTokenRenewal() }.disabled(!model.canConfigure)
                    Button("有効性を確認") { Task { await model.checkToken() } }.disabled(model.busy || model.checkingToken)
                }
                if !model.keychainNeedsAccess {
                DisclosureGroup("保存済みトークンへのアクセス") {
                    Text("読み込みにmacOSの確認が必要な場合に使います。「常に許可」を選ぶと、同じ署名のアプリを次回も許可できます。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("保存済みトークンを読み込む") { Task { await model.authorizeSavedToken() } }.disabled(!model.canConfigure)
                }
                }
            } header: { Text("Webexアカウント") } footer: {
                Text("API Key（個人アクセストークン）はキーチェーンに保存します。失効時は取得ページを既定のブラウザで開き、更新を案内します。")
            }
            Section {
                LabeledContent("選択中の宛先", value: model.settings.roomTitle.isEmpty ? "未選択" : model.settings.roomTitle)
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("DM名で絞り込む", text: $model.query).textFieldStyle(.plain).disabled(!model.canConfigure)
                    if model.roomsLoading { ProgressView().controlSize(.small) }
                    Button { model.loadRooms() } label: { Image(systemName: "arrow.clockwise") }.help("DM一覧を更新").accessibilityLabel("DM一覧を更新").disabled(!model.canConfigure)
                }
                VStack(spacing: 0) {
                    ForEach(0..<5, id: \.self) { index in
                        if index > 0 { Divider() }
                        if index < model.filteredRooms.count {
                            let room = model.filteredRooms[index]
                            Button { model.selectRoom(room) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.teal.opacity(0.8))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(room.title).foregroundStyle(.primary).lineLimit(1)
                                        if let date = parseDate(room.lastActivity) { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    if model.settings.roomID == room.id { Image(systemName: "checkmark").foregroundStyle(.teal).fontWeight(.semibold) }
                                }.padding(.horizontal, 6).frame(height: 49).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(!model.canConfigure)
                        } else {
                            HStack { if index == 0 { Text(model.roomsLoading ? "宛先を探しています…" : "一致する宛先がありません").font(.callout).foregroundStyle(.secondary) }; Spacer() }.frame(height: 49)
                        }
                    }
                }
            } header: { Text("送信先のDM") } footer: {
                Text("最近やりとりした5件を表示します。検索すると、一致する宛先の直近5件に切り替わります。\n\(model.roomSearchStatus)")
            }
            Section {
                Toggle("トークンの発行時刻を指定する", isOn: Binding(get: { model.settings.tokenIssuedAt != nil }, set: { model.settings.tokenIssuedAt = $0 ? Date() : nil }))
                if model.settings.tokenIssuedAt != nil {
                    DatePicker("実際の発行時刻", selection: Binding(get: { model.settings.tokenIssuedAt ?? Date() }, set: { model.settings.tokenIssuedAt = $0 }), in: ...Date())
                }
            } header: { Text("有効期限の目安") } footer: { Text(model.tokenEstimate) }
            .disabled(!model.canConfigure)
        }.formStyle(.grouped)
        .onAppear { if !model.isPreview && model.rooms.isEmpty && !model.roomsLoading { model.loadRooms() } }
    }
}
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
struct OutputSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            SettingsIntro(section: .output, description: "声の種類と、返信を待つ間の動作を設定します。")
            Section {
                Toggle("レスポンスを読み上げる", isOn: $model.settings.readReplies).disabled(!model.canConfigure)
                Picker("読み上げ方式", selection: $model.settings.ttsEngine) {
                    Text("Mac標準音声").tag("system")
                    Text("Qwen3-TTS · 自分の声を再現").tag("qwen")
                }.disabled(!model.canConfigure)
                if model.settings.ttsEngine == "system" {
                    Picker("日本語の声", selection: $model.settings.systemVoiceID) {
                        Text("自動選択").tag("")
                        ForEach(SpeechOutput.voices, id: \.identifier) { Text(SpeechOutput.name($0)).tag($0.identifier) }
                    }.disabled(!model.canConfigure)
                } else {
                    ReferenceSettings(model: model, kind: .voice)
                    TextSetting(title: "参照録音で実際に読んだ全文", text: $model.settings.referenceText, height: 85).disabled(!model.canConfigure)
                    Toggle("参照音声の背景ノイズを軽減", isOn: $model.settings.reduceReferenceNoise).disabled(!model.canConfigure)
                    Text("声と一緒に再現される背景音を抑えます。声の響きが気になる場合は、オフの音声と比べてください。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("読み上げる声") } footer: { Text("Qwenは10〜20秒の参照音声から声を再現します。参照本文は録音の全文と一致させてください。追加学習は行いません。") }
            Section {
                TextSetting(title: "試聴する文章", text: $model.speechTestText, height: 105)
                Button("この設定で読み上げを試す", systemImage: "play.fill") { model.testSpeech() }.disabled(!model.canConfigure)
            } header: { Text("声を試す") } footer: { Text("この試聴はWebexへ送信しません。Qwenは冒頭を短く区切り、音声ができ次第読み始めます。その後は改行に沿って読み上げ、再生中も次の行を準備します。") }.disabled(!model.canConfigure)
            Section {
                Toggle("返信待ちにソナー音を流す", isOn: $model.settings.waitingSound)
                HStack { Text("ソナー音量"); Slider(value: $model.settings.waitingSoundVolume, in: 0...1).frame(maxWidth: 220) }.disabled(!model.settings.waitingSound)
                Toggle("返信待ちに音声モデルを準備する", isOn: $model.settings.hotStandby)
            } header: { Text("返信待ち") } footer: { Text("約3秒ごとのソナー音が、読み上げ開始と同時に止まります。ホットスタンバイではモデルと参照音声を先に準備します。") }.disabled(!model.canConfigure)
            Section {
                NumberSetting(title: "返信の監視間隔", unit: "ms", value: $model.settings.replyPollMilliseconds)
                NumberSetting(title: "本文更新が止まってから待つ時間", unit: "秒", value: $model.settings.replySettleSeconds)
                NumberSetting(title: "返信の待ち時間", unit: "秒", value: $model.settings.replyTimeoutSeconds)
                DisclosureGroup("返信の判定条件") {
                    Toggle("送信へのスレッド返信だけを読む", isOn: $model.settings.requireThreadedReply)
                    TextSetting(title: "途中表示の先頭フレーズ（1行ずつ）", text: $model.settings.busyPatterns)
                }
            } header: { Text("返信の確認") } footer: { Text("監視は100〜30,000ms、更新停止は2〜60秒、返信の待ち時間は30〜900秒。期限後は再送せず、次の合言葉の待受へ戻ります。最終回答の判定は更新停止に基づく推定です。") }.disabled(!model.canConfigure)
        }.formStyle(.grouped).disabled(!model.canConfigure && !model.referenceRecording)
    }
}
struct ContentSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            SettingsIntro(section: .content, description: "送る内容と、返信の書き方を設定します。")
            Section {
                Toggle("スクショ・OCRを送付", isOn: $model.settings.includeScreen)
                Toggle("送信前に本文と画像を確認", isOn: $model.settings.confirmBeforeSending)
            } header: { Text("送信前の確認") } footer: {
                Text("スクショをオンにした場合だけ前面ウィンドウを取得します。取得できない場合や画面ロック中は、画像とOCRを省いて続行します。送信前確認がオンなら、ロック解除後の確認を待ちます。オフならロック中も送信します。")
            }
            Section {
                TextSetting(title: "通常の送信テンプレート", text: $model.settings.template, height: 300)
                Button("初期テンプレートに戻す") { model.settings.template = MessageTemplate.defaultValue }
            } header: { Text("ボットへの指示") } footer: {
                Text("初期値では日本語・カタカナ・短文改行で返答するよう指示します。二桁以上の数字は「じゅうさんじ」のように、意味に合ったひらがな表記を求めます。")
            }
            Section {
                TextSetting(title: "スレッド返信用テンプレート", text: $model.settings.replyTemplate, height: 100)
                Button("初期の返信テンプレートに戻す") { model.settings.replyTemplate = MessageTemplate.defaultReplyValue }
            } header: { Text("追加の返信") } footer: {
                Text("同じ話題へのユーザ返信として、文脈を引き継ぐよう指示します。送るのはこの指示と新しい文字起こしだけです。直前のボット回答やスクショ・OCRは付けません。")
            }
            Section {
                Text("{{transcript}}：音声文字起こし\n{{ocr}}：OCR文字列\n{{#screen}}…{{/screen}}：スクショが有効なときだけ送る範囲")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            } header: { Text("使える変数") }
        }.formStyle(.grouped).disabled(!model.canConfigure)
    }
}
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
