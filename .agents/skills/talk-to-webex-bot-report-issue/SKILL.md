---
name: talk-to-webex-bot-report-issue
description: Talk to Webex botで困った利用者のために、再現手順と個人情報を含まない環境情報を整理し、GitHub Issueの下書き・投稿を支援する。不具合報告や開発者への報告依頼に使う。
---

# Talk to Webex botのIssue報告

報告先は `nyasukun/talk-to-webex-bot`。フォークからの利用でも、別のリモートへ自動投稿しない。このスキルの場所からリポジトリルートを解決し、`Package.swift` と `scripts/collect-issue-report.py` を確認する。

1. 症状、再現操作、期待した結果、実際の結果、頻度、試した対処を会話から整理する。不足する情報だけをまとめて質問する。再現できない場合も報告可能で、原因の推測と観測事実を分ける。
2. `python3 scripts/collect-issue-report.py` をリポジトリで実行する。macOS・CPU・ソースの版・コミット・ツールの有無だけを取得し、通信や設定読み出しはしない。下書きを保存する場合はGit対象外の `.build/issue-report.md` に置く。起動できる場合は「ログ」→「不具合を報告」の下書きも使える。ソースの版と起動中アプリの版を混同しない。
3. [トラブルシューティング](../../../docs/troubleshooting.md)で症状に関係する項目だけ確認する。報告に不要な再インストール・権限リセット・実送信を要求しない。送信成否不明の再現のために同じ指示を再送しない。
4. 必要ならアプリの診断ログから該当するイベントと数値を加える。トークン、キーチェーン、settings.json、合言葉、宛先、会話、OCR、画面画像、参照録音、環境変数を収集・添付しない。ユーザが提供した自由文にも個人名・内部URL・ローカルのユーザ名入りパスがないか確認し、一般的な例に置き換える。機密性のある問題は公開Issueに詳細を載せない。
5. タイトルは具体的な症状にし、[Issueフォーム](../../../.github/ISSUE_TEMPLATE/bug_report.yml)の項目に沿って読みやすい下書きを作る。利用可能なGitHubツールや `gh issue list --repo nyasukun/talk-to-webex-bot --state open --search '一般化した症状'` で重複を調べる。検索できなければ未確認と明示し、下書きの完成を妨げない。
6. ユーザが投稿まで依頼していれば、その許可の範囲で投稿する。相談や下書きの依頼だけなら、完成した内容を提示してから投稿許可を得る。CLIでは `gh issue create --repo nyasukun/talk-to-webex-bot --title '症状' --body-file .build/issue-report.md` を使う。投稿結果が不明な場合は既存Issueを検索し、重複を確認するまで再投稿しない。利用可能な認証済みツールがなければ、[報告フォーム](https://github.com/nyasukun/talk-to-webex-bot/issues/new?template=bug_report.yml)と下書きを渡す。

投稿時は作成したIssueのURL、下書きだけの場合はその状態と保存先を返す。自動収集しなかった情報を「検証済み」と書かない。
