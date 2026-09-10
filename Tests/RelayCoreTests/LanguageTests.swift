import Foundation
import Testing
@testable import RelayCore

struct LanguageTests {
    @Test func onlyThePrimarySystemLanguageDeterminesTheDefault() {
        for languages in [["ja-JP"], ["ja"], ["ja_JP", "en-US"]] {
            #expect(AppLanguage.preferred(languages) == .japanese)
        }
        for languages in [["en-US", "ja-JP"], ["fr-FR", "ja"], ["zh-Hans"], ["de-DE"], []] {
            #expect(AppLanguage.preferred(languages) == .english)
        }
        #expect(Settings().language == AppLanguage.system)
    }

    @Test func switchingResetsOnlyLanguageDependentDefaultsAndRoundTrips() throws {
        var settings = Settings(language: .japanese)
        settings.template = "custom {{transcript}}"
        settings.replyTemplate = "reply {{transcript}}"
        settings.wakePhrases = "custom wake"
        settings.replyWakePhrases = "custom reply"
        settings.systemVoiceID = "previous-voice"
        settings.referenceText = "実際に読んだ本文"
        settings.referenceAudioPath = "/reference.wav"
        settings.speakerAudioPath = "/speaker.wav"
        settings.asrModelPath = "/asr"
        settings.ttsModelPath = "/tts"
        settings.roomID = "room"
        settings.confirmBeforeSending = false
        settings.changeLanguage(to: .english)
        #expect(settings.wakePhrases == "Okay, assistant")
        #expect(settings.replyWakePhrases == "Okay, reply")
        #expect(settings.template == MessageTemplate.defaultValue(for: .english))
        #expect(settings.replyTemplate == MessageTemplate.defaultReplyValue(for: .english))
        #expect(settings.systemVoiceID.isEmpty)
        #expect(settings.busyPatterns == AppLanguage.english.busyPatterns)
        #expect(settings.referenceText == "実際に読んだ本文")
        #expect(settings.referenceAudioPath == "/reference.wav" && settings.speakerAudioPath == "/speaker.wav")
        #expect(settings.asrModelPath == "/asr" && settings.ttsModelPath == "/tts")
        #expect(settings.roomID == "room" && !settings.confirmBeforeSending)
        try settings.validate()
        let restored = try SettingsCodec.decode(JSONEncoder().encode(settings), systemLanguage: .japanese)
        #expect(restored == settings)
        settings.template = "custom English {{transcript}}"
        settings.busyPatterns = "custom progress"
        let customized = settings
        settings.changeLanguage(to: .english)
        #expect(settings == customized)
        settings.changeLanguage(to: .japanese)
        #expect(settings.template == MessageTemplate.defaultValue)
        #expect(settings.replyTemplate == MessageTemplate.defaultReplyValue)
        #expect(settings.wakePhrases == AppLanguage.japanese.wakePhrases)
        #expect(settings.busyPatterns == "custom progress")
    }

    @Test func legacyMigrationUsesSystemLanguageOnceAndPreservesExplicitLanguage() throws {
        let data = try JSONSerialization.data(withJSONObject: ["wakePhrases": "変更済みの合言葉", "template": "custom {{transcript}}", "roomID": "room"])
        let japanese = try SettingsCodec.decode(data, systemLanguage: .japanese)
        #expect(japanese.wakePhrases == "変更済みの合言葉")
        #expect(japanese.template.hasPrefix("custom {{transcript}}"))
        var english = try SettingsCodec.decode(data, systemLanguage: .english)
        #expect(english.language == .english && english.roomID == "room")
        #expect(english.template == MessageTemplate.defaultValue(for: .english))
        #expect(english.replyWakePhrases == "Okay, reply")
        english.template = "my English prompt {{transcript}}"
        english.wakePhrases = "my custom wake"
        let restored = try SettingsCodec.decode(JSONEncoder().encode(english), systemLanguage: .japanese)
        #expect(restored == english)
        let partialEnglish = try SettingsCodec.decode(Data(#"{"language":"en","template":"{{transcript}}","replyTemplate":"{{transcript}}"}"#.utf8))
        #expect(partialEnglish.template.contains(MessageTemplate.englishSpeechInstructions))
        #expect(!partialEnglish.template.contains(MessageTemplate.speechInstructions))
        #expect(partialEnglish.replyTemplate == MessageTemplate.defaultReplyValue(for: .english))
        let englishDefaults = try SettingsCodec.decode(Data(#"{"language":"en"}"#.utf8), systemLanguage: .japanese)
        #expect(englishDefaults.wakePhrases == "Okay, assistant")
        #expect(englishDefaults.replyWakePhrases == "Okay, reply")
        #expect(englishDefaults.template == MessageTemplate.defaultValue(for: .english))
        #expect(englishDefaults.replyTemplate == MessageTemplate.defaultReplyValue(for: .english))
    }

    @Test func englishPromptsRenderScreenAndThreadContextWithoutJapaneseInstructions() throws {
        let settings = Settings(language: .english)
        for screen in [true, false] {
            let body = try MessageTemplate.render(settings.template, transcript: "Explain this.", ocr: "Screen text", screen: screen)
            #expect(body.contains("Explain this."))
            #expect(body.contains("Screen text") == screen)
            #expect(body.contains("screenshot") == screen)
            #expect(body.contains("Reply in English"))
            #expect(!body.contains("{{") && !body.contains("日本語"))
        }
        let followup = try MessageTemplate.render(settings.replyTemplate, transcript: "Only the afternoon.", ocr: "Never attach", screen: false)
        #expect(followup.contains("Only the afternoon.") && followup.contains("same thread"))
        #expect(followup.contains("Reply in English") && !followup.contains("Never attach"))
    }

    @Test func englishWakePhrasesAcceptWhisperSpellingsAndRouteFollowups() {
        let settings = Settings(language: .english)
        for prefix in ["Okay, assistant.", "OK assistant", "okay ASSISTANT!"] {
            #expect(WakeMatcher.command(in: prefix + " What is next?", phrases: settings.wakePhrases) == "What is next")
        }
        var router = VoiceRouter()
        let now = Date()
        #expect(router.accept("OK reply", phrases: settings.wakePhrases, replyPhrases: settings.replyWakePhrases, now: now, timeout: 12) == .armed(.threadReply))
        #expect(router.accept("Only the afternoon.", phrases: settings.wakePhrases, replyPhrases: settings.replyWakePhrases, now: now, timeout: 12) == .command("Only the afternoon.", .threadReply))
    }

    @Test func englishSpeechFormattingKeepsWordsAndUsesEnglishNotices() {
        let source = "# Progress\n- **Ready:** 50% at 25°C & 3~5 items → next.\nhttps://example.com\nuser@example.com\n```swift\nprint(1)\n```"
        let spoken = SpeechText.forSpeech(source, language: .english)
        #expect(spoken.contains("50 percent") && spoken.contains("25 degrees Celsius"))
        #expect(spoken.contains("and 3 to 5 items"))
        #expect(spoken.contains("link") && spoken.contains("email address") && spoken.contains("Code omitted."))
        #expect(!spoken.contains("リンク") && !spoken.contains("から") && !spoken.contains("パーセント"))
        #expect(SpeechText.forSpeech("😀", language: .english) == "Please check the reply on screen.")
        #expect(SpeechText.forSpeech("1. First\n| One | Two |", language: .english) == "1, First\nOne, Two")
        #expect(SpeechText.forSpeech("50%", language: .japanese) == "50パーセント")
    }

    @Test func catalogPreservesPlaceholdersAndInterpolationNeverReinterpretsUserText() {
        for (source, translated) in L10n.english {
            #expect(!translated.isEmpty)
            #expect(Set(source.matches(of: #/\{\d+\}/#).map { String($0.output) }) == Set(translated.matches(of: #/\{\d+\}/#).map { String($0.output) }))
            #expect(source.matches(of: #/%[.\d]*[fgd%]/#).map { String($0.output) } == translated.matches(of: #/%[.\d]*[fgd%]/#).map { String($0.output) })
            #expect(!translated.contains(#/[一-龥ぁ-んァ-ヶ]/#))
        }
        #expect(L10n.text("送信先  ·  \("{0} 日本語")", language: .english) == "Destination · {0} 日本語")
        #expect(L10n.text("Webexの呼び出し制限です。約\(12)秒後に再実行してください。", language: .english).contains("12 seconds"))
    }
}
