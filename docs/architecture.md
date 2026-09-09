# 構成と変更の境界

## データの流れ

音声入力 → ローカルworkerの文字起こし → 合言葉と送信モードの判定 → 任意の画面取得 → 送信前確認 → Webex → 返信判定 → ローカル読み上げ、という流れです。`AppModel` は処理の世代を管理し、停止後に返った古い結果を採用しません。送信の成否が不明なPOSTを自動再送しないことは、変更時も維持してください。

## 主な責務

| 場所 | 責務 |
| --- | --- |
| `Sources/RelayCore` | 設定と移行、テンプレート、合言葉、返信判定、Webex通信。UIやキーチェーンに依存しないロジック。 |
| `AppModel.swift` / `AppModelPresentation.swift` | 音声・送信の進行管理と、画面の状態・設定準備の案内。 |
| `PrivateFiles.swift` / `Storage.swift` | 上限付きのファイル読込、0600での一時書込と原子的な置換、設定とキーチェーン。既存の署名・保存先の互換性を維持。 |
| `LocalWorker.swift` / `WorkerResponseReader.swift` | 直列のworker呼び出しと、最大1 MBのJSON Lines応答の組立。改行のない途中応答を受け付けない。 |
| `OfflineProcess.swift` | workerと標準読み上げのネットワーク禁止・環境変数の許可リスト。 |
| `worker/relay_worker.py` | ローカル音声推論。アプリが定義したエラーだけを利用者へ返し、依存ライブラリの例外本文を返さない。 |
| `DiagnosticLog.swift` / `IssueReport.swift` | 既知イベントと数値の診断、共有可能な項目だけで構成する報告下書き。 |

## 検証

`scripts/test.sh` が共通の入口です。`RELAY_TEST_PYTHON` を指定すると、既定のローカルランタイム以外でもworkerテストを実行できます。workerの依存関係は `worker/uv.lock` を使い、モデルを自動取得するテストは追加しません。

GitHub ActionsはApple Siliconの `macos-15` を使い、固定コミットのActionsと固定版uvで依存関係を準備します。ランナーの対応は[GitHub公式資料](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)を確認してください。CIに個人設定・モデル・署名鍵は渡さず、パッケージは未署名の検証用です。

公開前監査は通常のテキストと、明示的にハッシュを承認した生成アイコンだけを許可します。画像を一般的に除外解除せず、個人の録音・録画・画面キャプチャはGitへ追加しないでください。コミット直前には `python3 scripts/audit-public.py --staged` を実行します。
