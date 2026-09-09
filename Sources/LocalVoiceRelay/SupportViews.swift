import SwiftUI
import AppKit
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
                Button("あとで") { model.tokenInput = ""; model.showTokenRenewal = false }.keyboardShortcut(.cancelAction).disabled(model.busy)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("保存して接続確認") { Task { await model.saveToken() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(model.busy || model.tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 510).fixedSize(horizontal: false, vertical: true)
            .interactiveDismissDisabled(model.busy).onAppear { focused = true }.onDisappear { model.tokenInput = "" }
    }
}

struct LogsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var log: DiagnosticLog
    @State private var category: LogCategory?
    @State private var errorsOnly = false
    @State private var search = ""
    @State var showTests = false
    @State private var copied = false
    @State private var confirmClear = false
    private var filtered: [LogEntry] {
        log.entries.reversed().filter { entry in
            (category == nil || entry.category == category) && (!errorsOnly || entry.level != .info) &&
            (search.isEmpty || entry.event.message.localizedStandardContains(search) || entry.details.localizedStandardContains(search))
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                ViewThatFits(in: .horizontal) {
                    HStack { Text("処理の履歴").font(.title2.weight(.semibold)); Spacer(); actions }
                    HStack { Text("処理の履歴").font(.title2.weight(.semibold)); Spacer(); actions.labelStyle(.iconOnly) }
                }
                ViewThatFits(in: .horizontal) {
                    HStack { filters; Spacer(); searchField.frame(width: 200) }
                    VStack(alignment: .leading, spacing: 10) { filters; searchField }
                }
                if log.storageFailed { Label("ログの保存に失敗しました。画面内の履歴は確認できます。", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            }.padding(24).background(.bar)
            Divider()
            if showTests {
                ScrollView { diagnosticTests.padding(18) }.frame(maxHeight: 280).background(Color.teal.opacity(0.035))
                Divider()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if filtered.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "list.bullet.rectangle").font(.largeTitle).foregroundStyle(.tertiary)
                            Text("該当するログはありません").foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 70)
                    }
                    ForEach(filtered) { entry in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: entry.level == .error ? "xmark.circle.fill" : entry.level == .warning ? "exclamationmark.triangle.fill" : "circle.fill")
                                .font(.system(size: entry.level == .info ? 6 : 12)).frame(width: 16, height: 18)
                                .foregroundStyle(entry.level == .error ? Color.red : entry.level == .warning ? Color.orange : Color.teal)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(entry.category.rawValue).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(entry.date.formatted(date: .omitted, time: .standard)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                        .help(entry.date.formatted(date: .abbreviated, time: .standard))
                                }
                                Text(entry.event.message).font(.callout).textSelection(.enabled)
                                if !entry.details.isEmpty { Text(entry.details).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled) }
                            }
                        }.padding(.vertical, 12).padding(.horizontal, 24)
                        Divider().padding(.leading, 52)
                    }
                }
            }
            Divider()
            HStack {
                Text("\(filtered.count)件 · このMacに直近500件を保存").font(.caption)
                Spacer()
                Text("本文・宛先・認証情報は記録しません").font(.caption)
            }.foregroundStyle(.secondary).padding(14)
        }.onChange(of: search) { _, _ in copied = false }
            .onChange(of: category) { _, _ in copied = false }
            .onChange(of: errorsOnly) { _, _ in copied = false }
            .onReceive(log.$entries) { _ in copied = false }
            .alert("診断ログを消去しますか？", isPresented: $confirmClear) {
                Button("取り消す", role: .cancel) {}
                Button("消去", role: .destructive) { log.clear() }
            } message: { Text("このMacに保存された履歴を消去します。必要な場合は先にログをコピーしてください。") }
    }
    private var actions: some View {
        HStack {
            Button("不具合を報告", systemImage: "ladybug") { model.presentIssueReport() }
                .disabled(!model.canConfigure).help("停止中に報告用の下書きを開きます")
            Button(showTests ? "テストを閉じる" : "診断テスト", systemImage: "stethoscope") { showTests.toggle() }.help("診断テストを表示・非表示")
            Button(copied ? "コピー済み" : "ログをコピー", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(log.text(filtered), forType: .string); copied = true
            }.disabled(filtered.isEmpty).help("表示中のログをコピー")
            Button("ログを消去", systemImage: "trash") { confirmClear = true }.labelStyle(.iconOnly).help("診断ログを消去").disabled(log.entries.isEmpty)
        }
    }
    private var filters: some View {
        HStack {
            Picker("分類", selection: $category) {
                Text("すべて").tag(nil as LogCategory?)
                ForEach(LogCategory.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
            }.frame(width: 185)
            Toggle("注意・エラーのみ", isOn: $errorsOnly).toggleStyle(.checkbox)
        }
    }
    private var searchField: some View {
        TextField("ログを検索", text: $search).textFieldStyle(.roundedBorder).accessibilityLabel("ログを検索")
    }
    private var diagnosticTests: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("マイクを5秒テスト", systemImage: "mic") { model.testMicrophone() }.disabled(!model.canConfigure || model.permissionSnapshot.microphone != .allowed)
                Button("ローカル環境を診断", systemImage: "desktopcomputer") { Task { await model.checkLocal() } }.disabled(!model.canConfigure)
                Spacer(minLength: 0)
            }
            if let progress = model.microphoneTestProgress {
                ProgressView("5秒間のテスト録音", value: progress).font(.caption)
            }
            HStack(spacing: 10) {
                Label("マイク入力", systemImage: "mic").font(.caption).foregroundStyle(.secondary)
                ProgressView(value: Double(model.level)).frame(width: 120).accessibilityLabel("診断中のマイク入力レベル")
                Spacer()
                Text(model.phase.rawValue).font(.caption).foregroundStyle(.secondary)
            }
            Text(model.detail).font(.callout).foregroundStyle(model.phase == .error ? Color.orange : Color.primary).textSelection(.enabled)
            if !model.diagnostics.isEmpty { Text(model.diagnostics).font(.caption).textSelection(.enabled) }
            Text(model.audioStatus).font(.caption).foregroundStyle(.secondary)
            if !model.recognizedInput.isEmpty {
                Text("直近の認識結果（保存しません）").font(.caption.weight(.medium))
                Text(model.recognizedInput).font(.callout).textSelection(.enabled).lineLimit(3)
            }
            HStack {
                TextField("接続テストで送る指示", text: $model.testInput)
                Button("送信内容を確認") { model.prepareTextTest() }.disabled(!model.canConfigure)
            }
            Text("マイクテストは送信しません。接続テストは宛先と本文を確認してから送信します。").font(.caption).foregroundStyle(.secondary)
        }
    }
}
