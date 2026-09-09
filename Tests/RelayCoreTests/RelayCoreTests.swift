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
}
