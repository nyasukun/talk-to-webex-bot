import Foundation

/// Pure, versioned migration of saved settings; independent of disk and Keychain.
public enum SettingsCodec {
    public static func decode(_ data: Data, systemLanguage: AppLanguage = .system) throws -> Settings {
        guard var saved = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RelayError.message(L10n.text("設定の形式を読み取れません。"))
        }
        let language = (saved["language"] as? String).flatMap(AppLanguage.init(rawValue:)) ?? .japanese
        guard let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings(language: language))) as? [String: Any] else {
            throw RelayError.message(L10n.text("設定の形式を読み取れません。"))
        }
        let speechInstructions = language == .japanese ? MessageTemplate.speechInstructions : MessageTemplate.englishSpeechInstructions
        let numberInstructions = language == .japanese ? MessageTemplate.numberInstructions : MessageTemplate.englishSpeechInstructions
        if saved["replyPollVersion"] == nil {
            if saved["replyPollSeconds"] as? Double == 2 { saved["replyPollSeconds"] = 0.1 }
            saved["replyPollVersion"] = 1
        }
        if saved["speechTemplateVersion"] == nil {
            if let template = saved["template"] as? String, !template.contains(speechInstructions) {
                saved["template"] = template + "\n" + speechInstructions
            }
            saved["speechTemplateVersion"] = 1
        }
        if saved["numberTemplateVersion"] == nil {
            if let template = saved["template"] as? String, !template.contains(numberInstructions) {
                saved["template"] = template + "\n" + numberInstructions
            }
            saved["numberTemplateVersion"] = 1
        }
        if saved["replyTemplateVersion"] == nil {
            if saved["replyTemplate"] as? String == "{{transcript}}" { saved["replyTemplate"] = MessageTemplate.defaultReplyValue(for: language) }
            saved["replyTemplateVersion"] = 1
        }
        // The folder switch itself needs the file system; Settings.resolveVoiceModel finishes it at load time.
        if saved["voiceModelVersion"] == nil { saved["voiceModelVersion"] = 1 }
        let hadLanguage = saved["language"] != nil
        let merged = try JSONSerialization.data(withJSONObject: defaults.merging(saved) { _, new in new })
        var settings = try JSONDecoder().decode(Settings.self, from: merged)
        // Older releases always used Japanese. Moving them to English is a language switch,
        // with the same prompt/wake-phrase reset as the settings picker. Run it only once.
        if !hadLanguage { settings.changeLanguage(to: systemLanguage) }
        return settings
    }
}
