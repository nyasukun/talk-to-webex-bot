import SwiftUI
import RelayCore

struct SpeechQualitySettingsView: View {
    @ObservedObject var model: AppModel
    @State var expandedGroups: Set<SpeechParameter.Group> = []

    var body: some View {
        Section {
            ForEach(SpeechParameter.Group.allCases, id: \.self) { group in
                DisclosureGroup(title(group), isExpanded: Binding(get: { expandedGroups.contains(group) }, set: { expanded in
                    if expanded { expandedGroups.insert(group) } else { expandedGroups.remove(group) }
                })) {
                    Text(explanation(group)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(SpeechParameter.allCases.filter { $0.spec.group == group }, id: \.self) { parameter in
                        parameterRow(parameter)
                    }
                }
            }
            Button(L10n.text("Qwenの音質を初期値に戻す")) {
                model.settings.qwenSpeech = QwenSpeechSettings()
                model.settings.reduceReferenceNoise = true
            }
        } header: { Text(L10n.text("Qwenの音質・詳細設定")) } footer: {
            Text(L10n.text("少しずつ変更し、下の試聴で確認してください。試聴には編集中の値を使います。「変更を保存」で次回起動にも引き継ぎます。"))
        }
    }

    private func parameterRow(_ parameter: SpeechParameter) -> some View {
        let spec = parameter.spec
        return VStack(alignment: .leading, spacing: 3) {
            NumberSetting(title: L10n.key(spec.title), unit: L10n.key(spec.unit),
                          value: Binding(get: { model.settings.qwenSpeech[parameter] },
                                         set: { model.settings.qwenSpeech[parameter] = $0 }))
            Text(L10n.text("範囲 \(spec.range.lowerBound.formatted())〜\(spec.range.upperBound.formatted()) · 初期値 \(spec.defaultValue.formatted())") +
                 (spec.integer ? L10n.text("（整数）") : ""))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 3)
        .disabled(parameter == .referenceNoiseStrength && !model.settings.reduceReferenceNoise)
    }

    private func title(_ group: SpeechParameter.Group) -> String {
        switch group {
        case .generation: return L10n.text("声の生成と反復抑制")
        case .timing: return L10n.text("区間の長さと間")
        case .reference: return L10n.text("参照音声の調整")
        case .output: return L10n.text("生成音声の仕上げ")
        }
    }
    private func explanation(_ group: SpeechParameter.Group) -> String {
        switch group {
        case .generation:
            return L10n.text("Temperatureや候補の範囲を上げると生成の変化が増えます。反復の抑制を強めすぎると発音が崩れることがあります。デコード間隔は音声を処理する単位です。")
        case .timing:
            return L10n.text("短い区間は読み始めを早め、長い区間は文脈を保ちやすくします。末尾の間は区間ごとに入ります。生成待ちの時間が加わる場合もあります。")
        case .reference:
            return L10n.text("低域カットは0で無効です。目標音量は声の実効レベル（RMS）で、最大減衰・増幅の範囲内で補正します。元の録音は変更しません。")
        case .output:
            return L10n.text("低域カットは0で無効です。目標音量と補正幅で区間ごとの音量をそろえ、フェードで端のクリック音を抑えます。ピーク上限は参照音声にも適用します。")
        }
    }
}
