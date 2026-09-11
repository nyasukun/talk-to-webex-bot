// Draft preparation, voice continuation and Webex delivery.
import AppKit
import RelayCore

extension AppModel {
    struct Draft: Identifiable {
        let id = UUID()
        let body: String
        let screen: ScreenContext?
        let settings: Settings
        let thread: ThreadReplyTarget?
        var screenOmitted: Bool { settings.includeScreen && screen == nil }
    }
    struct Delivery {
        let client: WebexClient
        let sent: Message
        let baseline: [Message]
        let settings: Settings
    }
    var voiceDelivery: Delivery? { voiceInteraction?.delivery }
    var voiceSentIDs: Set<String> { voiceInteraction?.sentIDs ?? [] }

    func prepareVoiceCommand(_ command: String, mode: VoiceMode, speech: SpeechInterval, run: UUID) async throws {
        guard run == epoch else { return }
        voiceInteraction = VoiceInteraction(command: command, speech: speech, seconds: settings.continuationSeconds, mode: mode)
        transcript = command
        try await prepare(command: command, run: run, forceConfirmation: false, mode: mode)
    }
    func appendVoiceCommand(_ text: String, speech: SpeechInterval, run: UUID) async throws {
        guard run == epoch, var interaction = voiceInteraction,
              let draft = try interaction.append(text, speech: speech) else { return }
        voiceInteraction = interaction
        commitVoiceInputCheckpoint()
        transcript = interaction.text
        if !draft.settings.confirmBeforeSending { try await send(draft, run: run) }
        guard run == epoch else { return }
        showContinuationStatus()
    }
    private func showContinuationStatus() {
        phase = .listening
        indicator = voiceDelivery == nil ? .receiving : .sent
        detail = L10n.text("続きの発話を受け付けています。最後に声が出てから設定した無音時間で確定します。")
    }
    func finishVoiceInput(run: UUID) async throws {
        guard run == epoch else { return }
        voiceInteraction?.closeInput()
        recorder.stop()
        level = 0
        let prepared = voiceInteraction?.draft, delivery = voiceDelivery, sentIDs = voiceSentIDs.union(voiceScreenRequestIDs)
        voiceInteraction = nil
        phase = .waiting
        if let prepared, prepared.settings.confirmBeforeSending {
            presentDraft(prepared)
            return
        }
        if let delivery, delivery.settings.readReplies {
            try await monitor(client: delivery.client, sent: delivery.sent, baseline: delivery.baseline,
                              settings: delivery.settings, run: run, supersededRequestIDs: sentIDs.subtracting([delivery.sent.id]))
        }
        guard run == epoch else { return }
        try await resumeAfterInteraction(run: run)
    }
    func prepare(command: String, run: UUID, forceConfirmation: Bool, mode: VoiceMode = .message) async throws {
        phase = .preparing
        detail = L10n.text("送信内容を準備しています。")
        var snapshot = settings
        let target: ThreadReplyTarget?
        if mode == .threadReply {
            guard let previous = lastReplyTarget else { throw RelayError.message(L10n.text("返信先がありません。このアプリで相手の返信を受け取ってから、返信用の合言葉を話してください。")) }
            try previous.require(roomID: snapshot.roomID)
            target = previous
            snapshot.template = snapshot.replyTemplate
            snapshot.includeScreen = false
        } else { target = nil }
        if snapshot.includeScreen { try Permissions.requireScreen() }
        let screen = try await ScreenAttachment.captureIfAvailable(enabled: snapshot.includeScreen)
        guard run == epoch else { return }
        if screen != nil { logs.record(.screenCaptured, category: .permissions) }
        else if snapshot.includeScreen { logs.record(.screenOmitted, category: .permissions) }
        let body = try MessageTemplate.render(snapshot.template, transcript: command, ocr: screen?.ocr, screen: screen != nil)
        let draft = Draft(body: body, screen: screen, settings: snapshot, thread: target)
        if voiceInteraction != nil {
            voiceInteraction?.setDraft(draft)
            commitVoiceInputCheckpoint()
            if !snapshot.confirmBeforeSending { try await send(draft, run: run) }
            guard run == epoch else { return }
            showContinuationStatus()
            return
        }
        if snapshot.confirmBeforeSending || forceConfirmation {
            presentDraft(draft)
        } else { try await send(draft, run: run) }
    }
    func presentDraft(_ draft: Draft) {
        self.draft = draft
        phase = .confirming
        detail = L10n.text("本文・画像・宛先を確認してください。")
        showMainWindow?()
        if !isPreview { NSApp.activate(ignoringOtherApps: true) }
    }
    func confirmDraft() {
        guard let draft, phase == .confirming else { return }
        self.draft = nil
        launch { [self] run in try await send(draft, run: run) }
    }
    func cancelDraft() {
        let resumeVoice = screenUseCaseActive && listening
        let paused = pausedVoiceInput
        draft = nil
        stop()
        detail = L10n.text("送信を取り消しました。")
        if resumeVoice { resumeVoiceAfterScreenUseCase(paused) }
    }
    func send(_ draft: Draft, run: UUID) async throws {
        let client = try await connection(), snapshot = draft.settings
        guard run == epoch else { return }
        replyMonitoringStatus = snapshot.readReplies ? L10n.text("送信後に返信を監視します。") : L10n.text("返信の読み上げはOFFです。監視しません。")
        logs.record(.sendStarted, category: .webex)
        phase = .sending
        detail = L10n.text("Webexへ送信しています。")
        // Every send has a fresh identity check. Never infer validity from local save time.
        let person = try await client.me()
        guard run == epoch else { return }
        ownID = person.id
        let baseline = snapshot.readReplies ? try await client.messages(roomID: snapshot.roomID) : []
        guard run == epoch else { return }
        let sent = try await client.send(roomID: snapshot.roomID, text: draft.body, png: draft.screen?.png, parentID: draft.thread?.parentID)
        guard run == epoch else { return }
        indicator = .sent
        if draft.thread == nil { lastReplyTarget = nil }
        logs.record(.sendCompleted, category: .webex)
        detail = L10n.text("送信しました。")
        if voiceInteraction != nil {
            voiceInteraction?.recordDelivery(Delivery(client: client, sent: sent, baseline: baseline, settings: snapshot))
            replyMonitoringStatus = snapshot.readReplies ? L10n.text("追加発話の受付後、最後に送ったメッセージの返信だけを監視します。") : L10n.text("返信の読み上げはOFFです。監視しません。")
            beginQueuedScreenUseCase()
            return
        }
        let relatedVoiceRequests = (pausedVoiceInput?.interaction?.sentIDs ?? []).union(pausedVoiceInput?.screenRequestIDs ?? [])
        if pausedVoiceInput?.hasVoiceContext == true { pausedVoiceInput?.screenRequestIDs.insert(sent.id) }
        if snapshot.readReplies {
            try await monitor(client: client, sent: sent, baseline: baseline, settings: snapshot, run: run,
                              supersededRequestIDs: relatedVoiceRequests.union(voiceScreenRequestIDs))
        }
        guard run == epoch else { return }
        try await resumeAfterInteraction(run: run)
    }
}
