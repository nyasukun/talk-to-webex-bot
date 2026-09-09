import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers
import RelayCore

@MainActor final class AppModel: ObservableObject {
    enum Phase: String { case stopped = "停止", listening = "待受", recording = "録音", recognizing = "認識中", preparing = "送信準備", confirming = "送信前確認", sending = "送信", waiting = "返信待ち", speaking = "読み上げ", error = "エラー" }
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
            if oldValue.includeScreen != settings.includeScreen { refreshPermissions() }
            if oldValue.roomID != settings.roomID { lastReplyTarget = nil }
            if oldValue.preventIdleSleep != settings.preventIdleSleep { updateStandbyActivity() }
        }
    }
    @Published var permissionSnapshot: PermissionSnapshot
    @Published private(set) var savedSettings: Settings
    @Published var showTokenRenewal = false
    @Published var issueReportDraft: String?
    @Published var tokenBrowserOpened = true
    @Published private(set) var tokenValid = false
    @Published private(set) var keychainNeedsAccess = false
    @Published private(set) var checkingToken = false
    @Published private(set) var tokenRecovery = TokenRecovery()
    let logs: DiagnosticLog
    let isPreview: Bool
    private let openPortal: (URL) -> Bool
    var hasUnsavedChanges: Bool { settings != savedSettings }
    @Published var phase: Phase = .stopped
    @Published var indicator: RelayIndicator = .idle
    @Published var lastReplyTarget: ThreadReplyTarget?
    @Published var detail = "設定を保存して待受を開始してください。"
    @Published var tokenInput = ""
    @Published var tokenStatus = "未確認"
    @Published var rooms: [Room] = []
    @Published var query = "" { didSet { if query != oldValue { searchRooms() } } }
    @Published var roomsLoading = false
    @Published var roomSearchStatus = "最近のDMを最大5件表示します。"
    @Published var busy = false
    @Published var level: Float = 0
    @Published var microphoneTestProgress: Double?
    @Published var transcript = ""
    @Published var reply = ""
    @Published var replyMonitoringStatus = "返信監視はまだ実行していません。"
    @Published var voiceStandbyStatus = "音声待機: 未開始"
    @Published var diagnostics = ""
    @Published var audioStatus = "マイク未開始"
    @Published var recognizedInput = ""
    @Published var draft: Draft?
    @Published var listening = false { didSet { updateStandbyActivity() } }
    @Published var referenceRecording = false
    @Published var testInput = "接続確認です。短く返答してください。"
    @Published var speechTestText = """
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
    var showMainWindow: (() -> Void)?
    private let recorder = AudioRecorder()
    private let worker = LocalWorker()
    private let speech = SpeechOutput()
    private let waitingSound = WaitingSound()
    private let standbyActivity = StandbyActivity()
    private var referenceRecorder: AVAudioRecorder?
    private var lastMeterUpdate = Date.distantPast
    private var referenceKind = "speaker"
    private var referenceURL: URL?
    private var client: WebexClient?
    private var tokenReadTask: Task<String?, Error>?
    private var roomSearchTask: Task<Void, Never>?
    private var roomSearchID = UUID()
    private var ownID = ""
    private var wake = VoiceRouter()
    private var chunks: [AudioRecorder.Chunk] = []
    private var processing = false
    private var inputRevision = UUID()
    private var epoch = UUID()
    private var operation: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var armTimeout: Task<Void, Never>?
    private var inputWatchdog: Task<Void, Never>?
    private var receivedAudio = false
    private var lastInputAt = Date.distantPast
    private var audioRecovery = AudioRecovery()
    private var credentialEpoch = UUID()
    private var tokenCheckEpoch: UUID?
    private var permissionError = false
    private var lastTokenCheck: Date?

    init(preview: Bool = false, openPortal: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        isPreview = preview
        self.openPortal = openPortal
        let initial = preview ? Settings() : PrivateStorage.load()
        settings = initial; savedSettings = initial
        permissionSnapshot = preview ? PermissionSnapshot(microphone: .allowed, screen: true) : Permissions.snapshot()
        logs = preview ? DiagnosticLog() : DiagnosticLog(file: PrivateStorage.directory.appendingPathComponent("diagnostics/events.json"))
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
        detail = "未保存の変更を取り消しました。"
        refreshPermissions()
    }
    func presentIssueReport() {
        guard canConfigure else { return }
        issueReportDraft = IssueReport.draft(settings: settings, phase: phase, permissions: permissionSnapshot, entries: logs.entries)
        showMainWindow?()
    }
    func clearConversation() {
        guard canConfigure else { return }
        transcript = ""; reply = ""; recognizedInput = ""; lastReplyTarget = nil
    }
    private func persistReference(kind: String, path: String) throws {
        var saved = savedSettings
        if kind == "speaker" { saved.speakerAudioPath = path }
        else { saved.referenceAudioPath = path }
        try PrivateStorage.save(saved)
        if kind == "speaker" { settings.speakerAudioPath = path }
        else { settings.referenceAudioPath = path }
        savedSettings = saved
        logs.record(.settingsSaved)
    }
    func openTokenPortal() {
        tokenBrowserOpened = openPortal(TokenRecovery.portalURL)
        logs.record(tokenBrowserOpened ? .browserOpened : .browserFailed, category: .webex, level: tokenBrowserOpened ? .info : .warning)
    }
    func presentTokenRenewal() { showTokenRenewal = true; showMainWindow?() }
    func handleAuthenticationFailure() {
        tokenValid = false
        tokenStatus = "認証が無効です。新しいAPI Keyを入力してください。"
        guard tokenRecovery.unauthorized() else { return }
        presentTokenRenewal()
        openTokenPortal()
    }
    func authenticationSucceeded(dismissRenewal: Bool = false) {
        let wasRecovering = tokenRecovery.needsRenewal
        tokenValid = true; keychainNeedsAccess = false; tokenRecovery.authenticated()
        if dismissRenewal || wasRecovering { showTokenRenewal = false }
        if wasRecovering && phase == .error && permissionsReady {
            phase = .stopped; detail = "Webexの認証を更新しました。待受を開始できます。"
        }
        tokenStatus = "有効（\(Date().formatted(date: .omitted, time: .shortened))に確認）"
        logs.record(.tokenValid, category: .webex)
    }
    func saveSettings() {
        guard canConfigure else { return }
        do { try settings.validate(); try persistSettings(); detail = "設定をこのMacに保存しました。"; refreshPermissions() }
        catch { fail(error) }
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
                if phase == .error { phase = .stopped; detail = "必要な権限を確認しました。操作を開始できます。" }
            }
        } catch {
            let wasSending = phase == .sending
            if listening || referenceRecording || ![.stopped, .error].contains(phase) { stop() }
            permissionError = true; phase = .error; detail = error.localizedDescription
            if wasSending { detail += " 送信中だったため成否はWebexのDMで確認してください。自動再送しません。" }
        }
    }
    func configureMicrophonePermission() async {
        guard canConfigure else { return }
        await Permissions.configureMicrophone()
        refreshPermissions()
    }
    private func connection() async throws -> WebexClient {
        if let client { return client }
        // One noninteractive read per launch; API health checks reuse the in-memory client.
        if tokenReadTask == nil { tokenReadTask = Task { try await TokenStore.read() } }
        let saved: String?
        do { saved = try await tokenReadTask!.value }
        catch {
            if let client { return client }
            keychainNeedsAccess = error is TokenReadError
            throw error
        }
        if let client { return client }
        guard let token = saved, !token.isEmpty else { throw RelayError.message("設定のWebex欄でトークンをキーチェーンに保存してください。") }
        let result = WebexClient(token: token); client = result; return result
    }
    func authorizeSavedToken() async {
        guard canConfigure else { return }
        cancelRoomSearch()
        busy = true; defer { busy = false }
        do {
            guard let token = try await TokenStore.authorize(), !token.isEmpty else {
                throw RelayError.message("保存済みトークンがありません。アプリ内で入力して保存してください。")
            }
            credentialEpoch = UUID(); client = WebexClient(token: token); tokenReadTask = nil
            if permissionsReady, phase == .error { phase = .stopped }
            detail = "保存済みトークンを読み込みました。Webexで有効性を確認します。"
            await checkToken()
        } catch { keychainNeedsAccess = error is TokenReadError; tokenStatus = error.localizedDescription; logs.failure(error, category: .webex) }
    }
    func saveToken() async {
        guard canConfigure, !tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        cancelRoomSearch()
        busy = true; defer { busy = false; tokenInput = "" }
        do {
            let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = WebexClient(token: token)
            let person = try await candidate.me()
            try await TokenStore.write(token)
            tokenReadTask = nil
            credentialEpoch = UUID(); client = candidate; ownID = person.id; lastTokenCheck = Date()
            authenticationSucceeded(dismissRenewal: true)
            logs.record(.tokenSaved, category: .webex)
            if permissionsReady { phase = .stopped }
            detail = "認証を確認しました。送信先DMを選んでください。"
            busy = false; loadRooms()
        } catch { tokenStatus = error.localizedDescription; fail(error) }
    }
    func checkToken(silent: Bool = false) async {
        let current = credentialEpoch
        guard tokenCheckEpoch != current else { return }
        tokenCheckEpoch = current; checkingToken = true
        defer { if tokenCheckEpoch == current { tokenCheckEpoch = nil; checkingToken = false } }
        do {
            let person = try await connection().me()
            guard current == credentialEpoch else { return }
            ownID = person.id; lastTokenCheck = Date()
            authenticationSucceeded()
        } catch {
            guard current == credentialEpoch else { return }
            tokenValid = false; tokenStatus = error.localizedDescription
            if case RelayError.unauthorized = error { fail(error) }
            else if !silent { fail(error) }
            else { logs.failure(error, category: .webex) }
        }
    }
    func loadRooms() { searchRooms(debounce: false) }
    private func cancelRoomSearch() {
        roomSearchTask?.cancel(); roomSearchID = UUID()
        if roomsLoading { roomSearchStatus = "DM検索を停止しました。更新ボタンで再開できます。" }
        roomsLoading = false
    }
    private func searchRooms(debounce: Bool = true) {
        guard canConfigure else { return }
        roomSearchTask?.cancel()
        let id = UUID(), filter = query
        roomSearchID = id; rooms = []; roomsLoading = true
        roomSearchStatus = "最近のやりとり順に、一致するDMを最大5件探しています。"
        roomSearchTask = Task {
            defer { if roomSearchID == id { roomsLoading = false } }
            do {
                if debounce { try await Task.sleep(nanoseconds: 400_000_000) }
                let result = try await connection().rooms(matching: filter)
                try Task.checkCancellation()
                guard roomSearchID == id, query == filter else { return }
                rooms = result
                logs.record(.roomsLoaded, category: .webex, metrics: [.count: Double(result.count)])
                roomSearchStatus = result.isEmpty ? "条件に一致するDMはありません。" : "\(result.count)件 • 最近のやりとり順 • 最大5件"
            } catch {
                guard !Task.isCancelled, roomSearchID == id else { return }
                roomSearchStatus = error.localizedDescription
                if case RelayError.unauthorized = error { fail(error) } else { logs.failure(error, category: .webex) }
            }
        }
    }
    func selectRoom(_ room: Room) {
        guard canConfigure else { return }
        settings.roomID = room.id; settings.roomTitle = room.title
    }
    private func validateDestination() throws {
        try settings.validate()
        guard !settings.roomID.isEmpty else { throw RelayError.message("送信先DMを選んでください。") }
    }
    func checkLocal() async {
        guard canConfigure else { return }
        let run = epoch
        busy = true; defer { busy = false }
        do {
            let result = try await worker.call(["action": "diagnose", "model": settings.asrModelPath,
                                                "voice_model": settings.ttsEngine == "qwen" ? settings.ttsModelPath : ""], python: settings.pythonPath)
            guard run == epoch else { return }
            diagnostics = result["summary"] as? String ?? "ローカル環境を確認しました。"
            detail = diagnostics
            logs.record(.environmentReady)
        } catch { if run == epoch { diagnostics = error.localizedDescription; fail(error) } }
    }
    func start() {
        guard !listening, !busy, !referenceRecording else { return }
        stop()
        audioRecovery.reset()
        let run = epoch
        phase = .recognizing; detail = "ローカル音声環境とWebex認証を確認しています。"
        operation = Task {
            do {
                try Permissions.snapshot().require(includeScreen: settings.includeScreen)
                try validateDestination()
                try persistSettings()
                _ = try await worker.call(["action": "diagnose", "model": settings.asrModelPath,
                                           "voice_model": settings.ttsEngine == "qwen" ? settings.ttsModelPath : ""], python: settings.pythonPath)
                guard run == epoch else { return }
                let person = try await connection().me()
                guard run == epoch else { return }
                ownID = person.id; lastTokenCheck = Date()
                if settings.speakerVerification && !FileManager.default.fileExists(atPath: settings.speakerAudioPath) { throw RelayError.message("本人照合用の参照音声を録音または選択してください。") }
                listening = true
                try await startRecorder(run: run)
            } catch { if run == epoch { fail(error) } }
        }
    }
    private func startRecorder(run: UUID) async throws {
        guard run == epoch, listening else { return }
        recorder.onChunk = { [weak self] chunk in Task { @MainActor in self?.receive(chunk, run: run) } }
        recorder.onError = { [weak self] message in Task { @MainActor in
            guard let self, self.epoch == run else { return }; self.fail(RelayError.message(message))
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
            self.lastMeterUpdate = Date(); self.level = value
            let rms = Double(value) / 15
            self.audioStatus = String(format: "マイク入力あり: %.1f dB / 検出しきい値 %.1f dB", 20 * log10(max(rms, 0.000001)), 20 * log10(self.settings.minimumRMS))
            if [.listening, .recording].contains(self.phase) { self.phase = value > Float(self.settings.minimumRMS * 15) ? .recording : .listening }
        } }
        phase = .preparing; detail = "許可済みのマイク入力を開始しています。"
        audioStatus = "入力デバイス: \(AVCaptureDevice.default(for: .audio)?.localizedName ?? "見つかりません") — 音声フレーム待ち"
        try await recorder.start(silenceSeconds: settings.silenceSeconds, minimumRMS: settings.minimumRMS, voiceProcessing: settings.voiceProcessing)
        logs.record(.microphoneStarted, category: .audio, metrics: [.sampleRate: recorder.inputFormat.rate, .channels: recorder.inputFormat.channels])
        if run != epoch || !listening { recorder.stop() }
        else {
            phase = .listening; detail = "合言葉を待っています。停止ボタンでマイクを解放します。"
            inputWatchdog?.cancel()
            inputWatchdog = Task {
                while !Task.isCancelled, run == epoch, listening {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled, run == epoch, listening else { return }
                    if recorder.isCapturing && Date().timeIntervalSince(lastInputAt) >= 4 {
                        recoverInput(run: run); return
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
            fail(RelayError.message("マイク入力を再接続できませんでした。macOSと会議アプリの入力デバイスを確認し、マイクテストを実行してください。"))
            return
        }
        epoch = UUID(); let next = epoch
        operation?.cancel(); inputWatchdog?.cancel(); armTimeout?.cancel()
        recorder.stop(); worker.shutdown(); chunks = []; processing = false; wake.reset(); indicator = .idle; level = 0
        phase = .preparing; detail = "マイクの変更を検出しました。入力を再接続しています。"
        operation = Task {
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
                guard next == epoch, listening else { return }
                try await startRecorder(run: next)
                logs.record(.inputRecovered, category: .audio)
                detail = "マイクを再接続しました。合言葉からもう一度話してください。"
            } catch { if next == epoch { fail(error) } }
        }
    }
    private func receive(_ chunk: AudioRecorder.Chunk, run: UUID) {
        guard run == epoch, recorder.isCapturing else { return }
        acceptAudioChunk(chunk)
    }
    func acceptAudioChunk(_ chunk: AudioRecorder.Chunk) {
        guard listening, [.listening, .recording, .recognizing].contains(phase) else { return }
        guard !chunk.truncated else { discardInput(.utteranceDiscarded); return }
        guard chunks.count < 3 else { discardInput(.inputBacklogDiscarded); return }
        chunks.append(chunk)
        guard !processing else { return }
        processing = true
        let run = epoch
        operation = Task { await processChunks(run: run) }
    }
    private func discardInput(_ event: LogEvent) {
        // Keep the microphone running; invalidate in-flight recognition before accepting fresh audio.
        inputRevision = UUID()
        chunks = []; wake.reset(); armTimeout?.cancel(); indicator = .idle
        if processing { worker.shutdown() }
        phase = .listening
        detail = event == .utteranceDiscarded
            ? "長い音声区間を破棄しました。常時待受は継続しています。一呼吸置き、合言葉から話してください。"
            : "認識待ちの音声を破棄しました。常時待受は継続しています。合言葉から話してください。"
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
                let result = try await worker.call(["action": "transcribe", "audio": file.path, "model": settings.asrModelPath,
                                                    "prefer_speaker": settings.speakerVerification && settings.speakerMode == "prefer",
                                                    "reference_audio": settings.speakerAudioPath], python: settings.pythonPath)
                guard run == epoch, listening else { return }
                guard revision == inputRevision else { continue }
                updateSpeakerDiagnostics(result)
                let text = result["text"] as? String ?? ""
                recognizedInput = text.isEmpty ? (result["rejected"] as? String ?? "音声を認識できませんでした。") : text
                logs.record(text.isEmpty ? .recognitionRejected : .recognitionAccepted, category: .audio, level: text.isEmpty ? .warning : .info)
                if text.isEmpty { detail = result["rejected"] as? String ?? "発話を検出できませんでした。"; phase = .listening; continue }
                switch wake.accept(text, phrases: settings.wakePhrases, replyPhrases: settings.replyWakePhrases, now: Date(), timeout: settings.commandWaitSeconds) {
                case .ignored: indicator = .idle; phase = .listening; detail = "合言葉を待っています。"
                case .armed(let mode):
                    indicator = .receiving
                    logs.record(.wakeDetected, category: .audio)
                    phase = .listening
                    detail = settings.speakerVerification && settings.speakerMode == "strict" ? "合言葉を検出しました。続けて指示を話してください。指示の音声で本人照合します。" : "合言葉を受け付けました。続けて指示を話してください。短い指示も受け付けます。"
                    if mode == .threadReply { detail = "返信用の合言葉を受け付けました。スレッドに返す内容を話してください。" }
                    armTimeout?.cancel()
                    armTimeout = Task {
                        try? await Task.sleep(nanoseconds: UInt64(settings.commandWaitSeconds * 1_000_000_000))
                        guard !Task.isCancelled, run == epoch else { return }
                        if !processing && chunks.isEmpty { wake.reset(); indicator = .idle; detail = "指示の受付を区切り、次の合言葉を待っています。常時待受は継続しています。"; logs.record(.commandWaitExpired, category: .audio) }
                    }
                case .command(let command, let mode):
                    indicator = .receiving
                    logs.record(.wakeDetected, category: .audio)
                    armTimeout?.cancel(); recorder.stop(); level = 0; chunks = []
                    if settings.speakerVerification && settings.speakerMode == "strict" {
                        phase = .recognizing; detail = "送信前に指示の音声で本人照合しています。"
                        let checked = try await worker.call(["action": "verify_speaker", "audio": file.path,
                                                             "reference_audio": settings.speakerAudioPath,
                                                             "speaker_threshold": settings.speakerThreshold], python: settings.pythonPath)
                        guard run == epoch, listening else { return }
                        updateSpeakerDiagnostics(checked)
                        guard checked["accepted"] as? Bool == true else {
                            wake.reset(); indicator = .idle
                            let reason = checked["rejected"] as? String ?? "本人照合を確認できませんでした。"
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
                fail(error); return
            }
        }
    }
    func prepareTextTest() {
        guard canConfigure else { return }
        stop(); let run = epoch
        operation = Task {
            do {
                try validateDestination()
                transcript = testInput
                try await prepare(command: testInput, run: run, forceConfirmation: true)
            } catch { if run == epoch { fail(error) } }
        }
    }
    private func prepare(command: String, run: UUID, forceConfirmation: Bool, mode: VoiceMode = .message) async throws {
        phase = .preparing; detail = "送信内容を準備しています。"
        var snapshot = settings
        let target: ThreadReplyTarget?
        if mode == .threadReply {
            guard let previous = lastReplyTarget else { throw RelayError.message("返信先がありません。このアプリで相手の返信を受け取ってから、返信用の合言葉を話してください。") }
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
            self.draft = draft; phase = .confirming; detail = "本文・画像・宛先を確認してください。"
            showMainWindow?()
            NSApp.activate(ignoringOtherApps: true)
        } else { try await send(draft, run: run) }
    }
    func confirmDraft() {
        guard let draft, phase == .confirming else { return }
        self.draft = nil
        let run = epoch
        operation = Task {
            do { try await send(draft, run: run) }
            catch { if run == epoch { fail(error) } }
        }
    }
    func cancelDraft() { draft = nil; stop(); detail = "送信を取り消しました。" }
    private func send(_ draft: Draft, run: UUID) async throws {
        let client = try await connection(), snapshot = draft.settings
        replyMonitoringStatus = snapshot.readReplies ? "送信後に返信を監視します。" : "返信の読み上げはOFFです。監視しません。"
        logs.record(.sendStarted, category: .webex)
        phase = .sending; detail = "Webexへ送信しています。"
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
        detail = "送信しました。"
        if snapshot.readReplies {
            try await monitor(client: client, sent: sent, baseline: baseline, settings: snapshot, run: run)
        }
        guard run == epoch else { return }
        try await resumeAfterInteraction(run: run)
    }
    private func monitor(client: WebexClient, sent: Message, baseline: [Message], settings: Settings, run: UUID) async throws {
        guard let sentAt = parseDate(sent.created) else { throw RelayError.message("送信は完了しましたが、返信を照合する送信時刻がありません。Webexで確認してください。") }
        if settings.waitingSound {
            do { try waitingSound.start(volume: settings.waitingSoundVolume) }
            catch { diagnostics = "ソナー音を再生できません。返信監視は続けます。"; logs.record(.sonarFailed, category: .speech, level: .warning) }
        }
        voiceStandbyStatus = settings.ttsEngine == "system" ? "音声待機: Mac標準音声" : "音声待機: 返信後に準備"
        let warmup: Task<Void, Error>? = settings.hotStandby && settings.ttsEngine == "qwen" ? Task {
            logs.record(.speechWarming, category: .speech)
            voiceStandbyStatus = "音声待機: モデルと参照音声を準備中"
            do {
                try await speech.warmup(settings: settings, worker: worker)
                guard run == epoch, !Task.isCancelled else { return }
                logs.record(.speechReady, category: .speech)
                voiceStandbyStatus = "音声待機: 準備完了"
            } catch {
                if run == epoch { voiceStandbyStatus = "音声待機: 準備できませんでした" }
                throw error
            }
        } : nil
        defer { warmup?.cancel(); waitingSound.stop() }
        var tracker = ReplyTracker(request: sent, ownPersonID: ownID, baseline: Set(baseline.map(\.id)),
                                   settleSeconds: settings.replySettleSeconds, busyPhrases: settings.busyPatterns.components(separatedBy: .newlines),
                                   requireThreaded: settings.requireThreadedReply)
        let deadline = Date().addingTimeInterval(settings.replyTimeoutSeconds)
        var polls = 0
        var failures = 0
        var lastLog = Date.distantPast, lastUpdates = -1, lastCandidates = -1, lastBusy = -1
        while Date() < deadline, run == epoch {
            try Task.checkCancellation()
            phase = .waiting; detail = "返信の新着と本文更新を確認しています。"
            do {
                var messages = try await client.messages(roomID: sent.roomId, since: sentAt)
                // Fetch known IDs directly even when they fall off the newest list page.
                for id in tracker.candidateIDs {
                    let current = try await client.message(id: id)
                    messages.removeAll { $0.id == id }; messages.append(current)
                }
                guard run == epoch else { return }
                let ready = tracker.ingest(messages, now: Date())
                polls += 1
                replyMonitoringStatus = "取得 \(polls)回 / 返信候補 \(tracker.candidateIDs.count)件 / 途中表示 \(tracker.busyMessageCount)件 / 同一IDの本文更新 \(tracker.bodyUpdateCount)回"
                if Date().timeIntervalSince(lastLog) >= 5 || lastUpdates != tracker.bodyUpdateCount || lastCandidates != tracker.candidateIDs.count || lastBusy != tracker.busyMessageCount || !ready.isEmpty {
                    logs.record(.replyProgress, category: .webex, metrics: [.polls: Double(polls), .candidates: Double(tracker.candidateIDs.count), .busyMessages: Double(tracker.busyMessageCount), .updates: Double(tracker.bodyUpdateCount)])
                    lastLog = Date(); lastUpdates = tracker.bodyUpdateCount; lastCandidates = tracker.candidateIDs.count; lastBusy = tracker.busyMessageCount
                }
                if tracker.interruptedByOtherRequest { throw RelayError.message("同じDMに別の送信がありました。返信の取り違えを避けるため読み上げ監視を終了しました。") }
                if !ready.isEmpty {
                    if let message = tracker.readyMessages.last { lastReplyTarget = ThreadReplyTarget(message: message) }
                    reply = ready.joined(separator: "\n\n"); phase = .speaking; detail = "返信を確認しました。最初の音声を準備しています。"
                    let received = Date()
                    try await warmup?.value
                    guard run == epoch else { return }
                    try await speech.speak(reply, settings: settings, worker: worker, onSplit: { count in
                        logs.record(.speechSubdivided, category: .speech, metrics: [.count: Double(count)])
                    }, onProgress: recordSpeechProgress) {
                        waitingSound.stop()
                        logs.record(.speechStarted, category: .speech, metrics: [.seconds: Date().timeIntervalSince(received)])
                        detail = "返信をローカル音声で読み上げています。"
                        voiceStandbyStatus += String(format: " / 返信確定から再生開始 %.1f秒", Date().timeIntervalSince(received))
                    }
                    logs.record(.speechCompleted, category: .speech)
                    replyMonitoringStatus += " / 読み上げ完了"
                    return
                }
                failures = 0
            } catch RelayError.rateLimited(let delay) {
                logs.record(.rateLimited, category: .webex, level: .warning, metrics: [.seconds: delay])
                detail = "API制限の解除を待っています。送信の再実行は行いません。"
                let wait = min(delay, max(0, deadline.timeIntervalSinceNow))
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            } catch let error as URLError {
                logs.failure(error, category: .webex)
                failures += 1
                guard failures < 4 else { throw error }
                detail = "接続を再確認しています（返信の取得のみ）。"
                try await Task.sleep(nanoseconds: UInt64(min(30, pow(2, Double(failures))) * 1_000_000_000))
            }
            try await Task.sleep(nanoseconds: UInt64(settings.replyPollSeconds * 1_000_000_000))
        }
        if run == epoch {
            logs.record(.replyTimeout, category: .webex, level: .warning)
            replyMonitoringStatus += " / 返信待ち終了（送信済み・再送なし・待受へ復帰）"
        }
    }
    private func resumeAfterInteraction(run: UUID) async throws {
        // No capture while speaking; clear all buffers and leave an acoustic tail gap.
        waitingSound.stop(); speech.stop(); wake.reset(); chunks = []
        try await Task.sleep(nanoseconds: 1_000_000_000)
        guard run == epoch else { return }
        indicator = .idle
        if listening { try await startRecorder(run: run) }
        else { phase = .stopped; detail = "操作が完了しました。" }
    }
    func testSpeech() {
        guard canConfigure else { return }
        stop(); let run = epoch
        phase = .speaking
        operation = Task {
            do {
                guard !speechTestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      speechTestText.count <= 20000 else { throw RelayError.message("試聴する文章は1〜20,000文字で入力してください。") }
                try await speech.speak(speechTestText, settings: settings, worker: worker, onSplit: { count in
                    self.logs.record(.speechSubdivided, category: .speech, metrics: [.count: Double(count)])
                }, onProgress: recordSpeechProgress) { self.logs.record(.speechStarted, category: .speech) }
                logs.record(.speechCompleted, category: .speech)
                guard run == epoch else { return }; phase = .stopped; detail = "読み上げが終わりました。発音と声質を確認してください。"
            } catch { if run == epoch { fail(error) } }
        }
    }
    private func recordSpeechProgress(_ progress: SpeechLineProgress) {
        let metrics: [LogMetric: Double] = [.speechLine: Double(progress.line), .speechLines: Double(progress.total),
                                          .generationSeconds: progress.generationSeconds, .audioSeconds: progress.audioSeconds,
                                          .bufferedSeconds: progress.bufferedSeconds]
        logs.record(.speechLineReady, category: .speech, metrics: metrics)
        if progress.bufferRanOut { logs.record(.speechBufferWait, category: .speech, level: .warning, metrics: metrics) }
    }
    func testMicrophone() {
        guard canConfigure else { return }
        stop(); let run = epoch
        phase = .preparing; detail = "許可済みのマイクをテストします。Webexへは送信しません。"
        operation = Task {
            defer { if run == epoch { microphoneTestProgress = nil } }
            do {
                try Permissions.requireMicrophone()
                guard run == epoch else { return }
                let file = try PrivateStorage.temporaryFile(extension: "wav")
                defer { try? FileManager.default.removeItem(at: file) }
                var peak = Float(0)
                recorder.onChunk = nil
                recorder.onConfigurationChange = { [weak self] in Task { @MainActor in
                    guard let self, run == self.epoch else { return }
                    self.logs.record(.inputInterrupted, category: .audio, level: .warning)
                    self.fail(RelayError.message("テスト中にマイクの音声形式が変わりました。入力デバイスが安定してから、もう一度テストしてください。"))
                } }
                recorder.onError = { [weak self] message in Task { @MainActor in
                    guard let self, self.epoch == run else { return }; self.fail(RelayError.message(message))
                } }
                recorder.onLevel = { [weak self] value in Task { @MainActor in
                    guard let self, self.epoch == run, self.phase == .recording else { return }
                    self.level = value; peak = max(peak, value)
                } }
                try await recorder.start(silenceSeconds: settings.silenceSeconds, minimumRMS: settings.minimumRMS,
                                         voiceProcessing: settings.voiceProcessing, diagnostic: true)
                phase = .recording; detail = "5秒間のテスト録音中です。合言葉と短い指示を話してください。送信はしません。"
                microphoneTestProgress = 0
                for step in 0..<50 {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    microphoneTestProgress = Double(step + 1) / 50
                }
                let samples = recorder.finishDiagnostic(); level = 0
                guard run == epoch else { return }
                logs.record(.microphoneSampled, category: .audio, metrics: [.seconds: Double(samples.count) / 16000,
                    .level: Double(peak), .sampleRate: recorder.inputFormat.rate, .channels: recorder.inputFormat.channels])
                guard !samples.isEmpty else {
                    throw RelayError.message("マイクから音声フレームが届きませんでした。macOSのサウンド設定と会議アプリの入力デバイスを確認し、待受を停止してから再テストしてください。")
                }
                guard peak > 0 else {
                    throw RelayError.message("音声フレームは届いていますが、入力音量がゼロです。macOSのサウンド設定で内蔵マイクの入力音量を確認してください。")
                }
                try AudioRecorder.write(samples, to: file)
                phase = .recognizing; audioStatus = String(format: "5秒録音の入力レベル最大: %.0f%%（待受と同じ録音経路）", peak * 100)
                let result = try await worker.call(["action": "transcribe", "audio": file.path, "model": settings.asrModelPath,
                                                    "verify_speaker": settings.speakerVerification && settings.speakerMode == "strict",
                                                    "prefer_speaker": settings.speakerVerification && settings.speakerMode == "prefer",
                                                    "reference_audio": settings.speakerAudioPath, "speaker_threshold": settings.speakerThreshold], python: settings.pythonPath)
                guard run == epoch else { return }
                updateSpeakerDiagnostics(result)
                recognizedInput = result["text"] as? String ?? ""
                let match = WakeMatcher.command(in: recognizedInput, phrases: settings.wakePhrases) != nil || WakeMatcher.command(in: recognizedInput, phrases: settings.replyWakePhrases) != nil
                logs.record(.microphoneTest, category: .audio, metrics: [.level: Double(peak), .count: match ? 1 : 0])
                phase = .stopped
                detail = recognizedInput.isEmpty ? (result["rejected"] as? String ?? "認識できませんでした。入力デバイスと音量を確認してください。") :
                    (match ? "マイク・文字起こし・合言葉の一致を確認しました。送信していません。" : "文字起こしは成功しましたが、合言葉が一致しません。表示された表記を別候補として登録できます。")
            } catch { if run == epoch { fail(error) } }
        }
    }
    private func updateSpeakerDiagnostics(_ result: [String: Any]) {
        diagnostics = result["speaker_note"] as? String ?? ""
        guard let similarity = result["similarity"] as? Double else { return }
        logs.record(.speakerMeasured, category: .audio, metrics: [.similarity: similarity, .overall: result["overall_similarity"] as? Double ?? similarity, .threshold: settings.speakerThreshold])
        if let windows = result["speaker_windows"] as? [[String: Any]] {
            for (index, window) in windows.enumerated() {
                if let seconds = window["seconds"] as? Double, let value = window["similarity"] as? Double {
                    logs.record(.speakerMeasured, category: .audio, metrics: [.window: Double(index + 1), .seconds: seconds, .similarity: value])
                }
            }
        }
        if settings.speakerMode == "prefer" {
            diagnostics += String(format: "\n話者類似度 %.3f（参考値・単独発話を拒否するしきい値ではありません）", similarity)
            return
        }
        diagnostics = String(format: "話者類似度 %.3f（しきい値 %.3f）", similarity, settings.speakerThreshold)
        if let overall = result["overall_similarity"] as? Double {
            diagnostics += String(format: " / 発話全体 %.3f", overall)
        }
        if let windows = result["speaker_windows"] as? [[String: Any]] {
            let values = windows.compactMap { window -> String? in
                guard let seconds = window["seconds"] as? Double, let value = window["similarity"] as? Double else { return nil }
                return String(format: "%.2f秒: %.3f", seconds, value)
            }
            diagnostics += "\n区間別: " + values.joined(separator: "、")
        }
    }
    func requestScreenPermission() {
        guard canConfigure, settings.includeScreen else { return }
        Permissions.configureScreen()
        refreshPermissions()
    }
    func chooseReference(kind: String) {
        guard canConfigure, ["speaker", "voice"].contains(kind) else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.wav, .aiff, .mpeg4Audio, .mp3]; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            try PrivateStorage.prepare()
            let target = PrivateStorage.directory.appendingPathComponent("\(kind)-\(UUID().uuidString).wav")
            do { try AudioRecorder.importReference(from: source, to: target) }
            catch { try? FileManager.default.removeItem(at: target); throw error }
            do { try persistReference(kind: kind, path: target.path) }
            catch { try? FileManager.default.removeItem(at: target); throw error }
            detail = "参照音声をこのMacのアプリ用フォルダへコピーしました。他の設定は「変更を保存」で適用します。"
        } catch { fail(error) }
    }
    func startReference(kind: String) async {
        guard canConfigure, ["speaker", "voice"].contains(kind) else { return }
        stop(); let run = epoch
        phase = .preparing; detail = "許可済みのマイクで参照音声を録音します。"
        do {
            try Permissions.requireMicrophone()
            guard run == epoch else { return }
            try PrivateStorage.prepare()
            let url = PrivateStorage.directory.appendingPathComponent("\(kind)-\(UUID().uuidString).wav")
            let recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 24000,
                                                                     AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16])
            guard recorder.record(forDuration: 30) else { throw RelayError.message("参照音声の録音を開始できません。") }
            referenceRecorder = recorder; referenceKind = kind; referenceURL = url; referenceRecording = true
            phase = .recording
            detail = "参照音声を録音中です。10〜20秒話し、録音終了を押してください（最大30秒）。"
            operation = Task { try? await Task.sleep(nanoseconds: 30_000_000_000); if !Task.isCancelled { finishReference() } }
        } catch { if run == epoch { fail(error) } }
    }
    func finishReference() {
        guard referenceRecording, let recorder = referenceRecorder, let url = referenceURL else { return }
        recorder.stop(); operation?.cancel(); referenceRecorder = nil; referenceRecording = false
        phase = .stopped
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let audioFile = try AVAudioFile(forReading: url)
            guard Double(audioFile.length) / audioFile.processingFormat.sampleRate >= 3 else {
                try? FileManager.default.removeItem(at: url)
                throw RelayError.message("録音が3秒未満です。10〜20秒の参照音声を録り直してください。")
            }
            try persistReference(kind: referenceKind, path: url.path)
            detail = "参照音声を保存しました。これは追加学習ではありません。声の再現用には読んだ本文も入力してください。"
        } catch { fail(error) }
    }
    func stop() {
        indicator = .idle
        logs.record(.stopped)
        let wasSending = phase == .sending
        cancelRoomSearch()
        epoch = UUID(); operation?.cancel(); armTimeout?.cancel(); inputWatchdog?.cancel(); recorder.stop(); waitingSound.stop(); speech.stop(); worker.shutdown()
        voiceStandbyStatus = "音声待機: 停止（モデルを解放）"
        if referenceRecording { referenceRecorder?.stop(); if let referenceURL { try? FileManager.default.removeItem(at: referenceURL) } }
        referenceRecording = false; referenceRecorder = nil
        listening = false; processing = false; inputRevision = UUID(); chunks = []; wake.reset(); level = 0; draft = nil; phase = .stopped
        microphoneTestProgress = nil
        detail = wasSending ? "送信中に停止しました。成否はWebexのDMで確認してください。自動再送しません。" : "停止しました。マイクを解放しています。"
    }
    private func fail(_ error: Error) {
        let category: LogCategory
        switch phase {
        case .speaking: category = .speech
        case .recording, .recognizing, .listening: category = .audio
        case .sending, .waiting: category = .webex
        default: category = .app
        }
        stop()
        if case RelayError.missingPermissions = error { permissionError = true } else { permissionError = false }
        phase = .error; detail = error.localizedDescription
        logs.failure(error, category: category)
        if case RelayError.unauthorized = error { handleAuthenticationFailure() }
    }
}
