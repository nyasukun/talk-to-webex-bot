import Testing
import Foundation
@testable import RelayCore

struct SpeechTextTests {
    @Test func markdownStructureBecomesPlainLines() {
        let reply = """
        ## 今日の予定
        > 概要です。
        - **10時**から会議です。
        * 資料は*3件*あります。
        1. 東京へ移動
        2) 大阪で打ち合わせ
        - [x] 完了した作業
        ---
        | 項目 | 時刻 |
        |:---|---:|
        | 会議 | 10:00 |
        """
        #expect(SpeechText.forSpeech(reply) == "今日の予定\n概要です。\n10時から会議です。\n資料は3件あります。\n1、東京へ移動\n2、大阪で打ち合わせ\n完了した作業\n項目、時刻\n会議、10:00")
    }
    @Test func codeBlocksAreReplacedOnceAndUnclosedBlocksStillEnd() {
        let closed = "実行します。\n```bash\nls -la\n```\n以上です。"
        #expect(SpeechText.forSpeech(closed) == "実行します。\n\(SpeechText.codeNotice)\n以上です。")
        let unclosed = "説明です。\n~~~\nprint('x')"
        #expect(SpeechText.forSpeech(unclosed) == "説明です。\n\(SpeechText.codeNotice)")
        #expect(SpeechText.forSpeech("```\ncode only\n```") == SpeechText.codeNotice)
        #expect(SpeechText.forSpeech("値は `config.json` にあります。") == "値は config.json にあります。")
    }
    @Test func linksCodeAndSymbolsGetSpokenForms() {
        #expect(SpeechText.forSpeech("詳細は[こちら](https://example.com/a?b=1)を見てください。") == "詳細はこちらを見てください。")
        #expect(SpeechText.forSpeech("詳細は https://example.com/path/x を見てください。") == "詳細は \(SpeechText.linkWord) を見てください。")
        #expect(SpeechText.forSpeech("<https://example.com>と<b>太字</b>") == "\(SpeechText.linkWord)と太字")
        #expect(SpeechText.forSpeech("連絡先は taro@example.co.jp です。") == "連絡先は \(SpeechText.emailWord) です。")
        #expect(SpeechText.forSpeech("降水確率は２０％、気温は25℃→28℃です。") == "降水確率は20パーセント、気温は25度、28度です。")
        #expect(SpeechText.forSpeech("10〜12時に R&D の会議 ※要確認") == "10から12時に RアンドD の会議 要確認")
        // Compatibility normalization turns full-width ASCII punctuation into ASCII; the voice reads both the same way.
        #expect(SpeechText.forSpeech("完了しました ✅🎉 お疲れさまでした！👍🏽") == "完了しました お疲れさまでした!")
        #expect(SpeechText.forSpeech("A &amp; B &lt;3") == "A アンド B <3")
    }
    @Test func emphasisMarkersAreRemovedButArithmeticAndIdentifiersSurvive() {
        #expect(SpeechText.forSpeech("**重要**: _明日_ の *予定* は ~~中止~~ 変更です。") == "重要: 明日 の 予定 は 中止 変更です。")
        #expect(SpeechText.forSpeech("計算は 2 * 3 * 4 = 24 です。") == "計算は 2 * 3 * 4 = 24 です。")
        #expect(SpeechText.forSpeech("変数名は user_name_value です。") == "変数名は user_name_value です。")
    }
    @Test func emptyOrUnreadableRepliesGetANoticeAndWhitespaceIsCompacted() {
        #expect(SpeechText.forSpeech("") == SpeechText.unreadableNotice)
        #expect(SpeechText.forSpeech("🎉\n\n---\n") == SpeechText.unreadableNotice)
        #expect(SpeechText.forSpeech("  最初です。  \r\n\r\n\r\n　次です。\t終わり  ") == "最初です。\n次です。 終わり")
        #expect(SpeechText.forSpeech("普通の文章です。改行も\nそのままです。") == "普通の文章です。改行も\nそのままです。")
    }
}
