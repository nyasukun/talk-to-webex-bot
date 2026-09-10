import SwiftUI
import RelayCore

struct SettingsIntro: View {
    let section: AppSection
    let description: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: section.symbol).font(.system(size: 23, weight: .medium)).foregroundStyle(.white)
                .frame(width: 50, height: 50).background(section.color.gradient, in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 5) {
                Text(section.rawValue).font(.title2.weight(.semibold))
                Text(description).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.vertical, 8)
    }
}
struct NumberSetting: View {
    let title: String
    let unit: String
    @Binding var value: Double
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: $value, format: .number).multilineTextAlignment(.trailing).frame(width: 90)
            Text(unit).foregroundStyle(.secondary).frame(minWidth: 28, alignment: .leading)
        }
    }
}
struct TextSetting: View {
    let title: String
    @Binding var text: String
    var height: CGFloat = 70
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout)
            TextEditor(text: $text).font(.system(.body)).scrollContentBackground(.hidden)
                .padding(6).frame(height: height).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary))
                .accessibilityLabel(title)
        }.padding(.vertical, 4)
    }
}
struct ReferenceSettings: View {
    @ObservedObject var model: AppModel
    let kind: ReferenceKind
    private var registered: Bool { !model.settings[keyPath: kind.pathKeyPath].isEmpty }
    var body: some View {
        LabeledContent("参照音声") { Label(registered ? "登録済み" : "未登録", systemImage: registered ? "checkmark.circle.fill" : "waveform").foregroundStyle(registered ? Color.teal : Color.secondary) }
        HStack {
            if model.referenceRecording {
                Label("録音中です。普段の声で話してください。", systemImage: "record.circle").foregroundStyle(.red)
                Spacer()
                Button("録音終了") { model.finishReference() }.tint(.red)
            } else {
                Button("参照音声を録音", systemImage: "mic") { Task { await model.startReference(kind: kind) } }
                    .disabled(!model.canConfigure || model.permissionSnapshot.microphone != .allowed)
                Button("音声ファイルを選ぶ", systemImage: "folder") { model.chooseReference(kind: kind) }.disabled(!model.canConfigure)
            }
        }
    }
}
