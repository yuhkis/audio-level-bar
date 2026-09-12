# Third-party notices

[English](THIRD_PARTY_NOTICES.md) | **日本語**

Audio Level Bar本体のライセンスと、第三者コンポーネントのライセンスは別に扱います。本体コードにはルート[`LICENSE`](LICENSE)のMIT Licenseが適用されます。適用範囲はディレクトリではなく出自で決まります。`ThirdParty/`には上流のライセンス本文を、`Vendor/`には上流のコードをコンパイルした静的ライブラリを置いています。いずれもMITの対象外で、各上流プロジェクトのライセンス、copyright、PATENTSが優先して適用されます。下記のC ABIラッパはAudio Level Bar自身のコードで、本体と同じくMITです。ラッパとそのsmoke testのソースファイルにはSPDXヘッダを付けてあり、同じ場所にあるREADMEとビルド用メタデータも本プロジェクト自身のものです。

## WebRTC noise suppression

`Vendor/WebRTCNoiseSuppression.xcframework`は、次のコンポーネントをarm64 macOS向けに静的リンクしたビルド用バイナリです。

- webrtc-audio-processing 2.1
- Abseil 20240722.0
- WebRTCに同梱されるOoura FFT、SPL square-root、FFT、PFFFT、RNNoise関連コード
- Audio Level Barの小さなC ABI wrapper

固定ソース、patch、vendored static libraryのSHA-256、再生成方法、smoke testは[ThirdParty/WebRTCNoiseSuppression/README.md](ThirdParty/WebRTCNoiseSuppression/README.md)に記録しています。上流の原文noticeは[ThirdParty/WebRTCNoiseSuppression/LICENSES](ThirdParty/WebRTCNoiseSuppression/LICENSES)に保存し、`make app`でアプリバンドルへ同梱、`make verify-app`で原文との一致を検証します。

このファイルは上流ライセンス本文の代替ではありません。利用・再配布時は、上記ディレクトリ内の各原文を確認してください。
