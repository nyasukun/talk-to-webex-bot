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

@MainActor struct ScreenUseCaseIntegrationTests {
    private func model(_ transport: ScreenTransport) -> AppModel {
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

    @Test func sendsSavedPromptImageAndOCRWithoutMicrophoneOrSpeechAndIgnoresRepeatedTriggers() async throws {
        let transport = ScreenTransport(), model = model(transport)
        defer { model.stop() }
        let useCase = model.savedSettings.screenUseCases[0]
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
