# cross_model_runner.jl: 上流モデル由来入力を含むシナリオの実行（`X6`）と保存・replay（`X7`）
# （Issue #282 / `PN-2`）。
#
# `run_cross_model_scenario(m, sc, xs)` は、event 由来の `Scenario.assumptions` と上流モデル由来の
# `ModelDerivedInput` を**それぞれ別の mapping 関数**（`map_event` / `map_model_derived_input`）で
# `AppliedModelInput`（`L4`）へ変換したうえで、既存の `schedule_events`（全順序・固定順合成）を
# 1 回だけ呼び、`capex_run` へ渡す。`run_scenario`・`Scenario`・`AppliedModelInput`・
# `scenario.json`・`MACRO_EVENT_*` 語彙は変更しない（ADR 0024 決定 14–17）。
#
# 失敗契約（設計 §10.5・§11）:
#   - status は既存の 4 値（`SCENARIO_EXECUTION_STATUSES`）を再利用する。
#   - event 由来の拒否・警告（`EventRejection`/`ScenarioWarning`）と cross-model の拒否・警告
#     （`CrossModelRejection`/`CrossModelWarning`）を同じ配列へ混ぜない。
#   - cross-model の拒否が 1 件でもあればモデルを実行しない。`on_unmapped = :warn` は
#     cross-model の拒否を緩めない。
#
# 設計契約:
#   docs/architecture/pne_sector_output_integration.md §10.3–§10.5・§12・§13
#   docs/adr/0024-pne-sector-output-cross-model-input-contract.md 決定 14–17

# ===========================================================================
# 語彙・型
# ===========================================================================

"cross-model 実行の保存成果物の schema version（設計 §12.4）。"
const CROSS_MODEL_SCENARIO_ARTIFACT_SCHEMA_VERSION = "dme.cross-model-scenario/1.0.0"

"""
cross-model 実行が `SimulationResult.metadata` へ追加する予約キー 10 個（設計 §12.3）。
イベント層の 20 キー・CCC の予約キーを上書きしない。
"""
const CROSS_MODEL_METADATA_KEYS = (
    "cross_model_contract_version",
    "cross_model_input_set_hash",
    "cross_model_inputs",
    "cross_model_upstream_artifacts",
    "cross_model_mapping_refs",
    "cross_model_compatibility_report_hashes",
    "cross_model_transmission_modes",
    "cross_model_claim_scope",
    "cross_model_warnings",
    "cross_model_rejections",
)

"""
    CrossModelProvenance

cross-model 実行固有の identity（設計 §12.1–§12.2）。event 層の `ScenarioProvenance` と並べて保持する。
"""
struct CrossModelProvenance
    contract_version::String
    model_mapping_version::String
    cross_model_input_set_hash::String
    upstream_content_hashes::Vector{String}
    mapping_hashes::Vector{String}
    compatibility_report_hashes::Vector{String}
end

"""
    CrossModelScenarioRun

`run_cross_model_scenario` の戻り値（設計 §10.5）。`ScenarioRun` と同じ情報に加え、
`model_derived_inputs`・`cross_model_rejections`・`cross_model_warnings`・`input_log`・
`cross_model_provenance` を持つ。`status = :rejected_*` のとき `result === nothing`・
`exog === nothing`（モデルを実行していない）。

`applied_inputs` は event 由来と上流由来の `L4` を両方含む。上流由来の `L4` の ID は
`upstream_applied_input_ids`。
"""
struct CrossModelScenarioRun
    status::Symbol
    scenario::Scenario
    model_derived_inputs::Vector{ModelDerivedInput}
    model_name::String
    model_symbol::Symbol
    applied_inputs::Vector{AppliedModelInput}
    upstream_applied_input_ids::Vector{String}
    schedule::Union{EventSchedule, Nothing}
    exog::Union{Dict{Symbol, Vector{Float64}}, Nothing}
    model_run::Any
    accounting::Any
    diagnostics::Any
    result::Union{SimulationResult, Nothing}
    event_rejections::Vector{EventRejection}
    event_warnings::Vector{ScenarioWarning}
    cross_model_rejections::Vector{CrossModelRejection}
    cross_model_warnings::Vector{CrossModelWarning}
    input_log::Vector{Dict{String, Any}}
    provenance::ScenarioProvenance
    cross_model_provenance::CrossModelProvenance
    options::ScenarioRunOptions
end

# ===========================================================================
# 実行前検証（設計 §10.5 ステップ1）
# ===========================================================================

"""
    _cross_model_validate_inputs(m, sc, xs) -> Vector{CrossModelRejection}

`xs` の集合検証（`stage = :run_validation`）。全件を列挙し、1 件目で打ち切らない。
"""
function _cross_model_validate_inputs(
    m::CapexCreditCycleModel,
    sc::Scenario,
    xs::Vector{ModelDerivedInput},
)
    rejections = CrossModelRejection[]
    ids = [x.input_id for x in xs]
    dup = sort(unique([id for id in ids if count(==(id), ids) > 1]))
    if !isempty(dup)
        push!(
            rejections,
            CrossModelRejection(;
                code = :duplicate_input_id,
                stage = :run_validation,
                subject_ids = dup,
                detail = "ModelDerivedInput の input_id が重複しています: $(dup)" *
                         "（schedule_events の duplicate_dropped に委ねず実行前に拒否する。設計 §10.4）",
            ),
        )
    end
    assumption_ids = Set(a.assumption_id for a in sc.assumptions)
    clash = sort(unique([id for id in ids if id in assumption_ids]))
    if !isempty(clash)
        push!(
            rejections,
            CrossModelRejection(;
                code = :duplicate_input_id,
                stage = :run_validation,
                subject_ids = clash,
                detail = "ModelDerivedInput の input_id が Scenario の assumption_id と衝突しています: $(clash)",
            ),
        )
    end
    msym = model_symbol(m)
    for x in xs
        if x.target_model !== msym
            push!(
                rejections,
                CrossModelRejection(;
                    code = :unsupported_target_model,
                    stage = :run_validation,
                    subject_ids = [x.input_id],
                    detail = "入力 $(x.input_id) の target_model=$(x.target_model) は実行対象 $(msym) と一致しません",
                ),
            )
            continue
        end
        t0 = _cross_model_resolve_t0(x, sc.period_zero; stage = :run_validation)
        t0 isa CrossModelRejection && push!(rejections, t0)
    end
    return rejections
end

# ===========================================================================
# 警告: upstream_event_same_target（設計 §10.4）
# ===========================================================================

function _cross_model_same_target_warnings(
    event_inputs::Vector{AppliedModelInput},
    upstream_inputs::Vector{AppliedModelInput},
)
    warnings = CrossModelWarning[]
    for u in upstream_inputs
        overlapping = String[]
        for e in event_inputs
            e.target_variable === u.target_variable || continue
            any(i -> u.values[i] != 0.0 && e.values[i] != 0.0, eachindex(u.values)) &&
                push!(overlapping, e.input_id)
        end
        isempty(overlapping) && continue
        push!(
            warnings,
            CrossModelWarning(;
                code = :upstream_event_same_target,
                subject_ids = vcat([u.input_id], overlapping),
                detail = "$(u.target_variable) に上流由来の入力 $(u.input_id) と event 由来の入力 " *
                         "$(overlapping) が同じ期に重なります。同じ現象を二重に計上していないか確認して" *
                         "ください（DME は両者が同じ現象かを判定しません。設計 §10.4）",
            ),
        )
    end
    return warnings
end

# ===========================================================================
# 監査ログ・要約（設計 §12.3–§12.4、#282 Scope 6）
# ===========================================================================

function _cross_model_input_log_entry(
    x::ModelDerivedInput,
    applied::AppliedModelInput,
    periods::Vector{Int},
    period_zero::Union{CalendarQuarter, Nothing},
)
    applied_periods = [periods[i] for i in eachindex(periods) if applied.values[i] != 0.0]
    q = length(x.values)
    t0 = applied.t_apply
    return Dict{String, Any}(
        "input_id" => x.input_id,
        "applied_input_id" => applied.input_id,
        "target_model" => String(x.target_model),
        "target_concept" => String(x.target_concept),
        "target_group" => String(x.target_group),
        "target_variable" => String(applied.target_variable),
        "application_mode" => String(applied.application_mode),
        "unit" => applied.unit,
        "timing_basis" => String(x.timing_basis),
        "anchor_quarter" =>
            x.anchor_quarter === nothing ? nothing : quarter_label(x.anchor_quarter),
        "period_zero" => period_zero === nothing ? nothing : quarter_label(period_zero),
        "t_start" => x.t_start,
        "t0" => t0,
        "source_quarters" => q,
        "truncated_quarters" => max(0, t0 + q - 1 - maximum(periods)),
        "placed_periods" => collect(t0:min(t0 + q - 1, maximum(periods))),
        "applied_periods" => applied_periods,
        "path_percent" => [100.0 * v for v in x.values],
        "path_min_percent" => 100.0 * minimum(x.values),
        "post_horizon" => String(x.post_horizon),
        "coverage" => _scenario_hash_encode(x.coverage),
        "transmission_mode" => String(x.transmission_mode),
        "claim_scope" => String(x.claim_scope),
        "upstream_artifact_id" => x.upstream.artifact_id,
        "upstream_content_hash" => x.upstream.content_hash,
        "mapping_id" => x.mapping_id,
        "mapping_version" => x.mapping_version,
        "mapping_hash" => x.mapping_hash,
        "compatibility_report_hash" => x.compatibility_report_hash,
        "model_mapping_rule" => applied.mapping_id,
        "model_mapping_version" => applied.mapping_version,
    )
end

_cross_model_claim_scope(xs::Vector{ModelDerivedInput}) =
    isempty(xs) ? nothing :
    any(x -> x.claim_scope === :hypothetical_fictional, xs) ? :hypothetical_fictional :
    :same_economy_model_derived

function _cross_model_provenance(xs::Vector{ModelDerivedInput})
    return CrossModelProvenance(
        CROSS_MODEL_INPUT_CONTRACT_VERSION,
        CCC_CROSS_MODEL_MAPPING_VERSION,
        cross_model_input_set_hash(xs),
        sort(unique([x.upstream.content_hash for x in xs])),
        sort(unique([x.mapping_hash for x in xs])),
        sort(unique([x.compatibility_report_hash for x in xs])),
    )
end

function _cross_model_upstream_refs(xs::Vector{ModelDerivedInput})
    seen = Dict{String, Dict{String, Any}}()
    for x in xs
        haskey(seen, x.upstream.content_hash) && continue
        seen[x.upstream.content_hash] = upstream_artifact_ref_to_dict(x.upstream)
    end
    return Any[seen[k] for k in sort(collect(keys(seen)))]
end

function _cross_model_mapping_refs(xs::Vector{ModelDerivedInput})
    refs = Dict{String, Dict{String, Any}}()
    for x in xs
        refs[x.mapping_hash] = Dict{String, Any}(
            "mapping_id" => x.mapping_id,
            "mapping_version" => x.mapping_version,
            "mapping_hash" => x.mapping_hash,
            "target_model_mapping_version" => CCC_CROSS_MODEL_MAPPING_VERSION,
        )
    end
    return Any[refs[k] for k in sort(collect(keys(refs)))]
end

function _cross_model_merge_metadata!(
    result::SimulationResult,
    xs::Vector{ModelDerivedInput},
    input_log::Vector{Dict{String, Any}},
    provenance::CrossModelProvenance,
    warnings::Vector{CrossModelWarning},
    rejections::Vector{CrossModelRejection},
)
    md = result.metadata
    for k in CROSS_MODEL_METADATA_KEYS
        haskey(md, k) && throw(
            ArgumentError(
                "cross-model metadata 予約キー \"$(k)\" が既に存在します（上書きしない）",
            ),
        )
    end
    scope = _cross_model_claim_scope(xs)
    md["cross_model_contract_version"] = provenance.contract_version
    md["cross_model_input_set_hash"] = provenance.cross_model_input_set_hash
    md["cross_model_inputs"] = [copy(e) for e in input_log]
    md["cross_model_upstream_artifacts"] = _cross_model_upstream_refs(xs)
    md["cross_model_mapping_refs"] = _cross_model_mapping_refs(xs)
    md["cross_model_compatibility_report_hashes"] =
        copy(provenance.compatibility_report_hashes)
    md["cross_model_transmission_modes"] =
        Dict{String, Any}(x.input_id => String(x.transmission_mode) for x in xs)
    md["cross_model_claim_scope"] = scope === nothing ? nothing : String(scope)
    md["cross_model_warnings"] = [_cross_model_warning_to_dict(w) for w in warnings]
    md["cross_model_rejections"] = [_cross_model_rejection_to_dict(r) for r in rejections]
    return nothing
end

# ===========================================================================
# run_cross_model_scenario（`X6`）
# ===========================================================================

function _cross_model_run_result(
    status::Symbol,
    sc::Scenario,
    xs::Vector{ModelDerivedInput},
    m::CapexCreditCycleModel,
    inputs::Vector{AppliedModelInput},
    upstream_ids::Vector{String},
    schedule,
    exog,
    model_run,
    accounting,
    diagnostics,
    result,
    event_rejections::Vector{EventRejection},
    event_warnings::Vector{ScenarioWarning},
    xm_rejections::Vector{CrossModelRejection},
    xm_warnings::Vector{CrossModelWarning},
    input_log::Vector{Dict{String, Any}},
    provenance::ScenarioProvenance,
    options::ScenarioRunOptions,
)
    return CrossModelScenarioRun(
        status,
        sc,
        xs,
        model_name(m),
        model_symbol(m),
        inputs,
        upstream_ids,
        schedule,
        exog,
        model_run,
        accounting,
        diagnostics,
        result,
        event_rejections,
        event_warnings,
        xm_rejections,
        xm_warnings,
        input_log,
        provenance,
        _cross_model_provenance(xs),
        options,
    )
end

"""
    run_cross_model_scenario(m::CapexCreditCycleModel, sc::Scenario,
                             xs::Vector{ModelDerivedInput};
                             options::ScenarioRunOptions = ScenarioRunOptions())
        -> CrossModelScenarioRun

event 由来の仮定（`sc.assumptions`）と上流モデル由来の入力（`xs`）を含むシナリオを実行する
（`X6`、設計 §10.5）。`run_scenario` を変更せず、次の固定順で実行する。

1. 検証: `Scenario` 全体検証（既存）と `xs` の集合検証（ID の重複・衝突・`target_model`・
   配置基準・助走区間）。失敗は `:rejected_validation`。
2. mapping: `sc.assumptions` に `map_event`（既存）、`xs` に `map_model_derived_input`。cross-model の
   拒否が 1 件でもあれば `:rejected_mapping`（`on_unmapped = :warn` でも実行しない）。
3. schedule: 両系統の `L4` を連結して `schedule_events`（既存の全順序・固定順合成）。
4. model: `capex_run`（`exog` を明示的に渡す）。
5. 会計・診断: `run_scenario` と同じ。
6. result: `to_simulation_result` + イベント層 metadata 20 キー + cross-model metadata 10 キー
   （`CROSS_MODEL_METADATA_KEYS`）。

`xs` が空のとき、外生パスと系列は同じ `m`・`sc`・`options` の `run_scenario` と一致する。
例外を投げない（`options.on_unmapped` が不正な場合を除く）。
"""
function run_cross_model_scenario(
    m::CapexCreditCycleModel,
    sc::Scenario,
    xs::Vector{ModelDerivedInput};
    options::ScenarioRunOptions = ScenarioRunOptions(),
)
    options.on_unmapped in (:reject, :warn) || throw(
        ArgumentError(
            "ScenarioRunOptions.on_unmapped=$(options.on_unmapped) は :reject/:warn の" *
            "いずれかでなければなりません（統合設計 §6.4、`Y-06`）",
        ),
    )
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
            "cross_model_input_contract_version" => CROSS_MODEL_INPUT_CONTRACT_VERSION,
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
    empty_log = Dict{String, Any}[]
    no_inputs = AppliedModelInput[]

    # ステップ1: 検証
    structural = _scenario_validate_structure(sc, m, options)
    xm_validation = _cross_model_validate_inputs(m, sc, xs)
    if !isempty(structural) || !isempty(xm_validation)
        return _cross_model_run_result(
            :rejected_validation,
            sc,
            xs,
            m,
            no_inputs,
            String[],
            nothing,
            nothing,
            nothing,
            nothing,
            nothing,
            nothing,
            structural,
            ScenarioWarning[],
            xm_validation,
            CrossModelWarning[],
            empty_log,
            provenance,
            options,
        )
    end

    n = model_options.horizon_runup + model_options.horizon_eval
    periods = collect((-model_options.horizon_runup):(model_options.horizon_eval - 1))
    baseline = _ccc_baseline_exog(m, n)

    # ステップ2: mapping（event 由来と上流由来を別関数で変換する）
    event_inputs, event_map_rejections, event_map_warnings =
        _scenario_map_assumptions(m, sc, periods, baseline, options)
    upstream_inputs = AppliedModelInput[]
    xm_rejections = CrossModelRejection[]
    xm_warnings = CrossModelWarning[]
    input_log = Dict{String, Any}[]
    for x in sort(xs; by = x -> x.input_id)
        mapped, ws = map_model_derived_input(
            m,
            x;
            periods = periods,
            baseline = baseline,
            period_zero = sc.period_zero,
        )
        append!(xm_warnings, ws)
        if mapped isa CrossModelRejection
            push!(xm_rejections, mapped)
        else
            push!(upstream_inputs, mapped)
            push!(
                input_log,
                _cross_model_input_log_entry(x, mapped, periods, sc.period_zero),
            )
        end
    end
    append!(xm_warnings, _cross_model_same_target_warnings(event_inputs, upstream_inputs))
    pre_warnings = vcat(
        event_map_warnings,
        _scenario_confidence_warnings(sc, options),
        _scenario_timing_sensitive_warnings(sc, options),
    )
    inputs = vcat(event_inputs, upstream_inputs)
    upstream_ids = [i.input_id for i in upstream_inputs]

    if !isempty(event_map_rejections) || !isempty(xm_rejections)
        return _cross_model_run_result(
            :rejected_mapping,
            sc,
            xs,
            m,
            inputs,
            upstream_ids,
            nothing,
            nothing,
            nothing,
            nothing,
            nothing,
            nothing,
            event_map_rejections,
            pre_warnings,
            xm_rejections,
            xm_warnings,
            input_log,
            provenance,
            options,
        )
    end

    # ステップ3: schedule_events（既存の全順序・固定順合成を 1 回だけ呼ぶ）
    schedule = schedule_events(inputs, sc, baseline)
    if !isempty(schedule.rejections)
        return _cross_model_run_result(
            :rejected_mapping,
            sc,
            xs,
            m,
            inputs,
            upstream_ids,
            schedule,
            nothing,
            nothing,
            nothing,
            nothing,
            nothing,
            schedule.rejections,
            vcat(pre_warnings, schedule.warnings),
            xm_rejections,
            xm_warnings,
            input_log,
            provenance,
            options,
        )
    end

    # ステップ4: capex_run
    model_run = capex_run(
        m;
        scenario = sc.id,
        exog = schedule.paths,
        options = model_options,
        validate_accounting = false,
        diagnostics = false,
    )

    # ステップ5: 会計・診断（`run_scenario` と同じ扱い）
    accounting =
        options.validate_accounting ? validate_capex_accounting(m, model_run) : nothing
    thresholds =
        options.thresholds === nothing ? CapexDiagnosticThresholds() : options.thresholds
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

    # ステップ6: SimulationResult + metadata（イベント層 20 キー + cross-model 10 キー）
    result = to_simulation_result(m, model_run, String(sc.id))
    event_warnings = vcat(
        pre_warnings,
        schedule.warnings,
        _scenario_extreme_shock_warnings(inputs, periods, options),
    )
    _scenario_merge_event_metadata!(
        result,
        sc,
        status,
        options,
        schedule,
        EventRejection[],
        event_warnings,
        provenance,
    )
    xm_provenance = _cross_model_provenance(xs)
    _cross_model_merge_metadata!(
        result,
        xs,
        input_log,
        xm_provenance,
        xm_warnings,
        CrossModelRejection[],
    )

    return CrossModelScenarioRun(
        status,
        sc,
        xs,
        model_name(m),
        model_symbol(m),
        inputs,
        upstream_ids,
        schedule,
        schedule.paths,
        model_run,
        accounting,
        diagnostics,
        result,
        EventRejection[],
        event_warnings,
        CrossModelRejection[],
        xm_warnings,
        input_log,
        provenance,
        xm_provenance,
        options,
    )
end

"""
    cross_model_input_summary(run::CrossModelScenarioRun) -> Dict{String,Any}

「PNE shock が DME のどの入力へ変換されたか」を確認するための要約（#282 Scope 6）。入力ごとに
採用した source sector（member）・除外した sector（unmapped）・被覆率・target 変数・適用期・
パスの最小値・provenance chain を持つ。status・拒否・警告も含める。
"""
function cross_model_input_summary(run::CrossModelScenarioRun)
    scope = _cross_model_claim_scope(run.model_derived_inputs)
    return Dict{String, Any}(
        "status" => String(run.status),
        "claim_scope" => scope === nothing ? nothing : String(scope),
        "cross_model_input_set_hash" =>
            run.cross_model_provenance.cross_model_input_set_hash,
        "inputs" => [copy(e) for e in run.input_log],
        "provenance_chain" => Any[
            Dict{String, Any}(
                "input_id" => x.input_id,
                "applied_input_ids" => [
                    id for id in run.upstream_applied_input_ids if
                    startswith(id, x.input_id * "/")
                ],
                "mapping_hash" => x.mapping_hash,
                "compatibility_report_hash" => x.compatibility_report_hash,
                "upstream_artifact_id" => x.upstream.artifact_id,
                "upstream_content_hash" => x.upstream.content_hash,
                "dynamic_artifact_id" => x.upstream.dynamic_artifact_id,
                "dynamic_artifact_hash" => x.upstream.dynamic_artifact_hash,
                "scenario_hash" => x.upstream.scenario_hash,
                "scenario_policy_hash" => x.upstream.scenario_policy_hash,
                "scenario_config_hash" => x.upstream.scenario_config_hash,
                "export_config_hash" => x.upstream.export_config_hash,
                "source_input_hash" => x.upstream.source_input_hash,
                "network_id" => x.upstream.network_id,
            ) for x in sort(run.model_derived_inputs; by = x -> x.input_id)
        ],
        "cross_model_rejections" =>
            [_cross_model_rejection_to_dict(r) for r in run.cross_model_rejections],
        "cross_model_warnings" =>
            [_cross_model_warning_to_dict(w) for w in run.cross_model_warnings],
        "event_rejections" =>
            [_scenario_rejection_to_dict(r) for r in run.event_rejections],
    )
end

# ===========================================================================
# 保存（`X7`、設計 §12.4）
# ===========================================================================

function _cross_model_scenario_dict(sc::Scenario, xs::Vector{ModelDerivedInput})
    sorted = sort(xs; by = x -> x.input_id)
    return Dict{String, Any}(
        "schema_version" => CROSS_MODEL_SCENARIO_ARTIFACT_SCHEMA_VERSION,
        "contract_version" => CROSS_MODEL_INPUT_CONTRACT_VERSION,
        "scenario" => scenario_to_dict(sc),
        "model_derived_inputs" => Any[model_derived_input_to_dict(x) for x in sorted],
        "cross_model_input_set_hash" => cross_model_input_set_hash(xs),
    )
end

function _cross_model_report_dict_hash(d::AbstractDict)
    dd = deepcopy(Dict{String, Any}(String(k) => v for (k, v) in d))
    up = Dict{String, Any}(String(k) => v for (k, v) in dd["upstream"])
    delete!(up, "source_bytes_sha256")
    dd["upstream"] = up
    return "sha256:" * sha256_hex_of_canonical(dd)
end

function _cross_model_report_markdown(run::CrossModelScenarioRun)
    sc = run.scenario
    scope = _cross_model_claim_scope(run.model_derived_inputs)
    io = IOBuffer()
    println(io, "# Cross-model Scenario Run Report")
    println(io)
    println(io, "- scenario_id: `$(sc.id)`")
    println(io, "- model: `$(run.model_name)` (`$(run.model_symbol)`)")
    println(io, "- status: `$(run.status)`")
    println(io, "- event assumptions: $(length(sc.assumptions))")
    println(io, "- upstream model-derived inputs: $(length(run.model_derived_inputs))")
    println(io, "- claim_scope: `$(scope === nothing ? "none" : scope)`")
    println(
        io,
        "- cross_model_input_set_hash: `$(run.cross_model_provenance.cross_model_input_set_hash)`",
    )
    println(io)
    println(io, "## Upstream model-derived inputs")
    println(io)
    for e in run.input_log
        cov = e["coverage"]
        println(
            io,
            "- `$(e["input_id"])` → `$(e["target_variable"])`（t0=$(e["t0"])・" *
            "covered_share=$(cov["covered_share"])・uncovered_share=$(cov["uncovered_share"])・" *
            "claim_scope=$(e["claim_scope"])）",
        )
    end
    println(io)
    if !isempty(run.cross_model_rejections) || !isempty(run.event_rejections)
        println(io, "## Rejections")
        println(io)
        for r in run.cross_model_rejections
            println(io, "- `$(r.code)` ($(r.stage)): $(r.detail)")
        end
        for r in run.event_rejections
            println(io, "- `$(r.code)` ($(r.layer)): $(r.detail)")
        end
        println(io)
    end
    if !isempty(run.cross_model_warnings)
        println(io, "## Cross-model warnings")
        println(io)
        for w in run.cross_model_warnings
            println(io, "- `$(w.code)`: $(w.detail)")
        end
        println(io)
    end
    println(io, "## Notes")
    println(io)
    println(
        io,
        "- 上流（PNE）の値はシナリオ条件付きのモデル導出結果であり、観測・実績・予測ではない。",
    )
    println(
        io,
        "- 派生需要入力は target 変数のうち mapping がカバーする割合に限った寄与であり、" *
        "uncovered share は本入力の対象外である（影響の有無を述べるものではない）。",
    )
    println(io, "- mapping の weight・顧客区分は識別仮定である（PG-04）。")
    println(
        io,
        "- CCC は供給能力の外生入力を持たず、対応部門自身の供給制約を表現しない（PG-01）。",
    )
    if scope === :hypothetical_fictional
        println(
            io,
            "- claim_scope=hypothetical_fictional: 架空（synthetic）の供給網入力による仮想シナリオであり、" *
            "実在の経済・部門・企業の途絶の影響を表さない。",
        )
    end
    println(
        io,
        "- 本レポートは実行結果の機械的要約であり、投資判断・政策提言を目的としない。",
    )
    return String(take!(io))
end

"""
    save_cross_model_scenario_artifact(dir::AbstractString, run::CrossModelScenarioRun;
                                       mappings::Vector{CrossModelMapping},
                                       reports::Vector{CrossModelCompatibilityReport})
        -> Vector{String}

cross-model 実行の成果物を `dir` へ書き出す（`X7`、設計 §12.4）。**既存の `scenario.json` は
書かない**（既存 `replay_scenario` が上流入力を欠いたまま再実行することを防ぐ）。

- `cross_model_scenario.json`（`dme.cross-model-scenario/1.0.0`）: `scenario`（`scenario_to_dict`）・
  `model_derived_inputs`・`cross_model_input_set_hash`
- `mappings.json` / `compatibility_reports.json`: 入力が参照する mapping artifact・report の全件
- `event_log.json`（既存形式）・`cross_model_input_log.json`・`manifest.json`・
  `result_summary.json`・`report.md`

`mappings`・`reports` は `run.model_derived_inputs` が参照する hash をすべて含まなければならない
（不足は `provenance_chain_broken` の `ArgumentError`）。
"""
function save_cross_model_scenario_artifact(
    dir::AbstractString,
    run::CrossModelScenarioRun;
    mappings::Vector{CrossModelMapping},
    reports::Vector{CrossModelCompatibilityReport},
)
    mapping_by_hash = Dict(cross_model_mapping_hash(mp) => mp for mp in mappings)
    report_by_hash = Dict(cross_model_compatibility_report_hash(r) => r for r in reports)
    for x in run.model_derived_inputs
        haskey(mapping_by_hash, x.mapping_hash) || throw(
            ArgumentError(
                "provenance_chain_broken: 入力 $(x.input_id) が参照する mapping $(x.mapping_hash) が " *
                "mappings に含まれていません",
            ),
        )
        haskey(report_by_hash, x.compatibility_report_hash) || throw(
            ArgumentError(
                "provenance_chain_broken: 入力 $(x.input_id) が参照する compatibility report " *
                "$(x.compatibility_report_hash) が reports に含まれていません",
            ),
        )
    end
    used_mappings = unique([x.mapping_hash for x in run.model_derived_inputs])
    used_reports = unique([x.compatibility_report_hash for x in run.model_derived_inputs])

    mkpath(dir)
    paths = String[]
    push!(
        paths,
        _scenario_write_json(
            joinpath(dir, "cross_model_scenario.json"),
            _cross_model_scenario_dict(run.scenario, run.model_derived_inputs),
        ),
    )
    push!(
        paths,
        _scenario_write_json(
            joinpath(dir, "mappings.json"),
            Dict{String, Any}(
                "schema_version" => CROSS_MODEL_SCENARIO_ARTIFACT_SCHEMA_VERSION,
                "mappings" => Any[
                    cross_model_mapping_to_dict(mapping_by_hash[h]) for
                    h in sort(used_mappings)
                ],
            ),
        ),
    )
    push!(
        paths,
        _scenario_write_json(
            joinpath(dir, "compatibility_reports.json"),
            Dict{String, Any}(
                "schema_version" => CROSS_MODEL_SCENARIO_ARTIFACT_SCHEMA_VERSION,
                "reports" => Any[
                    cross_model_compatibility_report_to_dict(report_by_hash[h]) for
                    h in sort(used_reports)
                ],
            ),
        ),
    )
    log_entries =
        run.schedule === nothing ? Dict{String, Any}[] : scenario_event_log(run.schedule)
    push!(
        paths,
        _scenario_write_json(
            joinpath(dir, "event_log.json"),
            Dict{String, Any}(
                "schema_version" => SCENARIO_ARTIFACT_SCHEMA_VERSION,
                "event_log" => log_entries,
            ),
        ),
    )
    push!(
        paths,
        _scenario_write_json(
            joinpath(dir, "cross_model_input_log.json"),
            Dict{String, Any}(
                "schema_version" => CROSS_MODEL_SCENARIO_ARTIFACT_SCHEMA_VERSION,
                "inputs" => Any[copy(e) for e in run.input_log],
            ),
        ),
    )
    manifest = _scenario_manifest_dict(
        run.provenance,
        run.status,
        length(run.event_warnings) + length(run.cross_model_warnings),
        length(run.event_rejections) + length(run.cross_model_rejections),
    )
    manifest["run_kind"] = "cross_model"
    manifest["cross_model_contract_version"] = run.cross_model_provenance.contract_version
    manifest["cross_model_input_set_hash"] =
        run.cross_model_provenance.cross_model_input_set_hash
    manifest["model_mapping_version"] = run.cross_model_provenance.model_mapping_version
    push!(paths, _scenario_write_json(joinpath(dir, "manifest.json"), manifest))
    summary = if run.result === nothing
        Dict{String, Any}(
            "schema_version" => CROSS_MODEL_SCENARIO_ARTIFACT_SCHEMA_VERSION,
            "status" => String(run.status),
            "metadata" => nothing,
            "variables" => nothing,
        )
    else
        Dict{String, Any}(
            "schema_version" => CROSS_MODEL_SCENARIO_ARTIFACT_SCHEMA_VERSION,
            "status" => String(run.status),
            "metadata" => Dict{String, Any}(
                String(k) => _scenario_hash_encode(v) for (k, v) in run.result.metadata
            ),
            "variables" => Dict{String, Any}(
                String(k) => copy(v) for (k, v) in pairs(run.result.variables)
            ),
        )
    end
    push!(paths, _scenario_write_json(joinpath(dir, "result_summary.json"), summary))
    report_path = joinpath(dir, "report.md")
    write(report_path, _cross_model_report_markdown(run))
    push!(paths, report_path)
    return paths
end

# ===========================================================================
# 読み込み・replay（`X7`、設計 §12.4）
# ===========================================================================

function _cross_model_read_json(path::AbstractString)
    isfile(path) || throw(ArgumentError("$(path) が見つかりません"))
    d = _scenario_json_to_plain(json_read(read(path, String)))
    d isa AbstractDict ||
        throw(ArgumentError("$(path): トップレベルは object でなければなりません"))
    return d
end

"""
    load_cross_model_scenario(path::AbstractString) -> (Scenario, Vector{ModelDerivedInput})

`cross_model_scenario.json` を読み込む（fail closed: 未知 schema version・キーの過不足・
`scenario` の decode 失敗（`scenario_from_dict`）・`cross_model_input_set_hash` の不一致は
`ArgumentError`）。
"""
function load_cross_model_scenario(path::AbstractString)
    d = _cross_model_read_json(path)
    get(d, "schema_version", nothing) == CROSS_MODEL_SCENARIO_ARTIFACT_SCHEMA_VERSION ||
        throw(
            ArgumentError(
                "unsupported_schema_version: $(path) の schema_version は " *
                "$(CROSS_MODEL_SCENARIO_ARTIFACT_SCHEMA_VERSION) でなければなりません",
            ),
        )
    expected = Set([
        "schema_version",
        "contract_version",
        "scenario",
        "model_derived_inputs",
        "cross_model_input_set_hash",
    ])
    Set(String(k) for k in keys(d)) == expected || throw(
        ArgumentError("$(path): キー集合が $(sort(collect(expected))) と一致しません"),
    )
    d["contract_version"] == CROSS_MODEL_INPUT_CONTRACT_VERSION || throw(
        ArgumentError(
            "$(path): contract_version=$(d["contract_version"]) は受理されません" *
            "（$(CROSS_MODEL_INPUT_CONTRACT_VERSION)）",
        ),
    )
    sc = scenario_from_dict(d["scenario"])
    xs = ModelDerivedInput[
        model_derived_input_from_dict(x) for x in d["model_derived_inputs"]
    ]
    cross_model_input_set_hash(xs) == d["cross_model_input_set_hash"] || throw(
        ArgumentError(
            "provenance_chain_broken: $(path) の cross_model_input_set_hash が再計算値と一致しません",
        ),
    )
    return sc, xs
end

"""
    replay_cross_model_scenario(m::CapexCreditCycleModel, dir::AbstractString;
                                options::ScenarioRunOptions = ScenarioRunOptions(),
                                upstream_artifacts = nothing) -> CrossModelScenarioRun

保存済み成果物から再実行する（`X7`、設計 §12.4）。**replay の入力は
`cross_model_scenario.json` のみ**であり、PNE artifact のバイト列・ネットワーク・API キー・
ローカル絶対パスに依存しない。

1. `load_cross_model_scenario` で `Scenario` と `ModelDerivedInput` を復元する。
2. `mappings.json`・`compatibility_reports.json` を読み、各入力の `mapping_hash`・
   `compatibility_report_hash` が同梱ファイルの再計算値と一致し、report の upstream・mapping の
   参照が入力と一致することを検証する（不一致は `provenance_chain_broken`）。
3. `run_cross_model_scenario` を再実行し、`manifest.json` の `params_hash`・`initial_state_id`・
   `solver_settings_hash`・`cross_model_input_set_hash` と照合する（不一致は
   `params_identity_mismatch` / `provenance_chain_broken`）。
4. `upstream_artifacts`（`content_hash => PNE artifact のパス`）が与えられた場合に限り、PNE artifact
   から `X1`–`X3` を再実行し、入力の `values` が bit 単位で一致することを検証する（再導出検証）。
"""
function replay_cross_model_scenario(
    m::CapexCreditCycleModel,
    dir::AbstractString;
    options::ScenarioRunOptions = ScenarioRunOptions(),
    upstream_artifacts::Union{AbstractDict, Nothing} = nothing,
)
    sc, xs = load_cross_model_scenario(joinpath(dir, "cross_model_scenario.json"))

    mappings_doc = _cross_model_read_json(joinpath(dir, "mappings.json"))
    mapping_by_hash = Dict{String, CrossModelMapping}()
    for md in mappings_doc["mappings"]
        mp = cross_model_mapping_from_dict(md)
        mapping_by_hash[cross_model_mapping_hash(mp)] = mp
    end
    reports_doc = _cross_model_read_json(joinpath(dir, "compatibility_reports.json"))
    report_by_hash = Dict{String, Dict{String, Any}}()
    for rd in reports_doc["reports"]
        report_by_hash[_cross_model_report_dict_hash(rd)] = rd
    end
    for x in xs
        haskey(mapping_by_hash, x.mapping_hash) || throw(
            ArgumentError(
                "provenance_chain_broken: 入力 $(x.input_id) の mapping_hash=$(x.mapping_hash) に一致する " *
                "mapping が mappings.json にありません",
            ),
        )
        rd = get(report_by_hash, x.compatibility_report_hash, nothing)
        rd === nothing && throw(
            ArgumentError(
                "provenance_chain_broken: 入力 $(x.input_id) の compatibility_report_hash に一致する " *
                "report が compatibility_reports.json にありません",
            ),
        )
        (
            rd["decision"] == "accepted" &&
            rd["mapping"]["mapping_hash"] == x.mapping_hash &&
            rd["upstream"]["content_hash"] == x.upstream.content_hash
        ) || throw(
            ArgumentError(
                "provenance_chain_broken: 入力 $(x.input_id) の report が accepted でないか、" *
                "mapping / upstream の参照が一致しません",
            ),
        )
    end

    run = run_cross_model_scenario(m, sc, xs; options = options)

    manifest = _cross_model_read_json(joinpath(dir, "manifest.json"))
    get(manifest, "run_kind", nothing) == "cross_model" ||
        throw(ArgumentError("manifest.json の run_kind が cross_model ではありません"))
    for key in ("params_hash", "initial_state_id", "solver_settings_hash")
        manifest[key] == getproperty(run.provenance, Symbol(key)) || throw(
            ArgumentError(
                "params_identity_mismatch: manifest.json の $(key)=$(manifest[key]) が現在の実行の値" *
                "=$(getproperty(run.provenance, Symbol(key))) と一致しません",
            ),
        )
    end
    manifest["cross_model_input_set_hash"] ==
    run.cross_model_provenance.cross_model_input_set_hash || throw(
        ArgumentError(
            "provenance_chain_broken: manifest.json の cross_model_input_set_hash が一致しません",
        ),
    )

    if upstream_artifacts !== nothing
        for x in xs
            path = get(upstream_artifacts, x.upstream.content_hash, nothing)
            path === nothing && continue
            a = load_pne_sector_output_path(path)
            a.content_hash == x.upstream.content_hash || throw(
                ArgumentError(
                    "provenance_chain_broken: $(path) の content_hash=$(a.content_hash) が入力 " *
                    "$(x.input_id) の upstream.content_hash と一致しません",
                ),
            )
            mp = mapping_by_hash[x.mapping_hash]
            r = check_cross_model_compatibility(a, mp)
            cross_model_compatibility_report_hash(r) == x.compatibility_report_hash ||
                throw(
                    ArgumentError(
                        "provenance_chain_broken: 再計算した compatibility report の hash が入力 " *
                        "$(x.input_id) の参照と一致しません",
                    ),
                )
            paths = apply_cross_model_mapping(a, mp, r)
            p = only(filter(p -> p.target_group === x.target_group, paths))
            p.values == x.values || throw(
                ArgumentError(
                    "provenance_chain_broken: PNE artifact から再導出した $(x.target_group) の値が " *
                    "入力 $(x.input_id) の値と一致しません",
                ),
            )
        end
    end
    return run
end
