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

    @Test func voiceModelMovesToTheStandardFolderOnceAndKeepsLaterChoices() throws {
        let standard = "/data/models/voice-1.7b", small = "/data/models/voice"
        // Saved before the larger model existed: move as soon as it is installed, not before.
        var old = try SettingsCodec.decode(Data(#"{"ttsModelPath":"/data/models/voice"}"#.utf8))
        #expect(old.voiceModelVersion == 1)
        old.resolveVoiceModel(standard: standard, small: small, standardExists: false, smallExists: true)
        #expect(old.ttsModelPath == small && old.voiceModelVersion == 1)
        old.resolveVoiceModel(standard: standard, small: small, standardExists: true, smallExists: true)
        #expect(old.ttsModelPath == standard && old.voiceModelVersion == 2)
        // After the move, choosing the small folder again is respected on every later launch.
        var chosen = try SettingsCodec.decode(JSONEncoder().encode(old))
        chosen.ttsModelPath = small
        chosen.resolveVoiceModel(standard: standard, small: small, standardExists: true, smallExists: true)
        #expect(chosen.ttsModelPath == small && chosen.voiceModelVersion == 2)
        // A custom folder is never touched, and marks the migration as done.
        var custom = try SettingsCodec.decode(Data(#"{"ttsModelPath":"/elsewhere/qwen"}"#.utf8))
        custom.resolveVoiceModel(standard: standard, small: small, standardExists: true, smallExists: true)
        #expect(custom.ttsModelPath == "/elsewhere/qwen" && custom.voiceModelVersion == 2)
        // Fresh settings prefer the standard folder unless only the small one is installed.
        for (standardExists, smallExists, expected) in [(true, true, standard), (false, false, standard), (false, true, small), (true, false, standard)] {
            var fresh = Settings()
            fresh.resolveVoiceModel(standard: standard, small: small, standardExists: standardExists, smallExists: smallExists)
            #expect(fresh.ttsModelPath == expected && fresh.voiceModelVersion == 2)
        }
    }
}
