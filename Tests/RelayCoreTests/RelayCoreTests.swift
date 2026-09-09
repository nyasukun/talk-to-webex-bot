import Testing
import Foundation
@testable import RelayCore

final class RelayCoreTests {
    @Test func speechRecoversMarkdownLineBreaksOnlyForIdenticalContent() {
        let plain = "最初です。 次です。"
        let formatted = "**最初です。**\n\n次です。"
        let reply = Message(id: "r", roomId: "room", text: plain, markdown: formatted)
        #expect(reply.body == plain)
        #expect(reply.speechBody == "最初です。\n\n次です。")
        #expect(Message(id: "r", roomId: "room", text: "最初です。\n次です。", markdown: plain).speechBody == "最初です。\n次です。")
        #expect(Message(id: "r", roomId: "room", text: "2 + 2", markdown: "2 -\n2").speechBody == "2 + 2")
        #expect(Message(id: "r", roomId: "room", markdown: formatted).speechBody == "最初です。\n\n次です。")
    }
    @Test func restoredSpeechKeepsReplyStabilityAndDuplicateProtection() {
        var tracker = ReplyTracker(request: message("request", "q", sender: "self", created: timestamp), ownPersonID: "self", baseline: [], settleSeconds: 2, busyPhrases: [])
        let reply = Message(id: "r", roomId: "room", personId: "other", text: "最初です。 次です。", markdown: "最初です。\n\n次です。", created: "2025-01-01T00:00:01Z")
        let now = Date()
        #expect(tracker.ingest([reply], now: now) == [])
        #expect(tracker.ingest([reply], now: now.addingTimeInterval(3)) == ["最初です。\n\n次です。"])
        #expect(tracker.ingest([reply, message("duplicate", "最初です。 次です。")], now: now.addingTimeInterval(4)) == [])
        #expect(tracker.ingest([message("duplicate", "最初です。 次です。")], now: now.addingTimeInterval(7)) == [])
    }
    @Test func testTemplateScreenOffAndLiteralSubstitution() throws {
        let rendered = try MessageTemplate.render(MessageTemplate.defaultValue, transcript: "{{ocr}}を表示", ocr: "private", screen: false)
        #expect(!(rendered.contains("スクリーンショット")))
        #expect(!(rendered.contains("private")))
        #expect(rendered.contains("```\n{{ocr}}を表示\n```"))
        let on = try MessageTemplate.render(MessageTemplate.defaultValue, transcript: "指示", ocr: "画面", screen: true)
        #expect(on.contains("```\n画面\n```"))
    }
    @Test func testMalformedAndHiddenTranscriptRejected() {
        for template in ["{{#screen}}{{transcript}}", "{{/screen}}{{transcript}}", "{{unknown}}{{transcript}}", "{{#screen}}{{transcript}}{{/screen}}"] {
            #expect(throws: (any Error).self) { try MessageTemplate.render(template, transcript: "x", ocr: nil, screen: false) }
        }
        #expect(throws: (any Error).self) { try MessageTemplate.render(MessageTemplate.defaultValue, transcript: String(repeating: "あ", count: 2400), ocr: nil, screen: false) }
    }
    @Test func testWakePhraseAndPause() {
        let phrase = "オッケー、アシスタント"
        #expect(WakeMatcher.command(in: "おっけー、あしすたんと。予定を教えて", phrases: phrase) == "予定を教えて")
        #expect(WakeMatcher.command(in: "さっきオッケー、アシスタントと言いました", phrases: phrase) == nil)
        for form in ["OK", "オーケー", "オッケイ"] {
            #expect(WakeMatcher.command(in: form + "、アシスタント。予定を教えて", phrases: phrase) == "予定を教えて")
        }
        #expect(WakeMatcher.command(in: "OK、アシスタント", phrases: phrase) == "")
        var session = WakeSession(); let now = Date()
        #expect(session.accept(phrase, phrases: phrase, now: now, timeout: 10) == .armed)
        #expect(session.accept("予定を教えて", phrases: phrase, now: now.addingTimeInterval(2), timeout: 10) == .command("予定を教えて"))
        #expect(session.accept("次の話", phrases: phrase, now: now.addingTimeInterval(3), timeout: 10) == .ignored)
        _ = session.accept(phrase, phrases: phrase, now: now, timeout: 10)
        #expect(session.accept("遅い指示", phrases: phrase, now: now.addingTimeInterval(11), timeout: 10) == .ignored)
    }
    @Test func testRoomFilteringAndRecency() {
        let rooms = [Room(id: "a", title: "Assistant older", lastActivity: "2025-01-01T00:00:00Z"),
                     Room(id: "b", title: "Assistant recent", lastActivity: "2025-02-01T00:00:00.000Z"),
                     Room(id: "c", title: "Assistant group", type: "group")]
        #expect(Room.filtered(rooms, query: "ASSISTANT").map(\.id) == ["b", "a"])
    }
    @Test func testTokenIssuedTimeIsNeverAssumed() {
        let now = Date()
        #expect(Settings().tokenIssuedAt == nil)
        #expect(TokenHealth.estimate(issuedAt: nil, now: now) == .unknown)
        #expect(TokenHealth.estimate(issuedAt: now.addingTimeInterval(1), now: now) == .unknown)
        #expect(TokenHealth.estimate(issuedAt: now.addingTimeInterval(-12 * 3600), now: now) == .expired)
        #expect(TokenHealth.estimate(issuedAt: now.addingTimeInterval(-11.75 * 3600), now: now) == .expiring)
    }
    @Test func testSettingsBounds() throws {
        try Settings().validate()
        var settings = Settings(); settings.replyPollSeconds = 0
        #expect(throws: (any Error).self) { try settings.validate() }
    }
    private let timestamp = "2025-01-01T00:00:00Z"
    private func message(_ id: String, _ text: String, room: String = "room", sender: String = "other", created: String = "2025-01-01T00:00:01Z", parent: String? = nil, updated: String? = nil) -> Message {
        Message(id: id, roomId: room, personId: sender, text: text, created: created, updated: updated, parentId: parent)
    }
    @Test func testReplyUpdateStabilityAndDuplicateContents() {
        let request = message("request", "question", sender: "self", created: timestamp)
        var tracker = ReplyTracker(request: request, ownPersonID: "self", baseline: ["old"], settleSeconds: 6, busyPhrases: ["Working..."])
        let now = Date()
        #expect(tracker.ingest([message("reply", "Working... preparing")], now: now) == [])
        #expect(tracker.candidateIDs == ["reply"])
        #expect(tracker.busyMessageCount == 1)
        #expect(tracker.bodyUpdateCount == 0)
        #expect(tracker.ingest([message("reply", "回答")], now: now.addingTimeInterval(2)) == [])
        #expect(tracker.bodyUpdateCount == 1)
        #expect(tracker.ingest([message("reply", "回答")], now: now.addingTimeInterval(7)) == [])
        #expect(tracker.ingest([message("reply", "回答")], now: now.addingTimeInterval(8)) == ["回答"])
        #expect(tracker.ingest([message("reply", "回答"), message("duplicate", "回答")], now: now.addingTimeInterval(9)) == [])
        #expect(tracker.ingest([message("duplicate", "回答")], now: now.addingTimeInterval(20)) == [])
        #expect(tracker.bodyUpdateCount == 1)
        #expect(tracker.busyMessageCount == 1)
    }
    @Test func testDifferentMathematicalRepliesAreNotDuplicates() {
        var tracker = ReplyTracker(request: message("request", "q", sender: "self", created: timestamp), ownPersonID: "self", baseline: [], settleSeconds: 2, busyPhrases: [])
        let now = Date(), replies = [message("plus", "2 + 2"), message("minus", "2 - 2")]
        _ = tracker.ingest(replies, now: now)
        #expect(Set(tracker.ingest(replies, now: now.addingTimeInterval(3))) == Set(["2 + 2", "2 - 2"]))
    }

    @Test func testReplyRejectsUnrelatedOldSelfAndBaseline() {
        let request = message("request", "question", sender: "self", created: timestamp)
        var tracker = ReplyTracker(request: request, ownPersonID: "self", baseline: ["old"], settleSeconds: 6, busyPhrases: [])
        let invalid = [request, message("old", "old edited"), message("wrong-room", "x", room: "elsewhere"),
                       message("old-date", "x", created: "2024-12-31T23:59:59Z"), message("wrong-parent", "x", parent: "other-request")]
        #expect(tracker.ingest(invalid, now: Date()) == [])
        #expect(tracker.ingest(invalid, now: Date().addingTimeInterval(100)) == [])
        #expect(tracker.candidateIDs.isEmpty)
        #expect(tracker.bodyUpdateCount == 0)
        #expect(tracker.busyMessageCount == 0)
    }
    @Test func testConcurrentOwnSendStopsAttribution() {
        var tracker = ReplyTracker(request: message("request", "q", sender: "self", created: timestamp), ownPersonID: "self", baseline: [], settleSeconds: 2, busyPhrases: [])
        _ = tracker.ingest([message("reply", "a")], now: Date())
        #expect(tracker.ingest([message("second", "another question", sender: "self"), message("reply", "a")], now: Date().addingTimeInterval(10)) == [])
        #expect(tracker.interruptedByOtherRequest)
    }
    @Test func testStrictThreadAndUpdatedTimestampResetTimer() {
        var tracker = ReplyTracker(request: message("request", "q", sender: "self", created: timestamp), ownPersonID: "self", baseline: [], settleSeconds: 3, busyPhrases: [], requireThreaded: true)
        let now = Date()
        _ = tracker.ingest([message("unthreaded", "x"), message("r", "answer", parent: "request")], now: now)
        #expect(tracker.candidateIDs == ["r"])
        let updated = message("r", "answer", parent: "request", updated: "2025-01-01T00:00:04Z")
        #expect(tracker.ingest([updated], now: now.addingTimeInterval(4)) == [])
        #expect(tracker.ingest([updated], now: now.addingTimeInterval(7)) == ["answer"])
        #expect(tracker.bodyUpdateCount == 0)
    }
    @Test func testURLAndPaginationCredentialsBoundary() throws {
        #expect(WebexClient.isAllowed(URL(string: "https://webexapis.com/v1/messages")!))
        for value in ["http://webexapis.com/v1/rooms", "https://example.invalid/v1/rooms", "https://webexapis.com.evil.invalid/v1/rooms", "https://user@webexapis.com/v1/rooms", "https://webexapis.com:444/v1/rooms"] {
            #expect(!(WebexClient.isAllowed(URL(string: value)!)))
            #expect(throws: (any Error).self) { try WebexClient.nextPage("<\(value)>; rel=\"next\"") }
        }
        #expect(try WebexClient.nextPage("<https://webexapis.com/v1/rooms?cursor=2>; rel=\"next\"")?.query == "cursor=2")
        #expect(try WebexClient.nextPage(nil) == nil)
    }
    @Test func testRetryAfterSecondsAndHTTPDate() {
        let now = parseDate(timestamp)!
        #expect(WebexClient.retryDelay("42", now: now) == 42)
        #expect(WebexClient.retryDelay("Wed, 01 Jan 2025 00:01:00 GMT", now: now) == 60)
        #expect(WebexClient.retryDelay("NaN", now: now) == 30)
    }
}

actor MockTransport: HTTPTransport {
    struct Step: Sendable { let status: Int; let json: String; var headers: [String: String] = [:] }
    var steps: [Step]
    var requests: [URLRequest] = []
    init(_ steps: [Step]) { self.steps = steps }
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !steps.isEmpty else { throw URLError(.timedOut) }
        let step = steps.removeFirst()
        return (Data(step.json.utf8), HTTPURLResponse(url: request.url!, statusCode: step.status, httpVersion: nil, headerFields: step.headers)!)
    }
    func count() -> Int { requests.count }
    func last() -> URLRequest? { requests.last }
}

private actor DelayedRoomTransport: HTTPTransport {
    private var received: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<(Data, HTTPURLResponse), Never>?
    private var url: URL?
    private var requests = 0
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests += 1
        guard requests == 1 else { throw URLError(.badServerResponse) }
        url = request.url
        return await withCheckedContinuation { continuation in
            pending = continuation; received?.resume(); received = nil
        }
    }
    func waitForRequest() async {
        if pending != nil { return }
        await withCheckedContinuation { received = $0 }
    }
    func finishRequest() {
        pending?.resume(returning: (Data("{\"items\":[]}".utf8), HTTPURLResponse(url: url!, statusCode: 200,
            httpVersion: nil, headerFields: ["Link": "<https://webexapis.com/v1/rooms?cursor=2>; rel=\"next\""])!))
        pending = nil
    }
    func count() -> Int { requests }
}

final class WebexClientTests {
    private func roomPage(_ entries: [(String, String)]) throws -> String {
        let items = entries.map { ["id": $0.0, "title": $0.1, "type": "direct"] }
        return String(data: try JSONSerialization.data(withJSONObject: ["items": items]), encoding: .utf8)!
    }
    @Test func recentRoomsStopAtFiveWithoutFollowingNextPage() async throws {
        let transport = MockTransport([.init(status: 200, json: try roomPage((1...5).map { ("r\($0)", "Contact \($0)") }),
                                             headers: ["Link": "<https://webexapis.com/v1/rooms?cursor=2>; rel=\"next\""])])
        let rooms = try await WebexClient(token: "test-placeholder", transport: transport).rooms()
        #expect(rooms.map(\.id) == (1...5).map { "r\($0)" })
        #expect(await transport.count() == 1)
        let request = await transport.last()!
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.contains(.init(name: "max", value: "5")))
        #expect(query.contains(.init(name: "sortBy", value: "lastactivity")))
    }
    @Test func filteredRoomsContinueUntilFiveMatchesAndSkipDuplicates() async throws {
        let transport = MockTransport([
            .init(status: 200, json: try roomPage([("x", "Other"), ("a", "Example recent")]),
                  headers: ["Link": "<https://webexapis.com/v1/rooms?cursor=2>; rel=\"next\""]),
            .init(status: 200, json: try roomPage([("a", "Example recent"), ("b", "Example second"), ("c", "Example third")]),
                  headers: ["Link": "<https://webexapis.com/v1/rooms?cursor=3>; rel=\"next\""]),
            .init(status: 200, json: try roomPage([("d", "Example fourth"), ("e", "Example fifth"), ("f", "Example older")]),
                  headers: ["Link": "<https://webexapis.com/v1/rooms?cursor=4>; rel=\"next\""])
        ])
        let rooms = try await WebexClient(token: "test-placeholder", transport: transport).rooms(matching: " EXAMPLE ")
        #expect(rooms.map(\.id) == ["a", "b", "c", "d", "e"])
        #expect(await transport.count() == 3)
    }
    @Test func filteredRoomsReturnFewerMatchesWhenPagesEnd() async throws {
        let transport = MockTransport([.init(status: 200, json: try roomPage([("a", "Example"), ("b", "Other")]))])
        let rooms = try await WebexClient(token: "test-placeholder", transport: transport).rooms(matching: "Example")
        #expect(rooms.map(\.id) == ["a"])
        #expect(await transport.count() == 1)
    }
    @Test func cancelledRoomSearchStopsPaginationAfterAnInFlightResponse() async {
        let transport = DelayedRoomTransport()
        let client = WebexClient(token: "test-placeholder", transport: transport)
        let search = Task { try await client.rooms(matching: "Example") }
        await transport.waitForRequest()
        search.cancel()
        await transport.finishRequest()
        do { _ = try await search.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(await transport.count() == 1)
    }
    @Test func testRoomPaginationAndDeduplication() async throws {
        let transport = MockTransport([
            .init(status: 200, json: "{\"items\":[{\"id\":\"a\",\"title\":\"First\",\"type\":\"direct\"}]}", headers: ["Link": "<https://webexapis.com/v1/rooms?cursor=2>; rel=\"next\""]),
            .init(status: 200, json: "{\"items\":[{\"id\":\"a\",\"title\":\"First\",\"type\":\"direct\"},{\"id\":\"b\",\"title\":\"Second\",\"type\":\"direct\"}]}")])
        let rooms = try await WebexClient(token: "test-placeholder", transport: transport).rooms()
        #expect(rooms.map(\.id) == ["a", "b"])
        let count = await transport.count(); #expect(count == 2)
    }
    @Test func testMessageMonitoringTraversesNewerPages() async throws {
        let transport = MockTransport([
            .init(status: 200, json: "{\"items\":[{\"id\":\"new\",\"roomId\":\"room\",\"created\":\"2025-01-01T00:00:10Z\"}]}", headers: ["Link": "<https://webexapis.com/v1/messages?cursor=2>; rel=\"next\""]),
            .init(status: 200, json: "{\"items\":[{\"id\":\"old\",\"roomId\":\"room\",\"created\":\"2024-12-31T23:59:00Z\"}]}", headers: ["Link": "<https://webexapis.com/v1/messages?cursor=3>; rel=\"next\""])
        ])
        let client = WebexClient(token: "test-placeholder", transport: transport)
        let messages = try await client.messages(roomID: "room", since: parseDate("2025-01-01T00:00:00Z"))
        #expect(messages.map(\.id) == ["new", "old"])
        let count = await transport.count(); #expect(count == 2)
    }

    @Test func testAmbiguousSendNeverRetried() async {
        for step in [MockTransport.Step(status: 503, json: "{}"), .init(status: 200, json: "invalid")] {
            let transport = MockTransport([step]), client = WebexClient(token: "test-placeholder", transport: MockTransport([]))
            do { _ = try await WebexClient(token: "test-placeholder", transport: transport).send(roomID: "room", text: "test", png: nil); Issue.record("Unexpected success") }
            catch { guard case RelayError.ambiguousSend = error else { Issue.record("Unexpected error"); return } }
            let count = await transport.count(); #expect(count == 1)
            do { _ = try await client.send(roomID: "room", text: "test", png: nil); Issue.record("Unexpected success") }
            catch { guard case RelayError.ambiguousSend = error else { Issue.record("Unexpected error"); return } }
        }
    }
    @Test func testRateLimitAndUnauthorized() async {
        let transport = MockTransport([.init(status: 429, json: "{}", headers: ["Retry-After": "60"])])
        let client = WebexClient(token: "test-placeholder", transport: transport)
        for _ in 0..<2 {
            do { _ = try await client.me(); Issue.record("Unexpected success") }
            catch { guard case RelayError.rateLimited = error else { Issue.record("Unexpected success"); return } }
        }
        let count = await transport.count(); #expect(count == 1)
        do { _ = try await WebexClient(token: "test-placeholder", transport: MockTransport([.init(status: 401, json: "{}")])).me(); Issue.record("Unexpected success") }
        catch { guard case RelayError.unauthorized = error else { Issue.record("Unexpected success"); return } }
    }
    @Test func testAttachmentIsExactAndNoAttachmentWhenDisabled() async throws {
        let response = "{\"id\":\"sent\",\"roomId\":\"room\"}"
        let transport = MockTransport([.init(status: 200, json: response), .init(status: 200, json: response)])
        let client = WebexClient(token: "test-placeholder", transport: transport)
        let png = Data([137, 80, 78, 71, 0, 255])
        _ = try await client.send(roomID: "room", text: "本文", png: png)
        let attached = await transport.last()!
        #expect(attached.httpBody?.range(of: png) != nil)
        #expect(attached.value(forHTTPHeaderField: "Content-Type")!.hasPrefix("multipart/form-data"))
        _ = try await client.send(roomID: "room", text: "本文", png: nil)
        let plain = await transport.last()!
        #expect(plain.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let json = try JSONSerialization.jsonObject(with: plain.httpBody!) as! [String: String]
        #expect(json == ["roomId": "room", "text": "本文"])
    }
}
