import Foundation

/// User-facing sound controls. Codec rates, runaway limits and detection internals stay fixed.
public enum SpeechParameter: String, CaseIterable, Sendable {
    case temperature = "temperature"
    case topK = "top_k"
    case topP = "top_p"
    case repetitionPenalty = "repetition_penalty"
    case repetitionWindow = "repetition_window"
    case streamingInterval = "streaming_interval"
    case openingCharacters = "opening_characters"
    case maxLineCharacters = "max_line_characters"
    case outputLeadingSeconds = "output_leading_seconds"
    case outputTrailingSeconds = "output_trailing_seconds"
    case referenceNoiseStrength = "reference_noise_strength"
    case referenceHighPassHz = "reference_high_pass_hz"
    case referenceTargetRmsDb = "reference_target_rms_db"
    case referenceMaxAttenuationDb = "reference_max_attenuation_db"
    case referenceMaxGainDb = "reference_max_gain_db"
    case outputHighPassHz = "output_high_pass_hz"
    case outputTargetRmsDb = "output_target_rms_db"
    case outputMaxAttenuationDb = "output_max_attenuation_db"
    case outputMaxGainDb = "output_max_gain_db"
    case outputFadeInSeconds = "output_fade_in_seconds"
    case outputFadeOutSeconds = "output_fade_out_seconds"
    case peakCeiling = "peak_ceiling"

    public enum Group: CaseIterable, Sendable { case generation, timing, reference, output }
    public struct Spec: Sendable {
        public let defaultValue: Double
        public let range: ClosedRange<Double>
        public let integer: Bool
        public let unit: String
        public let group: Group
        public let title: String
    }
    public var spec: Spec {
        switch self {
        case .temperature: return Spec(defaultValue: 0.9, range: 0.1...1.5, integer: false, unit: "", group: .generation, title: "生成のばらつき（Temperature）")
        case .topK: return Spec(defaultValue: 50, range: 1...200, integer: true, unit: "", group: .generation, title: "候補数（Top K）")
        case .topP: return Spec(defaultValue: 1, range: 0.1...1, integer: false, unit: "", group: .generation, title: "候補の確率範囲（Top P）")
        case .repetitionPenalty: return Spec(defaultValue: 1.05, range: 1...2, integer: false, unit: "", group: .generation, title: "反復の抑制")
        case .repetitionWindow: return Spec(defaultValue: 64, range: 1...512, integer: true, unit: "トークン", group: .generation, title: "反復を調べる範囲")
        case .streamingInterval: return Spec(defaultValue: 0.8, range: 0.2...2, integer: false, unit: "秒", group: .generation, title: "音声デコード間隔")
        case .openingCharacters: return Spec(defaultValue: 32, range: 8...160, integer: true, unit: "文字", group: .timing, title: "冒頭の最大文字数")
        case .maxLineCharacters: return Spec(defaultValue: 160, range: 32...300, integer: true, unit: "文字", group: .timing, title: "通常区間の最大文字数")
        case .outputLeadingSeconds: return Spec(defaultValue: 0.08, range: 0...0.5, integer: false, unit: "秒", group: .timing, title: "冒頭に残す無音")
        case .outputTrailingSeconds: return Spec(defaultValue: 0.3, range: 0...2, integer: false, unit: "秒", group: .timing, title: "区間末尾の間")
        case .referenceNoiseStrength: return Spec(defaultValue: 0.65, range: 0...1, integer: false, unit: "", group: .reference, title: "ノイズ軽減の強さ")
        case .referenceHighPassHz: return Spec(defaultValue: 60, range: 0...300, integer: false, unit: "Hz", group: .reference, title: "参照音声の低域カット")
        case .referenceTargetRmsDb: return Spec(defaultValue: -20, range: -30 ... -10, integer: false, unit: "dB", group: .reference, title: "参照音声の目標音量")
        case .referenceMaxAttenuationDb: return Spec(defaultValue: 12, range: 0...24, integer: false, unit: "dB", group: .reference, title: "参照音声の最大減衰")
        case .referenceMaxGainDb: return Spec(defaultValue: 18, range: 0...24, integer: false, unit: "dB", group: .reference, title: "参照音声の最大増幅")
        case .outputHighPassHz: return Spec(defaultValue: 50, range: 0...300, integer: false, unit: "Hz", group: .output, title: "生成音声の低域カット")
        case .outputTargetRmsDb: return Spec(defaultValue: -18, range: -30 ... -10, integer: false, unit: "dB", group: .output, title: "生成音声の目標音量")
        case .outputMaxAttenuationDb: return Spec(defaultValue: 8, range: 0...24, integer: false, unit: "dB", group: .output, title: "生成音声の最大減衰")
        case .outputMaxGainDb: return Spec(defaultValue: 8, range: 0...24, integer: false, unit: "dB", group: .output, title: "生成音声の最大増幅")
        case .outputFadeInSeconds: return Spec(defaultValue: 0.005, range: 0...0.1, integer: false, unit: "秒", group: .output, title: "フェードイン")
        case .outputFadeOutSeconds: return Spec(defaultValue: 0.02, range: 0...0.2, integer: false, unit: "秒", group: .output, title: "フェードアウト")
        case .peakCeiling: return Spec(defaultValue: 0.95, range: 0.1...1, integer: false, unit: "", group: .output, title: "ピーク音量の上限")
        }
    }
}

/// Store overrides by name so older and partial settings gain new defaults automatically.
public struct QwenSpeechSettings: Codable, Equatable, Sendable {
    private var values: [String: Double] = [:]
    public init() {}
    public subscript(_ parameter: SpeechParameter) -> Double {
        get { values[parameter.rawValue] ?? parameter.spec.defaultValue }
        set { values[parameter.rawValue] = newValue == parameter.spec.defaultValue ? nil : newValue }
    }
    public var workerOptions: [String: Double] {
        Dictionary(uniqueKeysWithValues: SpeechParameter.allCases.map { ($0.rawValue, self[$0]) })
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let saved = try container.decode([String: Double].self)
        for parameter in SpeechParameter.allCases {
            if let value = saved[parameter.rawValue] { self[parameter] = value }
        }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
    public func validate() throws {
        for parameter in SpeechParameter.allCases {
            let value = self[parameter], spec = parameter.spec
            guard value.isFinite, spec.range.contains(value), !spec.integer || value.rounded() == value else {
                let title = L10n.key(spec.title)
                let lower = spec.range.lowerBound.formatted(), upper = spec.range.upperBound.formatted()
                throw RelayError.message(L10n.text("\(title)は\(lower)〜\(upper)の範囲で指定してください。") +
                                         (spec.integer ? L10n.text("整数で指定してください。") : ""))
            }
        }
        guard self[.openingCharacters] <= self[.maxLineCharacters] else {
            throw RelayError.message(L10n.text("冒頭の最大文字数は、通常区間の最大文字数以下にしてください。"))
        }
    }
}

extension Settings {
    public func validateSpeech() throws {
        guard speechVolume.isFinite, (0...1).contains(speechVolume) else {
            throw RelayError.message(L10n.text("読み上げ音量は0〜100%で指定してください。"))
        }
        guard systemSpeechRate.isFinite, systemSpeechRate == 0 || (80...400).contains(systemSpeechRate) else {
            throw RelayError.message(L10n.text("Mac標準音声の速さは0（自動）、または80〜400語/分で指定してください。"))
        }
        try qwenSpeech.validate()
    }
}
