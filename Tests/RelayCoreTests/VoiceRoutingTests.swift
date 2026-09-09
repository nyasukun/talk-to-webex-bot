import Testing
import Foundation
@testable import RelayCore

struct VoiceRoutingTests {
    @Test func separateWakePhrasesRetainModeAcrossPauseAndSwitchExplicitly() {
        var router = VoiceRouter()
        let now = Date(), normal = "オッケー、アシスタント", reply = "オッケー、返信して"
        func accept(_ text: String, after seconds: Double = 0) -> VoiceRouter.Result {
            router.accept(text, phrases: normal, replyPhrases: reply, now: now.addingTimeInterval(seconds), timeout: 12)
        }
        #expect(accept("オッケー、返信して。続けてください") == .command("続けてください", .threadReply))
        #expect(accept(reply) == .armed(.threadReply))
        #expect(accept("ありがとうございます", after: 2) == .command("ありがとうございます", .threadReply))
        #expect(accept(reply) == .armed(.threadReply))
        #expect(accept("遅れました", after: 13) == .ignored)
        #expect(accept(reply) == .armed(.threadReply))
        #expect(accept(normal) == .armed(.message))
        #expect(accept("新しい話題です", after: 1) == .command("新しい話題です", .message))
        router.reset()
        #expect(accept("普通の会話です") == .ignored)
    }
    @Test func ambiguousWakePhrasesAreRejectedAndReplyCanBeDisabled() throws {
        var settings = Settings()
        settings.replyWakePhrases = "オーケー、アシスタント"
        #expect(throws: (any Error).self) { try settings.validate() }
        settings.replyWakePhrases = ""
        settings.replyTemplate = "{{transcript}}"
        try settings.validate()
        let text = try MessageTemplate.render(settings.replyTemplate, transcript: "ありがとうございます。続けてください。", ocr: nil, screen: false)
        #expect(text == "ありがとうございます。続けてください。")
    }
    @Test func threadTargetsUseRootAndRejectDifferentDM() throws {
        let root = Message(id: "reply", roomId: "room", text: "回答")
        #expect(ThreadReplyTarget(message: root).parentID == "reply")
        let child = Message(id: "child", roomId: "room", text: "続き", parentId: "root")
        let target = ThreadReplyTarget(message: child)
        #expect(target.parentID == "root")
        try target.require(roomID: "room")
        #expect(throws: (any Error).self) { try target.require(roomID: "another") }
    }
    @Test func threadedFollowUpTracksOnlyNewRepliesInTheSameRoot() {
        let request = Message(id: "follow-up", roomId: "room", personId: "self", text: "続けて", created: "2026-01-01T00:00:00Z", parentId: "root")
        var tracker = ReplyTracker(request: request, ownPersonID: "self", baseline: ["old"], settleSeconds: 2, busyPhrases: ["Working..."])
        let working = Message(id: "new", roomId: "room", personId: "other", text: "Working...", created: "2026-01-01T00:00:01Z", parentId: "root")
        let final = Message(id: "new", roomId: "room", personId: "other", text: "続きの回答", created: "2026-01-01T00:00:01Z", parentId: "root")
        let unrelated = Message(id: "unrelated", roomId: "room", personId: "other", text: "別の話題", created: "2026-01-01T00:00:02Z")
        let now = Date()
        #expect(tracker.ingest([working, unrelated], now: now).isEmpty)
        #expect(tracker.ingest([final, unrelated], now: now.addingTimeInterval(1)).isEmpty)
        #expect(tracker.ingest([final, unrelated], now: now.addingTimeInterval(3)) == ["続きの回答"])
        #expect(tracker.readyMessages.map(\.id) == ["new"])
        #expect(tracker.candidateIDs == ["new"])
        #expect(tracker.bodyUpdateCount == 1)
        #expect(tracker.ingest([final], now: now.addingTimeInterval(6)).isEmpty)
    }
    @Test func microphoneRecoveryIsBoundedAndRearmsAfterQuietPeriod() {
        var recovery = AudioRecovery()
        let now = Date()
        #expect({ recovery.permit(at: now) }())
        #expect({ recovery.permit(at: now.addingTimeInterval(4)) }())
        #expect({ !recovery.permit(at: now.addingTimeInterval(8)) }())
        #expect({ recovery.permit(at: now.addingTimeInterval(31)) }())
        recovery.reset()
        #expect({ recovery.permit(at: now.addingTimeInterval(32)) }())
    }
    @Test func threadSendUsesOnlyTranscriptAndExplicitParentWithoutRetryingAmbiguousResults() async throws {
        let transport = MockTransport([.init(status: 200, json: "{\"id\":\"sent\",\"roomId\":\"room\",\"parentId\":\"root\"}")])
        let client = WebexClient(token: "test-placeholder", transport: transport)
        let body = try MessageTemplate.render("{{transcript}}", transcript: "続けてください。", ocr: nil, screen: false)
        let sent = try await client.send(roomID: "room", text: body, png: nil, parentID: "root")
        #expect(sent.parentId == "root")
        let request = await transport.last()!
        let json = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
        #expect(json == ["roomId": "room", "parentId": "root", "text": "続けてください。"])
        let failed = MockTransport([.init(status: 503, json: "{}")])
        do {
            _ = try await WebexClient(token: "test-placeholder", transport: failed).send(roomID: "room", text: body, png: nil, parentID: "root")
            Issue.record("Expected ambiguous send")
        } catch { guard case RelayError.ambiguousSend = error else { Issue.record("Unexpected error"); return } }
        #expect(await failed.count() == 1)
    }
    @Test func recoveryRearmsAfterSuccessfulCredentialUpdate() {
        var recovery = TokenRecovery()
        #expect({ recovery.unauthorized() }())
        #expect({ !recovery.unauthorized() }())
        recovery.authenticated()
        #expect({ recovery.unauthorized() }())
    }
    @Test func defaultThreadPromptIncludesOnlyNewTranscriptAndInstructions() async throws {
        let transport = MockTransport([.init(status: 200, json: #"{"id":"sent","roomId":"room","parentId":"root"}"#)])
        let body = try MessageTemplate.render(Settings().replyTemplate, transcript: "午後の予定だけ教えてください。", ocr: nil, screen: false)
        #expect(body.contains("同じスレッド内"))
        #expect(body.contains("以上の会話のコンテキストとユーザ返信"))
        #expect(body.contains(MessageTemplate.speechInstructions))
        #expect(body.contains(MessageTemplate.numberInstructions))
        #expect(!body.contains("OCR"))
        #expect(!body.contains("{{"))
        #expect(body.components(separatedBy: "```").count == 3)
        #expect(body.components(separatedBy: "```")[1].trimmingCharacters(in: .whitespacesAndNewlines) == "午後の予定だけ教えてください。")
        _ = try await WebexClient(token: "test-placeholder", transport: transport).send(roomID: "room", text: body, png: nil, parentID: "root")
        let request = await transport.last()!
        let json = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
        #expect(json == ["roomId": "room", "parentId": "root", "text": body])
    }
}
