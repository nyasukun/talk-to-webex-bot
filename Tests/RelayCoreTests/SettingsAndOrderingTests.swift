import Testing
import Foundation
@testable import RelayCore

struct SettingsAndOrderingTests {
    @Test func equalActivityDatesHaveStableOrderingAndInvalidDatesSortLast() {
        let rooms = [Room(id: "b", title: "B", lastActivity: "2026-01-01T00:00:00Z"),
                     Room(id: "missing", title: "No date", lastActivity: "invalid"),
                     Room(id: "a", title: "A", lastActivity: "2026-01-01T00:00:00Z")]
        #expect(Room.filtered(rooms, query: "").map(\.id) == ["a", "b", "missing"])
    }
    @Test func unsupportedSpeechEngineAndNonfiniteSettingsAreRejected() {
        var settings = Settings()
        settings.ttsEngine = "unexpected"
        #expect(throws: (any Error).self) { try settings.validate() }
        settings.ttsEngine = "system"
        settings.replyPollSeconds = .nan
        #expect(throws: (any Error).self) { try settings.validate() }
    }
    @Test func extremeRetryHeadersCannotCrashErrorPresentation() {
        for seconds in [Double.greatestFiniteMagnitude, .infinity, .nan, -1] {
            #expect(!RelayError.rateLimited(seconds).localizedDescription.isEmpty)
        }
    }
}
