import AppKit
import RelayCore

extension AppModel {
    func registerScreenHotkeys() {
        guard !isPreview else { return }
        hotkeyErrors = globalHotkeys.replace(with: savedSettings.screenUseCases) { [weak self] id in
            self?.runScreenUseCase(id: id)
        }
        do {
            try raycastBridge.publish(savedSettings)
            raycastStatus = L10n.text("Raycast用の一覧は保存済み設定と同期しています。")
        } catch { raycastStatus = L10n.text("Raycast用の一覧を更新できません。設定を保存し直してください。") }
    }

    var canRunScreenUseCase: Bool {
        guard !busy, !referenceRecording, !screenUseCaseActive, voiceInteraction == nil else { return false }
        return [.stopped, .error].contains(phase) || (listening && phase == .listening && indicator == .idle)
    }

    func runRaycastUseCase(_ request: RaycastBridge.Request) throws {
        guard canRunScreenUseCase else { throw RelayError.message(L10n.text("別の操作を処理中です。完了または停止してから実行してください。")) }
        guard savedSettings.screenUseCases.contains(where: { $0.id == request.useCaseID && $0.enabled }) else {
            throw RelayError.message(L10n.text("このユースケースは削除または無効化されています。Raycastの一覧を更新してください。"))
        }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == request.expectedBundleID else {
            throw ScreenContext.Unavailable.changedWindow
        }
        runScreenUseCase(id: request.useCaseID, expectedBundleID: request.expectedBundleID)
    }

    func runScreenUseCase(id: UUID, expectedBundleID: String? = nil) {
        guard canRunScreenUseCase,
              let useCase = savedSettings.screenUseCases.first(where: { $0.id == id && $0.enabled }) else { return }
        let snapshot = savedSettings
        let resumeListening = listening
        stop()
        // Pause an existing voice standby, but never start the microphone for a screen-only session.
        listening = resumeListening
        screenUseCaseActive = true
        phase = .preparing
        indicator = .receiving
        detail = L10n.text("「\(useCase.name)」の画面とOCRを取得しています。")
        launch { [self] run in
            try ScreenUseCase.validate([useCase])
            guard !snapshot.roomID.isEmpty else { throw RelayError.message(L10n.text("送信先DMを選んでください。")) }
            if let expectedBundleID, NSWorkspace.shared.frontmostApplication?.bundleIdentifier != expectedBundleID {
                throw ScreenContext.Unavailable.changedWindow
            }
            let screen = try await captureScreen()
            try Task.checkCancellation()
            guard run == epoch else { return }
            logs.record(.screenCaptured, category: .permissions)
            let draft = try screenDraft(useCase: useCase, screen: screen, settings: snapshot)
            transcript = useCase.prompt
            reply = ""
            if useCase.confirmBeforeSending { presentDraft(draft) }
            else { try await send(draft, run: run) }
        }
    }

    func screenDraft(useCase: ScreenUseCase, screen: ScreenContext, settings: Settings) throws -> Draft {
        var snapshot = settings
        snapshot.includeScreen = true
        snapshot.readReplies = useCase.readReplies
        snapshot.confirmBeforeSending = useCase.confirmBeforeSending
        if useCase.readReplies {
            snapshot.changeLanguage(to: useCase.speechLanguage)
            try snapshot.validateSpeech()
        }
        return Draft(body: try useCase.render(ocr: screen.ocr), screen: screen, settings: snapshot, thread: nil)
    }

    func addScreenUseCase() {
        guard canConfigure else { return }
        settings.screenUseCases.append(ScreenUseCase(name: L10n.text("新しいユースケース"),
            prompt: L10n.text("添付した画面とOCRの内容を説明してください。")))
    }

    func duplicateScreenUseCase(id: UUID) {
        guard canConfigure, var copy = settings.screenUseCases.first(where: { $0.id == id }) else { return }
        copy.id = UUID()
        copy.name += L10n.text(" のコピー")
        copy.hotkey = nil
        settings.screenUseCases.append(copy)
    }

    func removeScreenUseCase(id: UUID) {
        guard canConfigure else { return }
        settings.screenUseCases.removeAll { $0.id == id }
    }
}
