# 漫画キッチン（MangaKitchen）

[繁體中文](README.zh-TW.md) | [English](README.md) | 日本語 | [한국어](README.ko.md)

漫画キッチン（MangaKitchen）は、macOSネイティブの漫画翻訳ワークスペースです。フロントエンドはHTML + JavaScript、Swift Packageのバックエンドはドメインコア、Metal/Core ML Runtime、WKWebView Appの3層に分かれています。コアは特定のUIレイアウトに依存せず、モデル境界、ページ単位のワークフロー、台詞領域、マスク、組版を扱います。

<p align="center">
  <img src="AppPic/screen01.jpg" alt="MangaKitchen アプリケーション画面" width="800">
</p>

[最新の公証済み DMG をダウンロード](https://github.com/VaderChen/MangaKitchen/releases/latest) · macOS 14以降が必要です

## 著作権と適法な利用

MangaKitchenに読み込まれる漫画原稿、キャラクター、文章、作画、商標その他のコンテンツに関する著作権および関連する権利は、原作者、出版社、正規配信プラットフォーム、その他それぞれの正当な権利者に帰属します。本ツールを使用してもこれらの権利は移転せず、作品の複製、翻訳、公衆送信、配布、販売の許諾が与えられるものではありません。

MangaKitchenは、正式な許諾を得た翻訳者、ローカライズチーム、その他の適法な利用者が、ページ、マスク、訳文、用語、組版を効率的に管理し、反復作業を減らすことで、より速く高品質な正規翻訳を読者へ届けるための支援ツールです。翻訳成果は二次的著作物に該当する場合があります。原稿や翻訳成果を公開、共有、配布する前に必要な許諾を取得し、適用法令、コンテンツのライセンス、および使用するモデルやAIサービスの規約を遵守してください。

海賊版、無許諾の翻訳・スキャンレーション、クラックされたコンテンツの作成や配布、DRM、透かし、その他の権利保護措置の回避にMangaKitchenを使用しないでください。開発者は著作権侵害を推奨または支援しません。正規の単行本、電子書籍、サブスクリプション、ライセンス商品を正規の販売経路から購入し、作者、翻訳者、出版社、そして創作文化全体を支援してください。

## ソフトウェアライセンス

MangaKitchenはデュアルライセンス方式を採用します。本repository内でMangaKitchenの著作権者が権利を持ち、別途表示のないコードは、標準で[GNU General Public License version 3 only](LICENSE)（`GPL-3.0-only`）の下で提供されます。クローズドソース製品への統合、プロプライエタリな配布、または異なる契約条件が必要な場合は、別途[商用ライセンス](COMMERCIAL-LICENSE.md)を利用できます。

GPLv3自体も商用利用と有償配布を認めていますが、ソースコード提供およびcopyleftの義務を守る必要があります。商用ライセンスは代替案であり、GPLv3で既に得た権利を制限しません。第三者package、モデルとweight、フォント、漫画コンテンツはMangaKitchenのデュアルライセンス対象外で、それぞれの条件に従います。

## 実装済み機能

- macOS 14以降に対応するSwiftUI / WKWebViewアプリケーションシェル。
- HTML/JavaScriptとSwift間の非同期JSON Bridge。
- `AUTO`、繁体字中国語、英語、日本語、韓国語のWeb UI。AUTOはmacOSの言語に従い、手動設定は次回起動後も保持され、ネイティブパネルとMCPメニューバーにも反映されます。
- 一般、詳細、モデル、MCP、情報の各タブを持つグローバル設定DLG。言語、配色、CPU／GPU画像合成、データ保存先、マルチモーダル／文字位置検出／OCR／カラー化／超解像モデル、MCPポート、IP/CIDR許可リストを設定できます。
- ソースフォルダごとに独立したプロジェクトを作成し、複数プロジェクトを保存・切り替えできます。
- サブフォルダの相対パスを保持する再帰スキャン、自然順ソート、同名ファイルの衝突回避。
- Command／Shiftによる複数選択、検索、状態フィルタ、選択ページのマスク・翻訳・合成の一括処理。
- 単一の逐次バッチキュー、現在ページ、成功／失敗数、キャンセル、履歴消去、失敗ページの再試行。領域単位の翻訳中は現在の領域／総領域数と実際の進捗も表示します。
- プロジェクトごとの多言語用語集。1つの原語に複数のBCP-47翻訳を保存し、対象言語に応じて自動選択します。
- グローバル設定でキャンバス選択色と既定の出力ルートを保存できます。新規プロジェクトはその配下に安全化したプロジェクト名のフォルダを作成し、既存プロジェクトの明示的な出力先は置き換えません。
- 翻訳は4段階で、ページ、文字／マスクと文字消去済み背景、翻訳／組版プレビュー、出力保存を分離します。カラー化は別の4段階と独立状態を使用します。
- 各段階が管理する成果物を分離し、後の段階が前の段階を暗黙に再実行しない再開可能なワークフローを提供します。
- 画像ごとのバージョン付き`.str` JSONに、文字、位置、フォント、固定／自動サイズ、マスクストロークを保存。
- 原画像のピクセル層で膨張してアンチエイリアスの縁を取り込み、正規化ブラシでマスクを追加・消去・領域単位に取り消して二値PNGを生成します。各run矩形をベクター描画する方式は廃止し、灰色の毛羽立ちを防ぎます。ステップ2の完了後、画像編集モデルを起動せず、原文を消去したCPU／GPUマスク確認プレビューを直ちに表示します。
- 同梱の manga109 吹き出し分割 Core ML モデルが、Apple Neural Engine を優先して白黒漫画の対話 BBOX と吹き出し形状を生成します。ステップ2は常にその吹き出しを原画像ピクセルから文字マスクへ精修し、OCR／VLM の選択でこのマスク処理は変化しません。Apple Vision OCR は使用しません。効果音、ページ番号、フッター情報、人物、空白領域は主処理から除外します。
- ステップ2は PP-OCR 文字検出も `imageToText` VLM も必要としません。Medium Det と VLM の位置検出 runtime はマスク生成から分離され、モデル切り替えによる既存の吹き出し／ピクセルマスクの退行を防ぎます。ステップ3では PP-OCRv6 Medium recognizer を標準で使用し、Small を fallback として保持します。`sourceText` が空の場合は既定 OCR 結果を翻訳原文に採用しますが、確認済み原文、座標、マスクは上書きしません。
- GUI翻訳はダウンロード済みのマルチモーダルモデルに固定され、ページ全体の画像文脈を利用します。原文抽出はPP-OCRの領域単位認識またはVLM転記を選択でき、旧プロジェクトのテキスト生成設定は`imageToText`へ移行されます。
- 受理された領域は対話 BBOX を検索範囲として原画像の連結成分からピクセル文字マスクへ精修し、文字領域を膨張前の実際のglyph外接矩形へ縮小します。自動組版の方向は実際の字形排列を優先します。各候補は独立して処理し、1領域の分類・転記・翻訳に失敗してもその領域を保持して他の領域を続行します。キャンセル時だけ全体を停止します。
- 画像テキスト化モデル向けのページ文脈プロンプトと厳格なJSON応答解析。
- Apple Silicon／Metal上で`mlx-swift-lm`を使用するローカルHugging Face MLX VLMの読み込み。
- model manifestによる`.mlmodelc`、`.mlmodel`、`.mlpackage`の読み込みと、Metal GPUを指定したCore ML実行。
- 反吹き出しマスクとダウンロード式DDColor Tiny Core MLを使う独立した4段階カラー化フロー。翻訳済み出力があれば優先し、なければ原稿へフォールバックします。カラー化の状態、プレビュー、出力は翻訳フローと分離されます。DDColor Tinyが利用しない色数範囲とカラー化モードのカードは現在無効です。
- 台詞マスクは1つ以上のピクセル形状で元文字を覆い、吹き出し境界でクリップした上でブラシによる追加・消去を重ねられます。画像モデルがない場合はCPUまたはMetal GPU修復を選択できます。
- HTML/CSSを翻訳組版の唯一の基準とし、横書き／縦書き、固定または自動文字サイズ、ドラッグ、領域サイズ変更に対応します。最終PNGもWebKitが同じ文字レイヤーを描画するため、ステップ3の組版が出力時に別方式へ置き換わりません。
- WebKitは実際のSRピクセルサイズでステップ3のプレビューを描画し、ステップ4はそのプレビューを再構築せず保存します。2×／4×超解像は古い1×出力を無効化して、PNGとPSDがSR前の画像へ戻らないようにします。
- エディターは領域の追加、複製、削除、並べ替えと、ページごとに最大50件のundo／redoに対応します。キャンバスは水平・垂直にパンでき、スクロールズームは表示キャンバスの中心を基準にします。テキストレイヤーは表示、透明度、回転、整列、文字色、縁取り、インストール済みフォントの即時プレビューに対応します。
- PSDは結合プレビュー、文字ごとのRaster Layer、クリーン背景、非表示の原稿をHTML/CSSの描画結果からまとめます。超解像後は利用可能な全レイヤーが同じ拡大後サイズを保ちます。
- 画像、フォルダ、ZIP／CBZ、RAR／CBR、PDFをプロジェクトへ追加・取り込みでき、ページの名前変更、並べ替え、削除にも対応します。取り込んだデータは管理対象フォルダへコピー、展開、またはラスタライズされます。
- 任意のファイルを公開せず、制限付きカスタムURL SchemeでWeb UIに原稿と出力画像を提供。
- プロジェクト索引と状態をバージョン付きJSONとして自動保存。書き込み前に旧版を`.bak`として残し、起動時に検証して復元。
- オプションのmacOS 26 Swift/MLX Qwen Image Edit worker。マスクをモデル条件と最終合成範囲の両方に使用。
- 翻訳／カラー化tools、workspace／画像resources、キャンセル、進捗通知を備えた標準MCP Streamable HTTP server。マルチモーダルAgentはカラー化入力と反吹き出しマスクを一度に受け取り、自身のProviderで処理した結果をAppのプレビューへ書き戻せます。
- MCP有効時はmacOSメニューバーに常駐し、メインウィンドウを閉じた後も再表示できます。
- マルチモーダルモデルは使用時に初めて遅延ロードされ、同じモデル container を再利用します。メモリ負荷が高い場合は、大型モデルをロードする前に他の runtime を解放します。
- **Think Mode (Beta)** は既定でオフです。短い推論を安全な Markdown で表示し、推論を LOG に保存しません。完全な JSON が得られなければ、同じモデルで非思考の最終 JSON を生成します。
- ツールバーからメモリ内 LOG を開いて消去できます。下部ステータスバーの GPU、MEMORY、解像度、倍率は transient 更新され、選択やドラッグ操作を中断しません。
- 起動時に GitHub の最新安定版を確認し、「設定 → 情報」に公式 GitHub／Releases URL と手動の「更新を確認」を表示します。App は公式パスだけを開き、自動ダウンロードやインストールは行いません。
- ローカル翻訳ではページ全体の文脈、二次校正、直訳稿と表示訳の分離、役割・口調、信頼度、deterministic QAを設定できます。MCPは外部Providerとの拡張境界として機能し、Agentが処理結果をアプリへ書き戻します。

## 翻訳の2つの利用方法と独立したカラー化フロー

MangaKitchenの翻訳は、ローカルGUIまたはMCP経由のマルチモーダルAgent校正で実行できます。両者は同じプロジェクトデータと翻訳生成物を共有します。カラー化は別の状態と出力を持つ独立フローです。

2つの翻訳方式に共通する4段階は次のとおりです。

1. **プロジェクトとページ**：ソースフォルダを選択して画像を再帰スキャンし、複数選択・一括処理可能なページ一覧を作成します。
2. **文字、マスク、文字消去済み背景**：内蔵Core ML分割モデルで対話BBOXと吹き出し形状を検出し、原画像ピクセルから文字maskへ精修して背景を修復します。この段階ではVLMを呼び出さず、MCP Agentによる領域やmaskの再構築も許可しません。
3. **翻訳と組版**：GUIは同梱 OCR または選択した VLM で原文を抽出し、マルチモーダルモデルで翻訳、任意の二次校正、意味 QA を実行します。MCPはAppが作成した単一ページの作業パッケージをマルチモーダルAgentへ渡し、結果をAppのプロジェクト状態へ戻します。
4. **出力保存**：確認済みのステップ3プレビューだけを出力先へ保存し、mask、修復、翻訳、超解像、組版を再実行しません。

4段階は再開可能な状態、生成物、依存関係を定義するもので、毎回ステップ1からやり直す固定チェックリストではありません。GUIとMCPはAppが提供するページ状態と作業パッケージを確認し、前提データがある任意の段階から開始できます。マスクがあれば翻訳へ、訳文があれば組版や合成へ直接進めます。明示的に再実行を求めない限り、完了済みの領域認識、マスク、訳文、手動編集を上書きしません。

任意の段階から開始する前に、状態名だけでなくページごとの実データを検証します。前提生成物がなければ、必要な作業が見つかるまで1段階ずつ戻ります。

- ステップ4の前に、有効なマスクと`.str`の訳文／組版データを確認します。訳文がなければステップ3へ、文字領域またはマスクがなければさらにステップ2へ戻ります。
- ステップ3の前に、原稿ページ、文字領域、OCR／VLM／Agent／利用者が提供した原文、マスクを確認します。不完全ならステップ2へ戻ります。
- ステップ2の前に、原稿画像の存在とプロジェクトのページ索引を確認します。失効していればステップ1で再スキャンします。
- 戻る処理は欠損または失効したデータだけを補い、有効な前提生成物は再作成しません。ページごとに異なる段階から再開できます。

### 独立したカラー化4段階

カラー化は、ページ選択と翻訳出力優先の入力決定、反吹き出しmaskの作成・編集、ダウンロード済みDDColor Tinyまたは外部マルチモーダルAgentによるプレビュー、既存プレビューの出力保存の順です。白いmask画素はカラー化を許可し、黒い画素は吹き出しと手動消去領域を保護します。先にAppで対話領域とmaskデータを完成させる必要がありますが、カラー化の進捗、プレビュー、リセット、出力は翻訳状態を上書きしません。

### 方法A：モデルをダウンロードして完全オフラインで実行

「設定 → モデル」でマルチモーダル翻訳モデルを、ローカルカラー化が必要な場合はDDColor Tinyもダウンロードします。領域認識、翻訳、背景修復、合成、ローカルカラー化はMac上で実行されます。

- 翻訳は常に`imageToText`を使用します。PP-OCRの「原文を再抽出」自体はVLM不要ですが、翻訳、二次校正、意味QAにはマルチモーダルモデルが必要です。
- `imageToImage`モデルはステップ2の背景修復を担当するオプションです。未設定時は「設定 → 詳細」でMetal GPU近傍修復またはCPUによる吹き出し主要色修復を選択でき、GPU失敗時はCPUへ自動的に切り替わります。
- GUIでは各段階を個別に実行でき、「選択ページ／全ページを完全処理」も利用できます。一括実行も内部ではステップ2〜4を順番に処理し、中間データを保持します。
- ローカルカラー化はステップ3で`imageColorization`モデルを遅延読み込みして直ちにプレビューを作り、ステップ4はそのプレビューだけを保存します。
- 結果はプロジェクトと`.str`へ戻されるため、任意の段階を修正して後続段階だけを再実行できます。

### 方法B：AI AgentからMCP経由で校正（推奨）

> **推奨フロー：先にAppで翻訳ステップ2を完了し、その後MCPで校正します。** 公開MCPは領域、ピクセルmask、文字消去済み背景を代行しません。AgentはAppの作業パッケージにある原文、訳文、組版だけを校正し、完成済みの領域とmaskを保持します。

「設定 → MCP」でサービスを有効にし、ポートとクライアントIP/CIDR許可リストを設定して、Streamable HTTP対応のAI Agentを接続します。MCPはAgentに4段階を分解・消去・再構築させず、単一ページの作業パッケージだけを提供します。

1. GUIでプロジェクトを開き、対象ページのステップ2（領域、ピクセルmask、文字消去済み背景）まで完了します。
2. 「設定 → MCP」でサービスを有効にし、Streamable HTTP対応のAI Agentを接続します。
3. Agentは`mangakitchen.workspace.open`で`workspace_id`を取得し、対象ページごとに`mangakitchen.page.prepare_agent_task`を呼びます。このtoolは完了済みステップ2だけを梱包し、maskまたは文字消去済み背景がなければ停止してAppでの完了を求めます。
4. Agentは既存領域ごとに処理します。空でない`sourceText`／`translatedText`は原画像と照合して校正する下書きとして扱い、誤りや空白を修正し、HTML組版のサイズ、位置、字重、縦横方向も調整します。領域やmaskを追加・削除・結合・変更してはいけません。
5. `mangakitchen.page.submit_agent_result`で校正済みの原文、翻訳、組版結果を全領域分まとめて返します。Appはステップ2 maskを保持してステップ3プレビューを作成し、利用者が出力を要求した場合だけ`mangakitchen.page.render`を呼びます。

Appで反吹き出しmaskを完成した後はカラー化もAgentへ委任できます。`mangakitchen.page.prepare_colorization_task`で実際の入力画像とmaskを取得し、`mangakitchen.page.submit_colorization_result`で全ページ結果を書き戻します。Appは復号後20 MiB上限、完全一致する画素サイズ、PNG正規化、保護mask再適用を検証し、出力要求時だけ`mangakitchen.page.render_colorization`を呼びます。

`region_source`と旧来の領域単位toolは互換性のために残りますが、既定のMCPフローではありません。MCPのステップ3は完全にAgentが担当し、App内蔵VLMによる転記・翻訳は実行しません。Agentは`.str`を検索・読取・作成してはならず、複数resourceの読取や`region.update`も必要としません。

既存プロジェクトでAgentが完了済み段階を独自に消去、再スキャン、再実行してはいけません。利用者が指定したページだけ作業パッケージを準備します。`workspace.pages`は状態照会であり、自動ループ開始の命令ではありません。

MCPモードも複数workspace、明示的な`workspace_id`、複数ページの一括処理、プロジェクト用語集、キャンセル、進捗通知に対応します。AI Agentはワークフローの操作者であり、別の保存バックエンドではありません。

## 実行

```bash
swift build
swift run MangaKitchen
```

GUIと同時にMCP serverを起動する場合：

```bash
swift run MangaKitchen --mcp=on
```

GUIは常に起動します。`--mcp`を省略すると保存済み設定を使用し、`--mcp=on|off`は今回の起動だけを上書きします。listenerは`0.0.0.0`にbindし、既定ポートは`12080`です。実際の接続元IP/CIDRが許可リストにあるrequestだけを受け付け、初期値は`127.0.0.1`のみです。ローカルMCP URLは`http://127.0.0.1:12080/mcp`で、`--mcp-port=<port>`でも上書きできます。メインウィンドウを閉じてもAppは終了せず、メニューバーから再表示できます。

データ保存先の変更は再起動後に反映されます。`imageToText`、`imageColorization`、`superResolution`モデルの変更は即時反映され、MCPスイッチ、ポート、許可リストの変更時はlistenerが再起動します。

### SwiftPMとMetalのトラブルシューティング

MLXは同梱Metalリソース（`default.metallib`）に依存します。パッケージングスクリプトはアプリ専用の`mlx.metallib`を一度だけビルドし、SwiftPMの`.build`キャッシュ外にある`Artifacts/MLXMetal/<configuration>/`へ保存します。MLX shaderのソースが変わらない限り、`--clean`でも再ビルドしません。`swift test`が`Failed to load the default metallib`で停止した場合、MLXの初期化中に失敗しており、MangaKitchenのGGUF loaderには到達していません。これはMangaKitchenやGGUF kernelのエラーではありません。

SwiftPMの依存関係とビルドキャッシュをクリーンにします。

```bash
swift package clean
swift package resolve
swift test
```

Apple Metalのコマンドラインツールを確認します。

```bash
xcrun --find metal
xcrun --find metallib
```

両方ともApple Metal toolchain内のパスを表示する必要があります。対応環境はApple Silicon、macOS 14以降、完全なXcode Command Line Tools／Metal環境です。コマンドが解決できても`default.metallib`がない場合はCommand Line Toolsを修復または再インストールし、ターミナルを開き直してクリーンビルドをやり直してください。`swift build`の成功はコンパイル成功だけを示し、MLX runtimeテストには実行時のMetalリソースも必要です。

既定のデータ保存先：

```text
~/Library/Application Support/MangaKitchen/
  Projects/library.json
  Projects/<project-uuid>/project.json
  Imported/<import-uuid>/
  Artifacts/<page-uuid>/
```

各`.str`は原画像と同じ場所に保存されます。例えば`ComicTest/001.webp`には`ComicTest/001.str`が対応します。指定した出力フォルダには最終PNGのみを保存します。旧配置の`.str`は原画像の横へコピーし、旧ファイルも保持します。

旧`Workspace/workspace.json`は初回起動時に最初のプロジェクトへ移行され、元ファイルは残ります。

## モデル形式

Core MLと外部Runtimeのモデルフォルダは`mangakitchen-model.json`を使用します。`config.json`、tokenizer、Safetensorsが揃ったHugging Face MLXフォルダはmanifestなしでも推定でき、明示的な表示名や生成設定が必要な場合だけmanifestで上書きできます。例：

- `Examples/Models/ImageToTextModel/mangakitchen-model.json`
- `Examples/Models/ImageToImageModel/mangakitchen-model.json`
- `Examples/Models/MLXVLMModel/mangakitchen-model.json`
- `Examples/Models/QwenImageEditModel/mangakitchen-model.json`

manifestのfeature名はCore MLモデルと一致させます。現在のAdapterは画像テキスト化の画像／任意prompt／文字列出力、および画像変換の画像／任意mask・prompt／画像出力を扱います。

カラー化は汎用画像変換契約ではなく専用`ImageColorizing` Adapterを使用します。ダウンローダーはApache-2.0の[`mlboydaisuke/DDColor-Tiny-CoreML`](https://huggingface.co/mlboydaisuke/DDColor-Tiny-CoreML)を取得し、`DDColor_Tiny.mlpackage`の`image`入力と`ab_channels`出力を持つ`imageColorization` manifestを作成します。

Core ML manifestは1回のpredictionとしてパッケージ済みのモデル向けです。tokenizerと逐次decodeが必要なQwen-VLは専用MLX Adapterを使用し、sampler loopを持つdiffusion modelも専用`ImageToImageGenerating` Adapterが必要です。コアpipelineは変更しません。

Appはテキストのみの翻訳を`MLXTextRuntime`、`mlx-swift-lm`対応のローカルマルチモーダル翻訳を`MLXVLMRuntime`で実行します。テキスト翻訳の推奨モデルは`mlx-community/Qwen3-4B-4bit`で、より大きい`Qwen3-8B-4bit`も選択できます。GPT-OSSも任意で利用できますが、多言語翻訳の品質が安定しないため既定の翻訳モデルではありません。

1. Hugging Faceモデル一式をローカルフォルダへダウンロードします。
2. Appでそのフォルダを選択します。初回読み込み後はcontainerをメモリに保持してページ間で再利用します。
3. 表示名や生成設定を明示的に上書きする場合だけ`Examples/Models/MLXVLMModel/mangakitchen-model.json`を追加します。

単一のsafetensorsだけでは利用できません。`config.json`、tokenizer、chat templateを保持してください。その他のマルチモーダルモデルではprocessor設定も保持してください。`vision_config`を含むQwen3.5チェックポイントで`processor_config.json`と`preprocessor_config.json`がない場合、factoryは`config.json`から互換性のあるQwen3VLProcessor設定を推論します。

### DFlash speculative decoding

翻訳とマルチモーダルモデルの設定では、対応するQwen3／Qwen3.5ターゲットでDFlashを有効にできます。Appは選択したターゲットと同じモデルルートからDraftを自動検出するため、Draftのパスを別途保存しません。ネイティブSwift／MLX実装はターゲットと同じMetal runtimeを使い、Safetensors／MLX checkpointやGGUFの読み込みを置き換えません。Qwen3-VLとQwen3.5-VLは視覚対応prefill後に同じspeculative decoding loopへ入り、その他のVLMは標準生成へ安全にフォールバックします。Draftがない、互換性がない、無効、または未対応の生成設定の場合は理由をログに記録して標準生成へ戻ります。Draftの重みはAppに同梱されません。

### GGUF重み

`MLXTextRuntime`と`MLXVLMRuntime`は`.gguf`重みをSafetensorsへ変換せず、モデルフォルダから直接読み込めます。本番Appは`group64`と`quality` profileを既定とし、GGUF raw blockからMLXの`wq/scales/biases`を生成します。`Q4_0`／`Q4_1`／`Q1_0`／`Q2_0`／`Q2_K`／`Q3_K`／`Q4_K`は`INT4`、`Q8_0`／`Q5_K`／`Q6_K`は`INT8`を目標にします。`speed` profileではQ5_K／Q6_Kを`INT4`へ再量子化してdecodeのメモリ帯域を減らせますが、品質が低下する可能性があります。指定しない場合は`quality`を使用します。GGUFのF32／F16 compute重みはBF16へ変換し、Qwen3.5の`blk.N.ssm_a`（`linear_attn.A_log`）だけはF32のまま保持します。`mmproj`も同じgroup sizeを使用します。列挙されていない型（`Q8_K`を含む）はinspectと読み込み前に未対応として報告されます。llama.cpp bridgeは`Tools/GGUFBackendPOC`のparser比較用にのみ残され、本番Appの依存ではありません。

GGUF loaderは主`.gguf`のmetadataからモデル設定とtokenizerを優先して構築し、外部の`config.json`、`tokenizer.json`、`tokenizer_config.json`はfallbackとして使います。完全なmetadataを含むテキストモデルは`.gguf`だけで構成できます。マルチモーダルモデルには対応する`mmproj-*.gguf`が必要です。processor設定がない場合は`mmproj` metadataから基本設定を作成します。外部tokenizer fallbackには少なくとも`tokenizer.json`が必要で、`tokenizer_config.json`は埋め込みまたは外部のtokenizer dataと組み合わせられます。

`FP8`（`F8_E4M3`／`F8_E5M2`を含む）は`INT8`へ再量子化します。一般のGGUF `F16`／`F32` compute重みは上記規則でBF16へ変換し、`blk.N.ssm_a`だけF32のままです。標準llama.cpp GGUF type tableに独立したFP8 tensor typeはないため、Swift loaderは未知のtypeをFP8として扱いません。`GGUFStoragePolicy.targetStorageType(for:)`は`quality` profileの目標を固定し、`targetStorageType(for:profile:)`でspeed profileを確認できます。

```bash
swift run GGUFSmoke --directory /path/to/Qwen3.8-27B-GGUF \
  --load --benchmark --image /path/to/page.png --prompt "Describe this image." --tokens 128 \
  --gguf-group-size 64 --gguf-profile quality
swift run GGUFSmoke --directory /path/to/Qwen3.8-27B-MLX-4bit \
  --load --benchmark --image /path/to/page.png --prompt "Describe this image." --tokens 128
```

`GGUFSmoke`と`Tools/GGUFBackendPOC`はformat、数値、性能の開発者検証専用です。`--gguf-profile quality|speed`でQ5_K／Q6_KのINT8またはINT4目標を切り替えられます。benchmarkとfixtureの結果はAppから読み込まず、runtimeのモデル選択や品質基準も決定しません。異なる形式を比較する場合は同じハードウェアとパラメータで個別に実行し、その回の測定値として扱ってください。

マルチモーダルGGUFは主モデルだけでは成立しません。モデルフォルダには`config.json`、Hugging Face tokenizer／chat template、対応する`mmproj-*.gguf`視覚投影ファイルを置く必要があります。`mmproj`がない場合、テキストモデルとして偽装して読み込みません。ダウンローダーはrepositoryに指定された`mmproj`があることを確認し、主GGUF、その`mmproj`、必要なQwen基本設定だけを取得します。

`mangakitchen-model.json`で重みファイルを指定できます。

```json
{
  "schemaVersion": 1,
  "id": "local-llama-q4",
  "displayName": "Local Llama Q4",
  "capability": "imageToText",
  "backend": "mlxSwift",
  "weightsFile": "model-q4_0.gguf",
  "weightsFormat": "gguf",
  "mmprojFile": "mmproj-F16.gguf"
}
```

## Qwen Image Edit Worker

画像変換は独立したSwift Packageで実行し、完了またはキャンセル後に大型モデルを解放します。現在macOS 26が必要です。

```bash
Scripts/build-qwen-image-edit-worker.sh
```

開発時の検索先：

```text
RuntimeSupport/QwenImageEditWorker/.build/release/MangaKitchenQwenImageEditWorker
```

正式な`.app`では`Contents/Helpers/`へコピーします。`MANGAKITCHEN_QWEN_WORKER`で絶対パスも指定できます。

```text
QwenImageEditModel/
  mangakitchen-model.json
  snapshot/
    vae/
    text_encoder/
    processor/
    transformer/
  quantized/
    qie-2511-dit-int4-mod8.safetensors
    qie-2511-vl7b-int4.safetensors
```

`snapshot`はQwen Image Edit 2511基礎モデル、2つのINT4ファイルはSwift Runtime用の事前量子化モデルです。Workerへ原稿と二値maskを渡し、生成後はmask内の画素だけを採用します。

## パッケージ構成

```text
MangaKitchenCore       ドメインデータ、座標、処理設定、モデル／ワークフローprotocol
MangaKitchenRuntime    吹き出し検出、OCR／VLM転記、Core ML／MLX翻訳、カラー化、SR、マスク、修復
MangaKitchenApp        SwiftUI、WKWebView、URL Scheme、JSON Bridge、HTML/JavaScript組版とPNG出力
MangaKitchenApp/MCP    GUI process内のMCP Streamable HTTP adapterとライフサイクル
```

設計とデータフローは[Documentation/ARCHITECTURE.md](Documentation/ARCHITECTURE.md)、Swift／JavaScript／MCP契約は[Documentation/WORKFLOW_API.md](Documentation/WORKFLOW_API.md)を参照してください。

## 既知の制限

- 同梱の`manga109-segmentation-bubble`、PP-OCRv6 Medium標準モデル、Small fallback Core MLモデルはApache-2.0の元モデルから生成しています。画像テキスト化、ダウンロード式DDColor Tiny、超解像、実験的画像変換の重みは同梱しません。DDColor TinyもApache-2.0で、変換済みOCR packageとライセンス声明はrepositoryに含まれます。
- 対話BBOXは気泡形状で範囲を制限し、原画像の明度、連結成分、ピクセル膨張で精修します。暗色／カラー作品ではAppでの手動mask修正が必要な場合があります。標準Agent作業パッケージは領域やmaskを変更できず、効果音は意図的に翻訳主処理から外しています。
- Metal近傍修復は代替手段です。複雑な網点や線画をまたぐ文字にはinpainting modelを推奨します。
- Qwen Image Edit INT4は約25GB級の推論メモリとページごとの完全なdiffusionを必要とします。
- App Sandboxのsecurity-scoped bookmark、署名、notarization、正式な`.app` packagingは未実装です。
