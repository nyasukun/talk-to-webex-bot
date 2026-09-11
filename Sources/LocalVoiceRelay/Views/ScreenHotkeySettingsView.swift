import SwiftUI
import RelayCore

struct ScreenHotkeySettingsView: View {
    @ObservedObject var model: AppModel
    @State var expandedIDs = Set<UUID>()
    @State private var search = ""
    var body: some View {
        Form {
            SettingsIntro(section: .screenHotkeys, description: L10n.text("ホットキーで前面ウィンドウの画像・OCR・プロンプトをWebexへ送ります。音声入力や待受の開始は不要です。"))
            Section {
                LabeledContent(L10n.text("送信先のDM"), value: model.savedSettings.roomTitle.isEmpty ? L10n.text("宛先を選択してください") : model.savedSettings.roomTitle)
                LabeledContent(L10n.text("画面収録"), value: model.permissionSnapshot.screen ? L10n.text("許可済み") : L10n.text("未許可"))
                if !model.permissionSnapshot.screen {
                    Button(L10n.text("画面収録の許可を設定")) { model.requestScreenPermission() }.disabled(!model.canConfigure)
                }
                if !model.hotkeyErrors.isEmpty {
                    Label(L10n.text("登録できないホットキーがあります。該当するユースケースのキーを変更してください。"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text(L10n.text("アプリ起動中に、対象ウィンドウを前面にしてキーを押してください。初期設定は直接送信・読み上げオフです。変更は「変更を保存」で適用します。"))
            }
            Section {
                TextField(L10n.text("ユースケースを検索"), text: $search)
                ForEach($model.settings.screenUseCases) { $useCase in
                    if search.isEmpty || useCase.name.localizedStandardContains(search) || useCase.prompt.localizedStandardContains(search) {
                        Button {
                            if expandedIDs.contains(useCase.id) { expandedIDs.remove(useCase.id) }
                            else { expandedIDs.insert(useCase.id) }
                        } label: {
                            HStack {
                                Image(systemName: expandedIDs.contains(useCase.id) ? "chevron.down" : "chevron.right")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(useCase.name).foregroundStyle(useCase.enabled ? Color.primary : Color.secondary)
                                Spacer()
                                if model.hotkeyErrors[useCase.id] != nil { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                                if useCase.readReplies { Image(systemName: "speaker.wave.2").foregroundStyle(.secondary) }
                                Text(useCase.hotkey?.title ?? L10n.text("キー未設定")).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(!model.canConfigure)
                        if expandedIDs.contains(useCase.id) {
                            ScreenUseCaseEditor(useCase: $useCase, error: model.hotkeyErrors[useCase.id],
                                duplicate: { model.duplicateScreenUseCase(id: useCase.id) },
                                remove: { model.removeScreenUseCase(id: useCase.id) }).disabled(!model.canConfigure)
                        }
                    }
                }
                Button(L10n.text("ユースケースを追加"), systemImage: "plus") {
                    model.addScreenUseCase()
                    search = ""
                    if let id = model.settings.screenUseCases.last?.id { expandedIDs.insert(id) }
                }
                    .disabled(!model.canConfigure)
            } footer: {
                Text(L10n.text("登録数にアプリ側の上限はありません。複製したユースケースには、新しいホットキーを割り当ててください。削除した初期ユースケースは再起動しても復元されません。"))
            }
            Section {
                Text(L10n.text("Raycastに talk と入力すると、ユースケースが検索結果に直接表示されます。選んでEnterを押すと実行します。"))
                    .font(.callout)
                Text(L10n.text("初回だけ、RaycastのSettings → Extensions → ＋ → Add Script Directoryで次のフォルダを登録してください。"))
                    .font(.caption)
                Text(model.raycastBridge.scriptsDirectory.path).font(.caption).textSelection(.enabled)
                if !model.raycastStatus.isEmpty { Text(model.raycastStatus).font(.caption).foregroundStyle(.secondary) }
            } header: { Text("Raycast") } footer: {
                Text(L10n.text("処理中の再入力は受け付けません。画面を取得できないときは送信を止めます。読み上げオフの返信はWebexで確認してください。"))
            }
        }.formStyle(.grouped)
    }
}

private struct ScreenUseCaseEditor: View {
    @Binding var useCase: ScreenUseCase
    let error: String?
    let duplicate: () -> Void
    let remove: () -> Void

    private var shortcut: Binding<ScreenHotkey> {
        Binding(get: { useCase.hotkey ?? ScreenHotkey() }, set: { useCase.hotkey = $0 })
    }

    var body: some View {
        Toggle(L10n.text("有効"), isOn: $useCase.enabled)
        TextField(L10n.text("ユースケース名"), text: $useCase.name)
        Toggle(L10n.text("ホットキーを割り当てる"), isOn: Binding(get: { useCase.hotkey != nil }, set: {
            useCase.hotkey = $0 ? ScreenHotkey() : nil
        }))
        if useCase.hotkey != nil {
            HStack {
                Toggle("⌃ Control", isOn: shortcut.control)
                Toggle("⌥ Option", isOn: shortcut.option)
                Toggle("⇧ Shift", isOn: shortcut.shift)
                Toggle("⌘ Command", isOn: shortcut.command)
            }.toggleStyle(.checkbox)
            Picker(L10n.text("キー"), selection: shortcut.keyCode) {
                ForEach(ScreenHotkey.keys, id: \.code) { key in Text(key.label).tag(key.code) }
            }
            Text(L10n.text("キー名は標準の英字配列上の位置です。別の配列では同じ位置のキーを使います。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        TextSetting(title: L10n.text("プロンプト"), text: $useCase.prompt, height: 110)
        Toggle(L10n.text("返信を読み上げる"), isOn: $useCase.readReplies)
        if useCase.readReplies {
            Picker(L10n.text("読み上げの言語"), selection: $useCase.speechLanguage) {
                ForEach(AppLanguage.allCases) { language in Text(language.name).tag(language) }
            }
            Text(L10n.text("音声方式・音量・返信待ちの設定は「読み上げ・返信」と共通です。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        Toggle(L10n.text("送信前に本文と画像を確認"), isOn: $useCase.confirmBeforeSending)
        HStack {
            Button(L10n.text("複製"), action: duplicate)
            Spacer()
            Button(L10n.text("削除"), role: .destructive, action: remove)
        }
    }
}
