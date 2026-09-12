# Audio Level Bar 公開・配布ロードマップ

この文書は、公開前監査を受けて確定した公開・配布方針です。端末固有のデバイス名、権限DB、backupパス、バイナリhashは公開リポジトリへ置かず、非公開の配備記録として分離します。

## 確定した方針

- 知的財産の帰属とライセンス付与権限を確認した後、`yuhkis/audio-level-bar`を個人プロジェクトとして公開します
- 識別子と名前空間は個人のもの（`io.github.yuhkis.*`）に統一し、所属組織を示す文字列を公開面に出しません
- 権利確認、公開文書、CI、実機ゲートが完了するまでGitHubリポジトリをprivateのまま維持します
- 本体コードはルート`LICENSE`のMIT Licenseで提供します。適用範囲は出自で決まります。`ThirdParty/`に置いた上流のライセンス本文と、`Vendor/`の静的ライブラリへコンパイルした上流のコードはMITの対象外で、各上流ライセンスが優先します。同じ場所に置いた自作のC ABIラッパはMITで、区別はSPDXヘッダで示します
- `make app`は本体`LICENSE`をアプリバンドルの`Contents/Resources/LICENSE`へ同梱し、`make verify-app`がソースとの一致を検証します
- 最初の公開版は`v0.4.0`とし、`.app`のRelease assetは添付しません
- リポジトリにはarm64用のWebRTC／Abseil静的XCFrameworkを含めます。固定ソース、hash、再生成手順、第三者noticeを追跡可能にします
- 一般配布バイナリは、Developer ID署名、Hardened Runtime、notarization、更新手順を検証した後の別マイルストーンとします
- 日常利用する正規版は`/Applications/Audio Level Bar.app`とし、`dist/Audio Level Bar.app`はビルド・検証用候補として扱います
- ログイン時起動は正規の`/Applications`版を対象にします。正式署名後は`SMAppService`への移行を検討します
- 複数のMacへ導入するときは、Macごとに再ビルドせず、最初に検証した同一バンドルを転送します。同じソースから別々に生成した候補は、同じMacで作り直した場合でも、source fingerprintが一致する一方でbundle content fingerprintとCDHashが一致せず、同一バイトの`.app`にはならないためです
- アプリのUIと権限文言は英語と日本語に対応し、macOSの言語設定に従います。開発ロケールは英語（`CFBundleDevelopmentRegion` = `en`）で、`localized(...)`のキーが英語の文言そのものです
- 利用者向け文書は`README.md`／`README.ja.md`、`CONTRIBUTING`、`CODE_OF_CONDUCT`、`SECURITY`、`THIRD_PARTY_NOTICES`を英語と日本語の対で提供し、英語をルートのファイル名に置きます
- `DESIGN.md`と`ROADMAP.md`は日本語のみとします。設計判断と公開方針の記録であり、利用者が読む前提の文書ではないためです。翻訳の二重管理コストが、想定読者に対する利益を上回ります
- `AGENTS.md`と`docs/development.md`は英語のみとします。コーディングエージェントと開発者が読む作業規約と作業別の詳細であり、同じ理由で対訳を用意しません。英語のみである旨は日本語読者向けに`README.ja.md`へ明記します
- `make diagnose`と`--reclaim-taps`の出力は英語のみとします。アプリバンドルの外で動作し文字列テーブルを参照できないため、そもそもローカライズできません

## 識別子と互換性

- Bundle Identifierは`io.github.yuhkis.audio-level-bar`です。公開版はこの識別子だけを用い、defaultsドメインの移行は行いません
- メニューバー位置は、アプリ自身のautosave keyに保存がない場合に限り、同じドメイン内のAppKit汎用キー`NSStatusItem Preferred Position Item-0`から引き継ぎます。同じドメイン内の旧キー読み替えは、ほかにメーター色の共有しきい値と、マイク音声処理方式の前身であるオン／オフのフラグがあります
- 公開加工済みマイクのUIDは`io.github.yuhkis.audio-level-bar.processed-microphone.public`です。このUIDだけは利用者の環境へ複製されるため、公開後は変更しません。入力一覧からの除外と孤立デバイス回収も、このUIDだけを対象にします
- 互換性に不要なqueue labelや一時aggregate UIDは`io.github.yuhkis.audio-level-bar`名前空間を使用します

## Versionとbuildの境界

候補の同一性は、build番号ではなく候補自身に埋め込んだprovenanceで判定します。Git cloneから作る候補にはcommit SHA、clean／dirty状態、source fingerprint、HEADコミット時刻を埋め込み、`make verify-app`が表示します。Gitメタデータを含まないDownload ZIP等では`source-archive`と内容fingerprintを埋め込み、Git clone由来と混同しません。

**同じversion/buildを別内容の配備候補へ再利用しません。** `scripts/build-app.sh`はsource fingerprintに加えてcommitとclean／dirty状態も比較し、一致しなければ同じbuild番号での再生成を拒否します。したがってbuild番号は、配備候補を作るたびに進めます。ビルドもインストールもしないコミットでは進めません。コミットしてから候補をビルドする順序は[開発資料](docs/development.md#build-and-installation)に記載しています。逆順にすると同じ内容に2つのbuild番号を使うことになります。

build番号ごとの経緯はこの文書では追跡しません。候補は頻繁に作られ、必要な事実は候補自身に埋め込まれています。どのMacに何を導入したかは端末固有の情報なので、冒頭の方針どおり非公開の配備記録に置きます。

以下は、build番号でしか表現できない互換性の境界です。

- 公開履歴の最初のcommitより前に作られた候補は、埋め込まれたcommit SHAをこのリポジトリから解決できません。公開前の開発は公開対象ではないためで、対応関係は非公開の配備記録でのみ追跡します

公開候補のbuild番号は固定しません。実機ゲートを通過した候補に対して`v0.4.0`タグを作成します。

## 公開前のソース整理

- [x] Bundle Identifierを`io.github.yuhkis.*`に固定した
- [x] ユーザー単位の排他ロックと、実行中の別インスタンス検出を実装した
- [x] `/Applications`へのbackup付き置換とLaunchAgent切替をtransaction化した
- [x] build provenanceとアプリバンドル検証を実装した
- [x] チャンネル別しきい値とstatus itemの右クリック操作を文書化した
- [x] `.claude/`、非公開の配備記録、build成果物をリポジトリ単位で除外した
- [x] 第三者バイナリのhash、notice、smoke testを公開ソースから追跡可能にした
- [x] CI workflow、contribution、security、conduct文書を用意した
- [x] commitに使うGit authorをGitHub noreplyアドレスへ統一した
- [x] 個人としてライセンス付与できることを確認し、ルート`LICENSE`（MIT）を追加した

公開履歴は、監査済みのtreeから作る単一のroot commitから始まります。それ以前の開発履歴は公開対象ではありません。
著作者名が公開面に現れるのは、著作権表示（ルート`LICENSE`と自作ラッパのSPDXヘッダ）とcommitのauthor名に限ります。

## CIと検証境界

GitHub ActionsではApple SiliconのmacOS runnerを使い、次を検証します。

- plistとshell scriptの静的検証
- ローカライズ検査（`make check-localization`）
- vendored static libraryのSHA-256、architecture、header、module map
- checked-in libraryへ直接linkするWebRTC smoke test
- `make test`
- `make app`と`make verify-app`

CIでは`make diagnose`、GUI、TCC、デバイス切替、音量書き込み、スリープ復帰、consumerアプリでの音声品質を検証しません。これらは実機ゲートとして別に記録します。CIのアドホック署名済み`.app`は一時的な検証成果物であり、artifactとして保存・配布しません。同じbuild番号を異なるcommitのCIが検証する場合も、埋め込みcommitとsource fingerprintで区別します。「同じversion/buildを別内容の配備候補へ再利用しない」という規則は、保存して実機へ配備する候補に適用します。

## publicへ変更するゲート

次の項目をすべて満たすまでpublicへ変更しません。

- [x] 個人として公開・MIT Licenseを付与できることを確認した
- [x] ルート`LICENSE`、第三者notice、サポート方針、公開用文書が揃っている
- [x] 公開履歴のauthor／committer emailをGitHub noreplyアドレスとする方針を決定した
- [ ] 公開する`main`の履歴を、監査済みのtreeから作る単一のroot commitから始め、そのauthorとcommitterがGitHubのnoreplyアドレスであることと、非公開パターンファイルを置き`origin`を公開先へ向けたcloneで`make audit-history`が検出なしで通ることを確認した
- [ ] 公開するGitHubリポジトリの`main`が、そのroot commitから始まり、ローカルの`main`と同じcommitを指している。root commitより前の履歴へ到達するbranch、tag、PRのhead refがない（PRのhead refはbranchを削除しても消えないため、これは後から解消できません）。root commitを基点とするPRやbranchはこの条件の対象外で、`v0.4.0`タグも実機ゲート通過後に作成します
- [ ] 公開するリポジトリで、working treeがcleanなfresh cloneとGitHub Actionsの両方からテスト・ビルド・検証を再現できる
- [ ] 公開するリポジトリのPR、Issue、Actionsログを含む公開対象に秘密情報と個人絶対パスがない
- [x] 孤立Process Tapの原因と、自分が作成したものだけを対象にする安全なcleanupを検証した
- [x] 終了、公開が残った状態からの再起動、加工済みマイク使用中の入力切替でresource状態を確認した
- [x] UIと権限文言の英語・日本語対応と、利用者向け文書の英日対を用意した
- [ ] 機器の抜き差しとスリープ復帰後のresource状態を確認した

このゲートは加工済みマイクだけの問題ではありません。システム再生レベル監視も自分のProcess Tapと集約デバイスを作るため、抜き差しとスリープ復帰は実験的表記の対象外の機能にも掛かります。したがって実験的表記では免除せず、実機で確認します。孤立Process Tapのcleanupと資源状態の2項目は、tapと集約デバイスの帰属判定を現行の識別子だけへ狭める前に確認したものなので、この実機セッションでまとめて再確認します。

**このゲートがクラッシュを1件検出しました。** Bluetoothヘッドセットを装着して既定入力が内蔵マイクから切り替わった瞬間に、`SIGSEGV`（`EXC_BAD_ACCESS`）で終了しました。クラッシュレポートに競合の両側が写っています。`microphone-meter.lifecycle`キューが`-[AVAudioEngine dealloc]`を実行している最中に、AVFAudioの`AVAudioIOUnit::IOUnitPropertyListener`のブロックが`AVAudioIOUnit`キューで同じオブジェクトへ`objc_msgSend`していました。デバイス到着がそのリスナーを発火させています。

これは加工済みマイクの経路ではありません。落ちたのは常時動作するマイクレベルメーターで、加工済みマイクはオフでした。**実験的表記はこのクラッシュをカバーしません。** さらに、クラッシュはteardownを完走しない異常終了なので、同じ競合が加工済みマイクの公開中に起きればcoreaudiodのwedge経路に一致します。加工済みマイクのリスク評価も、この修正が検証されるまでは引き上げて扱います。

修正は`MicrophoneMeter`がstartのたびに`AVAudioEngine`を作り直すのをやめ、restart経路では同一オブジェクトを使い回してtapだけ張り直す形にしました。この時点で`AVAudioEngine`を破棄する経路は`stop()`だけになりました。`stop()`は終了時と加工済みマイクへの受け渡し時にしか呼ばれず、デバイス変更の最中には走りません。

**engineを使い回すこの修正が、2件目のクラッシュを生みました。** その後、実機の候補が`SIGABRT`で終了しました。`AVAudioEngineImpl::InstallTapOnNode`がObjective-C例外を投げています。同じクラッシュレポートで、別スレッドがAVFAudioの`IOBindingChanged`の中でエンジンのロックを待っており、`installTap`を呼んだ瞬間に入力の結び付け替えが進行中でした。engineを使い回すと、`outputFormat`を読んでから`installTap`へ渡すまでの間にハードウェア形式が変わり得ます。`InstallTapOnNode`は渡された形式を現在の形式と照合して例外を投げ、Objective-C例外はSwiftから捕捉できないためプロセスが落ちます。**1件目のSIGSEGVをSIGABRTに置き換えただけでした。**

続けて、tapの形式を自前で渡すのをやめて`nil`をAVFAudioへ委ね、設定変更後の再起動の待ち時間を0.3秒から0.75秒へ延ばしました。前者は形式の不一致という原因そのものを取り除き、後者は結び付け替えが収まる前に触れる確率を下げます。

**これは緩和であって保証ではありません。** 結び付け替えの最中であれば`installTap`は依然として例外を投げ得ますし、Swiftからは捕捉できません。確実にするにはObjective-Cの`@try`/`@catch`でこの呼び出しを包むか、メーターをAVAudioEngineからHAL IOProcへ移す必要があります。後者は`SystemOutputMeter`が既に採っている方式で、この不具合クラス自体が消えますが、加工済みマイクへの入力受け渡しを含む書き直しになります。前者は後に実装しました（後述）。後者は未着手です。

**次の候補は入力デバイスの遷移を5回越えて生存し、このときはクラッシュが止まりました。** 一方で、AirPodsをマイクに選ぶと「マイクレベルの監視を開始できません」を表示するようになりました。調べた結果、これはその候補が作った不具合ではなく、**元からあった不具合が可視化されたもの**です。

原因はサンプルレートの読み取り先でした。`AVAudioInputNode`の`outputFormat(forBus:)`は入力デバイスの実レートを反映せず、AirPodsマイク（実機24 kHz）に対しても48 kHzを返し続けます。実測値は次のとおりです。

| tapに渡す形式 | 結果 |
|---|---|
| `nil`（nodeのoutputFormat 48 kHzへ解決） | 開始失敗 `-10868` |
| `outputFormat`（48 kHz）を明示 | 開始成功、**受信フレーム0**（無音） |
| `inputFormat`（24 kHz）を明示 | 開始成功、フレーム受信あり |

元のコードは`outputFormat`を明示していたため、レートの異なるマイクでは開始に成功したまま1フレームも届かず、🎙が`--`のまま無言で止まっていました。`nil`へ変えたことで、同じ失敗が可視のエラーへ変わりました。48 kHzで動く機器では症状が出ないため、これまで露見していませんでした。

修正として`inputFormat(forBus:)`を読み、その形式を明示してtapを張るようにしました。24 kHzのマイクでもメーターが動きます。

**例外の経路はそれでも残っていました。** さらに次の候補が、素早いマイク切り替えの最中に、`installTapOnBus:`が呼び出し時点で形式を照合し直して投げたObjective-C例外で終了しました。`inputFormat(forBus:)`を読んだ直後の形式でも、デバイス変更の進行中はinstallまでの間にハードウェア形式が変わり得ます。そこでObjective-Cの小さなshim（`ObjCExceptionShim`）で`@try`/`@catch`を実装し、`installTap`と、同じように例外を投げ得る`prepare()`／`start()`を包みました。捕捉した例外は具体的なエラーとして表示し、形式が落ち着くのを待って0.75秒後に再試行します。再試行はそのセッションが現行である間に限り、連続8回までです。捕捉した例外ごとにわずかなメモリが残るため、例外を投げ続けるデバイスで際限なく増やさないためです。成功すると回数はリセットされ、デバイス変更やパネル表示による開始は回数にかかわらず試みます。メーターをHAL IOProcへ移してこの不具合クラスそのものを消す方法は、引き続き未着手です。

その後、Bluetoothマイクの監視を止めるために、`suspend()`が2.5秒の沈静化遅延の後にengineを解放する経路を加えました（DESIGN.md参照）。遅延中に再開した場合は解放を取り消してengineを再利用します。したがって現在、`AVAudioEngine`を破棄する経路は`stop()`とこの遅延解放の2つです。

**デバイス変更でアプリが死ぬ経路が残っている限り、加工済みマイクの公開中のクラッシュはcoreaudiodのwedgeに直結します。** 既知の経路には上記のとおり対処しましたが、機器の抜き差しはad-hoc署名のビルドで試したのみで、スリープ復帰はまだ確認していません。このゲートは未通過のままです。

「QuickTime Player、Zoom、Teamsで実発話、先頭欠落、音切れを確認した」は、加工済みマイクを実験的機能として公開する判断に伴い、公開の阻害要因から外しました。理由は次節に記録します。

孤立Process Tapのcleanupは、他アプリのtapを同時に置いた状態で両方向を確認しました。自分のbundleに帰属する孤立tapだけが破棄され、帰属しないtapは残ります。アプリが動作中のときは、使用中と取り残されたtapを区別できないため回収そのものを行いません。

実際のクラッシュは再現していません。加工済みマイクの公開中に強制終了するとcoreaudiodを巻き込む危険があるためです。代わりに、消費側がデバイスを開いている最中に終了して公開が残った状態を作り、そこからの復帰経路を確認しました。残留する資源の状態はクラッシュ後と同じです。

## 加工済みマイクを実験的機能として公開する判断

加工済みマイクは「実験的（experimental）」と明記したうえで0.4.0に含めます。UIのトグルは「加工済みマイクを使用（実験的）」、READMEでは独立した節に警告付きで記載します。それ以外の機能――メニューバーのメーター、デバイス選択、音量と入力ゲイン、ミュート、システム再生レベル監視――は通常機能として公開します。

この判断の前提は次の3点です。

1. **既知の制限は回避策も含めて文書化済み**で、アプリ内で直せる種類のものではありません（次節）。消費側アプリの再起動という回避策があり、根本解は配布方式の変更を伴う別マイルストーンです
2. **最悪の失敗モードを表記と分離して明記する。** 「実験的」という語が通常伝えるのは「粗いかもしれない」「仕様が変わるかもしれない」までであり、「Macの再起動が必要になるかもしれない」は伝えません。公開中の強制終了がcoreaudiodを巻き込む件は、実験的表記とは別に、READMEの独立した見出しとして警告します
3. **オフにすれば影響が完全に消える。** 加工済みマイクは初期状態でオフであり、オンにしなければProcess Tapも集約デバイスも作りません

したがって、consumerアプリでの実発話品質の網羅的な検証は、公開の阻害要因ではなく、実験的機能の未確認事項として扱います。ただし、それを「検証した」とは記載しません。READMEには未検証の範囲と既知の制限を書き、メーターが動くことや単体テストの成功をもって音声品質確認の完了とはみなさない方針を維持します。

## 既知の制限: 同一プロセスからの再オープンが無音になる

消費側プロセスが一度デバイスを開いて完全に手放すと、以後そのプロセスからのオープンは全ゼロを受け取ります。QuickTimeの2本目の収録、アプリを終了せずの通話再入室、録音前に短くデバイスを開くアプリの本番録音が該当します。回避策は消費側アプリの再起動です。

原因はProcess Tapを含む集約デバイスのmacOS側の不具合で、集約デバイスの`AudioObjectID`が同じである限り続きます。tapは生きており、差し替えても直りません。

待機へ戻るたびに公開集約を作り直す対処を実装して撤回しました。数サイクルで、破棄した集約のUIDがデバイス一覧から消えるのを待つ処理が時間切れになり、そこから復帰できずデバイスが全アプリの入力一覧から消えます。無音より悪い状態を作るため採用しません。

根本的な解消には仮想オーディオドライバ（AudioServerPlugIn）への移行が必要で、配布方式の変更（root権限インストール、Developer ID署名、notarization）を伴うため別マイルストーンとします。0.4.0はこの制限を明記したうえで公開します。

## 公開後の最初の形

- GitHub owner: `yuhkis`
- Repository: `audio-level-bar`
- License: MIT
- First public tag: `v0.4.0`（実機ゲート通過後に作成）
- Release assets: なし
- Binary distribution: Developer ID署名・notarization完了後に別途判断
- Update mechanism: 当初は手動。ネットワークアクセスを伴う自動更新は別の設計変更として扱う
- Private vulnerability reporting: public化の直後に有効化する。`SECURITY.md`／`SECURITY.ja.md`が指定する報告経路がこれで、有効化するまで報告先が存在しない
