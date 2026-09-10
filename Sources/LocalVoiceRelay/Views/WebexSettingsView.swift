import SwiftUI
import RelayCore

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
                            HStack {
                                if index == 0 { Text(model.roomsLoading ? "宛先を探しています…" : "一致する宛先がありません").font(.callout).foregroundStyle(.secondary) }
                                Spacer()
                            }.frame(height: 49)
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
