# Talk to Webex botの署名手順

このMacで使うアプリの手順です。通常は作成済みのローカル証明書を再利用します。配布用の署名・公証を行う手順ではありません。

## 既存のローカル証明書で署名する

アプリを終了し、このリポジトリをターミナルの作業ディレクトリにします。

```bash
# 初回だけ必要。設定済みなら同じ証明書を再利用する
python3 scripts/setup-signing.py

# ビルドと署名を分けて行う
scripts/build.sh --prepare
python3 scripts/sign-app.py "dist/Talk to Webex bot.app"

# 署名の検証と起動
codesign --verify --strict --verbose=2 "dist/Talk to Webex bot.app"
open "dist/Talk to Webex bot.app"
```

すでに「署名待ち」の.appが用意されている場合は、`sign-app.py` の行から実行できます。`--prepare` はアプリのパッケージを作成するまでで、最後の証明書署名を行いません。署名と検証に成功してから起動してください。

macOSから「codesign」が「Local Voice Relay Development」の秘密鍵を使う確認が出たら、許可してください。今後のビルドでも使用する場合は「常に許可」を選べます。要求されたMacのパスワードはmacOSのダイアログ内だけで入力します。この証明書名は以前に作成した鍵の名前で、アプリ名を変更しても同じ鍵を再利用します。

署名成功時は `Signature verified.` と表示されます。次回からはアプリを終了して `scripts/build.sh` を実行すれば、ビルドと同じ証明書での署名をまとめて行えます。

## 自分のApple発行証明書を使う場合

既存のApple Development証明書など、秘密鍵と対になったコード署名用証明書がキーチェーンにある場合に使えます。

```bash
# 利用可能な証明書を自分のターミナルで確認する
security find-identity -v -p codesigning
```

使う証明書の40桁のSHA-1を以下のプレースホルダーと置き換えて、手元のターミナルで実行します。実際の個人名・証明書の選択情報をリポジトリへ書き込まないでください。

```bash
SIGNING_IDENTITY='YOUR_CERTIFICATE_SHA1' python3 scripts/sign-app.py "dist/Talk to Webex bot.app"
codesign --verify --strict --verbose=2 "dist/Talk to Webex bot.app"
```

再ビルドでも同じ証明書を指定します。`SIGNING_IDENTITY` はそのコマンドだけに適用されるため、毎回指定してください。

```bash
SIGNING_IDENTITY='YOUR_CERTIFICATE_SHA1' scripts/build.sh
```

環境変数の指定を省くと、作成済みのローカル証明書が選ばれます。署名に失敗した場合、別の証明書へ自動で切り替えません。署名方式の切り替え時は画面収録やキーチェーンの許可を求められることがあります。

## 権限とアプリ名

Finderの.app名、ウィンドウ、画面内タイトルは「Talk to Webex bot」です。Bundle ID `org.localvoicerelay.app` と設定保存先 `~/Library/Application Support/LocalVoiceRelay/` は既存設定との互換性のため維持しています。旧名の.appが残っている場合は、今回の新しい.appを起動してください。

アドホック署名は実行ファイルの変更で識別条件が変わります。同じ証明書とBundle IDを継続して使うことで、更新版を同じアプリとして識別できる署名条件を維持します。画面収録の許可が実際に再ビルド後も使えるかは、このMacでの確認が必要です。[Appleの署名要件](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)

署名コマンドは画面収録権限をリセットしません。起動後、サイドバーの「権限」で状態を確認してください。システム設定に旧署名の登録が残っている場合は、画面収録一覧の対象アプリを削除して、新しい.appを再許可します。

## 保存済みトークンへのアクセス

旧署名で保存したトークンは、アプリの署名を固定しても以前の許可設定が残る場合があります。起動時に読み出せないときは、Webex設定の「保存済みトークンへのアクセス」を開き、「保存済みトークンを読み込む」を押してください。macOSの確認に「常に許可」があれば、今後も同じ署名で使うアプリに許可を保存できます。トークンを作り直す必要はありませんが、すでに失効していれば更新は必要です。

読み出しボタンは一度だけ読み出し、既存項目のアクセスリストを書き換えません。アクセスリスト自体の変更は所有者の承認を必要とするため、認証確認やトークン更新のたびに行うべき処理ではありません。トークンの更新は値だけ、新規項目は作成アプリを信頼するmacOSの既定設定を使います。[Appleの説明](https://developer.apple.com/forums/thread/836816)

既存のファイル型キーチェーンとの互換性を保つため、非対話読み出しではSecurityの対話フラグを直列キュー内で一時的に無効にし、完了通知前に元へ戻します。トークンは起動中のメモリで再利用します。キーチェーン全体の保護や他の項目は変更しません。
