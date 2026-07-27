# DME API リファレンス

## Public API と Internal API の分離方針

DME では関数・型を **Public API** と **Internal API** に分類しています。

| 分類 | 定義 |
|---|---|
| **Public API** | `using DME` でエクスポートされる。後方互換性を保って維持される。 |
| **Internal API** | エクスポートされない。`DME.func()` でアクセス可能だが、将来変更・削除される可能性がある。 |

---

## Public API 一覧

### モデル型

```julia
abstract type AbstractMacroModel end
struct RamseyModel <: AbstractMacroModel  # RamseyModel(α, β, δ)
struct RBCModel    <: AbstractMacroModel  # RBCModel(α, β, γ, δ, μ, ρ)
struct KeenModel   <: AbstractMacroModel  # KeenModel(α, β, δ, ν, r, φ0, φ1, κ0, κ1, κ2)
struct SIMModel    <: AbstractMacroModel  # SIMModel(; α1, α2, θ, G, W=1.0)  最小 SIM 型 SFC
```

### モデルメタ情報

```julia
model_name(m::AbstractMacroModel)        -> String
state_variables(m::AbstractMacroModel)   -> Vector{Symbol}
control_variables(m::AbstractMacroModel) -> Vector{Symbol}
parameters(m::AbstractMacroModel)        -> NamedTuple
```

### 計算 API

すべての計算関数は `NamedTuple` を返します。キーは変数名の `Symbol` です。

```julia
# 定常状態
steady_state(m::RamseyModel)                              -> (K, C)
steady_state(m::RBCModel)                                 -> (A, r, w, L, K, Y, C)

# 完全予見均衡経路
transition_path(m::RamseyModel, K0::Float64; maxT=30)     -> (C, K)
transition_path(m::RBCModel, A0::Float64, K0::Float64; maxT=150) -> (A, r, w, L, K, Y, C)

# 動学シミュレーション（Ramsey のみ）
simulate(m::RamseyModel, K0::Float64; maxT=30, vi_opts=ValueIterationOptions()) -> (C, K)

# インパルス応答（RBC のみ）
impulse_response(m::RBCModel, shock_size::Float64; maxT=150) -> (â, r̂, ŵ, l̂, k̂, ŷ, ĉ)

# Keen モデル（連続時間 ODE、固定刻み RK4）
steady_state(m::KeenModel)                                -> (ω, λ, d, π, g)  # 良い均衡（閉形式）
simulate(m::KeenModel, ω0, λ0, d0; T=300, options=ODESolverOptions()) -> (ω, λ, d, π, g)
impulse_response(m::KeenModel, shock; T=300, variable=:d, options=ODESolverOptions()) -> (ω, λ, d, π, g)

# SIM 型 SFC モデル（離散時間・閉形式・再帰）。系列キーは (Y, C, YD, T, G, H, N)
steady_state(m::SIMModel)                                 -> (Y, C, YD, T, G, H, N)  # 貯蓄ゼロ均衡（閉形式）
simulate(m::SIMModel, H0=0.0; T=100)                      -> (Y, C, YD, T, G, H, N)  # 前向き反復
impulse_response(m::SIMModel, shock_size;                             # 財政ショック（定常状態から）
    shock=:G, T=50, permanent=true, shock_start=1, H0=nothing) -> (Y, C, YD, T, G, H, N)
```

### Minsky 資金調達区分診断（Keen モデル）

Keen モデルの出力から Hedge / Speculative / Ponzi 等の資金調達区分を診断する読み取り専用の後処理層。
`KeenModel` の ODE 動学・パラメータには一切影響しない。操作的定義・仮定の詳細は
[Minsky 資金調達区分診断](models/minsky_regime_diagnostics.md)、責務分離の理由は
[ADR 0003](adr/0003-minsky-financing-regime-diagnostics.md) を参照。

```julia
@enum FinancingRegime unlevered hedge speculative ponzi invalid

struct FinancingRegimeConfig
    amortization_rate::Float64         # 元本返済代理率（1/年）。既定 0.05
    debt_tolerance::Float64            # unlevered 判定閾値。既定 1e-8
    classification_tolerance::Float64  # 境界の数値許容差 τ。既定 1e-9
    methodology_version::String        # 既定 "minsky-regime/1.0.0"
end
FinancingRegimeConfig(; amortization_rate=0.05, debt_tolerance=1e-8,
                       classification_tolerance=1e-9,
                       methodology_version="minsky-regime/1.0.0")

struct FinancingRegimeObservation
    time::Int
    regime::FinancingRegime
    ω::Float64
    d::Float64
    r::Float64
    operating_surplus::Float64      # 1 - ω
    interest_commitment::Float64    # r * max(d, 0)
    principal_commitment::Float64   # amortization_rate * max(d, 0)
    debt_service::Float64           # interest_commitment + principal_commitment
    ponzi_margin::Float64           # operating_surplus - interest_commitment
    hedge_margin::Float64           # operating_surplus - debt_service
    methodology_version::String
end

struct FinancingRegimeTransition
    time::Int                       # 遷移後（to側）の時点
    from::FinancingRegime
    to::FinancingRegime
    ponzi_margin::Float64           # 遷移後時点の ponzi_margin
    hedge_margin::Float64           # 遷移後時点の hedge_margin
    from_observation::FinancingRegimeObservation
    to_observation::FinancingRegimeObservation
end

struct FinancingRegimeDiagnostics
    observations::Vector{FinancingRegimeObservation}  # 元の時系列と同じ長さ・順序
    transitions::Vector{FinancingRegimeTransition}
    config::FinancingRegimeConfig
    valid_periods::Vector{Int}      # regime != invalid な時点
    invalid_periods::Vector{Int}    # regime == invalid な時点（発散後の NaN 区間に対応）
end

# 単一時点の診断（純粋関数、m・ω・d を変更しない）
classify_financing_regime(m::KeenModel, ω::Float64, d::Float64;
                           config::FinancingRegimeConfig = FinancingRegimeConfig(),
                           time::Int = 1) -> FinancingRegimeObservation

# NamedTuple 出力（simulate / impulse_response）からの時系列診断
diagnose_financing_regime(m::KeenModel, result::NamedTuple;
                           config::FinancingRegimeConfig = FinancingRegimeConfig()) -> FinancingRegimeDiagnostics

# SimulationResult からの時系列診断（"ω"・"d" 変数と metadata["parameters"].r が必要）
diagnose_financing_regime(sr::SimulationResult;
                           config::FinancingRegimeConfig = FinancingRegimeConfig()) -> FinancingRegimeDiagnostics
```

**使用例**:

```julia
m = KeenModel(0.025, 0.02, 0.01, 3.0, 0.03, 0.0400641, 6.41e-5, -0.0065, exp(-5), 20.0)
ss = steady_state(m)
result = simulate(m, ss.ω, ss.λ, 5.0; T = 300)  # 高債務初期値 → 崩壊経路

diag = diagnose_financing_regime(m, result)
diag.observations[end].regime   # invalid（発散後の NaN 区間は Ponzi へ誤分類されない）
diag.invalid_periods            # 発散後の時点インデックス
diag.transitions                # 区分が変化した時点の一覧（invalid への遷移も含む）

# NamedTuple / SimulationResult の両経路は同一契約を満たす
sr = to_simulation_result(m, result, "simulate")
diagnose_financing_regime(sr).observations == diag.observations  # true 相当（NaN 比較を除く）
```

`unlevered`（`d ≤ debt_tolerance`、負の `d` を含む）と `invalid`（非有限値）は
Hedge/Speculative/Ponzi の基本分類より優先して判定されるため、無借金・発散後の
`NaN` が誤って `hedge`/`ponzi` に分類されることはない。

### Minsky 連続診断指標・サマリー（Keen モデル）

区分（Hedge/Speculative/Ponzi）だけでは失われる連続量（カバレッジ比率・境界からの距離・
債務変化等）を提供する読み取り専用の後処理層。`diagnose_financing_regime`（上記）と同一の
`FinancingRegimeDiagnostics` を内部で共有するため、区分の判定結果は完全に一致する。
指標定義・型契約の詳細は [Minsky 連続診断指標・サマリー](models/minsky_diagnostics_summary.md)
を参照。

```julia
@enum DivergenceStatus no_divergence divergence_onset divergence_continued

const MINSKY_DIAGNOSTICS_METHODOLOGY_VERSION = "minsky-diagnostics/1.0.0"

struct MinskyDiagnosticObservation
    time::Int
    debt_ratio::Float64                    # d
    operating_surplus_share::Float64       # 1 - ω
    net_profit_share::Float64              # π = 1 - ω - r*d
    interest_burden::Float64                # r * max(d, 0)
    principal_commitment_proxy::Float64     # amortization_rate * max(d, 0)
    interest_coverage_ratio::Float64        # operating_surplus_share / interest_burden（0除算はInf）
    debt_service_coverage_ratio::Float64     # operating_surplus_share / debt_service（0除算はInf）
    ponzi_margin::Float64
    hedge_margin::Float64
    debt_change::Float64                    # 前期差分 d[t] - d[t-1]（t=1 は NaN）
    growth_rate::Float64                    # 既存出力 g（再計算しない）
    divergence_status::DivergenceStatus
    methodology_version::String
end

struct MinskyDiagnosticsResult
    model_name::String
    scenario_name::String
    observations::Vector{MinskyDiagnosticObservation}
    regime_diagnostics::FinancingRegimeDiagnostics
    config::FinancingRegimeConfig
    methodology_version::String
    valid_periods::Vector{Int}
    invalid_periods::Vector{Int}
    divergence_time::Union{Int, Nothing}
    metadata::Dict{String, Any}
end

# NamedTuple 出力（simulate / impulse_response、:ω・:d・:g が必要）からの構築
minsky_diagnostics(m::KeenModel, result::NamedTuple;
                   config::FinancingRegimeConfig = FinancingRegimeConfig(),
                   scenario_name::String = "simulate") -> MinskyDiagnosticsResult

# SimulationResult（"ω"・"d"・"g" と metadata["parameters"].r が必要）からの構築
minsky_diagnostics(sr::SimulationResult;
                   config::FinancingRegimeConfig = FinancingRegimeConfig()) -> MinskyDiagnosticsResult

struct MinskyDiagnosticsSummary
    model_name::String
    scenario_name::String
    methodology_version::String
    config::FinancingRegimeConfig
    n_periods::Int
    n_valid::Int
    n_invalid::Int
    regime_counts::Dict{FinancingRegime, Int}
    regime_share_of_valid::Dict{FinancingRegime, Float64}
    first_speculative_time::Union{Int, Nothing}
    first_ponzi_time::Union{Int, Nothing}
    recovery_to_hedge_time::Union{Int, Nothing}
    peak_debt_ratio::Union{Float64, Nothing}
    peak_debt_ratio_time::Union{Int, Nothing}
    min_interest_coverage_ratio::Union{Float64, Nothing}
    min_interest_coverage_ratio_time::Union{Int, Nothing}
    min_debt_service_coverage_ratio::Union{Float64, Nothing}
    min_debt_service_coverage_ratio_time::Union{Int, Nothing}
    min_ponzi_margin::Union{Float64, Nothing}
    min_ponzi_margin_time::Union{Int, Nothing}
    min_hedge_margin::Union{Float64, Nothing}
    min_hedge_margin_time::Union{Int, Nothing}
    max_debt_change::Union{Float64, Nothing}
    max_debt_change_time::Union{Int, Nothing}
    diverged::Bool
    divergence_time::Union{Int, Nothing}
end

minsky_diagnostics_summary(diag::MinskyDiagnosticsResult) -> MinskyDiagnosticsSummary

struct MinskyDiagnosticsComparison
    scenario_names::Vector{String}
    diagnostics::Vector{MinskyDiagnosticsResult}
    summaries::Vector{MinskyDiagnosticsSummary}
end

# 名前付き MinskyDiagnosticsResult のベクトルから比較結果を構築する
minsky_diagnostics_comparison(
    named_diagnostics::AbstractVector{<:Pair{String, MinskyDiagnosticsResult}},
) -> MinskyDiagnosticsComparison
```

**使用例**:

```julia
m = KeenModel(0.025, 0.02, 0.01, 3.0, 0.03, 0.0400641, 6.41e-5, -0.0065, exp(-5), 20.0)
ss = steady_state(m)
result = simulate(m, ss.ω, ss.λ, 5.0; T = 300)  # 高債務初期値 → 崩壊経路

diag = minsky_diagnostics(m, result)
diag.divergence_time                 # 発散ガード作動時点（発散しなければ nothing）
diag.observations[1].interest_coverage_ratio

summary = minsky_diagnostics_summary(diag)
summary.first_ponzi_time             # 最初に ponzi へ移行した時点（未到達なら nothing）
summary.peak_debt_ratio              # 有効期間内の債務比率の最大値

# シナリオ比較（baseline / 高金利 / 高初期債務 / amortization_rate 感応度）
diag_base = minsky_diagnostics(m, simulate(m, ss.ω, ss.λ, ss.d + 0.01; T = 300); scenario_name = "baseline")
diag_high_debt = minsky_diagnostics(m, simulate(m, ss.ω, ss.λ, 5.0; T = 300); scenario_name = "high_debt")
cmp = minsky_diagnostics_comparison(["baseline" => diag_base, "high_debt" => diag_high_debt])
cmp.summaries[2].peak_debt_ratio > cmp.summaries[1].peak_debt_ratio  # true
```

重み付き単一複合スコアは提供しない。`raw` 指標を常に個別に参照し、
「危機確率」等の予測値として解釈しない（[LLM 出力の安全性ルール](llm_safety.md)）。

### 結果型

```julia
struct SimulationResult
    model_name::String
    scenario_name::String
    variables::Dict{String, Vector{Float64}}
    metadata::Dict{String, Any}
end

# コンストラクタ（metadata 省略可）
SimulationResult(model_name, scenario_name, variables)
SimulationResult(model_name, scenario_name, variables, metadata)

# NamedTuple / Dict → SimulationResult 変換
to_simulation_result(m::AbstractMacroModel, result::NamedTuple, scenario::String) -> SimulationResult
to_simulation_result(m::RBCModel, result::Dict{String, Vector{Float64}}, scenario::String) -> SimulationResult

# ユーティリティ
result["K"]              # 変数系列の取得
haskey(result, "K")      # 変数の存在確認
variable_names(result)   # 変数名リスト -> Vector{String}
nperiods(result)         # 期間数 -> Int

# サマリー抽出
summarize_result(result) -> Dict{String, Any}
```

#### `summarize_result` の戻り値構造

```julia
Dict{String, Any}(
    "model_name"    => String,   # モデル名
    "scenario_name" => String,   # シナリオ名
    "nperiods"      => Int,      # 期間数
    "variables"     => Dict{String, NamedTuple}  # 変数名 → 変数サマリー
)
```

変数サマリー (`NamedTuple`) のフィールド:

| フィールド | 型 | 説明 |
|---|---|---|
| `initial` | Float64 | 初期値（第1期） |
| `final` | Float64 | 最終値（最終期） |
| `max` | Float64 | 最大値 |
| `min` | Float64 | 最小値 |
| `range` | Float64 | 変化幅（max - min） |
| `argmax` | Int | 最大値の時点（1始まり） |
| `argmin` | Int | 最小値の時点（1始まり） |
| `peak_response` | Float64 | 絶対値最大の値（符号付き）。IRF結果で有用。 |
| `sign_reversal` | Bool | 系列が正と負の両方を取るか。IRF結果で有用。 |

**例**:

```julia
m = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)
irf = impulse_response(m, 0.01)
sr = to_simulation_result(m, irf, "technology_shock")
summary = summarize_result(sr)

summary["model_name"]                     # "RBC Model"
summary["nperiods"]                       # 150
summary["variables"]["ŷ"].max             # ŷ の最大値
summary["variables"]["ŷ"].argmax          # ŷ が最大になる期
summary["variables"]["k̂"].sign_reversal   # 資本が符号反転するか
```

### データ比較 v1（`compare_with_data`）

モデル結果と実データ（いずれも `SimulationResult`）を変数マッピングに基づいて比較し、乖離指標を返す。

```julia
compare_with_data(
    model_result::SimulationResult,
    data_result::SimulationResult;
    mapping::Dict{String, String},   # モデル変数名 => データ変数名
) -> ComparisonResult

struct ComparisonResult
    model_name::String
    data_source::String
    mapping::Dict{String, String}
    comparison_period::Tuple{Int, Int}   # 比較した期間インデックス（配列位置）
    variables::Dict{String, NamedTuple}  # 変数名 → 乖離指標
end

# LLM AnalysisContext への接続
to_data_comparison_summary(cr::ComparisonResult; caveats=String[]) -> DataComparisonSummary
```

**制約（v1）**: 期間合わせは両系列の短い方への**配列位置**切り詰め（`min(nperiods)` の `[1:n]`）で行い、日付・頻度・単位・stock/flow を考慮しない。頻度変換・単位換算は呼び出し前に完了していること。日付・単位・概念対応を明示したい場合は v2 を使用する。

### データ比較 v2（`compare_results_v2`）

配列位置での暗黙切り詰めや暗黙の単位/頻度変換を行わず、日付・単位・頻度・概念定義・比較可能性を明示する比較 API（Issue #150）。v1 は非破壊で維持される（ADR 0007 §9）。

```julia
compare_results_v2(left::SimulationResult, right::SimulationResult; spec::ComparisonSpec) -> ComparisonResultV2

# 変数対応（equivalent/proxy/partial/incompatible・概念 id・明示変換を保持）
VariableComparisonMapping(;
    model_variable::String, data_variable::String,
    mapping_type::Symbol = :equivalent,          # :equivalent / :proxy / :partial / :incompatible
    model_concept_id::Union{Symbol,Nothing} = nothing,  # MODEL_CONCEPT_DEFINITION_REGISTRY 参照
    data_concept_id::Union{Symbol,Nothing} = nothing,
    unit::Union{String,Nothing} = nothing,
    transform::Union{Nothing,Function} = nothing,       # 宣言時のみ適用（暗黙変換なし）
    transform_label::String = "", caveats = String[],
)

# 実行仕様
ComparisonSpec(;
    mode::Symbol,                                 # :trajectory / :shock_response / :empirical_fit / :mechanism
    mappings::Vector{VariableComparisonMapping} = [],  # :mechanism 以外は 1 つ以上必須
    period::Union{Nothing,Tuple{String,String}} = nothing,  # 整列に使う日付ラベル範囲
    allow_period_index::Bool = false,             # 日付なし同士の配列位置比較を明示許可
    left_model::Union{Symbol,Nothing} = nothing,  # :mechanism 用モデル識別子
    right_model::Union{Symbol,Nothing} = nothing,
    metadata = Dict{String,Any}(),
)
```

**戻り値 `ComparisonResultV2`**:

| フィールド | 型 | 説明 |
|---|---|---|
| `mode` | Symbol | 実行した比較モード |
| `model_name` / `data_source` | String | left / right の名称 |
| `assessment` | `ComparabilityAssessment` | 比較可能性の総合評価 |
| `alignment` | `Dict{String,AlignmentResult}` | 変数ごとの整列結果（独立整列） |
| `metrics` | `Dict{String,NamedTuple}` | 変数別指標（レベルが `:comparable`/`:partial` の変数のみ） |
| `mechanism_diff` | `Union{Nothing,Dict{String,Any}}` | `:mechanism` の構造化差分（他モードは `nothing`） |
| `warnings` | `Vector{String}` | proxy/部分対応・period index 使用・変換適用などの注意 |
| `provenance` | `Dict{String,Any}` | 契約 version・mode・spec 要約 |

`ComparabilityAssessment` は `level`（`:comparable` / `:partial` / `:insufficient` / `:incompatible`）・`reasons`・`required_transforms`（次に必要な変換/証拠）・`per_variable` を持つ。`AlignmentResult` は `common_dates` / `excluded_dates` / `model_indices` / `data_indices` / `n_missing` / `used_period_index` / `transform_history` を持つ。

**契約**:

- 日付 metadata があれば日付 intersection（`spec.period` 指定時はその範囲）で整列し、配列位置は使わない。
- 日付なし同士の配列位置比較は `allow_period_index=true` の明示許可時のみ行う（既定は `:insufficient`）。
- 単位差・頻度差は明示 `transform` が無い限り比較可能性を降格し、次に必要な変換を返す（暗黙換算をしない）。
- stock/flow など概念種別が異なる場合は `:incompatible` とし数値比較しない。同名変数でも `concept_id`（≒ `definition_key`）が異なれば `equivalent` にしない。
- 比較不能でも例外で終了せず、理由と必要変換を `assessment` に構造化して返す（変数の非存在のみ `ArgumentError`）。

```julia
spec = ComparisonSpec(;
    mode = :trajectory,
    mappings = [VariableComparisonMapping(; model_variable="Y", data_variable="GDP")],
)
r = compare_results_v2(model_sr, data_sr; spec)
r.assessment.level                # :comparable / :partial / :insufficient / :incompatible
r.metrics["Y"].rmse               # comparable/partial の変数のみ
r.assessment.required_transforms  # 比較可能にするために次に必要な変換
```

### Real-rate model artifact（`real_rate_model_artifact`）

New Keynesian モデルから、economic-data-provider ADR 006（[vendor コピー](contract/README.md)）
準拠の再現可能 JSON artifact を構築する。期待インフレ率・model-implied 実質政策金利を
`current_inflation`/`inflation_target`/`natural_real_rate` と区別して明示する。設計判断は
[ADR 0008](adr/0008-real-rate-model-artifact-export.md)、実行例は
[real-rate model artifact 生成デモ](examples/real_rate_model_artifact.md) を参照。

```julia
# New Keynesian モデルの期待値パス・level 復元（Issue #159）
nk_expected_inflation_path(m::NewKeynesianModel, shock_size::Float64, t::Int,
    hs::AbstractVector{<:Integer}; shock::Symbol = :demand) -> Vector{Float64}
nk_inflation_level(m::NewKeynesianModel, π_deviation::Float64) -> Float64
nk_nominal_rate_level(m::NewKeynesianModel, i_deviation::Float64) -> Float64

# artifact 構築（adapter。sfc_result と同じ idiom）
real_rate_model_artifact(m::NewKeynesianModel;
    country, scenario_id, run_id,
    decision_time::DateTime, data_cutoff_at::DateTime, generated_at::DateTime,
    parameter_set_id, calibration_id, calibration_version, code_commit_sha,
    shock::Symbol = :demand, shock_size::Float64 = 0.0, model_period_index::Int = 1,
    horizons::AbstractVector{<:AbstractString} = ["P3M", "P1Y"],
    calibration_kind::Symbol = :fixture, purpose::Symbol = :comparison,
    model_version = "0.1.0", solver_id = "dme.new_keynesian.msv",
    solver_version = "1.0.0", solver_method = "minimum_state_variable_linear_solution",
    input_snapshot::InputSnapshot = InputSnapshot(; snapshot_id="no-external-input", snapshot_kind=:none),
) -> RealRateModelArtifact

# atomic 保存・読み込み（RFC 8785 正準 JSON、ADR 006 §6 のファイル名規約）
save_real_rate_model_artifact(a::RealRateModelArtifact, base_dir::AbstractString) -> String
load_real_rate_model_artifact(path::AbstractString) -> RealRateModelArtifact

# 正準化・hash（RFC 8785 JSON Canonicalization Scheme の限定実装）
canonical_json_bytes(value) -> Vector{UInt8}
canonical_json_string(value) -> String
sha256_hex_of_canonical(value) -> String

# シリアライズ（既存 to_dict/to_json 慣行に準拠）
to_dict(a::RealRateModelArtifact) -> Dict{String,Any}
to_json(a::RealRateModelArtifact) -> String
real_rate_model_artifact_from_dict(d::AbstractDict) -> RealRateModelArtifact
real_rate_model_artifact_from_json(s::AbstractString) -> RealRateModelArtifact
```

> `shock_size == 0.0`（既定）のときは `output_kind=:steady_state`。`horizons` は
> `"P3M"`（`aggregation=:one_step_ahead`）・`"P1Y"`（4四半期の年率換算値の
> `arithmetic_mean`）のみサポートし、5Y/10Y term structure は生成しない。
> `artifact_id`/`parameter_hash`/`calibration_hash`/`snapshot_hash` は各型が自前で計算し、
> コンストラクタの引数として渡すことはできない。`model_implied_real_policy_rate` の値は
> 構築時に `nominal_policy_rate - expected_inflation`（許容誤差 `1e-9`）で自己検証される。
> `decision_time`/`data_cutoff_at`/`generated_at` は UTC 固定（MVP 制約、[ADR 0008 §3](adr/0008-real-rate-model-artifact-export.md)）。

```julia
m = NewKeynesianModel(1.0, 0.02, 0.99, 0.1, 1.5, 0.5, 0.02, 0.8, 0.5, 0.5)
a = real_rate_model_artifact(m;
    country = "US", scenario_id = "baseline", run_id = "nk-us-001",
    decision_time = DateTime(2026, 7, 27, 9, 0, 0),
    data_cutoff_at = DateTime(2026, 7, 26, 23, 0, 0),
    generated_at = DateTime(2026, 7, 27, 9, 5, 0),
    parameter_set_id = "p1", calibration_id = "fixture-v1", calibration_version = "1.0.0",
    code_commit_sha = "0"^40,
)
path = save_real_rate_model_artifact(a, "artifacts")
b = load_real_rate_model_artifact(path)
b.artifact_id == a.artifact_id  # true（hash 再検証を通過）
```

### 実データ型

外部マクロデータを DME 内で統一的に扱う標準データ型。

```julia
@enum DataFrequency Annual Quarterly Monthly

struct DataSeries
    id::String                            # 系列識別子 (例: "FRED_GDPC1")
    name::String                          # 人間可読な系列名
    source::String                        # データ出所 (例: "FRED", "e-Stat", "BOJ")
    frequency::DataFrequency              # 観測頻度 (Annual / Quarterly / Monthly)
    unit::String                          # 単位
    dates::Vector{String}                 # 日付ラベル
    values::Vector{Union{Float64,Missing}} # 観測値。欠損値は missing
    metadata::Dict{String,Any}            # 追加メタデータ
end

# コンストラクタ（キーワード引数）
DataSeries(; id, name, source, frequency, unit, dates, values, metadata=Dict())

# ユーティリティ
series["2020-Q1"]         # 日付ラベルで値を取得
haskey(series, "2020-Q1") # 日付の存在確認
length(series)            # 観測点数
nonmissing_values(series) # 欠損を除いた Vector{Float64}
missing_count(series)     # 欠損値の個数

struct MacroDataset
    name::String                   # データセット名
    series::Dict{String,DataSeries} # id → DataSeries のマップ
end

# コンストラクタ
MacroDataset(name)                          # 空データセット
MacroDataset(name, series_list::Vector{DataSeries})  # ベクタから一括作成

# ユーティリティ
push!(dataset, series)         # DataSeries を追加（同一 id は上書き）
get_series(dataset, id)        # id で DataSeries を取得（なければ KeyError）
series_ids(dataset)            # 利用可能な系列 id リスト -> Vector{String}
haskey(dataset, id)            # id の存在確認
length(dataset)                # 系列数
```

**使用例**:

```julia
s = DataSeries(
    id        = "FRED_GDPC1",
    name      = "Real GDP",
    source    = "FRED",
    frequency = Quarterly,
    unit      = "Billions of Chained 2017 Dollars",
    dates     = ["2020-Q1", "2020-Q2", "2020-Q3"],
    values    = [19254.0, 17302.0, 18638.0],
)

s["2020-Q1"]    # 19254.0
length(s)       # 3

ds = MacroDataset("US Macro")
push!(ds, s)
get_series(ds, "FRED_GDPC1").name  # "Real GDP"
```

**`DataSeries` と `SimulationResult` の変換方針**については
[`docs/data/data_series_guide.md`](../data/data_series_guide.md) を参照。

---

### Keen 実証データセット

Keen モデルの状態変数 `ω`・`λ`・`d` と外生金利 `r` を実データ（FRED fixture/live/rest_api）から
取得・単位変換・四半期整列し、キャリブレーション/検証にそのまま使える構造化データセットへまとめる
読み取り専用層。観測方程式・時間軸契約・識別戦略の設計は
[Keen モデル 実証化戦略](models/keen_empirical_strategy.md)（決定記録 [ADR 0004](adr/0004-keen-empirical-calibration-strategy.md)）。

```julia
# 1 系列の観測方程式・単位変換・四半期化方式・妥当域
struct KeenSeriesSpec
    variable::Symbol       # :ω / :λ / :d / :r
    source_id::String      # 例 "CRDQUSAPABIS"（DataSeries.id は "FRED_<source_id>"）
    conversion::Symbol     # :ratio_from_percent / :employment_from_unrate / :identity_ratio
    aggregation::Symbol    # 月次→四半期: :mean / :sum / :end（四半期系列では無視）
    domain_lo::Float64     # 変換後の妥当域（clamp せず域外は invalid）
    domain_hi::Float64
    forbid_index::Bool     # 指数 unit の水準シェア誤用を拒否
end

# 純粋関数（観測方程式・単位変換・妥当域検証）
keen_convert_value(spec, v)   # v/100・1-v/100・v。missing/非有限は 0埋めせず伝播
keen_value_valid(spec, v)     # 有限かつ domain 内なら true（clamp しない）

# 国別設定（モデル本体から分離）
struct KeenEmpiricalDataConfig
    country::String
    omega::KeenSeriesSpec; lambda; debt; rate
    sample_start::Union{String,Nothing}; sample_end  # nothing で共通期間から自動
    min_valid_obs::Int                                # 下回れば明示的に失敗
    r_mode::Symbol                                    # :sample_mean / :start / :fixed
    r_fixed::Float64
    validation_split::Union{Float64,String}           # 末尾比率 or 分割点四半期
    methodology_version::String
end
keen_us_default_config(; kwargs...)  # 米国 MVP 既定（ω は指数を拒否）

# 構築（元データは無変更で派生 dataset を返す）
build_keen_empirical_dataset(config; client=FredClient(), retrieved_at=nothing)  # fixture/live/rest_api 共通契約
build_keen_empirical_dataset(config, dataset::MacroDataset; mode=:provided, retrieved_at=nothing)

struct KeenEmpiricalDataset
    config
    dates::Vector{String}                # 共通四半期軸（日付 intersection・時間順）
    observation_times::Vector{Float64}   # 年単位・先頭 0.0・Δ=0.25（欠損は間隔に反映）
    ω; λ; d; r::Vector{Float64}          # モデル単位へ変換・整列済み
    initial_state::NamedTuple            # (ω0, λ0, d0)
    r_param::Float64                     # r_mode に基づく固定金利
    calibration_indices; validation_indices::Vector{Int}  # 重複・look-ahead なし
    provenance::Dict{Symbol,KeenSeriesProvenance}         # source/mode/元unit/変換式/aggregation/採用期間
    dropped_dates::Vector{String}; quality_flags::Dict    # 欠損/invalid の追跡
    source_dataset::MacroDataset; metadata::Dict
end
```

**使用例**:

```julia
client = FredClient(mode=:fixture, fixture_dir="test/fixtures/keen")
ds = build_keen_empirical_dataset(keen_us_default_config(); client=client)
ds.initial_state          # (ω0=..., λ0=..., d0=...)  Keen simulate の初期値
ds.observation_times      # [0.0, 0.25, 0.5, ...]
ds.provenance[:d]         # 系列 d の source/変換式/採用期間
```

---

### Keen 限定キャリブレーション（ODE residual）

`KeenEmpiricalDataset`（上記）を入力に、固定パラメータと推定対象を明示的に分離して行動
パラメータの最小集合だけを推定する読み取り専用の後処理層。観測状態の前進差分（`Δt=0.25`）と
`keen_rhs` の残差を方程式単位で最小化する（ODE residual 方式）。`KeenModel`・`keen_rhs`・
`steady_state` は無変更。方式・識別戦略の詳細は
[Keen モデル 実証化戦略 §5](models/keen_empirical_strategy.md)（決定記録 [ADR 0004](adr/0004-keen-empirical-calibration-strategy.md)）。

```julia
const KEEN_CALIBRATION_METHODOLOGY_VERSION = "keen-calibration/1.0.0"
const KEEN_LITERATURE_PARAMS  # Grasselli & Costa Lima (2012) 文献 default（α..κ2）
keen_literature_params()      -> Dict{Symbol,Float64}

struct KeenCalibrationConfig
    estimated_params::Vector{Symbol}          # 既定 [:φ0,:φ1,:κ0,:κ1]（κ2 は固定推奨）
    fixed_params::Dict{Symbol,Float64}        # α,β,δ,ν,r と非推定の行動パラメータを網羅
    fixed_basis::Dict{Symbol,Symbol}          # :data / :literature / :assumption
    bounds::Dict{Symbol,Tuple}                # 正値制約は下限>0 で表現（φ1,κ1,κ2）
    initial_guess::Dict{Symbol,Float64}
    weight_mode::Symbol                        # :std_normalize（既定）/ :fixed / :none
    use_calibration_split::Bool                # true で calibration_indices のみ（look-ahead 回避）
    difference_scheme::Symbol                  # :forward
    optimizer::Symbol; max_iterations; tol     # :nelder_mead（自前・決定的）
    n_starts::Int; seed::Int; start_perturbation  # multi-start
    boundary_atol; nonunique_obj_rtol; nonunique_param_rtol; weak_param_rtol; sensitivity_step
    invalid_penalty::Float64                   # 良い均衡が定義できない候補への penalty
    methodology_version::String
end

# r を dataset.r_param（:data）から取り込み、α,β,δ,ν,κ2 を文献値で固定した米国既定設定
keen_default_calibration_config(dataset; kwargs...) -> KeenCalibrationConfig

calibrate_keen(dataset::KeenEmpiricalDataset, config) -> KeenCalibrationResult

struct KeenCalibrationResult
    model::KeenModel                           # calibrated（固定値は不変）
    estimated; fixed::Dict{Symbol,Float64}
    objective_value::Float64                   # 総値
    objective_contributions::Dict{Symbol}      # 方程式別 :ω/:λ/:d 寄与
    converged::Bool; iterations::Int
    n_obs_used; n_obs_excluded::Int; excluded_reasons  # 欠損/非連続/状態域逸脱
    weights_used::Dict{Symbol,Float64}
    adopted_start::Int; starts::Vector{KeenCalibrationStart}
    boundary_hits::Vector{Symbol}              # bounds へ張り付いた推定値の warning
    weak_identification; nonunique_solutions::Bool; alternative_solutions
    sensitivity::Dict{Symbol,Float64}          # objective 曲率近似（分散推定ではない）
    standard_errors_supported::Bool            # 本 version は false（Hessian 推論未対応）
    literature_objective::Float64; literature_params  # literature vs calibrated 比較用
    predicted; observed::Dict{Symbol,Vector}; pair_times  # 有効ペアの予測/観測 state 差分
    dataset_metadata::Dict{String,Any}         # 系列 ID・期間・measurement version（再現用）
    methodology_version::String; metadata
end

# 保存・読込（再現に必要な公開設定のみ。optimizer 内部状態は保存しない）
save_keen_calibration(path, result)           # 結果を JSON へ
save_keen_calibration_config(path, config)    # 設定を JSON へ
load_keen_calibration_config(path)  -> KeenCalibrationConfig  # 結果 JSON の "config" 配下も可
keen_calibration_config_to_dict / _from_dict / keen_calibration_to_dict
```

**使用例**:

```julia
ds  = build_keen_empirical_dataset(keen_us_default_config();
          client = FredClient(mode=:fixture, fixture_dir="test/fixtures/keen"))
cfg = keen_default_calibration_config(ds)          # φ0,φ1,κ0,κ1 を推定・r は data 固定
res = calibrate_keen(ds, cfg)

res.estimated                     # Dict(:φ0=>..., :φ1=>..., :κ0=>..., :κ1=>...)
res.objective_value - res.literature_objective   # literature default との fit 差
res.boundary_hits                 # bounds 到達（識別上の注意）
res.weak_identification           # 弱識別・非一意解の warning

save_keen_calibration_config("cfg.json", cfg)      # 保存
cfg2 = load_keen_calibration_config("cfg.json")    # 読込 → 同じ fixture で再実行すると一致
```

> **注意（fit ≠ 因果・危機確率）**: 推定値は近似対応する集計系列への当てはめであり、
> 因果パラメータ・普遍定数・危機発生確率ではない。標準誤差（Hessian ベースの統計推論）は
> 本 methodology version では未対応で、`sensitivity` は objective の曲率近似（分散推定ではない）。
> 詳細は [実証化戦略 §8](models/keen_empirical_strategy.md) と [ADR 0004](adr/0004-keen-empirical-calibration-strategy.md)。

---

### Keen 実証バリデーション・感応度分析

`calibrate_keen`（推定層）・`simulate`（RK4 積分）・`minsky_diagnostics_summary`（診断層）を
組み合わせ、Keen モデルの実証結果を **in-sample / out-of-sample・literature vs calibrated・
方向性/転換点/regime 遷移・診断仮定感応度**の観点で構造化して返す読み取り専用の後処理層。
`KeenModel`・`KeenEmpiricalDataset`・`KeenCalibrationResult` は変更しない。設計は
[実証化戦略 §6](models/keen_empirical_strategy.md)。

```julia
const KEEN_VALIDATION_METHODOLOGY_VERSION = "keen-validation/1.0.0"
const KEEN_VALIDATION_CAVEATS  # fit ≠ 因果/危機確率/投資助言 等の固定注意文言

struct KeenVariableMetrics      # 変数別 metric（RMSE/MAE/correlation/bias/direction/turning point/標準化）
struct KeenSensitivityScenario  # base への上書き（dataset / calibration_config / regime_config）
KeenSensitivityScenario(; name, kind, dataset=nothing, calibration_config=nothing,
                          regime_config=nothing, note="") -> KeenSensitivityScenario
#   kind ∈ (:amortization_rate,:rate_method,:wage_share_proxy,:calibration_sample,
#           :initial_guess,:variable_weight,:custom)

struct KeenValidationConfig
    calibration_config::KeenCalibrationConfig
    regime_config::FinancingRegimeConfig
    comparison_models::Vector{Symbol}       # ⊆ [:literature,:calibrated]
    initial_state_modes::Vector{Symbol}     # ⊆ [:observed_start,:calibration_continued]
    eval_variables::Vector{Symbol}          # ⊆ [:ω,:λ,:d]
    metrics::Vector{Symbol}
    sensitivity_scenarios::Vector{KeenSensitivityScenario}
    substeps_per_year::Int                  # 予測 RK4 の年あたりステップ数（既定 4）
    guard_max::Float64; methodology_version::String
end
keen_default_validation_config(dataset; calibration_config=..., regime_config=...,
                                real_rate_spread=0.02, kwargs...) -> KeenValidationConfig

validate_keen(dataset::KeenEmpiricalDataset, config) -> KeenValidationResult

struct KeenPeriodEvaluation     # (model × period × init_mode) の観測/予測系列と変数別 metric
struct KeenRegimeComparison     # observed / literature / calibrated の MinskyDiagnosticsSummary
struct KeenSensitivityResult    # base を含むシナリオ別の推定値・fit・regime・遷移・発散
struct KeenTrajectoryBundle     # observed/literature/calibrated の full-sample 系列（同一時間軸、可視化用）
struct KeenValidationResult
    config; calibration_result::KeenCalibrationResult
    evaluations::Vector{KeenPeriodEvaluation}
    regime_comparison::KeenRegimeComparison
    sensitivity::Vector{KeenSensitivityResult}
    trajectories::KeenTrajectoryBundle      # 可視化層はこれを読むだけ（再計算しない）
    split_info::Dict; calibrated_worse_than_literature::Bool
    warnings::Vector{String}; caveats::Vector{String}
    dataset_metadata::Dict; methodology_version::String; metadata::Dict
end

# 保存（metric 等の非有限値 NaN/Inf は JSON null。0 化しない）
keen_validation_to_dict(result) -> Dict            # JSON 化可能な要約（生系列・dataset は含めない）
save_keen_validation(path, result) -> path

# 機械可読な統合レポート（dataset provenance + 検証要約 + artifact パス。秘密情報は含めない）
keen_empirical_report(dataset, result; mode=nothing, artifact_paths=String[]) -> Dict
save_keen_empirical_report(path, dataset, result; mode=nothing, artifact_paths=String[]) -> path

# 実証比較可視化（KeenValidationResult を読むだけ。欠損・発散後は補間・0化せず線を途切れさせる）
plot_keen_empirical_trajectories(result; variables=[:ω,:λ,:d], combine=true, kwargs...)  # observed vs literature vs calibrated
plot_keen_regime_comparison(result; kwargs...)                                            # observed proxy / literature / calibrated の regime timeline（3段）
plot_keen_sensitivity(result; metric=:peak_debt_ratio, kwargs...)                         # 感応度シナリオ別スカラー棒グラフ
```

**使用例**:

```julia
ds   = build_keen_empirical_dataset(keen_us_default_config();
           client = FredClient(mode=:fixture, fixture_dir="test/fixtures/keen"))
vcfg = keen_default_validation_config(ds)          # amort 3値・実質金利代理・init guess・weight 感応度を既定装備
res  = validate_keen(ds, vcfg)

res.evaluations                        # literature/calibrated × in_sample/out_of_sample × init_mode
res.calibrated_worse_than_literature   # calibrated が literature より悪化したか（隠さない）
res.regime_comparison.observed_summary.first_ponzi_time   # observed proxy の Ponzi 初到達（集計代理）
res.sensitivity[1].estimated           # base 推定値。amort シナリオは reused_base_calibration=true で同一
res.warnings                           # 発散・弱識別・境界張り付き・validation 空 等
res.trajectories                       # observed/literature/calibrated の full-sample 系列（可視化用）

# 可視化（ヘッドレスは ENV["GKSwstype"]="nul"）
p1 = plot_keen_empirical_trajectories(res)               # ω/λ/d の observed vs literature vs calibrated
p2 = plot_keen_regime_comparison(res)                    # regime timeline 3段比較
save_keen_validation("val.json", res)                    # 決定的（同一 ds・config で同一結果）
save_keen_empirical_report("report.json", ds, res; mode=:fixture,
                           artifact_paths=["p1.png"])    # 統合レポート（秘密情報を含めない）
```

fixture/live/rest_api の全フロー（データ→推定→検証→感応度→可視化→レポート）を 1 本で完走する
統合デモは [`examples/keen_empirical_demo.jl`](../examples/keen_empirical_demo.jl)
（取得モードは `DME_DATA_MODE`、出力先は `KEEN_DEMO_OUTDIR`）。

> **注意（実証 fit の限界）**: 実証 fit は因果関係・危機発生確率・将来予測精度と同一ではない。
> observed proxy regime は集計系列への操作的定義の代理であり企業別実測分類ではない。
> `amortization_rate` 等の診断仮定は作業仮定であり、regime 判定はその仮定に依存する。
> 実証層では単一 pass/fail 閾値を課さず、成功・失敗・限界を metric・`warnings`・`caveats` として返す。
> 詳細は [実証化戦略 §6・§8](models/keen_empirical_strategy.md) と [ADR 0004](adr/0004-keen-empirical-calibration-strategy.md)。

---

### Keen 実証 AI コンテキスト（`KeenEmpiricalContext`）

Keen 実証層の成果物を、認識論的性質（観測 / 測定 / 推定 / モデル出力 / 診断proxy / 感応度 / 限界）を
混同せずに LLM へ渡すための `AnalysisContext` 拡張。全主張を安定 source ID（`EvidenceSource`）へ
結び付ける。契約は [ADR 0005](adr/0005-keen-ai-explanation-contract.md)、型の詳細は
[AnalysisContext 設計 §2.1](architecture/analysis_context.md)。

```julia
# 実証層成果物から生成する主 adapter（再計算せず写像。非有限は 0 化せず null）
KeenEmpiricalContext(dataset::KeenEmpiricalDataset, result::KeenValidationResult;
                     mode=nothing, prompt_version=KEEN_AI_PROMPT_VERSION) -> KeenEmpiricalContext

# AnalysisContext の optional field として添付（既存 API・explain_result は無変更）
AnalysisContext(m, result; keen_empirical=nothing, kwargs...)

to_dict(ctx::KeenEmpiricalContext)          # JSON 化可能な Dict（未実施 section は nothing/空）
to_compact_dict(ctx::KeenEmpiricalContext)  # observed の生系列を落としたトークン節約版
```

公開型: `KeenEmpiricalContext`・`EvidenceSource`・`ExplanationWarning`・`AnalysisScope`・
`ObservedSeriesSummary`・`MethodologySummary`・`CalibrationSummary`・`ModelOutputSummary`・
`ValidationSummary`（`ValidationEvaluationSummary`・`ValidationVariableFit`）・
`RegimeDiagnosticSummary`・`SensitivitySummary`・`LimitationSummary`。
定数: `KEEN_AI_CONTEXT_CONTRACT_VERSION`・`KEEN_AI_PROMPT_VERSION`・`KEEN_EVIDENCE_CATEGORIES`。

```julia
kctx = KeenEmpiricalContext(ds, res; mode=:fixture)
actx = AnalysisContext(model, sr; keen_empirical=kctx)
to_dict(actx)["keen_empirical"]["sources"]   # source registry（category 別に根拠を分離）
```

> **注意**: 推定値を因果パラメータ・普遍定数と断定しない。in/out-of-sample fit を妥当性・予測保証へ
> 昇格させない。observed proxy regime をモデル内生 regime と同一視しない。warning severity が
> 該当 section の解釈可否を規定する（ADR 0005 §5・§6）。

---

### Keen 実証結果の根拠付き説明API（`explain_keen_empirical_result`）

`KeenEmpiricalContext` を持つ `AnalysisContext` から、認識論的性質を分離した構造化説明を生成する。
必須 section・source 参照・warning・免責を常に含み、provider 未接続でも決定的に動作する。契約は
[ADR 0005 §4〜§9](adr/0005-keen-ai-explanation-contract.md)。

```julia
# prompt 生成（provider 呼び出しから分離。keen_empirical が nothing なら ArgumentError）
build_keen_empirical_prompt(ctx::AnalysisContext; audience=:analyst, detail=:standard) -> String

# 構造化説明（provider=nothing なら決定的生成。provider 指定時は応答を検証し parsed/fallback）
explain_keen_empirical_result(ctx::AnalysisContext;
    audience=:analyst, detail=:standard, provider=nothing,
    max_tokens=3000, temperature=0.2) -> KeenEmpiricalExplanationOutput

# provider raw 応答（JSON）を検証。成功で :parsed 出力、失敗で nothing（呼び出し側が fallback）
parse_keen_empirical_response(raw, kctx::KeenEmpiricalContext;
    audience=:analyst, detail=:standard, prompt="") -> Union{KeenEmpiricalExplanationOutput, Nothing}

to_dict(out::KeenEmpiricalExplanationOutput)   # section を表示順で保持した JSON 化可能な Dict
to_json(out::KeenEmpiricalExplanationOutput)
```

`KeenEmpiricalExplanationOutput` は次を常に持つ（順序は ADR 0005 §4.3）:
`executive_summary`・`analysis_scope`・`observed_evidence`・`measurement_and_transformations`・
`calibration_interpretation`・`validation_assessment`・`regime_assessment`・
`sensitivity_and_robustness`・`interpretation_scope`・`limitations_and_alternatives`（各 `ExplanationSection`）、
`source_references`・`reproducibility`・`warnings`・`disclaimer`・`generation_status`
（`:deterministic` / `:parsed` / `:fallback`）・`contract_version`（`keen-ai-output/1.0.0`）。

各 `ExplanationSection` は `status`（`:available` / `:not_available` / `:insufficient_evidence`）・
`claims::Vector{EvidenceClaim}`・`missing_fields` を持つ。`EvidenceClaim` は `epistemic_status`
（`observed` / `measured` / `estimated` / `simulated` / `diagnostic` / `sensitivity` / `limitation`）と
1 件以上の `source_ids`（registry 登録済・category と整合）・`qualifiers` を持つ。

```julia
kctx = KeenEmpiricalContext(ds, res; mode=:fixture)
actx = AnalysisContext(model, sr; keen_empirical=kctx)

out = explain_keen_empirical_result(actx)          # provider 未接続 → :deterministic
out.calibration_interpretation.status              # :available / :insufficient_evidence
out.source_references                              # claim から参照された EvidenceSource のみ

# 実 provider を使う場合（応答が検証を通れば :parsed、失敗すれば安全な :fallback）
out2 = explain_keen_empirical_result(actx; provider=create_provider())
```

> **注意**: warning の severity=`error`/`blocking` が該当 section を `insufficient_evidence` にし、
> 肯定的解釈 claim を抑止する（値の存在は qualifier 付きで報告）。`blocking` warning がある場合は
> provider を呼ばず fallback にする。provider 応答は JSON parse・必須 section・source registry・
> category/status 整合を検証し、いずれか失敗で `parser failure` warning 付き決定的 fallback へ落ちる。
> 公開型: `KeenEmpiricalExplanationOutput`・`ExplanationSection`・`EvidenceClaim`。
> 定数: `KEEN_AI_OUTPUT_CONTRACT_VERSION`・`KEEN_EPISTEMIC_STATUSES`・`KEEN_SECTION_STATUSES`・
> `KEEN_OUTPUT_SECTION_ORDER`。

---

### クロスモデル推論（`explain_cross_model_comparison`）

Keen 実証結果と既存マクロモデルの比較を、モデル間の概念対応（`ModelConceptMapping`）を明示した
うえで根拠付きに説明する。同名変数でも定義が異なれば同一視せず、比較不能な項目は
`insufficient_comparability` として統合しない。モデルの性質は `MODEL_CONCEPT_REGISTRY`
（docs 由来の repository metadata）のみを根拠とする。契約は
[ADR 0006](adr/0006-cross-model-reasoning-contract.md)、設計は
[クロスモデル推論層の設計](architecture/cross_model_reasoning.md)。

```julia
# repository metadata registry（(model, concept) の絞り込み）
model_concept_coverage(; model=nothing, concept=nothing) -> Vector{ModelConceptCoverage}

# 2 coverage → 概念対応（equivalent / proxy / partial / incompatible を保守的に導出）
derive_concept_mapping(a::ModelConceptCoverage, b::ModelConceptCoverage) -> ModelConceptMapping

# 比較コンテキスト（registry を (models × concepts) で絞り込み、mapping・source・warning を生成）
build_cross_model_comparison_context(; models::Vector{Symbol},
    concepts=collect(CROSS_MODEL_CONCEPTS), empirical=nothing,
    model_metadata=Dict{Symbol,ModelMetadata}()) -> CrossModelComparisonContext

# 全 mapping が incompatible で比較不能な概念
insufficient_comparability_concepts(ctx::CrossModelComparisonContext) -> Vector{Symbol}

# prompt 生成（provider 呼び出しから分離）
build_cross_model_prompt(ctx::CrossModelComparisonContext; audience=:analyst, detail=:standard) -> String

# 構造化推論（provider=nothing なら決定的生成。provider 指定時は応答を検証し parsed/fallback）
explain_cross_model_comparison(ctx::CrossModelComparisonContext;
    audience=:analyst, detail=:standard, provider=nothing,
    max_tokens=3500, temperature=0.2) -> CrossModelReasoningOutput

# provider raw 応答（JSON）を検証。成功で :parsed、失敗で nothing（呼び出し側が fallback）
parse_cross_model_response(raw, ctx::CrossModelComparisonContext;
    audience=:analyst, detail=:standard, prompt="") -> Union{CrossModelReasoningOutput, Nothing}

to_dict(ctx) / to_json(ctx) / to_dict(out) / to_json(out)
```

`CrossModelReasoningOutput` は次の section を表示順で常に持つ（ADR 0006 §6）:
`executive_summary`・`comparison_scope`・`concept_mappings`・`mechanisms_by_model`・
`consistent_observations`・`divergent_conclusions`・`empirical_support`・
`incomparable_or_insufficient`・`next_evidence`・`limitations`（各 `ExplanationSection`）、
`source_references`・`reproducibility`・`warnings`・`disclaimer`・`generation_status`
（`:deterministic` / `:parsed` / `:fallback`）・`contract_version`（`cross-model-output/1.0.0`）。

section status は `:available` / `:not_available` / `:insufficient_comparability`。claim の
`epistemic_status` は `metadata`（coverage）・`mapping`（概念対応）・`empirical`（実証結果）・
`comparative`（合成観察）・`limitation`（限界）。`metadata`/`mapping`/`empirical` の claim は
対応 category の source のみ、`comparative`/`limitation` の合成 claim は複数 category を参照できる。

```julia
# 民間債務は Keen のみ内生 → 全 mapping incompatible → insufficient_comparability
ctx = build_cross_model_comparison_context(; models=[:keen, :rbc, :islm])
out = explain_cross_model_comparison(ctx)              # provider 未接続 → :deterministic
out.concept_mappings.claims                            # equivalent/proxy/partial/incompatible の明示
insufficient_comparability_concepts(ctx)              # [:private_debt_credit]

# Keen 実証結果を渡すと empirical_support が available になる
ctx2 = build_cross_model_comparison_context(; models=[:keen, :rbc], empirical=kctx)
out2 = explain_cross_model_comparison(ctx2; provider=create_provider())
```

> **安全性**（ADR 0006 §7）: 同名変数の定義差は `DEFINITION_MISMATCH` warning で明示し `equivalent`
> としない。fit の単純比較は `FIT_COMPARISON_RESTRICTED`（対象系列・期間・自由度・推定方法の一致が
> 必要）で抑止し、実証 fit を持つのは Keen 実証層のみ（`EMPIRICAL_ONLY_FOR_KEEN`）。あるモデルの
> 失敗を別モデルの正しさの証明にしない。
> 公開型: `ModelConceptCoverage`・`ModelConceptMapping`・`CrossModelComparisonContext`・
> `CrossModelReasoningOutput`。定数: `CROSS_MODEL_CONCEPTS`・`CROSS_MODEL_TREATMENTS`・
> `CROSS_MODEL_MAPPING_TYPES`・`CROSS_MODEL_OUTPUT_SECTION_ORDER`・`MODEL_CONCEPT_REGISTRY`・
> `CROSS_MODEL_CONTEXT_CONTRACT_VERSION`・`CROSS_MODEL_OUTPUT_CONTRACT_VERSION`。

---

### モデル能力プロファイル・概念定義 metadata（`model_capabilities` / `concept_definitions`）

各モデルが内生化する部門・金融機構・期待形成・政策変数・対応 API・実証能力を、LLM やクロスモデル
推論が根拠にできる機械可読な repository metadata として提供する。能力を推測で過大申告せず、未対応は
明示的に `false` / `:none` / 空とする。同名変数でも定義が異なれば `definition_key` で非等価と判定する。
既存モデル API（`model_name` / `state_variables` …）は変更しない。設計は
[モデル能力・概念定義 metadata](model_capabilities.md)。

```julia
const MODEL_CAPABILITY_CONTRACT_VERSION = "model-capability/1.0.0"

# 能力プロファイル（モデルインスタンスまたは Symbol を受け付ける）
model_capabilities(model) -> ModelCapabilityProfile
supports_api(p, api)      # api ∈ CAPABILITY_APIS
has_sector(p, sector)     # sector ∈ CAPABILITY_SECTORS
has_instrument(p, instr)  # instr ∈ CAPABILITY_INSTRUMENTS

# 概念定義（変数単位。安定 concept_id は重複しない）
concept_definitions(model) -> Vector{ModelConceptDefinition}
concept_definitions_equivalent(a, b) -> Bool   # definition_key・kind・unit・timing の一致

# JSON round-trip（規約は SFC serialization に準拠）
to_dict(p); to_json(p); model_capability_profile_from_dict(d); model_capability_profile_from_json(s)
to_dict(c); to_json(c); model_concept_definition_from_dict(d); model_concept_definition_from_json(s)

# Phase 4 クロスモデル registry との橋渡し
coverage_concept_definitions(cov::ModelConceptCoverage) -> Vector{ModelConceptDefinition}

p = model_capabilities(:keen)
supports_api(p, :calibration)   # true（実証は Keen のみ）
p.accounting_closure            # :none（SFC は SIM のみ :stock_flow_consistent）
```

> 公開型: `ModelCapabilityProfile`・`ModelConceptDefinition`。registry: `MODEL_CAPABILITY_REGISTRY`
> （`Dict{Symbol,ModelCapabilityProfile}`）・`MODEL_CONCEPT_DEFINITION_REGISTRY`
> （`Vector{ModelConceptDefinition}`）。固定語彙: `CAPABILITY_APIS`・`CAPABILITY_SECTORS`・
> `CAPABILITY_INSTRUMENTS`・`CAPABILITY_ACCOUNTING_CLOSURES`・`CAPABILITY_TREATMENTS`・
> `CAPABILITY_EXPECTATIONS`・`CAPABILITY_EQUILIBRIUM_CONCEPTS`・`CONCEPT_KINDS`・`CONCEPT_TIMINGS`
> ほか。`model_symbol(m)` はインスタンス → 識別子。

---

### Keen–SFC 概念対応・比較レポート（`compare_keen_sfc`）

Keen（Minsky 系）モデルと最小 SIM 型 SFC モデルの概念・機構・会計範囲を比較し、同値・proxy・
部分対応・比較不能を根拠付きで報告する。概念対応は能力プロファイル・概念定義 metadata（#149）を
根拠にし、数値比較の可否は比較 API v2（#150）に委ねる。出力契約は ADR 0006 の
`ModelConceptMapping` / `CrossModelComparisonContext` / `CrossModelReasoningOutput` を再利用する。
解説は [Keen–SFC 概念対応・比較レポート](analysis/keen_sfc_comparison.md)。

```julia
const KEEN_SFC_COMPARISON_CONTRACT_VERSION = "keen-sfc-comparison/1.0.0"

# 概念対応 registry（equivalent/proxy/partial/incompatible × comparable/partial/insufficient/incompatible）
keen_sfc_correspondences(; concept=nothing, mapping_type=nothing, comparability=nothing)
    -> Vector{KeenSFCConceptCorrespondence}

# Phase 4 型（ADR 0006）への写像
keen_sfc_concept_mapping(c::KeenSFCConceptCorrespondence) -> ModelConceptMapping
keen_sfc_concept_mappings(; kwargs...) -> Vector{ModelConceptMapping}

# 構造・問い・ギャップ（すべて決定的）
keen_sfc_mechanism_diff() -> Dict{String,Any}            # 能力 metadata の構造化差分（v2 :mechanism と同一）
keen_sfc_suitable_questions() -> Dict{String,Vector{String}}
keen_sfc_minsky_gaps(; correspondences=KEEN_SFC_CONCEPT_CORRESPONDENCES) -> Vector{String}
keen_sfc_sim_unavailable_indicators() -> Vector{String}  # SIM 出力から生成してはならない指標

# 比較コンテキスト（比較軸 mapping ＋ Keen–SFC 概念対応 ＋ 根拠 source を加算）
build_keen_sfc_comparison_context(; empirical=nothing, accounting_report=nothing,
    model_metadata=Dict{Symbol,ModelMetadata}(),
    correspondences=KEEN_SFC_CONCEPT_CORRESPONDENCES) -> CrossModelComparisonContext

# 比較レポート（LLM は呼ばない）
compare_keen_sfc(; keen_result=nothing, sim_result=nothing, empirical=nothing,
    accounting_report=nothing, period=nothing, allow_period_index=false,
    model_metadata=Dict{Symbol,ModelMetadata}(),
    correspondences=KEEN_SFC_CONCEPT_CORRESPONDENCES) -> KeenSFCComparisonReport

# 根拠付き構造化説明（provider=nothing なら決定的生成。失敗時は :fallback）
explain_keen_sfc_comparison(report::KeenSFCComparisonReport; audience=:analyst,
    detail=:standard, provider=nothing, max_tokens=3500, temperature=0.2)
    -> CrossModelReasoningOutput

to_dict(c::KeenSFCConceptCorrespondence) / to_json(c)
to_dict(report::KeenSFCComparisonReport) / to_json(report)
```

`KeenSFCComparisonReport` のフィールド: `shared_concepts`（`equivalent`。現状は空）・
`partial_concepts`（`proxy`/`partial`）・`incomparable_concepts`（`incompatible`）・
`structural_differences`（会計閉鎖・部門・機構の差）・`numeric_comparisons`
（`Dict{String,ComparisonResultV2}`。metric を計算した概念のみ）・`skipped_comparisons`
（不実施の概念・理由・必要な追加証拠）・`suitable_questions`・`minsky_sfc_gaps`・
`required_evidence`・`context`・`warnings`・`provenance`。

```julia
report = compare_keen_sfc()
report.shared_concepts                 # 空（Keen と SIM に厳密に等価な概念は無い）
report.incomparable_concepts           # 民間債務・資金調達区分・賃金シェア・雇用率・会計閉鎖・財政政策 …
report.structural_differences["accounting_closure"]   # ("none" vs "stock_flow_consistent")

# 系列を渡すと comparable/partial な概念だけ metric を返す
report = compare_keen_sfc(; keen_result=keen_sr, sim_result=sim_sr, allow_period_index=true)
keys(report.numeric_comparisons)       # ["aggregate_output"]
report.skipped_comparisons             # 不実施理由と必要な追加モデル・系列・変換

out = explain_keen_sfc_comparison(report)             # :deterministic
out.incomparable_or_insufficient.status               # :insufficient_comparability
```

> **安全性**: `mapping_type=:incompatible` の概念に数値比較レベルを与えられない（コンストラクタが
> `ArgumentError`）。`:equivalent` は両側の `ModelConceptDefinition` が
> `concept_definitions_equivalent` を満たす場合のみ許可する。SIM の政府貨幣 `H`（政府負債）と
> Keen の民間債務 `d` を同一視・集計しない（`DEBT_CONCEPTS_NOT_INTERCHANGEABLE`）。SIM 出力から
> 金融不安定性・分配指標を生成しない（`SIM_NO_FINANCIAL_INSTABILITY`）。会計恒等式に違反がある
> 場合は `SFC_ACCOUNTING_VIOLATION`（severity `:error`）を付す。
> 公開型: `KeenSFCConceptCorrespondence`・`KeenSFCComparisonReport`。定数:
> `KEEN_SFC_CONCEPTS`・`KEEN_SFC_CONCEPT_LABELS`・`KEEN_SFC_CONCEPT_CORRESPONDENCES`・
> `KEEN_SFC_MODELS`・`KEEN_SFC_SOURCE_IDS`・`KEEN_SFC_COMPARISON_CONTRACT_VERSION`。

---

### SFC 会計プリミティブ（Stock-Flow Consistent 標準データ構造）

部門・金融商品・貸借対照表・取引フロー・期別スナップショットを型安全かつ決定的に表現する
標準型（会計恒等式の判定・モデル方程式・可視化・LLM は扱わない。判定は会計検証エンジンが担う）。
安定 ID（`Symbol`）と表示名（`String`）を分離し、sector・instrument・transaction は stable id
昇順へ正準化する。金額は `Float64` で非有限値（NaN/Inf）は拒否せず保持し、JSON では文字列タグへ
符号化して round-trip で失われないようにする。設計は [SFC 統合設計](models/sfc_integration_design.md)・
[ADR 0007](adr/0007-sfc-integration-contract.md)。

```julia
const SFC_CONTRACT_VERSION = "sfc-primitives/1.0.0"
const SFC_SECTOR_TYPES      # (:household,:firm,:government,:bank,:central_bank,:rest_of_world,:other)
const SFC_SIGN_CONVENTIONS  # (:source_use, :receipt_payment)
const SFC_TIME_CONVENTIONS  # (:end_of_period, :during_period)

struct SFCSector           # 会計主体（部門）
    id::Symbol; name::String; sector_type::Symbol; metadata::Dict{String,Any}
end
struct SFCInstrument       # 金融商品（issuers=負債発行部門, holders=資産保有部門。id 昇順）
    id::Symbol; name::String; issuers::Vector{Symbol}; holders::Vector{Symbol}
    unit::String; metadata::Dict{String,Any}
end
struct BalanceSheetMatrix     # 期末ストック（行=instrument, 列=sector。資産+ / 負債−）
    instruments::Vector{Symbol}; sectors::Vector{Symbol}; holdings::Matrix{Float64}
end
struct TransactionFlowMatrix  # 当期フロー（行=取引, 列=sector。源泉+ / 使途−）
    transactions::Vector{Symbol}; sectors::Vector{Symbol}; flows::Matrix{Float64}
end
struct SFCPeriodSnapshot      # 1 期分（valuation_adjustment は同一軸。MVP は全ゼロの独立項）
    period::String; balance_sheet::BalanceSheetMatrix; transaction_flow::TransactionFlowMatrix
    valuation_adjustment::BalanceSheetMatrix; warnings::Vector{String}
end
struct SFCMethodologyMetadata # 契約/モデル版・符号/時点規約・許容誤差・provenance
    contract_version::String; model_version::String
    sign_convention::Symbol; time_convention::Symbol
    tolerance_abs::Float64; tolerance_rel::Float64; provenance::Dict{String,Any}
end
struct SFCResult              # 既存 SimulationResult（任意）と SFC 構造を束ねる
    model_name::String; scenario_name::String
    sectors::Vector{SFCSector}; instruments::Vector{SFCInstrument}
    snapshots::Vector{SFCPeriodSnapshot}
    simulation_result::Union{SimulationResult,Nothing}
    methodology::SFCMethodologyMetadata; warnings::Vector{String}; metadata::Dict{String,Any}
end

# 各型はキーワードコンストラクタを持つ（例）
SFCSector(; id, name, sector_type=:other, metadata=Dict{String,Any}())
SFCResult(; model_name, scenario_name, sectors, instruments, snapshots=SFCPeriodSnapshot[],
          simulation_result=nothing, methodology=SFCMethodologyMetadata(),
          warnings=String[], metadata=Dict{String,Any}())

# 導出量（未知参照は ArgumentError）
holding(bs, instrument_id, sector_id)      # 要素参照
flow_value(tf, transaction_id, sector_id)  # 要素参照
net_worth(bs, sector_id)                   # 列和（非有限は伝播）
total_assets(bs, sector_id)                # 正保有の合計（非有限は除外）
total_liabilities(bs, sector_id)           # 負保有の絶対値合計（非有限は除外）
zero_valuation(bs)                         # 同一軸の全ゼロ評価調整行列

# JSON 往復（安定 ID をキーに決定的出力。非有限は "NaN"/"Inf"/"-Inf" タグへ符号化）
to_dict(x); to_json(x)
sfc_result_from_dict(d); sfc_result_from_json(s)
save_sfc_result(path, r) -> path;  load_sfc_result(path) -> SFCResult
```

> コンストラクタは stable id 昇順への正準化・ID 重複拒否・行列次元不一致拒否・スナップショット行列軸の
> 未知参照拒否（すべて `ArgumentError`）を保証する。**不整合の自動補正・残差の押込みは行わない。**

### SFC 会計恒等式検証エンジン（`validate_sfc_accounting`）

上記プリミティブを入力に、貸借対照表・取引フロー・ストック更新式の会計恒等式を各期で検証する
**読み取り専用**の後処理層（Minsky 診断層と同じ配置方針）。プリミティブ・モデル方程式・可視化・
LLM 層は変更しない。設計は [SFC 統合設計 §5.3](models/sfc_integration_design.md)・
[ADR 0007 §4-5](adr/0007-sfc-integration-contract.md)。

```julia
const SFC_ACCOUNTING_METHODOLOGY_VERSION = "sfc-accounting/1.0.0"

@enum AccountingCheckStatus acc_pass acc_warning acc_fail acc_invalid
accounting_status_label(s) -> String   # "pass" / "warning" / "fail" / "invalid"

struct AccountingViolation             # 非 pass の検証 1 件（残差と evidence を追跡可能に保持）
    check::Symbol                       # :flow_row_sum / :flow_column_sum / :balance_row_sum /
                                        # :balance_column_sum / :stock_flow /
                                        # :duplicate_period / :period_order / :dimension_change
    period::String
    status::AccountingCheckStatus
    sector::Union{Symbol,Nothing}
    instrument::Union{Symbol,Nothing}
    transaction::Union{Symbol,Nothing}
    residual::Float64
    scale::Float64                      # 許容誤差算出の代表スケール（関与項の有限絶対値の最大）
    tolerance::Float64                  # 実効許容誤差 atol + rtol*scale
    message::String
    evidence::Dict{String,Any}
end

struct AccountingCheckReport
    status::AccountingCheckStatus        # 全検証の最悪深刻度（violations 空なら acc_pass）
    violations::Vector{AccountingViolation}
    checks_performed::Int; checks_passed::Int
    max_abs_residual::Float64            # 有限残差の絶対値の最大
    valid_periods::Vector{String}; invalid_periods::Vector{String}  # 非有限を含む期を invalid
    divergence_time::Union{String,Nothing}  # ストックが非有限になった最初の期
    methodology::SFCMethodologyMetadata
    tolerance_abs::Float64; tolerance_rel::Float64
end

accounting_passed(report) -> Bool        # status === acc_pass

# SFCResult 版（atol/rtol 既定は methodology 由来・上書き可能）
validate_sfc_accounting(r::SFCResult;
    atol = r.methodology.tolerance_abs, rtol = r.methodology.tolerance_rel,
    stock_flow_map = nothing) -> AccountingCheckReport

# 単一 SFCPeriodSnapshot 版（期内検証のみ。stock_flow・構造検証は行わない）
validate_sfc_accounting(snap::SFCPeriodSnapshot;
    atol = 1e-8, rtol = 1e-6) -> AccountingCheckReport
```

検証項目（ADR 0007 §4）と契約:

| 検証名 | 恒等式 |
|---|---|
| `:flow_row_sum` | 取引フロー各行の行和 = 0（すべてのフローに相手方） |
| `:flow_column_sum` | 取引フロー各 sector 列の列和 = 0（部門予算制約） |
| `:balance_row_sum` | 貸借対照表各 instrument 行の行和 = 0（資産＝負債対応） |
| `:balance_column_sum` | 貸借対照表各 sector 列の列和 = 0（純資産バランス行込み） |
| `:stock_flow` | `stock_t − stock_{t-1} = flow + valuation`（連続 2 期） |

> **判定**: `abs(residual) ≤ atol + rtol·scale`。**NaN/Inf は `acc_invalid`** として別扱いにし、会計違反
> （`acc_fail`）や Ponzi へ読み替えない。空行列・0 除算を安全に処理し、**自動補正・辻褄合わせをしない。**
> **符号**: `:source_use`（既定）ではフローがストック変化と逆符号で記録されるため残差 =
> `Δstock + flow − valuation`。純資産バランス行（instrument metadata `"role" ∈ ("balancing","net_worth")`）は
> stock_flow から除外する。stock_flow の instrument→取引 対応は `stock_flow_map`（省略時は規約
> `<instrument>_change`）。`save_sfc_result`→`load_sfc_result` 後も同一 report を得る（決定的）。

```julia
r   = SFCResult(; model_name="SIM", scenario_name="baseline", sectors, instruments, snapshots, methodology)
rep = validate_sfc_accounting(r)
accounting_passed(rep)              # 全恒等式が許容誤差内なら true
rep.violations                     # 非 pass の検証（check・period・residual・evidence 付き）
rep.invalid_periods                # NaN/Inf を含む期
```

---

### SIM 型 SFC モデルの adapter（`sfc_result`）

[`SIMModel`](models/sim_sfc.md) の水準系列を、部門別貸借対照表・取引フロー行列を持つ
[`SFCResult`](#sfc-会計プリミティブstock-flow-consistent-標準データ構造) へ変換し、
全期の会計恒等式検証まで接続する adapter。モデル方程式・会計プリミティブ・会計検証層は変更しない。
設計は [SFC 統合設計 §5.4](models/sfc_integration_design.md)。

```julia
const SIM_SFC_MODEL_VERSION = "sfc-sim/1.0.0"

# 水準系列 NamedTuple（simulate / impulse_response の返り値。必須キー Y,C,YD,T,G,H）から構成
sfc_result(m::SIMModel, series::NamedTuple;
    scenario_name = "baseline", periods = nothing, shock = nothing,
    provenance = Dict(), atol = 1e-8, rtol = 1e-6, validate = true) -> SFCResult

# SimulationResult（必須変数 "Y","C","YD","T","G","H"）から SFC 構造を復元する adapter（§5.4）
sfc_result(sr::SimulationResult;
    scenario_name = sr.scenario_name, periods = nothing, shock = nothing,
    provenance = Dict(), atol = 1e-8, rtol = 1e-6, validate = true) -> SFCResult
```

> **部門**: `:households` / `:production` / `:government`。**金融商品**: `:money`（政府貨幣 H）と
> 列和を 0 にする純資産バランス行 `:net_worth`（`role="net_worth"` で stock_flow から除外）。
> **符号**: `:source_use`（源泉+ / 使途−）。`validate=true`（既定）で全期の
> [`validate_sfc_accounting`](#sfc-会計恒等式検証エンジンvalidate_sfc_accounting) を実行し、集約結果を
> `metadata["accounting_status"]` 等に、違反を `warnings` に構造化して保持する（自動補正なし）。
> `shock` を渡すとショック定義を `metadata["shock"]` に保存。主要系列は `SFCResult.simulation_result`
> に格納され、既存 `plot_result` / `summarize_result` にそのまま乗る。

```julia
m   = SIMModel(; α1=0.6, α2=0.4, θ=0.2, G=20.0)
r   = sfc_result(m, simulate(m, 0.0; T=60))
accounting_passed(validate_sfc_accounting(r))   # baseline は全期 pass
summarize_result(r.simulation_result)           # 埋め込み SimulationResult で既存 API
```

---

### 可視化API

```julia
# SimulationResult の変数系列を時系列プロットとして描画（水準系列向け）
plot_result(result::SimulationResult;
    vars    = nothing,   # String / Symbol 単体か配列。省略時は全変数
    title   = "モデル名 — シナリオ名",
    xlabel  = "Period",
    ylabel  = "",
    kwargs...            # Plots.jl に直接渡す追加オプション
) -> Plots.Plot

# IRF（インパルス応答）をゼロラインつきで描画（対数偏差系列向け）
plot_irf(result::SimulationResult;
    vars       = nothing,   # String / Symbol 単体か配列。省略時は全変数
    shock_size = nothing,   # 数値。タイトルに表示。metadata["shock_size"] も参照
    title      = nothing,   # 省略時: "モデル名 — シナリオ名 (IRF)"
    xlabel     = "Period",
    ylabel     = "Log deviation from steady state",
    kwargs...               # Plots.jl に直接渡す追加オプション
) -> Plots.Plot
```

`plot_result` は水準系列（`transition_path` / `simulate`）、`plot_irf` は対数偏差系列（`impulse_response`）に使用する。
`plot_irf` はゼロライン（定常状態基準）を自動描画し、x 軸はショック発生時点 t=0 始まりで表示する。

**エラー**: 存在しない変数名を指定した場合は `ArgumentError` が発生し、
利用可能な変数名を含むメッセージが表示される。

**例**:

```julia
sr = to_simulation_result(m, simulate(m, K0), "simulate")

plot_result(sr)                              # 全変数
plot_result(sr; vars = "K")                  # 単一変数（String）
plot_result(sr; vars = :K)                   # 単一変数（Symbol）
plot_result(sr; vars = ["K", "C"])           # 複数変数
plot_result(sr; vars = ["K", "C"],
            title = "Ramsey 移行経路",
            xlabel = "Period", ylabel = "Level")

# IRF プロット
m_rbc = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)
irf = impulse_response(m_rbc, 0.01)
sr_irf = to_simulation_result(m_rbc, irf, "technology_shock")

plot_irf(sr_irf)                             # 全変数、ゼロラインつき
plot_irf(sr_irf; vars = ["ŷ", "ĉ", "k̂"])   # 特定変数のみ
plot_irf(sr_irf; vars = "ŷ", shock_size = 0.01)  # ショックサイズをタイトルに表示
```

### Minsky 可視化API（Keen モデル）

`MinskyDiagnosticsResult`/`MinskyDiagnosticsComparison`（上記「Minsky 連続診断指標・サマリー」）を
読み取るだけの可視化専用レイヤー。診断値の再計算は行わない。発散後の `NaN` は
`Plots.jl` の標準挙動どおり線を途切れさせるだけであり、補間・0化・Ponzi帯への混入は行わない。
図の読み方・注意事項の詳細は [Keen モデル §7](models/keen.md#7-ショックシナリオ) を参照。

```julia
# 資金調達区分（unlevered/hedge/speculative/ponzi/invalid）のタイムライン
plot_financing_regimes(diag::MinskyDiagnosticsResult;
    title            = nothing,  # 省略時: 代理診断である旨を含む既定タイトル
    show_transitions = true,     # 区分変化時点（invalid との遷移を含む）に縦線を表示
    kwargs...                    # Plots.jl に直接渡す追加オプション
) -> Plots.Plot

# 金融不安定性連続診断指標の複数パネルプロット
plot_minsky_diagnostics(diag::MinskyDiagnosticsResult;
    panels  = :all,   # :debt_ratio, :burden, :coverage, :margin, :profit_growth の Symbol 配列
    combine = true,   # true: layout で結合した単一 Plots.Plot／false: Vector{Plots.Plot}
    kwargs...         # combine=true のとき Plots.jl に直接渡す追加オプション
) -> Plots.Plot または Vector{Plots.Plot}

# 複数シナリオの比較プロット（同一指標・同一軸）
plot_minsky_scenario_comparison(comparison::MinskyDiagnosticsComparison;
    var    = :debt_ratio,  # :debt_ratio, :interest_coverage_ratio, :debt_service_coverage_ratio,
                            # :ponzi_margin, :hedge_margin, :net_profit_share, :growth_rate, :debt_change
    strict = true,          # true: methodology_version/config 不一致で ArgumentError（比較拒否）
                             # false: 不一致でも @warn のみで比較を続行
    title  = nothing,
    kwargs...
) -> Plots.Plot
```

`plot_financing_regimes` は帯の色に加えてマーカー形状でも区分を識別できる（色覚非依存）。
`invalid`（発散後の `NaN` 埋め・非有限入力）は破線境界・別配色・別ラベルで表示し、
`ponzi` の帯へは混入しない。

`plot_minsky_diagnostics` の `:coverage` パネルには coverage ratio `= 1`（損益分岐点）、
`:margin` パネルには margin `= 0` の境界線が自動的に追加される。coverage ratio が
`Inf`（無借金でデットサービスが 0）になる期間はプロット専用に `NaN` 化してギャップとして
表示する（値そのものは変更しない）。両パネルとも `divergence_time`（発散ガード作動時点）に
縦線を表示する。

`plot_minsky_scenario_comparison` は既定 (`strict=true`) で `methodology_version` または
`config`（`amortization_rate` 等）が異なるシナリオの比較を拒否する。異なる診断設定を
暗黙に重ねて比較しないための安全策であり、意図的な感応度比較を行う場合のみ
`strict=false` を指定する。

**エラー**:

- `diag.observations`/`diag.regime_diagnostics.observations` が空の場合は `ArgumentError`
- `plot_minsky_diagnostics` の `panels` に未知のキーを指定した場合は `ArgumentError`
- `plot_minsky_scenario_comparison` は比較対象が2シナリオ未満、`var` が未知、
  または `strict=true` で診断設定が不一致の場合に `ArgumentError`

**例**:

```julia
m = KeenModel(0.025, 0.02, 0.01, 3.0, 0.03, 0.0400641, 6.41e-5, -0.0065, exp(-5), 20.0)
ss = steady_state(m)

diag_base = minsky_diagnostics(m, simulate(m, ss.ω, ss.λ, ss.d + 0.01; T = 300);
                               scenario_name = "baseline")
diag_high_debt = minsky_diagnostics(m, simulate(m, ss.ω, ss.λ, 5.0; T = 300);
                                    scenario_name = "high_debt")

plot_financing_regimes(diag_high_debt)
plot_minsky_diagnostics(diag_high_debt)                       # 5パネル結合
plot_minsky_diagnostics(diag_high_debt; panels = [:debt_ratio, :margin])

cmp = minsky_diagnostics_comparison(["baseline" => diag_base, "high_debt" => diag_high_debt])
plot_minsky_scenario_comparison(cmp; var = :debt_ratio)
```

統合デモは [`examples/minsky_diagnostics_demo.jl`](../examples/minsky_diagnostics_demo.jl) を参照。

### オプション型

```julia
Base.@kwdef struct SolverOptions
    horizon::Int       = 30
    max_iter::Int      = 1000
    tolerance::Float64 = 1e-8
end

Base.@kwdef struct ValueIterationOptions
    n::Int             = 20      # グリッドサイズ
    a::Float64         = 0.5     # グリッド下限
    b::Float64         = 3.0     # グリッド上限
    max_iter::Int      = 100
    tolerance::Float64 = 0.0001
    itp_type           = ITPCubic
end

Base.@kwdef struct ODESolverOptions
    substeps::Int      = 20      # 1期（1年）あたりの RK4 サブステップ数
    guard_max::Float64 = 1e6     # 発散判定の閾値（状態変数の絶対値上限）
end
```

---

## Internal API 一覧

以下はエクスポートされない内部関数です。`DME.func()` でアクセスできますが、
将来のバージョンで変更・削除される可能性があります。

| 関数 | 役割 | 推奨代替 |
|---|---|---|
| `DME.calc_ep(m)` | 定常状態の解析的計算 | `steady_state(m)` |
| `DME.find_path(m, ...)` | NLsolve による完全予見経路 | `transition_path(m, ...)` |
| `DME.simulate_by_nlvar(m, ...)` | 価値反復法+シミュレーション | `simulate(m, ...)` |
| `DME.solve_by_nlvar(m; opts)` | 価値反復法（ポリシー関数を返す） | 高度な用途専用 |
| `DME.solve_rbc(m)` | 線形化（Blanchard-Kahn 法）の行列計算 | 高度な用途専用 |
| `DME.shock(m, ε)` | インパルス応答の計算 | `impulse_response(m, ε)` |
| `DME.keen_scenario_comparison(m_base, m_scenario)` | Keen モデルのパラメータシナリオ比較（`mf_policy_shock` と同型） | 高度な用途専用 |

---

## 移行ガイド

### `calc_ep` → `steady_state`

```julia
# 旧 (Internal API)
K_star, C_star = DME.calc_ep(m)

# 新 (Public API)
ep = steady_state(m)
ep.K  # K_star に相当
ep.C  # C_star に相当
```

### `find_path` → `transition_path`

```julia
# 旧 (Internal API) — Ramsey
result = DME.find_path(m, K0)
result.K  # 資本系列
result.C  # 消費系列

# 新 (Public API)
result = transition_path(m, K0)
result.K
result.C

# 旧 (Internal API) — RBC (Dict を返す)
result = DME.find_path(m, A0, K0)
result["K"]

# 新 (Public API) — RBC (NamedTuple を返す)
result = transition_path(m, A0, K0)
result.K
```

### `simulate_by_nlvar` → `simulate`

```julia
# 旧 (Internal API)
result = DME.simulate_by_nlvar(m, K0)

# 新 (Public API)
result = simulate(m, K0)
```

### `shock` → `impulse_response`

```julia
# 旧 (Internal API) — Dict を返す
irf = DME.shock(m, 0.01)
irf["ĉ"]

# 新 (Public API) — NamedTuple を返す
irf = impulse_response(m, 0.01)
irf.ĉ
```

---

## 旧 Internal API の移行状況

| 状態 | 内容 |
|---|---|
| 完了 | Public/Internal API の分離。旧関数は `DME.` 修飾でアクセス可能。 |
| 完了 | ソルバー設定（`SolverOptions` / `ValueIterationOptions`）の計算 API への組み込み。 |
| 未着手 | 旧関数（`calc_ep`, `find_path`, `simulate_by_nlvar`, `solve_rbc`, `shock`）への `@deprecated` マーク追加と削除。 |

### 新規モデル追加時のルール

新しいモデル `FooModel` を追加する際は以下を実装すること。

**必須**:
1. `struct FooModel <: AbstractMacroModel`
2. `model_name`, `state_variables`, `control_variables`, `parameters` を実装
3. `steady_state(m::FooModel) -> NamedTuple` を実装
4. テストを `test/runtests.jl` に追加

**推奨**（該当する場合）:
5. `transition_path` を実装（完全予見均衡がある場合）
6. `simulate` を実装（動学シミュレーションがある場合）
7. `impulse_response` を実装（ショック分析がある場合）

**禁止**:
- 共通関数の戻り値に `Dict` を使わない（新APIでは NamedTuple を使うこと）
- `Tuple` の位置依存参照を外部APIとして公開しない
