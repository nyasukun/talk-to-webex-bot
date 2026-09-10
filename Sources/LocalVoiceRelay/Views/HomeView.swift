import SwiftUI
import RelayCore

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
