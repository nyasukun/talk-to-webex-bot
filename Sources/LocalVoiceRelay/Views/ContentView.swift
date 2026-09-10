import SwiftUI
import AppKit
import RelayCore

enum RelaySheet: Identifiable {
    case draft(AppModel.Draft), token, report(String)
    var id: String {
        switch self {
        case .draft(let draft): return draft.id.uuidString
        case .token: return "token"
        case .report: return "report"
        }
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
        }, set: { value in
            if value == nil {
                model.showTokenRenewal = false
                model.issueReportDraft = nil
            }
        })
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
                        Text(L10n.text("Webexの認証を更新してください。"))
                        Spacer()
                        Button(L10n.text("API Keyを入力")) { model.presentTokenRenewal() }
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
            .navigationTitle(section.title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if model.listening || ![.stopped, .error].contains(model.phase) {
                        Button(L10n.text("停止"), systemImage: "stop.fill") { model.stop() }.help(L10n.text("マイク・読み上げ・返信監視を停止"))
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
                            Text(model.canConfigure ? (model.hasUnsavedChanges ? L10n.text("保存していない変更があります") : L10n.text("設定は保存済みです")) : L10n.text("変更するには、上部の「停止」を押してください"))
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if model.hasUnsavedChanges {
                                Button(L10n.text("変更を取り消す")) { model.discardSettingsChanges() }.disabled(!model.canConfigure)
                            }
                            Button(L10n.text("変更を保存")) { model.saveSettings() }.buttonStyle(.borderedProminent)
                                .keyboardShortcut("s").disabled(!model.canConfigure || !model.hasUnsavedChanges)
                        }.padding(.horizontal, 24).padding(.vertical, 13)
                    }.background(.bar)
                }
            }
        }
        .id(model.settings.language)
        .environment(\.locale, model.settings.language.locale)
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
            model.showMainWindow = {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
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

extension Notification.Name { static let relayShowSettings = Notification.Name("relayShowSettings") }
