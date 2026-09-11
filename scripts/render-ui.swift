// Render source views with generic data. No microphone, screen capture, credentials or network.
import SwiftUI
import AppKit
import RelayCore

@main struct RenderInterface {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.applicationIconImage = NSImage(contentsOfFile: "Resources/AppIcon.icns")
        let language: AppLanguage = CommandLine.arguments.contains("--english") ? .english : .japanese
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(language == .english ? ".build/ui/en" : ".build/ui")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = AppModel(preview: true, openPortal: { _ in true })
        model.changeLanguage(to: language)
        model.authenticationSucceeded()
        model.settings.roomTitle = language == .english ? "Assistant" : "アシスタント"
        model.settings.roomID = "sample-room"
        model.settings.pythonPath = "/usr/bin/true"
        model.settings.asrModelPath = root.path
        model.rooms = (1...5).map { Room(id: "sample-\($0)", title: "\(model.settings.roomTitle) \($0)", lastActivity: "2026-01-01T09:00:00Z") }
        model.roomSearchStatus = language == .english ? "5 results · Recent activity first" : "5件 · 最近のやりとり順"
        model.logs.record(.launched)
        model.logs.record(.replyProgress, category: .webex, metrics: [.polls: 15, .updates: 1])
        model.logs.record(.speechCompleted, category: .speech)
        try await render(IssueReportView(draft: IssueReport.draft(settings: model.settings, phase: model.phase, permissions: model.permissionSnapshot, entries: model.logs.entries)), name: "issue-report", size: NSSize(width: 748, height: 688), root: root)
        try await render(RelaySidebarView(model: model, selection: .constant(.home)), name: "sidebar", size: NSSize(width: 232, height: 780), root: root)
        for section in [AppSection.home, .webex, .input, .output, .content, .permissions, .advanced, .logs] {
            try await render(ContentView(model: model, selection: section), name: section.id, size: NSSize(width: 1080, height: 780), root: root)
        }
        try await render(ContentView(model: model, selection: .home), name: "home-dark", size: NSSize(width: 1080, height: 780), root: root, dark: true)
        model.settings.ttsEngine = "qwen"
        try await render(ContentView(model: model, selection: .output), name: "qwen-noise-control", size: NSSize(width: 880, height: 650), root: root)
        for (index, group) in SpeechParameter.Group.allCases.enumerated() {
            try await render(Form { SpeechQualitySettingsView(model: model, expandedGroups: [group]) }.formStyle(.grouped),
                             name: "speech-quality-\(index)", size: NSSize(width: 680, height: 850), root: root)
        }
        model.settings.ttsEngine = "system"
        try await render(TokenRenewalView(model: model), name: "token-renewal", size: NSSize(width: 570, height: 560), root: root)
        for section in [AppSection.home, .webex, .input, .output, .content, .logs] {
            try await render(ContentView(model: model, selection: section), name: section.id + "-compact", size: NSSize(width: 880, height: 650), root: root)
        }
        model.microphoneTestProgress = 0.6
        model.level = 0.35
        model.diagnostics = "話者類似度 0.820 / 登録した声を優先"
        try await render(LogsView(model: model, log: model.logs, showTests: true), name: "logs-tests", size: NSSize(width: 646, height: 650), root: root)
        model.listening = true; model.phase = .listening; model.indicator = .receiving
        model.detail = "合言葉を受け付けました。続けて指示を話してください。"
        try await render(ContentView(model: model), name: "home-receiving", size: NSSize(width: 880, height: 650), root: root)
        model.listening = false; model.phase = .stopped
        var settings = model.settings
        settings.includeScreen = true
        let body = try MessageTemplate.render(settings.template, transcript: "接続確認です。", ocr: nil, screen: false)
        let omitted = AppModel.Draft(body: body, screen: nil, settings: settings, thread: nil)
        try await render(DraftView(model: model, draft: omitted), name: "draft-omitted", size: NSSize(width: 762, height: 702), root: root)
        settings.includeScreen = false
        let threadBody = try MessageTemplate.render(settings.replyTemplate, transcript: "午後の予定だけ教えてください。", ocr: nil, screen: false)
        let target = ThreadReplyTarget(message: Message(id: "sample-reply", roomId: "sample-room", text: "午前は資料を確認します。午後は作業を進めます。"))
        let thread = AppModel.Draft(body: threadBody, screen: nil, settings: settings, thread: target)
        try await render(DraftView(model: model, draft: thread), name: "draft-thread", size: NSSize(width: 762, height: 702), root: root)
        let unconfigured = AppModel(preview: true, openPortal: { _ in true })
        unconfigured.changeLanguage(to: language)
        try await render(ContentView(model: unconfigured), name: "home-setup", size: NSSize(width: 880, height: 650), root: root)
        for (name, state) in [("idle", RelayIndicator.idle), ("receiving", .receiving), ("sent", .sent)] {
            let image = StatusIcon.image(for: state)
            let data = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            try data.write(to: root.appendingPathComponent("status-\(name).png"))
        }
        print("Rendered generic UI previews in .build/ui")
    }
    @MainActor static func render<V: View>(_ view: V, name: String, size: NSSize, root: URL, dark: Bool = false) async throws {
        let hosting = NSHostingView(rootView: view.environment(\.locale, L10n.language.locale).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -12000, y: -12000))
        window.orderFrontRegardless()
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(nanoseconds: 250_000_000)
        hosting.layoutSubtreeIfNeeded()
        // Native split-view sidebars may live beside the hosting view in the window hierarchy.
        let surface = window.contentView?.superview ?? hosting
        surface.layoutSubtreeIfNeeded()
        guard let bitmap = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) else { fatalError("No bitmap") }
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
        try data.write(to: root.appendingPathComponent(name).appendingPathExtension("png"))
        window.orderOut(nil)
    }
}
