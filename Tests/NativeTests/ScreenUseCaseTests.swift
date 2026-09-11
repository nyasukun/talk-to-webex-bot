import Foundation
import Testing
import RelayCore
@testable import LocalVoiceRelay

private actor ScreenTransport: HTTPTransport {
    var requests: [URLRequest] = []
    func captured() -> [URLRequest] { requests }
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let data: Data
        if request.httpMethod == "POST" {
            data = try JSONEncoder().encode(Message(id: "sent", roomId: "saved-room", personId: "self", text: "request", created: "2026-01-01T00:00:01Z"))
        } else if request.url!.path.hasSuffix("people/me") { data = Data(#"{"id":"self"}"#.utf8) }
        else { data = Data(#"{"items":[]}"#.utf8) }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor SuspendedVoiceTransport: HTTPTransport {
    private var firstPost: CheckedContinuation<Void, Error>?
    private var requests: [URLRequest] = []
    private var replies: [Message] = []
    func setReplies(_ replies: [Message]) { self.replies = replies }
    func captured() -> [URLRequest] { requests }
    var isSending: Bool { firstPost != nil }
    func release(error: Error? = nil) {
        if let error { firstPost?.resume(throwing: error) } else { firstPost?.resume() }
        firstPost = nil
    }
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let posts = requests.filter { $0.httpMethod == "POST" }.count
        if request.httpMethod == "POST", posts == 1 {
            try await withCheckedThrowingContinuation { firstPost = $0 }
        }
        let data: Data
        if request.httpMethod == "POST" {
            data = try JSONEncoder().encode(Message(id: "sent-\(posts)", roomId: "saved-room", personId: "self",
                text: "request", created: "2026-01-01T00:00:01Z"))
        } else if request.url!.path.hasSuffix("people/me") { data = Data(#"{"id":"self"}"#.utf8) }
        else { data = try JSONEncoder().encode(["items": replies]) }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor struct ScreenUseCaseIntegrationTests {
    private func model(_ transport: any HTTPTransport) -> AppModel {
        let model = AppModel(preview: true)
        model.settings.roomID = "saved-room"
        model.settings.readReplies = true // The use case's OFF must override the voice setting.
        model.settings.confirmBeforeSending = true
        model.savedSettings = model.settings
        model.permissionSnapshot = PermissionSnapshot(microphone: .denied, screen: true)
        model.client = WebexClient(token: "synthetic", transport: transport)
        model.captureScreen = { ScreenContext(png: Data("synthetic-png".utf8), ocr: "Screen {{ocr}} text") }
        return model
    }

    @Test func hotkeyAndRaycastPreserveVoiceDraftAndResumeOnlyOnceInEveryInputPhase() async throws {
        for phase in [AppModel.Phase.listening, .recording, .recognizing, .preparing] {
            let transport = ScreenTransport(), model = model(transport)
            defer { model.stop() }
            var starts = 0
            model.beginMicrophoneCapture = { _, _, _ in starts += 1 }
            model.frontmostBundleID = { "com.example.source" }
            model.listening = true
            model.phase = phase
            model.indicator = .receiving
            model.voiceInteraction = VoiceInteraction(command: "unfinished voice command",
                speech: .init(startedAt: Date(), lastVoiceAt: Date()), seconds: 30)
            model.voiceInteraction?.setDraft(AppModel.Draft(body: "unfinished voice command", screen: nil, settings: model.settings, thread: nil))
            let previousEpoch = model.epoch
            let id = model.savedSettings.screenUseCases[0].id
            if phase == .recognizing {
                try model.runRaycastUseCase(.init(useCaseID: id, createdAt: Date().timeIntervalSince1970,
                    expectedBundleID: "com.example.source"))
            } else { model.runScreenUseCase(id: id) }
            #expect(model.epoch != previousEpoch && model.screenUseCaseActive && model.listening)
            #expect(model.voiceInteraction == nil && !model.recorder.isCapturing)
            // Late input callbacks cannot replace the new screen operation.
            model.acceptAudioChunk(.init(samples: [], truncated: true))
            #expect(model.phase == .preparing)
            model.runScreenUseCase(id: id)
            await model.operation?.value
            let sends = await transport.captured().filter { $0.httpMethod == "POST" }
            #expect(sends.count == 1)
            #expect(!String(decoding: sends[0].httpBody!, as: UTF8.self).contains("unfinished voice command"))
            #expect(starts == 1 && model.listening && model.phase == .listening && model.indicator == .receiving)
            #expect(!model.screenUseCaseActive)
            #expect(model.voiceInteraction?.text == "unfinished voice command")
            try await model.appendVoiceCommand("continued instruction", speech: .init(startedAt: Date(), lastVoiceAt: Date()), run: model.epoch)
            #expect(model.voiceInteraction?.text == "unfinished voice command\ncontinued instruction")
            #expect(model.voiceInteraction?.draft?.body.contains("continued instruction") == true)
            #expect(await transport.captured().filter { $0.httpMethod == "POST" }.count == 1)
        }
    }

    @Test func cancelledAndFailedScreenActionsResumeVoiceButAnExplicitStopDoesNot() async throws {
        for outcome in ["cancel", "failure", "stop"] {
            let transport = ScreenTransport(), model = model(transport)
            defer { model.stop() }
            var starts = 0
            model.beginMicrophoneCapture = { _, _, _ in starts += 1 }
            model.listening = true
            model.phase = .recording
            model.voiceInteraction = VoiceInteraction(command: "preserved on cancel or capture failure",
                speech: .init(startedAt: Date(), lastVoiceAt: Date()), seconds: 30)
            model.voiceInteraction?.setDraft(AppModel.Draft(body: "preserved", screen: nil, settings: model.settings, thread: nil))
            model.savedSettings.screenUseCases[0].confirmBeforeSending = true
            if outcome == "failure" { model.captureScreen = { throw ScreenContext.Unavailable.noWindow } }
            model.runScreenUseCase(id: model.savedSettings.screenUseCases[0].id)
            await model.operation?.value
            if outcome == "cancel" { model.cancelDraft() }
            if outcome == "stop" { model.stop() }
            await model.operation?.value
            #expect(await transport.captured().isEmpty)
            #expect(starts == (outcome == "stop" ? 0 : 1))
            #expect(model.listening == (outcome != "stop"))
            #expect(!model.screenUseCaseActive)
            #expect((model.voiceInteraction != nil) == (outcome != "stop"))
        }
    }

    @Test func recognitionInFlightResumesItsAudioOnceAndIgnoresTheCancelledResult() async throws {
        let transport = ScreenTransport(), model = model(transport)
        defer { model.stop() }
        model.settings.wakePhrases = "computer"
        model.settings.includeScreen = false
        model.settings.speakerVerification = false
        model.settings.continuationSeconds = 30
        model.listening = true
        model.phase = .listening
        model.beginMicrophoneCapture = { _, _, _ in }
        var pending: CheckedContinuation<[String: Any], Never>?
        var recognitions = 0
        model.callVoiceWorker = { _, _, _ in
            recognitions += 1
            if recognitions == 1 { return await withCheckedContinuation { pending = $0 } }
            return ["text": recognitions == 2 ? "computer retained instruction" : "additional instruction"]
        }
        let spoken = AudioRecorder.Chunk(samples: [Float](repeating: 0.1, count: 8000), truncated: false,
            speech: .init(startedAt: Date().addingTimeInterval(-0.5), lastVoiceAt: Date()))
        model.acceptAudioChunk(spoken)
        let firstRecognition = try #require(model.operation)
        for _ in 0..<1000 { if pending != nil { break }; await Task.yield() }
        #expect(pending != nil && model.phase == .recognizing)
        model.runScreenUseCase(id: model.savedSettings.screenUseCases[0].id)
        let screenOperation = model.operation
        pending?.resume(returning: ["text": "computer stale duplicate"])
        await firstRecognition.value
        await screenOperation?.value
        for _ in 0..<1000 {
            if model.voiceInteraction?.draft != nil { break }
            if model.phase == .error { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(model.phase != .error, "\(model.detail)")
        #expect(recognitions == 2 && model.voiceInteraction?.text == "retained instruction")
        model.acceptAudioChunk(.init(samples: spoken.samples, truncated: false,
            speech: .init(startedAt: Date(), lastVoiceAt: Date().addingTimeInterval(0.1))))
        for _ in 0..<1000 {
            if model.voiceInteraction?.text.contains("additional instruction") == true { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(recognitions == 3 && model.voiceInteraction?.text == "retained instruction\nadditional instruction")
        #expect(await transport.captured().filter { $0.httpMethod == "POST" }.count == 1)
    }

    @Test func anArmedWakeResumesWithoutRepeatingTheWakePhrase() async throws {
        let transport = ScreenTransport(), model = model(transport)
        defer { model.stop() }
        model.settings.wakePhrases = "computer"
        model.settings.replyWakePhrases = "reply"
        model.settings.includeScreen = false
        model.settings.speakerVerification = false
        model.settings.commandWaitSeconds = 30 // Deadline freezing is tested with a deterministic 300-second shift in RelayCore.
        model.settings.continuationSeconds = 30
        model.lastReplyTarget = ThreadReplyTarget(message: Message(id: "previous-reply", roomId: "saved-room", personId: "bot", text: "earlier reply"))
        model.listening = true
        model.phase = .listening
        model.beginMicrophoneCapture = { _, _, _ in }
        var recognitions = 0
        model.callVoiceWorker = { _, _, _ in
            recognitions += 1
            return ["text": recognitions == 1 ? "reply" : "continued thread instruction"]
        }
        let audio = [Float](repeating: 0.1, count: 8000)
        model.acceptAudioChunk(.init(samples: audio, truncated: false,
            speech: .init(startedAt: Date().addingTimeInterval(-0.5), lastVoiceAt: Date())))
        await model.operation?.value
        #expect(model.indicator == .receiving && model.voiceInteraction == nil)
        model.runScreenUseCase(id: model.savedSettings.screenUseCases[0].id)
        await model.operation?.value
        #expect(model.indicator == .receiving && model.listening)
        model.acceptAudioChunk(.init(samples: audio, truncated: false,
            speech: .init(startedAt: Date(), lastVoiceAt: Date().addingTimeInterval(0.1))))
        for _ in 0..<1000 {
            if model.voiceInteraction?.draft != nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(recognitions == 2)
        #expect(model.phase != .error, "\(model.detail)")
        #expect(model.voiceInteraction?.text == "continued thread instruction", "\(model.recognizedInput); \(model.detail)")
        #expect(model.voiceInteraction?.draft?.thread?.parentID == "previous-reply")
        #expect(await transport.captured().filter { $0.httpMethod == "POST" }.count == 1)
    }

    @Test func anInFlightVoiceSendFinishesBeforeTheCapturedScreenRunsAndNeverRetries() async throws {
        for outcome in ["success", "failure", "rejected", "stop"] {
            let transport = SuspendedVoiceTransport(), model = model(transport)
            defer { model.stop() }
            var captures = 0, starts = 0
            model.beginMicrophoneCapture = { _, _, _ in starts += 1 }
            model.captureScreen = { captures += 1; return ScreenContext(png: Data("original-window".utf8), ocr: "original") }
            model.frontmostBundleID = { "com.example.source" }
            model.settings.includeScreen = false
            model.settings.confirmBeforeSending = false
            model.settings.readReplies = false
            model.listening = true
            model.launch { run in
                try await model.prepareVoiceCommand("already sending voice", mode: .message,
                    speech: .init(startedAt: Date(), lastVoiceAt: Date()), run: run)
            }
            let voiceOperation = try #require(model.operation)
            for _ in 0..<1000 { if await transport.isSending { break }; await Task.yield() }
            #expect(await transport.isSending && model.phase == .sending)
            let previousEpoch = model.epoch, id = model.savedSettings.screenUseCases[0].id
            try model.runRaycastUseCase(.init(useCaseID: id, createdAt: Date().timeIntervalSince1970,
                expectedBundleID: "com.example.source"))
            model.runScreenUseCase(id: id)
            #expect(model.queuedScreenUseCase != nil && model.screenUseCaseActive && model.epoch == previousEpoch)
            #expect(model.pausedVoiceInput != nil && !model.recorder.isCapturing)
            for _ in 0..<100 { if captures == 1 { break }; await Task.yield() }
            #expect(captures == 1) // Capture is not delayed until the HTTP request completes.
            model.savedSettings.screenUseCases[0].prompt = "changed after selection"
            if outcome == "stop" { model.stop() }
            let error: Error? = outcome == "failure" ? RelayError.ambiguousSend : outcome == "rejected" ? RelayError.rateLimited(60) : nil
            await transport.release(error: error)
            await voiceOperation.value
            if outcome == "success" {
                for _ in 0..<1000 {
                    if starts == 1 && !model.screenUseCaseActive { break }
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
            } else { await model.operation?.value }
            let sends = await transport.captured().filter { $0.httpMethod == "POST" }
            #expect(sends.count == (outcome == "success" ? 2 : 1))
            if outcome == "success" {
                let body = String(decoding: sends[1].httpBody!, as: UTF8.self)
                #expect(body.contains("original-window") && !body.contains("changed after selection") && !body.contains("already sending voice"))
                #expect(model.listening && model.phase == .listening && starts == 1)
                #expect(model.voiceInteraction?.text == "already sending voice" && model.voiceSentIDs == ["sent-1"])
                try await model.appendVoiceCommand("continued after screen", speech: .init(startedAt: Date(), lastVoiceAt: Date()), run: model.epoch)
                let continued = await transport.captured().filter { $0.httpMethod == "POST" }
                #expect(continued.count == 3)
                let voiceBody = String(decoding: continued[2].httpBody!, as: UTF8.self)
                #expect(voiceBody.contains("already sending voice") && voiceBody.contains("continued after screen") && !voiceBody.contains("original-window"))
            } else { #expect(!model.listening && starts == 0) }
            #expect(model.queuedScreenUseCase == nil && !model.screenUseCaseActive)
        }
    }

    @Test func sendsSavedPromptImageAndOCRWithoutMicrophoneOrSpeechAndIgnoresRepeatedTriggers() async throws {
        let transport = ScreenTransport(), model = model(transport)
        defer { model.stop() }
        let useCase = model.savedSettings.screenUseCases[0]
        var windowRequests = 0
        model.showMainWindow = { windowRequests += 1 }
        model.settings.roomID = "unsaved-room"
        model.settings.screenUseCases[0].prompt = "unsaved prompt"
        model.runScreenUseCase(id: useCase.id)
        model.runScreenUseCase(id: useCase.id)
        #expect(!model.listening && !model.recorder.isCapturing && model.screenUseCaseActive)
        await model.operation?.value
        let requests = await transport.captured()
        let sends = requests.filter { $0.httpMethod == "POST" }
        #expect(sends.count == 1)
        let body = String(decoding: sends.first!.httpBody!, as: UTF8.self)
        #expect(body.contains("saved-room") && !body.contains("unsaved-room"))
        #expect(body.contains(useCase.prompt) && body.contains("Screen {{ocr}} text") && body.contains("synthetic-png"))
        #expect(!body.contains("unsaved prompt") && !body.contains("parentId"))
        #expect(!requests.contains { $0.httpMethod == "GET" && $0.url!.path.hasSuffix("messages") })
        #expect(!model.logs.entries.contains { [.microphoneStarted, .speechStarted, .replyProgress].contains($0.event) })
        #expect(model.phase == .stopped && !model.screenUseCaseActive)
        #expect(windowRequests == 0)
    }

    @Test func microphoneRestartFailureStopsInsteadOfLooping() async throws {
        let transport = ScreenTransport(), model = model(transport)
        defer { model.stop() }
        model.listening = true
        model.phase = .recording
        var starts = 0
        model.beginMicrophoneCapture = { _, _, _ in
            starts += 1
            throw RelayError.message("synthetic microphone restart failure")
        }
        model.runScreenUseCase(id: model.savedSettings.screenUseCases[0].id)
        await model.operation?.value
        #expect(starts == 1 && model.phase == .error && !model.listening)
        #expect(model.pausedVoiceInput == nil && !model.screenUseCaseActive)
        #expect(await transport.captured().filter { $0.httpMethod == "POST" }.count == 1)
    }

    @Test func resumingTheOriginalReplyMonitorIgnoresTheInterveningScreenRequest() async throws {
        let transport = SuspendedVoiceTransport(), model = model(transport)
        defer { model.stop() }
        model.settings.includeScreen = false
        model.settings.confirmBeforeSending = false
        model.settings.continuationSeconds = 30
        model.settings.waitingSound = false
        model.settings.ttsEngine = "system"
        model.settings.replyTimeoutSeconds = 0.05
        model.beginMicrophoneCapture = { _, _, _ in }
        model.listening = true
        model.launch { run in
            try await model.prepareVoiceCommand("voice instruction", mode: .message,
                speech: .init(startedAt: Date(), lastVoiceAt: Date()), run: run)
        }
        for _ in 0..<1000 { if await transport.isSending { break }; await Task.yield() }
        await transport.release()
        await model.operation?.value
        model.runScreenUseCase(id: model.savedSettings.screenUseCases[0].id)
        await model.operation?.value
        #expect(model.voiceScreenRequestIDs == ["sent-2"])
        #expect(model.voiceDelivery?.sent.id == "sent-1")
        model.operation?.cancel()
        await model.operation?.value
        await transport.setReplies([
            Message(id: "sent-2", roomId: "saved-room", personId: "self", text: "screen request", created: "2026-01-01T00:00:02Z"),
            Message(id: "ambiguous", roomId: "saved-room", personId: "bot", text: "unthreaded reply", created: "2026-01-01T00:00:03Z"),
            Message(id: "screen-reply", roomId: "saved-room", personId: "bot", text: "screen answer", created: "2026-01-01T00:00:03Z", parentId: "sent-2"),
            Message(id: "voice-reply", roomId: "saved-room", personId: "bot", text: "voice answer", created: "2026-01-01T00:00:03Z", parentId: "sent-1")
        ])
        try await model.finishVoiceInput(run: model.epoch)
        #expect(model.listening && model.phase == .listening)
        #expect(model.logs.entries.contains { $0.event == .replyProgress && $0.metrics[LogMetric.candidates.rawValue] == 1 })
        #expect(!model.logs.entries.contains { $0.event == .speechStarted })
        #expect(await transport.captured().filter { $0.httpMethod == "POST" }.count == 2)
    }

    @Test func rawAudioIsRestoredAndTruncatedQueuedAudioIsStillRejected() async throws {
        let transport = ScreenTransport(), model = model(transport)
        defer { model.stop() }
        model.listening = true
        model.phase = .recording
        let before = Date()
        var segmenter = AudioSegmenter()
        _ = segmenter.ingest([Float](repeating: 0.1, count: 8000), isVoiced: true, endingAt: before, silenceSeconds: 1.2)
        model.pausedVoiceInput = AppModel.PausedVoiceInput(pausedAt: before.addingTimeInterval(-300), wake: VoiceRouter(),
            interaction: nil, audio: AudioRecorder.PausedInput(segmenter: segmenter, chunks: [.init(samples: [], truncated: true)]),
            chunks: [], transcript: "", recognizedInput: "", reply: "", replyTarget: nil, indicator: .receiving)
        var resumed: AudioRecorder.PausedInput?
        model.beginMicrophoneCapture = { _, _, saved in resumed = saved }
        var recognitions = 0
        model.callVoiceWorker = { _, _, _ in recognitions += 1; return ["text": "must not transcribe discarded audio"] }
        model.runScreenUseCase(id: model.savedSettings.screenUseCases[0].id)
        await model.operation?.value
        let restored = try #require(resumed)
        #expect(restored.segmenter.pendingSpeech!.lastVoiceAt.timeIntervalSince(before) >= 300)
        #expect(restored.chunks.isEmpty)
        #expect(model.logs.entries.contains { $0.event == .utteranceDiscarded })
        #expect(recognitions == 0 && model.listening)
    }

    @Test func confirmationKeepsItsSnapshotAndReadAloudOverrideWithoutStartingAudio() async throws {
        let transport = ScreenTransport(), model = model(transport)
        defer { model.stop() }
        model.savedSettings.screenUseCases[0].confirmBeforeSending = true
        model.savedSettings.screenUseCases[0].readReplies = true
        model.savedSettings.changeLanguage(to: .english)
        model.runScreenUseCase(id: model.savedSettings.screenUseCases[0].id)
        await model.operation?.value
        let draft = try #require(model.draft)
        #expect(model.phase == .confirming && model.screenUseCaseActive)
        #expect(draft.screen != nil && draft.settings.includeScreen && draft.settings.readReplies)
        #expect(draft.settings.language == .japanese)
        #expect(draft.thread == nil)
        #expect(!model.listening && !model.recorder.isCapturing)
        #expect(await transport.captured().isEmpty)
        model.cancelDraft()
        #expect(!model.screenUseCaseActive && model.draft == nil)
    }

    @Test func missingCaptureAndPermissionsNeverSend() async {
        for error in [ScreenContext.Unavailable.noWindow as Error, ScreenContext.Unavailable.changedWindow,
                      ScreenContext.Unavailable.inactiveSession, RelayError.missingPermissions(["screen"])] {
            let transport = ScreenTransport(), model = model(transport)
            defer { model.stop() }
            model.captureScreen = { throw error }
            model.runScreenUseCase(id: model.savedSettings.screenUseCases[0].id)
            await model.operation?.value
            #expect(model.phase == .error)
            #expect(await transport.captured().isEmpty)
        }
    }

    @Test func stoppingDuringCaptureDiscardsLateResultAndBusyOrDisabledCasesNeverStart() async {
        let transport = ScreenTransport(), model = model(transport)
        defer { model.stop() }
        var pending: CheckedContinuation<ScreenContext, Never>?
        model.captureScreen = { await withCheckedContinuation { pending = $0 } }
        let id = model.savedSettings.screenUseCases[0].id
        model.phase = .sending
        model.runScreenUseCase(id: id)
        #expect(model.operation == nil)
        model.phase = .stopped
        model.savedSettings.screenUseCases[0].enabled = false
        model.runScreenUseCase(id: id)
        #expect(model.operation == nil)
        model.savedSettings.screenUseCases[0].enabled = true
        model.runScreenUseCase(id: id)
        let operation = model.operation
        for _ in 0..<1000 { if pending != nil { break }; await Task.yield() }
        #expect(pending != nil)
        model.stop()
        pending?.resume(returning: ScreenContext(png: Data(), ocr: "late"))
        await operation?.value
        #expect(model.phase == .stopped && !model.screenUseCaseActive)
        #expect(await transport.captured().isEmpty)
    }

    @Test func editingCopiesUseCasesWithNewIdentityAndNoConflictingKey() {
        let model = AppModel(preview: true)
        let first = model.settings.screenUseCases[0]
        model.duplicateScreenUseCase(id: first.id)
        #expect(model.settings.screenUseCases.count == 3)
        let copy = model.settings.screenUseCases[2]
        #expect(copy.id != first.id && copy.prompt == first.prompt && copy.hotkey == nil)
        model.removeScreenUseCase(id: first.id)
        #expect(model.settings.screenUseCases.count == 2)
        model.addScreenUseCase()
        #expect(model.settings.screenUseCases.count == 3)
        model.discardSettingsChanges()
        #expect(model.settings.screenUseCases == ScreenUseCase.defaults)
    }
}
