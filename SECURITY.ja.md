# Security policy

[English](SECURITY.md) | **日本語**

## Supported version

`main`の最新状態と、タグを作成した以降は最新のリリースを対象にします。それより前のタグは対象外です。

## Reporting a vulnerability

GitHubのPrivate vulnerability reporting（Security → Report a vulnerability）を使用してください。公開Issueへ、未修正の脆弱性、認証情報、個人情報、音声データ、端末固有のログを投稿しないでください。

報告には、影響するversion／commit、再現条件、期待する安全な挙動、最小限の再現手順を含めてください。受領確認と公開時期は、影響範囲を確認した後に個別に調整します。

このアプリはマイクとシステムオーディオの権限を使用し、Core AudioのProcess Tapとaggregate deviceを作成できます。権限境界、意図しない音声保存・送信、別プロセスへの干渉、残留デバイスやTapはセキュリティ上の問題として扱います。
