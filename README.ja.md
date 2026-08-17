# 漫画キッチン（MangaKitchen）

[繁體中文](README.md) | [English](README.en.md) | 日本語 | [한국어](README.ko.md)

漫画キッチン（MangaKitchen）は、macOSネイティブの漫画翻訳ワークスペースです。フロントエンドはHTML + JavaScript、Swift Packageのバックエンドはドメインコア、Metal/Core ML Runtime、WKWebView Appの3層に分かれています。コアは特定のUIレイアウトに依存せず、モデル境界、ページ単位のワークフロー、台詞領域、マスク、組版を扱います。

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
- 一般、詳細、モデル、MCP、情報の各タブを持つグローバル設定DLG。言語、配色、CPU／GPU画像合成、データ保存先、モデル、MCPポート、IP/CIDR許可リストを設定できます。
- ソースフォルダごとに独立したプロジェクトを作成し、複数プロジェクトを保存・切り替えできます。
- サブフォルダの相対パスを保持する再帰スキャン、自然順ソート、同名ファイルの衝突回避。
- Command／Shiftによる複数選択、検索、状態フィルタ、選択ページのマスク・翻訳・合成の一括処理。
- 単一の逐次バッチキュー、現在ページ、成功／失敗数、キャンセル、履歴消去、失敗ページの再試行。
- プロジェクトごとの多言語用語集。1つの原語に複数のBCP-47翻訳を保存し、対象言語に応じて自動選択します。
- 4段階ワークフロー：スキャン、文字／マスク、翻訳／組版設定、背景修復／合成。ページ全体および全ページの一括実行も利用できます。
- 画像ごとのバージョン付き`.str` JSONに、文字、位置、フォント、固定／自動サイズ、マスクストロークを保存。
- 正規化ベクターブラシによるマスクの追加、消去、領域単位の取り消しと二値PNG生成。ステップ2の完了後、画像編集モデルを起動せず、原文を消去したCPU／GPUマスク確認プレビューを直ちに表示します。
- 白黒漫画では、システムVision OCRと閉じた明領域の検出を独立して実行します。各OCR粗枠は最も適合する閉領域へ割り当て、未割り当ての枠は外枠なし文字として保持します。OCRが何も検出しなかった閉領域もすべて画像テキスト化モデルへ渡し、OCR、VLM出力、閉領域の形状を統合・重複排除します。現在の主処理では効果音、ページ番号、フッター情報、人物、空白領域を意図的に除外します。
- 候補文字は連結成分で文字形状polygonへ精修した後、ページ全体の文脈を保ったbatchでOCRを校正します。原文と校正値を保存し、全領域の結果が揃った場合のみ完了とします。
- 画像テキスト化モデル向けのページ文脈プロンプトと厳格なJSON応答解析。
- Apple Silicon／Metal上で`mlx-swift-lm`を使用するローカルHugging Face MLX VLMの読み込み。
- model manifestによる`.mlmodelc`、`.mlmodel`、`.mlpackage`の読み込みと、Metal GPUを指定したCore ML実行。
- 台詞マスクは1つ以上の多角形で元文字を覆い、吹き出し境界でクリップした上でブラシによる追加・消去を重ねられます。画像モデルがない場合はCPUまたはMetal GPU修復を選択できます。
- Core Textは原文glyphの位置と大きさをanchorにし、横書き／縦書き、overflow時の優先縮小、同一吹き出し内の複数領域を重ならないレーンへ分割、吹き出し内縁でのhard clip、手動編集後の再組版に対応します。
- 任意のファイルを公開せず、制限付きカスタムURL SchemeでWeb UIに原稿と出力画像を提供。
- プロジェクト索引と状態をバージョン付きJSONとして自動保存。書き込み前に旧版を`.bak`として残し、起動時に検証して復元。
- オプションのmacOS 26 Swift/MLX Qwen Image Edit worker。マスクをモデル条件と最終合成範囲の両方に使用。
- 4段階tools、workspace／画像resources、キャンセル、進捗通知を備えた標準MCP Streamable HTTP server。
- MCP有効時はmacOSメニューバーに常駐し、メインウィンドウを閉じた後も再表示できます。

## 2つの利用方法、共通のプロジェクトと4段階ワークフロー

MangaKitchenには2つの利用方法があります。違うのは推論と操作を誰が担当するかだけで、データ形式や処理フローは共通です。すべての作業はソースフォルダのプロジェクトから始まり、ページ、マスク、翻訳、組版設定、用語集、出力状態はそのプロジェクト内に保存されます。

共通する4つの段階は次のとおりです。

1. **プロジェクトとページ**：ソースフォルダを選択して画像を再帰スキャンし、複数選択・一括処理可能なページ一覧を作成します。
2. **文字とマスク**：台詞領域と原文を検出し、粗い矩形を文字形状maskへ精修し、ローカルLLM、Agent、または人がOCRを一度校正してからmaskを編集します。
3. **翻訳と組版**：各領域の原文、訳文、位置、フォント、サイズを画像に対応する`.str`へ保存します。
4. **修復と合成**：元の文字を除去し、背景を修復して訳文を組版し、プロジェクトの出力先へ保存します。

4段階は再開可能な状態、生成物、依存関係を定義するもので、毎回ステップ1からやり直す固定チェックリストではありません。GUIとMCPはページ状態と`.str`を確認し、前提データがある任意の段階から開始できます。マスクがあれば翻訳へ、訳文があれば組版や合成へ直接進めます。明示的に再実行を求めない限り、完了済みのOCR、マスク、訳文、手動編集を上書きしません。

任意の段階から開始する前に、状態名だけでなくページごとの実データを検証します。前提生成物がなければ、必要な作業が見つかるまで1段階ずつ戻ります。

- ステップ4の前に、有効なマスクと`.str`の訳文／組版データを確認します。訳文がなければステップ3へ、文字領域またはマスクがなければさらにステップ2へ戻ります。
- ステップ3の前に、原稿ページ、文字領域、一度校正済みのOCR原文、マスクを確認します。不完全ならステップ2へ戻ります。
- ステップ2の前に、原稿画像の存在とプロジェクトのページ索引を確認します。失効していればステップ1で再スキャンします。
- 戻る処理は欠損または失効したデータだけを補い、有効な前提生成物は再作成しません。ページごとに異なる段階から再開できます。

### 方法A：モデルをダウンロードして完全オフラインで実行

「設定 → モデル」で画像テキスト化モデルと、必要に応じて画像変換モデルを指定します。OCR、翻訳、背景修復、合成はMac上で実行されます。モデルのダウンロード後は、漫画の内容を外部AIサービスへ送信する必要がありません。

- `imageToText`モデルはステップ2でタイトル／台詞候補を分類し、OCRが見落とした閉領域を補完して完全なOCR校正を行い、ステップ3でページ文脈翻訳を担当します。事前にシステムOCR、VLM出力、閉領域の形状を統合・重複排除します。モデル未読込時もシステムOCRだけでマスクを作成できます。効果音は現在の翻訳主処理に含めず、校正と翻訳はbatch化して全領域の結果を検証します。
- `imageToImage`モデルはステップ4の背景修復を担当するオプションです。未設定時は「設定 → 詳細」でMetal GPU近傍修復またはCPUによる吹き出し主要色修復を選択でき、GPU失敗時はCPUへ自動的に切り替わります。
- GUIでは各段階を個別に実行でき、「選択ページ／全ページを完全処理」も利用できます。一括実行も内部ではステップ2〜4を順番に処理し、中間データを保持します。
- 結果はプロジェクトと`.str`へ戻されるため、任意の段階を修正して後続段階だけを再実行できます。

### 方法B：AI AgentからMCP経由で実行

「設定 → MCP」でサービスを有効にし、ポートとクライアントIP/CIDR許可リストを設定して、Streamable HTTP対応のAI Agentを接続します。Agentもworkspace／projectの状態と4段階の生成物を利用しますが、既存生成物があれば任意の段階から再開でき、完了済みの処理を繰り返す必要はありません。

ローカル画像テキスト化モデルを使わず、新しい未処理プロジェクトを翻訳する例：

1. `mangakitchen.workspace.open`を呼び、返された`workspace_id`を保持します。
2. `mangakitchen.page.detect_masks`でOCRとマスク生成を行います。
3. ページと原稿画像resourceを読み、現在の領域と比較します。文字や領域の漏れがあれば、`mangakitchen.page.supplement_regions`で粗い矩形と原文を一括送信します。backendは文字形状maskの精修、重複除去、`.str`同期を行い、Agentから正確なpolygonを直接指定することもできます。
4. 既存領域の`ocrTextRefined`がfalseなら、Agentが`rawSourceText`を先に校正し、その後翻訳して`mangakitchen.region.update`で`source_text`、訳文、組版設定を書き戻します。
5. `mangakitchen.page.compose`で背景修復と出力を行います。

ローカル`imageToText`モデルも読み込まれている場合、Agentは`mangakitchen.page.translate`または`mangakitchen.page.run_full`を利用できます。`page.run_full`にはローカル画像テキスト化モデルが必要です。純粋なAgent翻訳では`detect_masks → supplement_regions → region.update → compose`を使用し、漏れがなければ`supplement_regions`を省略できます。

既存プロジェクトでは、Agentはworkspace、page、`.str` resourceと実際の生成物を先に確認し、必要なtoolだけを呼びます。有効なマスクを持つ`maskReady`ページは翻訳または`region.update`から、完全な訳文を持つ`translationReady`ページは`compose`から開始できます。データ不足時は上記の規則で段階的に戻ります。純Agentモードでステップ3へ戻る場合は、ローカルモデルを強制せず、Agentが翻訳して`region.update`へ書き込みます。

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

GUIは常に起動します。`--mcp`を省略すると保存済み設定を使用し、`--mcp=on|off`は今回の起動だけを上書きします。listenerは`0.0.0.0`にbindし、既定ポートは`12080`です。実際の接続元IP/CIDRが許可リストにあるrequestだけを受け付け、初期値は`127.0.0.1`のみです。ローカルendpointは`http://127.0.0.1:12080/mcp`で、`--mcp-port=<port>`でも上書きできます。メインウィンドウを閉じてもAppは終了せず、メニューバーから再表示できます。

データ保存先の変更は再起動後に反映されます。2種類のモデル変更は即時反映され、MCPスイッチ、ポート、許可リストの変更時はlistenerが再起動します。

既定のデータ保存先：

```text
~/Library/Application Support/MangaKitchen/
  Projects/library.json
  Projects/<project-uuid>/project.json
  Artifacts/<page-uuid>/
```

各`.str`は原画像と同じ場所に保存されます。例えば`ComicTest/001.webp`には`ComicTest/001.str`が対応します。指定した出力フォルダには最終PNGのみを保存します。旧配置の`.str`は原画像の横へコピーし、旧ファイルも保持します。

旧`Workspace/workspace.json`は初回起動時に最初のプロジェクトへ移行され、元ファイルは残ります。

## モデル形式

モデルフォルダには`mangakitchen-model.json`が必要です。例：

- `Examples/Models/ImageToTextModel/mangakitchen-model.json`
- `Examples/Models/ImageToImageModel/mangakitchen-model.json`
- `Examples/Models/MLXVLMModel/mangakitchen-model.json`
- `Examples/Models/QwenImageEditModel/mangakitchen-model.json`

manifestのfeature名はCore MLモデルと一致させます。現在のAdapterは画像テキスト化の画像／任意prompt／文字列出力、および画像変換の画像／任意mask・prompt／画像出力を扱います。

Core ML manifestは1回のpredictionとしてパッケージ済みのモデル向けです。tokenizerと逐次decodeが必要なQwen-VLは専用MLX Adapterを使用し、sampler loopを持つdiffusion modelも専用`ImageToImageGenerating` Adapterが必要です。コアpipelineは変更しません。

`MLXVLMRuntime`は`mlx-swift-lm`が対応する`model_type`のローカルVLMを読み込めます。約3GBの`lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit`からの開始を推奨します。

1. Hugging Faceモデル一式をローカルフォルダへダウンロードします。
2. `Examples/Models/MLXVLMModel/mangakitchen-model.json`をモデルのルートへコピーします。
3. Appでそのフォルダを選択します。初回読み込み後はcontainerをメモリに保持してページ間で再利用します。

単一のsafetensorsだけでは利用できません。`config.json`、tokenizer、processor、chat templateも保持してください。

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
MangaKitchenRuntime    Vision OCR、読み順、Core ML/Metal、マスク、修復、Core Text
MangaKitchenApp        SwiftUI、WKWebView、URL Scheme、JSON Bridge、HTML/JavaScript
MangaKitchenApp/MCP    GUI process内のMCP Streamable HTTP adapterとライフサイクル
```

設計とデータフローは[Documentation/ARCHITECTURE.md](Documentation/ARCHITECTURE.md)、Swift／JavaScript／MCP契約は[Documentation/WORKFLOW_API.md](Documentation/WORKFLOW_API.md)を参照してください。

## 既知の制限

- モデルweightは同梱していません。正式モデル選定後に容量、ライセンス、配布方法を決定する必要があります。
- 現在の自動候補検出は白黒漫画の閉じた明るい領域が中心です。暗色／カラーの吹き出しや閉じていないナレーション枠は、将来segmentation modelで補強できます。効果音は意図的に翻訳主処理から外しており、将来対応する場合は専用の検出・組版方式を使用します。
- Metal近傍修復は代替手段です。複雑な網点や線画をまたぐ文字にはinpainting modelを推奨します。
- Qwen Image Edit INT4は約25GB級の推論メモリとページごとの完全なdiffusionを必要とします。
- App Sandboxのsecurity-scoped bookmark、署名、notarization、正式な`.app` packagingは未実装です。
