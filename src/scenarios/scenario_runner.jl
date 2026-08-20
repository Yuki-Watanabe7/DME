# scenario_runner.jl: `Scenario` → `SimulationResult` の実行層（Issue #202 / `E-6`）。
#
# `run_scenario` を提供する。統合設計 §5.7 の6ステップ固定実行
# （1 Scenario全体検証 → 2 map_event → 3 schedule_events → 4 capex_run → 5 会計・診断 →
# 6 to_simulation_result + metadata付与）を `CapexCreditCycleModel` に対して実装する
# （Phase 2 の初期対応モデルは CCC のみ、統合設計 §1「初期対応モデル」）。
#
# `run_scenario` は例外を投げない（引数そのものが不正な場合を除く。統合設計 §5.7 契約1）。
# 拒否は `status`（`SCENARIO_EXECUTION_STATUSES`）と `rejections` で返し、
# `status = :rejected_*` のとき `result === nothing`・`exog === nothing` であり
# モデルを実行していない（fail closed、統合設計 §6.3）。
#
# 本ファイルが Issue #202 時点で暫定的に持っていた再現契約 hash（`event_set_hash`・
# `scenario_content_hash`・`params_hash`・`initial_state_id`・`solver_settings_hash`）と
# 型写像 encoder（`_scenario_hash_encode`）は、Issue #203 / `E-7` で
# `src/scenarios/scenario_provenance.jl` へ移設した（統合設計 §11 `E-7` 行・§4.1）。
# `event_log`（統合設計 §9.1 の14項目、`scenario_event_log`）・完全な encode/decode
# （`scenario_to_dict`/`_from_dict`）・`save_scenario_artifact`/`load_scenario`/
# `replay_scenario` も Issue #203 が `scenario_provenance.jl`/`scenario_serialization.jl`
# へ実装した。
#
# 設計契約:
#   docs/architecture/macro_event_runtime_integration.md §5.7（`ScenarioRunOptions`・
#     `ScenarioRun`・`run_scenario` の型・実行順）・§6（失敗契約の3層分離）・
#     §7.6（定期更新とイベントのハイブリッド実行）・§8.2（既存 `capex_run` の移行表、`Y-20`・
#     `Y-21`）・§9.2（再現契約・hash対象フィールド）・§9.3（`SimulationResult` metadata
#     予約キー20個。`event_log` を含む）・§11 `E-6`・`E-7` 行

# ------------------------------------------------------------
# period label（統合設計 §7.1・§9.3、`Y-07`）
# ------------------------------------------------------------

"`period_zero` を起点に `t` 期先の暦四半期を返す（`quarter_index` の逆演算）。"
function _scenario_calendar_quarter_add(q::CalendarQuarter, t::Int)
    total = (q.quarter - 1) + t
    y = q.year + fld(total, 4)
    qq = mod(total, 4) + 1
    return CalendarQuarter(y, qq)
end

"""
    _scenario_period_labels(periods, period_zero) -> Vector{String}

`period_zero` があれば `["2024Q1", …]`、無ければ `["t-8", …, "t+19"]` 形式（統合設計 §7.1、
`Y-07`）。
"""
function _scenario_period_labels(
    periods::Vector{Int},
    period_zero::Union{CalendarQuarter, Nothing},
)
    period_zero === nothing && return [t >= 0 ? "t+$(t)" : "t$(t)" for t in periods]
    return [quarter_label(_scenario_calendar_quarter_add(period_zero, t)) for t in periods]
end

# ------------------------------------------------------------
# EventRejection / ScenarioWarning → Dict（metadata 用、統合設計 §9.3）
# ------------------------------------------------------------

function _scenario_rejection_to_dict(r::EventRejection)
    return Dict{String, Any}(
        "code" => String(r.code),
        "layer" => String(r.layer),
        "subject_ids" => copy(r.subject_ids),
        "event_type" => r.event_type === nothing ? nothing : String(r.event_type),
        "target_concept" =>
            r.target_concept === nothing ? nothing : String(r.target_concept),
        "detail" => r.detail,
        "upstream_issue" => r.upstream_issue,
    )
end

function _scenario_warning_to_dict(w::ScenarioWarning)
    return Dict{String, Any}(
        "code" => String(w.code),
        "period" => w.period,
        "subject_ids" => copy(w.subject_ids),
        "target_variable" =>
            w.target_variable === nothing ? nothing : String(w.target_variable),
        "detail" => w.detail,
    )
end

# ------------------------------------------------------------
# Scenario 全体検証（統合設計 §5.7 実行順ステップ1・§6.1 層(2)）
# ------------------------------------------------------------

"""
    _scenario_validate_structure(sc, m, options) -> Vector{EventRejection}

`Scenario` 集合レベルの構造化検証（統合設計 §5.7 ステップ1）。1件で例外を投げず、
検出したすべての矛盾を集めて返す（層(2)の規律、統合設計 §6.1）。
"""
function _scenario_validate_structure(
    sc::Scenario,
    m::CapexCreditCycleModel,
    options::ScenarioRunOptions,
)
    rejections = EventRejection[]

    if sc.model != model_symbol(m)
        push!(
            rejections,
            EventRejection(;
                code = :model_mismatch,
                layer = :assumption,
                subject_ids = [String(sc.id)],
                detail = "Scenario.model=$(sc.model) が実行対象モデル $(model_symbol(m)) と" *
                         "一致しません（統合設計 §5.7 実行順ステップ1）",
            ),
        )
    end

    if options.model_options !== nothing
        mo = options.model_options
        if mo.horizon_runup != sc.horizon_runup || mo.horizon_eval != sc.horizon_eval
            push!(
                rejections,
                EventRejection(;
                    code = :horizon_mismatch,
                    layer = :assumption,
                    subject_ids = [String(sc.id)],
                    detail = "Scenario.horizon_runup/horizon_eval=" *
                             "($(sc.horizon_runup),$(sc.horizon_eval)) が " *
                             "options.model_options=($(mo.horizon_runup),$(mo.horizon_eval)) と" *
                             "一致しません（`Y-09`・統合設計 §7.3）",
                ),
            )
        end
    end

    id_counts = Dict{String, Int}()
    for a in sc.assumptions
        id_counts[a.assumption_id] = get(id_counts, a.assumption_id, 0) + 1
    end
    dup_ids = sort([id for (id, c) in id_counts if c > 1])
    if !isempty(dup_ids)
        push!(
            rejections,
            EventRejection(;
                code = :duplicate_event_id,
                layer = :assumption,
                subject_ids = dup_ids,
                detail = "Scenario.assumptions に重複した assumption_id があります: " *
                         "$(dup_ids)（マクロイベント変換契約 §5.5）",
            ),
        )
    end

    if !isempty(sc.assumptions)
        bases = unique(a.timing.basis for a in sc.assumptions)
        if length(bases) > 1
            push!(
                rejections,
                EventRejection(;
                    code = :mixed_timing_basis,
                    layer = :assumption,
                    subject_ids = [a.assumption_id for a in sc.assumptions],
                    detail = "Scenario.assumptions の timing.basis が混在しています" *
                             "（$(bases)）。1つのScenario内で暦日基準とモデル期基準を混在" *
                             "させられません（`Y-02`）",
                ),
            )
        end
    end

    if sc.period_zero === nothing &&
       any(a.timing.basis === :calendar for a in sc.assumptions)
        push!(
            rejections,
            EventRejection(;
                code = :period_zero_required,
                layer = :assumption,
                subject_ids = [
                    a.assumption_id for a in sc.assumptions if a.timing.basis === :calendar
                ],
                detail = "timing.basis=:calendar の仮定を含みますが Scenario.period_zero が" *
                         "指定されていません（シナリオ時間軸の意味論 §2.1）",
            ),
        )
    end

    return rejections
end

# ------------------------------------------------------------
# map_event 適用（統合設計 §5.7 実行順ステップ2、`Y-06`）
# ------------------------------------------------------------

"""
    _scenario_map_assumptions(m, sc, periods, baseline, options) ->
        (inputs, rejections, warnings)

`sc.assumptions` を `map_event` で `L4` へ変換する。`unmapped_target` は
`options.on_unmapped` に従う（`:reject` は拒否として集める。`:warn` は
`unmapped_target_accepted` 警告へ変換し実行を継続する、`Y-06`）。それ以外の拒否
（`:unsupported_model` 等）は常に拒否として集める。
"""
function _scenario_map_assumptions(
    m::CapexCreditCycleModel,
    sc::Scenario,
    periods::Vector{Int},
    baseline::Dict{Symbol, Vector{Float64}},
    options::ScenarioRunOptions,
)
    inputs = AppliedModelInput[]
    rejections = EventRejection[]
    warnings = ScenarioWarning[]
    for a in sc.assumptions
        mapped = map_event(
            m,
            a;
            periods = periods,
            baseline = baseline,
            timing_rules = sc.timing_rules,
            period_zero = sc.period_zero,
        )
        if mapped isa EventRejection
            if mapped.code === :unmapped_target && options.on_unmapped === :warn
                push!(
                    warnings,
                    ScenarioWarning(;
                        code = :unmapped_target_accepted,
                        subject_ids = mapped.subject_ids,
                        detail = mapped.detail,
                    ),
                )
            else
                push!(rejections, mapped)
            end
        else
            push!(inputs, mapped)
        end
    end
    return inputs, rejections, warnings
end

# ------------------------------------------------------------
# 警告: low_confidence / timing_sensitive / extreme_shock（統合設計 §5.7・§7.3・`Y-16`・`Y-29`）
# ------------------------------------------------------------

"""
    _scenario_confidence_warnings(sc, options) -> Vector{ScenarioWarning}

`options.confidence_threshold` を明示指定したときのみ `low_confidence` 警告を出す
（既定 `nothing` では常に空、`Y-16`）。`confidence` はいかなる場合も magnitude・適用可否に
作用しない。
"""
function _scenario_confidence_warnings(sc::Scenario, options::ScenarioRunOptions)
    options.confidence_threshold === nothing && return ScenarioWarning[]
    threshold = options.confidence_threshold
    warnings = ScenarioWarning[]
    for a in sc.assumptions
        a.confidence === nothing && continue
        a.confidence < threshold || continue
        push!(
            warnings,
            ScenarioWarning(;
                code = :low_confidence,
                subject_ids = [a.assumption_id],
                detail = "confidence=$(a.confidence) が options.confidence_threshold=" *
                         "$(threshold) 未満です（統合設計 §5.7・`Y-16`。confidence は" *
                         "magnitude・適用可否には作用しません）",
            ),
        )
    end
    return warnings
end

"""
    _scenario_timing_sensitive_warnings(sc, options) -> Vector{ScenarioWarning}

`:calendar` 基準の仮定について、`effective_from` が cutoff 境界から
`options.timing_sensitive_days` 日以内のとき `timing_sensitive` 警告を出す
（統合設計 §7.3・`Y-29`。`scenario_timing_sensitivity` による併記対象）。
"""
function _scenario_timing_sensitive_warnings(sc::Scenario, options::ScenarioRunOptions)
    warnings = ScenarioWarning[]
    for a in sc.assumptions
        a.timing.basis === :calendar || continue
        q = quarter_of(a.timing.effective_from)
        cutoff = _scenario_time_cutoff_date(q, sc.timing_rules)
        days = abs(Dates.value(a.timing.effective_from - cutoff))
        days <= options.timing_sensitive_days || continue
        push!(
            warnings,
            ScenarioWarning(;
                code = :timing_sensitive,
                subject_ids = [a.assumption_id],
                detail = "effective_from=$(a.timing.effective_from) は cutoff=$(cutoff) から" *
                         "$(days)日以内です（options.timing_sensitive_days=" *
                         "$(options.timing_sensitive_days)。統合設計 §7.3・`Y-29`）",
            ),
        )
    end
    return warnings
end

"""
    _scenario_extreme_shock_warnings(inputs, periods, options) -> Vector{ScenarioWarning}

各 `AppliedModelInput` の `t_apply` 期における baseline 比（`:multiplicative` は
`magnitude/100`、それ以外は `|values-baseline_values|/|baseline_values|`）が
`options.extreme_shock_ratio` を超える場合に `extreme_shock` 警告を出す（統合設計 §5.7）。
"""
function _scenario_extreme_shock_warnings(
    inputs::Vector{AppliedModelInput},
    periods::Vector{Int},
    options::ScenarioRunOptions,
)
    warnings = ScenarioWarning[]
    for inp in inputs
        idx = findfirst(==(inp.t_apply), periods)
        idx === nothing && continue
        rel = if inp.application_mode === :multiplicative
            abs(inp.values[idx]) / 100
        else
            b = inp.baseline_values[idx]
            b == 0.0 ? (inp.values[idx] == 0.0 ? 0.0 : Inf) : abs(inp.values[idx]) / abs(b)
        end
        rel > options.extreme_shock_ratio || continue
        push!(
            warnings,
            ScenarioWarning(;
                code = :extreme_shock,
                period = inp.t_apply,
                subject_ids = [inp.input_id],
                target_variable = inp.target_variable,
                detail = "t_apply=$(inp.t_apply) の $(inp.target_variable) の相対規模" *
                         "（$(rel)）が options.extreme_shock_ratio=" *
                         "$(options.extreme_shock_ratio) を超えています（baseline比、" *
                         "統合設計 §5.7）",
            ),
        )
    end
    return warnings
end

# ------------------------------------------------------------
# ScenarioRun（統合設計 §5.7）
# ------------------------------------------------------------

"""
    ScenarioRun

`run_scenario` の戻り値（統合設計 §5.7）。

## フィールド
- `status::Symbol`: `SCENARIO_EXECUTION_STATUSES` のいずれか。
- `scenario::Scenario`
- `model_name::String` / `model_symbol::Symbol`
- `applied_inputs::Vector{AppliedModelInput}`: mapping に成功した `L4`（`status` によらず、
  そこまでに得られたものを保持する）。
- `schedule::Union{EventSchedule,Nothing}`: `schedule_events` の戻り値。`status =
  :rejected_validation` または mapping 段階で拒否された場合は `nothing`。
- `exog::Union{Dict{Symbol,Vector{Float64}},Nothing}`: `status = :rejected_*` のとき
  `nothing`（fail closed、統合設計 §6.3）。
- `model_run::Any`: `CapexCreditCycleRun` または `nothing`。
- `accounting::Any` / `diagnostics::Any`: `options.validate_accounting`/`options.diagnostics`
  に従う。
- `result::Union{SimulationResult,Nothing}`: `status = :rejected_*` のとき `nothing`。
- `rejections::Vector{EventRejection}`
- `warnings::Vector{ScenarioWarning}`
- `provenance::ScenarioProvenance`
- `options::ScenarioRunOptions`
"""
struct ScenarioRun
    status::Symbol
    scenario::Scenario
    model_name::String
    model_symbol::Symbol
    applied_inputs::Vector{AppliedModelInput}
    schedule::Union{EventSchedule, Nothing}
    exog::Union{Dict{Symbol, Vector{Float64}}, Nothing}
    model_run::Any
    accounting::Any
    diagnostics::Any
    result::Union{SimulationResult, Nothing}
    rejections::Vector{EventRejection}
    warnings::Vector{ScenarioWarning}
    provenance::ScenarioProvenance
    options::ScenarioRunOptions
end

# ------------------------------------------------------------
# metadata 付与（統合設計 §9.3、イベント層20キー）
# ------------------------------------------------------------

"""
    _scenario_merge_event_metadata!(result, sc, status, options, schedule,
                                     rejections, warnings, provenance)

`to_simulation_result` が生成した `result.metadata`（可変 `Dict`）へ、統合設計 §9.3の
イベント層 metadata 予約キー20個を**追加**する（既存の `CCC` 予約20キー + 補助3キーは
上書きしない）。`event_log` は `scenario_event_log`（`scenario_provenance.jl`、Issue #203）を
呼ぶ。
"""
function _scenario_merge_event_metadata!(
    result::SimulationResult,
    sc::Scenario,
    status::Symbol,
    options::ScenarioRunOptions,
    schedule::EventSchedule,
    rejections::Vector{EventRejection},
    warnings::Vector{ScenarioWarning},
    provenance::ScenarioProvenance,
)
    md = result.metadata
    md["event_contract_version"] = MACRO_EVENT_CONTRACT_VERSION
    md["time_semantics_version"] = SCENARIO_TIME_SEMANTICS_VERSION
    md["event_runtime_version"] = MACRO_EVENT_RUNTIME_VERSION
    md["event_rule_version"] = EVENT_RULE_VERSION
    md["event_mapping_version"] = CAPEX_CC_EVENT_MAPPING_VERSION
    md["scenario_id"] = String(sc.id)
    md["scenario_version"] = sc.version
    md["scenario_content_hash"] = scenario_content_hash(sc)
    md["event_set_hash"] = provenance.event_set_hash
    md["period_zero"] = sc.period_zero === nothing ? nothing : quarter_label(sc.period_zero)
    md["period_labels"] = _scenario_period_labels(schedule.periods, sc.period_zero)
    md["shock_origin_index"] = findfirst(==(0), schedule.periods)
    md["timing_rule_set"] = _scenario_timing_rule_set_dict(sc.timing_rules)
    md["event_warnings"] = [_scenario_warning_to_dict(w) for w in warnings]
    md["event_rejections"] = [_scenario_rejection_to_dict(r) for r in rejections]
    md["event_execution_status"] = String(status)
    md["unmapped_policy"] = String(options.on_unmapped)
    md["params_hash"] = provenance.params_hash
    md["initial_state_id"] = provenance.initial_state_id
    md["event_log"] = scenario_event_log(schedule)
    return nothing
end

# ------------------------------------------------------------
# run_scenario（統合設計 §5.7、CCC dispatch）
# ------------------------------------------------------------

"""
    run_scenario(m::CapexCreditCycleModel, sc::Scenario;
                 options::ScenarioRunOptions = ScenarioRunOptions()) -> ScenarioRun

検証済み `Scenario` を受け取り、イベント適用（`map_event`）→ スケジューリング
（`schedule_events`）→ モデル実行（`capex_run`）→ 会計・診断（`validate_capex_accounting`・
`capex_diagnostics`）→ `SimulationResult` 変換（`to_simulation_result` + イベント層
metadata）を決定的な順序で行う（統合設計 §5.7）。

**実行順（固定）**: 1) `Scenario` 全体検証 → 2) `map_event`（`L3→L4`） →
3) `schedule_events`（全順序・合成・外生パス） → 4) `capex_run`（`exog` を明示的に渡す。
`Y-20`） → 5) `validate_capex_accounting`・`capex_diagnostics`（`Y-21`） →
6) `to_simulation_result` + metadata付与。

**例外を投げない**（`options.on_unmapped` が `:reject`/`:warn` のいずれでもない場合を除く。
引数そのものが不正な場合の例外は許容する、統合設計 §5.7 契約1）。拒否は `status` と
`rejections` で返す。`status ∈ (:rejected_validation, :rejected_mapping)` のとき
`result === nothing`・`exog === nothing`（fail closed、統合設計 §6.3）。

`sc.assumptions` が空（baseline）でも正当に実行できる。同一 `m`・同一
`options.model_options`（`state0` は常に既定の定常状態）で `assumptions` が空の `Scenario`
を実行したものが baseline run である（統合設計 §5.7 契約4）。
"""
function run_scenario(
    m::CapexCreditCycleModel,
    sc::Scenario;
    options::ScenarioRunOptions = ScenarioRunOptions(),
)
    options.on_unmapped in (:reject, :warn) || throw(
        ArgumentError(
            "ScenarioRunOptions.on_unmapped=$(options.on_unmapped) は :reject/:warn の" *
            "いずれかでなければなりません（統合設計 §6.4、`Y-06`）",
        ),
    )

    mname = model_name(m)
    msym = model_symbol(m)

    model_options =
        options.model_options === nothing ?
        CapexCreditCycleOptions(;
            horizon_runup = sc.horizon_runup,
            horizon_eval = sc.horizon_eval,
        ) : options.model_options

    cv = m.contract_versions
    provenance = ScenarioProvenance(
        cv.model_version,
        Dict{String, String}(
            "event_contract_version" => MACRO_EVENT_CONTRACT_VERSION,
            "time_semantics_version" => SCENARIO_TIME_SEMANTICS_VERSION,
            "event_runtime_version" => MACRO_EVENT_RUNTIME_VERSION,
            "model_contract_version" => cv.contract_version,
        ),
        String(sc.id),
        sc.version,
        event_set_hash(sc),
        EVENT_RULE_VERSION,
        CAPEX_CC_EVENT_MAPPING_VERSION,
        _scenario_params_hash(m),
        _scenario_initial_state_id(nothing),
        _scenario_solver_settings_hash(model_options),
        _scenario_timing_rule_set_dict(sc.timing_rules),
    )

    # ステップ1: Scenario 全体検証
    structural_rejections = _scenario_validate_structure(sc, m, options)
    if !isempty(structural_rejections)
        return ScenarioRun(
            :rejected_validation,
            sc,
            mname,
            msym,
            AppliedModelInput[],
            nothing,
            nothing,
            nothing,
            nothing,
            nothing,
            nothing,
            structural_rejections,
            ScenarioWarning[],
            provenance,
            options,
        )
    end

    n = model_options.horizon_runup + model_options.horizon_eval
    periods = collect((-model_options.horizon_runup):(model_options.horizon_eval - 1))
    baseline = _ccc_baseline_exog(m, n)

    # ステップ2: map_event（L3 → L4）
    inputs, mapping_rejections, mapping_warnings =
        _scenario_map_assumptions(m, sc, periods, baseline, options)

    pre_warnings = vcat(
        mapping_warnings,
        _scenario_confidence_warnings(sc, options),
        _scenario_timing_sensitive_warnings(sc, options),
    )

    if !isempty(mapping_rejections)
        return ScenarioRun(
            :rejected_mapping,
            sc,
            mname,
            msym,
            inputs,
            nothing,
            nothing,
            nothing,
            nothing,
            nothing,
            nothing,
            mapping_rejections,
            pre_warnings,
            provenance,
            options,
        )
    end

    # ステップ3: schedule_events（全順序・固定順合成・外生パス）
    schedule = schedule_events(inputs, sc, baseline)

    if !isempty(schedule.rejections)
        return ScenarioRun(
            :rejected_mapping,
            sc,
            mname,
            msym,
            inputs,
            schedule,
            nothing,
            nothing,
            nothing,
            nothing,
            nothing,
            schedule.rejections,
            vcat(pre_warnings, schedule.warnings),
            provenance,
            options,
        )
    end

    # ステップ4: capex_run（exog を明示的に渡す。`scenario` 引数はラベルのみ、`Y-20`）
    model_run = capex_run(
        m;
        scenario = sc.id,
        exog = schedule.paths,
        options = model_options,
        validate_accounting = false,
        diagnostics = false,
    )

    # ステップ5: 会計・診断を明示的に呼ぶ（`Y-21`）
    accounting =
        options.validate_accounting ? validate_capex_accounting(m, model_run) : nothing
    thresholds =
        options.thresholds === nothing ? CapexDiagnosticThresholds() : options.thresholds
    # `capex_diagnostics` の delayed_containment 判定（Phase 1 / #183）は `contained_adjustment`
    # ラベルのときに限り `capex_scenario(run.scenario)`（Sc0–Sc4 の凡例のみを持つ）を内部で
    # 呼ぶ。event-driven な `Scenario.id`（例 `sc.id`）は一般に Sc0–Sc4 の集合に属さないため、
    # この経路が `ArgumentError` を投げうる（Phase 1 由来の既存の制約であり、本 Issue の対象
    # ファイルではない `analysis/capex_credit_cycle_diagnostics.jl` 側の限界）。`run_scenario`
    # は例外を投げない契約（統合設計 §5.7 契約1）を守るため、この特定の失敗のみを捕捉し
    # `diagnostics = nothing` に落とす（診断以外のステップ・結果には影響しない）。
    diagnostics = if options.diagnostics
        try
            capex_diagnostics(m, model_run; thresholds = thresholds, accounting = accounting)
        catch e
            e isa ArgumentError || rethrow()
            nothing
        end
    else
        nothing
    end

    status = model_run.termination_reason === :completed ? :completed : :terminated

    # ステップ6: to_simulation_result + イベント層 metadata の付与
    result = to_simulation_result(m, model_run, String(sc.id))

    extreme_warnings = _scenario_extreme_shock_warnings(inputs, periods, options)
    all_warnings = vcat(pre_warnings, schedule.warnings, extreme_warnings)

    _scenario_merge_event_metadata!(
        result,
        sc,
        status,
        options,
        schedule,
        EventRejection[],
        all_warnings,
        provenance,
    )

    return ScenarioRun(
        status,
        sc,
        mname,
        msym,
        inputs,
        schedule,
        schedule.paths,
        model_run,
        accounting,
        diagnostics,
        result,
        EventRejection[],
        all_warnings,
        provenance,
        options,
    )
end
