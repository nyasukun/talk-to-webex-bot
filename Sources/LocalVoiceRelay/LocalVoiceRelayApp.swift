import RelayCore
import SwiftUI
import AppKit

@main enum RelayEntryPoint {
    @MainActor static func main() {
        if CommandLine.arguments.dropFirst().first == "--run-screen-use-case" {
            exit(RaycastCommand.run(arguments: Array(CommandLine.arguments.dropFirst(2))))
        }
        if CommandLine.arguments.dropFirst().first == "--dispatch-raycast-request" {
            exit(RaycastCommand.dispatchExisting(arguments: Array(CommandLine.arguments.dropFirst(2))))
        }
        LocalVoiceRelayApp.main()
    }
}

struct LocalVoiceRelayApp: App {
    @NSApplicationDelegateAdaptor(RelayApplicationDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("Talk to Webex bot", id: "main") {
            ContentView(model: model)
                .environment(\.locale, model.settings.language.locale)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.stop()
                    model.globalHotkeys.unregister()
                    PrivateStorage.clearTransient()
                }
        }
            .defaultSize(width: 1080, height: 780)
            .windowToolbarStyle(.unified)
            .commands {
                CommandGroup(replacing: .newItem) {}
                CommandGroup(replacing: .appSettings) {
                    Button(L10n.text("設定…")) {
                        model.showMainWindow?()
                        NotificationCenter.default.post(name: .relayShowSettings, object: nil)
                    }.keyboardShortcut(",")
                }
                CommandGroup(after: .appInfo) {
                    Button(L10n.text("すべて停止")) { model.stop() }.keyboardShortcut(".", modifiers: .command)
                }
                CommandGroup(replacing: .help) {
                    Button(L10n.text("不具合を報告…")) { model.presentIssueReport() }.disabled(!model.canConfigure)
                }
            }
        MenuBarExtra {
            Text(model.statusTitle)
            Button(L10n.text("アプリを表示")) { model.showMainWindow?() }
            if model.canConfigure {
                Button(model.hasUnsavedChanges ? L10n.text("保存して待受を開始") : L10n.text("待受を開始")) { model.start() }.disabled(model.nextSetupStep != nil)
            } else { Button(L10n.text("停止")) { model.stop() } }
            Divider()
            Button(L10n.text("終了")) {
                model.stop()
                NSApp.terminate(nil)
            }
        } label: {
            Image(nsImage: StatusIcon.image(for: model.indicator))
                .accessibilityLabel(model.indicator == .receiving ? L10n.text("指示を受付中") : model.indicator == .sent ? L10n.text("Webexへ送信済み") : L10n.text("待機中"))
        }
    }
}
