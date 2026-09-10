import SwiftUI
import RelayCore

struct ContentSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Group {
                SettingsIntro(section: .content, description: L10n.text("送る内容と、返信の書き方を設定します。"))
                Section {
                    Toggle(L10n.text("スクショ・OCRを送付"), isOn: $model.settings.includeScreen)
                    Toggle(L10n.text("送信前に本文と画像を確認"), isOn: $model.settings.confirmBeforeSending)
                } header: { Text(L10n.text("送信前の確認")) } footer: {
                    Text(L10n.text("スクショをオンにした場合だけ前面ウィンドウを取得します。取得できない場合や画面ロック中は、画像とOCRを省いて続行します。送信前確認がオンなら、ロック解除後の確認を待ちます。オフならロック中も送信します。"))
                }
                Section {
                    TextSetting(title: L10n.text("通常の送信テンプレート"), text: $model.settings.template, height: 300)
                    Button(L10n.text("初期テンプレートに戻す")) { model.settings.template = MessageTemplate.defaultValue(for: model.settings.language) }
                } header: { Text(L10n.text("ボットへの指示")) } footer: {
                    Text(L10n.text("初期値では日本語・カタカナ・短文改行で返答するよう指示します。二桁以上の数字は「じゅうさんじ」のように、意味に合ったひらがな表記を求めます。"))
                }
                Section {
                    TextSetting(title: L10n.text("スレッド返信用テンプレート"), text: $model.settings.replyTemplate, height: 100)
                    Button(L10n.text("初期の返信テンプレートに戻す")) { model.settings.replyTemplate = MessageTemplate.defaultReplyValue(for: model.settings.language) }
                } header: { Text(L10n.text("追加の返信")) } footer: {
                    Text(L10n.text("同じ話題へのユーザ返信として、文脈を引き継ぐよう指示します。送るのはこの指示と新しい文字起こしだけです。直前のボット回答やスクショ・OCRは付けません。"))
                }
                Section {
                    Text(L10n.text("{{transcript}}：音声文字起こし\n{{ocr}}：OCR文字列\n{{#screen}}…{{/screen}}：スクショが有効なときだけ送る範囲"))
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                } header: { Text(L10n.text("使える変数")) }
            }.disabled(!model.canConfigure)
        }.formStyle(.grouped)
    }
}
