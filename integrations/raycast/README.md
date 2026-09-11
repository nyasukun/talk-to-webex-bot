# Talk to Webex bot — Raycast

Raycastに **`talk` と入力するだけ**で、有効なユースケースが検索結果に直接並びます。「Talk」を一度開く操作は不要です。

- `talk 日本語で要約`
- `talk 日本語へ翻訳`
- アプリで追加した任意のユースケース

項目を選んでEnterを押すとRaycastが閉じ、前面に戻ったアプリのウィンドウで実行します。`talk 要約` のように続けて入力して絞り込むこともできます。初期2件は直接送信・読み上げOFFです。

## 初回の設定

1. 更新版のTalk to Webex botを起動し、Webexの認証・送信先DMを保存して画面収録を許可します。画面操作だけならマイク・Whisperの準備は不要です。
2. Raycastの **Settings → Extensions → ＋ → Add Script Directory** を開き、以下のフォルダを登録します。

   ```text
   ~/Library/Application Support/LocalVoiceRelay/raycast-scripts
   ```

3. 対象ウィンドウからRaycastを開いて `talk` を入力し、候補を選んでEnterを押します。

Raycastの[Script Commands](https://github.com/raycast/script-commands#install-script-commands-from-this-repository)を使うため、Node.jsや開発モードの常駐は不要です。アプリの「画面ホットキー」で追加・複製・名前変更・有効化・削除を保存すると、候補も自動更新されます。登録数にアプリ側の上限はありません。ホットキー未設定の項目も表示します。

以前の開発拡張で「Talk」が表示される場合は、RaycastのSettings → Extensionsでその旧コマンドのEnabledをOFFにすると、候補だけを直接選べます。旧拡張のTypeScriptソースは、このディレクトリに任意の一覧ビューとして残しています。新しい方式では導入不要です。

## 実行時の設定

プロンプト・読み上げ・送信前確認は、アプリの「画面ホットキー」に保存したユースケースごとの設定を使います。編集中の未保存の内容は使いません。

- 読み上げOFFの場合、返信はWebexで確認します。ONの場合は共通の音声方式・音量・返信監視設定を使います。
- 送信前確認ONの場合は、Talk to Webex botで本文・画像・宛先を確認してから送信します。
- 別の操作中は実行しません。連打や通信失敗でも自動再送はしません。
- 画面ロック中、対象アプリの切り替え、画面・OCR取得失敗時には送信を止めます。

## ローカル連携の仕組み

アプリは起動時と設定保存時に、ローカルの `screen-use-cases.json` と `raycast-scripts/talk-<ユースケースUUID>.sh` を更新します。スクリプトは名前とIDを持ち、同じ署名付きアプリのコマンドラインモードを呼び出します。認証情報・宛先・プロンプト・画像・OCRをスクリプトに含めません。生成先フォルダとスクリプトは0700、一覧と実行要求は0600です。

コマンドラインモードはマイク・画面取得・キーチェーン読み込みを起動しません。Raycastが閉じて前面アプリが安定してから一回限りの要求ファイルを作り、`talk-to-webex-bot://run?request=<要求UUID>` を `/usr/bin/open -g -a <アプリの場所>` でGUIアプリに渡します。GUIアプリはSwiftUIのアプリデリゲートでURLを受信します。

要求は30秒で失効し、実行前に消費するため再実行できません。URLだけでは送信できず、実行内容は保存済みの設定から取得します。受付結果はRaycastのHUD、以降の進捗やエラーはTalk to Webex botに表示します。

## 開発・検証

リポジトリ直下の `scripts/test.sh` で、コマンド生成・要求の受信・同期・モック送信を検証します。`scripts/build.sh` で署名付きアプリに含まれるコマンドラインモードもビルドします。

任意の旧一覧拡張を開発する場合だけ、このディレクトリで `npm ci`、`npm run typecheck`、`npm test`、`npm run build` を実行します。`npm run dev` は旧一覧コマンドをRaycastに登録します。新しい直接検索の利用には実行不要です。
