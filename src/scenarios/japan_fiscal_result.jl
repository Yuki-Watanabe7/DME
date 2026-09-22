# japan_fiscal_result.jl: Japan Fiscal Scenario Lab の scenario runner・result artifact
# （Issue #276）。adapter 層（scenarios/adapters/japan_fiscal_model_adapters.jl）の出力を、
# #285 claim-level 契約（H-06..H-12）を満たす versioned な machine-readable artifact へ
# 組み立てる。Market Analyzer はこの artifact のみを consume し、Julia 内部型を import しない
# （#274 §8）。
#
# 設計方針（ADR 0023）:
#   - `adoption=:not_adopted` のセル（not_representable 40件 + partial-but-not_adopted 1件）は
#     モデルを実行せず `JapanFiscalScenarioRejection` を返す（機械可読な拒否）。
#   - 実行前に `japan_fiscal_validate_claims`（#285）を呼び、違反があれば artifact を生成しない
#     （H-07）。
#   - diagnostics は `claim_level` が許す範囲だけを計算する。peak/onset/duration/relative_delta
#     は `:direction_and_relative_timing` のセルにのみ存在し、`:direction_only` のセルには
#     フィールド自体が現れない（null で隠さない・そもそも計算しない）。
#   - `japan_fiscal_coverage(family, model)` を丸ごと artifact へ埋め込む（H-06）。
#   - baseline/scenario の model・params・initial-state・horizon 一致は、両者を常に同一の
#     baseline パラメータから adapter 内部で導出することで構成上保証する（ランタイム検証では
#     なく構成上の不可能性）。
#   - hash・atomic write は artifacts/json_canonical.jl・real_rate_model_artifact_export.jl と
#     同じ idiom（RFC 8785 正準化・`generated_at` 除外・tmp+fsync+atomic rename）を流用する。
#
# 依存: scenarios/adapters/japan_fiscal_model_adapters.jl（JAPAN_FISCAL_MODEL_ADAPTERS 等）・
# scenarios/japan_fiscal_capability.jl・scenarios/japan_fiscal_claim_contract.jl・
# scenarios/japan_fiscal_scenario_schema.jl・analysis/scenario_diagnostics.jl（診断プリミティブ）・
# artifacts/json_canonical.jl（canonical_json_bytes・sha256_hex_of_canonical）。
#
# 設計契約:
#   docs/architecture/japan_fiscal_scenario_result_contract.md
#   docs/adr/0023-japan-fiscal-scenario-result-artifact-contract.md

"result artifact の契約 version。"
const JAPAN_FISCAL_RESULT_ARTIFACT_SCHEMA_VERSION = "japan-fiscal-scenario-result/1.0.0"

_jf_result_format_datetime(dt::DateTime) =
    Dates.format(dt, dateformat"yyyy-mm-ddTHH:MM:SS") * "Z"

# ===========================================================================
# JapanFiscalComparisonDiagnostics
# ===========================================================================

"""
    JapanFiscalComparisonDiagnostics

baseline/scenario 比較の診断。`claim_level` が許す診断だけがフィールドとして存在する
（`:direction_only` のセルでは `direction`/`sign_of_delta` 以外は `nothing`）。

## フィールド
- `claim_level::Symbol` / `numeric_semantics::Symbol`
- `variables::Vector{Symbol}`
- `direction::Dict{Symbol,Symbol}` / `sign_of_delta::Dict{Symbol,Symbol}`: `:up`/`:down`/`:none`。
  常に計算する（`:direction_only` でも主張できる最小限）。
- `relative_delta::Union{Dict{Symbol,Vector{Union{Float64,Missing}}},Nothing}`
- `peak` / `trough::Union{Dict{Symbol,NamedTuple},Nothing}`: `(value,period,sign)`。
- `onset_period` / `duration_periods` / `recovery_period::Union{Dict{Symbol,Union{Int,Nothing}},Nothing}`
- `contribution_decomposition::Union{Dict{String,Any},Nothing}`
- `thresholds::ScenarioDiagnosticThresholds`
"""
struct JapanFiscalComparisonDiagnostics
    claim_level::Symbol
    numeric_semantics::Symbol
    variables::Vector{Symbol}
    direction::Dict{Symbol, Symbol}
    sign_of_delta::Dict{Symbol, Symbol}
    relative_delta::Union{Dict{Symbol, Vector{Union{Float64, Missing}}}, Nothing}
    peak::Union{Dict{Symbol, NamedTuple}, Nothing}
    trough::Union{Dict{Symbol, NamedTuple}, Nothing}
    onset_period::Union{Dict{Symbol, Union{Int, Nothing}}, Nothing}
    duration_periods::Union{Dict{Symbol, Union{Int, Nothing}}, Nothing}
    recovery_period::Union{Dict{Symbol, Union{Int, Nothing}}, Nothing}
    contribution_decomposition::Union{Dict{String, Any}, Nothing}
    thresholds::ScenarioDiagnosticThresholds
end

_jf_sign(x::Float64) = x > 0.0 ? :up : (x < 0.0 ? :down : :none)

"""
    _japan_fiscal_diagnostics(adapter_out, coverage; thresholds) -> JapanFiscalComparisonDiagnostics

`claim_level` が許す範囲だけを計算する。`result_shape=:static_point` は常に `claim_level=
:direction_only` のセルにのみ現れるため（#274 の55セルで実際に確認済み）、time_path 診断
（peak/onset/duration/relative_delta）は `result_shape=:time_path` かつ
`claim_level=:direction_and_relative_timing` のときだけ計算する。
"""
function _japan_fiscal_diagnostics(
    adapter_out::JapanFiscalAdapterOutput,
    coverage::JapanFiscalCoverage;
    thresholds::ScenarioDiagnosticThresholds = ScenarioDiagnosticThresholds(),
)
    variables =
        sort(collect(intersect(keys(adapter_out.baseline), keys(adapter_out.scenario))))
    direction = Dict{Symbol, Symbol}()
    sign_of_delta = Dict{Symbol, Symbol}()
    for v in variables
        b = adapter_out.baseline[v]
        s = adapter_out.scenario[v]
        delta = s[end] - b[end]
        direction[v] = _jf_sign(delta)
        sign_of_delta[v] = _jf_sign(delta)
    end

    permits(d) = d in coverage.permitted_diagnostics

    relative_delta = nothing
    peak = nothing
    trough = nothing
    onset_period = nothing
    duration_periods = nothing
    recovery_period = nothing
    contribution = nothing

    if adapter_out.result_shape === :time_path && permits(:peak)
        relative_delta = Dict{Symbol, Vector{Union{Float64, Missing}}}()
        peak = Dict{Symbol, NamedTuple}()
        trough = Dict{Symbol, NamedTuple}()
        onset_period = Dict{Symbol, Union{Int, Nothing}}()
        duration_periods = Dict{Symbol, Union{Int, Nothing}}()
        recovery_period = Dict{Symbol, Union{Int, Nothing}}()
        periods = adapter_out.periods
        last_idx = length(periods)
        for v in variables
            b = adapter_out.baseline[v]
            s = adapter_out.scenario[v]
            diff = s .- b
            rel = Union{Float64, Missing}[
                _scenario_diag_rel(diff[i], b[i], thresholds.rel_denominator_floor) for
                i in eachindex(diff)
            ]
            relative_delta[v] = rel
            peak[v] = _scenario_diag_extremum(diff, periods, last_idx, >)
            trough[v] = _scenario_diag_extremum(diff, periods, last_idx, <)
            breach = _scenario_diag_breach(diff, rel, last_idx, thresholds)
            onset = _scenario_diag_onset(breach, periods, thresholds.onset_persistence)
            onset_period[v] = onset
            recovery = _scenario_diag_recovery(
                breach,
                periods,
                onset,
                thresholds.onset_persistence,
            )
            recovery_period[v] = recovery
            duration_periods[v] =
                (onset === nothing) ? nothing :
                (recovery === nothing ? nothing : recovery - onset)
        end
        if permits(:contribution_decomposition) &&
           haskey(adapter_out.sensitivity, "contribution_decomposition")
            contribution = adapter_out.sensitivity["contribution_decomposition"]
        end
    end

    return JapanFiscalComparisonDiagnostics(
        coverage.claim_level,
        coverage.numeric_semantics,
        variables,
        direction,
        sign_of_delta,
        relative_delta,
        peak,
        trough,
        onset_period,
        duration_periods,
        recovery_period,
        contribution,
        thresholds,
    )
end

function _jf_peak_dict(d::Union{Dict{Symbol, NamedTuple}, Nothing})
    d === nothing && return nothing
    return Dict{String, Any}(
        String(k) =>
            Dict{String, Any}("value" => v.value, "period" => v.period, "sign" => v.sign)
        for (k, v) in d
    )
end

function to_dict(d::JapanFiscalComparisonDiagnostics)
    out = Dict{String, Any}(
        "claim_level" => String(d.claim_level),
        "numeric_semantics" => String(d.numeric_semantics),
        "variables" => String.(d.variables),
        "direction" =>
            Dict{String, Any}(String(k) => String(v) for (k, v) in d.direction),
        "sign_of_delta" =>
            Dict{String, Any}(String(k) => String(v) for (k, v) in d.sign_of_delta),
    )
    if d.relative_delta !== nothing
        # canonical_json_bytes は Missing をサポートしないため null（nothing）へ変換する
        # （`_scenario_diag_rel` は分母がしきい値未満のとき missing を返す。0除算を隠さず、
        # かつ JSON では null として表現する）。
        out["relative_delta"] = Dict{String, Any}(
            String(k) => Any[x === missing ? nothing : x for x in v] for
            (k, v) in d.relative_delta
        )
        out["peak"] = _jf_peak_dict(d.peak)
        out["trough"] = _jf_peak_dict(d.trough)
        out["onset_period"] = Dict{String, Any}(String(k) => v for (k, v) in d.onset_period)
        out["duration_periods"] =
            Dict{String, Any}(String(k) => v for (k, v) in d.duration_periods)
        out["recovery_period"] =
            Dict{String, Any}(String(k) => v for (k, v) in d.recovery_period)
    end
    d.contribution_decomposition === nothing ||
        (out["contribution_decomposition"] = d.contribution_decomposition)
    return out
end

# ===========================================================================
# JapanFiscalScenarioRejection
# ===========================================================================

"""
    JapanFiscalScenarioRejection

`adoption=:not_adopted` のセル（not_representable 40件 + partial-but-not_adopted 1件）に対する
`japan_fiscal_run` の機械可読な戻り値。モデルを実行しない。
"""
struct JapanFiscalScenarioRejection
    schema_version::String
    family::Symbol
    model::Symbol
    representability::Symbol
    adoption::Symbol
    reason::String
    status::Symbol
    doc_ref::String
end

function to_dict(r::JapanFiscalScenarioRejection)
    return Dict{String, Any}(
        "schema_version" => r.schema_version,
        "family" => String(r.family),
        "model" => String(r.model),
        "representability" => String(r.representability),
        "adoption" => String(r.adoption),
        "reason" => r.reason,
        "status" => String(r.status),
        "doc_ref" => r.doc_ref,
    )
end
to_json(r::JapanFiscalScenarioRejection) = JSON3.write(to_dict(r))

# ===========================================================================
# JapanFiscalScenarioResult
# ===========================================================================

"""
    JapanFiscalScenarioResult

#276 の result artifact 本体。フィールドは Issue #276 の artifact contract 項目に 1:1 対応する。

## フィールド（主要なもののみ抜粋。全体は `to_dict` を参照）
- 契約 version chain: `schema_version`・`adapter_contract_version`・
  `capability_contract_version`・`claim_contract_version`・`scenario_schema_version`
- scenario identity: `scenario_id`・`scenario_content_hash`・`assumption_set_hash`
- observed context identity: `fre_context_identity`（nullable）
- model identity: `model_name`・`parameter_identity_hash`
- `horizon`・`periods`・`result_shape`
- traceability: `applied_inputs`
- observed/assumed/model_implied（H-10）: `observed`・`assumed`・`model_implied`
- `diagnostics`・`coverage`（H-06）・`funding_cost_legs`（H-11、jgb_funding_cost のみ）・
  `sensitivity`
- `execution_status`・`termination_reason`・`warnings`
- `generated_at`（volatile・hash 対象外）・`result_content_hash`（`generated_at` と自身を除いた
  正準 JSON の SHA-256）
"""
struct JapanFiscalScenarioResult
    schema_version::String
    adapter_contract_version::String
    capability_contract_version::String
    claim_contract_version::String
    scenario_schema_version::String
    family::Symbol
    model::Symbol
    scenario_id::String
    scenario_content_hash::String
    assumption_set_hash::String
    fre_context_identity::Union{String, Nothing}
    model_name::String
    parameter_identity_hash::String
    horizon::Int
    periods::Vector{Int}
    result_shape::Symbol
    applied_inputs::Vector{JapanFiscalAppliedInput}
    observed::Union{Dict{String, Any}, Nothing}
    assumed::Vector{Dict{String, Any}}
    model_implied::Dict{String, Any}
    diagnostics::JapanFiscalComparisonDiagnostics
    coverage::JapanFiscalCoverage
    funding_cost_legs::Union{Dict{String, Any}, Nothing}
    sensitivity::Dict{String, Any}
    execution_status::Symbol
    termination_reason::Union{String, Nothing}
    warnings::Vector{String}
    generated_at::String
    result_content_hash::String
end

"F5（jgb_funding_cost）専用: sovereign leg / private pass-through leg を別フィールドで保持する
（H-11）。他 family では `nothing`。"
function _jf_funding_cost_legs(mapping::JapanFiscalModelMapping)
    mapping.family === :jgb_funding_cost || return nothing
    return Dict{String, Any}(
        "private_pass_through" => Dict{String, Any}(
            "status" => "modeled",
            "target" => String(
                something(
                    (r = _jf_input_row(mapping, :long_rate_funding_condition)) === nothing ? nothing : r.variable,
                    :none,
                ),
            ),
            "note" => "民間の実効借入コストへのpass-through（ADR 0019）。政府の調達コストではない（G-14）。",
        ),
        "sovereign" => Dict{String, Any}(
            "status" => "unsupported",
            "gap_ids" => ["G-01", "G-14"],
            "note" => "利付き政府債務ストック・政府の調達コスト・利払費を持つモデルが無い（G-01）。",
        ),
    )
end

function _jf_tag_series(series::Dict{Symbol, Vector{Float64}}, numeric_semantics::Symbol)
    return Dict{String, Any}(
        "numeric_semantics" => String(numeric_semantics),
        "series" => Dict{String, Any}(String(k) => v for (k, v) in series),
    )
end

"""
    _japan_fiscal_result_content_hash(d) -> String

`to_dict(::JapanFiscalScenarioResult)` と同じ形の `d` から、volatile な `generated_at` と
自己参照の `result_content_hash` を除いた identity の `"sha256:" * hex` を計算する
（`compute_artifact_id`、artifacts/real_rate_model_artifact.jl と同じ非対称除外の idiom）。
`japan_fiscal_run`（hash 計算時）と `japan_fiscal_scenario_result_from_dict`（round-trip 検証時）
の両方がこの1関数だけを使うことで、除外対象フィールドの重複記述を避ける。
"""
function _japan_fiscal_result_content_hash(d::AbstractDict)
    identity = Dict{String, Any}(
        k => v for (k, v) in d if k != "generated_at" && k != "result_content_hash"
    )
    return "sha256:" * sha256_hex_of_canonical(identity)
end

"""
    japan_fiscal_run(model, scenario; horizon=nothing) -> Union{JapanFiscalScenarioResult,JapanFiscalScenarioRejection}

Japan Fiscal Scenario Lab の scenario runner（Issue #276 の公開 entrypoint）。
`family` は `scenario.family` から取るため、family/scenario の不一致は構成上発生しない。

`japan_fiscal_model_mapping(scenario.family, model).adoption === :not_adopted` のときは
モデルを実行せず `JapanFiscalScenarioRejection` を返す。それ以外は
`JAPAN_FISCAL_MODEL_ADAPTERS[model]` を呼び、`japan_fiscal_validate_claims`（H-07）を経てから
`JapanFiscalScenarioResult` を組み立てる。
"""
function japan_fiscal_run(
    model::Symbol,
    scenario::JapanFiscalScenario;
    horizon::Union{Int, Nothing} = nothing,
)
    mapping = japan_fiscal_model_mapping(scenario.family, model)

    if mapping.adoption === :not_adopted
        return JapanFiscalScenarioRejection(
            JAPAN_FISCAL_RESULT_ARTIFACT_SCHEMA_VERSION,
            mapping.family,
            mapping.model,
            mapping.representability,
            mapping.adoption,
            mapping.reason,
            :not_executed,
            mapping.doc_ref,
        )
    end

    coverage = japan_fiscal_coverage(scenario.family, model)

    violations = japan_fiscal_validate_claims(
        scenario.family,
        model;
        diagnostics = coverage.permitted_diagnostics,
        numeric_semantics = coverage.numeric_semantics,
        disclosed_unsupported_concepts = coverage.unsupported_concepts,
        disclosed_unsupported_outputs = coverage.unsupported_outputs,
    )
    isempty(violations) || throw(
        ArgumentError(
            "japan_fiscal_run: japan_fiscal_validate_claims が違反を返しました（family=" *
            "$(scenario.family), model=$model）: $(join([v.detail for v in violations], "; "))",
        ),
    )

    h = horizon === nothing ? JAPAN_FISCAL_DEFAULT_HORIZON : horizon
    h >= 1 || throw(
        ArgumentError("japan_fiscal_run: horizon は1以上でなければなりません（実値: $h）"),
    )

    adapter = JAPAN_FISCAL_MODEL_ADAPTERS[model]
    out = adapter(mapping, scenario; horizon = h)

    diagnostics = _japan_fiscal_diagnostics(out, coverage)

    observed = scenario.fre_context === nothing ? nothing : to_dict(scenario.fre_context)
    assumed = [to_dict(a) for a in scenario.assumptions]
    model_implied = Dict{String, Any}(
        "baseline" => _jf_tag_series(out.baseline, coverage.numeric_semantics),
        "scenario" => _jf_tag_series(out.scenario, coverage.numeric_semantics),
    )

    # parameters(m) はモデルによって Greek 文字のフィールド名（例: NK の φ_x・Keen の κ2）を
    # 持つため、canonical JSON の ASCII-only キー制約（RFC 8785 実装、artifacts/json_canonical.jl）
    # に抵触する。フィールド名ではなく固定順序の値配列としてハッシュする（型ごとに
    # `parameters(m)` の NamedTuple フィールド順は一定であり、model と組にすれば曖昧さはない）。
    parameter_identity_hash = sha256_hex_of_canonical(
        Dict{String, Any}(
            "adapter_contract_version" => JAPAN_FISCAL_ADAPTER_CONTRACT_VERSION,
            "model" => String(model),
            "parameters" => Float64[Float64(v) for v in values(out.parameter_identity)],
        ),
    )

    generated_at = _jf_result_format_datetime(now(UTC))

    base = Dict{String, Any}(
        "schema_version" => JAPAN_FISCAL_RESULT_ARTIFACT_SCHEMA_VERSION,
        "adapter_contract_version" => JAPAN_FISCAL_ADAPTER_CONTRACT_VERSION,
        "capability_contract_version" => JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION,
        "claim_contract_version" => JAPAN_FISCAL_CLAIM_CONTRACT_VERSION,
        "scenario_schema_version" => JAPAN_FISCAL_SCENARIO_SCHEMA_VERSION,
        "family" => String(scenario.family),
        "model" => String(model),
        "scenario_id" => scenario.scenario_id,
        "scenario_content_hash" => japan_fiscal_scenario_content_hash(scenario),
        "assumption_set_hash" => japan_fiscal_assumption_set_hash(scenario),
        "fre_context_identity" =>
            scenario.fre_context === nothing ? nothing :
            japan_fiscal_fre_context_identity(scenario.fre_context),
        "model_name" => String(model),
        "parameter_identity_hash" => parameter_identity_hash,
        "horizon" => h,
        "periods" => out.periods,
        "result_shape" => String(out.result_shape),
        "applied_inputs" => [to_dict(a) for a in out.applied_inputs],
        "observed" => observed,
        "assumed" => assumed,
        "model_implied" => model_implied,
        "diagnostics" => to_dict(diagnostics),
        "coverage" => to_dict(coverage),
        "funding_cost_legs" => _jf_funding_cost_legs(mapping),
        "sensitivity" => out.sensitivity,
        "execution_status" => "ok",
        "termination_reason" => nothing,
        "warnings" => out.warnings,
        "generated_at" => generated_at,
    )
    result_content_hash = _japan_fiscal_result_content_hash(base)

    return JapanFiscalScenarioResult(
        JAPAN_FISCAL_RESULT_ARTIFACT_SCHEMA_VERSION,
        JAPAN_FISCAL_ADAPTER_CONTRACT_VERSION,
        JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION,
        JAPAN_FISCAL_CLAIM_CONTRACT_VERSION,
        JAPAN_FISCAL_SCENARIO_SCHEMA_VERSION,
        scenario.family,
        model,
        scenario.scenario_id,
        base["scenario_content_hash"],
        base["assumption_set_hash"],
        base["fre_context_identity"],
        String(model),
        parameter_identity_hash,
        h,
        out.periods,
        out.result_shape,
        out.applied_inputs,
        observed,
        assumed,
        model_implied,
        diagnostics,
        coverage,
        base["funding_cost_legs"],
        out.sensitivity,
        :ok,
        nothing,
        out.warnings,
        generated_at,
        result_content_hash,
    )
end

function to_dict(r::JapanFiscalScenarioResult)
    return Dict{String, Any}(
        "schema_version" => r.schema_version,
        "adapter_contract_version" => r.adapter_contract_version,
        "capability_contract_version" => r.capability_contract_version,
        "claim_contract_version" => r.claim_contract_version,
        "scenario_schema_version" => r.scenario_schema_version,
        "family" => String(r.family),
        "model" => String(r.model),
        "scenario_id" => r.scenario_id,
        "scenario_content_hash" => r.scenario_content_hash,
        "assumption_set_hash" => r.assumption_set_hash,
        "fre_context_identity" => r.fre_context_identity,
        "model_name" => r.model_name,
        "parameter_identity_hash" => r.parameter_identity_hash,
        "horizon" => r.horizon,
        "periods" => r.periods,
        "result_shape" => String(r.result_shape),
        "applied_inputs" => [to_dict(a) for a in r.applied_inputs],
        "observed" => r.observed,
        "assumed" => r.assumed,
        "model_implied" => r.model_implied,
        "diagnostics" => to_dict(r.diagnostics),
        "coverage" => to_dict(r.coverage),
        "funding_cost_legs" => r.funding_cost_legs,
        "sensitivity" => r.sensitivity,
        "execution_status" => String(r.execution_status),
        "termination_reason" => r.termination_reason,
        "warnings" => r.warnings,
        "generated_at" => r.generated_at,
        "result_content_hash" => r.result_content_hash,
    )
end
to_json(r::JapanFiscalScenarioResult) = JSON3.write(to_dict(r))

"""
    japan_fiscal_result_artifact_contract() -> Dict{String,Any}

Market Analyzer 向けの machine-readable 契約 export（Julia 型なしで artifact の形を
把握できる）。`japan_fiscal_capability_matrix()`（#274）・`japan_fiscal_downstream_contract()`
（#285）・`japan_fiscal_scenario_schema_contract()`（#275）と同じ 1 Dict export の型。
"""
function japan_fiscal_result_artifact_contract()
    return Dict{String, Any}(
        "schema_version" => JAPAN_FISCAL_RESULT_ARTIFACT_SCHEMA_VERSION,
        "adapter_contract_version" => JAPAN_FISCAL_ADAPTER_CONTRACT_VERSION,
        "capability_contract_version" => JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION,
        "claim_contract_version" => JAPAN_FISCAL_CLAIM_CONTRACT_VERSION,
        "scenario_schema_version" => JAPAN_FISCAL_SCENARIO_SCHEMA_VERSION,
        "adopted_models" => sort(collect(String.(keys(JAPAN_FISCAL_MODEL_ADAPTERS)))),
        "result_shapes" => ["time_path", "static_point"],
        "rejection_status_values" => ["not_executed"],
        "fields" => Dict{String, Any}(
            "scenario_identity" =>
                ["scenario_id", "scenario_content_hash", "assumption_set_hash"],
            "observed_context_identity" => ["fre_context_identity"],
            "model_identity" => ["model_name", "parameter_identity_hash"],
            "provenance" => [
                "schema_version",
                "adapter_contract_version",
                "capability_contract_version",
                "claim_contract_version",
                "scenario_schema_version",
            ],
            "traceability" => ["applied_inputs"],
            "classification" => ["observed", "assumed", "model_implied"],
            "coverage" => ["coverage", "funding_cost_legs"],
            "diagnostics" => ["diagnostics", "sensitivity"],
            "identity_hash" => ["result_content_hash"],
        ),
        "doc_ref" => "docs/architecture/japan_fiscal_scenario_result_contract.md",
    )
end

# ===========================================================================
# serialization: fail-closed round trip
# ===========================================================================

"""
    japan_fiscal_scenario_result_from_dict(d) -> JapanFiscalScenarioResult

`to_dict(::JapanFiscalScenarioResult)` の round trip。未知/欠落キーを `ArgumentError` で拒否し
（fail closed）、`result_content_hash` を再計算して一致を検査する。
"""
function japan_fiscal_scenario_result_from_dict(d::AbstractDict)::JapanFiscalScenarioResult
    required = (
        "schema_version",
        "adapter_contract_version",
        "capability_contract_version",
        "claim_contract_version",
        "scenario_schema_version",
        "family",
        "model",
        "scenario_id",
        "scenario_content_hash",
        "assumption_set_hash",
        "fre_context_identity",
        "model_name",
        "parameter_identity_hash",
        "horizon",
        "periods",
        "result_shape",
        "applied_inputs",
        "observed",
        "assumed",
        "model_implied",
        "diagnostics",
        "coverage",
        "funding_cost_legs",
        "sensitivity",
        "execution_status",
        "termination_reason",
        "warnings",
        "generated_at",
        "result_content_hash",
    )
    _jf_check_keys("JapanFiscalScenarioResult", d, required)

    expected_hash = _japan_fiscal_result_content_hash(d)
    expected_hash == d["result_content_hash"] || throw(
        ArgumentError(
            "japan_fiscal_scenario_result_from_dict: result_content_hash が再計算値と一致しません" *
            "（改変または非正準の入力）。",
        ),
    )

    applied_inputs = JapanFiscalAppliedInput[
        JapanFiscalAppliedInput(;
            assumption_id = _jf_as_string(
                ai["assumption_id"],
                "applied_inputs[].assumption_id",
            ),
            concept = _jf_as_symbol(ai["concept"], "applied_inputs[].concept"),
            model = _jf_as_symbol(ai["model"], "applied_inputs[].model"),
            target = _jf_as_symbol(ai["target"], "applied_inputs[].target"),
            input_kind = _jf_as_symbol(ai["input_kind"], "applied_inputs[].input_kind"),
            unit = _jf_as_string(ai["unit"], "applied_inputs[].unit"),
            magnitude_model_units = _jf_as_float(
                ai["magnitude_model_units"],
                "applied_inputs[].magnitude_model_units",
            ),
            conversion = _jf_as_string(ai["conversion"], "applied_inputs[].conversion"),
            notes = _jf_as_string(ai["notes"], "applied_inputs[].notes"),
        ) for ai in d["applied_inputs"]
    ]

    family = _jf_as_symbol(d["family"], "family")
    model = _jf_as_symbol(d["model"], "model")
    coverage = japan_fiscal_coverage(family, model)

    diag_d = d["diagnostics"]
    thresholds = ScenarioDiagnosticThresholds()
    has_timing = haskey(diag_d, "peak")
    variables = Symbol.(diag_d["variables"])
    diagnostics = JapanFiscalComparisonDiagnostics(
        _jf_as_symbol(diag_d["claim_level"], "diagnostics.claim_level"),
        _jf_as_symbol(diag_d["numeric_semantics"], "diagnostics.numeric_semantics"),
        variables,
        Dict{Symbol, Symbol}(Symbol(k) => Symbol(v) for (k, v) in diag_d["direction"]),
        Dict{Symbol, Symbol}(Symbol(k) => Symbol(v) for (k, v) in diag_d["sign_of_delta"]),
        has_timing ?
        Dict{Symbol, Vector{Union{Float64, Missing}}}(
            Symbol(k) => Union{Float64, Missing}[
                x === nothing ? missing : Float64(x) for x in v
            ] for (k, v) in diag_d["relative_delta"]
        ) : nothing,
        has_timing ?
        Dict{Symbol, NamedTuple}(
            Symbol(k) => (
                value = Float64(v["value"]),
                period = v["period"],
                sign = Int(v["sign"]),
            ) for (k, v) in diag_d["peak"]
        ) : nothing,
        has_timing ?
        Dict{Symbol, NamedTuple}(
            Symbol(k) => (
                value = Float64(v["value"]),
                period = v["period"],
                sign = Int(v["sign"]),
            ) for (k, v) in diag_d["trough"]
        ) : nothing,
        has_timing ?
        Dict{Symbol, Union{Int, Nothing}}(
            Symbol(k) => v for (k, v) in diag_d["onset_period"]
        ) : nothing,
        has_timing ?
        Dict{Symbol, Union{Int, Nothing}}(
            Symbol(k) => v for (k, v) in diag_d["duration_periods"]
        ) : nothing,
        has_timing ?
        Dict{Symbol, Union{Int, Nothing}}(
            Symbol(k) => v for (k, v) in diag_d["recovery_period"]
        ) : nothing,
        get(diag_d, "contribution_decomposition", nothing),
        thresholds,
    )

    return JapanFiscalScenarioResult(
        _jf_as_string(d["schema_version"], "schema_version"),
        _jf_as_string(d["adapter_contract_version"], "adapter_contract_version"),
        _jf_as_string(d["capability_contract_version"], "capability_contract_version"),
        _jf_as_string(d["claim_contract_version"], "claim_contract_version"),
        _jf_as_string(d["scenario_schema_version"], "scenario_schema_version"),
        family,
        model,
        _jf_as_string(d["scenario_id"], "scenario_id"),
        _jf_as_string(d["scenario_content_hash"], "scenario_content_hash"),
        _jf_as_string(d["assumption_set_hash"], "assumption_set_hash"),
        _jf_as_optional(_jf_as_string, d["fre_context_identity"], "fre_context_identity"),
        _jf_as_string(d["model_name"], "model_name"),
        _jf_as_string(d["parameter_identity_hash"], "parameter_identity_hash"),
        Int(d["horizon"]),
        Int.(d["periods"]),
        _jf_as_symbol(d["result_shape"], "result_shape"),
        applied_inputs,
        d["observed"],
        d["assumed"],
        d["model_implied"],
        diagnostics,
        coverage,
        d["funding_cost_legs"],
        d["sensitivity"],
        _jf_as_symbol(d["execution_status"], "execution_status"),
        _jf_as_optional(_jf_as_string, d["termination_reason"], "termination_reason"),
        Vector{String}(d["warnings"]),
        _jf_as_string(d["generated_at"], "generated_at"),
        _jf_as_string(d["result_content_hash"], "result_content_hash"),
    )
end

# ===========================================================================
# atomic save
# ===========================================================================

function _jf_result_slugify(s::AbstractString)::String
    return replace(s, r"[^A-Za-z0-9._-]" => "-")
end

function _jf_result_file_path(
    base_dir::AbstractString,
    r::JapanFiscalScenarioResult,
)::String
    digest = replace(r.result_content_hash, r"^sha256:" => "")
    fname = string(_jf_result_slugify(r.scenario_id), "__", digest, ".json")
    return joinpath(
        base_dir,
        "artifacts",
        "japan_fiscal_scenario_result",
        r.schema_version,
        String(r.family),
        String(r.model),
        fname,
    )
end

"""
    save_japan_fiscal_scenario_result(r, base_dir) -> String

`r` を atomic に `base_dir` 配下へ保存する（`.tmp` へ書いて `fsync` した後 `mv` で確定させる。
同名ファイルへは上書きしない）。`save_real_rate_model_artifact`（ADR 0008）と同じ idiom。
書き込む内容は常に正準 JSON バイト列。`base_dir` 自体は identity（hash 対象）に含まれない
（no secrets/local paths in identity）。生成されたファイルパスを返す。
"""
function save_japan_fiscal_scenario_result(
    r::JapanFiscalScenarioResult,
    base_dir::AbstractString,
)::String
    path = _jf_result_file_path(base_dir, r)
    isfile(path) && throw(
        ArgumentError(
            "japan fiscal scenario result ファイルが既に存在します（上書きしません）: $path",
        ),
    )
    mkpath(dirname(path))
    tmp_path = path * ".tmp"
    bytes = canonical_json_bytes(to_dict(r))
    try
        open(tmp_path, "w") do io
            write(io, bytes)
            flush(io)
            @static if Sys.isunix()
                ccall(:fsync, Cint, (Cint,), fd(io))
            end
        end
        mv(tmp_path, path; force = false)
    catch
        isfile(tmp_path) && rm(tmp_path; force = true)
        rethrow()
    end
    return path
end
