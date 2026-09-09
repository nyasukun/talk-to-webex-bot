import SwiftUI
import AppKit
import RelayCore

enum AppSection: String, CaseIterable, Identifiable {
    case home = "ホーム", webex = "Webex", input = "音声入力", output = "読み上げ・返信", content = "送信内容", permissions = "権限", advanced = "詳細設定", logs = "ログ"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .home: return "waveform"
        case .webex: return "bubble.left.and.bubble.right.fill"
        case .input: return "mic.fill"
        case .output: return "speaker.wave.2.fill"
        case .content: return "text.bubble.fill"
        case .permissions: return "hand.raised.fill"
        case .advanced: return "gearshape.fill"
        case .logs: return "list.bullet.rectangle"
        }
    }
    var color: Color {
        switch self {
        case .home, .webex: return .teal
        case .input: return .orange
        case .output: return .purple
        case .content: return .blue
        case .permissions: return .indigo
        case .advanced, .logs: return .gray
        }
    }
    var isSetting: Bool { self != .home && self != .logs }
    func matches(_ search: String) -> Bool {
        let terms: String
        switch self {
        case .home: terms = "開始 停止 待受 会話"
        case .webex: terms = "API Key パスワード キーチェーン トークン 認証 DM 宛先"
        case .input: terms = "合言葉 マイク 話者 録音 常時 ロック スリープ"
        case .output: terms = "TTS Qwen 声 再生 ソナー ポーリング 監視 タイムアウト"
        case .content: terms = "スクショ 画像 OCR プロンプト テンプレート スレッド 確認"
        case .permissions: terms = "許可 画面収録 マイク"
        case .advanced: terms = "Python モデル インストール 保存先 環境"
        case .logs: terms = "テスト エラー 診断 履歴 不具合 報告 Issue サポート"
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || (rawValue + " " + terms).localizedStandardContains(query)
    }
}

enum RelaySheet: Identifiable {
    case draft(AppModel.Draft), token, report(String)
    var id: String {
        switch self { case .draft(let draft): return draft.id.uuidString; case .token: return "token"; case .report: return "report" }
    }
}

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: AppModel
    @State var selection: AppSection? = .home
    private var section: AppSection { selection ?? .home }
    private var sheet: Binding<RelaySheet?> {
        Binding(get: {
            if let draft = model.draft { return .draft(draft) }
            if model.showTokenRenewal { return .token }
            return model.issueReportDraft.map(RelaySheet.report)
        }, set: { value in if value == nil { model.showTokenRenewal = false; model.issueReportDraft = nil } })
    }
    var body: some View {
        NavigationSplitView {
            RelaySidebarView(model: model, selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 232, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if model.tokenRecovery.needsRenewal && section != .webex {
                    HStack(spacing: 10) {
                        Image(systemName: "key.fill").foregroundStyle(.orange)
                        Text("Webexの認証を更新してください。")
                        Spacer()
                        Button("API Keyを入力") { model.presentTokenRenewal() }
                    }.font(.callout).padding(14).background(Color.orange.opacity(0.08))
                    Divider()
                }
                if model.phase == .error && section != .home && !model.tokenRecovery.needsRenewal {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(model.detail).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(14).background(Color.orange.opacity(0.08))
                    Divider()
                }
                detail
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(section.rawValue)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if model.listening || ![.stopped, .error].contains(model.phase) {
                        Button("停止", systemImage: "stop.fill") { model.stop() }.help("マイク・読み上げ・返信監視を停止")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if section.isSetting {
                    VStack(spacing: 0) {
                        Divider()
                        HStack(spacing: 12) {
                            Image(systemName: model.hasUnsavedChanges ? "circle.fill" : "checkmark.circle")
                                .foregroundStyle(model.hasUnsavedChanges ? Color.orange : Color.secondary).font(.caption)
                            Text(model.canConfigure ? (model.hasUnsavedChanges ? "保存していない変更があります" : "設定は保存済みです") : "変更するには、上部の「停止」を押してください")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if model.hasUnsavedChanges {
                                Button("変更を取り消す") { model.discardSettingsChanges() }.disabled(!model.canConfigure)
                            }
                            Button("変更を保存") { model.saveSettings() }.buttonStyle(.borderedProminent)
                                .keyboardShortcut("s").disabled(!model.canConfigure || !model.hasUnsavedChanges)
                        }.padding(.horizontal, 24).padding(.vertical, 13)
                    }.background(.bar)
                }
            }
        }
        .tint(.teal)
        .frame(minWidth: 880, minHeight: 650)
        .sheet(item: sheet) { presentation in
            switch presentation {
            case .draft(let draft): DraftView(model: model, draft: draft).interactiveDismissDisabled()
            case .token: TokenRenewalView(model: model)
            case .report(let draft): IssueReportView(draft: draft)
            }
        }
        .onAppear {
            guard !model.isPreview else { return }
            model.showMainWindow = { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            model.refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: .relayShowSettings)) { _ in selection = .webex }
    }
    @ViewBuilder private var detail: some View {
        switch section {
        case .home: HomeView(model: model) { selection = $0 }
        case .webex: WebexSettingsView(model: model)
        case .input: InputSettingsView(model: model)
        case .output: OutputSettingsView(model: model)
        case .content: ContentSettingsView(model: model)
        case .permissions: PermissionSettingsView(model: model)
        case .advanced: AdvancedSettingsView(model: model)
        case .logs: LogsView(model: model, log: model.logs)
        }
    }
}

struct RelaySidebarView: View {
    @ObservedObject var model: AppModel
    @Binding var selection: AppSection?
    @State private var search = ""
    var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit()
                        .frame(width: 44, height: 44).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Talk to Webex bot").font(.system(size: 13, weight: .semibold))
                        Text("このMacの音声アシスタント").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 18)
                TextField("項目を検索", text: $search).textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 12).padding(.bottom, 12).accessibilityLabel("設定項目を検索")
                List(selection: $selection) {
                    if !AppSection.allCases.contains(where: { $0.matches(search) }) {
                        Text("一致する項目がありません").font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        navigationRow(.home)
                    }
                    Section("設定") {
                        ForEach(AppSection.allCases.filter(\.isSetting)) { navigationRow($0) }
                    }
                    Section("サポート") {
                        navigationRow(.logs)
                        if AppSection.logs.matches(search) {
                            Button("不具合を報告", systemImage: "ladybug") { model.presentIssueReport() }
                                .disabled(!model.canConfigure).help("停止中に報告用の下書きを開きます")
                        }
                    }
                }.listStyle(.sidebar)
                HStack(spacing: 7) {
                    Circle().fill(model.phase == .error ? Color.orange : model.listening ? Color.teal : Color.gray).frame(width: 6, height: 6)
                    Text(model.statusTitle).font(.caption).lineLimit(1)
                    Spacer()
                    Text("v\(IssueReport.version(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)) · \(IssueReport.version(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }.padding(16)
            }
    }
    @ViewBuilder private func navigationRow(_ item: AppSection) -> some View {
        if item.matches(search) {
            NavigationLink(value: item) {
                HStack(spacing: 10) {
                    Image(systemName: item.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 25, height: 25).background(item.color.gradient, in: RoundedRectangle(cornerRadius: 6))
                    Text(item.rawValue).font(.system(size: 13))
                }.padding(.vertical, 3)
            }
        }
    }
}

extension Notification.Name { static let relayShowSettings = Notification.Name("relayShowSettings") }

struct HomeView: View {
    @ObservedObject var model: AppModel
    let navigate: (AppSection) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .top, spacing: 18) {
                        Image(systemName: model.phase == .speaking ? "speaker.wave.2" : "waveform")
                            .font(.system(size: 28, weight: .medium)).foregroundStyle(.teal)
                            .frame(width: 64, height: 64).background(Color.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.phase == .stopped ? "声で、会話を始めましょう" : model.statusTitle).font(.system(size: 24, weight: .semibold))
                            Text(model.detail).font(.callout).foregroundStyle(model.phase == .error ? Color.orange : Color.secondary)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 12) {
                        Button { model.start() } label: { Label(model.hasUnsavedChanges ? "保存して待受を開始" : "待受を開始", systemImage: "mic.fill").frame(minWidth: 112) }
                            .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canConfigure || model.nextSetupStep != nil)
                        if model.listening || ![.stopped, .error].contains(model.phase) {
                            Button("停止") { model.stop() }.controlSize(.large)
                        }
                        Spacer()
                        if model.busy || [.preparing, .sending, .waiting].contains(model.phase) || (model.phase == .recognizing && !model.listening) {
                            ProgressView().controlSize(.small).accessibilityLabel("処理中")
                        }
                        Image(systemName: "mic").foregroundStyle(.secondary)
                        ProgressView(value: Double(model.level)).frame(width: 90).accessibilityLabel("マイク入力レベル")
                    }
                }.padding(24).relayCard()
                if let step = model.nextSetupStep, !model.listening { setupCard(step) }
                HStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("送信先のDM").font(.caption).foregroundStyle(.secondary)
                        Text(model.settings.roomTitle.isEmpty ? "宛先を選択してください" : model.settings.roomTitle).font(.headline).lineLimit(1)
                    }
                    Spacer()
                    Button("変更") { navigate(.webex) }
                }.padding(16).relayCard()
                HStack(spacing: 16) {
                    feature("スクショ・OCR", symbol: "rectangle.dashed.badge.record", enabled: model.settings.includeScreen, section: .content)
                    feature("送信前確認", symbol: "checkmark.bubble", enabled: model.settings.confirmBeforeSending, section: .content)
                    feature("返信読み上げ", symbol: "speaker.wave.2", enabled: model.settings.readReplies, section: .output)
                }
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("会話").font(.headline)
                        Spacer()
                        if !model.transcript.isEmpty || !model.reply.isEmpty {
                            Button("表示を消去", systemImage: "xmark.circle") { model.clearConversation() }
                                .font(.caption).disabled(!model.canConfigure)
                                .help("この画面の会話とスレッド返信先を消去します。Webexのメッセージは残ります")
                        }
                    }
                    if model.transcript.isEmpty && model.reply.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 28)).foregroundStyle(.tertiary)
                            Text("会話がここに表示されます").font(.headline)
                            Text("待受は停止するまで続きます。\n合言葉のあとに、指示を話してください。")
                                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.vertical, 36)
                    } else {
                        if !model.transcript.isEmpty { conversationBlock("あなた", text: model.transcript, color: .teal) }
                        if !model.reply.isEmpty { conversationBlock("Webexからの返信", text: model.reply, color: .purple) }
                        if model.lastReplyTarget != nil {
                            Label("返信用の合言葉で、この会話のスレッドへ返せます", systemImage: "arrowshape.turn.up.left").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(22).relayCard()
                HStack {
                    Label("音声処理はこのMacで完結", systemImage: "desktopcomputer").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("テスト・ログを開く") { navigate(.logs) }.buttonStyle(.link).font(.caption)
                }
            }.frame(maxWidth: 820).padding(28).frame(maxWidth: .infinity)
        }
    }
    @ViewBuilder private func setupCard(_ step: AppModel.SetupStep) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "checklist").foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 4) {
                Text("次の準備").font(.caption).foregroundStyle(.secondary)
                Text(setupDescription(step)).font(.callout)
            }
            Spacer()
            switch step {
            case .permissions: Button("権限を確認") { navigate(.permissions) }
            case .token:
                if model.keychainNeedsAccess {
                    Button("保存済みトークンを読み込む") { Task { await model.authorizeSavedToken() } }.disabled(!model.canConfigure)
                } else { Button("Webexを設定") { navigate(.webex) } }
            case .destination: Button("DMを選ぶ") { navigate(.webex) }
            case .models: Button("音声環境を確認") { navigate(.advanced) }
            }
        }.padding(16).relayCard()
    }
    private func setupDescription(_ step: AppModel.SetupStep) -> String {
        switch step {
        case .permissions: return "マイクと、使う機能の権限を確認してください。"
        case .token: return model.keychainNeedsAccess ? "キーチェーンのアクセス確認が必要です。" : "Webexの認証を確認してください。"
        case .destination: return "声で話しかける相手のDMを選んでください。"
        case .models: return "このMacの音声処理環境を準備してください。"
        }
    }
    private func feature(_ title: String, symbol: String, enabled: Bool, section: AppSection) -> some View {
        Button { navigate(section) } label: {
        HStack(spacing: 7) {
            Image(systemName: symbol).foregroundStyle(enabled ? Color.teal : Color.secondary)
            Text(title).font(.caption)
            Text(enabled ? "オン" : "オフ").font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 12).relayCard()
        }.buttonStyle(.plain).help("\(title)の設定を開く")
    }
    private func conversationBlock(_ title: String, text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(color)
            Text(text).textSelection(.enabled).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(16).background(color.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    }
}

extension View {
    func relayCard() -> some View {
        self.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.055)))
    }
}

struct DraftView: View {
    @ObservedObject var model: AppModel
    let draft: AppModel.Draft
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("送信内容を確認", systemImage: "paperplane").font(.title2.bold())
            Text("送信先  ·  \(draft.settings.roomTitle)").font(.headline)
            if draft.screenOmitted {
                Label("画面を取得できないため、画像とOCRを省いて送信します。", systemImage: "rectangle.slash").font(.callout).foregroundStyle(.secondary)
            }
            if let thread = draft.thread {
                VStack(alignment: .leading, spacing: 6) {
                    Label("スレッドへの返信", systemImage: "arrowshape.turn.up.left.fill").font(.callout.weight(.semibold)).foregroundStyle(.teal)
                    Text("返信先の確認用です。以下の引用は送信本文に含めません。").font(.caption).foregroundStyle(.secondary)
                    Text(thread.preview).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).relayCard()
            } else { Text("通常のDMメッセージ").font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let screen = draft.screen, let image = NSImage(data: screen.png) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 260).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    Text(draft.body).textSelection(.enabled).lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(18)
            }.relayCard()
            HStack {
                Text(draft.screen == nil ? "表示中の本文を送信します。" : "表示中の本文と画像を送信します。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取り消す") { model.cancelDraft() }.keyboardShortcut(.cancelAction)
                Button("Webexへ送信") { model.confirmDraft() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 710, height: 650)
    }
}
