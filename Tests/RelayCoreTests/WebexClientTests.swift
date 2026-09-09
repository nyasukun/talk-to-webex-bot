import Testing
import Foundation
@testable import RelayCore

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
    private let timestamp = "2025-01-01T00:00:00Z"
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
