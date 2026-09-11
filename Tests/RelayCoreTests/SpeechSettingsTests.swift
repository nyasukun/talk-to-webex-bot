import Foundation
import Testing
@testable import RelayCore

struct SpeechSettingsTests {
    @Test func legacyAndPartialSettingsKeepTheirSoundAndGainNewDefaults() throws {
        let legacy = try SettingsCodec.decode(Data(#"{"language":"ja","systemVoiceID":"saved","reduceReferenceNoise":false}"#.utf8))
        #expect(legacy.speechVolume == 1 && legacy.systemSpeechRate == 0)
        #expect(legacy.systemVoiceID == "saved" && !legacy.reduceReferenceNoise)
        #expect(legacy.qwenSpeech[.temperature] == 0.9 && legacy.qwenSpeech[.outputTrailingSeconds] == 0.3)
        let partial = try SettingsCodec.decode(Data(#"{"language":"ja","speechVolume":0.42,"qwenSpeech":{"temperature":0.7}}"#.utf8))
        #expect(partial.speechVolume == 0.42 && partial.qwenSpeech[.temperature] == 0.7)
        #expect(partial.qwenSpeech[.referenceNoiseStrength] == 0.65)
        #expect(try SettingsCodec.decode(JSONEncoder().encode(partial)) == partial)
        try partial.validate()
    }

    @Test func qualityControlsRejectNonfiniteFractionalOutOfRangeAndConflictingValues() throws {
        try Settings(language: .japanese).validateSpeech()
        for parameter in SpeechParameter.allCases {
            for value in [Double.nan, .infinity, -.infinity, parameter.spec.range.lowerBound - 1, parameter.spec.range.upperBound + 1] {
                var settings = Settings(language: .japanese)
                settings.qwenSpeech[parameter] = value
                #expect(throws: (any Error).self) { try settings.validateSpeech() }
            }
            if parameter.spec.integer {
                var settings = Settings(language: .japanese)
                settings.qwenSpeech[parameter] = parameter.spec.defaultValue + 0.5
                #expect(throws: (any Error).self) { try settings.validateSpeech() }
            }
        }
        var settings = Settings(language: .japanese)
        settings.qwenSpeech[.maxLineCharacters] = 32
        settings.qwenSpeech[.openingCharacters] = 33
        #expect(throws: (any Error).self) { try settings.validateSpeech() }
        settings.qwenSpeech = QwenSpeechSettings()
        for volume in [Double.nan, .infinity, -0.01, 1.01] {
            settings.speechVolume = volume
            #expect(throws: (any Error).self) { try settings.validateSpeech() }
        }
        settings.speechVolume = 0
        for rate in [0.0, 80, 400] { settings.systemSpeechRate = rate; try settings.validateSpeech() }
        for rate in [Double.nan, .infinity, -1, 79, 401] {
            settings.systemSpeechRate = rate
            #expect(throws: (any Error).self) { try settings.validateSpeech() }
        }
    }

    @Test func resettingOverridesRestoresEqualityAndAllControlsHaveEnglishLabels() {
        var quality = QwenSpeechSettings()
        quality[.temperature] = 0.6
        quality[.temperature] = SpeechParameter.temperature.spec.defaultValue
        #expect(quality == QwenSpeechSettings())
        for parameter in SpeechParameter.allCases {
            #expect(L10n.key(parameter.spec.title, language: .english) != parameter.spec.title)
            #expect(!L10n.key(parameter.spec.unit, language: .english).contains(#/[一-龥ぁ-んァ-ヶ]/#))
        }
    }
}
