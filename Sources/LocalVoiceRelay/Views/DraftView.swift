import SwiftUI
import AppKit
import RelayCore

struct DraftView: View {
    @ObservedObject var model: AppModel
    let draft: AppModel.Draft
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("送信内容を確認", systemImage: "paperplane").font(.title2.bold())
            Text("送信先  ·  \(draft.settings.roomTitle)").font(.headline)
            if draft.screenOmitted {
                Label("画面を取得できないため、画像とOCRを省いて送信します。", systemImage: "rectangle.slash").font(.callout).foregroundStyle(.secondary)
            }
            if let thread = draft.thread {
                VStack(alignment: .leading, spacing: 6) {
                    Label("スレッドへの返信", systemImage: "arrowshape.turn.up.left.fill").font(.callout.weight(.semibold)).foregroundStyle(.teal)
                    Text("返信先の確認用です。以下の引用は送信本文に含めません。").font(.caption).foregroundStyle(.secondary)
                    Text(thread.preview).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).relayCard()
            } else { Text("通常のDMメッセージ").font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let screen = draft.screen, let image = NSImage(data: screen.png) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 260).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    Text(draft.body).textSelection(.enabled).lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(18)
            }.relayCard()
            HStack {
                Text(draft.screen == nil ? "表示中の本文を送信します。" : "表示中の本文と画像を送信します。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取り消す") { model.cancelDraft() }.keyboardShortcut(.cancelAction)
                Button("Webexへ送信") { model.confirmDraft() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 710, height: 650)
    }
}
