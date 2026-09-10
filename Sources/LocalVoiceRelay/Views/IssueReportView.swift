import RelayCore
import SwiftUI
import AppKit

struct IssueReportView: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: String
    @State private var copied = false
    @State private var openFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L10n.text("不具合を報告"), systemImage: "ladybug").font(.title2.bold())
            Text(L10n.text("症状と再現手順を追記して、下書きをコピーしてください。GitHubのフォームで内容を確認して投稿できます。"))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Label(L10n.text("トークン・宛先・会話・録音は自動添付しません。追記にも個人情報を含めないでください。"), systemImage: "lock.shield")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $draft).font(.system(.body, design: .monospaced))
                .padding(8).relayCard().accessibilityLabel(L10n.text("Issue報告の下書き"))
            if openFailed {
                Text(L10n.text("ブラウザを開けませんでした。下書きをコピーし、リポジトリのIssuesから報告してください。"))
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button(L10n.text("閉じる")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(copied ? L10n.text("コピー済み") : L10n.text("下書きをコピー"), systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(draft, forType: .string)
                }
                Button(L10n.text("GitHubの報告フォームを開く"), systemImage: "arrow.up.right.square") {
                    openFailed = !NSWorkspace.shared.open(IssueReport.formURL)
                }.buttonStyle(.borderedProminent)
            }
            Text(L10n.text("フォームを開くだけでは投稿されません。")).font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 700, height: 640)
            .onChange(of: draft) { _, _ in copied = false }
    }
}
