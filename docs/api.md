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

### Minsky 連続診断指標・サマリー（Keen モデル、Phase 2）

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

重み付き単一複合スコアは Phase 2 では提供しない。`raw` 指標を常に個別に参照し、
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

### Minsky 可視化API（Keen モデル、Phase 2）

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

統合デモは [`examples/minsky_phase2_demo.jl`](../examples/minsky_phase2_demo.jl) を参照。

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
