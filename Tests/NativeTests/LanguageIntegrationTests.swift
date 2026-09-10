import Foundation
import Testing
import RelayCore
@testable import LocalVoiceRelay

struct LanguageIntegrationTests {
    @Test @MainActor func languageSwitchRefreshesViewsAndDiscardRestoresCustomDefaults() {
        let previous = L10n.language
        defer { L10n.language = previous }
        let model = AppModel(preview: true)
        model.changeLanguage(to: .japanese)
        model.settings.template = "custom {{transcript}}"
        model.settings.wakePhrases = "保存済みの合言葉"
        model.savedSettings = model.settings
        model.detail = L10n.text("送信先DMを選んでください。")
        model.changeLanguage(to: .english)
        #expect(L10n.language == .english && model.hasUnsavedChanges)
        #expect(AppSection.input.title == "Voice Input" && AppSection.input.matches("language"))
        #expect(model.detail == "Select a destination DM.")
        #expect(model.statusTitle == "Stop")
        #expect(model.speechTestText.contains("Webex connection"))
        #expect(model.testInput == "This is a connection test. Please reply briefly.")
        let report = IssueReport.draft(settings: model.settings, phase: .stopped, permissions: model.permissionSnapshot, entries: [])
        #expect(report.contains("## What happened") && report.contains("No events"))
        #expect(!report.contains(#/[一-龥ぁ-んァ-ヶ]/#))
        model.discardSettingsChanges()
        #expect(L10n.language == .japanese && !model.hasUnsavedChanges)
        #expect(model.settings.wakePhrases == "保存済みの合言葉")
        #expect(model.settings.template == "custom {{transcript}}")
        #expect(model.speechTestText.contains("ウェブエックス"))
        model.listening = true
        model.changeLanguage(to: .english)
        #expect(model.settings.language == .japanese)
        model.listening = false
        model.referenceRecording = true
        model.changeLanguage(to: .english)
        #expect(model.settings.language == .japanese)
        model.referenceRecording = false
        model.phase = .speaking
        model.changeLanguage(to: .english)
        #expect(model.settings.language == .japanese)
    }

    @Test func speechRequestsCarryLanguageAndWorkerStatusesKeepTranscriptsVerbatim() {
        for language in AppLanguage.allCases {
            let settings = Settings(language: language)
            let requests = [WorkerRequest.transcribe(audio: "/test.wav", settings: settings, verifyInline: true),
                            WorkerRequest.warmSpeech(settings: settings), WorkerRequest.beginSpeech(text: "Hello.", settings: settings),
                            WorkerRequest.verifySpeaker(audio: "/test.wav", settings: settings), WorkerRequest.diagnose(settings: settings)]
            #expect(requests.allSatisfy { $0["language"] as? String == language.rawValue })
        }
        let text = "音声区間が不足しています。"
        let result = LocalWorker.localizedResult(["text": text, "rejected": text, "error": text], language: .english)
        #expect(result["text"] as? String == text)
        #expect(result["rejected"] as? String == "Insufficient speech duration.")
        #expect(result["error"] as? String == "Insufficient speech duration.")
    }

    @Test @MainActor func installedSystemVoicesAreFilteredByTheSelectedLanguage() {
        for language in AppLanguage.allCases {
            #expect(SpeechOutput.voices(for: language).allSatisfy { $0.language.hasPrefix(language.rawValue) })
            if let automatic = SpeechOutput.automaticVoice(for: language) {
                #expect(automatic.language.hasPrefix(language.rawValue))
            }
        }
    }
}
