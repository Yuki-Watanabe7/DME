# 部門別 CAPEX・信用循環モデル（CCC）の履歴再生検証層（Issue #249 / `P-9`）。
#
# 履歴再生の数値的 fit と、転換点・時差・方向・持続性・信用増幅・部門波及を
# 別 dimension として返す読み取り専用層である。単一 score や単一 pass/fail gate は
# 意図的に持たない。観測から信用増幅を推定せず、信用増幅は既存の :credit_off
# 反実仮想で定義されたモデル内の量だけを報告する。
#
# Design: docs/architecture/capex_credit_cycle_empirical_integration.md §10
# （P-9 / Z-22--Z-24）・docs/models/capex_credit_cycle_empirical_strategy.md
# §9.3・§10.2--§10.6。`scenario_diagnostics.jl` の共有純関数を runtime 時に呼ぶ。
# このファイルは scenario_diagnostics.jl より先に include されるが、Julia の関数本体は
# 呼び出し時に解決されるため、モジュール読み込み後の公開 API からは問題なく利用できる。

"本検証層の methodology version。"
const CAPEX_CC_EMPIRICAL_VALIDATION_VERSION = "capex-credit-cycle-empirical-validation/1.0.0"

"数値 fit と動学・構造を分離して返す固定 dimension。"
const CAPEX_CC_VALIDATION_DIMENSIONS = (
    :numerical_fit,
    :turning_point,
    :timing,
    :direction,
    :persistence,
    :credit_amplification,
    :propagation,
)

"系列ごとの数値 metric の適用可否。"
const CAPEX_CC_METRIC_APPLICABILITY =
    (:applicable, :not_applicable_role, :not_applicable_latent, :unavailable_data)

"dimension ごとの状態語彙。`:partially_available` は一部の系列だけを評価できたことを表す。"
const CAPEX_CC_VALIDATION_STATUSES = (:available, :partially_available, :unavailable)

"""
    CAPEX_CC_PROPAGATION_PATH

履歴再生で記述的に確認する部門波及の経路。ここで返す順序は時系列上の onset 順であり、
統計的な因果効果・寄与率ではない。
"""
const CAPEX_CC_PROPAGATION_PATH =
    (:capex_exec_s1, :order_s2, :order_s3, :emp_s2, :emp_s3, :hh_income, :cons, :y_tot)

const _CAPEX_CC_PROPAGATION_EDGES = (
    (:capex_exec_s1, :order_s2),
    (:capex_exec_s1, :order_s3),
    (:order_s2, :emp_s2),
    (:order_s3, :emp_s3),
    (:emp_s2, :hh_income),
    (:emp_s3, :hh_income),
    (:hh_income, :cons),
    (:cons, :y_tot),
)

"""
    CAPEX_CC_EMPIRICAL_VALIDATION_CAVEATS

すべての report に添える固定の解釈上の制限。個別 run の打ち切り・会計違反・弱識別は
`warnings` にも加える。
"""
const CAPEX_CC_EMPIRICAL_VALIDATION_CAVEATS = String[
    "これは point-in-time replay ではなく、現在利用可能な改定後データによる履歴再生である。",
    "fit は因果妥当性・景気後退確率・投資助言を意味しない。",
    "proxy / allocation 系列と direct 観測を evidence_tier で区別し、数値 fit の根拠を混同しない。",
    "S1 の収益ブロックと R1a は企業開示を較正入力に用いていないため、実証的に検証できない範囲を残す。",
    "観測側の baseline 比乖離にはトレンドが残り、定常状態を使うモデル側とは完全に対称ではない。",
    "SH-EXP の規模は較正値ではなく scenario assumption の走査対象である。",
    "unmapped event やモデル境界の外にあるイベントを、近い変数へ自動的に寄せてはいない。",
    "propagation order は onset の記述であり、統計的因果寄与率ではない。",
]

"""
    CapexSeriesFit

一つのモデル変数について、評価期間だけの baseline 比乖離を比較した数値 fit。
`D` / `C` のみが `:applicable` になり得る。`P` は proxy / allocation の限界を保つため
数値 fit を出さず、`E` / `A` は構造的に潜在なので指標自体を計算しない。
"""
struct CapexSeriesFit
    key::Symbol
    model_var::Symbol
    observability::Symbol
    applicability::Symbol
    evidence_tier::Symbol
    rmse::Union{Float64, Nothing}
    mae::Union{Float64, Nothing}
    rmse_standardized::Union{Float64, Nothing}
    correlation_level::Union{Float64, Nothing}
    correlation_diff::Union{Float64, Nothing}
    bias::Union{Float64, Nothing}
    n_pairs::Int
    n_excluded::Int
    caveats::Vector{String}
end

"""
    CapexEmpiricalValidationReport

1 本の `CapexHistoricalReplayRun` を dimension 別に検証した機械可読 report。
`dimension_status` は各 dimension の利用可否と理由を保持する。`propagation` は model と
observed の onset 順・隣接関係の順序確認を持つが、因果的な寄与を表さない。
"""
struct CapexEmpiricalValidationReport
    episode::Symbol
    parameter_set_kind::Symbol
    in_sample::Bool
    fits::Dict{Symbol, CapexSeriesFit}
    turning_points::Dict{Symbol, NamedTuple}
    onset_order::Vector{Symbol}
    onset_order_observed::Vector{Symbol}
    direction_agreement::Dict{Symbol, Float64}
    persistence::Dict{Symbol, Int}
    persistence_observed::Dict{Symbol, Int}
    credit_amplification::Dict{String, Float64}
    propagation::NamedTuple
    diagnostic_label::Symbol
    accounting::Any
    dimension_status::Dict{Symbol, NamedTuple}
    warnings::Vector{String}
    caveats::Vector{String}
    metadata::Dict{String, Any}
end

# ---------------------------------------------------------------------------
# 小さな純関数（数値 fit）
# ---------------------------------------------------------------------------

function _capex_validation_mean(values::Vector{Float64})::Float64
    return sum(values) / length(values)
end

function _capex_validation_std(values::Vector{Float64})::Float64
    length(values) < 2 && return 0.0
    μ = _capex_validation_mean(values)
    return sqrt(sum((x - μ)^2 for x in values) / length(values))
end

function _capex_validation_corr(
    left::Vector{Float64},
    right::Vector{Float64},
)::Union{Float64, Nothing}
    length(left) == length(right) || throw(ArgumentError("相関の系列長が一致しません"))
    length(left) < 2 && return nothing
    lmean = _capex_validation_mean(left)
    rmean = _capex_validation_mean(right)
    cross = 0.0
    lvar = 0.0
    rvar = 0.0
    for i in eachindex(left)
        dl = left[i] - lmean
        dr = right[i] - rmean
        cross += dl * dr
        lvar += dl^2
        rvar += dr^2
    end
    (lvar <= 0.0 || rvar <= 0.0) && return nothing
    return cross / sqrt(lvar * rvar)
end

function _capex_validation_float(value)::Union{Float64, Nothing}
    value isa Real || return nothing
    number = Float64(value)
    return isfinite(number) ? number : nothing
end

"""助走期間の有限値平均を baseline とし、評価期間の乖離を返す。"""
function _capex_validation_deviation(
    series::AbstractVector,
    runup_indices::Vector{Int},
    eval_indices::Vector{Int},
)::Union{NamedTuple, Nothing}
    baseline_values = Float64[]
    for i in runup_indices
        i <= length(series) || continue
        value = _capex_validation_float(series[i])
        value === nothing || push!(baseline_values, value)
    end
    isempty(baseline_values) && return nothing
    baseline = _capex_validation_mean(baseline_values)
    deviations = fill(NaN, length(eval_indices))
    for (j, i) in enumerate(eval_indices)
        i <= length(series) || continue
        value = _capex_validation_float(series[i])
        value === nothing || (deviations[j] = value - baseline)
    end
    return (baseline = baseline, deviations = deviations)
end

function _capex_validation_fit_metrics(
    model_dx::Vector{Float64},
    observed_dx::Vector{Float64},
)::NamedTuple
    length(model_dx) == length(observed_dx) ||
        throw(ArgumentError("model と observed の評価系列長が一致しません"))
    pairs = [
        i for i in eachindex(model_dx) if isfinite(model_dx[i]) && isfinite(observed_dx[i])
    ]
    n_pairs = length(pairs)
    n_excluded = length(model_dx) - n_pairs
    n_pairs == 0 && return (
        rmse = nothing,
        mae = nothing,
        rmse_standardized = nothing,
        correlation_level = nothing,
        correlation_diff = nothing,
        bias = nothing,
        n_pairs = n_pairs,
        n_excluded = n_excluded,
    )

    model_values = model_dx[pairs]
    observed_values = observed_dx[pairs]
    errors = model_values .- observed_values
    rmse = sqrt(sum(error^2 for error in errors) / n_pairs)
    mae = sum(abs, errors) / n_pairs
    bias = sum(errors) / n_pairs
    obs_std = _capex_validation_std(observed_values)

    model_diff = Float64[]
    observed_diff = Float64[]
    for i in 1:(length(model_dx) - 1)
        (
            isfinite(model_dx[i]) &&
            isfinite(model_dx[i + 1]) &&
            isfinite(observed_dx[i]) &&
            isfinite(observed_dx[i + 1])
        ) || continue
        push!(model_diff, model_dx[i + 1] - model_dx[i])
        push!(observed_diff, observed_dx[i + 1] - observed_dx[i])
    end

    return (
        rmse = rmse,
        mae = mae,
        rmse_standardized = obs_std > 0.0 ? rmse / obs_std : nothing,
        correlation_level = _capex_validation_corr(model_values, observed_values),
        correlation_diff = _capex_validation_corr(model_diff, observed_diff),
        bias = bias,
        n_pairs = n_pairs,
        n_excluded = n_excluded,
    )
end

function _capex_validation_direction_agreement(
    model_dx::Vector{Float64},
    observed_dx::Vector{Float64},
)::NamedTuple
    length(model_dx) == length(observed_dx) ||
        throw(ArgumentError("方向性の系列長が一致しません"))
    comparable = 0
    matches = 0
    for i in 1:(length(model_dx) - 1)
        (
            isfinite(model_dx[i]) &&
            isfinite(model_dx[i + 1]) &&
            isfinite(observed_dx[i]) &&
            isfinite(observed_dx[i + 1])
        ) || continue
        comparable += 1
        sign(model_dx[i + 1] - model_dx[i]) == sign(observed_dx[i + 1] - observed_dx[i]) &&
            (matches += 1)
    end
    return (
        agreement = comparable == 0 ? nothing : matches / comparable,
        n_pairs = comparable,
    )
end

function _capex_validation_nearest_timing_error(
    observed_periods::Vector{Int},
    model_periods::Vector{Int},
)::Union{Float64, Nothing}
    (isempty(observed_periods) || isempty(model_periods)) && return nothing
    return sum(
        minimum(abs(observed - model) for model in model_periods) for
        observed in observed_periods
    ) / length(observed_periods)
end

# ---------------------------------------------------------------------------
# catalog / variable metadata からの適用可否
# ---------------------------------------------------------------------------

function _capex_validation_source_specs(
    ds::CapexEmpiricalDataset,
    model_var::Symbol,
)::Vector{CapexSeriesSpec}
    specs = CapexSeriesSpec[
        measurement.spec for measurement in values(ds.measurements) if
        model_var in measurement.spec.model_vars
    ]
    sort!(specs; by = spec -> String(spec.key))
    return specs
end

function _capex_validation_evidence_tier(specs::Vector{CapexSeriesSpec})::Symbol
    isempty(specs) && return :direct
    methods = Set(spec.methodology for spec in specs)
    :proxy in methods && return :proxy
    :allocation in methods && return :allocation
    (length(specs) > 1 || :aggregation in methods) && return :composed
    return :direct
end

function _capex_validation_observability(
    run::CapexHistoricalReplayRun,
    model_var::Symbol,
)::Symbol
    if run.result !== nothing
        values = get(run.result.metadata, "variable_observability", nothing)
        if values isa AbstractDict
            observed = get(values, String(model_var), nothing)
            observed isa AbstractString && return Symbol(observed)
        end
    end
    return haskey(_CCC_VAR_META, model_var) ? Symbol(_CCC_VAR_META[model_var][4]) : :A
end

function _capex_validation_series_key(
    model_var::Symbol,
    specs::Vector{CapexSeriesSpec},
)::Symbol
    return length(specs) == 1 ? only(specs).key : model_var
end

function _capex_validation_applicability(observability::Symbol, has_deviation::Bool)::Symbol
    observability in (:E, :A) && return :not_applicable_latent
    observability === :P && return :not_applicable_role
    return has_deviation ? :applicable : :unavailable_data
end

function _capex_validation_fit_caveats(
    observability::Symbol,
    evidence_tier::Symbol,
    applicability::Symbol,
    n_excluded::Int,
)::Vector{String}
    caveats = String[]
    observability in (:E, :A) && push!(
        caveats,
        "observability=$(observability) の潜在・会計上の内生系列には fit metric を適用しない。",
    )
    observability === :P &&
        push!(caveats, "proxy 系列は数値 fit の根拠に使わず、動学的な記述に限定する。")
    evidence_tier in (:proxy, :allocation) &&
        push!(caveats, "evidence_tier=$(evidence_tier) のため direct 観測と同一視しない。")
    applicability === :unavailable_data &&
        push!(caveats, "評価期間または助走 baseline に有効な観測・モデルの組がない。")
    n_excluded > 0 && push!(
        caveats,
        "評価期間の $(n_excluded) 期は欠損または打ち切り後の非有限値のため除外した（0 補完しない）。",
    )
    return caveats
end

function _capex_validation_dimension_status(
    eligible::Int,
    evaluated::Int,
    unavailable_reason::String,
)::NamedTuple
    status = if eligible == 0 || evaluated == 0
        :unavailable
    elseif evaluated < eligible
        :partially_available
    else
        :available
    end
    reason = status === :unavailable ? unavailable_reason : nothing
    return (
        status = status,
        unavailable_reason = reason,
        eligible = eligible,
        evaluated = evaluated,
    )
end

function _capex_validation_propagation_edge(
    upstream::Symbol,
    downstream::Symbol,
    onsets::Dict{Symbol, Union{Int, Nothing}},
)::NamedTuple
    upstream_onset = get(onsets, upstream, nothing)
    downstream_onset = get(onsets, downstream, nothing)
    status = if upstream_onset === nothing || downstream_onset === nothing
        :unavailable
    elseif upstream_onset <= downstream_onset
        :consistent
    else
        :reversed
    end
    return (
        upstream = upstream,
        downstream = downstream,
        upstream_onset = upstream_onset,
        downstream_onset = downstream_onset,
        status = status,
    )
end

function _capex_validation_propagation(
    model_onsets::Dict{Symbol, Union{Int, Nothing}},
    observed_onsets::Dict{Symbol, Union{Int, Nothing}},
)::NamedTuple
    ordered(onsets) = sort(
        [
            variable for variable in CAPEX_CC_PROPAGATION_PATH if
            get(onsets, variable, nothing) !== nothing
        ];
        by = variable -> (onsets[variable], String(variable)),
    )
    model_edges = [
        _capex_validation_propagation_edge(a, b, model_onsets) for
        (a, b) in _CAPEX_CC_PROPAGATION_EDGES
    ]
    observed_edges = [
        _capex_validation_propagation_edge(a, b, observed_onsets) for
        (a, b) in _CAPEX_CC_PROPAGATION_EDGES
    ]
    return (
        expected_path = collect(CAPEX_CC_PROPAGATION_PATH),
        model_order = ordered(model_onsets),
        observed_order = ordered(observed_onsets),
        model_edges = model_edges,
        observed_edges = observed_edges,
        interpretation = "onset order only; not a statistical causal contribution",
    )
end

# ---------------------------------------------------------------------------
# report の構築
# ---------------------------------------------------------------------------

function _capex_validation_empty_report(
    run::CapexHistoricalReplayRun,
    reason::String,
)::CapexEmpiricalValidationReport
    statuses = Dict{Symbol, NamedTuple}(
        dimension => _capex_validation_dimension_status(0, 0, reason) for
        dimension in CAPEX_CC_VALIDATION_DIMENSIONS
    )
    metadata = Dict{String, Any}(
        "validation_version" => CAPEX_CC_EMPIRICAL_VALIDATION_VERSION,
        "turning_point_rule_version" => SCENARIO_TURNING_POINT_RULE_VERSION,
        "onset_rule_version" => "scenario-diagnostics-thresholds/1.0.0",
        "replay_hash" => run.replay_hash,
        "dataset_hash" => run.dataset_hash,
        "replay_status" => String(run.status),
    )
    return CapexEmpiricalValidationReport(
        run.episode.id,
        run.parameter_set.kind,
        run.in_sample,
        Dict{Symbol, CapexSeriesFit}(),
        Dict{Symbol, NamedTuple}(),
        Symbol[],
        Symbol[],
        Dict{Symbol, Float64}(),
        Dict{Symbol, Int}(),
        Dict{Symbol, Int}(),
        Dict{String, Float64}(),
        _capex_validation_propagation(
            Dict{Symbol, Union{Int, Nothing}}(),
            Dict{Symbol, Union{Int, Nothing}}(),
        ),
        :unavailable,
        nothing,
        statuses,
        vcat(run.warnings, [reason]),
        copy(CAPEX_CC_EMPIRICAL_VALIDATION_CAVEATS),
        metadata,
    )
end

"""
    validate_capex_empirical(run, ds) -> CapexEmpiricalValidationReport

`capex_historical_replay` の 1 run を、評価期間だけの baseline 比乖離で検証する。
`run.status == :rejected_input` は例外にせず、全 dimension を `:unavailable` とした report を
返す。打ち切り run は、モデル・観測がともに有限な有効ペアのみを評価し、後続を 0 補完しない。

`D/C` の数値 fit、`P` の記述的な動学診断、`E/A` の非適用を分離する。parameter set と
`in_sample` は report 自体に記録されるため、literature/default・calibrated・estimated および
in/out-of-sample の run は同一 schema で並置できる。
"""
function validate_capex_empirical(
    run::CapexHistoricalReplayRun,
    ds::CapexEmpiricalDataset,
)::CapexEmpiricalValidationReport
    ds_hash = get(ds.metadata, "dataset_hash", "")
    run.dataset_hash == ds_hash ||
        throw(ArgumentError("run.dataset_hash と ds の dataset_hash が一致しません"))
    run.model_run === nothing && return _capex_validation_empty_report(
        run,
        "model run が無いため validation を実行できません（rejected input は fail closed）。",
    )

    model_run = run.model_run
    runup_indices = findall(<(0), model_run.periods)
    eval_indices = findall(>=(0), model_run.periods)
    isempty(runup_indices) && return _capex_validation_empty_report(
        run,
        "助走期間が無いため baseline 比乖離を定義できません。",
    )
    isempty(eval_indices) && return _capex_validation_empty_report(
        run,
        "評価期間が無いため validation を実行できません。",
    )
    eval_periods = model_run.periods[eval_indices]
    thresholds = ScenarioDiagnosticThresholds(
        id = "capex-empirical-validation",
        version = "capex-empirical-validation-onset/1.0.0",
    )

    model_variables = Set(Symbol(variable) for variable in keys(model_run.series))
    variables = sort(collect(union(model_variables, Set(keys(run.observed)))); by = String)
    fits = Dict{Symbol, CapexSeriesFit}()
    turning_points = Dict{Symbol, NamedTuple}()
    direction_agreement = Dict{Symbol, Float64}()
    persistence = Dict{Symbol, Int}()
    persistence_observed = Dict{Symbol, Int}()
    model_onsets = Dict{Symbol, Union{Int, Nothing}}()
    observed_onsets = Dict{Symbol, Union{Int, Nothing}}()
    warnings = copy(run.warnings)

    numeric_eligible = 0
    numeric_evaluated = 0
    dynamic_eligible = 0
    dynamic_evaluated = 0
    timing_evaluated = 0
    direction_evaluated = 0
    persistence_evaluated = 0

    for variable in variables
        specs = _capex_validation_source_specs(ds, variable)
        key = _capex_validation_series_key(variable, specs)
        observability = _capex_validation_observability(run, variable)
        evidence_tier = _capex_validation_evidence_tier(specs)
        observed_series = get(run.observed, variable, nothing)
        model_series =
            variable in model_variables ? getproperty(model_run.series, variable) : nothing
        model_deviation =
            model_series === nothing ? nothing :
            _capex_validation_deviation(model_series, runup_indices, eval_indices)
        observed_deviation =
            observed_series === nothing ? nothing :
            _capex_validation_deviation(observed_series, runup_indices, eval_indices)
        has_deviation = model_deviation !== nothing && observed_deviation !== nothing
        applicability = _capex_validation_applicability(observability, has_deviation)

        fit_metrics =
            has_deviation ?
            _capex_validation_fit_metrics(
                model_deviation.deviations,
                observed_deviation.deviations,
            ) :
            (
                rmse = nothing,
                mae = nothing,
                rmse_standardized = nothing,
                correlation_level = nothing,
                correlation_diff = nothing,
                bias = nothing,
                n_pairs = 0,
                n_excluded = length(eval_indices),
            )
        fit_caveats = _capex_validation_fit_caveats(
            observability,
            evidence_tier,
            applicability,
            fit_metrics.n_excluded,
        )

        if observability in (:D, :C)
            numeric_eligible += 1
            applicability === :applicable &&
                fit_metrics.n_pairs > 0 &&
                (numeric_evaluated += 1)
        end
        fits[variable] = CapexSeriesFit(
            key,
            variable,
            observability,
            applicability,
            evidence_tier,
            applicability === :applicable ? fit_metrics.rmse : nothing,
            applicability === :applicable ? fit_metrics.mae : nothing,
            applicability === :applicable ? fit_metrics.rmse_standardized : nothing,
            applicability === :applicable ? fit_metrics.correlation_level : nothing,
            applicability === :applicable ? fit_metrics.correlation_diff : nothing,
            applicability === :applicable ? fit_metrics.bias : nothing,
            applicability === :applicable ? fit_metrics.n_pairs : 0,
            fit_metrics.n_excluded,
            fit_caveats,
        )

        # P は数値 fit から除外するが、proxy であることを保持したうえで timing / propagation
        # の記述には使える。E/A は観測比較そのものを作らない。
        (observability in (:D, :C, :P) && has_deviation) || continue
        dynamic_eligible += 1
        model_dx = model_deviation.deviations
        observed_dx = observed_deviation.deviations
        model_rel = Union{Float64, Missing}[
            _scenario_diag_rel(
                model_dx[i],
                model_deviation.baseline,
                thresholds.rel_denominator_floor,
            ) for i in eachindex(model_dx)
        ]
        observed_rel = Union{Float64, Missing}[
            _scenario_diag_rel(
                observed_dx[i],
                observed_deviation.baseline,
                thresholds.rel_denominator_floor,
            ) for i in eachindex(observed_dx)
        ]
        model_breach =
            _scenario_diag_breach(model_dx, model_rel, length(model_dx), thresholds)
        observed_breach = _scenario_diag_breach(
            observed_dx,
            observed_rel,
            length(observed_dx),
            thresholds,
        )
        model_onset =
            _scenario_diag_onset(model_breach, eval_periods, thresholds.onset_persistence)
        observed_onset = _scenario_diag_onset(
            observed_breach,
            eval_periods,
            thresholds.onset_persistence,
        )
        model_onsets[variable] = model_onset
        observed_onsets[variable] = observed_onset
        model_turns = _scenario_diag_turning_points(model_dx, eval_periods)
        observed_turns = _scenario_diag_turning_points(observed_dx, eval_periods)
        turning_points[variable] = (
            model_peaks = model_turns.peaks,
            observed_peaks = observed_turns.peaks,
            model_troughs = model_turns.troughs,
            observed_troughs = observed_turns.troughs,
            model_peak_count = length(model_turns.peaks),
            observed_peak_count = length(observed_turns.peaks),
            model_trough_count = length(model_turns.troughs),
            observed_trough_count = length(observed_turns.troughs),
            peak_timing_error = _capex_validation_nearest_timing_error(
                observed_turns.peaks,
                model_turns.peaks,
            ),
            trough_timing_error = _capex_validation_nearest_timing_error(
                observed_turns.troughs,
                model_turns.troughs,
            ),
            model_onset = model_onset,
            observed_onset = observed_onset,
            onset_lead_lag = model_onset === nothing || observed_onset === nothing ?
                             nothing : model_onset - observed_onset,
        )
        persistence[variable] = _scenario_diag_persistence_duration(model_breach)
        persistence_observed[variable] =
            _scenario_diag_persistence_duration(observed_breach)
        dynamic_evaluated += 1
        persistence_evaluated += 1

        direction = _capex_validation_direction_agreement(model_dx, observed_dx)
        if direction.agreement !== nothing
            direction_agreement[variable] = direction.agreement
            direction_evaluated += 1
        end
        model_onset !== nothing && observed_onset !== nothing && (timing_evaluated += 1)
    end

    onset_order = sort(
        [variable for (variable, onset) in model_onsets if onset !== nothing];
        by = variable -> (model_onsets[variable], String(variable)),
    )
    onset_order_observed = sort(
        [variable for (variable, onset) in observed_onsets if onset !== nothing];
        by = variable -> (observed_onsets[variable], String(variable)),
    )
    propagation = _capex_validation_propagation(model_onsets, observed_onsets)

    accounting = validate_capex_accounting(run.model, model_run)
    accounting_passed(accounting) || push!(
        warnings,
        "accounting=$(accounting_status_label(accounting.status)): 会計検証が全項目 acc_pass ではない。",
    )
    diagnostic = try
        capex_diagnostics(run.model, model_run; accounting = accounting)
    catch error
        error isa ArgumentError || rethrow()
        push!(warnings, "diagnostic_label_unavailable: $(sprint(showerror, error))")
        nothing
    end
    diagnostic_label = diagnostic === nothing ? :unavailable : diagnostic.label

    credit_amplification = Dict{String, Float64}()
    credit_reason = "credit-off 反実仮想を評価できませんでした。"
    try
        amplification = _capex_amplification(run.model, model_run)
        if amplification === nothing
            credit_reason = "credit-off の peak が 0 または非有限のため、増幅比 A を定義できません。"
        else
            credit_amplification["A_credit_off"] = amplification
        end
    catch error
        error isa ArgumentError || rethrow()
        credit_reason = "credit-off 反実仮想を評価できませんでした: $(sprint(showerror, error))"
        push!(warnings, "credit_amplification_unavailable: $(sprint(showerror, error))")
    end

    propagation_eligible = length(_CAPEX_CC_PROPAGATION_EDGES)
    propagation_evaluated =
        count(edge -> edge.status !== :unavailable, propagation.observed_edges)
    statuses = Dict{Symbol, NamedTuple}(
        :numerical_fit => _capex_validation_dimension_status(
            numeric_eligible,
            numeric_evaluated,
            "D/C 分類で有効な model-observed pair がありません。",
        ),
        :turning_point => _capex_validation_dimension_status(
            dynamic_eligible,
            dynamic_evaluated,
            "D/C/P 分類で baseline と評価期間の両方が利用可能な系列がありません。",
        ),
        :timing => _capex_validation_dimension_status(
            dynamic_eligible,
            timing_evaluated,
            "model と observed の両方で持続的な onset が検出されませんでした。",
        ),
        :direction => _capex_validation_dimension_status(
            dynamic_eligible,
            direction_evaluated,
            "方向性を比較できる連続した有効 period pair がありません。",
        ),
        :persistence => _capex_validation_dimension_status(
            dynamic_eligible,
            persistence_evaluated,
            "持続期間を評価できる系列がありません。",
        ),
        :credit_amplification => _capex_validation_dimension_status(
            1,
            isempty(credit_amplification) ? 0 : 1,
            credit_reason,
        ),
        :propagation => _capex_validation_dimension_status(
            propagation_eligible,
            propagation_evaluated,
            "部門波及の隣接系列に observed onset が揃いませんでした。",
        ),
    )

    run.status === :terminated && push!(
        warnings,
        "terminated run: 有効期間だけを評価し、打ち切り後の非有限値は除外した（0 補完しない）。",
    )
    weak_parameters = sort([
        String(parameter) for
        (parameter, source) in run.parameter_set.parameter_source if
        startswith(String(source), "demoted_")
    ],)
    !isempty(weak_parameters) && push!(
        warnings,
        "weak identification の降格パラメータ: $(join(weak_parameters, ", "))",
    )

    metadata = Dict{String, Any}(
        "validation_version" => CAPEX_CC_EMPIRICAL_VALIDATION_VERSION,
        "turning_point_rule_version" => SCENARIO_TURNING_POINT_RULE_VERSION,
        "onset_rule_version" => thresholds.version,
        "onset_thresholds" => Dict(
            "absolute" => thresholds.onset_abs,
            "relative" => thresholds.onset_rel,
            "persistence" => thresholds.onset_persistence,
            "rel_denominator_floor" => thresholds.rel_denominator_floor,
        ),
        "comparison_scale" => "baseline_deviation",
        "evaluation_periods" => eval_periods,
        "replay_hash" => run.replay_hash,
        "dataset_hash" => run.dataset_hash,
        "parameter_set_hash" => run.parameter_set_hash,
        "parameter_set_kind" => String(run.parameter_set.kind),
        "in_sample" => run.in_sample,
        "replay_status" => String(run.status),
        "credit_amplification_definition" => "A = |peak(dI_full)| / |peak(dI_credit_off)|; model-internal counterfactual only",
        "metric_policy" => Dict(
            "D/C" => "numerical fit and dynamic diagnostics",
            "P" => "dynamic diagnostics only; not numerical-fit evidence",
            "E/A" => "not applicable; latent or accounting-internal",
        ),
    )

    return CapexEmpiricalValidationReport(
        run.episode.id,
        run.parameter_set.kind,
        run.in_sample,
        fits,
        turning_points,
        onset_order,
        onset_order_observed,
        direction_agreement,
        persistence,
        persistence_observed,
        credit_amplification,
        propagation,
        diagnostic_label,
        accounting,
        statuses,
        sort(unique(warnings)),
        copy(CAPEX_CC_EMPIRICAL_VALIDATION_CAVEATS),
        metadata,
    )
end

# ---------------------------------------------------------------------------
# 機械可読な report 出力
# ---------------------------------------------------------------------------

_capex_validation_json_number(::Nothing) = nothing
_capex_validation_json_number(value::Real) = isfinite(value) ? Float64(value) : nothing

function _capex_validation_namedtuple_to_dict(value::NamedTuple)::Dict{String, Any}
    return Dict(
        String(key) => _capex_validation_json_value(item) for (key, item) in pairs(value)
    )
end

function _capex_validation_json_value(value)
    value isa NamedTuple && return _capex_validation_namedtuple_to_dict(value)
    value isa Symbol && return String(value)
    value isa Real && return _capex_validation_json_number(value)
    value isa AbstractVector &&
        return [_capex_validation_json_value(item) for item in value]
    value isa AbstractDict && return Dict(
        String(key) => _capex_validation_json_value(item) for (key, item) in value
    )
    return value
end

function _capex_validation_fit_to_dict(fit::CapexSeriesFit)::Dict{String, Any}
    return Dict(
        "key" => String(fit.key),
        "model_var" => String(fit.model_var),
        "observability" => String(fit.observability),
        "applicability" => String(fit.applicability),
        "evidence_tier" => String(fit.evidence_tier),
        "rmse" => _capex_validation_json_number(fit.rmse),
        "mae" => _capex_validation_json_number(fit.mae),
        "rmse_standardized" => _capex_validation_json_number(fit.rmse_standardized),
        "correlation_level" => _capex_validation_json_number(fit.correlation_level),
        "correlation_diff" => _capex_validation_json_number(fit.correlation_diff),
        "bias" => _capex_validation_json_number(fit.bias),
        "n_pairs" => fit.n_pairs,
        "n_excluded" => fit.n_excluded,
        "caveats" => fit.caveats,
    )
end

"""
    capex_empirical_validation_report_to_dict(report) -> Dict{String,Any}

検証 report を JSON に保存できる辞書へ変換する。非有限数は `null` とし、打ち切り後の値を
0 には変換しない。
"""
function capex_empirical_validation_report_to_dict(
    report::CapexEmpiricalValidationReport,
)::Dict{String, Any}
    accounting = report.accounting === nothing ? nothing : to_dict(report.accounting)
    return Dict(
        "validation_version" => CAPEX_CC_EMPIRICAL_VALIDATION_VERSION,
        "episode" => String(report.episode),
        "parameter_set_kind" => String(report.parameter_set_kind),
        "in_sample" => report.in_sample,
        "fits" => Dict(
            String(variable) => _capex_validation_fit_to_dict(fit) for
            (variable, fit) in report.fits
        ),
        "turning_points" => Dict(
            String(variable) => _capex_validation_namedtuple_to_dict(turning) for
            (variable, turning) in report.turning_points
        ),
        "onset_order" => String.(report.onset_order),
        "onset_order_observed" => String.(report.onset_order_observed),
        "direction_agreement" => Dict(
            String(variable) => value for (variable, value) in report.direction_agreement
        ),
        "persistence" =>
            Dict(String(variable) => value for (variable, value) in report.persistence),
        "persistence_observed" => Dict(
            String(variable) => value for (variable, value) in report.persistence_observed
        ),
        "credit_amplification" => report.credit_amplification,
        "propagation" => _capex_validation_namedtuple_to_dict(report.propagation),
        "diagnostic_label" => String(report.diagnostic_label),
        "accounting" => accounting,
        "dimension_status" => Dict(
            String(dimension) => _capex_validation_namedtuple_to_dict(status) for
            (dimension, status) in report.dimension_status
        ),
        "warnings" => report.warnings,
        "caveats" => report.caveats,
        "metadata" => _capex_validation_json_value(report.metadata),
    )
end

"""
    save_capex_empirical_validation_report(path, report) -> path

`capex_empirical_validation_report_to_dict(report)` を整形 JSON として保存する。
"""
function save_capex_empirical_validation_report(
    path::AbstractString,
    report::CapexEmpiricalValidationReport,
)
    open(path, "w") do io
        JSON3.pretty(io, capex_empirical_validation_report_to_dict(report))
    end
    return path
end
