# AnalysisContext 設計ドキュメント

> Phase 6 / P0
> 関連Issue: #70
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
└── docs_excerpts         :: Union{DocsExcerpts, Nothing}
```

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

## 3. 公開 API

| 関数 / コンストラクタ | 説明 |
|---|---|
| `ModelMetadata(m::AbstractMacroModel)` | モデルから `ModelMetadata` を作成 |
| `SimulationResultSummary(result; shock_description)` | `SimulationResult` から統計サマリーを作成 |
| `Caveats()` | 空の `Caveats` を作成 |
| `DocsExcerpts()` | 空の `DocsExcerpts` を作成 |
| `AnalysisContext(m, result; kwargs...)` | モデルと `SimulationResult` から `AnalysisContext` を作成 |
| `to_dict(ctx)` | `Dict{String, Any}` に変換（各サブ型にも定義） |
| `to_json(ctx)` | JSON 文字列に変換 |
| `to_compact_dict(ctx)` | トークン量を抑えたコンパクト版 Dict に変換 |

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

### ドキュメント抜粋を含む例（RAG 層との連携）

```julia
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

## 5. `to_compact_dict` の仕様

`to_compact_dict` は、LLM に渡すトークン量を抑えるために変数サマリーを以下の4フィールドに絞る。

| 保持するフィールド | 省略されるフィールド |
|---|---|
| `initial`, `final`, `peak_response`, `sign_reversal` | `max`, `min`, `range`, `argmax`, `argmin` |

また、フィールドがすべて空文字列の `DocsExcerpts` は出力から省略される。

---

## 6. 設計上の注意事項

- **LLM API を呼ばない**: `AnalysisContext` の構築・変換はすべて LLM API なしで完結する。LLM 呼び出しは LLM接続層（[llm_layer.md](llm_layer.md) セクション7参照）に閉じる。
- **`data_comparison_summary` は実データ比較後に設定**: 実データ比較を行っていない場合は `Nothing` のままとする。`DataComparisonSummary` を手動で構築する場合は `variable_mapping.md` の対応表を参照すること。
- **`parameters` は `Dict{String, Any}`**: JSON3 でシリアライズ可能にするため NamedTuple から変換している。モデルの `parameters(m)` の NamedTuple は `ModelMetadata(m)` のコンストラクタ内で自動変換される。
- **`variable_summaries` の NamedTuple→Dict 変換**: `summarize_result` が返す各変数のサマリーは NamedTuple だが、`to_dict` / `to_json` の際に Dict に変換される。

---

## 7. ドキュメント間の関係

| ドキュメント | 本ドキュメントとの関係 |
|---|---|
| [LLM接続層の設計](llm_layer.md) | セクション4の `AnalysisContext` 入力仕様の実装が本型 |
| [LLM出力の安全性・免責・禁止表現ルール](../llm_safety.md) | `caveats` フィールドの内容は本ドキュメントのルールに従って設定する |
| [出力結果の読み方](../simulation_outputs.md) | `variable_summaries` の各フィールドの解釈方法 |
| [モデル変数と実データ系列のマッピング表](../data/variable_mapping.md) | `DataComparisonSummary` を設定する際の変数対応参照先 |
