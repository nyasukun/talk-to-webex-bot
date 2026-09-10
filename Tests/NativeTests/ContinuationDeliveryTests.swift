import Testing
import Foundation
import RelayCore
@testable import LocalVoiceRelay

private actor ContinuationTransport: HTTPTransport {
    var bodies: [[String: String]] = []
    var pause = false
    var pending: CheckedContinuation<Void, Never>?
    var failSend = false
    func pauseSend() { pause = true }
    func failNextSend() { failSend = true }
    func isPaused() -> Bool { pending != nil }
    func resume() { pending?.resume(); pending = nil }
    func sentBodies() -> [[String: String]] { bodies }
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        if request.httpMethod == "POST" {
            let body = try JSONDecoder().decode([String: String].self, from: request.httpBody!)
            bodies.append(body)
            if pause {
                pause = false
                await withCheckedContinuation { pending = $0 }
            }
            if failSend { throw URLError(.timedOut) }
            data = try JSONEncoder().encode(Message(id: "sent-\(bodies.count)", roomId: body["roomId"]!, personId: "self",
                text: body["text"], created: "2025-01-01T00:00:0\(bodies.count)Z", parentId: body["parentId"]))
        } else if request.url!.path.hasSuffix("people/me") {
            data = Data(#"{"id":"self"}"#.utf8)
        } else { data = Data(#"{"items":[]}"#.utf8) }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor struct ContinuationDeliveryTests {
    private let start = Date(timeIntervalSince1970: 1000)
    private func interval(_ from: Double, _ to: Double) -> SpeechInterval {
        SpeechInterval(startedAt: start.addingTimeInterval(from), lastVoiceAt: start.addingTimeInterval(to))
    }
    private func model(_ transport: ContinuationTransport) -> AppModel {
        let model = AppModel(preview: true)
        model.settings.roomID = "room"
        model.settings.includeScreen = false
        model.settings.confirmBeforeSending = false
        model.settings.readReplies = true
        model.settings.template = "{{transcript}}"
        model.settings.replyTemplate = "{{transcript}}"
        model.client = WebexClient(token: "synthetic", transport: transport)
        return model
    }

    @Test func cumulativeSendsReplaceOnlyTheLatestDeliveryAndPreserveDestination() async throws {
        let transport = ContinuationTransport()
        let model = model(transport)
        defer { model.stop() }
        try await model.prepareVoiceCommand("最初の指示", mode: .message, speech: interval(0, 1), run: model.epoch)
        #expect(model.voiceDelivery?.sent.id == "sent-1")
        // Current wall time is much later than these capture times; latency cannot reject this continuation.
        try await model.appendVoiceCommand("追加の条件", speech: interval(4.5, 8), run: model.epoch)
        try await model.appendVoiceCommand("最後の条件", speech: interval(10, 11), run: model.epoch)
        let bodies = await transport.sentBodies()
        #expect(bodies.map { $0["text"]! } == ["最初の指示", "最初の指示\n追加の条件", "最初の指示\n追加の条件\n最後の条件"])
        #expect(bodies.allSatisfy { $0["roomId"] == "room" && $0["parentId"] == nil })
        #expect(model.voiceDelivery?.sent.id == "sent-3")
        #expect(model.voiceSentIDs == ["sent-1", "sent-2", "sent-3"])
        #expect(!model.logs.entries.contains { $0.event == .replyProgress || $0.event == .speechStarted })
        try await model.appendVoiceCommand("期限外", speech: interval(14.6, 16), run: model.epoch)
        #expect(await transport.sentBodies().count == 3)
    }

    @Test func confirmationCollectsSpeechWithoutPostingAndThenPresentsCombinedDraft() async throws {
        let transport = ContinuationTransport()
        let model = model(transport)
        model.settings.confirmBeforeSending = true
        defer { model.stop() }
        try await model.prepareVoiceCommand("first", mode: .message, speech: interval(0, 1), run: model.epoch)
        try await model.appendVoiceCommand("second", speech: interval(3, 4), run: model.epoch)
        #expect(model.draft == nil)
        #expect(await transport.sentBodies().isEmpty)
        try await model.finishVoiceInput(run: model.epoch)
        #expect(model.phase == .confirming)
        #expect(model.draft?.body == "first\nsecond")
        #expect(await transport.sentBodies().isEmpty)
    }

    @Test func threadContinuationKeepsTheOriginalThreadAndUsesOnlyNewSpeech() async throws {
        let transport = ContinuationTransport()
        let model = model(transport)
        defer { model.stop() }
        model.lastReplyTarget = ThreadReplyTarget(message: Message(id: "reply", roomId: "room", text: "previous answer", parentId: "root"))
        try await model.prepareVoiceCommand("new command", mode: .threadReply, speech: interval(0, 1), run: model.epoch)
        try await model.appendVoiceCommand("more", speech: interval(3, 4), run: model.epoch)
        let bodies = await transport.sentBodies()
        #expect(bodies.map { $0["parentId"]! } == ["root", "root"])
        #expect(bodies.last?["text"] == "new command\nmore")
        try await model.finishVoiceInput(run: model.epoch)
        #expect(model.phase == .stopped)
        #expect(model.logs.entries.contains { $0.event == .replyCorrelationUnavailable })
        #expect(!model.logs.entries.contains { $0.event == .speechStarted })
    }

    @Test func disablingReadRepliesStillSendsContinuationsAndCompletes() async throws {
        let transport = ContinuationTransport()
        let model = model(transport)
        model.settings.readReplies = false
        defer { model.stop() }
        try await model.prepareVoiceCommand("first", mode: .message, speech: interval(0, 1), run: model.epoch)
        try await model.appendVoiceCommand("second", speech: interval(3, 4), run: model.epoch)
        #expect(await transport.sentBodies().count == 2)
        try await model.finishVoiceInput(run: model.epoch)
        #expect(model.phase == .stopped)
        #expect(model.voiceDelivery == nil)
        #expect(!model.logs.entries.contains { $0.event == .replyProgress || $0.event == .speechStarted })
    }

    @Test func stopDuringSendDiscardsLateCompletionAndPreventsFurtherSends() async throws {
        let transport = ContinuationTransport()
        let model = model(transport)
        await transport.pauseSend()
        let run = model.epoch
        let send = Task { try await model.prepareVoiceCommand("first", mode: .message, speech: interval(0, 1), run: run) }
        for _ in 0..<1000 {
            if await transport.isPaused() { break }
            await Task.yield()
        }
        #expect(await transport.isPaused())
        model.stop()
        await transport.resume()
        try await send.value
        try await model.appendVoiceCommand("late", speech: interval(3, 4), run: run)
        #expect(model.phase == .stopped)
        #expect(model.voiceDelivery == nil)
        #expect(model.voiceSentIDs.isEmpty)
        #expect(await transport.sentBodies().count == 1)
    }

    @Test func ambiguousContinuationIsNeverRetriedOrMadeTheMonitoredDelivery() async throws {
        let transport = ContinuationTransport()
        let model = model(transport)
        defer { model.stop() }
        try await model.prepareVoiceCommand("first", mode: .message, speech: interval(0, 1), run: model.epoch)
        await transport.failNextSend()
        do {
            try await model.appendVoiceCommand("second", speech: interval(3, 4), run: model.epoch)
            Issue.record("Expected ambiguous send")
        } catch {
            guard case RelayError.ambiguousSend = error else { Issue.record("Wrong error"); return }
            model.fail(error)
        }
        #expect(model.phase == .error)
        #expect(model.voiceDelivery == nil)
        #expect(await transport.sentBodies().count == 2)
    }
}
