// Core state machine: settings, permissions, listening and cancellation.
// Drafts and delivery live in AppModelDelivery.swift, reply monitoring in AppModelReplies.swift.
// Other extensions handle Webex auth, diagnostics, reference audio and view presentation.
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
    @Published var hotkeyErrors: [UUID: String] = [:]
    @Published var screenUseCaseActive = false
    @Published var raycastStatus = ""
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
    let waitingSound = WaitingSound()
    let globalHotkeys = GlobalHotkeys()
    let raycastBridge = RaycastBridge()
    var captureScreen: @MainActor () async throws -> ScreenContext = { try await ScreenContext.capture() }
    var frontmostBundleID: @MainActor () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    var beginMicrophoneCapture: @MainActor (AudioRecorder, Settings, AudioRecorder.PausedInput?) async throws -> Void = { recorder, settings, resuming in
        try await recorder.start(silenceSeconds: settings.silenceSeconds, minimumRMS: settings.minimumRMS, voiceProcessing: settings.voiceProcessing, resuming: resuming)
    }
    var callVoiceWorker: @MainActor (LocalWorker, [String: Any], String) async throws -> [String: Any] = { worker, request, python in
        try await worker.call(request, python: python)
    }
    var queuedScreenUseCase: QueuedScreenUseCase?
    var screenCaptureTask: Task<ScreenContext, Error>?
    struct PausedVoiceInput {
        let pausedAt: Date
        var wake: VoiceRouter
        var interaction: VoiceInteraction?
        var audio: AudioRecorder.PausedInput
        var chunks: [AudioRecorder.Chunk]
        let transcript: String
        let recognizedInput: String
        let reply: String
        let replyTarget: ThreadReplyTarget?
        let indicator: RelayIndicator
        var screenRequestIDs = Set<String>()
        var hasVoiceContext: Bool {
            interaction != nil || indicator == .receiving || !chunks.isEmpty || !audio.chunks.isEmpty || audio.segmenter.pendingSpeech != nil
        }
    }
    var pausedVoiceInput: PausedVoiceInput?
    var voiceScreenRequestIDs = Set<String>()
    private struct VoiceInputCheckpoint {
        let chunk: AudioRecorder.Chunk
        let wake: VoiceRouter
        let interaction: VoiceInteraction?
        let transcript: String
        let recognizedInput: String
        let indicator: RelayIndicator
    }
    private var inputCheckpoint: VoiceInputCheckpoint?
    func commitVoiceInputCheckpoint() { inputCheckpoint = nil }
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
    var voiceInteraction: VoiceInteraction?
    var acceptingContinuation: Bool { voiceInteraction?.acceptingInput == true }
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
        raycastBridge.start { [weak self] request in
            guard let self else { return }
            try self.runRaycastUseCase(request)
        }
        registerScreenHotkeys()
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
        registerScreenHotkeys()
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
            if screenUseCaseActive {
                guard permissionSnapshot.screen else { throw RelayError.missingPermissions([L10n.text("画面収録")]) }
            } else {
                try permissionSnapshot.require(includeScreen: settings.includeScreen)
            }
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
            catch {
                if run == epoch {
                    let showError = screenUseCaseActive
                    let resumeVoice = screenUseCaseActive && listening && queuedScreenUseCase == nil
                    let paused = pausedVoiceInput
                    fail(error)
                    if showError { showMainWindow?() }
                    if resumeVoice {
                        switch error {
                        case RelayError.unauthorized, RelayError.ambiguousSend: break
                        default: resumeVoiceAfterScreenUseCase(paused)
                        }
                    }
                }
            }
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
    private func startRecorder(run: UUID, resuming: AudioRecorder.PausedInput? = nil) async throws {
        guard run == epoch, listening else { return }
        recorder.onChunksReady = { [weak self] in Task { @MainActor in self?.receiveChunks(run: run) } }
        recorder.onError = { [weak self] message in Task { @MainActor in
            guard let self, self.epoch == run, !self.screenUseCaseActive else { return }
            self.fail(RelayError.message(message))
        } }
        receivedAudio = false
        lastInputAt = Date()
        recorder.onConfigurationChange = { [weak self] in
            Task { @MainActor in self?.recoverInput(run: run) }
        }
        recorder.onLevel = { [weak self] value in Task { @MainActor in
            guard let self, self.epoch == run, self.listening, !self.screenUseCaseActive else { return }
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
        try await beginMicrophoneCapture(recorder, settings, resuming)
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
        guard run == epoch, listening, !screenUseCaseActive, recorder.isCapturing else { return }
        logs.record(.inputInterrupted, category: .audio, level: .warning)
        guard phase != .sending else {
            // Reconnecting cancels the operation. A POST may already have reached Webex.
            fail(RelayError.ambiguousSend)
            return
        }
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
        voiceInteraction = nil
        inputCheckpoint = nil
        voiceScreenRequestIDs = []
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
    private func receiveChunks(run: UUID) {
        guard run == epoch, recorder.isCapturing else { return }
        for chunk in recorder.takeChunks() { acceptAudioChunk(chunk) }
    }
    func acceptAudioChunk(_ chunk: AudioRecorder.Chunk) {
        guard listening, !screenUseCaseActive, voiceInteraction?.acceptingInput != false,
              voiceInteraction != nil || [.listening, .recording, .recognizing].contains(phase) else { return }
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
        voiceInteraction?.closeInput()
        wake.reset()
        armTimeout?.cancel()
        indicator = .idle
        if processing && phase == .recognizing { worker.shutdown() }
        if phase != .sending { phase = .listening }
        detail = event == .utteranceDiscarded
            ? L10n.text("長い音声区間を破棄しました。常時待受は継続しています。一呼吸置き、合言葉から話してください。")
            : L10n.text("認識待ちの音声を破棄しました。常時待受は継続しています。合言葉から話してください。")
        recognizedInput = ""
        logs.record(event, category: .audio, level: .warning)
    }
    private func processChunks(run: UUID) async {
        defer { if run == epoch { processing = false } }
        while run == epoch, listening, !screenUseCaseActive {
            if chunks.isEmpty {
                guard let voiceInteraction else { return }
                if voiceInteraction.shouldWait(now: Date(), pending: recorder.pendingSpeech) {
                    do { try await Task.sleep(nanoseconds: 50_000_000) }
                    catch { return }
                    continue
                }
                do { try await finishVoiceInput(run: run) }
                catch { if run == epoch { fail(error) } }
                return
            }
            let chunk = chunks.removeFirst()
            if let voiceInteraction, !voiceInteraction.accepts(chunk.speech) { continue }
            // Re-run only this uncommitted chunk after an interruption. Completed sends are never replayed.
            inputCheckpoint = VoiceInputCheckpoint(chunk: chunk, wake: wake, interaction: voiceInteraction,
                transcript: transcript, recognizedInput: recognizedInput, indicator: indicator)
            defer { if run == epoch { inputCheckpoint = nil } }
            let revision = inputRevision
            do {
                phase = .recognizing
                let file = try PrivateStorage.temporaryFile(extension: "wav")
                defer { try? FileManager.default.removeItem(at: file) }
                try AudioRecorder.write(chunk.samples, to: file)
                let result = try await callVoiceWorker(worker, WorkerRequest.transcribe(audio: file.path, settings: settings, verifyInline: false), settings.pythonPath)
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
                if voiceInteraction != nil {
                    if settings.verifiesSpeakerStrictly {
                        let checked = try await callVoiceWorker(worker, WorkerRequest.verifySpeaker(audio: file.path, settings: settings), settings.pythonPath)
                        guard run == epoch, listening else { return }
                        guard revision == inputRevision else { continue }
                        updateSpeakerDiagnostics(checked)
                        guard checked["accepted"] as? Bool == true else { continue }
                    }
                    try await appendVoiceCommand(text, speech: chunk.speech, run: run)
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
                    scheduleCommandTimeout(run: run)
                case .command(let command, let mode):
                    indicator = .receiving
                    logs.record(.wakeDetected, category: .audio)
                    armTimeout?.cancel()
                    if settings.verifiesSpeakerStrictly {
                        phase = .recognizing
                        detail = L10n.text("送信前に指示の音声で本人照合しています。")
                        let checked = try await callVoiceWorker(worker, WorkerRequest.verifySpeaker(audio: file.path, settings: settings), settings.pythonPath)
                        guard run == epoch, listening else { return }
                        guard revision == inputRevision else { continue }
                        updateSpeakerDiagnostics(checked)
                        guard checked["accepted"] as? Bool == true else {
                            wake.reset()
                            indicator = .idle
                            let reason = checked["rejected"] as? String ?? L10n.text("本人照合を確認できませんでした。")
                            recognizedInput = reason
                            phase = .listening
                            detail = reason
                            continue
                        }
                    }
                    try await prepareVoiceCommand(command, mode: mode, speech: chunk.speech, run: run)
                }
            } catch {
                guard run == epoch, listening else { return }
                if revision != inputRevision { continue }
                fail(error)
                return
            }
        }
    }
    func resumeAfterInteraction(run: UUID) async throws {
        // No capture while speaking; clear all buffers and leave an acoustic tail gap.
        waitingSound.stop()
        speech.stop()
        wake.reset()
        chunks = []
        try await Task.sleep(nanoseconds: 1_000_000_000)
        guard run == epoch else { return }
        if listening, let paused = pausedVoiceInput {
            try await restoreVoiceInput(paused, run: run)
            return
        }
        screenUseCaseActive = false
        voiceScreenRequestIDs = []
        indicator = .idle
        if listening { try await startRecorder(run: run) }
        else {
            phase = .stopped
            detail = L10n.text("操作が完了しました。")
        }
    }
    func requestScreenPermission() {
        guard canConfigure else { return }
        Permissions.configureScreen()
        refreshPermissions()
    }
    /// Preserve raw audio and committed voice state before cancelling recognition or waiting for a POST.
    func pauseVoiceInputForScreenUseCase() {
        guard listening, pausedVoiceInput == nil else { return }
        let pausedAt = Date()
        let checkpoint = phase == .sending ? nil : inputCheckpoint
        let audio = recorder.pause()
        pausedVoiceInput = PausedVoiceInput(pausedAt: pausedAt, wake: checkpoint?.wake ?? wake,
            interaction: checkpoint == nil ? voiceInteraction : checkpoint?.interaction,
            audio: audio, chunks: (checkpoint.map { [$0.chunk] } ?? []) + chunks,
            transcript: checkpoint?.transcript ?? transcript, recognizedInput: checkpoint?.recognizedInput ?? recognizedInput,
            reply: reply, replyTarget: lastReplyTarget, indicator: checkpoint?.indicator ?? indicator)
        pausedVoiceInput?.screenRequestIDs = voiceScreenRequestIDs
        armTimeout?.cancel()
        inputWatchdog?.cancel()
        chunks = []
        inputRevision = UUID()
        wake.reset()
        level = 0
    }

    func resumeVoiceAfterScreenUseCase(_ paused: PausedVoiceInput?) {
        pausedVoiceInput = paused
        listening = true
        screenUseCaseActive = true
        phase = .preparing
        launch { [self] run in try await resumeAfterInteraction(run: run) }
    }

    private func restoreVoiceInput(_ original: PausedVoiceInput, run: UUID) async throws {
        var paused = original
        let duration = max(0, Date().timeIntervalSince(paused.pausedAt))
        paused.wake.shift(by: duration)
        paused.interaction?.shift(by: duration)
        paused.audio.shift(by: duration)
        wake = paused.wake
        voiceInteraction = paused.interaction
        voiceScreenRequestIDs = paused.screenRequestIDs
        let pendingChunks = paused.chunks.map { $0.shifted(by: duration) } + paused.audio.chunks
        chunks = []
        paused.audio.chunks = []
        transcript = paused.transcript
        recognizedInput = paused.recognizedInput
        // Preserve the new screen reply in the conversation; restore a voice reply target while its input continues.
        if voiceInteraction != nil || paused.indicator == .receiving { lastReplyTarget = paused.replyTarget }
        if reply.isEmpty { reply = paused.reply }
        pausedVoiceInput = nil
        // A microphone restart failure must stop once, rather than repeatedly trying to resume.
        do { try await startRecorder(run: run, resuming: paused.audio) }
        catch { screenUseCaseActive = false; throw error }
        guard run == epoch, listening else { return }
        screenUseCaseActive = false
        indicator = paused.indicator
        // Apply the same length and backlog limits as live input, without launching a task per chunk.
        processing = true
        for chunk in pendingChunks { acceptAudioChunk(chunk) }
        processing = false
        scheduleCommandTimeout(run: run)
        if voiceInteraction != nil || indicator == .receiving || !chunks.isEmpty || paused.audio.segmenter.pendingSpeech != nil {
            detail = L10n.text("音声受付を再開しました。途中の指示に続けて話してください。")
        }
        if !chunks.isEmpty || voiceInteraction != nil {
            processing = true
            launch { [self] next in
                if let interaction = voiceInteraction, interaction.draft == nil {
                    try await prepare(command: interaction.text, run: next, forceConfirmation: false, mode: interaction.mode)
                } else if let interaction = voiceInteraction, interaction.needsDelivery,
                          let draft = interaction.draft, !draft.settings.confirmBeforeSending {
                    try await send(draft, run: next)
                }
                guard next == epoch else { return }
                await processChunks(run: next)
            }
        }
    }

    private func scheduleCommandTimeout(run: UUID) {
        armTimeout?.cancel()
        guard let remaining = wake.remaining(now: Date(), timeout: settings.commandWaitSeconds) else { return }
        armTimeout = Task {
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard !Task.isCancelled, run == epoch, !screenUseCaseActive else { return }
            if !processing && chunks.isEmpty {
                wake.reset()
                indicator = .idle
                detail = L10n.text("指示の受付を区切り、次の合言葉を待っています。常時待受は継続しています。")
                logs.record(.commandWaitExpired, category: .audio)
            }
        }
    }

    func stop() {
        indicator = .idle
        logs.record(.stopped)
        let wasSending = phase == .sending
        cancelRoomSearch()
        epoch = UUID()
        operation?.cancel()
        queuedScreenUseCase?.capture.cancel()
        queuedScreenUseCase = nil
        screenCaptureTask?.cancel()
        screenCaptureTask = nil
        pausedVoiceInput = nil
        inputCheckpoint = nil
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
        voiceInteraction = nil
        voiceScreenRequestIDs = []
        screenUseCaseActive = false
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
