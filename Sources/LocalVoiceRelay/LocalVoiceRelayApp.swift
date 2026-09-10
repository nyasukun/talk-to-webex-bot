import SwiftUI
import AppKit

@main struct LocalVoiceRelayApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("Talk to Webex bot", id: "main") {
            ContentView(model: model)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.stop()
                    PrivateStorage.clearTransient()
                }
        }
            .defaultSize(width: 1080, height: 780)
            .windowToolbarStyle(.unified)
            .commands {
                CommandGroup(replacing: .newItem) {}
                CommandGroup(replacing: .appSettings) {
                    Button("設定…") {
                        model.showMainWindow?()
                        NotificationCenter.default.post(name: .relayShowSettings, object: nil)
                    }.keyboardShortcut(",")
                }
                CommandGroup(after: .appInfo) {
                    Button("すべて停止") { model.stop() }.keyboardShortcut(".", modifiers: .command)
                }
                CommandGroup(replacing: .help) {
                    Button("不具合を報告…") { model.presentIssueReport() }.disabled(!model.canConfigure)
                }
            }
        MenuBarExtra {
            Text(model.statusTitle)
            Button("アプリを表示") { model.showMainWindow?() }
            if model.canConfigure {
                Button(model.hasUnsavedChanges ? "保存して待受を開始" : "待受を開始") { model.start() }.disabled(model.nextSetupStep != nil)
            } else { Button("停止") { model.stop() } }
            Divider()
            Button("終了") {
                model.stop()
                NSApp.terminate(nil)
            }
        } label: {
            Image(nsImage: StatusIcon.image(for: model.indicator))
                .accessibilityLabel(model.indicator == .receiving ? "指示を受付中" : model.indicator == .sent ? "Webexへ送信済み" : "待機中")
        }
    }
}
