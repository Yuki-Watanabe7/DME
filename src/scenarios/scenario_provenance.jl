# scenario_provenance.jl: 型写像 encoder・再現契約 hash・event_log 監査 dict・manifest 構築
# （Issue #203 / `E-7`）。
#
# 本ファイルは統合設計 §9.2「content identity と hash 対象」の実装本体を持つ。
# `event_set_hash`・`scenario_content_hash`・`params_hash`・`initial_state_id`・
# `solver_settings_hash` は Issue #202 / `E-6`（`scenario_runner.jl`）が暫定的に持っていたが、
# 本 Issue で本ファイルへ移設して完成させる（統合設計 §11 `E-7` 行・§4.1）。
#
# `scenario_event_log`（`EventSchedule.log` → 監査用 `Vector{Dict{String,Any}}`、統合設計 §9.1）
# と `_scenario_manifest_dict`（`ScenarioProvenance` → `manifest.json` 用 Dict、統合設計 §9.5）も
# 本ファイルに置く。`_scenario_manifest_dict` は `ScenarioRun` 型（`scenario_runner.jl`）へ
# 依存しないよう、`ScenarioProvenance`（`scenario_types.jl`）と個別のスカラー引数のみを取る
# （統合設計 §4.1 の依存表: 本ファイルの依存は `artifacts/json_canonical.jl`・
# `scenario_types.jl` のみ）。
#
# 設計契約:
#   docs/architecture/macro_event_runtime_integration.md §9.1（EventLogEntry 14項目）・
#     §9.2（content identity と hash 対象、`Y-04`・`Y-17`）・§9.4（型写像・正準化）・
#     §9.5（manifest.json の内容）・§11 `E-7` 行

# ------------------------------------------------------------
# 型写像 encoder（統合設計 §9.4）
# ------------------------------------------------------------

"""
    _scenario_hash_encode(x)

`canonical_json_bytes`（RFC 8785、`src/artifacts/json_canonical.jl`）が直接扱えない型を
Dict/Vector/String/Bool/Integer/Float64/Nothing へ写す（統合設計 §9.4 の型写像）。
`json_canonical.jl` 自体は変更しない。hash 計算（`event_set_hash` 等）と JSON シリアライズ
（`scenario_serialization.jl`）の双方から再利用する共通の型写像前段である。
"""
_scenario_hash_encode(::Nothing) = nothing
_scenario_hash_encode(::Missing) = nothing
_scenario_hash_encode(x::Symbol) = String(x)
_scenario_hash_encode(x::Date) = Dates.format(x, "yyyy-mm-dd")
_scenario_hash_encode(x::DateTime) = Dates.format(x, "yyyy-mm-ddTHH:MM:SS") * "Z"
_scenario_hash_encode(x::Bool) = x
_scenario_hash_encode(x::Integer) = x
_scenario_hash_encode(x::AbstractFloat) = Float64(x)
_scenario_hash_encode(x::AbstractString) = String(x)
_scenario_hash_encode(x::Tuple) = Any[_scenario_hash_encode(v) for v in x]
_scenario_hash_encode(x::NamedTuple) =
    Dict{String, Any}(String(k) => _scenario_hash_encode(v) for (k, v) in pairs(x))
_scenario_hash_encode(x::AbstractDict) =
    Dict{String, Any}(String(k) => _scenario_hash_encode(v) for (k, v) in x)
_scenario_hash_encode(x::AbstractVector) = Any[_scenario_hash_encode(v) for v in x]
_scenario_hash_encode(x) = throw(
    ArgumentError(
        "_scenario_hash_encode: 統合設計 §9.4 の型写像が対応しない型です: $(typeof(x))",
    ),
)

"`canonical_json_bytes` の SHA-256 を `\"sha256:<64hex>\"` 形式で返す（統合設計 §9.2）。"
_scenario_sha256(value)::String = "sha256:" * sha256_hex_of_canonical(value)

# ------------------------------------------------------------
# event_set_hash / scenario_content_hash（統合設計 §9.2、`Y-04`・`Y-17`）
# ------------------------------------------------------------

"""
    _scenario_assumption_hash_dict(a::ScenarioAssumption) -> Dict{String,Any}

`ScenarioAssumption` の hash 対象フィールドのみを Dict へ写す（統合設計 §9.2 の「hash に
含める」表）。`confidence`・`uncertainty`・`notes`・`caveats`・`provenance.generated_at` は
含めない（volatile / 表示専用）。
"""
function _scenario_assumption_hash_dict(a::ScenarioAssumption)
    timing = a.timing
    persistence = a.persistence
    provenance = a.provenance
    return Dict{String, Any}(
        "assumption_id" => a.assumption_id,
        "event_type" => String(a.event_type),
        "schema_version" => a.schema_version,
        "sector" => String(a.sector),
        "geography" => a.geography,
        "direction" => String(a.direction),
        "magnitude" => a.magnitude,
        "unit" => a.unit,
        "magnitude_source" => String(a.magnitude_source),
        "application_mode" => String(a.application_mode),
        "timing" => Dict{String, Any}(
            "basis" => String(timing.basis),
            "rule" => String(timing.rule),
            "effective_from" => _scenario_hash_encode(timing.effective_from),
            "effective_until" => _scenario_hash_encode(timing.effective_until),
            "t_apply" => timing.t_apply,
            "t_until" => timing.t_until,
            "rule_overridden" => timing.rule_overridden,
            "from_source" => String(timing.from_source),
        ),
        "persistence" => Dict{String, Any}(
            "shape" => String(persistence.shape),
            "duration" => persistence.duration,
            "params" => _scenario_hash_encode(persistence.params),
        ),
        "target_concepts" => sort(String.(a.target_concepts)),
        "is_scenario_assumption" => a.is_scenario_assumption,
        "provenance" => Dict{String, Any}(
            "layer" => String(provenance.layer),
            "derived_from" => sort(copy(provenance.derived_from)),
            "rule_id" => provenance.rule_id,
            "rule_version" => provenance.rule_version,
            "generator" => provenance.generator,
        ),
    )
end

"""
    event_set_hash(sc::Scenario) -> String

`sc.assumptions`（`L3` 集合）のみを対象とした `"sha256:…"`（統合設計 §9.2）。
`assumption_id` 昇順に整列してから正準化するため、入力順・`Vector` の反復順に依存しない
（統合設計 §10.4 項目11）。`generated_at`/`notes`/`confidence` を変えても値は変わらない
（項目12）。`magnitude` を1ulp変えると値が変わる（項目13）。
"""
function event_set_hash(sc::Scenario)
    sorted = sort(sc.assumptions; by = a -> a.assumption_id)
    payload = Dict{String, Any}(
        "assumptions" => [_scenario_assumption_hash_dict(a) for a in sorted],
    )
    return _scenario_sha256(payload)
end

"""
    scenario_content_hash(sc::Scenario) -> String

`Scenario` 全体（時間軸設定・ホライズン・既定値セットを含む）を対象とした `"sha256:…"`
（統合設計 §9.2）。
"""
function scenario_content_hash(sc::Scenario)
    sorted = sort(sc.assumptions; by = a -> a.assumption_id)
    payload = Dict{String, Any}(
        "id" => String(sc.id),
        "name" => sc.name,
        "version" => sc.version,
        "model" => String(sc.model),
        "period_zero" =>
            sc.period_zero === nothing ? nothing :
            Dict{String, Any}(
                "year" => sc.period_zero.year,
                "quarter" => sc.period_zero.quarter,
            ),
        "horizon_runup" => sc.horizon_runup,
        "horizon_eval" => sc.horizon_eval,
        "timing_rules" => _scenario_timing_rule_set_dict(sc.timing_rules),
        "defaults_set_id" => sc.defaults_set_id,
        "defaults_set_version" => sc.defaults_set_version,
        "assumptions" => [_scenario_assumption_hash_dict(a) for a in sorted],
    )
    return _scenario_sha256(payload)
end

"`TimingRuleSet` を hash・metadata 用の `Dict` へ写す。"
function _scenario_timing_rule_set_dict(tr::TimingRuleSet)
    return Dict{String, Any}(
        "id" => tr.id,
        "version" => tr.version,
        "cutoff_month_offset" => tr.cutoff_month_offset,
        "rules" => Dict{String, Any}(String(k) => String(v) for (k, v) in tr.rules),
    )
end

# ------------------------------------------------------------
# params_hash / initial_state_id / solver_settings_hash（統合設計 §9.2、`Y-17`）
# ------------------------------------------------------------

"`parameters(m)` の正準 JSON の SHA-256（統合設計 §9.2）。"
_scenario_params_hash(m::CapexCreditCycleModel) =
    _scenario_sha256(_scenario_hash_encode(parameters(m)))

"""
    _scenario_initial_state_id(state0) -> String

`state0` の正準 JSON の SHA-256。`state0 === nothing` のときは文字列 `"steady_state"`
（統合設計 §9.2、`Y-17`）。`run_scenario` は `state0` を常に `nothing`（既定の定常状態）で
呼ぶため（`ScenarioRunOptions` に `state0` フィールドを持たない、統合設計 §5.7）、実務上は
常に `"steady_state"` を返す。
"""
_scenario_initial_state_id(::Nothing) = "steady_state"
_scenario_initial_state_id(state0) = _scenario_sha256(_scenario_hash_encode(state0))

"`CapexCreditCycleOptions` 全フィールドの正準 JSON の SHA-256（統合設計 §9.2）。"
function _scenario_solver_settings_hash(o::CapexCreditCycleOptions)
    d = Dict{String, Any}(
        "horizon_runup" => o.horizon_runup,
        "horizon_eval" => o.horizon_eval,
        "div_eps" => o.div_eps,
        "guard_max" => o.guard_max,
        "runup_tol" => o.runup_tol,
        "stop_on_sign_violation" => o.stop_on_sign_violation,
    )
    return _scenario_sha256(d)
end

# ------------------------------------------------------------
# event_log 監査 dict（統合設計 §9.1、Issue #203）
# ------------------------------------------------------------

"""
    _scenario_event_log_entry_to_dict(e::EventLogEntry) -> Dict{String,Any}

`EventLogEntry`（統合設計 §9.1 の14項目）を ASCII キーの `Dict` へ写す。フィールド名を
そのままキー名とする（既に snake_case、`Y-19`）。
"""
function _scenario_event_log_entry_to_dict(e::EventLogEntry)::Dict{String, Any}
    return Dict{String, Any}(
        "input_id" => e.input_id,
        "assumption_id" => e.assumption_id,
        "derived_from" => copy(e.derived_from),
        "event_type" => e.event_type === nothing ? nothing : String(e.event_type),
        "schema_version" => e.schema_version,
        "t_apply" => e.t_apply,
        "timing_basis" => String(e.timing_basis),
        "timing_rule" => String(e.timing_rule),
        "effective_from" => _scenario_hash_encode(e.effective_from),
        "effective_until" => _scenario_hash_encode(e.effective_until),
        "target_variable" => String(e.target_variable),
        "application_mode" => String(e.application_mode),
        "unit" => e.unit,
        "shape" => String(e.shape),
        "shape_params" => _scenario_hash_encode(e.shape_params),
        "duration" => e.duration,
        "magnitude" => e.magnitude,
        "magnitude_source" =>
            e.magnitude_source === nothing ? nothing : String(e.magnitude_source),
        "baseline_value" => copy(e.baseline_value),
        "pre_value" => copy(e.pre_value),
        "post_value" => copy(e.post_value),
        "applied_delta" => copy(e.applied_delta),
        "composition_members" => copy(e.composition_members),
        "order_key" => _scenario_hash_encode(e.order_key),
        "rule_id" => e.rule_id,
        "rule_version" => e.rule_version,
        "mapping_id" => e.mapping_id,
        "mapping_version" => e.mapping_version,
        "warnings" => String.(e.warnings),
    )
end

"""
    scenario_event_log(schedule::EventSchedule) -> Vector{Dict{String,Any}}

`schedule.log` を `order_key` 昇順に整列してから `Dict` 化する（統合設計 §9.4「配列順序は
エンコーダの責務」）。`SimulationResult.metadata["event_log"]`（`scenario_runner.jl`）と
`event_log.json`（`scenario_serialization.jl`）が共に本関数を呼ぶ単一の実装である。
"""
function scenario_event_log(schedule::EventSchedule)::Vector{Dict{String, Any}}
    sorted = sort(schedule.log; by = e -> e.order_key)
    return [_scenario_event_log_entry_to_dict(e) for e in sorted]
end

# ------------------------------------------------------------
# manifest.json 構築（統合設計 §9.5、`ScenarioProvenance` のみに依存）
# ------------------------------------------------------------

"""
    _scenario_manifest_dict(provenance::ScenarioProvenance, status::Symbol,
                             n_warnings::Int, n_rejections::Int) -> Dict{String,Any}

`manifest.json`（統合設計 §9.5）の内容を構築する。統合設計 §9.2 の再現契約タプル・
version 一覧・`status`・警告と拒否の件数を持つ。`ScenarioRun` 型（`scenario_runner.jl`）へは
依存しない（本ファイルの依存は `scenario_types.jl` の `ScenarioProvenance` のみ、統合設計
§4.1）。`save_scenario_artifact`（`scenario_serialization.jl`）が `run.provenance`/
`run.status`/`length(run.warnings)`/`length(run.rejections)` を渡して呼ぶ。
"""
function _scenario_manifest_dict(
    provenance::ScenarioProvenance,
    status::Symbol,
    n_warnings::Int,
    n_rejections::Int,
)::Dict{String, Any}
    return Dict{String, Any}(
        "schema_version" => SCENARIO_ARTIFACT_SCHEMA_VERSION,
        "status" => String(status),
        "model_version" => provenance.model_version,
        "contract_versions" =>
            Dict{String, Any}(k => v for (k, v) in provenance.contract_versions),
        "scenario_id" => provenance.scenario_id,
        "scenario_version" => provenance.scenario_version,
        "event_set_hash" => provenance.event_set_hash,
        "rule_version" => provenance.rule_version,
        "mapping_version" => provenance.mapping_version,
        "params_hash" => provenance.params_hash,
        "initial_state_id" => provenance.initial_state_id,
        "solver_settings_hash" => provenance.solver_settings_hash,
        "timing_rule_set" => provenance.timing_rule_set,
        "warnings_count" => n_warnings,
        "rejections_count" => n_rejections,
    )
end
