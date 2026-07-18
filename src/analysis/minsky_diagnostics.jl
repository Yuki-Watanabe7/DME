# minsky_diagnostics.jl: Keen モデル出力から金融不安定性の連続診断指標・構造化診断結果・
# サマリーを生成する読み取り専用の後処理層。
#
# `src/analysis/minsky_regimes.jl`（Hedge/Speculative/Ponzi 区分診断、#112）の契約を再利用し、
# 区分だけでは失われる連続量（マージン・カバレッジ比率・債務変化等）を追加する。
# 詳細な指標定義・契約は docs/models/minsky_diagnostics_summary.md を参照。
# KeenModel の struct・parameters・ODE 動学（keen_rhs 等）はこのファイルの追加によって
# 一切変更されない。

"""
    DivergenceStatus

時系列上の各時点が Keen モデルの発散ガード（[keen.md](../../docs/models/keen.md) §8）に対して
どの状態にあるかを区別する。

- `no_divergence`       : 発散ガード未作動（有効値）
- `divergence_onset`    : 発散ガードが作動した最初の時点（この時点から値は `NaN`）
- `divergence_continued`: 発散後の `NaN` 埋め区間（`divergence_onset` より後）

`regime == invalid`（`FinancingRegime`）と対応するが、`divergence_onset` と
`divergence_continued` を区別することで発散イベントの発生時点を一意に特定できる。
"""
@enum DivergenceStatus no_divergence divergence_onset divergence_continued

"""
    MINSKY_DIAGNOSTICS_METHODOLOGY_VERSION

本ファイル（連続診断指標・サマリー）の methodology version。区分診断そのものの
methodology version（`FinancingRegimeConfig.methodology_version`、既定
`"minsky-regime/1.0.0"`）とは独立に管理する。指標定義・`debt_change` の方式・
`divergence_status` の意味論を変更する場合はこちらを更新する。
"""
const MINSKY_DIAGNOSTICS_METHODOLOGY_VERSION = "minsky-diagnostics/1.0.0"

"""
    MinskyDiagnosticObservation

単一時点の金融不安定性連続診断指標。すべて産出比・年率（Issue #111 §2 と同じ単位系）。

## フィールド
- `time::Int` : 時点（元の時系列のインデックス、1始まり）
- `debt_ratio::Float64` : 民間債務比率 `d`（入力値そのまま。`invalid` 時は `NaN`）
- `operating_surplus_share::Float64` : 営業余剰シェア `1 - ω`
- `net_profit_share::Float64` : 利払い後利潤シェア `π = 1 - ω - r*d`
- `interest_burden::Float64` : 利払い負担 `r * max(d, 0)`
- `principal_commitment_proxy::Float64` : 元本返済負担の代理 `amortization_rate * max(d, 0)`
- `interest_coverage_ratio::Float64` : 利払いカバレッジ比率
  `operating_surplus_share / interest_burden`。`interest_burden == 0.0`（`d ≤ 0`、無借金・
  純貸し手）のときは `Inf`（利払い負担が存在しないため常に賄える）。`ω`・`d`・`r` が
  非有限のときは `NaN`。`0 < d ≤ debt_tolerance`（`unlevered` 域内だが `d` が厳密に 0 でない）
  では `interest_burden` は厳密には非ゼロの微小値になるため、`Inf` ではなく有限の大きな
  値になる（`d ≤ 0` の場合とは区別される）
- `debt_service_coverage_ratio::Float64` : デットサービスカバレッジ比率
  `operating_surplus_share / (interest_burden + principal_commitment_proxy)`。
  分母が厳密に `0.0`（`d ≤ 0`）のときは `Inf`、非有限入力のときは `NaN`
  （`interest_coverage_ratio` と同じ規則）
- `ponzi_margin::Float64` : `operating_surplus_share - interest_burden`（Ponzi境界からの距離）
- `hedge_margin::Float64` : `operating_surplus_share - (interest_burden + principal_commitment_proxy)`
  （Hedge境界からの距離）
- `debt_change::Float64` : 離散系列の前期差分 `debt_ratio[t] - debt_ratio[t-1]`。
  `t == 1`（前期が存在しない）または `t-1` が発散後の場合は `NaN`
- `growth_rate::Float64` : 既存モデル出力 `g`（再計算しない）
- `divergence_status::DivergenceStatus` : 発散ガードに対する状態
- `methodology_version::String` : 本レイヤー（`MINSKY_DIAGNOSTICS_METHODOLOGY_VERSION`）の
  methodology version（provenance）。区分診断の methodology version は `config`
  （`FinancingRegimeConfig.methodology_version`）側で別途保持する

非有限入力（`ω`・`d`・`r` のいずれかが `NaN`/`Inf`）のとき、`debt_ratio`・`growth_rate` 以外の
派生量は明示的に `NaN` になる（`FinancingRegimeObservation` と同様、`ponzi`/`hedge` へ
誤って分類されることはない。カテゴリ判定は `FinancingRegimeDiagnostics` 側が担う）。
"""
struct MinskyDiagnosticObservation
    time::Int
    debt_ratio::Float64
    operating_surplus_share::Float64
    net_profit_share::Float64
    interest_burden::Float64
    principal_commitment_proxy::Float64
    interest_coverage_ratio::Float64
    debt_service_coverage_ratio::Float64
    ponzi_margin::Float64
    hedge_margin::Float64
    debt_change::Float64
    growth_rate::Float64
    divergence_status::DivergenceStatus
    methodology_version::String
end

"""
    MinskyDiagnosticsResult

時系列全体の金融不安定性診断結果。元の `SimulationResult`/`NamedTuple` を複製・変更せず、
派生結果として保持する。

## フィールド
- `model_name::String` : 元のモデル名
- `scenario_name::String` : 元のシナリオ名
- `observations::Vector{MinskyDiagnosticObservation}` : 時点別診断指標（元系列と同じ長さ・順序）
- `regime_diagnostics::FinancingRegimeDiagnostics` : `diagnose_financing_regime` と同一の
  資金調達区分診断（#112 の契約を再利用）
- `config::FinancingRegimeConfig` : 診断に用いた設定（`amortization_rate` 等）
- `methodology_version::String` : 本レイヤーの methodology version
  （`MINSKY_DIAGNOSTICS_METHODOLOGY_VERSION`）
- `valid_periods::Vector{Int}` : `regime_diagnostics.valid_periods` と同一
- `invalid_periods::Vector{Int}` : `regime_diagnostics.invalid_periods` と同一
- `divergence_time::Union{Int, Nothing}` : 発散ガードが作動した最初の時点。発散しなかった
  場合は `nothing`（`0` や最終時点で代用しない）
- `metadata::Dict{String, Any}` : 元のモデルパラメータ等（`"debt_change_method"` キーに
  `debt_change` の算出方式 `"discrete_diff"` を記録する）
"""
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

# 単一時点の連続診断指標を計算する内部コア。ω・d・r のいずれかが非有限のときは
# FinancingRegimeObservation と同様に明示的な分岐で全派生量を NaN にする
# （interest_burden 等は d・r のみに依存するため、NaN 伝播だけに頼ると ω のみ非有限な
# 場合に一部の派生量が有限値のまま残ってしまう）。
function _minsky_diagnostic_observation(
    ω::Float64,
    d::Float64,
    r::Float64,
    g::Float64,
    d_prev::Float64,
    config::FinancingRegimeConfig,
    time::Int,
    divergence_status::DivergenceStatus,
)
    if !isfinite(ω) || !isfinite(d) || !isfinite(r)
        return MinskyDiagnosticObservation(
            time,
            d,
            NaN,
            NaN,
            NaN,
            NaN,
            NaN,
            NaN,
            NaN,
            NaN,
            NaN,
            g,
            divergence_status,
            MINSKY_DIAGNOSTICS_METHODOLOGY_VERSION,
        )
    end

    operating_surplus_share = 1.0 - ω
    net_profit_share = 1.0 - ω - r * d
    interest_burden = r * max(d, 0.0)
    principal_commitment_proxy = config.amortization_rate * max(d, 0.0)
    debt_service = interest_burden + principal_commitment_proxy
    ponzi_margin = operating_surplus_share - interest_burden
    hedge_margin = operating_surplus_share - debt_service

    interest_coverage_ratio =
        interest_burden == 0.0 ? Inf : operating_surplus_share / interest_burden
    debt_service_coverage_ratio =
        debt_service == 0.0 ? Inf : operating_surplus_share / debt_service

    debt_change = isfinite(d_prev) ? d - d_prev : NaN

    MinskyDiagnosticObservation(
        time,
        d,
        operating_surplus_share,
        net_profit_share,
        interest_burden,
        principal_commitment_proxy,
        interest_coverage_ratio,
        debt_service_coverage_ratio,
        ponzi_margin,
        hedge_margin,
        debt_change,
        g,
        divergence_status,
        MINSKY_DIAGNOSTICS_METHODOLOGY_VERSION,
    )
end

# 系列全体から MinskyDiagnosticsResult を組み立てる内部ヘルパー。
# NamedTuple 経路・SimulationResult 経路の双方から共有する。
function _minsky_diagnostics_from_series(
    model_name::String,
    scenario_name::String,
    ω::Vector{Float64},
    d::Vector{Float64},
    r::Float64,
    g::Vector{Float64};
    config::FinancingRegimeConfig,
    metadata::Dict{String, Any},
)
    if length(ω) != length(d) || length(ω) != length(g)
        throw(
            ArgumentError(
                "ω, d, g の長さが一致しません（ω: $(length(ω))、d: $(length(d))、" *
                "g: $(length(g))）",
            ),
        )
    end

    regime_diag = _diagnose_from_series(ω, d, r; config = config)
    divergence_time =
        isempty(regime_diag.invalid_periods) ? nothing : first(regime_diag.invalid_periods)

    n = length(ω)
    observations = Vector{MinskyDiagnosticObservation}(undef, n)
    for t in 1:n
        d_prev = t == 1 ? NaN : d[t - 1]
        divergence_status = if divergence_time === nothing || t < divergence_time
            no_divergence
        elseif t == divergence_time
            divergence_onset
        else
            divergence_continued
        end
        observations[t] = _minsky_diagnostic_observation(
            ω[t],
            d[t],
            r,
            g[t],
            d_prev,
            config,
            t,
            divergence_status,
        )
    end

    merged_metadata =
        merge(metadata, Dict{String, Any}("debt_change_method" => "discrete_diff"))

    MinskyDiagnosticsResult(
        model_name,
        scenario_name,
        observations,
        regime_diag,
        config,
        MINSKY_DIAGNOSTICS_METHODOLOGY_VERSION,
        regime_diag.valid_periods,
        regime_diag.invalid_periods,
        divergence_time,
        merged_metadata,
    )
end

"""
    minsky_diagnostics(m::KeenModel, result::NamedTuple;
                       config::FinancingRegimeConfig = FinancingRegimeConfig(),
                       scenario_name::String = "simulate") -> MinskyDiagnosticsResult

`simulate(m, ...)` / `impulse_response(m, ...)` が返す `NamedTuple`（`:ω`・`:d`・`:g` を含む）から
金融不安定性の連続診断指標と資金調達区分診断をまとめた `MinskyDiagnosticsResult` を生成する。

`m`・`result` を変更しない純粋な診断処理。`diagnose_financing_regime(m, result)` と同一の
`FinancingRegimeDiagnostics` を内部で共有するため、区分の判定結果は完全に一致する。

## 使用例
```julia
m = KeenModel(0.025, 0.02, 0.01, 3.0, 0.03, 0.0400641, 6.41e-5, -0.0065, exp(-5), 20.0)
ss = steady_state(m)
result = simulate(m, ss.ω, ss.λ, 5.0; T = 300)  # 高債務初期値 → 崩壊経路
diag = minsky_diagnostics(m, result)

diag.observations[1].interest_coverage_ratio
diag.divergence_time            # 発散ガード作動時点（発散しなければ nothing）
```
"""
function minsky_diagnostics(
    m::KeenModel,
    result::NamedTuple;
    config::FinancingRegimeConfig = FinancingRegimeConfig(),
    scenario_name::String = "simulate",
)
    if !haskey(result, :ω) || !haskey(result, :d) || !haskey(result, :g)
        throw(
            ArgumentError(
                "result は :ω, :d, :g フィールドを持つ NamedTuple でなければなりません",
            ),
        )
    end
    _minsky_diagnostics_from_series(
        model_name(m),
        scenario_name,
        result.ω,
        result.d,
        m.r,
        result.g;
        config = config,
        metadata = Dict{String, Any}("parameters" => parameters(m)),
    )
end

"""
    minsky_diagnostics(sr::SimulationResult;
                       config::FinancingRegimeConfig = FinancingRegimeConfig()) -> MinskyDiagnosticsResult

`to_simulation_result` 済みの `SimulationResult`（`"ω"`・`"d"`・`"g"` 変数と
`metadata["parameters"].r` を含む）から `MinskyDiagnosticsResult` を生成する。

`NamedTuple` 経路（`minsky_diagnostics(m, result)`）と同一の内部ロジックを共有するため、
同じシミュレーション結果に対しては両経路で同一の診断結果を返す。入力 `sr` は変更しない。

## エラー
- `"ω"`・`"d"`・`"g"` のいずれかが `sr` に存在しない場合は `ArgumentError`
- `sr.metadata["parameters"]` が存在しない、または `r` フィールドを持たない場合は `ArgumentError`
"""
function minsky_diagnostics(
    sr::SimulationResult;
    config::FinancingRegimeConfig = FinancingRegimeConfig(),
)
    if !haskey(sr, "ω") || !haskey(sr, "d") || !haskey(sr, "g")
        throw(
            ArgumentError(
                "SimulationResult は \"ω\", \"d\", \"g\" 変数を持たなければなりません。" *
                "利用可能な変数: $(sort(variable_names(sr)))",
            ),
        )
    end
    if !haskey(sr.metadata, "parameters") || !hasproperty(sr.metadata["parameters"], :r)
        throw(
            ArgumentError(
                "SimulationResult の metadata[\"parameters\"] に r（貸出金利）が必要です",
            ),
        )
    end
    _minsky_diagnostics_from_series(
        sr.model_name,
        sr.scenario_name,
        sr["ω"],
        sr["d"],
        sr.metadata["parameters"].r,
        sr["g"];
        config = config,
        metadata = sr.metadata,
    )
end

"""
    MinskyDiagnosticsSummary

`MinskyDiagnosticsResult` を集約したサマリー。存在しないイベント（区分が到達しない、
発散しない等）は `nothing` で表し、`0` や最終時点で代用しない。

## フィールド
- `model_name`・`scenario_name`・`methodology_version`・`config` : 元の診断結果から引き継ぐ
- `n_periods`・`n_valid`・`n_invalid` : 全観測数・有効観測数・invalid観測数
- `regime_counts::Dict{FinancingRegime, Int}` : 各区分の期間数（`unlevered`/`hedge`/
  `speculative`/`ponzi`/`invalid` の5区分すべてを含む）
- `regime_share_of_valid::Dict{FinancingRegime, Float64}` : `unlevered`/`hedge`/
  `speculative`/`ponzi` は有効期間 `n_valid` に占める比率、`invalid` は全期間 `n_periods` に
  占める比率（`n_valid == 0`/`n_periods == 0` のときは `0.0`）
- `first_speculative_time`・`first_ponzi_time::Union{Int, Nothing}` : 最初にその区分へ
  移行した時点。到達しなければ `nothing`
- `recovery_to_hedge_time::Union{Int, Nothing}` : `speculative`/`ponzi` へ最初に移行した後、
  最初に `hedge` へ回復した時点。一度も `speculative`/`ponzi` に陥っていない、または
  回復しなかった場合は `nothing`
- `peak_debt_ratio`・`peak_debt_ratio_time` : 有効期間内の債務比率の最大値とその時点
- `min_interest_coverage_ratio`・`min_interest_coverage_ratio_time` : 同・最小値
- `min_debt_service_coverage_ratio`・`min_debt_service_coverage_ratio_time` : 同・最小値
- `min_ponzi_margin`・`min_ponzi_margin_time` : 同・最小値
- `min_hedge_margin`・`min_hedge_margin_time` : 同・最小値
- `max_debt_change`・`max_debt_change_time` : 有効な `debt_change`（`t == 1` を除く有効期間）
  の最大値とその時点
- `diverged::Bool` : 発散ガードが作動したか
- `divergence_time::Union{Int, Nothing}` : 発散時点（`diverged == false` なら `nothing`）

上記の `peak_*`・`min_*`・`max_*` 系フィールドは、対応する有効観測が1件も存在しない
（`n_valid == 0` 等）場合に限り値・時点ともに `nothing` になる。
"""
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

# pred(t) を満たす最初の t を返す（indices は昇順を仮定）。なければ nothing。
function _first_time(pred, indices)
    for t in indices
        if pred(t)
            return t
        end
    end
    return nothing
end

# periods（インデックス列）上で f(obs[t]) を最大化する (値, 時点) を返す。
# periods が空なら (nothing, nothing)。同値のときは最初に見つかった時点を採用する。
function _argmax_over(obs, f, periods)
    if isempty(periods)
        return (nothing, nothing)
    end
    best_t = first(periods)
    best_v = f(obs[best_t])
    for t in periods
        v = f(obs[t])
        if v > best_v
            best_v = v
            best_t = t
        end
    end
    return (best_v, best_t)
end

# _argmax_over の最小値版。
function _argmin_over(obs, f, periods)
    if isempty(periods)
        return (nothing, nothing)
    end
    best_t = first(periods)
    best_v = f(obs[best_t])
    for t in periods
        v = f(obs[t])
        if v < best_v
            best_v = v
            best_t = t
        end
    end
    return (best_v, best_t)
end

"""
    minsky_diagnostics_summary(diag::MinskyDiagnosticsResult) -> MinskyDiagnosticsSummary

`MinskyDiagnosticsResult` から regime 滞在比率・最初の悪化時点・peak/minimum・発散時点等を
集約した `MinskyDiagnosticsSummary` を生成する。存在しないイベントは `nothing` で表し、
`0` や最終時点で代用しない。

## 使用例
```julia
diag = minsky_diagnostics(m, result)
summary = minsky_diagnostics_summary(diag)

summary.regime_share_of_valid[hedge]   # Hedge が有効期間に占める比率
summary.first_speculative_time         # 最初に speculative へ移行した時点（nothing なら未到達）
summary.peak_debt_ratio                # 有効期間内の債務比率の最大値
summary.diverged                       # 発散ガードが作動したか
```
"""
function minsky_diagnostics_summary(diag::MinskyDiagnosticsResult)
    obs = diag.observations
    n = length(obs)
    n_valid = length(diag.valid_periods)
    n_invalid = length(diag.invalid_periods)

    regime_counts = Dict{FinancingRegime, Int}(
        rg => 0 for rg in (unlevered, hedge, speculative, ponzi, invalid)
    )
    for ro in diag.regime_diagnostics.observations
        regime_counts[ro.regime] += 1
    end

    regime_share_of_valid = Dict{FinancingRegime, Float64}(
        rg => n_valid == 0 ? 0.0 : regime_counts[rg] / n_valid for
        rg in (unlevered, hedge, speculative, ponzi)
    )
    regime_share_of_valid[invalid] = n == 0 ? 0.0 : n_invalid / n

    regimes = diag.regime_diagnostics.observations
    first_speculative_time = _first_time(t -> regimes[t].regime == speculative, 1:n)
    first_ponzi_time = _first_time(t -> regimes[t].regime == ponzi, 1:n)

    degradation_time = if first_speculative_time === nothing
        first_ponzi_time
    elseif first_ponzi_time === nothing
        first_speculative_time
    else
        min(first_speculative_time, first_ponzi_time)
    end
    recovery_to_hedge_time = if degradation_time === nothing
        nothing
    else
        _first_time(t -> t > degradation_time && regimes[t].regime == hedge, 1:n)
    end

    peak_debt_ratio, peak_debt_ratio_time =
        _argmax_over(obs, o -> o.debt_ratio, diag.valid_periods)
    min_icr, min_icr_time =
        _argmin_over(obs, o -> o.interest_coverage_ratio, diag.valid_periods)
    min_dscr, min_dscr_time =
        _argmin_over(obs, o -> o.debt_service_coverage_ratio, diag.valid_periods)
    min_pm, min_pm_time = _argmin_over(obs, o -> o.ponzi_margin, diag.valid_periods)
    min_hm, min_hm_time = _argmin_over(obs, o -> o.hedge_margin, diag.valid_periods)

    debt_change_periods = filter(t -> isfinite(obs[t].debt_change), diag.valid_periods)
    max_dc, max_dc_time = _argmax_over(obs, o -> o.debt_change, debt_change_periods)

    MinskyDiagnosticsSummary(
        diag.model_name,
        diag.scenario_name,
        diag.methodology_version,
        diag.config,
        n,
        n_valid,
        n_invalid,
        regime_counts,
        regime_share_of_valid,
        first_speculative_time,
        first_ponzi_time,
        recovery_to_hedge_time,
        peak_debt_ratio,
        peak_debt_ratio_time,
        min_icr,
        min_icr_time,
        min_dscr,
        min_dscr_time,
        min_pm,
        min_pm_time,
        min_hm,
        min_hm_time,
        max_dc,
        max_dc_time,
        diag.divergence_time !== nothing,
        diag.divergence_time,
    )
end

"""
    MinskyDiagnosticsComparison

複数シナリオの `MinskyDiagnosticsResult`/`MinskyDiagnosticsSummary` を並べて保持する比較結果。
各シナリオの `config`（`methodology_version` を含む）を個別に保持するため、異なる診断設定
（例: `amortization_rate` を変えた感応度確認）を暗黙に同列比較することはない。

## フィールド
- `scenario_names::Vector{String}` : 比較対象のシナリオ名（呼び出し側が付与）
- `diagnostics::Vector{MinskyDiagnosticsResult}` : 各シナリオの診断結果
- `summaries::Vector{MinskyDiagnosticsSummary}` : 各シナリオのサマリー
"""
struct MinskyDiagnosticsComparison
    scenario_names::Vector{String}
    diagnostics::Vector{MinskyDiagnosticsResult}
    summaries::Vector{MinskyDiagnosticsSummary}
end

"""
    minsky_diagnostics_comparison(named_diagnostics::AbstractVector{<:Pair{String, MinskyDiagnosticsResult}}) -> MinskyDiagnosticsComparison

複数の名前付き `MinskyDiagnosticsResult`（例: `"baseline" => diag_base`,
`"high_interest_rate" => diag_high_r`）から `MinskyDiagnosticsComparison` を構築する。

各シナリオは独立した `KeenModel`・初期値・`FinancingRegimeConfig` から生成されていてよい
（同一初期値からの複数シミュレーション比較、金利変更シナリオ比較、
`amortization_rate` 感応度比較のいずれにも使える入口）。各シナリオの `config`・
`methodology_version` はサマリーに保持されるため、比較時に診断設定の違いを見失わない。

## 使用例
```julia
diag_base = minsky_diagnostics(m_base, simulate(m_base, ss.ω, ss.λ, ss.d; T = 300))
diag_high_r = minsky_diagnostics(m_high_r, simulate(m_high_r, ss.ω, ss.λ, ss.d; T = 300))

cmp = minsky_diagnostics_comparison(["baseline" => diag_base, "high_interest_rate" => diag_high_r])
cmp.summaries[1].peak_debt_ratio
cmp.summaries[2].config.amortization_rate
```
"""
function minsky_diagnostics_comparison(
    named_diagnostics::AbstractVector{<:Pair{String, MinskyDiagnosticsResult}},
)
    if isempty(named_diagnostics)
        throw(ArgumentError("named_diagnostics は空であってはいけません"))
    end
    names = String[p.first for p in named_diagnostics]
    diags = MinskyDiagnosticsResult[p.second for p in named_diagnostics]
    summaries = MinskyDiagnosticsSummary[minsky_diagnostics_summary(d) for d in diags]
    MinskyDiagnosticsComparison(names, diags, summaries)
end
