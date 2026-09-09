import Testing
import Foundation
@testable import RelayCore

struct SettingsMigrationTests {
    @Test func referenceNoiseSettingMigratesAndPreservesAnExplicitOptOut() throws {
        #expect(try SettingsCodec.decode(Data("{}".utf8)).reduceReferenceNoise)
        let settings = try SettingsCodec.decode(Data(#"{"reduceReferenceNoise":false}"#.utf8))
        #expect(!settings.reduceReferenceNoise)
        #expect(try !SettingsCodec.decode(JSONEncoder().encode(settings)).reduceReferenceNoise)
    }
    @Test func speechPromptMigrationPreservesCustomTextAndRunsOnce() throws {
        let custom = "{{transcript}}\n簡潔に説明してください。"
        let old = try JSONSerialization.data(withJSONObject: ["template": custom])
        var migrated = try SettingsCodec.decode(old)
        #expect(migrated.template == custom + "\n" + MessageTemplate.speechInstructions + "\n" + MessageTemplate.numberInstructions)
        let twice = try SettingsCodec.decode(JSONEncoder().encode(migrated))
        #expect(twice.template == migrated.template)
        migrated.template = custom
        #expect(try SettingsCodec.decode(JSONEncoder().encode(migrated)).template == custom)
        for screen in [false, true] {
            let rendered = try MessageTemplate.render(twice.template, transcript: "動作確認", ocr: "画面", screen: screen)
            #expect(rendered.contains(MessageTemplate.speechInstructions))
        }
    }
    @Test func pollIntervalMigratesOnlyTheOldDefaultAndRoundTripsMilliseconds() throws {
        let migrated = try SettingsCodec.decode(Data(#"{"replyPollSeconds":2}"#.utf8))
        #expect(migrated.replyPollMilliseconds == 100)
        #expect(migrated.replySettleSeconds == 6)
        let custom = try SettingsCodec.decode(Data(#"{"replyPollSeconds":3.5}"#.utf8))
        #expect(custom.replyPollMilliseconds == 3500)
        var current = Settings()
        current.replyPollMilliseconds = 2000
        let restored = try SettingsCodec.decode(JSONEncoder().encode(current))
        #expect(restored.replyPollMilliseconds == 2000)
        current.replyPollMilliseconds = 125
        try current.validate()
        #expect(current.replyPollSeconds == 0.125)
        current.replyPollMilliseconds = 99
        #expect(throws: (any Error).self) { try current.validate() }
        #expect(try SettingsCodec.decode(Data("{}".utf8)).replyPollMilliseconds == 100)
    }
    @Test func numericReadingMigrationPreservesExistingEditsAndDoesNotReinsertDeletedInstructions() throws {
        let custom = "{{transcript}}\n自分で編集した指示です。"
        let data = try JSONSerialization.data(withJSONObject: ["template": custom, "speechTemplateVersion": 1])
        var settings = try SettingsCodec.decode(data)
        #expect(settings.template == custom + "\n" + MessageTemplate.numberInstructions)
        #expect(try SettingsCodec.decode(JSONEncoder().encode(settings)).template == settings.template)
        settings.template = custom
        #expect(try SettingsCodec.decode(JSONEncoder().encode(settings)).template == custom)
        #expect(settings.replyTemplate == MessageTemplate.defaultReplyValue)
    }
    @Test func replyInstructionsMigrateOnlyTheOldDefaultAndRespectLaterEdits() throws {
        var migrated = try SettingsCodec.decode(Data(#"{"replyTemplate":"{{transcript}}"}"#.utf8))
        #expect(migrated.replyTemplate == MessageTemplate.defaultReplyValue)
        migrated.replyTemplate = "{{transcript}}"
        #expect(try SettingsCodec.decode(JSONEncoder().encode(migrated)).replyTemplate == "{{transcript}}")
        let custom = "ユーザからの追加指示：{{transcript}}"
        let data = try JSONSerialization.data(withJSONObject: ["replyTemplate": custom])
        #expect(try SettingsCodec.decode(data).replyTemplate == custom)
    }
}
