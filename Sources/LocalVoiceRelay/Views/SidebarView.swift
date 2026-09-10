import SwiftUI
import AppKit

struct RelaySidebarView: View {
    @ObservedObject var model: AppModel
    @Binding var selection: AppSection?
    @State private var search = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit()
                    .frame(width: 44, height: 44).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Talk to Webex bot").font(.system(size: 13, weight: .semibold))
                    Text("このMacの音声アシスタント").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 18)
            TextField("項目を検索", text: $search).textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12).padding(.bottom, 12).accessibilityLabel("設定項目を検索")
            List(selection: $selection) {
                if !AppSection.allCases.contains(where: { $0.matches(search) }) {
                    Text("一致する項目がありません").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    navigationRow(.home)
                }
                Section("設定") {
                    ForEach(AppSection.allCases.filter(\.isSetting)) { navigationRow($0) }
                }
                Section("サポート") {
                    navigationRow(.logs)
                    if AppSection.logs.matches(search) {
                        Button("不具合を報告", systemImage: "ladybug") { model.presentIssueReport() }
                            .disabled(!model.canConfigure).help("停止中に報告用の下書きを開きます")
                    }
                }
            }.listStyle(.sidebar)
            HStack(spacing: 7) {
                Circle().fill(model.phase == .error ? Color.orange : model.listening ? Color.teal : Color.gray).frame(width: 6, height: 6)
                Text(model.statusTitle).font(.caption).lineLimit(1)
                Spacer()
                Text("v\(IssueReport.version(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)) · \(IssueReport.version(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }.padding(16)
        }
    }
    @ViewBuilder private func navigationRow(_ item: AppSection) -> some View {
        if item.matches(search) {
            NavigationLink(value: item) {
                HStack(spacing: 10) {
                    Image(systemName: item.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 25, height: 25).background(item.color.gradient, in: RoundedRectangle(cornerRadius: 6))
                    Text(item.rawValue).font(.system(size: 13))
                }.padding(.vertical, 3)
            }
        }
    }
}
