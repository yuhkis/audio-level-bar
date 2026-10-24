# Audio Level Bar 公開・配布ロードマップ

この文書は、公開前監査を受けて確定した公開・配布方針です。端末固有のデバイス名、権限DB、backupパス、バイナリhashは公開リポジトリへ置かず、非公開の配備記録として分離します。

## 確定した方針

- 知的財産の帰属とライセンス付与権限を確認した後、`yuhkis/audio-level-bar`を個人プロジェクトとして公開します
- 識別子と名前空間は個人のもの（`io.github.yuhkis.*`）に統一し、所属組織を示す文字列を公開面に出しません
- 権利確認、公開文書、CI、公開前監査が完了するまでGitHubリポジトリをprivateのまま維持します。実機ゲートは公開後の最初の作業として行い、その結果を記録してから`v0.4.0`タグを作成します（「publicへ変更するゲート」の節）
- 本体コードはルート`LICENSE`のMIT Licenseで提供します。適用範囲は出自で決まります。`ThirdParty/`に置いた上流のライセンス本文と、`Vendor/`の静的ライブラリへコンパイルした上流のコードはMITの対象外で、各上流ライセンスが優先します。同じ場所に置いた自作のC ABIラッパはMITで、区別はSPDXヘッダで示します
- `make app`は本体`LICENSE`をアプリバンドルの`Contents/Resources/LICENSE`へ同梱し、`make verify-app`がソースとの一致を検証します
- 最初の公開版は`v0.4.0`とし、実機ゲートの通過後に、Developer ID署名とnotarizationを済ませたDMGをRelease assetとして添付します
- リポジトリにはarm64用のWebRTC／Abseil静的XCFrameworkを含めます。固定ソース、hash、再生成手順、第三者noticeを追跡可能にします
- 一般配布バイナリは、`make release`で作るDeveloper ID署名、Hardened Runtime、notarization済みのDMGとし、v0.4.0以降のGitHub Releaseのassetとして配布します。添付は実機ゲートの通過後です。Developer ID Application証明書とnotarytoolの資格情報は保守者が用意し、リポジトリには置きません。更新は手動で、利用者が新しいDMGから置き換えます
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

次の項目のうち、最後の実機ゲートを除くすべてを満たしてからpublicへ変更します。実機ゲートを公開後へ回した判断と理由は、この節の末尾に記録します。

- [x] 個人として公開・MIT Licenseを付与できることを確認した
- [x] ルート`LICENSE`、第三者notice、サポート方針、公開用文書が揃っている
- [x] 公開履歴のauthor／committer emailをGitHub noreplyアドレスとする方針を決定した
- [x] 公開する`main`の履歴を、監査済みのtreeから作る単一のroot commitから始め、そのauthorとcommitterがGitHubのnoreplyアドレスであることと、非公開パターンファイルを置き`origin`を公開先へ向けたcloneで`make audit-history`が検出なしで通ることを確認した
- [x] 公開するGitHubリポジトリの`main`が、そのroot commitから始まり、ローカルの`main`と同じcommitを指している。root commitより前の履歴へ到達するbranch、tag、PRのhead refがない（PRのhead refはbranchを削除しても消えないため、これは後から解消できません）。root commitを基点とするPRやbranchはこの条件の対象外で、`v0.4.0`タグも実機ゲート通過後に作成します
- [x] 公開するリポジトリで、working treeがcleanなfresh cloneとGitHub Actionsの両方からテスト・ビルド・検証を再現できる
- [x] 公開するリポジトリのPR、Issue、Actionsログを含む公開対象に秘密情報と個人絶対パスがない
- [x] 孤立Process Tapの原因と、自分が作成したものだけを対象にする安全なcleanupを検証した
- [x] 終了、公開が残った状態からの再起動、加工済みマイク使用中の入力切替でresource状態を確認した
- [x] UIと権限文言の英語・日本語対応と、利用者向け文書の英日対を用意した
- [ ] 機器の抜き差しとスリープ復帰後のresource状態を確認した（公開後の最初の作業へ回した。この節の末尾）

このゲートは加工済みマイクだけの問題ではありません。システム再生レベル監視も自分のProcess Tapと集約デバイスを作るため、抜き差しとスリープ復帰は実験的表記の対象外の機能にも掛かります。したがって実験的表記では免除せず、実機で確認します。孤立Process Tapのcleanupと資源状態の2項目は、tapと集約デバイスの帰属判定を現行の識別子だけへ狭める前に確認したものなので、この実機セッションでまとめて再確認します。

**このゲートがクラッシュを検出しました。** Bluetoothヘッドセットを装着して既定入力が内蔵マイクから切り替わった瞬間に、`SIGSEGV`（`EXC_BAD_ACCESS`）で終了しました。クラッシュレポートに競合の両側が写っています。`microphone-meter.lifecycle`キューが`-[AVAudioEngine dealloc]`を実行している最中に、AVFAudioの`AVAudioIOUnit::IOUnitPropertyListener`のブロックが`AVAudioIOUnit`キューで同じオブジェクトへ`objc_msgSend`していました。デバイス到着がそのリスナーを発火させています。

これは加工済みマイクの経路ではありません。落ちたのは常時動作するマイクレベルメーターで、加工済みマイクはオフでした。**実験的表記はこのクラッシュをカバーしません。** さらに、クラッシュはteardownを完走しない異常終了なので、同じ競合が加工済みマイクの公開中に起きればcoreaudiodのwedge経路に一致します。加工済みマイクのリスク評価も、この修正が検証されるまでは引き上げて扱います。

修正は`MicrophoneMeter`がstartのたびに`AVAudioEngine`を作り直すのをやめ、restart経路では同一オブジェクトを使い回してtapだけ張り直す形にしました。この時点で`AVAudioEngine`を破棄する経路は`stop()`だけになりました。`stop()`は終了時と加工済みマイクへの受け渡し時にしか呼ばれず、デバイス変更の最中には走りません。

**engineを使い回すこの修正が、別のクラッシュを生みました。** その後、実機の候補が`SIGABRT`で終了しました。`AVAudioEngineImpl::InstallTapOnNode`がObjective-C例外を投げています。同じクラッシュレポートで、別スレッドがAVFAudioの`IOBindingChanged`の中でエンジンのロックを待っており、`installTap`を呼んだ瞬間に入力の結び付け替えが進行中でした。engineを使い回すと、`outputFormat`を読んでから`installTap`へ渡すまでの間にハードウェア形式が変わり得ます。`InstallTapOnNode`は渡された形式を現在の形式と照合して例外を投げ、Objective-C例外はSwiftから捕捉できないためプロセスが落ちます。**先のSIGSEGVをSIGABRTに置き換えただけでした。**

続けて、tapの形式を自前で渡すのをやめて`nil`をAVFAudioへ委ね、設定変更後の再起動の待ち時間を0.3秒から0.75秒へ延ばしました。前者は形式の不一致という原因そのものを取り除き、後者は結び付け替えが収まる前に触れる確率を下げます。

**これは緩和であって保証ではありません。** 結び付け替えの最中であれば`installTap`は依然として例外を投げ得ますし、Swiftからは捕捉できません。確実にするにはObjective-Cの`@try`/`@catch`でこの呼び出しを包むか、メーターをAVAudioEngineからHAL IOProcへ移す必要があります。後者は`SystemOutputMeter`が既に採っている方式で、この不具合クラス自体が消えますが、加工済みマイクへの入力受け渡しを含む書き直しになります。前者は後に実装しました（後述）。後者はこの時点では未着手でした。

**次の候補は入力デバイスの遷移を越えて生存し、このときはクラッシュが止まりました。** 一方で、AirPodsをマイクに選ぶと「マイクレベルの監視を開始できません」を表示するようになりました。調べた結果、これはその候補が作った不具合ではなく、**元からあった不具合が可視化されたもの**です。

原因はサンプルレートの読み取り先でした。`AVAudioInputNode`の`outputFormat(forBus:)`は入力デバイスの実レートを反映せず、AirPodsマイク（実機24 kHz）に対しても48 kHzを返し続けます。実測値は次のとおりです。

| tapに渡す形式 | 結果 |
|---|---|
| `nil`（nodeのoutputFormat 48 kHzへ解決） | 開始失敗 `-10868` |
| `outputFormat`（48 kHz）を明示 | 開始成功、**受信フレーム0**（無音） |
| `inputFormat`（24 kHz）を明示 | 開始成功、フレーム受信あり |

元のコードは`outputFormat`を明示していたため、レートの異なるマイクでは開始に成功したまま1フレームも届かず、🎙が`--`のまま無言で止まっていました。`nil`へ変えたことで、同じ失敗が可視のエラーへ変わりました。48 kHzで動く機器では症状が出ないため、これまで露見していませんでした。

修正として`inputFormat(forBus:)`を読み、その形式を明示してtapを張るようにしました。24 kHzのマイクでもメーターが動きます。

**例外の経路はそれでも残っていました。** さらに次の候補が、素早いマイク切り替えの最中に、`installTapOnBus:`が呼び出し時点で形式を照合し直して投げたObjective-C例外で終了しました。`inputFormat(forBus:)`を読んだ直後の形式でも、デバイス変更の進行中はinstallまでの間にハードウェア形式が変わり得ます。そこでObjective-Cの小さなshim（`ObjCExceptionShim`）で`@try`/`@catch`を実装し、`installTap`と、同じように例外を投げ得る`prepare()`／`start()`を包みました。捕捉した例外は具体的なエラーとして表示し、形式が落ち着くのを待って0.75秒後に再試行します。再試行はそのセッションが現行である間に限り、連続8回までです。捕捉した例外ごとにわずかなメモリが残るため、例外を投げ続けるデバイスで際限なく増やさないためです。成功すると回数はリセットされ、デバイス変更やパネル表示による開始は回数にかかわらず試みます。メーターをHAL IOProcへ移してこの不具合クラスそのものを消す方法は、この時点でも未着手でした。

その後、Bluetoothマイクの監視を止めるために、`suspend()`が2.5秒の沈静化遅延の後にengineを解放する経路を加えました（DESIGN.md参照）。遅延中に再開した場合は解放を取り消してengineを再利用します。したがってこの時点で、`AVAudioEngine`を破棄する経路は`stop()`とこの遅延解放の2つでした。

**続く実機ゲートで、coreaudiodが全プロセスに応答しなくなる事象を検出しました。** 既定入力に追従していたマイクメーターの動作中に、Bluetoothヘッドセットが接続されました。ログでは、アプリのコードを経由せずに、AVFAudioが既定デバイス用に作る集約デバイスとAUHALの代替デバイス探索が、メーターのIOをヘッドセットのマイクへ移していました。ヘッドセットのHFP入力はそれ自体の構成変更を要求し、coreaudiodはその中で全IOコンテキストの一時停止を待ちます。その最中にフレームワークが発行したメーターのIOの再開始がcoreaudiodの内部で止まり、一時停止の待ちが終わらなくなりました。以後どのプロセスも応答を得られず、復旧には再起動が必要でした。残っていたログの範囲では、Bluetooth入力を開いたのはすべてこのアプリでした。この追従はアプリの設定では止められず、再開始を遅らせても引き金の時刻がずれるだけです。

**そこでマイクメーターを`AVAudioEngine`からHAL IOProcへ移しました。** メーターは明示的に選んだ1つの`AudioDeviceID`に結び付き、既定入力へ自分から追従しません。Bluetoothマイクと、有効なサブデバイスにそれを含む集約デバイスは、パネルの表示にも加工済みマイクの状態にもよらず開かず、Bluetoothマイクでも常時監視する設定は削除しました。デバイス変更の後は、IOProc、Tap、集約デバイスの変更を静穏期間だけ保留します。いずれもDESIGN.mdの「Bluetoothマイクは自動では開かない」と「デバイス変更後の静穏期間」に記録しています。これにより、上に記録した`AVAudioEngine`の破棄とAVFAudioのリスナーの競合、`installTap`のObjective-C例外とその再試行、`outputFormat`と実レートの不一致、Bluetooth入力を解放するための2.5秒の遅延解放は、いずれもメーターには当てはまらなくなりました。`ObjCExceptionShim`はメーターでは使わなくなり、Apple音声処理の`AVAudioEngine`の呼び出しを包むために残しています。加工済みマイクの取り込みも、処理方式オフとWebRTCでは同じ方式のIOProcへ移し、Bluetoothマイクを入力にしません。Apple音声処理だけは`AVAudioEngine`に残ります。Bluetoothオーディオ機器が1台でも接続されている間は、既定になっていなくても動かしませんが、動作中に接続した場合は静穏期間の後に止めます。エンジンは開始時の入力と出力へ結び付けていますが、その数秒の間にmacOSがヘッドセットを既定にしたときに、結び付けたエンジンが追従しないことは実機でまだ確かめていません。

**build 56の実機ゲート（2026-10-24、Bluetoothヘッドセットを無人で出し入れ）は、基準1で不合格でした。** ①、②、③aはスリープのブロックを除いて自動判定で合格しましたが、③b-offでは、他のアプリが加工済みマイクを録音している間にヘッドセットが接続した瞬間、内蔵出力に結び付けたはずのpublisherの`AVAudioEngine`が既定出力になったヘッドセットへ移り（`invalidate`の`transport=moved`）、アプリの開始の行なしに、静穏期間の中で、アプリのプロセスでヘッドセットの出力のIOが始まりました（同じ`clientID=`の`IOWorkLoopInit`と`BluetoothHALPlugIn_StartIO`）。5サイクルとも同じで、ほかのブロックでも出ました。出力ノードを読み込んだ時点で、Bluetoothがなくても既定入力と既定出力の既定デバイス集約（`CADefaultDeviceAggregate-<アプリのPID>`）も作られていました。9/13にcoreaudiodが止まったときと同じ、フレームワークが既定へ自動追従してデバイスの変化の最中にIOを始める機構です。③b-Appleでも最初のサイクルで同種のIOが出ました。ヘッドセットへ移ったのはpublisherで、Apple音声処理のエンジンの行は結び付けた入力と出力を示し続けましたが、開始時に作り直される既定デバイス集約がどちらのものかはログで区別できませんでした。

**そこでpublisherもHAL IOProcへ移し、Apple音声処理は隠し設定の実験機能にしました。** publisherは、選んだ1つの出力デバイスに取り込みと同じライフサイクルキューで作るIOProcで、`AVAudioEngine`を使わず、既定デバイス集約も作りません（DESIGN.mdの「加工済みマイクはBluetoothマイクを入力にしない」）。Apple音声処理の扱いは、機能の削除、残して再ゲート、隠し設定への退避の3案からユーザーが隠し設定を選びました。`experimentalAppleVoiceProcessingEnabled`を設定して起動したときだけ選択肢に出し、実機ゲートの対象から外します（DESIGN.mdの「Apple音声処理は隠し設定の実験機能にする」）。合否基準1の`BluetoothHALPlugIn_register`は、ヘッドセットの出現時にCore Audioの全クライアントへ一斉に出る登録を含むため、同じ`clientID=`の`IOWorkLoopInit`か`BluetoothHALPlugIn_StartIO`を伴う登録だけを数える形に改めました。

**build 57の実機ゲート（2026-10-24〜25、同じ無人方式）は、②のスリープの挙動で不合格でした。** 基準1の決め手は解消し、アプリによるBluetoothのIOと`CADefaultDeviceAggregate-<アプリのPID>`は4構成の全ブロックで0件、スリープ以外の全ブロックが自動判定で基準を満たしました。しかしスリープしてから復帰するまで（`power will-sleep`から`power did-wake`まで）、ダークウェイクで動くアプリのシステム再生メーターが、レベルの届かないことを`output-stale`として数え、保留のたびにTap、非公開の集約デバイス、IOProcを約12秒ごとに作り直して、復帰より前に`give-up`へ至りました。既定出力がヘッドセットでも内蔵出力でも同じで、復帰後は出力が変わらない限りメーターが止まったままでした。そこでスリープ中はシステム再生メーターの回復を止め（レベルの到着を確かめず、無効化を数えず、作り直さない）、復帰で静穏期間を張って1回だけ作り直す形にしました（build 58、DESIGN.mdの「デバイス変更後の静穏期間」）。あわせて判定を実機の観察に合わせました。基準8は、集約デバイスの作成時にCore Audioが`_Deactivate`なしでTapのメタデバイスを一時的に登録・解除するため、`_Deactivate`を伴う解除だけを対象にしました。ライブのログはアプリの行を4〜15%落とすため、アプリの行はブロックごとに保存する永続ログで判定します。ダークウェイクを経ずに完全な復帰へ戻る場合は`Received power notification: FullWake`を復帰の起点とし、スリープそのものがMac自身のデバイスに出す要求の150 ms超は基準6で報告扱いとしました。

**これは原因を取り除く修正であって、coreaudiodの待ちそのものを防ぐものではありません。** 他のアプリが通話や音声入力でヘッドセットのマイクを開けば、同じ待ちは起こり得ます。静穏期間はタイミングに基づくため、デバイス集合や既定デバイスの変化を伴わない構成変更は検出できません。IOProcによるメーター、取り込み、publisherは、まだ実機ゲートを通していません。次のゲートは生存回数ではなく、下記のログ合否基準で判定します。

**デバイス変更でアプリが死ぬ経路、またはcoreaudiodを止める経路が残っている限り、加工済みマイクの公開中の事故はマシン全体の停止に直結します。** 既知の経路には上記のとおり対処しましたが、現在のIOProcによるメーターと取り込みは、機器の抜き差しもスリープ復帰もまだ実機で確認していません。このゲートは未通過のままです。

**実機ゲートは公開後の最初の作業へ回します。** 配布するのはソースだけで、READMEの冒頭と加工済みマイクの節に、現在のメーターと取り込みが実機ゲートを通っていないことを明記しています。ゲートはログ基準で判定するため、公開後に実施しても証拠の価値は変わらず、結果はそのまま公開履歴の次のcommitに記録できます。候補を開発機で日常的に動かした期間にクラッシュレポートもHALの応答停止もありませんでしたが、それは生存の観察であってゲートの証拠ではないので、合否の判断には使いません。`v0.4.0`タグはゲートを通過した候補に対して作成し、それまで公開リポジトリにタグとReleaseは置きません。

「QuickTime Player、Zoom、Teamsで実発話、先頭欠落、音切れを確認した」は、加工済みマイクを実験的機能として公開する判断に伴い、公開の阻害要因から外しました。理由は「加工済みマイクを実験的機能として公開する判断」の節に記録します。

孤立Process Tapのcleanupは、他アプリのtapを同時に置いた状態で両方向を確認しました。自分のbundleに帰属する孤立tapだけが破棄され、帰属しないtapは残ります。アプリが動作中のときは、使用中と取り残されたtapを区別できないため回収そのものを行いません。

実際のクラッシュは再現していません。加工済みマイクの公開中に強制終了するとcoreaudiodを巻き込む危険があるためです。代わりに、消費側がデバイスを開いている最中に終了して公開が残った状態を作り、そこからの復帰経路を確認しました。残留する資源の状態はクラッシュ後と同じです。

### 次のゲートのログ合否基準

生存回数では合否を判定しません。危険な操作の一部でだけ起きる事象は、何サイクルか続けて生存しても偶然に見逃し得ますし、coreaudiodの待ちは応答停止に至らないまま全プロセスを止めることがあります。一方、今回の修正が取り除いた機構は、サイクルごとのログに直接現れます。アプリによるBluetoothの入力や出力でのIO、Bluetoothの一時停止のバーストの時点で進行中のアプリの呼び出し、静穏期間中のアプリの資源変更、ドライバへ届くまでに滞る構成変更です。そこで下記の基準を各サイクルで判定し、機構が存在しないことを確かめます。まれな競合を捉えるためにサイクル数を積み上げることには頼らないため、サイクル数は少なく抑えています。構成、ブロック、ログの取り方、アプリのログ行の語彙は[開発資料](docs/development.md#hardware-gate-procedure)にあり、同じ基準と確認項目を英語でも記載しています。各サイクルをマーカーの間で切り出して判定し、どのサイクルでも1項目でも満たさなければ、その構成は不合格です。`third-party-mic`のサイクルだけは報告のみとします。

用語は次のとおりです。

- アプリの行は、`processID`が直近の`app-pid`マーカーの記録したインストール済みアプリのPIDである行です。coreaudiodのIOコンテキストは、取得したいずれかの行がそのコンテキストID（`IOWorkLoopInit`が先頭に出力します）をアプリに結び付ける場合に、アプリのものとします。coreaudiodの`BluetoothHALPlugIn_register`、`BluetoothHALPlugIn_StartIO`、`BluetoothHALPlugIn_StopIO`の行が、そのIDを`clientID=`として、アプリのPIDを`PID=`として持つ場合。アプリ自身のプロセスの行（`processID`がアプリのPIDである行。同じ名前のcoreaudiodの行は数えません）がそのIDを含む場合（`HALC_IOContext_PauseIO(<コンテキスト>)`、`HALC_IOContext_ResumeIO(<コンテキスト>)`、`id:<コンテキスト>`を持つ`HALC_ProxyIOContext::PauseIO`と`ResumeIO`の行）。基準9でその`IOWorkLoopInit`がアプリの開始行と対応付けられた場合。その`IOWorkLoopInit`がアプリのPID（`CADefaultDeviceAggregate-<pid>`など）かアプリの`aggregate-uid=`のUIDを含む場合。最初の2つは、フレームワークがアプリのプロセスの中で自分で始めたIO、つまりアプリの`start`の行を伴わないIOを示します。Bluetoothの入力や出力でのコンテキストのうち、取得したどの行もPIDに結び付けないものは、アプリのものとして数えます
- 要求は、coreaudiodの1つのスレッドIDが順に書く`HandlePlugIn_RequestConfigChange`の行です。`--->`、`--- calling driver`、`--- driver returned`、IOを再開する場合の`--- restarting IO`、`<---`の順です。行の順序ではなく、必ずスレッドIDで対応付けます。別々のスレッドの要求は入り交じり、`<---`の行はどの順序でも返るためです。基準4、6、7は、要求をそのスレッドの上で計ります。`<---`より前に同じスレッドが別の`--->`を書いた`--->`と、サイクルの終わりのマーカーまでに`<---`のない`--->`は、不合格です。要求のバーストの`PauseIO`の行と、再開の処理の`ResumeIO`の行は別のスレッドが書くため、時刻で要求に結び付けます。バーストはその`--->`から`calling driver`までの間にあり、再開の処理はその`restarting IO`に続きます。2つの要求の区間に入るバーストは、その両方のものとします
- Bluetoothの要求は、Bluetooth機器に対する要求です。要求の行そのものではcoreaudiodがデバイスを伏せるため、そのスレッドの上の、または`--->`の直前直後の`BluetoothHALPlugIn_`と`HFPInputShimDevice`の行から帰属を決めます。`Requesting config change`と`Starting config change`の行はMac自身のデバイスを示します。Bluetooth機器が変化している最中に帰属を決められない要求は、Bluetoothの要求として数えます。要求の区間は、`--->`から`<---`まで、およびその`restarting IO`が始める再開の処理の`ResumeIO`の行までです
- Bluetoothのバーストは、Bluetoothの要求の`PauseAllContexts`が書く一続きの`PauseIO`の行です
- アプリの呼び出しの区間は、begin行から結果の行までです。結果の行のないbegin行は、そのサイクルの終わりまで進行中とみなします
- スリープをまたぐ要求は、`--->`がcoreaudiodの`Received power notification: Sleep`の行より前にあるか、その行の後1秒以内で復帰の起点より前にあり、`<---`が復帰の起点より後にある要求です。スリープそのものがMac自身のデバイスに対して出す要求は、その行の数ミリ秒から数百ミリ秒後に始まり、すぐに`calling driver`へ達し、復帰の後にだけ返ります。復帰の起点は、そのSleepの行の後の最初の`NewState: DarkWakeEntitledIO`か`NewState: FullWake`の行です。coreaudiodはそこでIOの再開を始め、その復帰で最初の`HALC_IOContext_ResumeIO`の行が続きます。`Early Wake: Yes`を持つ`Received power notification: DarkWake`の行はそれより数百ミリ秒早いため起点にせず、ダークウェイクを経る復帰では`FullWake`の通知は要求が返った後に来ます。ダークウェイクを経ずに`Sleeping`から完全な復帰へ直接戻る場合は、`NewState:`の行が要求の返った後にしか来ないため、`Received power notification: FullWake`の行を起点にします。完全な復帰に至らない復帰のように、要求の`<---`より前にMacが`NewState: Sleeping`へ戻った場合は、その最後の行の後の起点を使います。基準4、6、7は、そうした要求をその起点から計ります。スリープの前に達していない`calling driver`はそこから2秒以内、`<---`はそこから、またはその後の`calling driver`から、遅いほうを起点に150 ms以内、バーストがアプリのIOコンテキストを一時停止する場合はそこから`calling driver`まで50 ms以内です。サイクルの終わりのマーカーまでに`<---`に達しない要求は不合格です。ほかの基準は、基準2と3を含め、その要求と区間をすべて判定します

基準は次のとおりです。

1. アプリがBluetoothの入力や出力でIOを行っていない。アプリのIOコンテキストでのBluetoothの入力や出力への`IOWorkLoopInit`が、アプリの`start`の行を伴うかどうかによらず、ない。アプリのPIDを持つ`BluetoothHALPlugIn_StartIO`も、アプリのPIDを持ち同じ`clientID=`に`IOWorkLoopInit`か`BluetoothHALPlugIn_StartIO`を伴う`BluetoothHALPlugIn_register`も、アプリのHFP入力shimの開始もない。ヘッドセットの出現時にはcoreaudiodがCore Audioの全クライアントを一斉に登録するため、登録だけの行は数えない。`CADefaultDeviceAggregate-<アプリのPID>`、アプリのAUHALとAVFAudioの既定デバイス集約の行、ヘッドセットを示すアプリの`VPAUAggregateAudioDevice`、`AUVPAggregate`、`AUVoiceIO`の行がない。Bluetoothの入力や出力でのアプリの`start`、`prepare`、`stop`、`invalidate`の行も、アプリのIOコンテキストの一時停止や再開もない。アプリの行のデバイスは`id=`であり、`transport=`が`unread`であっても同じである。解決できないIDはBluetoothとして数える。Bluetooth機器は接続のたびに新しいIDを得るため、後の`make diagnose`では解決しない。唯一の例外は記録済みの残余で、既定出力がBluetoothである間のシステム再生メーターのTapと非公開の集約デバイスであり、`clientID=`がその`system-output-ioproc`のコンテキストであるプラグインの行を含む。それらの呼び出しも、ほかのすべての基準で判定する
2. Bluetoothのバーストが始まった時点で、アプリの呼び出しが進行中でない。アプリの`start`、`prepare`、`stop`、`destroy`の区間がBluetoothのバーストの最初の`PauseIO`を含まず、どの操作のアプリのbegin行も、Bluetoothの要求の`--->`から`<---`までの間に入っていない
3. Bluetoothの要求をまたいで、アプリの停止や破棄が進行中でない。アプリの`stop`と`destroy`の区間が、`reason=`の種類を問わず、`quit`と`bluetooth-sub-device`も含めて、Bluetoothの要求の区間と重ならない
4. `PauseAllContexts: still waiting`が0件で、すべての`RequestConfigChange`が2秒以内に`calling driver`へ達する。スリープをまたぐ要求は復帰の起点から計る
5. アプリの`StartAndWaitForState`がエラーを返していない。コードは問わず、例外はドライバが`!obj`を返したデバイスだけの要求の直後の`nope`だけとする。35はすべての構成でエラーに数える
6. アプリに帰属する要求の停滞がない。要求の`--->`から`<---`までが150 ms以下である。スリープをまたぐ要求は復帰の起点から計る。他のアプリに帰属する停滞と、スリープそのものがMac自身のデバイスに出す要求（Sleepの通知の直後に始まり、復帰の後に返る）の停滞は、アプリに帰属しないため報告するが、不合格にはしない
7. バーストがアプリのIOコンテキストを一時停止する場合、そのバーストの最後の`PauseIO`から、スリープをまたぐ要求では復帰の起点から、`calling driver`までが50 ms以下である。アプリのIOコンテキストを含まないバーストでの超過は報告するが、不合格にはしない
8. Tapの解除が完了しており、Bluetoothの要求の外にある。アプリの`system-output-tap`、`processed-microphone-tap`、`reclaimed-tap`の`destroy`のすべてに、Tapの`unregister_meta_device`と、同じスレッドで同じIDの1秒以内の`_Deactivate`が対応し、その解除と`_Deactivate`がBluetoothの要求の区間に入っていない。アプリがTapの上に集約デバイスを作るとき、Core AudioはTapのメタデバイスを一時的に登録して解除し、`_Deactivate`は続かない。これは解除ではないためここでは数えず、作成そのものは基準2で判定する
9. アプリの開始行のすべてが、意図した非Bluetoothデバイスでのcoreaudiodの`IOWorkLoopInit`と対応する。意図したデバイスは、メーターと取り込みでは入力、publisherでは結び付けた出力、`system-output-ioproc`と`processed-microphone-probe-ioproc`では行が示す集約デバイス（システム再生メーターでは非公開の集約デバイス、確認用のIOProcでは公開した「Audio Level Bar Microphone」）で、そのUIDは`IOWorkLoopInit`が出力し、行も`aggregate-uid=`として持つ
10. 静穏期間の中で何も行っていない。行の順序ではなく`gen=`で判定する。世代番号Hの`quiet-window hold`か`quiet-window advance`の行の後に、アプリの`create`、`prepare`、`start`、`stop`、`destroy`のbegin行が、Hより小さい`gen=`を持たず、`gen=H`の`quiet-window release`より前に`gen=H`も持たない。メインスレッドの公開も、ほかの呼び出しと同じに判定し、公開だけの数え方も例外も設けない。公開のbegin行はどれも公開を指示した時点の世代番号を持ち、リスナーが世代番号を進めて中断された公開は、`interrupt`の行を残して、解除までそれ以上何も発行しない。作成も開始もせず、停止、破棄、巻き戻しもしない。`quiet-window hold reason=carried`は世代番号を進めないため、その後の行のうち直前の解除の`gen=`を持つbegin行は、その解除が発行した処理であり、基準11で判定する。`gen=-`の行で例外になるのは2種類だけで、`reason=bluetooth-selection`と、最後の`quit-deferred`の行の時刻にその`release-in`を足した時刻より前でない`reason=quit`である。`quit-deferred`の行がない場合、`quiet-window advance`の行か、`reason=carried`以外の`quiet-window hold`の行が、最初の`reason=quit`の行の3.00秒前より後にあれば、`reason=quit`の行を不合格とする。終了は遅らせるべきだったからである。期間が張られている間の`reason=bluetooth-sub-device`の行は不合格とする
11. `quiet-window release mode=stops-only`の後、次の`quiet-window release mode=full`までに、アプリの`create`、`prepare`、`start`のbegin行も、加工済みマイクの公開もない
12. すべての`quiet-window release mode=full`で、`writes-outstanding=0`であり、`snapshot-age=`が0.75以下である。ただし、期間の最初の保留から解除の1秒後までの間に`hal-poll slow`か`hal-poll recovered`の行がある解除は、定期更新が遅れていたものとして、値が大きくても不合格にせず、その値と行を記録する
13. どのオブジェクトの`stall`の行もなく、`make diagnose`が応答している間に、メニューバーとパネルがCore Audioの開始や停止が終わっていない旨を表示しない
14. すべての終了で、`quit-deferred`の行は、書かれた場合はどれもどの`reason=quit`の行よりも前にあり、最後の行の時刻とその`release-in`の和が、最初の行の時刻に3.00を足した時刻より後でない。`quit lifecycle-stops completed=true pending= waited=`の値が1未満で、プロセスが終了し、その後の`make diagnose`がアプリの公開デバイスとTapを列挙しない。例外は、QuickTime Playerが録音を続けている間の`relaunch-recording`だけとする
15. 各ブロックの後で`make diagnose`がCore Audioの応答を報告する

挙動もログとあわせて判定します。ヘッドセットが既定入力になってから1回の定期更新以内にメニューバーが`--`を表示すること、ヘッドセットが離れると静穏期間の後に元のマイクでメーターが再開すること、システム再生メーターが再開すること、加工済みマイクがBluetoothの拒否を表示し、公開を保ち、ヘッドセットが離れると再試行なしに自動で開始または再開することです。

次の項目は、合格とする前に原因を確かめます。いずれも健全な機器では想定しておらず、現れたら原因を理解する必要があります。

- `give-up`の行。マイクメーターの`microphone-ioproc give-up`と、公開の`processed-microphone-aggregate give-up`を含む
- `reason=failed-start`の停止
- 期間の外の`bluetooth-sub-device`の行。開いている集約デバイスの編集でしか至らず、ゲートではその編集を行わない
- アプリの`com.apple.coreaudio.avfaudio`、`AVAudioEngine`、`AUHAL`、`CADefaultDeviceAggregate-<アプリのPID>`の行と、キャプチャか`~/Library/Logs/DiagnosticReports`の中の`required condition is false`。Apple音声処理を有効にしていなければ、アプリは`AVAudioEngine`を作らない

次の項目は実機で確認し、確認できなければ未確認として記録します。

- 再開の処理。要求の`restarting IO`にどの`ResumeIO`の行がどのスレッドで続き、どの行が処理の終わりか。要求の`BluetoothHALPlugIn_`と`HFPInputShimDevice`の行が、その要求のスレッドに書かれること。要求の`--->`、`calling driver`、`driver returned`、`<---`の行が1つのスレッドIDを共有すること（用語はこれを前提にしている）。`HALC_IOContext_PauseIO(<コンテキスト>)`と`HALC_IOContext_ResumeIO(<コンテキスト>)`の行を書くのがcoreaudiodか、クライアントか、その両方か。コンテキストをクライアントに結び付けるのは、そのクライアント自身の行だけである。coreaudiodは`HALC_IOContext_ResumeIO(<コンテキスト>)`と`HandlePlugIn_RequestConfigChange: ... --- restarting IO`の行を書くと想定している。最初のサイクルで確かめる
- `IOWorkLoopInit`がTapのUIDを`tap-uid=`と同じ形で出力するか。アプリは`CATapDescription`のUUIDを大文字で記録する。集約デバイスのUIDは出力される
- `preflight`で、内蔵出力のpublisherのIOProcを、消音のProcess Tapが2つの処理方式のいずれでも捕捉し、入力と出力のレートが違っても録音に聞こえる途切れがないこと
- `aggregate`で、ケースに入ったヘッドセットのメンバーが`?`に解決されることと、Audio MIDI設定で作った集約デバイスの全サブデバイスの一覧を読めること。定期更新は行を書かないため、確認できるのは、ライフサイクルキューの`refuse`か`open-unverified`の行が分類を示した場合だけである
- `settings`で、同じ切り替えについて、`quiet-window advance source=hal-notification`と`quiet-window hold reason=hal-notification`が定期更新の`default-input`の保留より前にあり、その保留の後に作成の中断を示す`interrupt`の行がないこと。通知は差を縮めるもので、Bluetoothの変化が始まる前に届くかは分かっていない
- アプリ自身の作成と開始の前後で、HALが値の変わらない既定デバイスの通知を送るか。デバイスの変化がないのに、アプリの作成や開始の直後に現れる`quiet-window advance source=hal-notification`として見える。公開の最中に届いた通知は公開を中断し、中断された公開が3回続くと`processed-microphone-aggregate give-up`で終わる。ブロックごとにその件数を、公開の`interrupt`の行、`generation-advanced`と`poll-slow`の保留、`hal-poll slow`と`hal-poll recovered`の行、`poll-in-flight=true`の全面的な解除の件数とともに記録する
- ②で、デバイスの変化のない`system-output-ioproc start`の直後に`output-invalidated`の保留がなく、再構築が繰り返されず、音の再生中に`output-stale`の保留がないこと。`sleep`では、`power will-sleep`から`power did-wake`までに`output-stale`の保留も、システム再生メーターの作成と開始も、`give-up`もなく、`power did-wake`の後に`quiet-window hold reason=wake`と、解除の後の`system-output-tap create`がちょうど1回あること（build 57はここで不合格になった。スリープ中の`output-stale`のたびに作り直し、復帰より前に`give-up`へ至った）。復帰後の操作は、経過時間ではなくアプリの`power did-wake`の行を待ってから行う。ヘッドセットのサイクルで、`system-output-tap interrupt`とそれに続く`quiet-window hold reason=output-moved`が現れるか
- `third-party-mic`で、ヘッドセットのプロファイルの切り替えが`system-output-aggregate invalidate`と`output-invalidated`の保留を複数回起こすか、再構築が最後の通知の3秒後まで待つか
- `quit-in-hold`で、AppKitが終了を待つ間に遅延の後の後始末が走ること（期限で遅延を設定し直した場合を含む）、2回目の終了の指示が遅延を取り消さず、後始末を2回行わないこと
- 変化が続く中で停止だけの解除が起きた場合、変化のない3秒までメニューバーが`--`か開始待ちを表示し、監視や加工済みマイクのオフは15秒以内に反映されること
- `give-up`が現れた場合、失敗の文言と再試行ボタンの見え方。システム再生メーターのものでは、やめたメーターのTap、集約デバイス、IOProcを残しても無害であること。マイクメーターのものでは、やめたメーターは何も開いたままにしないので、メニューバーが`--`を表示すること、再試行ボタンがパネルのマイクのエラーの横にあること、入力が同じままなら再試行まで`microphone-ioproc`の行が現れず、再試行の後も期間の中には現れないこと。公開のものでは、3回の公開をそれぞれどの`quiet-window advance`か`hold`の行が中断したかと、その後の`make diagnose`がアプリの公開デバイスとTapを列挙しないこと
- 集約デバイスの拒否と失敗で表示される文言が、アプリの言語で表示されること
- `meter-refused`の保留が現れた場合、メーターの次の開始がすぐではなく、期間と間隔の後であること。`processed-microphone-capture-ioproc refuse`に続く`processing-refused`の保留の後の、取り込みの次の`create-begin`についても同じ

このゲートでは確かめず、未確認として報告するものは、coreaudiodの再起動からの回復（ゲートでは再起動しません）、内蔵以外の出力に結び付けたpublisher（その出力にBluetooth機器が加わったときの拒否を含みます）、`completed=false`での終了が何かを残すか（`make diagnose`は他のプロセスの非公開のオブジェクトを列挙できません）、他のアプリがヘッドセットのマイクを開く場合のように静穏期間が見ることのできないBluetoothの要求の始まりに終了を指示し、その停止と破棄が要求と重なる場合、アプリの非公開の集約デバイスの作成と破棄がアプリへデバイス一覧の通知を送るか（どの行にも残りません）、実際にtransportを読めなかった場合の`meter-refused`の保留と、その場合の取り込みのやり直し（ゲートでは起こせません）、自動のやり直しの打ち切りとその再試行（マイクメーター、取り込み、公開、publisherの出力、システム再生メーター。健全な機器では起きません）、期間が張られた後に失敗したpublisherの開始、呼び出しの間で中断された公開（いずれもゲートでは時機を合わせられません。最後のものは`launch`で現れることがあります）、隠し設定でだけ使えるApple音声処理のすべて（エンジン、結び付け、既定の書き込みの前の停止`reason=bluetooth-selection`、動作中の選択の不受理`picker refuse`）です。

実機ゲートは長時間稼働状態（起動から4時間以上）だけで行い、再起動直後のブロックは設けません。使うBluetoothヘッドセット以外のBluetoothオーディオ機器は切断しておきます。構成は、①メーターのみ、②システム再生レベル監視オン、③a加工済みマイクの公開中（待機）、③b-off QuickTime Playerが「Audio Level Bar Microphone」で録音中（処理方式オフ）、の4つで、③aと③bはシステム再生レベル監視をオンにして行います。各構成で、ヘッドセットの出し入れ10サイクル（ポップアップ表示中5、全パネルを閉じて5。それぞれ1、3、5回目のサイクルで音を再生）、既定入力のヘッドセットへの切り替えと戻し2回（アプリのピッカー1、システム設定1。20秒使い、戻してから15秒以上待つ。システム設定はそのサイクルが終わったら終了し、ほかのブロックでヘッドセットを出し入れする間は起動しておかない）、2分以上のスリープ復帰2回（ヘッドセットを装着したまま1、スリープ中にケースへ収納1）を行い、最後にアプリの終了項目で終了します。次の場面は、それぞれ最も合う構成で1回だけ行います。①ではログの形の確認と、内蔵マイクとヘッドセットのマイクから作った集約デバイスを既定入力にした拒否（Audio MIDI設定で作ります。システム設定の入力タブのレベルメーターは選択中の入力を開くため、集約デバイスを既定入力に選んだらシステム設定を終了し、各サイクルの前にもヘッドセットをケースに入れたまま使用中でないことを確かめ、使用中でないことを確かめてから削除します）、②ではピッカーでのコントロールの書き込み、静穏期間中の終了、復帰後の再生、③aではヘッドセットが接続する最中の起動、③b-offでは内蔵機器での2つの処理方式の事前確認、他のアプリによるヘッドセットのマイクの使用（報告のみ）、公開デバイスを開く最中の出力の遷移、WebRTCでの加工済みマイクのオフと、最後に録音を続けたままの終了と再起動を行います。Apple音声処理は隠し設定でだけ使えるため構成に含めず、ゲートの間は隠し設定を設定しません。ブロックごとにログをライブで取り、各サイクルの開始と終了にマーカーを記録します。ライブのログはアプリの行の一部を落とすため（build 57のゲートでは4〜15%）、ブロックの後にアプリのサブシステムとマーカーを永続ログから保存し、アプリの行はそれで判定します。所要時間は、ログの判定と休憩を除いて約2.2時間です。coreaudiodが応答しなくなった場合は、アプリを強制終了せず、集約デバイスも削除せず、ログの取得を続けたまま`hang`のマーカーを記録し、`sudo spindump coreaudiod`と`sudo sysdiagnose`を取得してから再起動します。

構成とブロックごとのサイクル数、接続できず試せなかった機器、各結果がソース、候補、インストール済みアプリ、実機検証のどれによるものかを報告します。生存回数も報告しますが、合否の基準にはしません。このゲートを通過するまで、publicへの変更と`v0.4.0`タグの作成は行いません。

## 加工済みマイクを実験的機能として公開する判断

加工済みマイクは「実験的（experimental）」と明記したうえで0.4.0に含めます。UIのトグルは「加工済みマイクを使用（実験的）」、READMEでは独立した節に警告付きで記載します。それ以外の機能――メニューバーのメーター、デバイス選択、音量と入力ゲイン、ミュート、システム再生レベル監視――は通常機能として公開します。ただし、1つのデバイスに結び付けたHAL IOProcによる現在のマイクメーターと加工済みマイクの取り込みは、まだ実機で動かしておらず、実機ゲートの通過を公開の条件とします。

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
- Release assets: Developer ID署名＋notarizeしたDMG（`Audio Level Bar-<version>.dmg`）とそのSHA-256（v0.4.0以降、実機ゲート通過後）
- Binary distribution: Developer ID署名＋notarizeしたDMGをGitHub Releaseのassetとして配布する（v0.4.0以降、実機ゲート通過後）。`make release`で作り、検査項目は[docs/development.md](docs/development.md#release-builds)に従う
- Update mechanism: 当初は手動。ネットワークアクセスを伴う自動更新は別の設計変更として扱う
- Private vulnerability reporting: public化の直後に有効化する。`SECURITY.md`／`SECURITY.ja.md`が指定する報告経路がこれで、有効化するまで報告先が存在しない

## 公開後の作業

- 実機ゲート（機器の抜き差し、Bluetoothヘッドセット、スリープ復帰）を[docs/development.md](docs/development.md#hardware-gate-procedure)の手順と「次のゲートのログ合否基準」で実施し、結果を記録する。通過した候補に`v0.4.0`タグを作成し、`make release`で作ったDMGとSHA-256をReleaseへ添付する。ゲートを通過したcommitが`make release`より前のものなら、アプリのソースに差分がないことを[docs/development.md](docs/development.md#release-builds)の手順で確かめた後のcommitから配布物を作る。不合格なら修正し、修正したbuildで再実施する
- `PublicProcessedMicrophoneDevice`を専用の直列ライフサイクルキューへ移し、セッションIDで古い結果を捨てる形にする。使用中リスナーは無効化だけの通知にして値をHALワーカーで読み、`AudioState`の`refreshDevices()`と`deviceUID`もワーカーへ移す。起動時の`refreshControls()`と孤立Process Tapの回収も、他の資源を作る前という順序を保ってワーカーへ移す。現在はこれらがメインスレッドで同期的にHALを呼ぶため、応答しないcoreaudiodがUIを止め、利用者を強制終了へ向かわせ得る（[DESIGN.md](DESIGN.md#メインスレッドに残る同期的なhal処理)）
- Apple音声処理の`AVAudioEngine`の準備、開始、停止を、Apple音声処理の開始の直前と直後にキャッシュを使わずに行う既定デバイスのIDの読み取りも含めて、メインスレッドから専用の直列キューへ移す。エンジンの生成から破棄までを1つのキューに閉じ、「publicへ変更するゲート」の節に記録した`-[AVAudioEngine dealloc]`とAVFAudioのリスナーの競合を再び招かないことを確かめる。現在は、終了時に止めたエンジンをプロセスの終了まで、それ以外で止めたエンジンを開始を認める次の評価まで解放しないことでこの競合を避けており、キューへ移してもこの規則を保つ。終了時のApple音声処理の停止と公開デバイスの破棄も、上限付きの停止待ちに含める。現在は応答しないcoreaudiodで、これらの呼び出しがUIと終了を止め得る。終了の指示から終了までの最悪の時間にも、終了の遅延と停止待ちの間にある、上限のないこれらの手順が含まれる（[DESIGN.md](DESIGN.md#メインスレッドに残る同期的なhal処理)）
- Apple音声処理は、2026-10-24のユーザーの判断で隠し設定の実験機能にした。HAL IOProcのpublisherで実機ゲートを通した後に、隠し設定を有効にしてヘッドセットの出し入れを別途確かめ、アプリのプロセスにBluetoothのIOも`CADefaultDeviceAggregate-<アプリのPID>`も出ないなら通常の選択肢へ戻すかを判断し、戻さないなら機能を削除する。定期更新を契機にその場で止める方法は、構成変更の最中にIOを止めることになるため避ける
- 既定出力が集約デバイスのとき、システム再生レベル監視のTapと非公開の集約デバイスを作るかの判断にも、その全サブデバイスの構成を使うかを決める。現在はマイク側の判断だけが、有効でないメンバーと解決できないメンバーを含めて判定する
- 自動のやり直しをやめた後の状態を見直す。加工済みマイクが出力のやり直しをやめた後も、開始していない取り込みのIOProcが残ってマイクメーターが受け渡されたままになる点と、処理方式を変えてもやり直しの回数が戻らない点である。やり直しの上限と間隔、およびHALが値の変わらない既定デバイスの通知を送る場合の抑制は、実機ゲートの結果に応じて見直す
- ログイン時起動を`SMAppService`によるログイン項目へ移す。現在、配布物から導入した利用者はシステム設定のログイン項目へ手動で追加し、`make install-login-agent`は同じバージョンとbuildのcloneを前提とする（[README.ja.md](README.ja.md#配布物からの導入)）
- 静穏期間中の終了で、終了の指示の時点で世代番号を進め、指示の直前に発行した停止を遅延中に走らせずに後始末へ任せるかを決める
- アプリターゲットの配線のうち、他の防御に隠れて、それだけを戻しても失敗するテストがないもの（評価の手順ごとの停止だけの許可の結び付け、終了時にレベルのゲートを先に閉じる順序、ピッカーの書き込みの完了時の再保留、いくつかの見張りの条件、公開の中断が3回続いた後に公開の手順が4回目を発行しないことなど）を、偽物のHALで観測できるようにして固定する
- Apple音声処理の有効化（`setVoiceProcessingEnabled`）と、準備だけ済んで開始していないエンジンの停止にも前後の行を付け、フレームワークの中で起きるIOProcの作成と破棄を、ゲートがアプリの行に対応付けられるようにする
- 1回の評価の途中で静穏期間の判定を読み直すと、評価が見た世代番号もその時点の値へ更新される。評価の冒頭で一度だけ控えた世代番号を、その評価が発行するすべての開始と停止に渡す形へ改める
- 取り込みのIOProcの作成など、準備の段階の失敗が期間の張られた後に起きた場合も、処理方式をオフにする失敗として報告される。publisherの作成の失敗と同じく、報告せずに期間後のやり直しへ回す
- 処理方式オフとWebRTCの取り込みは、入力のサンプルレートをレートのリスナーを置く前に読み、`AudioDeviceStart`の直前には読み直さない。その間にレートが変わると、次の再起動まで誤ったレートで処理する。リスナーを先に置くか、開始の直前に読み直す
- アプリのピッカーが選択を受け付けない場合（Apple音声処理の動作中に変化が進行中かもしれない間と、出力のやり直しをやめた後の、集約デバイス、transportが不明のデバイス、一覧にないデバイス）の見せ方を決める。受け付けなかったことを利用者に示すか、選択を期間の解除後に適用するかである
- Apple音声処理の開始の直前の読み取りが集約デバイスのメンバーを解決できなかった場合の扱いを、取り込みと同じ上限つきの再試行に揃えるかを決める。あわせて、構成が空の集約デバイスを拒否するときの文言を実態に合わせる
- マイクメーターが再試行を打ち切った状態と、取り込みの呼び出しの停滞の表示が重なった後、停滞が解けるとエラーの表示と再試行ボタンがともに消える場合がある。打ち切りの表示を、停滞の表示とは独立に保持する
