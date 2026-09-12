# Contributing

[English](CONTRIBUTING.md) | **日本語**

IssueとPull Requestを歓迎します。個人が余暇に開発しているプロジェクトのため、対応や返信をお約束できず、方針に合わない提案はお断りすることがあります（[README.ja.md](README.ja.md)の「公開・配布状況」を参照）。

本体コードはルート[`LICENSE`](LICENSE)のMIT Licenseで提供します。Pull Requestを送る場合は、その変更を同じMIT Licenseで提供できること、および第三者の著作物を含む場合はその出典とライセンスを明記することを前提とします。

## 開発の基本手順

1. Apple Silicon Macへリポジトリをcloneします
2. そのMacで`make setup-dev`を一度実行します。`core.hooksPath`を`scripts/git-hooks`へ向け、`.local/private-patterns.txt`のテンプレートを作り、あなた自身のGit identityをこのcloneへ固定します
3. `make test`でUI非依存の単体テストを実行します
4. `make build`でアプリ本体をコンパイルします
5. `make ci`でメタデータ、ローカライズ、vendored library、アプリバンドルまで検証します
6. ユーザー向けの設定、コマンド、権限、表示を変更した場合は、同じ変更で`README.md`（および`README.ja.md`）または`DESIGN.md`を更新します

`make ci`はアプリバンドルまで作り、`scripts/build-app.sh`は同じbuild番号を別内容へ再利用することを拒否します。そのため、変更後にもう一度ローカルで`make ci`を実行すると「Refusing to reuse …」で失敗します。このときはbuild番号を上げるのではなく`dist/`を削除してください。Pull Requestでは`Resources/Info.plist`の`CFBundleVersion`を変更せずそのままにします。同時に進むPull Requestがこの1行で衝突しないようにするためで、build番号は、次の配備候補を作るときにメンテナが上げます。GitHub Actionsは`dist/`が無い状態から始まるため影響を受けません。

Core Audioや実デバイスへ書き込む検証では、変更前の既定デバイス、音量、入力ゲインを記録し、検証後に戻してください。`make diagnose`は読み取り専用であり、CIでは実行しません。

## 変更時に守ること

- 音声サンプルを録音、永続化、ネットワーク送信しない
- システム再生キャプチャと加工済みマイクを明示的なオプトインに保つ
- デバイスが報告しない音量を100%と推定しない
- 変更不能なプロパティのスライダーを表示しない
- 利用者向けの文字列は英語の文言をキーとして`localized(...)`を通し、同じ変更で`Resources/ja.lproj/Localizable.strings`へ日本語訳を追加する。どちらかのテーブルに無いキー、未使用のキー、英語テーブルの値がキーと同一でないキーがあると`make check-localization`が失敗する
- `ThirdParty/`または`Vendor/`を変更するときは、取得元、固定版、SHA-256、ライセンス、再生成手順を同時に更新する
- GUI、TCC、consumerアプリでの音声品質を、単体テストやメーター表示だけで検証済みとしない

## Pull Requestの検証記録

実行したコマンド、対象macOS／Xcode、接続した音声機器、実機で確認した範囲と未確認事項を記載してください。秘密情報、個人の絶対パス、音声データ、TCCデータベースの内容を添付しないでください。
