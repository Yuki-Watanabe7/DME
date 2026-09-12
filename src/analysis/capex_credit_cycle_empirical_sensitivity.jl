# 部門別CAPEX・信用循環モデル（CCC）の実証robustness/sensitivity層（Issue #250 / P-10）。
#
# #249（capex_credit_cycle_empirical_validation.jl）が返す dimension 別 validation を基準に、
# proxy・sample window・series exclusion・event timing・event magnitude・weak identification
# パラメータ（W2 範囲報告・W3 複数仕様）・診断閾値の7 axis を **1 axis ずつ**動かし、baseline から
# 厳密に1点だけを変更した variant を生成して #249 の validation を再計算する。単一の総合スコア・
# 確率的予測・best-fit の自動選択を行わない（実証戦略 §10.1・§7.6・ADR 0012 決定 19）。
#
# Design: docs/models/capex_credit_cycle_empirical_strategy.md §7.6・§8.2–8.3・§9.3・§10（検証指標の
# 分離契約）・docs/architecture/capex_credit_cycle_empirical_integration.md §9–§11・
# ADR 0012 決定 19（診断閾値を較正しない）・ADR 0018 決定 19–22（検証を型として作らない集約規約）。
#
# depends on: analysis/capex_credit_cycle_historical_replay.jl（`CapexHistoricalReplayRun`・
# `CapexReplayOptions`・`capex_historical_replay`）・
# analysis/capex_credit_cycle_empirical_validation.jl（`CapexEmpiricalValidationReport`・
# `validate_capex_empirical`・`_capex_validation_json_value`・`_capex_validation_namedtuple_to_dict`。
# JSON 変換ヘルパを再利用し、同じ null 化・Symbol→String 規約を保つ）・
# analysis/capex_credit_cycle_history.jl（`CapexHistoricalEpisodeSpec`）・
# analysis/capex_credit_cycle_estimation.jl（`CapexParameterSet`）・
# analysis/capex_credit_cycle_diagnostics.jl（`capex_label_sensitivity`・`CapexDiagnosticThresholds`）・
# analysis/scenario_diagnostics.jl（`_scenario_shift_event_timing`・`_scenario_rebuild_assumption`。
# 本ファイルより後で include されるが、Julia は関数本体の呼び出しを呼び出し時に解決するため、
# capex_credit_cycle_historical_replay.jl が scenario_provenance.jl の関数を同じ理由で先に参照
# できているのと同じ規約で問題ない）・data/capex_credit_cycle_measurements.jl
# （`CapexEmpiricalDataset`・`CapexMeasurement`）・models/capex_credit_cycle.jl
# （`CapexCreditCycleModel`）・scenarios/scenario_time.jl（`CalendarQuarter`）。
#
# 読み取り専用の後処理層。provider / HTTP を呼ばない。モデル方程式・イベント層 API を変更しない
# （既存の低レベル部品 `capex_historical_replay`・`validate_capex_empirical`・
# `capex_label_sensitivity` を axis ごとに1点だけ変更した入力で呼び直すだけである）。

# ---------------------------------------------------------------------------
# 語彙定数
# ---------------------------------------------------------------------------

"本層の methodology version。"
const CAPEX_CC_EMPIRICAL_SENSITIVITY_VERSION = "capex-credit-cycle-empirical-sensitivity/1.0.0"

"""
    CAPEX_CC_SENSITIVITY_AXES

Issue #250 本文が列挙する7 sensitivity axis。**一度に複数軸を動かさない**（one-axis-at-a-time、
実証戦略 §10.1 の分離契約と同じ精神）。

- `:proxy`: primary series vs 許可された fallback proxy（catalog 上で同一 model_var へ複数の
  直接ソースを持つ場合のみ自動生成する。現行 catalog では `spread`（HY/IG）が該当する。
  allocation key・y_s のアンカー基準年・ycap_s の FRB Capacity 代替は本 suite では自動化しない
  （`CAPEX_CC_EMPIRICAL_SENSITIVITY_CAVEATS` に明記）。
- `:sample_window`: 評価窓の起点を事前定義した四半期数だけシフトする。
- `:series_exclusion`: `:calibration_required` 以外の観測比較系列を1本ずつ除外する（較正必須
  契約を破らない範囲）。
- `:event_timing`: episode の `assumptions` の timing を ±1Q（既定）ずらす。
- `:event_magnitude`: `magnitude_source = :assumed_default` の assumption の magnitude を
  ±ratio 倍する（推定誤差ではなく scenario assumption sensitivity として扱う）。
- `:parameter_weak_id`: `CapexParameterSet.ranges`（W2 範囲報告）・`alternate_specs`（W3 複数
  仕様）に登録済みのパラメータを、その範囲端・代替仕様値へ動かす。
- `:diagnostic_threshold`: 既存の `capex_label_sensitivity`（±50%）をそのまま再利用する。
"""
const CAPEX_CC_SENSITIVITY_AXES = (
    :proxy,
    :sample_window,
    :series_exclusion,
    :event_timing,
    :event_magnitude,
    :parameter_weak_id,
    :diagnostic_threshold,
)

"variant 実行ステータス。失敗した variant は除外せず `:failed` として保持する。"
const CAPEX_CC_SENSITIVITY_VARIANT_STATUSES = (:evaluated, :failed)

"各 axis・各 dimension の安定性判定を保持する固定 key の集合。"
const CAPEX_CC_SENSITIVITY_STABILITY_DIMENSIONS =
    (:diagnostic_label, :onset_order, :credit_amplification, :propagation)

"""
    CAPEX_CC_EMPIRICAL_SENSITIVITY_CAVEATS

すべての report に添える固定の解釈上の制限。
"""
const CAPEX_CC_EMPIRICAL_SENSITIVITY_CAVEATS = String[
    "各variantはbaselineから厳密に1点だけを変更する（one-axis-at-a-time）。複数軸を同時に動かすcombinatorial searchではない。",
    "失敗・拒否されたvariantは除外せず、failure_reasonとともに保持する。平均を取って隠さない。",
    "best-fitとなるproxy・sample・仕様・パラメータ値を自動選択しない。",
    "diagnostic labelが変化する境界を記録するが、recession probability等の確率的予測へ変換しない。",
    "event magnitude感応度はmagnitude_source=:assumed_defaultの仮定のみに適用し、推定誤差ではなくscenario assumption sensitivityとして扱う。",
    "allocation key（sales_sシェア/cap_sシェア）・y_sのアンカー基準年・ycap_sのFRB Capacity代替は、" * "本suiteでは自動化していない（catalog上で同一model_varへ複数の直接ソースを持つ場合のみ" * "proxy軸を自動生成する）。",
    "credit amplificationはcredit-off反実仮想の定義のみを参照し、観測から増幅度を推定しない。",
    "各variantの安定性は#249と同じdimension別validationの再計算から得る。dimensionを跨いだ単一スコアへ集約しない。",
]

# ---------------------------------------------------------------------------
# EmpiricalSensitivitySpec（variant 1個が baseline から何を1点変更したかの宣言）
# ---------------------------------------------------------------------------

"""
    EmpiricalSensitivitySpec

sensitivity variant 1個の宣言的仕様。baseline から**厳密に1点**変更した内容を機械可読に保持する
（実証戦略 §10.4 の「仕様・proxy・標本・イベント写像を変えて結論が変わるか」の記録契約）。
"""
struct EmpiricalSensitivitySpec
    id::String
    axis::Symbol
    changed_field::String
    changed_from::String
    changed_to::String
    description::String
    metadata::Dict{String, Any}

    function EmpiricalSensitivitySpec(;
        id::AbstractString,
        axis::Symbol,
        changed_field::AbstractString,
        changed_from::AbstractString,
        changed_to::AbstractString,
        description::AbstractString,
        metadata::Dict{String, Any} = Dict{String, Any}(),
    )
        axis in CAPEX_CC_SENSITIVITY_AXES || throw(
            ArgumentError("未知の axis :$(axis)（許容: $(CAPEX_CC_SENSITIVITY_AXES)）"),
        )
        return new(
            String(id),
            axis,
            String(changed_field),
            String(changed_from),
            String(changed_to),
            String(description),
            metadata,
        )
    end
end

"""
    EmpiricalSensitivityVariantResult

variant 1個の実行結果。`status === :failed` でも `spec` は保持され、黙って除外されない。
`stability` は baseline との比較（`true`/`false`）または比較不能（`nothing`）を
`CAPEX_CC_SENSITIVITY_STABILITY_DIMENSIONS` の4 key で持つ。
"""
struct EmpiricalSensitivityVariantResult
    spec::EmpiricalSensitivitySpec
    status::Symbol
    failure_reason::Union{String, Nothing}
    replay_status::Union{Symbol, Nothing}
    report::Union{CapexEmpiricalValidationReport, Nothing}
    diagnostic_label::Union{Symbol, Nothing}
    stability::Dict{Symbol, Union{Bool, Nothing}}
end

"""
    EmpiricalRobustnessReport

`capex_empirical_sensitivity_suite` の戻り値。baseline の `CapexEmpiricalValidationReport` と、
axis 別の variant 一覧・axis 別の可用性・axis×dimension の安定性集計を分離して保持する
（実証戦略 §10.1 と同じ「単一スコアへ集約しない」規律）。
"""
struct EmpiricalRobustnessReport
    episode::Symbol
    parameter_set_kind::Symbol
    baseline_report::CapexEmpiricalValidationReport
    variants::Dict{Symbol, Vector{EmpiricalSensitivityVariantResult}}
    axis_status::Dict{Symbol, NamedTuple}
    stability_summary::Dict{Symbol, Dict{Symbol, NamedTuple}}
    label_boundary_variants::Vector{String}
    warnings::Vector{String}
    caveats::Vector{String}
    metadata::Dict{String, Any}
end

# ---------------------------------------------------------------------------
# 小さな純関数（CalendarQuarter シフト・episode 再構築）
# ---------------------------------------------------------------------------

function _capex_sensitivity_shift_calendar_quarter(
    q::CalendarQuarter,
    delta::Int,
)::CalendarQuarter
    abs_idx = q.year * 4 + (q.quarter - 1) + delta
    return CalendarQuarter(fld(abs_idx, 4), mod(abs_idx, 4) + 1)
end

_capex_sensitivity_quarter_label(q::CalendarQuarter) = "$(q.year)-Q$(q.quarter)"

"""`ep` の一部フィールドだけを差し替えた新しい `CapexHistoricalEpisodeSpec` を返す。"""
function _capex_sensitivity_rebuild_episode(
    ep::CapexHistoricalEpisodeSpec;
    period_zero::CalendarQuarter = ep.period_zero,
    assumptions::Vector{ScenarioAssumption} = ep.assumptions,
    label_suffix::AbstractString = "",
)::CapexHistoricalEpisodeSpec
    return CapexHistoricalEpisodeSpec(;
        id = ep.id,
        label = isempty(label_suffix) ? ep.label : ep.label * " " * label_suffix,
        period_zero = period_zero,
        runup_quarters = ep.runup_quarters,
        eval_quarters = ep.eval_quarters,
        observed_events = ep.observed_events,
        assumptions = assumptions,
        interpretation_notes = ep.interpretation_notes,
        in_sample = ep.in_sample,
        notes = ep.notes,
        special_factors = ep.special_factors,
        data_definition_break_resolved = ep.data_definition_break_resolved,
        expected_diagnostic_label = ep.expected_diagnostic_label,
    )
end

"""`ds.measurements` だけを差し替えた新しい `CapexEmpiricalDataset` を返す。`dataset_hash` を
含む `metadata` は変更しない（proxy 選択・除外は raw provenance を書き換える操作ではなく、
同一 dataset に対する観測比較の選び方の違いであるため）。"""
function _capex_sensitivity_dataset_with_measurements(
    ds::CapexEmpiricalDataset,
    measurements::Dict{Symbol, CapexMeasurement},
)::CapexEmpiricalDataset
    return CapexEmpiricalDataset(
        ds.catalog,
        measurements,
        ds.dates,
        ds.observation_times,
        ds.values,
        ds.roles,
        ds.observability,
        ds.sample,
        ds.vintage_mode,
        ds.quality_flags,
        ds.raw,
        ds.metadata,
    )
end

# ---------------------------------------------------------------------------
# axis 別 variant 生成
# ---------------------------------------------------------------------------

"""axis `:sample_window`: 評価窓の起点を `shifts`（四半期数、既定 `[-4,-1,1,4]`）だけシフトする。"""
function _capex_sensitivity_window_variants(
    ep::CapexHistoricalEpisodeSpec,
    shifts::Vector{Int},
)::Vector{Tuple{EmpiricalSensitivitySpec, CapexHistoricalEpisodeSpec}}
    out = Tuple{EmpiricalSensitivitySpec, CapexHistoricalEpisodeSpec}[]
    for shift in sort(unique(shifts))
        shift == 0 && continue
        new_pz = _capex_sensitivity_shift_calendar_quarter(ep.period_zero, shift)
        ep_variant = _capex_sensitivity_rebuild_episode(
            ep;
            period_zero = new_pz,
            label_suffix = "(sample window shift $(shift > 0 ? "+" : "")$(shift)Q)",
        )
        spec = EmpiricalSensitivitySpec(;
            id = "sample_window_shift_$(shift)",
            axis = :sample_window,
            changed_field = "period_zero",
            changed_from = _capex_sensitivity_quarter_label(ep.period_zero),
            changed_to = _capex_sensitivity_quarter_label(new_pz),
            description = "評価窓の起点を事前定義どおり$(shift)四半期シフトしたsample window変更感応度（runup_quarters/eval_quartersは不変）。",
            metadata = Dict{String, Any}("shift_quarters" => shift),
        )
        push!(out, (spec, ep_variant))
    end
    return out
end

"""axis `:event_timing`: `ep.assumptions` 全体のtimingを `±shift` 期（既定1Q）ずらす。
`ep.assumptions` が空なら空を返す（対象がない、という状態を明示的に表す）。"""
function _capex_sensitivity_timing_variants(
    ep::CapexHistoricalEpisodeSpec,
    shift::Int,
)::Vector{Tuple{EmpiricalSensitivitySpec, CapexHistoricalEpisodeSpec}}
    isempty(ep.assumptions) &&
        return Tuple{EmpiricalSensitivitySpec, CapexHistoricalEpisodeSpec}[]
    out = Tuple{EmpiricalSensitivitySpec, CapexHistoricalEpisodeSpec}[]
    for s in (-abs(shift), abs(shift))
        assumptions_variant = [
            _scenario_rebuild_assumption(
                a;
                timing = _scenario_shift_event_timing(a.timing, s),
            ) for a in ep.assumptions
        ]
        ep_variant = _capex_sensitivity_rebuild_episode(
            ep;
            assumptions = assumptions_variant,
            label_suffix = "(event timing $(s > 0 ? "+" : "")$(s)Q)",
        )
        spec = EmpiricalSensitivitySpec(;
            id = "event_timing_shift_$(s)",
            axis = :event_timing,
            changed_field = "assumptions[*].timing",
            changed_from = "baseline timing",
            changed_to = "shift=$(s)Q",
            description = "正典（シナリオ時間軸の意味論 §4.6）で許容されるイベントtimingの$(s)四半期感応度。",
            metadata = Dict{String, Any}("shift_quarters" => s),
        )
        push!(out, (spec, ep_variant))
    end
    return out
end

"""axis `:event_magnitude`: `magnitude_source === :assumed_default` の assumption のみを
`±ratio` 倍する（既定 `ratio = 0.5`）。対象が無ければ空を返す。"""
function _capex_sensitivity_magnitude_variants(
    ep::CapexHistoricalEpisodeSpec,
    ratio::Float64,
)::Vector{Tuple{EmpiricalSensitivitySpec, CapexHistoricalEpisodeSpec}}
    targets = [a for a in ep.assumptions if a.magnitude_source === :assumed_default]
    isempty(targets) && return Tuple{EmpiricalSensitivitySpec, CapexHistoricalEpisodeSpec}[]
    out = Tuple{EmpiricalSensitivitySpec, CapexHistoricalEpisodeSpec}[]
    for factor in (1 - ratio, 1 + ratio)
        assumptions_variant = [
            a.magnitude_source === :assumed_default ?
            _scenario_rebuild_assumption(a; magnitude = a.magnitude * factor) : a for
            a in ep.assumptions
        ]
        ep_variant = _capex_sensitivity_rebuild_episode(
            ep;
            assumptions = assumptions_variant,
            label_suffix = "(event magnitude ×$(round(factor; digits = 3)))",
        )
        spec = EmpiricalSensitivitySpec(;
            id = "event_magnitude_factor_$(round(factor; digits = 3))",
            axis = :event_magnitude,
            changed_field = "assumptions[magnitude_source=:assumed_default].magnitude",
            changed_from = "factor=1.0",
            changed_to = "factor=$(round(factor; digits = 3))",
            description = "assumed_default event magnitudeの±$(round(ratio * 100; digits = 1))%走査。推定誤差ではなくscenario assumption sensitivityとして扱う。",
            metadata = Dict{String, Any}("factor" => factor, "ratio" => ratio),
        )
        push!(out, (spec, ep_variant))
    end
    return out
end

"""axis `:proxy`: catalog 上で同一 model_var に複数の直接ソースを持ち、かつ methodology が
全て `:aggregation`（構成要素の和）ではない場合のみ、各ソースを単独採用する variant を生成する
（`:aggregation` のみの組は構成要素であり代替 proxy ではないため対象外にする）。"""
function _capex_sensitivity_proxy_variants(
    ds::CapexEmpiricalDataset,
)::Vector{Tuple{EmpiricalSensitivitySpec, CapexEmpiricalDataset}}
    groups = Dict{Symbol, Vector{Symbol}}()
    for (key, meas) in ds.measurements
        for mv in meas.spec.model_vars
            push!(get!(() -> Symbol[], groups, mv), key)
        end
    end
    out = Tuple{EmpiricalSensitivitySpec, CapexEmpiricalDataset}[]
    for mv in sort(collect(keys(groups)); by = String)
        group_keys = groups[mv]
        length(group_keys) >= 2 || continue
        methods = unique(ds.measurements[k].spec.methodology for k in group_keys)
        all(==(:aggregation), methods) && continue
        for k in sort(group_keys; by = String)
            others = [k2 for k2 in group_keys if k2 !== k]
            measurements_variant =
                Dict(key => meas for (key, meas) in ds.measurements if !(key in others))
            ds_variant =
                _capex_sensitivity_dataset_with_measurements(ds, measurements_variant)
            spec = EmpiricalSensitivitySpec(;
                id = "proxy_$(mv)_only_$(k)",
                axis = :proxy,
                changed_field = "measurements[$(mv)]",
                changed_from = "combined($(join(sort(String.(group_keys)), "+")))",
                changed_to = "single($(k))",
                description = "$(mv) の観測比較を単一系列 $(k) のみへ絞ったalternative proxy感応度（実証戦略 §10.4）。",
                metadata = Dict{String, Any}(
                    "model_var" => String(mv),
                    "kept_key" => String(k),
                    "dropped_keys" => String.(sort(others)),
                ),
            )
            push!(out, (spec, ds_variant))
        end
    end
    return out
end

"""axis `:series_exclusion`: `role !== :calibration_required` の観測比較系列を1本ずつ除外する
（較正必須契約を破らない範囲）。baseline report の `fits` に現れる model_var に寄与する系列
だけを対象にする（無関係な系列の除外は #249 の validation に影響しないため生成しない）。"""
function _capex_sensitivity_exclusion_variants(
    ds::CapexEmpiricalDataset,
    baseline_report::CapexEmpiricalValidationReport,
)::Vector{Tuple{EmpiricalSensitivitySpec, CapexEmpiricalDataset}}
    relevant_vars = Set(keys(baseline_report.fits))
    out = Tuple{EmpiricalSensitivitySpec, CapexEmpiricalDataset}[]
    for key in sort(collect(keys(ds.measurements)); by = String)
        meas = ds.measurements[key]
        meas.spec.role === :calibration_required && continue
        any(mv -> mv in relevant_vars, meas.spec.model_vars) || continue
        measurements_variant = Dict(k => v for (k, v) in ds.measurements if k !== key)
        ds_variant = _capex_sensitivity_dataset_with_measurements(ds, measurements_variant)
        spec = EmpiricalSensitivitySpec(;
            id = "exclude_$(key)",
            axis = :series_exclusion,
            changed_field = "measurements[$(key)]",
            changed_from = "present",
            changed_to = "excluded",
            description = "非calibration_required系列 $(key)（role=$(meas.spec.role)、model_vars=$(meas.spec.model_vars)）を観測比較から除外した感応度。",
            metadata = Dict{String, Any}(
                "excluded_key" => String(key),
                "role" => String(meas.spec.role),
                "model_vars" => String.(meas.spec.model_vars),
            ),
        )
        push!(out, (spec, ds_variant))
    end
    return out
end

"""axis `:parameter_weak_id`: `ps.ranges`（W2）の範囲端2点、`ps.alternate_specs`（W3）の各
代替仕様値を、既存 behavioral パラメータへ1個ずつ上書きした `NamedTuple`（`m.params` 全体）を
生成する。`ps.kind !== :estimated` では両辞書とも空であり、空を返す。"""
function _capex_sensitivity_parameter_variants(
    m::CapexCreditCycleModel,
    ps::CapexParameterSet,
)::Vector{Tuple{EmpiricalSensitivitySpec, NamedTuple}}
    out = Tuple{EmpiricalSensitivitySpec, NamedTuple}[]
    for param in sort(collect(keys(ps.ranges)); by = String)
        haskey(m.params, param) || continue
        base_val = getfield(m.params, param)
        lo, hi = ps.ranges[param]
        for (tag, val) in (("lo", lo), ("hi", hi))
            new_params = merge(m.params, NamedTuple{(param,)}((Float64(val),)))
            spec = EmpiricalSensitivitySpec(;
                id = "weak_id_range_$(param)_$(tag)",
                axis = :parameter_weak_id,
                changed_field = "params.$(param)",
                changed_from = string(base_val),
                changed_to = string(val),
                description = "W2範囲報告パラメータ $(param) を objective 等値域の端（$(tag)）へ動かした感応度。",
                metadata = Dict{String, Any}(
                    "parameter" => String(param),
                    "bound" => tag,
                    "range" => [lo, hi],
                ),
            )
            push!(out, (spec, new_params))
        end
    end
    for param in sort(collect(keys(ps.alternate_specs)); by = String)
        haskey(m.params, param) || continue
        base_val = getfield(m.params, param)
        specs = ps.alternate_specs[param]
        for spec_name in sort(collect(keys(specs)))
            val = specs[spec_name]
            new_params = merge(m.params, NamedTuple{(param,)}((Float64(val),)))
            spec = EmpiricalSensitivitySpec(;
                id = "weak_id_altspec_$(param)_$(spec_name)",
                axis = :parameter_weak_id,
                changed_field = "params.$(param)",
                changed_from = string(base_val),
                changed_to = string(val),
                description = "W3複数仕様パラメータ $(param) を仕様 '$(spec_name)' の値へ切り替えた感応度。単一値を採らない（実証戦略 §8.3 W3）。",
                metadata = Dict{String, Any}(
                    "parameter" => String(param),
                    "alternate_spec" => spec_name,
                ),
            )
            push!(out, (spec, new_params))
        end
    end
    return out
end

# ---------------------------------------------------------------------------
# variant 実行（replay → validate、失敗を隠さない）
# ---------------------------------------------------------------------------

_capex_sensitivity_na_stability()::Dict{Symbol, Union{Bool, Nothing}} =
    Dict{Symbol, Union{Bool, Nothing}}(
        dim => nothing for dim in CAPEX_CC_SENSITIVITY_STABILITY_DIMENSIONS
    )

"""baseline と variant の `CapexEmpiricalValidationReport` を比較し、dimension 別の安定性
（`true`/`false`、比較不能なら `nothing`）を返す。変化量・rankではなく安定/不安定のみを返す
（実証戦略 §10.1・Issue #250 の受け入れ条件）。"""
function _capex_sensitivity_stability(
    baseline::CapexEmpiricalValidationReport,
    variant::CapexEmpiricalValidationReport,
)::Dict{Symbol, Union{Bool, Nothing}}
    label_stable =
        (
            baseline.diagnostic_label === :unavailable ||
            variant.diagnostic_label === :unavailable
        ) ? nothing : (baseline.diagnostic_label === variant.diagnostic_label)
    onset_stable = baseline.onset_order == variant.onset_order
    a_base = get(baseline.credit_amplification, "A_credit_off", nothing)
    a_var = get(variant.credit_amplification, "A_credit_off", nothing)
    amp_stable =
        (a_base === nothing || a_var === nothing) ? nothing :
        isapprox(a_base, a_var; atol = 1e-6, rtol = 1e-3)
    prop_stable = baseline.propagation.model_order == variant.propagation.model_order
    return Dict{Symbol, Union{Bool, Nothing}}(
        :diagnostic_label => label_stable,
        :onset_order => onset_stable,
        :credit_amplification => amp_stable,
        :propagation => prop_stable,
    )
end

"""1 variant を実行する共通経路。`model_fn`（zero-arg、`CapexCreditCycleModel` を返す）は
`:parameter_weak_id` axis でモデル再構築時に許容条件違反（`ArgumentError`）を起こしうるため、
`capex_historical_replay` 呼び出しと合わせて捕捉する。データに起因する失敗（`ArgumentError` の
契約違反、または `status === :rejected_input`）は例外にせず `:failed` として保持する
（invalid/failed variant を黙って除外しない、実証戦略 §7.6・Issue #250 受け入れ条件）。"""
function _capex_sensitivity_execute(
    spec::EmpiricalSensitivitySpec,
    model_fn::Function,
    ep_variant::CapexHistoricalEpisodeSpec,
    ds_variant::CapexEmpiricalDataset,
    ps::CapexParameterSet,
    options::CapexReplayOptions,
    baseline_report::CapexEmpiricalValidationReport,
)::EmpiricalSensitivityVariantResult
    try
        m_variant = model_fn()
        run = capex_historical_replay(
            m_variant,
            ep_variant,
            ds_variant,
            ps;
            options = options,
        )
        if run.status === :rejected_input
            reason =
                "rejected_input" *
                (isempty(run.warnings) ? "" : ": " * join(run.warnings, "; "))
            return EmpiricalSensitivityVariantResult(
                spec,
                :failed,
                reason,
                run.status,
                nothing,
                nothing,
                _capex_sensitivity_na_stability(),
            )
        end
        report = validate_capex_empirical(run, ds_variant)
        stability = _capex_sensitivity_stability(baseline_report, report)
        return EmpiricalSensitivityVariantResult(
            spec,
            :evaluated,
            nothing,
            run.status,
            report,
            report.diagnostic_label,
            stability,
        )
    catch e
        e isa ArgumentError || rethrow()
        return EmpiricalSensitivityVariantResult(
            spec,
            :failed,
            sprint(showerror, e),
            nothing,
            nothing,
            nothing,
            _capex_sensitivity_na_stability(),
        )
    end
end

"""axis `:diagnostic_threshold`: 既存 `capex_label_sensitivity`（±50%）を再利用し、diagnostic
label の安定性のみを報告する（他 dimension は再計算しない。実証戦略 §10.4 の既存感応度）。"""
function _capex_sensitivity_threshold_variants(
    m::CapexCreditCycleModel,
    baseline_run::CapexHistoricalReplayRun,
    thresholds::CapexDiagnosticThresholds,
)::Vector{EmpiricalSensitivityVariantResult}
    baseline_run.model_run === nothing && return EmpiricalSensitivityVariantResult[]
    sens = capex_label_sensitivity(m, baseline_run.model_run; thresholds = thresholds)
    results = EmpiricalSensitivityVariantResult[]
    for field in sort(collect(keys(sens)); by = String)
        entry = sens[field]
        base_value = getfield(thresholds, field)
        for (tag, label, factor) in
            (("minus50", entry.minus50, 0.5), ("plus50", entry.plus50, 1.5))
            spec = EmpiricalSensitivitySpec(;
                id = "threshold_$(field)_$(tag)",
                axis = :diagnostic_threshold,
                changed_field = "thresholds.$(field)",
                changed_from = string(base_value),
                changed_to = string(base_value * factor),
                description = "診断閾値 $(field) を$(tag == "minus50" ? "-50%" : "+50%")動かした既存感応度（capex_label_sensitivity、実証戦略 §10.4）。",
                metadata = Dict{String, Any}(
                    "threshold_field" => String(field),
                    "variant" => tag,
                ),
            )
            stability = Dict{Symbol, Union{Bool, Nothing}}(
                :diagnostic_label => (label === entry.baseline),
                :onset_order => nothing,
                :credit_amplification => nothing,
                :propagation => nothing,
            )
            push!(
                results,
                EmpiricalSensitivityVariantResult(
                    spec,
                    :evaluated,
                    nothing,
                    nothing,
                    nothing,
                    label,
                    stability,
                ),
            )
        end
    end
    return results
end

# ---------------------------------------------------------------------------
# axis 別集計（可用性・安定性）
# ---------------------------------------------------------------------------

function _capex_sensitivity_axis_status_for(
    results::Vector{EmpiricalSensitivityVariantResult},
)::NamedTuple
    n = length(results)
    n_evaluated = count(r -> r.status === :evaluated, results)
    n_failed = n - n_evaluated
    status, reason = if n == 0
        (
            :unavailable,
            "この軸で生成可能なvariantがありません（対象データ・対象イベントが無い）。",
        )
    elseif n_evaluated == 0
        (:unavailable, "全variantが失敗しました（各variantのfailure_reasonを参照）。")
    elseif n_failed > 0
        (:partially_available, nothing)
    else
        (:available, nothing)
    end
    return (
        status = status,
        n_variants = n,
        n_evaluated = n_evaluated,
        n_failed = n_failed,
        unavailable_reason = reason,
    )
end

function _capex_sensitivity_stability_summary(
    results::Vector{EmpiricalSensitivityVariantResult},
)::Dict{Symbol, NamedTuple}
    out = Dict{Symbol, NamedTuple}()
    for dim in CAPEX_CC_SENSITIVITY_STABILITY_DIMENSIONS
        applicable =
            [r for r in results if r.status === :evaluated && r.stability[dim] !== nothing]
        n_applicable = length(applicable)
        n_stable = count(r -> r.stability[dim] === true, applicable)
        out[dim] = (
            n_applicable = n_applicable,
            n_stable = n_stable,
            n_unstable = n_applicable - n_stable,
        )
    end
    return out
end

# ---------------------------------------------------------------------------
# capex_empirical_sensitivity_suite（公開 API）
# ---------------------------------------------------------------------------

"""
    capex_empirical_sensitivity_suite(m, ep, ds, ps;
        options = CapexReplayOptions(...),
        window_shifts = [-4, -1, 1, 4],
        timing_shift = 1,
        magnitude_ratio = 0.5,
        thresholds = CapexDiagnosticThresholds(),
    ) -> EmpiricalRobustnessReport

`capex_historical_replay(m, ep, ds, ps; options)` を baseline として1回実行し、
`CAPEX_CC_SENSITIVITY_AXES` の7 axis を1軸ずつ動かした variant を生成・実行・
`validate_capex_empirical` で検証する。各 variant は baseline から厳密に1点だけを変更する
（one-axis-at-a-time、combinatorial search をしない）。

`options` の既定値は `ep.runup_quarters`/`ep.eval_quarters`・`ps.kind` に整合させる。呼び出し側が
`options` を明示する場合、`capex_historical_replay` 自身の契約検査（`ArgumentError`）がそのまま
適用される。

baseline replay が `status === :rejected_input`（`model_run === nothing`）の場合、感応度を評価
できないため、全 axis を `:unavailable` とした空の report を返す（fail closed。#249 の
`_capex_validation_empty_report` と同じ規律）。

失敗した variant は除外せず `EmpiricalSensitivityVariantResult.status === :failed` として
`failure_reason` とともに残す。診断ラベル・転換点/onset・credit amplification・部門波及順序の
**安定性**（`true`/`false`。変化量・rankではない）を axis×dimension 別に集計するが、複数
dimension を跨いだ単一スコアへは集約しない（実証戦略 §10.1）。best-fit の自動選択・確率的予測
への変換は行わない。
"""
function capex_empirical_sensitivity_suite(
    m::CapexCreditCycleModel,
    ep::CapexHistoricalEpisodeSpec,
    ds::CapexEmpiricalDataset,
    ps::CapexParameterSet;
    options::CapexReplayOptions = CapexReplayOptions(;
        parameter_set_kind = ps.kind,
        model_options = CapexCreditCycleOptions(;
            horizon_runup = ep.runup_quarters,
            horizon_eval = ep.eval_quarters,
        ),
    ),
    window_shifts::Vector{Int} = [-4, -1, 1, 4],
    timing_shift::Int = 1,
    magnitude_ratio::Float64 = 0.5,
    thresholds::CapexDiagnosticThresholds = CapexDiagnosticThresholds(),
)::EmpiricalRobustnessReport
    baseline_run = capex_historical_replay(m, ep, ds, ps; options = options)
    baseline_report = validate_capex_empirical(baseline_run, ds)

    empty_variants = Dict{Symbol, Vector{EmpiricalSensitivityVariantResult}}(
        axis => EmpiricalSensitivityVariantResult[] for axis in CAPEX_CC_SENSITIVITY_AXES
    )

    if baseline_run.model_run === nothing
        reason = "baseline replay が status=:rejected_input のため感応度を評価できません。"
        axis_status = Dict{Symbol, NamedTuple}(
            axis => (
                status = :unavailable,
                n_variants = 0,
                n_evaluated = 0,
                n_failed = 0,
                unavailable_reason = reason,
            ) for axis in CAPEX_CC_SENSITIVITY_AXES
        )
        empty_dims = Dict{Symbol, NamedTuple}(
            dim => (n_applicable = 0, n_stable = 0, n_unstable = 0) for
            dim in CAPEX_CC_SENSITIVITY_STABILITY_DIMENSIONS
        )
        stability_summary = Dict{Symbol, Dict{Symbol, NamedTuple}}(
            axis => empty_dims for axis in CAPEX_CC_SENSITIVITY_AXES
        )
        metadata = Dict{String, Any}(
            "sensitivity_version" => CAPEX_CC_EMPIRICAL_SENSITIVITY_VERSION,
            "baseline_replay_hash" => baseline_run.replay_hash,
            "dataset_hash" => baseline_run.dataset_hash,
            "parameter_set_hash" => baseline_run.parameter_set_hash,
            "rejected" => true,
        )
        return EmpiricalRobustnessReport(
            ep.id,
            ps.kind,
            baseline_report,
            empty_variants,
            axis_status,
            stability_summary,
            String[],
            vcat(baseline_run.warnings, [reason]),
            copy(CAPEX_CC_EMPIRICAL_SENSITIVITY_CAVEATS),
            metadata,
        )
    end

    variants = empty_variants

    for (spec, ep_v) in _capex_sensitivity_window_variants(ep, window_shifts)
        push!(
            variants[:sample_window],
            _capex_sensitivity_execute(
                spec,
                () -> m,
                ep_v,
                ds,
                ps,
                options,
                baseline_report,
            ),
        )
    end
    for (spec, ep_v) in _capex_sensitivity_timing_variants(ep, timing_shift)
        push!(
            variants[:event_timing],
            _capex_sensitivity_execute(
                spec,
                () -> m,
                ep_v,
                ds,
                ps,
                options,
                baseline_report,
            ),
        )
    end
    for (spec, ep_v) in _capex_sensitivity_magnitude_variants(ep, magnitude_ratio)
        push!(
            variants[:event_magnitude],
            _capex_sensitivity_execute(
                spec,
                () -> m,
                ep_v,
                ds,
                ps,
                options,
                baseline_report,
            ),
        )
    end
    for (spec, ds_v) in _capex_sensitivity_proxy_variants(ds)
        push!(
            variants[:proxy],
            _capex_sensitivity_execute(
                spec,
                () -> m,
                ep,
                ds_v,
                ps,
                options,
                baseline_report,
            ),
        )
    end
    for (spec, ds_v) in _capex_sensitivity_exclusion_variants(ds, baseline_report)
        push!(
            variants[:series_exclusion],
            _capex_sensitivity_execute(
                spec,
                () -> m,
                ep,
                ds_v,
                ps,
                options,
                baseline_report,
            ),
        )
    end
    for (spec, new_params) in _capex_sensitivity_parameter_variants(m, ps)
        model_fn =
            () -> CapexCreditCycleModel(;
                params = new_params,
                targets = m.targets,
                sectors = m.sectors,
                contract_versions = m.contract_versions,
            )
        push!(
            variants[:parameter_weak_id],
            _capex_sensitivity_execute(
                spec,
                model_fn,
                ep,
                ds,
                ps,
                options,
                baseline_report,
            ),
        )
    end
    variants[:diagnostic_threshold] =
        _capex_sensitivity_threshold_variants(m, baseline_run, thresholds)

    axis_status = Dict{Symbol, NamedTuple}(
        axis => _capex_sensitivity_axis_status_for(variants[axis]) for
        axis in CAPEX_CC_SENSITIVITY_AXES
    )
    stability_summary = Dict{Symbol, Dict{Symbol, NamedTuple}}(
        axis => _capex_sensitivity_stability_summary(variants[axis]) for
        axis in CAPEX_CC_SENSITIVITY_AXES
    )
    label_boundary_variants = String[
        v.spec.id for axis in CAPEX_CC_SENSITIVITY_AXES for v in variants[axis] if
        v.status === :evaluated && v.stability[:diagnostic_label] === false
    ]

    metadata = Dict{String, Any}(
        "sensitivity_version" => CAPEX_CC_EMPIRICAL_SENSITIVITY_VERSION,
        "baseline_replay_hash" => baseline_run.replay_hash,
        "dataset_hash" => baseline_run.dataset_hash,
        "parameter_set_hash" => baseline_run.parameter_set_hash,
        "window_shifts" => sort(unique(window_shifts)),
        "timing_shift" => timing_shift,
        "magnitude_ratio" => magnitude_ratio,
        "threshold_id" => thresholds.id,
        "axes" => collect(String.(CAPEX_CC_SENSITIVITY_AXES)),
        "one_axis_at_a_time" => true,
    )

    return EmpiricalRobustnessReport(
        ep.id,
        ps.kind,
        baseline_report,
        variants,
        axis_status,
        stability_summary,
        label_boundary_variants,
        copy(baseline_run.warnings),
        copy(CAPEX_CC_EMPIRICAL_SENSITIVITY_CAVEATS),
        metadata,
    )
end

# ---------------------------------------------------------------------------
# 機械可読な report 出力（#249 の JSON 変換ヘルパを再利用）
# ---------------------------------------------------------------------------

function _capex_sensitivity_spec_to_dict(spec::EmpiricalSensitivitySpec)::Dict{String, Any}
    return Dict{String, Any}(
        "id" => spec.id,
        "axis" => String(spec.axis),
        "changed_field" => spec.changed_field,
        "changed_from" => spec.changed_from,
        "changed_to" => spec.changed_to,
        "description" => spec.description,
        "metadata" => _capex_validation_json_value(spec.metadata),
    )
end

function _capex_sensitivity_variant_to_dict(
    v::EmpiricalSensitivityVariantResult,
)::Dict{String, Any}
    return Dict{String, Any}(
        "spec" => _capex_sensitivity_spec_to_dict(v.spec),
        "status" => String(v.status),
        "failure_reason" => v.failure_reason,
        "replay_status" => v.replay_status === nothing ? nothing : String(v.replay_status),
        "diagnostic_label" =>
            v.diagnostic_label === nothing ? nothing : String(v.diagnostic_label),
        "stability" => Dict{String, Any}(String(k) => val for (k, val) in v.stability),
        "report" =>
            v.report === nothing ? nothing :
            capex_empirical_validation_report_to_dict(v.report),
    )
end

"""
    capex_empirical_sensitivity_report_to_dict(report) -> Dict{String,Any}

`EmpiricalRobustnessReport` を JSON に保存できる辞書へ変換する。非有限数は `null`、`nothing`
はそのまま `null` として保存する（`0` 化しない、#249 と同じ規約）。
"""
function capex_empirical_sensitivity_report_to_dict(
    report::EmpiricalRobustnessReport,
)::Dict{String, Any}
    return Dict{String, Any}(
        "sensitivity_version" => CAPEX_CC_EMPIRICAL_SENSITIVITY_VERSION,
        "episode" => String(report.episode),
        "parameter_set_kind" => String(report.parameter_set_kind),
        "baseline_report" =>
            capex_empirical_validation_report_to_dict(report.baseline_report),
        "variants" => Dict{String, Any}(
            String(axis) => [_capex_sensitivity_variant_to_dict(v) for v in vs] for
            (axis, vs) in report.variants
        ),
        "axis_status" => Dict{String, Any}(
            String(axis) => _capex_validation_namedtuple_to_dict(status) for
            (axis, status) in report.axis_status
        ),
        "stability_summary" => Dict{String, Any}(
            String(axis) => Dict{String, Any}(
                String(dim) => _capex_validation_namedtuple_to_dict(nt) for
                (dim, nt) in dims
            ) for (axis, dims) in report.stability_summary
        ),
        "label_boundary_variants" => report.label_boundary_variants,
        "warnings" => report.warnings,
        "caveats" => report.caveats,
        "metadata" => _capex_validation_json_value(report.metadata),
    )
end

"""
    save_capex_empirical_sensitivity_report(path, report) -> path

`capex_empirical_sensitivity_report_to_dict(report)` を整形 JSON として保存する。
"""
function save_capex_empirical_sensitivity_report(
    path::AbstractString,
    report::EmpiricalRobustnessReport,
)
    open(path, "w") do io
        JSON3.pretty(io, capex_empirical_sensitivity_report_to_dict(report))
    end
    return path
end
