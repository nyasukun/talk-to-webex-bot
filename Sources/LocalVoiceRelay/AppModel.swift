// Core state machine: settings, permissions, listening, sending and reply monitoring.
// Webex auth and DM search live in AppModelWebex.swift, diagnostics in AppModelDiagnostics.swift,
// reference audio in AppModelReference.swift, derived view state in AppModelPresentation.swift.
// Only this file rotates the epoch (stop() and recoverInput()).
import AppKit
import AVFoundation
import Combine
import RelayCore

@MainActor final class AppModel: ObservableObject {
    enum Phase: String {
        case stopped = "停止"
        case listening = "待受"
        case recording = "録音"
        case recognizing = "認識中"
        case preparing = "送信準備"
        case confirming = "送信前確認"
        case sending = "送信"
        case waiting = "返信待ち"
        case speaking = "読み上げ"
        case error = "エラー"
        var title: String { L10n.key(rawValue) }
    }
    struct Draft: Identifiable {
        let id = UUID()
        let body: String
        let screen: ScreenContext?
        let settings: Settings
        let thread: ThreadReplyTarget?
        var screenOmitted: Bool { settings.includeScreen && screen == nil }
    }
    @Published var settings: Settings {
        didSet {
            if oldValue.language != settings.language {
                L10n.language = settings.language
                refreshLanguagePresentation(from: oldValue.language)
            }
            if oldValue.includeScreen != settings.includeScreen { refreshPermissions() }
            if oldValue.roomID != settings.roomID { lastReplyTarget = nil }
            if oldValue.preventIdleSleep != settings.preventIdleSleep { updateStandbyActivity() }
        }
    }
    @Published var permissionSnapshot: PermissionSnapshot
    @Published var savedSettings: Settings
    @Published var showTokenRenewal = false
    @Published var issueReportDraft: String?
    @Published var tokenBrowserOpened = true
    @Published var tokenValid = false
    @Published var keychainNeedsAccess = false
    @Published var checkingToken = false
    @Published var tokenRecovery = TokenRecovery()
    let logs: DiagnosticLog
    let isPreview: Bool
    let openPortal: (URL) -> Bool
    var hasUnsavedChanges: Bool { settings != savedSettings }
    @Published var phase: Phase = .stopped
    @Published var indicator: RelayIndicator = .idle
    @Published var lastReplyTarget: ThreadReplyTarget?
    @Published var detail = L10n.text("設定を保存して待受を開始してください。")
    @Published var tokenInput = ""
    @Published var tokenStatus = L10n.text("未確認")
    @Published var rooms: [Room] = []
    @Published var query = "" { didSet { if query != oldValue { searchRooms() } } }
    @Published var roomsLoading = false
    @Published var roomSearchStatus = L10n.text("最近のDMを最大5件表示します。")
    @Published var busy = false
    @Published var level: Float = 0
    @Published var microphoneTestProgress: Double?
    @Published var transcript = ""
    @Published var reply = ""
    @Published var replyMonitoringStatus = L10n.text("返信監視はまだ実行していません。")
    @Published var voiceStandbyStatus = L10n.text("音声待機: 未開始")
    @Published var diagnostics = ""
    @Published var audioStatus = L10n.text("マイク未開始")
    @Published var recognizedInput = ""
    @Published var draft: Draft?
    @Published var listening = false { didSet { updateStandbyActivity() } }
    @Published var referenceRecording = false
    @Published var testInput = L10n.text("接続確認です。短く返答してください。")
    static let defaultSpeechTestText: L10n.Message = """
    ウェブエックスの接続を確認しました。
    エーピーアイの確認間隔はひゃくミリ秒です。
    会議はじゅうさんじから始まります。
    今日の予定を順番に説明します。
    午前中は資料を確認してください。
    午後は必要な情報を整理します。
    進み具合は五十パーセントです。
    音量はプラスボタンで調整できます。
    これで最後の文です。
    """
    @Published var speechTestText = L10n.text(defaultSpeechTestText)
    var showMainWindow: (() -> Void)?
    let recorder = AudioRecorder()
    let worker = LocalWorker()
    let speech = SpeechOutput()
    private let waitingSound = WaitingSound()
    private let standbyActivity = StandbyActivity()
    var referenceRecorder: AVAudioRecorder?
    private var lastMeterUpdate = Date.distantPast
    var referenceKind: ReferenceKind = .speaker
    var referenceURL: URL?
    var client: WebexClient?
    var tokenReadTask: Task<String?, Error>?
    var roomSearchTask: Task<Void, Never>?
    var roomSearchID = UUID()
    var ownID = ""
    private var wake = VoiceRouter()
    private var chunks: [AudioRecorder.Chunk] = []
    private var processing = false
    private var inputRevision = UUID()
    // Only stop() and recoverInput() in this file rotate the epoch; extensions may read it.
    private(set) var epoch = UUID()
    private(set) var operation: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var armTimeout: Task<Void, Never>?
    private var inputWatchdog: Task<Void, Never>?
    private var receivedAudio = false
    private var lastInputAt = Date.distantPast
    private var audioRecovery = AudioRecovery()
    var credentialEpoch = UUID()
    var tokenCheckEpoch: UUID?
    private var permissionError = false

    init(preview: Bool = false, openPortal: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        isPreview = preview
        self.openPortal = openPortal
        let previousLanguage = L10n.language
        let initial = preview ? Settings() : PrivateStorage.load()
        settings = initial
        savedSettings = initial
        permissionSnapshot = preview ? PermissionSnapshot(microphone: .allowed, screen: true) : Permissions.snapshot()
        logs = preview ? DiagnosticLog() : DiagnosticLog(file: PrivateStorage.directory.appendingPathComponent("diagnostics/events.json"))
        L10n.language = initial.language
        refreshLanguagePresentation(from: previousLanguage)
        guard !preview else { return }
        logs.record(.launched)
        PrivateStorage.clearTransient()
        refreshPermissions()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkToken(silent: true)
                try? await Task.sleep(nanoseconds: 300_000_000_000)
            }
        }
    }
    func changeLanguage(to language: AppLanguage) {
        guard canConfigure, settings.language != language else { return }
        var updated = settings
        updated.changeLanguage(to: language)
        settings = updated
    }

    private func refreshLanguagePresentation(from previous: AppLanguage) {
        for path in [\AppModel.detail, \.tokenStatus, \.roomSearchStatus, \.replyMonitoringStatus,
                     \.voiceStandbyStatus, \.audioStatus] {
            self[keyPath: path] = L10n.relocalizeStatus(self[keyPath: path], from: previous)
        }
        if speechTestText == L10n.text(Self.defaultSpeechTestText, language: previous) {
            speechTestText = L10n.text(Self.defaultSpeechTestText)
        }
        let testMessage: L10n.Message = "接続確認です。短く返答してください。"
        if testInput == L10n.text(testMessage, language: previous) { testInput = L10n.text(testMessage) }
    }

    private func persistSettings() throws {
        try PrivateStorage.save(settings)
        savedSettings = settings
        logs.record(.settingsSaved)
    }
    private func updateStandbyActivity() {
        guard !isPreview else { return }
        standbyActivity.update(listening: listening, preventSleep: settings.preventIdleSleep)
    }
    func discardSettingsChanges() {
        guard canConfigure else { return }
        settings = savedSettings
        detail = L10n.text("未保存の変更を取り消しました。")
        refreshPermissions()
    }
    func presentIssueReport() {
        guard canConfigure else { return }
        issueReportDraft = IssueReport.draft(settings: settings, phase: phase, permissions: permissionSnapshot, entries: logs.entries)
        showMainWindow?()
    }
    func clearConversation() {
        guard canConfigure else { return }
        transcript = ""
        reply = ""
        recognizedInput = ""
        lastReplyTarget = nil
    }
    func saveSettings() {
        guard canConfigure else { return }
        do {
            try settings.validate()
            try persistSettings()
            detail = L10n.text("設定をこのMacに保存しました。")
            refreshPermissions()
        } catch { fail(error) }
    }
    func refreshPermissions() {
        guard !isPreview else { return }
        let previous = permissionSnapshot
        permissionSnapshot = Permissions.snapshot()
        if previous.microphone != permissionSnapshot.microphone || previous.screen != permissionSnapshot.screen || logs.entries.count <= 1 {
            logs.record(.permissionsChecked, category: .permissions, metrics: [.microphone: permissionSnapshot.microphone == .allowed ? 1 : 0,
                        .screen: permissionSnapshot.screen ? 1 : 0, .screenEnabled: settings.includeScreen ? 1 : 0])
        }
        do {
            try permissionSnapshot.require(includeScreen: settings.includeScreen)
            if permissionError {
                permissionError = false
                if phase == .error {
                    phase = .stopped
                    detail = L10n.text("必要な権限を確認しました。操作を開始できます。")
                }
            }
        } catch {
            let wasSending = phase == .sending
            if listening || referenceRecording || ![.stopped, .error].contains(phase) { stop() }
            permissionError = true
            phase = .error
            detail = error.localizedDescription
            if wasSending { detail += L10n.text(" 送信中だったため成否はWebexのDMで確認してください。自動再送しません。") }
        }
    }
    func configureMicrophonePermission() async {
        guard canConfigure else { return }
        await Permissions.configureMicrophone()
        refreshPermissions()
    }
    /// Stores body as the current operation without cancelling the previous one: callers stop() first, or cancel and rotate the epoch as recoverInput() does.
    /// Failures are reported only while the captured epoch is current.
    func launch(_ body: @escaping @MainActor (UUID) async throws -> Void) {
        let run = epoch
        operation = Task {
            do { try await body(run) }
            catch { if run == epoch { fail(error) } }
        }
    }
    func start() {
        guard !listening, !busy, !referenceRecording else { return }
        stop()
        audioRecovery.reset()
        phase = .recognizing
        detail = L10n.text("ローカル音声環境とWebex認証を確認しています。")
        launch { [self] run in
            try Permissions.snapshot().require(includeScreen: settings.includeScreen)
            try validateDestination()
            try persistSettings()
            _ = try await worker.call(WorkerRequest.diagnose(settings: settings), python: settings.pythonPath)
            guard run == epoch else { return }
            let person = try await connection().me()
            guard run == epoch else { return }
            ownID = person.id
            if settings.speakerVerification && !FileManager.default.fileExists(atPath: settings.speakerAudioPath) { throw RelayError.message(L10n.text("本人照合用の参照音声を録音または選択してください。")) }
            listening = true
            try await startRecorder(run: run)
        }
    }
    private func startRecorder(run: UUID) async throws {
        guard run == epoch, listening else { return }
        recorder.onChunk = { [weak self] chunk in Task { @MainActor in self?.receive(chunk, run: run) } }
        recorder.onError = { [weak self] message in Task { @MainActor in
            guard let self, self.epoch == run else { return }
            self.fail(RelayError.message(message))
        } }
        receivedAudio = false
        lastInputAt = Date()
        recorder.onConfigurationChange = { [weak self] in
            Task { @MainActor in self?.recoverInput(run: run) }
        }
        recorder.onLevel = { [weak self] value in Task { @MainActor in
            guard let self, self.epoch == run, self.listening else { return }
            self.receivedAudio = true
            self.lastInputAt = Date()
            guard Date().timeIntervalSince(self.lastMeterUpdate) > 0.15 else { return }
            self.lastMeterUpdate = Date()
            self.level = value
            let rms = Double(value) / 15
            self.audioStatus = String(format: L10n.text("マイク入力あり: %.1f dB / 検出しきい値 %.1f dB"), 20 * log10(max(rms, 0.000001)), 20 * log10(self.settings.minimumRMS))
            if [.listening, .recording].contains(self.phase) { self.phase = value > Float(self.settings.minimumRMS * 15) ? .recording : .listening }
        } }
        phase = .preparing
        detail = L10n.text("許可済みのマイク入力を開始しています。")
        audioStatus = L10n.text("入力デバイス: \(AVCaptureDevice.default(for: .audio)?.localizedName ?? L10n.text("見つかりません")) — 音声フレーム待ち")
        try await recorder.start(silenceSeconds: settings.silenceSeconds, minimumRMS: settings.minimumRMS, voiceProcessing: settings.voiceProcessing)
        logs.record(.microphoneStarted, category: .audio, metrics: [.sampleRate: recorder.inputFormat.rate, .channels: recorder.inputFormat.channels])
        if run != epoch || !listening { recorder.stop() }
        else {
            phase = .listening
            detail = L10n.text("合言葉を待っています。停止ボタンでマイクを解放します。")
            inputWatchdog?.cancel()
            inputWatchdog = Task {
                while !Task.isCancelled, run == epoch, listening {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled, run == epoch, listening else { return }
                    if recorder.isCapturing && Date().timeIntervalSince(lastInputAt) >= 4 {
                        recoverInput(run: run)
                        return
                    }
                }
            }
        }
    }
    private func recoverInput(run: UUID) {
        guard run == epoch, listening, recorder.isCapturing else { return }
        logs.record(.inputInterrupted, category: .audio, level: .warning)
        guard audioRecovery.permit(at: Date()) else {
            logs.record(.inputRecoveryFailed, category: .audio, level: .error)
            fail(RelayError.message(L10n.text("マイク入力を再接続できませんでした。macOSと会議アプリの入力デバイスを確認し、マイクテストを実行してください。")))
            return
        }
        epoch = UUID()
        operation?.cancel()
        inputWatchdog?.cancel()
        armTimeout?.cancel()
        recorder.stop()
        worker.shutdown()
        chunks = []
        processing = false
        wake.reset()
        indicator = .idle
        level = 0
        phase = .preparing
        detail = L10n.text("マイクの変更を検出しました。入力を再接続しています。")
        launch { [self] next in
            try await Task.sleep(nanoseconds: 350_000_000)
            guard next == epoch, listening else { return }
            try await startRecorder(run: next)
            logs.record(.inputRecovered, category: .audio)
            detail = L10n.text("マイクを再接続しました。合言葉からもう一度話してください。")
        }
    }
    private func receive(_ chunk: AudioRecorder.Chunk, run: UUID) {
        guard run == epoch, recorder.isCapturing else { return }
        acceptAudioChunk(chunk)
    }
    func acceptAudioChunk(_ chunk: AudioRecorder.Chunk) {
        guard listening, [.listening, .recording, .recognizing].contains(phase) else { return }
        guard !chunk.truncated else {
            discardInput(.utteranceDiscarded)
            return
        }
        guard chunks.count < 3 else {
            discardInput(.inputBacklogDiscarded)
            return
        }
        chunks.append(chunk)
        guard !processing else { return }
        processing = true
        launch { [self] run in await processChunks(run: run) }
    }
    private func discardInput(_ event: LogEvent) {
        // Keep the microphone running; invalidate in-flight recognition before accepting fresh audio.
        inputRevision = UUID()
        chunks = []
        wake.reset()
        armTimeout?.cancel()
        indicator = .idle
        if processing { worker.shutdown() }
        phase = .listening
        detail = event == .utteranceDiscarded
            ? L10n.text("長い音声区間を破棄しました。常時待受は継続しています。一呼吸置き、合言葉から話してください。")
            : L10n.text("認識待ちの音声を破棄しました。常時待受は継続しています。合言葉から話してください。")
        recognizedInput = ""
        logs.record(event, category: .audio, level: .warning)
    }
    private func processChunks(run: UUID) async {
        defer { if run == epoch { processing = false } }
        while !chunks.isEmpty, run == epoch, listening {
            let chunk = chunks.removeFirst()
            let revision = inputRevision
            do {
                phase = .recognizing
                let file = try PrivateStorage.temporaryFile(extension: "wav")
                defer { try? FileManager.default.removeItem(at: file) }
                try AudioRecorder.write(chunk.samples, to: file)
                let result = try await worker.call(WorkerRequest.transcribe(audio: file.path, settings: settings, verifyInline: false), python: settings.pythonPath)
                guard run == epoch, listening else { return }
                guard revision == inputRevision else { continue }
                updateSpeakerDiagnostics(result)
                let text = result["text"] as? String ?? ""
                recognizedInput = text.isEmpty ? (result["rejected"] as? String ?? L10n.text("音声を認識できませんでした。")) : text
                logs.record(text.isEmpty ? .recognitionRejected : .recognitionAccepted, category: .audio, level: text.isEmpty ? .warning : .info)
                if text.isEmpty {
                    detail = result["rejected"] as? String ?? L10n.text("発話を検出できませんでした。")
                    phase = .listening
                    continue
                }
                switch wake.accept(text, phrases: settings.wakePhrases, replyPhrases: settings.replyWakePhrases, now: Date(), timeout: settings.commandWaitSeconds) {
                case .ignored:
                    indicator = .idle
                    phase = .listening
                    detail = L10n.text("合言葉を待っています。")
                case .armed(let mode):
                    indicator = .receiving
                    logs.record(.wakeDetected, category: .audio)
                    phase = .listening
                    detail = settings.verifiesSpeakerStrictly ? L10n.text("合言葉を検出しました。続けて指示を話してください。指示の音声で本人照合します。") : L10n.text("合言葉を受け付けました。続けて指示を話してください。短い指示も受け付けます。")
                    if mode == .threadReply { detail = L10n.text("返信用の合言葉を受け付けました。スレッドに返す内容を話してください。") }
                    armTimeout?.cancel()
                    armTimeout = Task {
                        try? await Task.sleep(nanoseconds: UInt64(settings.commandWaitSeconds * 1_000_000_000))
                        guard !Task.isCancelled, run == epoch else { return }
                        if !processing && chunks.isEmpty {
                            wake.reset()
                            indicator = .idle
                            detail = L10n.text("指示の受付を区切り、次の合言葉を待っています。常時待受は継続しています。")
                            logs.record(.commandWaitExpired, category: .audio)
                        }
                    }
                case .command(let command, let mode):
                    indicator = .receiving
                    logs.record(.wakeDetected, category: .audio)
                    armTimeout?.cancel()
                    recorder.stop()
                    level = 0
                    chunks = []
                    if settings.verifiesSpeakerStrictly {
                        phase = .recognizing
                        detail = L10n.text("送信前に指示の音声で本人照合しています。")
                        let checked = try await worker.call(WorkerRequest.verifySpeaker(audio: file.path, settings: settings), python: settings.pythonPath)
                        guard run == epoch, listening else { return }
                        updateSpeakerDiagnostics(checked)
                        guard checked["accepted"] as? Bool == true else {
                            wake.reset()
                            indicator = .idle
                            let reason = checked["rejected"] as? String ?? L10n.text("本人照合を確認できませんでした。")
                            recognizedInput = reason
                            try await startRecorder(run: run)
                            detail = reason
                            return
                        }
                    }
                    transcript = command
                    try await prepare(command: command, run: run, forceConfirmation: false, mode: mode)
                    return
                }
            } catch {
                guard run == epoch, listening else { return }
                if revision != inputRevision { continue }
                fail(error)
                return
            }
        }
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
        if snapshot.confirmBeforeSending || forceConfirmation {
            self.draft = draft
            phase = .confirming
            detail = L10n.text("本文・画像・宛先を確認してください。")
            showMainWindow?()
            NSApp.activate(ignoringOtherApps: true)
        } else { try await send(draft, run: run) }
    }
    func confirmDraft() {
        guard let draft, phase == .confirming else { return }
        self.draft = nil
        launch { [self] run in try await send(draft, run: run) }
    }
    func cancelDraft() {
        draft = nil
        stop()
        detail = L10n.text("送信を取り消しました。")
    }
    private func send(_ draft: Draft, run: UUID) async throws {
        let client = try await connection(), snapshot = draft.settings
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
        if snapshot.readReplies {
            try await monitor(client: client, sent: sent, baseline: baseline, settings: snapshot, run: run)
        }
        guard run == epoch else { return }
        try await resumeAfterInteraction(run: run)
    }
    private func monitor(client: WebexClient, sent: Message, baseline: [Message], settings: Settings, run: UUID) async throws {
        guard let sentAt = parseDate(sent.created) else { throw RelayError.message(L10n.text("送信は完了しましたが、返信を照合する送信時刻がありません。Webexで確認してください。")) }
        if settings.waitingSound {
            do { try waitingSound.start(volume: settings.waitingSoundVolume) }
            catch {
                diagnostics = L10n.text("ソナー音を再生できません。返信監視は続けます。")
                logs.record(.sonarFailed, category: .speech, level: .warning)
            }
        }
        voiceStandbyStatus = settings.ttsEngine == "system" ? L10n.text("音声待機: Mac標準音声") : L10n.text("音声待機: 返信後に準備")
        let warmup: Task<Void, Error>? = settings.hotStandby && settings.ttsEngine == "qwen" ? Task {
            logs.record(.speechWarming, category: .speech)
            voiceStandbyStatus = L10n.text("音声待機: モデルと参照音声を準備中")
            do {
                try await speech.warmup(settings: settings, worker: worker)
                guard run == epoch, !Task.isCancelled else { return }
                logs.record(.speechReady, category: .speech)
                voiceStandbyStatus = L10n.text("音声待機: 準備完了")
            } catch {
                if run == epoch { voiceStandbyStatus = L10n.text("音声待機: 準備できませんでした") }
                throw error
            }
        } : nil
        defer {
            warmup?.cancel()
            waitingSound.stop()
        }
        var tracker = ReplyTracker(request: sent, ownPersonID: ownID, baseline: Set(baseline.map(\.id)),
                                   settleSeconds: settings.replySettleSeconds, busyPhrases: settings.busyPatterns.components(separatedBy: .newlines),
                                   requireThreaded: settings.requireThreadedReply)
        let deadline = Date().addingTimeInterval(settings.replyTimeoutSeconds)
        var polls = 0
        var failures = 0
        var lastLog = Date.distantPast, lastUpdates = -1, lastCandidates = -1, lastBusy = -1
        while Date() < deadline, run == epoch {
            try Task.checkCancellation()
            phase = .waiting
            detail = L10n.text("返信の新着と本文更新を確認しています。")
            do {
                var messages = try await client.messages(roomID: sent.roomId, since: sentAt)
                // Fetch known IDs directly even when they fall off the newest list page.
                for id in tracker.candidateIDs {
                    let current = try await client.message(id: id)
                    messages.removeAll { $0.id == id }
                    messages.append(current)
                }
                guard run == epoch else { return }
                let ready = tracker.ingest(messages, now: Date())
                polls += 1
                replyMonitoringStatus = L10n.text("取得 \(polls)回 / 返信候補 \(tracker.candidateIDs.count)件 / 途中表示 \(tracker.busyMessageCount)件 / 同一IDの本文更新 \(tracker.bodyUpdateCount)回")
                if Date().timeIntervalSince(lastLog) >= 5 || lastUpdates != tracker.bodyUpdateCount || lastCandidates != tracker.candidateIDs.count || lastBusy != tracker.busyMessageCount || !ready.isEmpty {
                    logs.record(.replyProgress, category: .webex, metrics: [.polls: Double(polls), .candidates: Double(tracker.candidateIDs.count), .busyMessages: Double(tracker.busyMessageCount), .updates: Double(tracker.bodyUpdateCount)])
                    lastLog = Date()
                    lastUpdates = tracker.bodyUpdateCount
                    lastCandidates = tracker.candidateIDs.count
                    lastBusy = tracker.busyMessageCount
                }
                if tracker.interruptedByOtherRequest { throw RelayError.message(L10n.text("同じDMに別の送信がありました。返信の取り違えを避けるため読み上げ監視を終了しました。")) }
                if !ready.isEmpty {
                    if let message = tracker.readyMessages.last { lastReplyTarget = ThreadReplyTarget(message: message) }
                    reply = ready.joined(separator: "\n\n")
                    phase = .speaking
                    detail = L10n.text("返信を確認しました。最初の音声を準備しています。")
                    let received = Date()
                    try await warmup?.value
                    guard run == epoch else { return }
                    try await speech.speak(reply, settings: settings, worker: worker, onSplit: { count in
                        logs.record(.speechSubdivided, category: .speech, metrics: [.count: Double(count)])
                    }, onProgress: recordSpeechProgress) {
                        waitingSound.stop()
                        logs.record(.speechStarted, category: .speech, metrics: [.seconds: Date().timeIntervalSince(received)])
                        detail = L10n.text("返信をローカル音声で読み上げています。")
                        voiceStandbyStatus += String(format: L10n.text(" / 返信確定から再生開始 %.1f秒"), Date().timeIntervalSince(received))
                    }
                    logs.record(.speechCompleted, category: .speech)
                    replyMonitoringStatus += L10n.text(" / 読み上げ完了")
                    return
                }
                failures = 0
            } catch RelayError.rateLimited(let delay) {
                logs.record(.rateLimited, category: .webex, level: .warning, metrics: [.seconds: delay])
                detail = L10n.text("API制限の解除を待っています。送信の再実行は行いません。")
                let wait = min(delay, max(0, deadline.timeIntervalSinceNow))
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            } catch let error as URLError {
                logs.failure(error, category: .webex)
                failures += 1
                guard failures < 4 else { throw error }
                detail = L10n.text("接続を再確認しています（返信の取得のみ）。")
                try await Task.sleep(nanoseconds: UInt64(min(30, pow(2, Double(failures))) * 1_000_000_000))
            }
            try await Task.sleep(nanoseconds: UInt64(settings.replyPollSeconds * 1_000_000_000))
        }
        if run == epoch {
            logs.record(.replyTimeout, category: .webex, level: .warning)
            replyMonitoringStatus += L10n.text(" / 返信待ち終了（送信済み・再送なし・待受へ復帰）")
        }
    }
    private func resumeAfterInteraction(run: UUID) async throws {
        // No capture while speaking; clear all buffers and leave an acoustic tail gap.
        waitingSound.stop()
        speech.stop()
        wake.reset()
        chunks = []
        try await Task.sleep(nanoseconds: 1_000_000_000)
        guard run == epoch else { return }
        indicator = .idle
        if listening { try await startRecorder(run: run) }
        else {
            phase = .stopped
            detail = L10n.text("操作が完了しました。")
        }
    }
    func requestScreenPermission() {
        guard canConfigure, settings.includeScreen else { return }
        Permissions.configureScreen()
        refreshPermissions()
    }
    func stop() {
        indicator = .idle
        logs.record(.stopped)
        let wasSending = phase == .sending
        cancelRoomSearch()
        epoch = UUID()
        operation?.cancel()
        armTimeout?.cancel()
        inputWatchdog?.cancel()
        recorder.stop()
        waitingSound.stop()
        speech.stop()
        worker.shutdown()
        voiceStandbyStatus = L10n.text("音声待機: 停止（モデルを解放）")
        if referenceRecording {
            referenceRecorder?.stop()
            if let referenceURL { try? FileManager.default.removeItem(at: referenceURL) }
        }
        referenceRecording = false
        referenceRecorder = nil
        listening = false
        processing = false
        inputRevision = UUID()
        chunks = []
        wake.reset()
        level = 0
        draft = nil
        phase = .stopped
        microphoneTestProgress = nil
        detail = wasSending ? L10n.text("送信中に停止しました。成否はWebexのDMで確認してください。自動再送しません。") : L10n.text("停止しました。マイクを解放しています。")
    }
    func fail(_ error: Error) {
        let category: LogCategory
        switch phase {
        case .speaking: category = .speech
        case .recording, .recognizing, .listening: category = .audio
        case .sending, .waiting: category = .webex
        default: category = .app
        }
        stop()
        if case RelayError.missingPermissions = error { permissionError = true } else { permissionError = false }
        phase = .error
        detail = error.localizedDescription
        logs.failure(error, category: category)
        if case RelayError.unauthorized = error { handleAuthenticationFailure() }
    }
}
