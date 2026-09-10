import Testing
import Foundation
@testable import RelayCore

struct SettingsMigrationTests {
    private func decodeJapanese(_ data: Data) throws -> Settings {
        try SettingsCodec.decode(data, systemLanguage: .japanese)
    }
    @Test func referenceNoiseSettingMigratesAndPreservesAnExplicitOptOut() throws {
        #expect(try decodeJapanese(Data("{}".utf8)).reduceReferenceNoise)
        let settings = try decodeJapanese(Data(#"{"reduceReferenceNoise":false}"#.utf8))
        #expect(!settings.reduceReferenceNoise)
        #expect(try !decodeJapanese(JSONEncoder().encode(settings)).reduceReferenceNoise)
    }
    @Test func speechPromptMigrationPreservesCustomTextAndRunsOnce() throws {
        let custom = "{{transcript}}\n簡潔に説明してください。"
        let old = try JSONSerialization.data(withJSONObject: ["template": custom])
        var migrated = try decodeJapanese(old)
        #expect(migrated.template == custom + "\n" + MessageTemplate.speechInstructions + "\n" + MessageTemplate.numberInstructions)
        let twice = try decodeJapanese(JSONEncoder().encode(migrated))
        #expect(twice.template == migrated.template)
        migrated.template = custom
        #expect(try decodeJapanese(JSONEncoder().encode(migrated)).template == custom)
        for screen in [false, true] {
            let rendered = try MessageTemplate.render(twice.template, transcript: "動作確認", ocr: "画面", screen: screen)
            #expect(rendered.contains(MessageTemplate.speechInstructions))
        }
    }
    @Test func pollIntervalMigratesOnlyTheOldDefaultAndRoundTripsMilliseconds() throws {
        let migrated = try decodeJapanese(Data(#"{"replyPollSeconds":2}"#.utf8))
        #expect(migrated.replyPollMilliseconds == 100)
        #expect(migrated.replySettleSeconds == 6)
        let custom = try decodeJapanese(Data(#"{"replyPollSeconds":3.5}"#.utf8))
        #expect(custom.replyPollMilliseconds == 3500)
        var current = Settings(language: .japanese)
        current.replyPollMilliseconds = 2000
        let restored = try decodeJapanese(JSONEncoder().encode(current))
        #expect(restored.replyPollMilliseconds == 2000)
        current.replyPollMilliseconds = 125
        try current.validate()
        #expect(current.replyPollSeconds == 0.125)
        current.replyPollMilliseconds = 99
        #expect(throws: (any Error).self) { try current.validate() }
        #expect(try decodeJapanese(Data("{}".utf8)).replyPollMilliseconds == 100)
    }
    @Test func numericReadingMigrationPreservesExistingEditsAndDoesNotReinsertDeletedInstructions() throws {
        let custom = "{{transcript}}\n自分で編集した指示です。"
        let data = try JSONSerialization.data(withJSONObject: ["template": custom, "speechTemplateVersion": 1])
        var settings = try decodeJapanese(data)
        #expect(settings.template == custom + "\n" + MessageTemplate.numberInstructions)
        #expect(try decodeJapanese(JSONEncoder().encode(settings)).template == settings.template)
        settings.template = custom
        #expect(try decodeJapanese(JSONEncoder().encode(settings)).template == custom)
        #expect(settings.replyTemplate == MessageTemplate.defaultReplyValue)
    }
    @Test func replyInstructionsMigrateOnlyTheOldDefaultAndRespectLaterEdits() throws {
        var migrated = try decodeJapanese(Data(#"{"replyTemplate":"{{transcript}}"}"#.utf8))
        #expect(migrated.replyTemplate == MessageTemplate.defaultReplyValue)
        migrated.replyTemplate = "{{transcript}}"
        #expect(try decodeJapanese(JSONEncoder().encode(migrated)).replyTemplate == "{{transcript}}")
        let custom = "ユーザからの追加指示：{{transcript}}"
        let data = try JSONSerialization.data(withJSONObject: ["replyTemplate": custom])
        #expect(try decodeJapanese(data).replyTemplate == custom)
    }

    @Test func voiceModelMovesToTheStandardFolderOnceAndKeepsLaterChoices() throws {
        let standard = "/data/models/voice-1.7b", small = "/data/models/voice"
        // Saved before the larger model existed: move as soon as it is installed, not before.
        var old = try decodeJapanese(Data(#"{"ttsModelPath":"/data/models/voice"}"#.utf8))
        #expect(old.voiceModelVersion == 1)
        old.resolveVoiceModel(standard: standard, small: small, standardExists: false, smallExists: true)
        #expect(old.ttsModelPath == small && old.voiceModelVersion == 1)
        old.resolveVoiceModel(standard: standard, small: small, standardExists: true, smallExists: true)
        #expect(old.ttsModelPath == standard && old.voiceModelVersion == 2)
        // After the move, choosing the small folder again is respected on every later launch.
        var chosen = try decodeJapanese(JSONEncoder().encode(old))
        chosen.ttsModelPath = small
        chosen.resolveVoiceModel(standard: standard, small: small, standardExists: true, smallExists: true)
        #expect(chosen.ttsModelPath == small && chosen.voiceModelVersion == 2)
        // A custom folder is never touched, and marks the migration as done.
        var custom = try decodeJapanese(Data(#"{"ttsModelPath":"/elsewhere/qwen"}"#.utf8))
        custom.resolveVoiceModel(standard: standard, small: small, standardExists: true, smallExists: true)
        #expect(custom.ttsModelPath == "/elsewhere/qwen" && custom.voiceModelVersion == 2)
        // Fresh settings prefer the standard folder unless only the small one is installed.
        for (standardExists, smallExists, expected) in [(true, true, standard), (false, false, standard), (false, true, small), (true, false, standard)] {
            var fresh = Settings(language: .japanese)
            fresh.resolveVoiceModel(standard: standard, small: small, standardExists: standardExists, smallExists: smallExists)
            #expect(fresh.ttsModelPath == expected && fresh.voiceModelVersion == 2)
        }
    }
}
