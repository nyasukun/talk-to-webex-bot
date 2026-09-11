import Foundation
import Testing
@testable import RelayCore

struct ScreenUseCaseTests {
    @Test func defaultsAreJapaneseScreenOnlyAndOldSettingsGainThemOnce() throws {
        let settings = Settings(language: .english)
        #expect(settings.screenUseCases.map(\.name) == ["日本語で要約", "日本語へ翻訳"])
        #expect(settings.screenUseCases.map { $0.hotkey?.title } == ["⌃⌥⌘S", "⌃⌥⌘T"])
        #expect(settings.screenUseCases.allSatisfy { $0.enabled && !$0.readReplies && !$0.confirmBeforeSending && $0.speechLanguage == .japanese })
        let old = try SettingsCodec.decode(Data(#"{"roomID":"room","language":"ja"}"#.utf8))
        #expect(old.screenUseCases == ScreenUseCase.defaults)
        #expect(old.roomID == "room")
        var edited = old
        edited.screenUseCases = []
        #expect(try SettingsCodec.decode(JSONEncoder().encode(edited)).screenUseCases.isEmpty)
        edited.screenUseCases = [ScreenUseCase(name: "custom", prompt: "custom prompt", readReplies: true)]
        #expect(try SettingsCodec.decode(JSONEncoder().encode(edited)) == edited)
        edited.changeLanguage(to: .english)
        #expect(edited.screenUseCases.first?.prompt == "custom prompt")
    }

    @Test func renderingPreservesLiteralPromptAndOCRAndRejectsOversizeInsteadOfTruncating() throws {
        let useCase = ScreenUseCase(name: "test", prompt: "日本語で翻訳 {{transcript}} {{ocr}}")
        let ocr = "{{#screen}}Data ``` 123 日本語"
        let body = try useCase.render(ocr: ocr)
        #expect(body.contains(useCase.prompt) && body.contains(ocr))
        #expect(!body.contains("音声発話"))
        #expect(try useCase.render(ocr: "").contains("文字を検出できませんでした"))
        #expect(throws: (any Error).self) { try useCase.render(ocr: String(repeating: "字", count: 2500)) }
    }

    @Test func validationRejectsDuplicateKeysAndBadInputsButAllowsUnassignedCasesWithoutCountLimit() throws {
        var cases = ScreenUseCase.defaults
        cases[1].hotkey = cases[0].hotkey
        #expect(throws: (any Error).self) { try ScreenUseCase.validate(cases) }
        cases[1].enabled = false
        try ScreenUseCase.validate(cases)
        cases[1].id = cases[0].id
        #expect(throws: (any Error).self) { try ScreenUseCase.validate(cases) }
        #expect(throws: (any Error).self) { try ScreenHotkey(keyCode: 999).validate() }
        #expect(throws: (any Error).self) { try ScreenHotkey(control: false, option: false, shift: true, command: false).validate() }
        #expect(throws: (any Error).self) { try ScreenUseCase.validate([ScreenUseCase(name: " ", prompt: "x")]) }
        #expect(throws: (any Error).self) { try ScreenUseCase.validate([ScreenUseCase(name: "x", prompt: " ")]) }
        var many = Settings()
        many.screenUseCases = (0..<2400).map { ScreenUseCase(name: "case \($0)", prompt: ScreenUseCase.defaults[0].prompt) }
        try many.validate()
        let data = try JSONEncoder().encode(many)
        #expect(data.count > 1_000_000)
        #expect(try SettingsCodec.decode(data) == many)
    }
}
