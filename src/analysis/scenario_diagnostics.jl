# scenario_diagnostics.jl: シナリオ比較診断（Issue #204 / `E-8`）。
#
# `run_scenario`（Issue #202）が返す `ScenarioRun` 2本（baseline / event scenario）を比較し、
# 変数ごとの差分系列・ピーク・開始時点・持続・回復と、部門・変数間の波及開始順を機械可読に返す
# 読み取り専用の診断層である。`ScenarioRun` の生成過程・モデル本体の動学には一切影響しない。
#
# `ScenarioRun` は `model_run::Any`・`accounting::Any`・`diagnostics::Any` を除いて
# モデル非依存の構造（`result::SimulationResult`・`scenario::Scenario`・
# `provenance::ScenarioProvenance`）を持つため、`scenario_comparison` は特定モデルへ
# dispatch しない（統合設計 `Y-24`）。`CCC` 固有の主要経路候補（診断ラベル・ループ作動）は
# `CapexDiagnostics` を**任意引数**として受け取ったときのみ `propagation_order` へ付加する。
# `capex_diagnostics`（`src/analysis/capex_credit_cycle_diagnostics.jl`）自体は変更しない。
#
# 設計契約:
#   docs/architecture/macro_event_runtime_integration.md §5.8（`ScenarioDiagnosticThresholds`・
#     `ScenarioComparisonDiagnostics`・`scenario_comparison`・`scenario_timing_sensitivity`・
#     `scenario_magnitude_sensitivity` の型・契約8項目）・§2.2 `Y-24`・`Y-29`・`Y-30`・§11 `E-8`
#   docs/models/capex_credit_cycle_analysis_contract.md（判定問題 Q1–Q5 との関係。本ファイルは
#     因果推論・寄与推定を行わない。§対象外）
#
# 出力の名称に `causal`（因果）・`contribution`（寄与）を用いない（統合設計 §5.8 契約4・§10 `E-8`
# 行の受け入れ条件）。`propagation_order` は**モデル内の系列順序**であり統計的因果効果ではない。
#
# `ScenarioComparisonDiagnostics` に `latent_only_onset::Bool` フィールドを持たせる。統合設計
# §5.8 の抜粋コードブロックには明示されていないが、契約5「`latent_only_onset` 警告を付す」を
# 表現する field が構造体に無いと契約を満たせない（`MACRO_EVENT_WARNING_CODES` は12種で固定
# されており §10.1 item 13 によりこれ以上増やせないため、`ScenarioWarning` は流用しない）。
# 同様の「抜粋コードブロックに無いが契約充足に必要なフィールドを追加する」判断は
# `src/scenarios/event_scheduler.jl`（`EventSchedule.rejections`）に先例がある。

# ------------------------------------------------------------
# ScenarioDiagnosticThresholds（統合設計 §5.8）
# ------------------------------------------------------------

"""
    ScenarioDiagnosticThresholds

`scenario_comparison` が用いる閾値集合（統合設計 §5.8）。`id`・`version` を持ち、
`ScenarioComparisonDiagnostics.thresholds` へそのまま保持される。

## フィールド
- `id::String`
- `version::String`
- `onset_abs::Float64`: 反応開始とみなす絶対差の下限。
- `onset_rel::Float64`: 反応開始とみなす相対差の下限。
- `onset_persistence::Int`: 反応開始・回復の判定に必要な連続期数。
- `rel_denominator_floor::Float64`: 相対差の分母下限。これを下回る期の `rel_diff` は
  `missing`（0除算を隠さない、統合設計 §5.8 契約3）。
"""
Base.@kwdef struct ScenarioDiagnosticThresholds
    id::String = "default"
    version::String = "scenario-diagnostics-thresholds/1.0.0"
    onset_abs::Float64 = 1e-8
    onset_rel::Float64 = 0.001
    onset_persistence::Int = 2
    rel_denominator_floor::Float64 = 1e-6
end

# ------------------------------------------------------------
# ScenarioComparisonDiagnostics（統合設計 §5.8）
# ------------------------------------------------------------

"""
    ScenarioComparisonDiagnostics

`scenario_comparison` の結果（統合設計 §5.8）。

## フィールド
- `variables::Vector{Symbol}`: 比較対象の変数（`baseline`・`scenario` 双方の `SimulationResult`
  に存在する変数の積集合、または `variables` 引数で明示指定した集合）。
- `abs_diff::Dict{Symbol,Vector{Float64}}`: `scenario - baseline`（水準差、全期間）。
- `rel_diff::Dict{Symbol,Vector{Union{Float64,Missing}}}`: `abs_diff / |baseline|`。
  `|baseline|` が `thresholds.rel_denominator_floor` 未満の期は `missing`。
- `peak::Dict{Symbol,NamedTuple}`: `(value, period, sign)`。有効区間内で `abs_diff` が
  最大（最も正）となる点。有効値が無ければ `(value=NaN, period=nothing, sign=0)`。
- `trough::Dict{Symbol,NamedTuple}`: `(value, period, sign)`。有効区間内で `abs_diff` が
  最小（最も負）となる点。
- `onset_period::Dict{Symbol,Union{Int,Nothing}}`: `abs_diff`（または `rel_diff`）が
  `onset_abs`/`onset_rel` を `onset_persistence` 期連続して超えた最初の期。無ければ `nothing`。
- `duration_above::Dict{Symbol,Int}`: 有効区間内で閾値を超えた期の総数（連続でなくてよい）。
- `recovery_period::Dict{Symbol,Union{Int,Nothing}}`: `onset_period` 以降、閾値未満の状態が
  `onset_persistence` 期連続して有効区間の終わりまで維持された最初の期。反応が無い、または
  一度も持続的に回復しない場合は `nothing`。
- `cumulative::Dict{Symbol,Union{Float64,Nothing}}`: 有効区間内の `abs_diff` の総和。
  `metadata["variable_timing"][name] == "SUM"`（フロー）の変数にのみ算出する。`"EOP"`
  （ストック）や metadata が無い変数は `nothing`（統合設計 §5.8 契約2、無差別適用しない）。
- `propagation_order::Vector{NamedTuple}`: `(variable, sector, onset_period, active_loops)`。
  `onset_period !== nothing` の変数を `onset_period` 昇順（同着は変数名の辞書順）で並べる。
  `sector` は `metadata["variable_sectors"]` から得られる文字列（無ければ `nothing`）。
  `active_loops::Vector{Symbol}` は `model_diagnostics` を与えたときのみ非空になりうる
  （後述）。**統計的因果効果ではない**（統合設計 §5.8 契約4）。
- `event_application_periods::Vector{Int}`: `scenario` 側の `schedule.events` の `t_apply` の
  昇順ユニーク値。`onset_period`（反応開始）とは別概念であり混同しない。
- `valid_range::UnitRange{Int}`: 打ち切りを考慮した比較の有効区間（期）。
- `invalid_reason::Union{Symbol,Nothing}`: `valid_range` が全区間より狭い理由
  （`:baseline_terminated`・`:scenario_terminated`・`:both_terminated`）。狭めていなければ
  `nothing`。
- `latent_only_onset::Bool`: `propagation_order` の先頭（`onset_period` が最小の変数群）が
  `metadata["variable_observability"]` で `"E"`（期待・見通し）または `"A"`（会計上の内生量。
  診断層の慣例で「潜在」側として扱う）の変数のみで構成される場合に `true`（統合設計 §5.8
  契約5。単独提示の抑止）。判定に必要な metadata が無い場合は `false`（判定不能を「潜在」と
  みなさない、fail closed ではなく警告を出さない側に倒す）。
- `thresholds::ScenarioDiagnosticThresholds`

`propagation_order` の `active_loops` フィールドの意味は [`scenario_comparison`](@ref) の
`model_diagnostics` 引数の説明を参照。
"""
struct ScenarioComparisonDiagnostics
    variables::Vector{Symbol}
    abs_diff::Dict{Symbol, Vector{Float64}}
    rel_diff::Dict{Symbol, Vector{Union{Float64, Missing}}}
    peak::Dict{Symbol, NamedTuple}
    trough::Dict{Symbol, NamedTuple}
    onset_period::Dict{Symbol, Union{Int, Nothing}}
    duration_above::Dict{Symbol, Int}
    recovery_period::Dict{Symbol, Union{Int, Nothing}}
    cumulative::Dict{Symbol, Union{Float64, Nothing}}
    propagation_order::Vector{NamedTuple}
    event_application_periods::Vector{Int}
    valid_range::UnitRange{Int}
    invalid_reason::Union{Symbol, Nothing}
    latent_only_onset::Bool
    thresholds::ScenarioDiagnosticThresholds
end

# ------------------------------------------------------------
# 比較可能性の事前検証（統合設計 §5.8 契約1）
# ------------------------------------------------------------

"""
    _scenario_diag_check_comparable(baseline, scenario)

`model_symbol`・`params_hash`・`initial_state_id`・`horizon`（`horizon_runup`/`horizon_eval`）・
`period_zero` の一致を検証する。不一致は `ArgumentError`（統合設計 §5.8 契約1）。両者の
`status` が `:rejected_validation`/`:rejected_mapping`（`result === nothing`）である場合も
比較できないため `ArgumentError`。
"""
function _scenario_diag_check_comparable(baseline::ScenarioRun, scenario::ScenarioRun)
    for (label, run) in (("baseline", baseline), ("scenario", scenario))
        run.status in (:rejected_validation, :rejected_mapping) && throw(
            ArgumentError(
                "$(label).status=$(run.status) は result を持たないため比較できません" *
                "（統合設計 §6.3 fail closed）",
            ),
        )
    end

    baseline.model_symbol == scenario.model_symbol || throw(
        ArgumentError(
            "model_symbol が一致しません: baseline=$(baseline.model_symbol) " *
            "scenario=$(scenario.model_symbol)（統合設計 §5.8 契約1）",
        ),
    )
    baseline.provenance.params_hash == scenario.provenance.params_hash || throw(
        ArgumentError(
            "params_hash が一致しません（同一モデル・同一パラメータの baseline/scenario でなければ" *
            "比較できません。統合設計 §5.8 契約1）",
        ),
    )
    baseline.provenance.initial_state_id == scenario.provenance.initial_state_id ||
        throw(ArgumentError("initial_state_id が一致しません（統合設計 §5.8 契約1）"))
    bsc = baseline.scenario
    ssc = scenario.scenario
    (bsc.horizon_runup, bsc.horizon_eval) == (ssc.horizon_runup, ssc.horizon_eval) || throw(
        ArgumentError(
            "horizon が一致しません: baseline=($(bsc.horizon_runup),$(bsc.horizon_eval)) " *
            "scenario=($(ssc.horizon_runup),$(ssc.horizon_eval))（統合設計 §5.8 契約1）",
        ),
    )
    bsc.period_zero == ssc.period_zero || throw(
        ArgumentError(
            "period_zero が一致しません: baseline=$(bsc.period_zero) " *
            "scenario=$(ssc.period_zero)（統合設計 §5.8 契約1）",
        ),
    )
    return nothing
end

# ------------------------------------------------------------
# 有効区間（統合設計 §5.8 契約6）
# ------------------------------------------------------------

"""
    _scenario_diag_last_valid_index(run, periods) -> Int

`run.status !== :terminated` なら `length(periods)`（全区間有効）。`:terminated` の場合、
`run.result.variables` のいずれかが非有限（`NaN`）になる最初の期の**直前**のインデックスを
返す（CCC 実行層は打ち切り後を `NaN` で埋めるため一律に検出できる、統合設計 §7.6・
`capex_credit_cycle.jl` の打ち切り実装）。全期間有効なら `length(periods)`、初期から無効なら
`0`。
"""
function _scenario_diag_last_valid_index(run::ScenarioRun, periods::Vector{Int})
    n = length(periods)
    run.status === :terminated || return n
    result = run.result
    for i in 1:n
        for v in values(result.variables)
            i <= length(v) || continue
            isfinite(v[i]) && continue
            return i - 1
        end
    end
    return n
end

"""
    _scenario_diag_valid_range(baseline, scenario, periods) -> (range, invalid_reason)

`baseline`・`scenario` それぞれの有効最終インデックスの小さい方を用いて `valid_range` を
構成する。両者とも打ち切られていなければ `invalid_reason = nothing`。欠損後を `0` で埋めない
（統合設計 §5.8 契約6）。
"""
function _scenario_diag_valid_range(
    baseline::ScenarioRun,
    scenario::ScenarioRun,
    periods::Vector{Int},
)
    last_b = _scenario_diag_last_valid_index(baseline, periods)
    last_s = _scenario_diag_last_valid_index(scenario, periods)
    last_idx = min(last_b, last_s)

    reason = if last_b < length(periods) && last_s < length(periods)
        :both_terminated
    elseif last_b < length(periods)
        :baseline_terminated
    elseif last_s < length(periods)
        :scenario_terminated
    else
        nothing
    end

    range = last_idx >= 1 ? (periods[1]:periods[last_idx]) : (periods[1]:(periods[1] - 1))
    return range, reason
end

# ------------------------------------------------------------
# 変数ごとの計算（統合設計 §5.8 契約2・3）
# ------------------------------------------------------------

"""
    _scenario_diag_variable_list(baseline, scenario, variables) -> Vector{Symbol}

`variables` が `nothing` のとき、`baseline`・`scenario` 双方の `SimulationResult.variables` に
存在する変数名の積集合を辞書順で返す。明示指定された場合は両方に存在することを検証する。
"""
function _scenario_diag_variable_list(
    baseline::ScenarioRun,
    scenario::ScenarioRun,
    variables::Union{Vector{Symbol}, Nothing},
)
    bkeys = Set(Symbol(k) for k in keys(baseline.result.variables))
    skeys = Set(Symbol(k) for k in keys(scenario.result.variables))
    common = bkeys ∩ skeys

    if variables === nothing
        return sort(collect(common); by = string)
    end

    missing_vars = [v for v in variables if v ∉ common]
    isempty(missing_vars) || throw(
        ArgumentError(
            "variables に baseline/scenario 双方に存在しない変数が含まれています: " *
            "$(missing_vars)",
        ),
    )
    return variables
end

"""
    _scenario_diag_rel(diff, base_value, floor) -> Union{Float64,Missing}

`|base_value| < floor` のとき `missing`（0除算を隠さない、統合設計 §5.8 契約3）。それ以外は
`diff / base_value`（`diff` が `NaN` ならその `NaN` をそのまま返す。打ち切り後の欠損を意味する）。
"""
function _scenario_diag_rel(diff::Float64, base_value::Float64, floor::Float64)
    abs(base_value) < floor && return missing
    return diff / base_value
end

"""
    _scenario_diag_extremum(diff, periods, last_idx, better) -> NamedTuple

`1:last_idx` の範囲で `better(candidate, current)` が真であり続ける値を探し `(value, period,
sign)` を返す（`better = (>)` で peak、`better = (<)` で trough）。有限値が無ければ
`(value=NaN, period=nothing, sign=0)`。
"""
function _scenario_diag_extremum(
    diff::Vector{Float64},
    periods::Vector{Int},
    last_idx::Int,
    better::Function,
)
    best_i = 0
    best_v = 0.0
    for i in 1:last_idx
        v = diff[i]
        isfinite(v) || continue
        if best_i == 0 || better(v, best_v)
            best_v = v
            best_i = i
        end
    end
    best_i == 0 && return (value = NaN, period = nothing, sign = 0)
    sgn = best_v > 0.0 ? 1 : (best_v < 0.0 ? -1 : 0)
    return (value = best_v, period = periods[best_i], sign = sgn)
end

"""
    _scenario_diag_breach(diff, rel, last_idx, thresholds) -> Vector{Bool}

各期について、`|diff| >= thresholds.onset_abs` または（`rel` が `Float64` かつ有限で）
`|rel| >= thresholds.onset_rel` のいずれかを満たすかを長さ `last_idx` の `Vector{Bool}` で返す。
"""
function _scenario_diag_breach(
    diff::Vector{Float64},
    rel::Vector{Union{Float64, Missing}},
    last_idx::Int,
    thresholds::ScenarioDiagnosticThresholds,
)
    breach = falses(last_idx)
    for i in 1:last_idx
        isfinite(diff[i]) || continue
        r = rel[i]
        rel_hit = r isa Float64 && isfinite(r) && abs(r) >= thresholds.onset_rel
        breach[i] = abs(diff[i]) >= thresholds.onset_abs || rel_hit
    end
    return breach
end

"""
    _scenario_diag_onset(breach, periods, persistence) -> Union{Int,Nothing}

`breach` が `persistence` 期以上連続して `true` になる**最初の**区間の開始期を返す。無ければ
`nothing`。
"""
function _scenario_diag_onset(
    breach::AbstractVector{Bool},
    periods::Vector{Int},
    persistence::Int,
)
    n = length(breach)
    persistence <= 0 && return nothing
    for i in 1:(n - persistence + 1)
        all(breach[i:(i + persistence - 1)]) && return periods[i]
    end
    return nothing
end

"""
    _scenario_diag_recovery(breach, periods, onset_period, persistence) -> Union{Int,Nothing}

`onset_period` より後で `breach` が `persistence` 期以上連続して `false` になる**最初の**期を
返す。`onset_period === nothing`（反応が無い）、または一度も持続的に回復しない場合は
`nothing`。
"""
function _scenario_diag_recovery(
    breach::AbstractVector{Bool},
    periods::Vector{Int},
    onset_period::Union{Int, Nothing},
    persistence::Int,
)
    onset_period === nothing && return nothing
    n = length(breach)
    persistence <= 0 && return nothing
    onset_idx = findfirst(==(onset_period), periods)
    onset_idx === nothing && return nothing
    for i in (onset_idx + 1):(n - persistence + 1)
        all(!, breach[i:(i + persistence - 1)]) && return periods[i]
    end
    return nothing
end

"""
    _scenario_diag_string_dict(result, key) -> Dict{String,String}

`result.metadata[key]` が存在すればそれを、無ければ空 `Dict` を返す。
"""
function _scenario_diag_string_dict(result::SimulationResult, key::String)
    v = get(result.metadata, key, nothing)
    return v isa AbstractDict ? v : Dict{String, String}()
end

# ------------------------------------------------------------
# 主要経路候補の構造化（`CapexDiagnostics` が与えられた場合のみ、統合設計 `Y-24`）
# ------------------------------------------------------------

"""
    _scenario_diag_active_loops(variable, model_diagnostics) -> Vector{Symbol}

`model_diagnostics.loop_active` で作動中（`true`）のループのうち、`variable` がその代表変数
（`_CAPEX_LOOP_GAIN_REPRESENTATIVE`）に含まれるものを返す。`model_diagnostics === nothing` の
ときは常に空。**ループの作動有無をそのまま引き写すのみであり、寄与度や因果効果を計算しない**
（統合設計 §5.8 契約4）。
"""
function _scenario_diag_active_loops(
    variable::Symbol,
    model_diagnostics::Union{CapexDiagnostics, Nothing},
)
    model_diagnostics === nothing && return Symbol[]
    loops = Symbol[]
    for loop_id in CAPEX_CC_LOOP_IDS
        get(model_diagnostics.loop_active, loop_id, false) || continue
        reps = get(_CAPEX_LOOP_GAIN_REPRESENTATIVE, loop_id, Symbol[])
        variable in reps && push!(loops, loop_id)
    end
    return loops
end

# ------------------------------------------------------------
# scenario_comparison（統合設計 §5.8）
# ------------------------------------------------------------

"""
    scenario_comparison(baseline::ScenarioRun, scenario::ScenarioRun;
                         variables::Union{Vector{Symbol},Nothing} = nothing,
                         thresholds::ScenarioDiagnosticThresholds = ScenarioDiagnosticThresholds(),
                         model_diagnostics::Union{CapexDiagnostics,Nothing} = nothing
                         ) -> ScenarioComparisonDiagnostics

`baseline`（イベントなし、またはショックの無いシナリオ）と `scenario`（比較対象の event
scenario）の `run_scenario` 結果を比較し、変数ごとの差分・ピーク・開始・持続・回復と、
部門・変数の波及開始順を返す（統合設計 §5.8）。

## 引数
- `variables`: 比較する変数の部分集合。既定 `nothing` は両 `SimulationResult` に共通する
  全変数。
- `thresholds`: [`ScenarioDiagnosticThresholds`](@ref)。
- `model_diagnostics`: `CCC` の [`capex_diagnostics`](@ref) 結果を渡すと、`propagation_order`
  の各エントリへ `active_loops`（作動中ループの ID）を付加する。**因果推論・寄与推定は
  行わない**（対象外、統合設計 §5.8）。

比較前に `model_symbol`・`params_hash`・`initial_state_id`・`horizon`・`period_zero` の一致を
検証し、不一致は `ArgumentError` とする（統合設計 §5.8 契約1）。`status ∈
(:rejected_validation, :rejected_mapping)` の run（`result === nothing`）も比較できないため
`ArgumentError`。
"""
function scenario_comparison(
    baseline::ScenarioRun,
    scenario::ScenarioRun;
    variables::Union{Vector{Symbol}, Nothing} = nothing,
    thresholds::ScenarioDiagnosticThresholds = ScenarioDiagnosticThresholds(),
    model_diagnostics::Union{CapexDiagnostics, Nothing} = nothing,
)
    _scenario_diag_check_comparable(baseline, scenario)

    periods = baseline.schedule.periods
    vars = _scenario_diag_variable_list(baseline, scenario, variables)
    valid_range, invalid_reason = _scenario_diag_valid_range(baseline, scenario, periods)
    last_idx = length(valid_range)

    sectors = _scenario_diag_string_dict(scenario.result, "variable_sectors")
    isempty(sectors) &&
        (sectors = _scenario_diag_string_dict(baseline.result, "variable_sectors"))
    observability = _scenario_diag_string_dict(scenario.result, "variable_observability")
    isempty(observability) && (
        observability =
            _scenario_diag_string_dict(baseline.result, "variable_observability")
    )
    timing_dict = _scenario_diag_string_dict(scenario.result, "variable_timing")
    isempty(timing_dict) &&
        (timing_dict = _scenario_diag_string_dict(baseline.result, "variable_timing"))

    abs_diff = Dict{Symbol, Vector{Float64}}()
    rel_diff = Dict{Symbol, Vector{Union{Float64, Missing}}}()
    peak = Dict{Symbol, NamedTuple}()
    trough = Dict{Symbol, NamedTuple}()
    onset_period = Dict{Symbol, Union{Int, Nothing}}()
    duration_above = Dict{Symbol, Int}()
    recovery_period = Dict{Symbol, Union{Int, Nothing}}()
    cumulative = Dict{Symbol, Union{Float64, Nothing}}()

    for v in vars
        key = String(v)
        bs = baseline.result.variables[key]
        ss = scenario.result.variables[key]
        diff = ss .- bs
        rel = Union{Float64, Missing}[
            _scenario_diag_rel(diff[i], bs[i], thresholds.rel_denominator_floor) for
            i in eachindex(diff)
        ]
        abs_diff[v] = diff
        rel_diff[v] = rel

        peak[v] = _scenario_diag_extremum(diff, periods, last_idx, >)
        trough[v] = _scenario_diag_extremum(diff, periods, last_idx, <)

        breach = _scenario_diag_breach(diff, rel, last_idx, thresholds)
        onset = _scenario_diag_onset(breach, periods, thresholds.onset_persistence)
        onset_period[v] = onset
        duration_above[v] = count(breach)
        recovery_period[v] =
            _scenario_diag_recovery(breach, periods, onset, thresholds.onset_persistence)

        cumulative[v] =
            get(timing_dict, key, nothing) == "SUM" ? sum(@view diff[1:last_idx]) : nothing
    end

    onset_vars = sort(
        [v for v in vars if onset_period[v] !== nothing];
        by = v -> (onset_period[v], string(v)),
    )
    propagation_order = NamedTuple[
        (
            variable = v,
            sector = get(sectors, String(v), nothing),
            onset_period = onset_period[v],
            active_loops = _scenario_diag_active_loops(v, model_diagnostics),
        ) for v in onset_vars
    ]

    latent_only_onset = false
    if !isempty(propagation_order)
        earliest = propagation_order[1].onset_period
        front = [e for e in propagation_order if e.onset_period == earliest]
        latent_only_onset = all(
            get(observability, String(e.variable), nothing) in ("E", "A") for e in front
        )
    end

    event_application_periods = sort(unique(ev.t_apply for ev in scenario.schedule.events))

    return ScenarioComparisonDiagnostics(
        vars,
        abs_diff,
        rel_diff,
        peak,
        trough,
        onset_period,
        duration_above,
        recovery_period,
        cumulative,
        propagation_order,
        event_application_periods,
        valid_range,
        invalid_reason,
        latent_only_onset,
        thresholds,
    )
end

# ------------------------------------------------------------
# scenario_timing_sensitivity（統合設計 §5.8 契約7、`Y-29`）
# ------------------------------------------------------------

"""
    _scenario_shift_event_timing(timing::EventTiming, shift::Int) -> EventTiming

`timing` を `shift` 期分ずらした新しい `EventTiming` を返す。`basis = :period` は `t_apply`/
`t_until` を直接 `shift` だけ加算する。`basis = :calendar` は1期 = 1四半期として
`effective_from`/`effective_until` を `3*shift` か月ずらす（暦月加算。厳密な日数シフトではなく
近似だが、四半期割当は `quarter_of` によりシフト後の日付から再計算されるため感応度診断の
目的には十分である）。
"""
function _scenario_shift_event_timing(timing::EventTiming, shift::Int)
    if timing.basis === :period
        return EventTiming(;
            basis = :period,
            rule = timing.rule,
            t_apply = timing.t_apply === nothing ? nothing : timing.t_apply + shift,
            t_until = timing.t_until === nothing ? nothing : timing.t_until + shift,
            rule_overridden = timing.rule_overridden,
            from_source = timing.from_source,
        )
    else
        months = Dates.Month(3 * shift)
        return EventTiming(;
            basis = :calendar,
            rule = timing.rule,
            effective_from = timing.effective_from === nothing ? nothing :
                             timing.effective_from + months,
            effective_until = timing.effective_until === nothing ? nothing :
                              timing.effective_until + months,
            rule_overridden = timing.rule_overridden,
            from_source = timing.from_source,
        )
    end
end

"""
    _scenario_rebuild_assumption(a::ScenarioAssumption; timing=a.timing, magnitude=a.magnitude)
        -> ScenarioAssumption

`a` の全フィールドを引き写しつつ `timing`/`magnitude` のみ差し替えた新しい
`ScenarioAssumption` を返す（`scenario_timing_sensitivity`・`scenario_magnitude_sensitivity`
共通の内部ヘルパー）。
"""
function _scenario_rebuild_assumption(
    a::ScenarioAssumption;
    timing::EventTiming = a.timing,
    magnitude::Float64 = a.magnitude,
)
    return ScenarioAssumption(;
        assumption_id = a.assumption_id,
        event_type = a.event_type,
        schema_version = a.schema_version,
        sector = a.sector,
        geography = a.geography,
        direction = a.direction,
        magnitude = magnitude,
        unit = a.unit,
        magnitude_source = a.magnitude_source,
        application_mode = a.application_mode,
        timing = timing,
        persistence = a.persistence,
        target_concepts = a.target_concepts,
        provenance = a.provenance,
        confidence = a.confidence,
        uncertainty = a.uncertainty,
        notes = a.notes,
        caveats = a.caveats,
    )
end

"""
    _scenario_rebuild(sc::Scenario, assumptions::Vector{ScenarioAssumption}) -> Scenario

`sc` の `assumptions` のみを差し替えた新しい `Scenario` を返す。
"""
function _scenario_rebuild(sc::Scenario, assumptions::Vector{ScenarioAssumption})
    return Scenario(;
        id = sc.id,
        name = sc.name,
        version = sc.version,
        model = sc.model,
        period_zero = sc.period_zero,
        horizon_runup = sc.horizon_runup,
        horizon_eval = sc.horizon_eval,
        assumptions = assumptions,
        timing_rules = sc.timing_rules,
        defaults_set_id = sc.defaults_set_id,
        defaults_set_version = sc.defaults_set_version,
        notes = sc.notes,
    )
end

"""
    scenario_timing_sensitivity(m, sc::Scenario;
                                options::ScenarioRunOptions = ScenarioRunOptions(),
                                shift::Int = 1) -> NamedTuple

`sc.assumptions` の全イベントを一律に `-shift`/`+shift` 期ずらした2ケースを実行し
`(shift, minus, plus)`（各 `ScenarioRun`）を返す（統合設計 §5.8 契約7・`Y-29`）。cutoff
近傍のイベントについて #168 時間軸 §4.6 が義務づける「±1期ずらした結果の併記」を、単一の
`run_scenario` 呼び出しではなく本関数で満たす。
"""
function scenario_timing_sensitivity(
    m::AbstractMacroModel,
    sc::Scenario;
    options::ScenarioRunOptions = ScenarioRunOptions(),
    shift::Int = 1,
)
    shifted(s) = _scenario_rebuild(
        sc,
        [
            _scenario_rebuild_assumption(
                a;
                timing = _scenario_shift_event_timing(a.timing, s),
            ) for a in sc.assumptions
        ],
    )
    run_minus = run_scenario(m, shifted(-shift); options = options)
    run_plus = run_scenario(m, shifted(shift); options = options)
    return (shift = shift, minus = run_minus, plus = run_plus)
end

# ------------------------------------------------------------
# scenario_magnitude_sensitivity（統合設計 §5.8 契約8、`Y-30`）
# ------------------------------------------------------------

"""
    scenario_magnitude_sensitivity(m, sc::Scenario;
                                   options::ScenarioRunOptions = ScenarioRunOptions(),
                                   ratio::Float64 = 0.5) -> NamedTuple

`magnitude_source = :assumed_default` の仮定のみを `magnitude` の `±ratio` 倍にずらした2ケースを
実行し `(ratio, minus, plus)`（各 `ScenarioRun`）を返す（統合設計 §5.8 契約8・`Y-30`）。
`:observed`/`:disclosed`/`:derived`/`:external_belief` の仮定は動かさない。閾値の `±50%`
感応度（`capex_label_sensitivity`）とは**別の関数・別の出力**であり、取り違えない。
"""
function scenario_magnitude_sensitivity(
    m::AbstractMacroModel,
    sc::Scenario;
    options::ScenarioRunOptions = ScenarioRunOptions(),
    ratio::Float64 = 0.5,
)
    scaled(factor) = _scenario_rebuild(
        sc,
        [
            a.magnitude_source === :assumed_default ?
            _scenario_rebuild_assumption(a; magnitude = a.magnitude * factor) : a for
            a in sc.assumptions
        ],
    )
    run_minus = run_scenario(m, scaled(1 - ratio); options = options)
    run_plus = run_scenario(m, scaled(1 + ratio); options = options)
    return (ratio = ratio, minus = run_minus, plus = run_plus)
end
