import Foundation

/// Pure, versioned migration of saved settings; independent of disk and Keychain.
public enum SettingsCodec {
    public static func decode(_ data: Data) throws -> Settings {
        guard var saved = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings())) as? [String: Any] else {
            throw RelayError.message("設定の形式を読み取れません。")
        }
        if saved["replyPollVersion"] == nil {
            if saved["replyPollSeconds"] as? Double == 2 { saved["replyPollSeconds"] = 0.1 }
            saved["replyPollVersion"] = 1
        }
        if saved["speechTemplateVersion"] == nil {
            if let template = saved["template"] as? String, !template.contains(MessageTemplate.speechInstructions) {
                saved["template"] = template + "\n" + MessageTemplate.speechInstructions
            }
            saved["speechTemplateVersion"] = 1
        }
        if saved["numberTemplateVersion"] == nil {
            if let template = saved["template"] as? String, !template.contains(MessageTemplate.numberInstructions) {
                saved["template"] = template + "\n" + MessageTemplate.numberInstructions
            }
            saved["numberTemplateVersion"] = 1
        }
        if saved["replyTemplateVersion"] == nil {
            if saved["replyTemplate"] as? String == "{{transcript}}" { saved["replyTemplate"] = MessageTemplate.defaultReplyValue }
            saved["replyTemplateVersion"] = 1
        }
        let merged = try JSONSerialization.data(withJSONObject: defaults.merging(saved) { _, new in new })
        return try JSONDecoder().decode(Settings.self, from: merged)
    }
}
