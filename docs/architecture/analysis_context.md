# AnalysisContext 設計ドキュメント

> 関連Issue: #70, #73
> 関連ドキュメント: [LLM接続層の設計](llm_layer.md)

---

## 1. 概要

`AnalysisContext` は、LLM（大規模言語モデル）へ渡す構造化コンテキストを表す型である。
モデルメタ情報・シミュレーション結果サマリー・実データ比較サマリー・注意事項・ドキュメント抜粋を一つの構造体にまとめ、LLM 入力を安定・検証可能にする。

LLM API は `AnalysisContext` のスコープ外である。この型は純粋なデータコンテナであり、`to_dict` / `to_json` / `to_compact_dict` によって Dict または JSON 文字列に変換してプロンプトへ埋め込む。

---

## 2. 型階層と構造

```
AnalysisContext
├── model_metadata        :: ModelMetadata
├── simulation_result_summary :: SimulationResultSummary
├── data_comparison_summary   :: Union{DataComparisonSummary, Nothing}
├── caveats               :: Caveats
├── docs_excerpts         :: Union{DocsExcerpts, Nothing}
└── keen_empirical        :: Union{KeenEmpiricalContext, Nothing}   # ADR 0005 §3（下記 §2.1）
```

`keen_empirical` は Keen 実証分析（キャリブレーション・検証・regime 診断・感応度・方法論）を
LLM へ構造化して渡すための optional field である。通常の simulation 説明では `nothing` とし、
実証層成果物を説明する場合のみ設定する。既存 constructor・`explain_result` /
`explain_data_comparison` の意味は一切変更しない。詳細は §2.1 と
[ADR 0005](../adr/0005-keen-ai-explanation-contract.md) を参照。

### ModelMetadata

モデルの識別情報と変数定義。

| フィールド | 型 | 内容 |
|---|---|---|
| `model_name` | `String` | モデルの識別名（例: `"RBC Model"`） |
| `state_variables` | `Vector{Symbol}` | 状態変数リスト（例: `[:K, :A]`） |
| `control_variables` | `Vector{Symbol}` | 操作変数リスト（例: `[:C, :L, :Y]`） |
| `parameters` | `Dict{String, Any}` | パラメータ名と値（JSON変換可能） |

### SimulationResultSummary

`SimulationResult` から生成した数値サマリー。元の時系列全体ではなく統計量のみを保持する。

| フィールド | 型 | 内容 |
|---|---|---|
| `scenario_name` | `String` | シナリオ名 |
| `n_periods` | `Int` | シミュレーション期間数 |
| `variable_summaries` | `Dict{String, Any}` | 変数ごとの統計サマリー（`summarize_result` の `variables` フィールド相当） |
| `shock_description` | `Union{String, Nothing}` | ショックの種類と大きさの説明（IRFの場合） |

`variable_summaries` の各エントリは `summarize_result` が返す統計量（`initial`, `final`, `max`, `min`, `range`, `argmax`, `argmin`, `peak_response`, `sign_reversal`）を持つ。

### DataComparisonSummary

実データとモデル出力の比較結果サマリー。実データ比較を行わない場合は `Nothing`。

| フィールド | 型 | 内容 |
|---|---|---|
| `data_source` | `String` | 実データの出典（例: `"FRED/GDPC1"`） |
| `comparison_period` | `Tuple{Int, Int}` | 比較対象期間（開始期, 終了期） |
| `deviation_statistics` | `Dict{String, Any}` | 乖離の統計量（平均・最大・方向等） |
| `data_caveats` | `Vector{String}` | データ固有の注意事項 |

### Caveats

LLM 出力に含めるべき免責・注意事項。

| フィールド | 型 | 内容 |
|---|---|---|
| `model_limitations` | `Vector{String}` | モデル仮定の限界リスト |
| `data_limitations` | `Vector{String}` | データ制約・信頼性の注意事項 |
| `interpretation_warnings` | `Vector{String}` | 解釈上の警告（例: 「変数は対数偏差」） |

### DocsExcerpts

LLM の文脈として提供するドキュメント抜粋。RAG 層が検索・選択して渡すことを想定する。

| フィールド | 型 | 内容 |
|---|---|---|
| `model_doc` | `String` | モデル解説ドキュメントの抜粋 |
| `output_guide` | `String` | 出力結果の読み方ガイドの抜粋 |
| `caveats_doc` | `String` | モデルの限界・注意事項の抜粋 |

---

## 2.1 Keen 実証コンテキスト（`KeenEmpiricalContext`, ADR 0005 §3）

Keen 実証層（観測系列変換・限定キャリブレーション・in/out-of-sample 検証・observed proxy /
model の regime 診断・感応度分析）の成果物を、**認識論的性質を混同せずに** LLM へ渡すための
拡張コンテキスト。値の性質を 7 つの固定カテゴリ（`observed_data` / `measurement` /
`calibration` / `model_output` / `diagnostic_proxy` / `sensitivity` / `limitations`）へ分離し、
すべての主要主張を安定 source ID（`EvidenceSource` registry）へ結び付ける。設計契約は
[ADR 0005](../adr/0005-keen-ai-explanation-contract.md)。

### 構造

```
KeenEmpiricalContext
├── contract_version   :: String                         # "keen-ai-context/1.0.0"
├── analysis_scope     :: AnalysisScope                   # 国・期間・mode・比較モデル・split
├── observed_data      :: Vector{ObservedSeriesSummary}   # 観測値・provenance（欠損は nothing）
├── measurement        :: Union{MethodologySummary, Nothing}   # 観測方程式・変換・頻度・version
├── calibration        :: Union{CalibrationSummary, Nothing}   # 推定設定・値・識別診断
├── model_outputs      :: Vector{ModelOutputSummary}      # literature/calibrated trajectory・発散
├── validation         :: Union{ValidationSummary, Nothing}    # in/OOS の変数別 fit metric
├── regime_diagnostics :: Vector{RegimeDiagnosticSummary} # observed/literature/calibrated を別要素
├── sensitivity        :: Vector{SensitivitySummary}      # base と変更 scenario・差・安定性
├── limitations        :: Vector{LimitationSummary}       # 安定 code 付き caveats
├── warnings           :: Vector{ExplanationWarning}      # code/severity/affected（§5）
├── sources            :: Dict{String, EvidenceSource}    # source registry（§2）
└── prompt_version     :: String
```

### 主要な補助型

| 型 | 役割 |
|---|---|
| `EvidenceSource` | 主張の出所（`id`・`category`・`context_path`・provider/series/period/unit/method_id 等）。`id` は `^[a-z][a-z0-9_.-]*$` を満たす一意 ID |
| `ExplanationWarning` | `code`・`severity`（`:info`/`:warning`/`:error`/`:blocking`）・`message`・`affected_source_ids`・`affected_sections` |
| `AnalysisScope` | country・mode・sample 期間・比較モデル・calibration/validation 期間 |
| `ObservedSeriesSummary` | 変数・date/value（欠損は `nothing`）・provider・series_id・mode・変換前後 unit・quality |
| `MethodologySummary` | 系列対応・単位・変換式・頻度集約・欠損処理・各層 methodology version・seed |
| `CalibrationSummary` | 推定/固定パラメータ・bounds・objective・収束・弱識別・非一意・境界張り付き等 |
| `ModelOutputSummary` | literature/calibrated の full-sample trajectory 点数・発散・期間 |
| `ValidationSummary` | 評価別（モデル×期間×初期値方式）の変数別 fit と literature 悪化フラグ |
| `RegimeDiagnosticSummary` | subject（`observed_proxy`/`literature_model`/`calibrated_model`）別の regime share・遷移・カバレッジ・margin・発散 |
| `SensitivitySummary` | シナリオ・変更仮定・base との差・符号反転・robustness status |
| `LimitationSummary` | 安定 code・本文・根拠 category・affected source IDs |

### 生成（adapter）

```julia
# 実証層成果物（keen_validation.jl）から生成する主 adapter
dataset = build_keen_empirical_dataset(config, macro_ds)
result  = validate_keen(dataset, keen_default_validation_config(dataset))
kctx    = KeenEmpiricalContext(dataset, result; mode = :fixture)

# AnalysisContext に optional field として載せる
actx = AnalysisContext(model, sr; keen_empirical = kctx)
to_dict(actx)["keen_empirical"]        # 実証コンテキストを含む Dict
```

adapter は dataset の dates / 観測系列と result の trajectory / summary を**再計算せず写像**する。
非有限値（欠損・発散由来の `NaN`/`Inf`）は 0 化せず JSON `null`（`nothing`）とする。validation split が
無い等で分析が欠ける場合は該当 section を空 / `nothing` とし、simulation-only に近い context も表現できる。

### warning の標準 code（ADR 0005 §5）

構造化フラグ・自由文 warning は標準 code へ写像される（`CALIBRATION_NOT_CONVERGED`・
`WEAK_IDENTIFICATION`・`NONUNIQUE_SOLUTION`・`PARAMETER_AT_BOUND`・`OOS_WORSE_THAN_LITERATURE`・
`MODEL_DIVERGED`・`REGIME_MISMATCH`・`SENSITIVITY_UNSTABLE`）。severity が該当 section の解釈可否を
規定する（後続 #131 の説明 API が利用）。

---

## 3. 公開 API

| 関数 / コンストラクタ | 説明 |
|---|---|
| `ModelMetadata(m::AbstractMacroModel)` | モデルから `ModelMetadata` を作成 |
| `SimulationResultSummary(result; shock_description)` | `SimulationResult` から統計サマリーを作成 |
| `Caveats()` | 空の `Caveats` を作成 |
| `DocsExcerpts()` | 空の `DocsExcerpts` を作成 |
| `AnalysisContext(m, result; kwargs...)` | モデルと `SimulationResult` から `AnalysisContext` を作成（`keen_empirical` kwarg で Keen 実証コンテキストを添付可） |
| `KeenEmpiricalContext(dataset, result; mode, prompt_version)` | 実証層成果物から Keen 実証コンテキストを生成（ADR 0005 §3、§2.1） |
| `to_dict(ctx)` | `Dict{String, Any}` に変換（各サブ型・`KeenEmpiricalContext` にも定義） |
| `to_json(ctx)` | JSON 文字列に変換 |
| `to_compact_dict(ctx)` | トークン量を抑えたコンパクト版 Dict に変換 |
| `build_docs_excerpts(model_name; ...)` | モデル名・変数名・キーワードから `DocsExcerpts` を生成（軽量RAG） |
| `build_docs_excerpts(ctx; ...)` | `AnalysisContext` から `DocsExcerpts` を生成（軽量RAG） |
| `build_keen_empirical_prompt(ctx; audience, detail)` | Keen 実証説明用の prompt 全文を生成（ADR 0005 §4、`keen_empirical` 必須） |
| `explain_keen_empirical_result(ctx; audience, detail, provider)` | Keen 実証結果の根拠付き構造化説明を生成（provider 未接続で決定的、ADR 0005 §4〜§7、下記 §2.2） |
| `parse_keen_empirical_response(raw, kctx; ...)` | provider 応答（JSON）を検証し `:parsed` 出力を返す（失敗時 `nothing`、ADR 0005 §7.1） |

---

## 2.2 Keen 実証結果の根拠付き説明 API（ADR 0005 §4〜§9）

`KeenEmpiricalContext` を持つ `AnalysisContext` から、認識論的性質を分離した構造化説明
`KeenEmpiricalExplanationOutput` を生成する。prompt 生成（`build_keen_empirical_prompt`）は
provider 呼び出しから分離し、provider 未接続でも決定的 fallback 出力を単体利用できる。

```julia
kctx = KeenEmpiricalContext(dataset, result; mode = :fixture)
actx = AnalysisContext(model, sr; keen_empirical = kctx)

out = explain_keen_empirical_result(actx)              # provider 未接続 → generation_status=:deterministic
out.validation_assessment.status                       # :available / :not_available / :insufficient_evidence
out.source_references                                  # claim から参照された EvidenceSource のみ（重複排除）

out2 = explain_keen_empirical_result(actx; provider = create_provider())  # 応答検証: :parsed か :fallback
```

### 必須 section と表示順（ADR 0005 §4.3）

`executive_summary` → `analysis_scope` → `observed_evidence` → `measurement_and_transformations`
→ `calibration_interpretation` → `validation_assessment` → `regime_assessment`
→ `sensitivity_and_robustness` → `interpretation_scope` → `limitations_and_alternatives`。
各 section は `ExplanationSection`（`status` / `claims` / `missing_fields`）。`claims` の各
`EvidenceClaim` は `epistemic_status`（`observed` / `measured` / `estimated` / `simulated` /
`diagnostic` / `sensitivity` / `limitation`）と、category が整合する 1 件以上の `source_ids` を持つ。

### warning・fallback の制御（ADR 0005 §5・§7）

- `error` / `blocking` の warning が該当 section を `insufficient_evidence` にし、肯定的解釈 claim を
  抑止する（値の存在は qualifier 付きで報告）。
- `blocking` warning がある場合は provider を呼ばず決定的 fallback にする。
- provider 応答は JSON parse・`contract_version`・必須 section・source registry・category/status
  整合を検証し、いずれか失敗で `OUTPUT_SCHEMA_INVALID` warning 付き決定的 fallback（`:fallback`）へ落ちる。
  部分的な自由文 salvage は行わない。

---

## 4. 利用例

### 基本的な使用例（RBC IRF）

```julia
using DME

rbc = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)
irf = impulse_response(rbc, 0.01)
sr  = to_simulation_result(rbc, irf, "technology_shock")

ctx = AnalysisContext(
    rbc, sr;
    shock_description = "1% positive technology shock at t=1",
    caveats = Caveats(
        ["Closed economy", "Representative agent", "No nominal frictions"],
        String[],
        ["Variables are log deviations from steady state"],
    ),
)

# Dict 変換（プロンプト埋め込み等に使用）
d = to_dict(ctx)
println(d["model_metadata"]["model_name"])   # "RBC Model"
println(d["simulation_result_summary"]["n_periods"])  # 150

# JSON 変換（ファイル保存やAPI送信に使用）
json_str = to_json(ctx)

# コンパクト変換（トークン削減が必要な場合）
compact = to_compact_dict(ctx)
```

### 実データ比較サマリーを含む例

```julia
dcs = DataComparisonSummary(
    "FRED/GDPC1",
    (1, 100),
    Dict{String, Any}(
        "mean_deviation" => 0.03,
        "max_deviation"  => 0.12,
        "direction"      => "model_above_data",
    ),
    [
        "Seasonal adjustment applied",
        "Calibration-free comparison — interpret with caution",
    ],
)

ctx = AnalysisContext(
    rbc, sr;
    shock_description = "1% technology shock",
    data_comparison_summary = dcs,
    caveats = Caveats(
        ["Closed economy"],
        ["FRED data subject to revision"],
        ["No calibration performed"],
    ),
)

d = to_dict(ctx)
println(d["data_comparison_summary"]["data_source"])  # "FRED/GDPC1"
```

### ドキュメント抜粋を含む例（`build_docs_excerpts` を使用）

`build_docs_excerpts` を使うと、モデル名・変数名・シナリオ名に基づいて `docs/` 配下の
Markdown から自動的に関連セクションを抽出できる（詳細は [セクション5](#5-軽量ragdoc-context-の仕組み) 参照）。

```julia
# 自動抽出（推奨）
de = build_docs_excerpts("RBC Model";
    variable_names = [:K, :A, :C, :L],
    scenario_name  = "technology_shock",
    keywords       = ["IRF"],
)
ctx = AnalysisContext(rbc, sr; docs_excerpts = de)

# AnalysisContext から直接生成する場合
ctx_base = AnalysisContext(rbc, sr)
de  = build_docs_excerpts(ctx_base)
ctx = AnalysisContext(rbc, sr; docs_excerpts = de)

# 手動指定（カスタム抜粋を使いたい場合）
de = DocsExcerpts(
    "RBC モデルは資本・労働・技術の3要素からなる標準的なリアルビジネスサイクルモデルです。",
    "ŷ は定常状態からの産出の対数偏差を示します。",
    "このモデルは名目硬直性・摩擦・不確実性を含みません。",
)
ctx = AnalysisContext(rbc, sr; docs_excerpts = de)
```

### Ramsey モデルの移行経路

```julia
rams = RamseyModel(0.3, 0.99, 0.25)
K_star, _ = DME.calc_ep(rams)
path = DME.find_path(rams, K_star / 2)
sr   = to_simulation_result(rams, path, "find_path")

ctx = AnalysisContext(
    rams, sr;
    caveats = Caveats(
        ["Infinite horizon", "Representative agent", "No uncertainty"],
        String[],
        String[],
    ),
)
```

### `explain_data_comparison` の利用例

```julia
using DME

rbc = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)
irf = impulse_response(rbc, 0.01)
sr  = to_simulation_result(rbc, irf, "technology_shock")

dcs = DataComparisonSummary(
    "FRED/GDPC1",
    (1, 40),
    Dict{String, Any}(
        "correlation_by_variable" => Dict{String, Any}("Y" => 0.82, "C" => 0.45, "K" => 0.91),
        "rmse_by_variable"        => Dict{String, Any}("Y" => 0.031, "C" => 0.058, "K" => 0.012),
        "overall_rmse"            => 0.034,
        "direction"               => "model_above_data",
    ),
    ["季節調整済みデータを使用", "キャリブレーションなしの参考比較"],
)

ctx = AnalysisContext(
    rbc, sr;
    shock_description = "1% technology shock",
    data_comparison_summary = dcs,
    caveats = Caveats(
        ["Closed economy", "Representative agent"],
        ["FRED data subject to revision"],
        ["Variables are log deviations from steady state"],
    ),
)

# プロンプト文字列のみを取得（LLMへ渡す用途）
prompt = build_data_comparison_prompt(ctx)

# 構造化 mock 応答を取得（LLM API なし）
out = explain_data_comparison(ctx)

println(out.what_was_compared)        # 何を比較したか
println(out.large_deviation_variables) # 乖離の大きい変数
println(out.model_explains_well)      # モデルが説明しやすい点
println(out.model_explains_poorly)    # モデルが説明しにくい点
println.(out.additional_series)       # 追加で見るべき系列（候補）
println.(out.caveats)                 # 免責・注意事項
println(out.disclaimer)               # 免責文言
```

> **注意**: `data_comparison_summary` が `nothing` のまま `explain_data_comparison` / `build_data_comparison_prompt` を呼ぶと `ArgumentError` が送出される。実データ比較を行った後に `DataComparisonSummary` を設定すること。

---

## 5. 軽量RAG/Doc Context の仕組み

`build_docs_excerpts`（`src/llm/doc_context.jl`）は、ベクトルDBや外部APIを使わず
`docs/` 配下のMarkdownをキーワードマッチングで検索し、`DocsExcerpts` を生成する軽量RAG層である。

### 選択ロジック

| `DocsExcerpts` フィールド | 選択元ファイル | 選択基準 |
|---|---|---|
| `model_doc` | `docs/models/<model>.md` | モデル名（固定マッピング）+ 「目的」見出し・LLM向け要約 |
| `output_guide` | `docs/simulation_outputs.md` | `scenario_name`・`keywords` に IRF/ショック語句が含まれるか |
| `caveats_doc` | `docs/models/<model>.md` | 「限界」「注意事項」「前提」等の見出しキーワード |

### モデル名 → ドキュメントファイルのマッピング

| モデル識別名 | ドキュメントファイル |
|---|---|
| `"RBC Model"` | `docs/models/rbc.md` |
| `"Ramsey Model"` | `docs/models/ramsey.md` |
| `"Solow Model"` | `docs/models/solow.md` |
| `"IS-LM Model"` | `docs/models/islm.md` |
| `"AD-AS Model"` | `docs/models/adas.md` |
| `"New Keynesian Model"` | `docs/models/new_keynesian.md` |
| `"VAR Model"` | `docs/models/var.md` |
| `"Mundell-Fleming Model"` | `docs/models/mundell_fleming.md` |

### Fallback

- ドキュメントファイルが存在しない場合 → 該当フィールドを `""` として安全に返す
- 見出しキーワードに一致するセクションがない場合 → ファイル先頭を `max_chars_per_doc` 文字まで抽出
- モデル名がマッピング表にない場合 → `model_doc` と `caveats_doc` を `""` で返す

### 将来のembedding/RAGへの拡張

現在の実装はキーワードマッチングに基づく軽量版である。
精度向上が必要になった場合、以下の方向で拡張できる:

1. **セクション抽出の高精度化**: 見出し階層を考慮した再帰的なセクション抽出
2. **ベクトル類似度検索**: `Embeddings.jl` 等によるdocsのベクトル化と類似度ランキング
3. **外部RAGエンジン連携**: ChromaDB・Weaviate等への `docs/` インデックス登録
4. **キャッシュ**: 頻繁に使うdocファイルのオンメモリキャッシュ

この拡張は `src/llm/doc_context.jl` 内の内部ヘルパー（`_extract_*` 系）を置き換えることで
`DocsExcerpts` を返す公開APIを変更せずに実現できる。

---

## 6. `to_compact_dict` の仕様

`to_compact_dict` は、LLM に渡すトークン量を抑えるために変数サマリーを以下の4フィールドに絞る。

| 保持するフィールド | 省略されるフィールド |
|---|---|
| `initial`, `final`, `peak_response`, `sign_reversal` | `max`, `min`, `range`, `argmax`, `argmin` |

また、フィールドがすべて空文字列の `DocsExcerpts` は出力から省略される。

---

## 7. 設計上の注意事項

- **LLM API を呼ばない**: `AnalysisContext` の構築・変換はすべて LLM API なしで完結する。LLM 呼び出しは LLM接続層（[llm_layer.md](llm_layer.md) セクション7参照）に閉じる。
- **`data_comparison_summary` は実データ比較後に設定**: 実データ比較を行っていない場合は `Nothing` のままとする。`DataComparisonSummary` を手動で構築する場合は `variable_mapping.md` の対応表を参照すること。
- **`parameters` は `Dict{String, Any}`**: JSON3 でシリアライズ可能にするため NamedTuple から変換している。モデルの `parameters(m)` の NamedTuple は `ModelMetadata(m)` のコンストラクタ内で自動変換される。
- **`variable_summaries` の NamedTuple→Dict 変換**: `summarize_result` が返す各変数のサマリーは NamedTuple だが、`to_dict` / `to_json` の際に Dict に変換される。

---

## 8. ドキュメント間の関係

| ドキュメント | 本ドキュメントとの関係 |
|---|---|
| [LLM接続層の設計](llm_layer.md) | セクション4の `AnalysisContext` 入力仕様の実装が本型 |
| [LLM出力の安全性・免責・禁止表現ルール](../llm_safety.md) | `caveats` フィールドの内容は本ドキュメントのルールに従って設定する |
| [出力結果の読み方](../simulation_outputs.md) | `variable_summaries` の各フィールドの解釈方法 |
| [モデル変数と実データ系列のマッピング表](../data/variable_mapping.md) | `DataComparisonSummary` を設定する際の変数対応参照先 |
| `src/llm/doc_context.jl` | `build_docs_excerpts` の実装。軽量RAGのキーワードマッチングロジック |
