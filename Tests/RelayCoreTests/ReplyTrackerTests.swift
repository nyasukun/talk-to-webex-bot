import Testing
import Foundation
@testable import RelayCore

final class ReplyTrackerTests {
    @Test func restoredSpeechKeepsReplyStabilityAndDuplicateProtection() {
        var tracker = ReplyTracker(request: message("request", "q", sender: "self", created: timestamp), ownPersonID: "self", baseline: [], settleSeconds: 2, busyPhrases: [])
        let reply = Message(id: "r", roomId: "room", personId: "other", text: "最初です。 次です。", markdown: "最初です。\n\n次です。", created: "2025-01-01T00:00:01Z")
        let now = Date()
        #expect(tracker.ingest([reply], now: now) == [])
        #expect(tracker.ingest([reply], now: now.addingTimeInterval(3)) == ["最初です。\n\n次です。"])
        #expect(tracker.ingest([reply, message("duplicate", "最初です。 次です。")], now: now.addingTimeInterval(4)) == [])
        #expect(tracker.ingest([message("duplicate", "最初です。 次です。")], now: now.addingTimeInterval(7)) == [])
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
}
