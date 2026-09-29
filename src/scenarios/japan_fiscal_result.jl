# japan_fiscal_result.jl: Japan Fiscal Scenario Lab の scenario runner・result artifact
# （Issue #276・#277）。adapter 層（scenarios/adapters/japan_fiscal_model_adapters.jl）の出力を、
# #285 claim-level 契約（H-06..H-12）を満たす versioned な machine-readable artifact へ
# 組み立てる。Market Analyzer はこの artifact のみを consume し、Julia 内部型を import しない
# （#274 §8）。
#
# 設計方針（ADR 0023・ADR 0025）:
#   - 実行できないセル・入力は、モデルを実行せず `JapanFiscalScenarioRejection` を返す
#     （機械可読な拒否。`rejection_code` 3 種）:
#       * `:not_adopted` … #274 が `adoption=:not_adopted` と判定したセル（not_representable
#         40件 + partial-but-not_adopted 1件）
#       * `:missing_required_assumption` … family の必須概念のうちモデルが受理する概念に
#         explicit assumption が無い。未指定を 0（変化なし）へ丸めて実行しない（#277）
#       * `:conversion_not_implemented` … mapping 上は受理されるが adapter が変換を実装して
#         いない概念（`:primary_balance`）に explicit assumption がある。黙って無視しない（#277）
#   - 実行前に `japan_fiscal_validate_claims`（#285）を呼び、違反があれば artifact を生成しない
#     （H-07）。
#   - diagnostics は `claim_level` が許す範囲だけを計算する。peak/onset/duration/relative_delta
#     は `:direction_and_relative_timing` のセルにのみ存在し、`:direction_only` のセルには
#     フィールド自体が現れない（null で隠さない・そもそも計算しない）。
#   - `japan_fiscal_coverage(family, model)` を丸ごと artifact へ埋め込む（H-06）。
#   - family の全概念について「explicit / 未指定」と「モデル入力としての扱い」を
#     `assumption_disposition` として artifact へ開示する（#277。未指定を 0 と区別する）。
#   - baseline/scenario の model・params・initial-state・horizon 一致は、両者を常に同一の
#     baseline パラメータから adapter 内部で導出することで構成上保証する（ランタイム検証では
#     なく構成上の不可能性）。
#   - hash・atomic write は artifacts/json_canonical.jl・real_rate_model_artifact_export.jl と
#     同じ idiom（RFC 8785 正準化・`generated_at` 除外・tmp+fsync+atomic rename）を流用する。
#     artifact は入力の並び順（assumption の順序・FRE の dominant_drivers の順序・Dict の挿入順）に
#     依存しない（#277）。
#   - decode は fail closed（未知/欠落キー・schema/契約 version 不一致・content hash 改変・
#     #285 registry と一致しない coverage・claim_level を超える診断を拒否する。#277）。
#
# 依存: scenarios/adapters/japan_fiscal_model_adapters.jl（JAPAN_FISCAL_MODEL_ADAPTERS 等）・
# scenarios/japan_fiscal_capability.jl・scenarios/japan_fiscal_claim_contract.jl・
# scenarios/japan_fiscal_scenario_schema.jl・analysis/scenario_diagnostics.jl（診断プリミティブ）・
# artifacts/json_canonical.jl（canonical_json_bytes・sha256_hex_of_canonical）。
#
# 設計契約:
#   docs/architecture/japan_fiscal_scenario_result_contract.md
#   docs/architecture/japan_fiscal_scenario_handoff.md
#   docs/adr/0023-japan-fiscal-scenario-result-artifact-contract.md
#   docs/adr/0025-japan-fiscal-scenario-handoff-contract.md

"""
result artifact の契約 version。Issue #277 で `2.0.0` に上げた（`artifact_kind`・
`assumption_disposition`・構造化された拒否 artifact の追加。1.0.0 は consumer fixture として
公開していない。変更点は docs/architecture/japan_fiscal_scenario_handoff.md §4）。
"""
const JAPAN_FISCAL_RESULT_ARTIFACT_SCHEMA_VERSION = "japan-fiscal-scenario-result/2.0.0"

"result / rejection artifact の JSON Schema（DME 所有。リポジトリルートからの相対パス）。"
const JAPAN_FISCAL_RESULT_ARTIFACT_JSON_SCHEMA = "schemas/japan-fiscal-scenario-result-v2.schema.json"

"artifact の種類（`artifact_kind`。consumer が discriminated union として decode する判別子）。"
const JAPAN_FISCAL_ARTIFACT_KINDS = (:result, :rejection)

"""
`JapanFiscalScenarioRejection.rejection_code` の語彙（Issue #277）。

- `:not_adopted` … #274 が `adoption=:not_adopted` と判定したセル（not_representable 40件 +
  partial-but-not_adopted 1件）
- `:missing_required_assumption` … family の必須概念のうちモデルが受理する概念に explicit
  assumption が無い。未指定を 0（変化なし）へ丸めて実行しない
- `:conversion_not_implemented` … mapping 上は受理される（`:requires_structural_conversion`）が
  adapter が変換を実装していない概念に explicit assumption がある。黙って無視しない
"""
const JAPAN_FISCAL_REJECTION_CODES =
    (:not_adopted, :missing_required_assumption, :conversion_not_implemented)

"assumption の有無（`JapanFiscalAssumptionDisposition.assumption_state`）。"
const JAPAN_FISCAL_ASSUMPTION_STATES = (:explicit, :not_specified)

"""
assumption 概念のモデル入力としての扱い（`JapanFiscalAssumptionDisposition.model_input`）。

- `:applied` … explicit assumption を単位換算してモデル入力へ適用した（`applied_inputs` に 1 件ある）
- `:held_at_baseline` … assumption が未指定のため、対応するモデル入力を baseline 値のまま保持した。
  「0 の assumption を置いた」ことではない
- `:not_accepted` … モデルがこの概念を受け取れない（#274。代理へ寄せない）
- `:conversion_not_implemented` … mapping 上は受理されるが adapter が変換を実装していない
"""
const JAPAN_FISCAL_MODEL_INPUT_TREATMENTS =
    (:applied, :held_at_baseline, :not_accepted, :conversion_not_implemented)

_jf_result_format_datetime(dt::DateTime) =
    Dates.format(dt, dateformat"yyyy-mm-ddTHH:MM:SS") * "Z"

# ===========================================================================
# JapanFiscalAssumptionDisposition（Issue #277）
# ===========================================================================

"""
    JapanFiscalAssumptionDisposition

family の assumption 概念 1 つについて、scenario が explicit assumption を置いたか
（`assumption_state`）と、モデル入力としてどう扱われたか（`model_input`）の組。
result artifact は family の `required_concepts ∪ optional_concepts` の全概念について
この record を持つ（未指定を 0 と区別し、受け取れない assumption を黙って捨てない）。

## 許される組
| `assumption_state` | `model_input` | 意味 |
|---|---|---|
| `:explicit` | `:applied` | assumption を適用した |
| `:explicit` | `:not_accepted` | assumption はあるがモデルが受け取れない（開示のみ・代理へ寄せない） |
| `:not_specified` | `:held_at_baseline` | assumption が無く、モデル入力を baseline 値のまま保持した（任意概念のみ） |
| `:not_specified` | `:not_accepted` | assumption が無く、モデルも受け取れない |
| `:not_specified` | `:conversion_not_implemented` | assumption が無く、変換も未実装（任意概念のみ） |

`(:explicit, :held_at_baseline)`（explicit assumption の黙殺）と `(:not_specified, :applied)`
（未指定の 0 化）はコンストラクタが拒否する。`(:explicit, :conversion_not_implemented)` と
「必須概念の `(:not_specified, :held_at_baseline)`」は record としては構築できるが、
`japan_fiscal_run` がモデルを実行せず拒否するため result artifact には現れない（decode が検査する）。

## フィールド
- `concept::Symbol` : `JAPAN_FISCAL_ASSUMPTION_CONCEPTS`
- `requirement::Symbol` : `:required` / `:optional`（family spec の区分）
- `assumption_state::Symbol` : `JAPAN_FISCAL_ASSUMPTION_STATES`
- `assumption_id::Union{String,Nothing}` : `:explicit` のときのみ非 `nothing`
- `model_input::Symbol` : `JAPAN_FISCAL_MODEL_INPUT_TREATMENTS`
- `target::Union{Symbol,Nothing}` : mapping 上の適用先変数（`:not_accepted` のときのみ `nothing`）
"""
struct JapanFiscalAssumptionDisposition
    concept::Symbol
    requirement::Symbol
    assumption_state::Symbol
    assumption_id::Union{String, Nothing}
    model_input::Symbol
    target::Union{Symbol, Nothing}

    function JapanFiscalAssumptionDisposition(;
        concept::Symbol,
        requirement::Symbol,
        assumption_state::Symbol,
        model_input::Symbol,
        assumption_id::Union{AbstractString, Nothing} = nothing,
        target::Union{Symbol, Nothing} = nothing,
    )
        _jf_check(concept, JAPAN_FISCAL_ASSUMPTION_CONCEPTS, "concept")
        _jf_check(requirement, (:required, :optional), "requirement")
        _jf_check(assumption_state, JAPAN_FISCAL_ASSUMPTION_STATES, "assumption_state")
        _jf_check(model_input, JAPAN_FISCAL_MODEL_INPUT_TREATMENTS, "model_input")
        (assumption_state === :explicit) == (assumption_id !== nothing) || throw(
            ArgumentError(
                "JapanFiscalAssumptionDisposition(concept=$(concept)): assumption_id は " *
                "assumption_state=:explicit のときのみ指定する（実値: state=$(assumption_state), id=$(repr(assumption_id))）",
            ),
        )
        assumption_state === :explicit &&
            model_input === :held_at_baseline &&
            throw(
                ArgumentError(
                    "JapanFiscalAssumptionDisposition(concept=$(concept)): explicit assumption を " *
                    "baseline 保持として扱えません（explicit assumption の黙殺）",
                ),
            )
        assumption_state === :not_specified &&
            model_input === :applied &&
            throw(
                ArgumentError(
                    "JapanFiscalAssumptionDisposition(concept=$(concept)): 未指定の概念を適用済みと" *
                    "扱えません（未指定を 0 へ丸めない）",
                ),
            )
        (model_input === :not_accepted) == (target === nothing) || throw(
            ArgumentError(
                "JapanFiscalAssumptionDisposition(concept=$(concept)): target は model_input が " *
                ":not_accepted のときのみ nothing とする（実値: model_input=$(model_input), target=$(repr(target))）",
            ),
        )
        return new(
            concept,
            requirement,
            assumption_state,
            assumption_id === nothing ? nothing : String(assumption_id),
            model_input,
            target,
        )
    end
end

to_dict(d::JapanFiscalAssumptionDisposition) = Dict{String, Any}(
    "concept" => String(d.concept),
    "requirement" => String(d.requirement),
    "assumption_state" => String(d.assumption_state),
    "assumption_id" => d.assumption_id,
    "model_input" => String(d.model_input),
    "target" => d.target === nothing ? nothing : String(d.target),
)

function _jf_disposition_from_dict(d::AbstractDict)::JapanFiscalAssumptionDisposition
    _jf_check_keys(
        "JapanFiscalAssumptionDisposition",
        d,
        (
            "concept",
            "requirement",
            "assumption_state",
            "assumption_id",
            "model_input",
            "target",
        ),
    )
    return JapanFiscalAssumptionDisposition(;
        concept = _jf_as_symbol(d["concept"], "assumption_disposition[].concept"),
        requirement = _jf_as_symbol(
            d["requirement"],
            "assumption_disposition[].requirement",
        ),
        assumption_state = _jf_as_symbol(
            d["assumption_state"],
            "assumption_disposition[].assumption_state",
        ),
        assumption_id = _jf_as_optional(
            _jf_as_string,
            d["assumption_id"],
            "assumption_disposition[].assumption_id",
        ),
        model_input = _jf_as_symbol(
            d["model_input"],
            "assumption_disposition[].model_input",
        ),
        target = _jf_as_optional(
            _jf_as_symbol,
            d["target"],
            "assumption_disposition[].target",
        ),
    )
end

"""
    japan_fiscal_assumption_disposition(scenario, model) -> Vector{JapanFiscalAssumptionDisposition}

`scenario.family` の `required_concepts`（先）・`optional_concepts`（後）の宣言順に、各概念の
disposition を #274 の mapping・`JAPAN_FISCAL_ADAPTER_IMPLEMENTED_CONCEPTS` から導出する
（モデルは実行しない）。`japan_fiscal_run` はこの結果で実行可否を判定し、result artifact へ
そのまま埋め込む。
"""
function japan_fiscal_assumption_disposition(scenario::JapanFiscalScenario, model::Symbol)
    mapping = japan_fiscal_model_mapping(scenario.family, model)
    spec = japan_fiscal_family_spec(scenario.family)
    implemented = get(JAPAN_FISCAL_ADAPTER_IMPLEMENTED_CONCEPTS, model, Symbol[])
    out = JapanFiscalAssumptionDisposition[]
    for (requirement, concepts) in
        ((:required, spec.required_concepts), (:optional, spec.optional_concepts))
        for c in concepts
            a = _jf_assumption_for(scenario, c)
            row = _jf_input_row(mapping, c)
            accepted = row !== nothing && row.input_kind !== :not_accepted
            model_input =
                !accepted ? :not_accepted :
                !(c in implemented) ? :conversion_not_implemented :
                a === nothing ? :held_at_baseline : :applied
            push!(
                out,
                JapanFiscalAssumptionDisposition(;
                    concept = c,
                    requirement = requirement,
                    assumption_state = a === nothing ? :not_specified : :explicit,
                    assumption_id = a === nothing ? nothing : a.assumption_id,
                    model_input = model_input,
                    target = accepted ? row.variable : nothing,
                ),
            )
        end
    end
    return out
end

"result artifact に現れてはならない disposition（実行前に拒否されるべき組）を検出する。"
function _jf_check_result_dispositions(
    label::AbstractString,
    dispositions::Vector{JapanFiscalAssumptionDisposition},
    applied_concepts,
)
    for d in dispositions
        d.requirement === :required &&
            d.assumption_state === :not_specified &&
            d.model_input !== :not_accepted &&
            throw(
                ArgumentError(
                    "$(label): 必須概念 $(repr(d.concept)) が未指定のまま実行結果として扱われています" *
                    "（未指定を 0 へ丸めない。rejection_code=:missing_required_assumption であるべき）",
                ),
            )
        d.assumption_state === :explicit &&
            d.model_input === :conversion_not_implemented &&
            throw(
                ArgumentError(
                    "$(label): explicit assumption $(repr(d.concept)) が変換未実装のまま実行結果として" *
                    "扱われています（rejection_code=:conversion_not_implemented であるべき）",
                ),
            )
    end
    expected = Set(d.concept for d in dispositions if d.model_input === :applied)
    Set(applied_concepts) == expected || throw(
        ArgumentError(
            "$(label): applied_inputs の概念 $(sort(collect(Set(applied_concepts)))) が " *
            "assumption_disposition の :applied $(sort(collect(expected))) と一致しません",
        ),
    )
    return nothing
end

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
- `thresholds::ScenarioDiagnosticThresholds`（timing 診断がある場合のみ artifact へ出力する）
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

_jf_thresholds_dict(t::ScenarioDiagnosticThresholds) = Dict{String, Any}(
    "id" => t.id,
    "version" => t.version,
    "onset_abs" => t.onset_abs,
    "onset_rel" => t.onset_rel,
    "onset_persistence" => t.onset_persistence,
    "rel_denominator_floor" => t.rel_denominator_floor,
)

function _jf_thresholds_from_dict(d::AbstractDict)
    _jf_check_keys(
        "diagnostics.thresholds",
        d,
        (
            "id",
            "version",
            "onset_abs",
            "onset_rel",
            "onset_persistence",
            "rel_denominator_floor",
        ),
    )
    return ScenarioDiagnosticThresholds(;
        id = _jf_as_string(d["id"], "thresholds.id"),
        version = _jf_as_string(d["version"], "thresholds.version"),
        onset_abs = _jf_as_float(d["onset_abs"], "thresholds.onset_abs"),
        onset_rel = _jf_as_float(d["onset_rel"], "thresholds.onset_rel"),
        onset_persistence = Int(d["onset_persistence"]),
        rel_denominator_floor = _jf_as_float(
            d["rel_denominator_floor"],
            "thresholds.rel_denominator_floor",
        ),
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
        # かつ JSON では null として表現する。0 へは丸めない）。
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
        out["thresholds"] = _jf_thresholds_dict(d.thresholds)
    end
    d.contribution_decomposition === nothing ||
        (out["contribution_decomposition"] = d.contribution_decomposition)
    return out
end

const _JF_TIMING_DIAGNOSTIC_KEYS = (
    "relative_delta",
    "peak",
    "trough",
    "onset_period",
    "duration_periods",
    "recovery_period",
    "thresholds",
)

function _jf_extremum_from_dict(d, label::AbstractString)
    return Dict{Symbol, NamedTuple}(
        Symbol(k) => (
            value = _jf_as_float(v["value"], "$(label).value"),
            period = v["period"] === nothing ? nothing : Int(v["period"]),
            sign = Int(v["sign"]),
        ) for (k, v) in d
    )
end

_jf_optional_int_dict(d) = Dict{Symbol, Union{Int, Nothing}}(
    Symbol(k) => (v === nothing ? nothing : Int(v)) for (k, v) in d
)

function _jf_diagnostics_from_dict(diag_d::AbstractDict)
    has_timing = haskey(diag_d, "peak")
    base_keys =
        ["claim_level", "numeric_semantics", "variables", "direction", "sign_of_delta"]
    expected_keys =
        has_timing ? vcat(base_keys, collect(_JF_TIMING_DIAGNOSTIC_KEYS)) : base_keys
    haskey(diag_d, "contribution_decomposition") &&
        push!(expected_keys, "contribution_decomposition")
    _jf_check_keys("diagnostics", diag_d, expected_keys)
    return JapanFiscalComparisonDiagnostics(
        _jf_as_symbol(diag_d["claim_level"], "diagnostics.claim_level"),
        _jf_as_symbol(diag_d["numeric_semantics"], "diagnostics.numeric_semantics"),
        Symbol[_jf_as_symbol(v, "diagnostics.variables[]") for v in diag_d["variables"]],
        Dict{Symbol, Symbol}(Symbol(k) => Symbol(v) for (k, v) in diag_d["direction"]),
        Dict{Symbol, Symbol}(Symbol(k) => Symbol(v) for (k, v) in diag_d["sign_of_delta"]),
        has_timing ?
        Dict{Symbol, Vector{Union{Float64, Missing}}}(
            Symbol(k) =>
                Union{Float64, Missing}[x === nothing ? missing : Float64(x) for x in v] for
            (k, v) in diag_d["relative_delta"]
        ) : nothing,
        has_timing ? _jf_extremum_from_dict(diag_d["peak"], "diagnostics.peak") : nothing,
        has_timing ? _jf_extremum_from_dict(diag_d["trough"], "diagnostics.trough") :
        nothing,
        has_timing ? _jf_optional_int_dict(diag_d["onset_period"]) : nothing,
        has_timing ? _jf_optional_int_dict(diag_d["duration_periods"]) : nothing,
        has_timing ? _jf_optional_int_dict(diag_d["recovery_period"]) : nothing,
        get(diag_d, "contribution_decomposition", nothing),
        has_timing ? _jf_thresholds_from_dict(diag_d["thresholds"]) :
        ScenarioDiagnosticThresholds(),
    )
end

# ===========================================================================
# 共通: 契約 version・content hash・coverage の検査
# ===========================================================================

"artifact が埋め込む契約 version chain（result / rejection 共通）。"
_jf_artifact_contract_versions() = (
    ("adapter_contract_version", JAPAN_FISCAL_ADAPTER_CONTRACT_VERSION),
    ("capability_contract_version", JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION),
    ("claim_contract_version", JAPAN_FISCAL_CLAIM_CONTRACT_VERSION),
    ("scenario_schema_version", JAPAN_FISCAL_SCENARIO_SCHEMA_VERSION),
)

"""
    _japan_fiscal_artifact_content_hash(d, hash_key) -> String

`d`（result / rejection artifact の dict）から、volatile な `generated_at` と自己参照の
`hash_key`（`result_content_hash` / `rejection_content_hash`）を除いた identity の
`"sha256:" * hex` を計算する（`compute_artifact_id`、artifacts/real_rate_model_artifact.jl と同じ
非対称除外の idiom）。生成時と decode 時の両方がこの 1 関数だけを使う。
"""
function _japan_fiscal_artifact_content_hash(d::AbstractDict, hash_key::AbstractString)
    identity =
        Dict{String, Any}(k => v for (k, v) in d if k != "generated_at" && k != hash_key)
    return "sha256:" * sha256_hex_of_canonical(identity)
end

_japan_fiscal_result_content_hash(d::AbstractDict) =
    _japan_fiscal_artifact_content_hash(d, "result_content_hash")

"schema_version・契約 version chain を現在の定数と照合する（major 違いを含め fail closed）。"
function _jf_check_artifact_versions(label::AbstractString, d::AbstractDict)
    sv = _jf_as_string(d["schema_version"], "schema_version")
    sv == JAPAN_FISCAL_RESULT_ARTIFACT_SCHEMA_VERSION || throw(
        ArgumentError(
            "$(label): 未対応の schema_version です（受理: $(JAPAN_FISCAL_RESULT_ARTIFACT_SCHEMA_VERSION)、" *
            "実値: $(sv)）。version が異なる artifact は fail closed で拒否する。",
        ),
    )
    for (key, expected) in _jf_artifact_contract_versions()
        v = _jf_as_string(d[key], key)
        v == expected || throw(
            ArgumentError(
                "$(label): $(key) が現在の契約と一致しません（期待: $(expected)、実値: $(v)）",
            ),
        )
    end
    return nothing
end

function _jf_check_content_hash(label::AbstractString, d::AbstractDict, hash_key::String)
    expected = _japan_fiscal_artifact_content_hash(d, hash_key)
    expected == d[hash_key] || throw(
        ArgumentError(
            "$(label): $(hash_key) が再計算値と一致しません（改変または非正準の入力）。",
        ),
    )
    return nothing
end

"artifact の `coverage` が #285 registry から導出した値と正準 JSON として一致することを検査する。"
function _jf_check_coverage(
    label::AbstractString,
    cov_d,
    family::Symbol,
    model::Symbol,
)::JapanFiscalCoverage
    coverage = japan_fiscal_coverage(family, model)
    cov_d isa AbstractDict ||
        throw(ArgumentError("$(label): coverage はオブジェクトでなければなりません"))
    canonical_json_bytes(cov_d) == canonical_json_bytes(to_dict(coverage)) || throw(
        ArgumentError(
            "$(label): coverage が #285 registry（japan_fiscal_coverage($(family), $(model))）と" *
            "一致しません。claim_level・numeric_semantics・unsupported 一覧を artifact 側で書き換えた" *
            "ものは受理しない（H-06・H-13）。",
        ),
    )
    return coverage
end

# ===========================================================================
# JapanFiscalScenarioRejection
# ===========================================================================

"""
    JapanFiscalScenarioRejection

`japan_fiscal_run` がモデルを実行しない（model-implied result を生成しない）ときの機械可読な
戻り値。`rejection_code`（`JAPAN_FISCAL_REJECTION_CODES`）が理由を区別する。

## フィールド
- 契約 version chain: `schema_version`・`adapter_contract_version`・
  `capability_contract_version`・`claim_contract_version`・`scenario_schema_version`
- `rejection_code::Symbol` / `status::Symbol`（常に `:not_executed`）
- `family::Symbol` / `model::Symbol` / `representability::Symbol` / `adoption::Symbol`
- `concepts::Vector{Symbol}` : 拒否の原因となった概念（`:not_adopted` では空）
- `reason::String` / `doc_ref::String`
- scenario identity: `scenario_id`・`scenario_content_hash`・`assumption_set_hash`・
  `fre_context_identity`（nullable）
- `horizon::Int` : 要求された horizon（replay 用）
- `coverage::JapanFiscalCoverage` : セルの被覆情報（#285、`claim_level` を含む）
- `generated_at`（volatile・hash 対象外）/ `rejection_content_hash`
"""
struct JapanFiscalScenarioRejection
    schema_version::String
    adapter_contract_version::String
    capability_contract_version::String
    claim_contract_version::String
    scenario_schema_version::String
    rejection_code::Symbol
    status::Symbol
    family::Symbol
    model::Symbol
    representability::Symbol
    adoption::Symbol
    concepts::Vector{Symbol}
    reason::String
    doc_ref::String
    scenario_id::String
    scenario_content_hash::String
    assumption_set_hash::String
    fre_context_identity::Union{String, Nothing}
    horizon::Int
    coverage::JapanFiscalCoverage
    generated_at::String
    rejection_content_hash::String
end

function _jf_rejection_dict_without_hash(
    rejection_code::Symbol,
    mapping::JapanFiscalModelMapping,
    coverage::JapanFiscalCoverage,
    scenario::JapanFiscalScenario,
    horizon::Int,
    generated_at::String,
    concepts::Vector{Symbol},
    reason::String,
)
    return Dict{String, Any}(
        "schema_version" => JAPAN_FISCAL_RESULT_ARTIFACT_SCHEMA_VERSION,
        "artifact_kind" => "rejection",
        "adapter_contract_version" => JAPAN_FISCAL_ADAPTER_CONTRACT_VERSION,
        "capability_contract_version" => JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION,
        "claim_contract_version" => JAPAN_FISCAL_CLAIM_CONTRACT_VERSION,
        "scenario_schema_version" => JAPAN_FISCAL_SCENARIO_SCHEMA_VERSION,
        "rejection_code" => String(rejection_code),
        "status" => "not_executed",
        "family" => String(mapping.family),
        "model" => String(mapping.model),
        "representability" => String(mapping.representability),
        "adoption" => String(mapping.adoption),
        "concepts" => String.(concepts),
        "reason" => reason,
        "doc_ref" => mapping.doc_ref,
        "scenario_id" => scenario.scenario_id,
        "scenario_content_hash" => japan_fiscal_scenario_content_hash(scenario),
        "assumption_set_hash" => japan_fiscal_assumption_set_hash(scenario),
        "fre_context_identity" =>
            scenario.fre_context === nothing ? nothing :
            japan_fiscal_fre_context_identity(scenario.fre_context),
        "horizon" => horizon,
        "coverage" => to_dict(coverage),
        "generated_at" => generated_at,
    )
end

function _jf_rejection(
    rejection_code::Symbol,
    mapping::JapanFiscalModelMapping,
    coverage::JapanFiscalCoverage,
    scenario::JapanFiscalScenario,
    horizon::Int,
    generated_at::String,
    concepts::Vector{Symbol},
    reason::String,
)
    _jf_check(rejection_code, JAPAN_FISCAL_REJECTION_CODES, "rejection_code")
    d = _jf_rejection_dict_without_hash(
        rejection_code,
        mapping,
        coverage,
        scenario,
        horizon,
        generated_at,
        concepts,
        reason,
    )
    return JapanFiscalScenarioRejection(
        JAPAN_FISCAL_RESULT_ARTIFACT_SCHEMA_VERSION,
        JAPAN_FISCAL_ADAPTER_CONTRACT_VERSION,
        JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION,
        JAPAN_FISCAL_CLAIM_CONTRACT_VERSION,
        JAPAN_FISCAL_SCENARIO_SCHEMA_VERSION,
        rejection_code,
        :not_executed,
        mapping.family,
        mapping.model,
        mapping.representability,
        mapping.adoption,
        concepts,
        reason,
        mapping.doc_ref,
        scenario.scenario_id,
        d["scenario_content_hash"],
        d["assumption_set_hash"],
        d["fre_context_identity"],
        horizon,
        coverage,
        generated_at,
        _japan_fiscal_artifact_content_hash(d, "rejection_content_hash"),
    )
end

function to_dict(r::JapanFiscalScenarioRejection)
    return Dict{String, Any}(
        "schema_version" => r.schema_version,
        "artifact_kind" => "rejection",
        "adapter_contract_version" => r.adapter_contract_version,
        "capability_contract_version" => r.capability_contract_version,
        "claim_contract_version" => r.claim_contract_version,
        "scenario_schema_version" => r.scenario_schema_version,
        "rejection_code" => String(r.rejection_code),
        "status" => String(r.status),
        "family" => String(r.family),
        "model" => String(r.model),
        "representability" => String(r.representability),
        "adoption" => String(r.adoption),
        "concepts" => String.(r.concepts),
        "reason" => r.reason,
        "doc_ref" => r.doc_ref,
        "scenario_id" => r.scenario_id,
        "scenario_content_hash" => r.scenario_content_hash,
        "assumption_set_hash" => r.assumption_set_hash,
        "fre_context_identity" => r.fre_context_identity,
        "horizon" => r.horizon,
        "coverage" => to_dict(r.coverage),
        "generated_at" => r.generated_at,
        "rejection_content_hash" => r.rejection_content_hash,
    )
end
to_json(r::JapanFiscalScenarioRejection) = JSON3.write(to_dict(r))

const _JF_REJECTION_KEYS = (
    "schema_version",
    "artifact_kind",
    "adapter_contract_version",
    "capability_contract_version",
    "claim_contract_version",
    "scenario_schema_version",
    "rejection_code",
    "status",
    "family",
    "model",
    "representability",
    "adoption",
    "concepts",
    "reason",
    "doc_ref",
    "scenario_id",
    "scenario_content_hash",
    "assumption_set_hash",
    "fre_context_identity",
    "horizon",
    "coverage",
    "generated_at",
    "rejection_content_hash",
)

"""
    japan_fiscal_scenario_rejection_from_dict(d) -> JapanFiscalScenarioRejection

`to_dict(::JapanFiscalScenarioRejection)` の round trip。未知/欠落キー・`artifact_kind`・
schema/契約 version・`rejection_content_hash`・coverage（#285 registry との一致）・
`representability`/`adoption` と `rejection_code` の整合を検査し、不一致は `ArgumentError`
（fail closed）。
"""
function japan_fiscal_scenario_rejection_from_dict(
    d::AbstractDict,
)::JapanFiscalScenarioRejection
    label = "JapanFiscalScenarioRejection"
    _jf_check_keys(label, d, _JF_REJECTION_KEYS)
    d["artifact_kind"] == "rejection" || throw(
        ArgumentError("$(label): artifact_kind は \"rejection\" でなければなりません"),
    )
    _jf_check_artifact_versions(label, d)
    _jf_check_content_hash(label, d, "rejection_content_hash")
    d["status"] == "not_executed" ||
        throw(ArgumentError("$(label): status は \"not_executed\" でなければなりません"))

    family = _jf_as_symbol(d["family"], "family")
    model = _jf_as_symbol(d["model"], "model")
    coverage = _jf_check_coverage(label, d["coverage"], family, model)
    mapping = japan_fiscal_model_mapping(family, model)
    code = _jf_as_symbol(d["rejection_code"], "rejection_code")
    _jf_check(code, JAPAN_FISCAL_REJECTION_CODES, "rejection_code")
    representability = _jf_as_symbol(d["representability"], "representability")
    adoption = _jf_as_symbol(d["adoption"], "adoption")
    (representability === mapping.representability && adoption === mapping.adoption) ||
        throw(
            ArgumentError(
                "$(label): representability/adoption が #274 registry と一致しません" *
                "（registry: $(mapping.representability)/$(mapping.adoption)）",
            ),
        )
    (code === :not_adopted) == (adoption === :not_adopted) || throw(
        ArgumentError(
            "$(label): rejection_code=$(code) は adoption=$(adoption) と整合しません",
        ),
    )

    return JapanFiscalScenarioRejection(
        _jf_as_string(d["schema_version"], "schema_version"),
        _jf_as_string(d["adapter_contract_version"], "adapter_contract_version"),
        _jf_as_string(d["capability_contract_version"], "capability_contract_version"),
        _jf_as_string(d["claim_contract_version"], "claim_contract_version"),
        _jf_as_string(d["scenario_schema_version"], "scenario_schema_version"),
        code,
        :not_executed,
        family,
        model,
        representability,
        adoption,
        Symbol[_jf_as_symbol(c, "concepts[]") for c in d["concepts"]],
        _jf_as_string(d["reason"], "reason"),
        _jf_as_string(d["doc_ref"], "doc_ref"),
        _jf_as_string(d["scenario_id"], "scenario_id"),
        _jf_as_string(d["scenario_content_hash"], "scenario_content_hash"),
        _jf_as_string(d["assumption_set_hash"], "assumption_set_hash"),
        _jf_as_optional(_jf_as_string, d["fre_context_identity"], "fre_context_identity"),
        Int(d["horizon"]),
        coverage,
        _jf_as_string(d["generated_at"], "generated_at"),
        _jf_as_string(d["rejection_content_hash"], "rejection_content_hash"),
    )
end

# ===========================================================================
# JapanFiscalScenarioResult
# ===========================================================================

"""
    JapanFiscalScenarioResult

#276 の result artifact 本体（#277 で schema 2.0.0）。

## フィールド（主要なもののみ抜粋。全体は `to_dict` を参照）
- 契約 version chain: `schema_version`・`adapter_contract_version`・
  `capability_contract_version`・`claim_contract_version`・`scenario_schema_version`
- scenario identity: `scenario_id`・`scenario_content_hash`・`assumption_set_hash`
- observed context identity: `fre_context_identity`（nullable）
- model identity: `model_name`・`parameter_identity_hash`
- `horizon`・`periods`・`result_shape`
- traceability: `applied_inputs`・`assumption_disposition`（#277）
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
    assumption_disposition::Vector{JapanFiscalAssumptionDisposition}
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

"`assumed`（H-10）: assumption_id 昇順に整列する（入力順に artifact identity を依存させない、#277）。"
_jf_assumed(scenario::JapanFiscalScenario) = Dict{String, Any}[
    to_dict(a) for a in sort(scenario.assumptions; by = a -> a.assumption_id)
]

"""
    japan_fiscal_run(model, scenario; horizon=nothing, generated_at=now(UTC))
        -> Union{JapanFiscalScenarioResult,JapanFiscalScenarioRejection}

Japan Fiscal Scenario Lab の scenario runner（Issue #276 の公開 entrypoint）。
`family` は `scenario.family` から取るため、family/scenario の不一致は構成上発生しない。

処理順:
1. `horizon`（既定 `JAPAN_FISCAL_DEFAULT_HORIZON`）が 1 未満なら `ArgumentError`（入力エラー。
   artifact を生成しない）。
2. `japan_fiscal_model_mapping(scenario.family, model).adoption === :not_adopted` なら
   `rejection_code=:not_adopted`。
3. `japan_fiscal_assumption_disposition` で、モデルが受理する必須概念に explicit assumption が
   無ければ `:missing_required_assumption`（未指定を 0 へ丸めない）、変換未実装の概念に
   explicit assumption があれば `:conversion_not_implemented`。
4. `japan_fiscal_validate_claims`（H-07）→ `JAPAN_FISCAL_MODEL_ADAPTERS[model]` を実行し、
   `applied_inputs` が disposition と一致することを検査したうえで `JapanFiscalScenarioResult` を
   組み立てる。

`generated_at` は artifact の volatile フィールド（hash 対象外）。fixture を決定的に再生成する
ときだけ固定値を渡す。
"""
function japan_fiscal_run(
    model::Symbol,
    scenario::JapanFiscalScenario;
    horizon::Union{Int, Nothing} = nothing,
    generated_at::DateTime = now(UTC),
)
    h = horizon === nothing ? JAPAN_FISCAL_DEFAULT_HORIZON : horizon
    h >= 1 || throw(
        ArgumentError("japan_fiscal_run: horizon は1以上でなければなりません（実値: $h）"),
    )
    mapping = japan_fiscal_model_mapping(scenario.family, model)
    coverage = japan_fiscal_coverage(scenario.family, model)
    ts = _jf_result_format_datetime(generated_at)

    if mapping.adoption === :not_adopted
        return _jf_rejection(
            :not_adopted,
            mapping,
            coverage,
            scenario,
            h,
            ts,
            Symbol[],
            mapping.reason,
        )
    end

    dispositions = japan_fiscal_assumption_disposition(scenario, model)
    missing_required = Symbol[
        d.concept for d in dispositions if d.requirement === :required &&
            d.assumption_state === :not_specified &&
            d.model_input !== :not_accepted
    ]
    if !isempty(missing_required)
        return _jf_rejection(
            :missing_required_assumption,
            mapping,
            coverage,
            scenario,
            h,
            ts,
            missing_required,
            "family=$(scenario.family) の必須概念 $(missing_required) はモデル $(model) が受理するが、" *
            "explicit assumption がありません。未指定を 0（変化なし）へ丸めて実行しません" *
            "（#274 zero_vs_missing）。『変化なし』を主張する場合は magnitude=0.0 の assumption を" *
            "明示してください。",
        )
    end
    unimplemented = Symbol[
        d.concept for d in dispositions if d.assumption_state === :explicit &&
            d.model_input === :conversion_not_implemented
    ]
    if !isempty(unimplemented)
        return _jf_rejection(
            :conversion_not_implemented,
            mapping,
            coverage,
            scenario,
            h,
            ts,
            unimplemented,
            "$(unimplemented) は #274 の mapping 上はモデル $(model) が受理する" *
            "（:requires_structural_conversion）が、adapter が変換（閉じ変数の選択、#274 §5.3）を" *
            "実装していません。explicit assumption を黙って無視せず実行しません。",
        )
    end

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

    adapter = JAPAN_FISCAL_MODEL_ADAPTERS[model]
    out = adapter(mapping, scenario; horizon = h)
    _jf_check_result_dispositions(
        "japan_fiscal_run(family=$(scenario.family), model=$(model))",
        dispositions,
        [ai.concept for ai in out.applied_inputs],
    )

    diagnostics = _japan_fiscal_diagnostics(out, coverage)

    observed = scenario.fre_context === nothing ? nothing : to_dict(scenario.fre_context)
    assumed = _jf_assumed(scenario)
    model_implied = Dict{String, Any}(
        "baseline" => _jf_tag_series(out.baseline, coverage.numeric_semantics),
        "scenario" => _jf_tag_series(out.scenario, coverage.numeric_semantics),
    )

    # parameters(m) はモデルによって Greek 文字のフィールド名（例: NK の φ_x・Keen の κ2）を
    # 持つため、canonical JSON の ASCII-only キー制約（RFC 8785 実装、artifacts/json_canonical.jl）
    # に抵触する。フィールド名ではなく固定順序の値配列としてハッシュする（型ごとに
    # `parameters(m)` の NamedTuple フィールド順は一定であり、model と組にすれば曖昧さはない）。
    parameter_identity_hash =
        "sha256:" * sha256_hex_of_canonical(
            Dict{String, Any}(
                "adapter_contract_version" => JAPAN_FISCAL_ADAPTER_CONTRACT_VERSION,
                "model" => String(model),
                "parameters" => Float64[Float64(v) for v in values(out.parameter_identity)],
            ),
        )

    base = Dict{String, Any}(
        "schema_version" => JAPAN_FISCAL_RESULT_ARTIFACT_SCHEMA_VERSION,
        "artifact_kind" => "result",
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
        "assumption_disposition" => [to_dict(x) for x in dispositions],
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
        "generated_at" => ts,
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
        dispositions,
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
        ts,
        result_content_hash,
    )
end

function to_dict(r::JapanFiscalScenarioResult)
    return Dict{String, Any}(
        "schema_version" => r.schema_version,
        "artifact_kind" => "result",
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
        "assumption_disposition" => [to_dict(x) for x in r.assumption_disposition],
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
フィールドの型・必須性の正本は `json_schema`（`JAPAN_FISCAL_RESULT_ARTIFACT_JSON_SCHEMA`）である。
"""
function japan_fiscal_result_artifact_contract()
    return Dict{String, Any}(
        "schema_version" => JAPAN_FISCAL_RESULT_ARTIFACT_SCHEMA_VERSION,
        "json_schema" => JAPAN_FISCAL_RESULT_ARTIFACT_JSON_SCHEMA,
        "adapter_contract_version" => JAPAN_FISCAL_ADAPTER_CONTRACT_VERSION,
        "capability_contract_version" => JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION,
        "claim_contract_version" => JAPAN_FISCAL_CLAIM_CONTRACT_VERSION,
        "scenario_schema_version" => JAPAN_FISCAL_SCENARIO_SCHEMA_VERSION,
        "adopted_models" => sort(collect(String.(keys(JAPAN_FISCAL_MODEL_ADAPTERS)))),
        "adapter_implemented_concepts" => Dict{String, Any}(
            String(m) => String.(cs) for
            (m, cs) in JAPAN_FISCAL_ADAPTER_IMPLEMENTED_CONCEPTS
        ),
        "artifact_kinds" => _jf_syms(JAPAN_FISCAL_ARTIFACT_KINDS),
        "result_shapes" => ["time_path", "static_point"],
        "rejection_status_values" => ["not_executed"],
        "rejection_codes" => _jf_syms(JAPAN_FISCAL_REJECTION_CODES),
        "assumption_states" => _jf_syms(JAPAN_FISCAL_ASSUMPTION_STATES),
        "model_input_treatments" => _jf_syms(JAPAN_FISCAL_MODEL_INPUT_TREATMENTS),
        "hash_rules" => Dict{String, Any}(
            "algorithm" => "sha256 over RFC 8785 canonical JSON",
            "result_content_hash" => "artifact 全体から generated_at と result_content_hash を除いた正準 JSON",
            "rejection_content_hash" => "artifact 全体から generated_at と rejection_content_hash を除いた正準 JSON",
            "volatile_fields" => ["generated_at"],
        ),
        "fields" => Dict{String, Any}(
            "discriminator" => ["artifact_kind"],
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
            "traceability" => ["applied_inputs", "assumption_disposition"],
            "classification" => ["observed", "assumed", "model_implied"],
            "coverage" => ["coverage", "funding_cost_legs"],
            "diagnostics" => ["diagnostics", "sensitivity"],
            "rejection" => ["rejection_code", "status", "concepts", "reason"],
            "identity_hash" => ["result_content_hash", "rejection_content_hash"],
        ),
        "doc_ref" => "docs/architecture/japan_fiscal_scenario_result_contract.md",
    )
end

# ===========================================================================
# serialization: fail-closed round trip
# ===========================================================================

const _JF_RESULT_KEYS = (
    "schema_version",
    "artifact_kind",
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
    "assumption_disposition",
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

"""
    japan_fiscal_scenario_result_from_dict(d) -> JapanFiscalScenarioResult

`to_dict(::JapanFiscalScenarioResult)` の round trip（fail closed）。次を検査し、違反は
`ArgumentError`:

- 未知/欠落キー・`artifact_kind == "result"`・`execution_status == "ok"`
- `schema_version` と契約 version chain が現在の定数と一致すること（version 違いを受理しない）
- `result_content_hash` の再計算一致（改変の検出）
- `coverage` が #285 registry から導出した値と一致すること（claim_level の書き換えを受理しない）
- `diagnostics` が `claim_level` の許す診断だけを持つこと・`numeric_semantics` の一致
- `assumption_disposition` が「必須概念の未指定」「explicit assumption の変換未実装」を含まず、
  `:applied` の概念が `applied_inputs` と一致すること（未指定を 0 として扱った artifact を拒否する）
"""
function japan_fiscal_scenario_result_from_dict(d::AbstractDict)::JapanFiscalScenarioResult
    label = "JapanFiscalScenarioResult"
    _jf_check_keys(label, d, _JF_RESULT_KEYS)
    d["artifact_kind"] == "result" ||
        throw(ArgumentError("$(label): artifact_kind は \"result\" でなければなりません"))
    _jf_check_artifact_versions(label, d)
    _jf_check_content_hash(label, d, "result_content_hash")
    d["execution_status"] == "ok" ||
        throw(ArgumentError("$(label): execution_status は \"ok\" でなければなりません"))

    family = _jf_as_symbol(d["family"], "family")
    model = _jf_as_symbol(d["model"], "model")
    coverage = _jf_check_coverage(label, d["coverage"], family, model)
    coverage.adoption === :not_adopted && throw(
        ArgumentError(
            "$(label): adoption=:not_adopted のセル（family=$(family), model=$(model)）は result " *
            "artifact を持てません（not_representable を成功結果として扱わない）",
        ),
    )
    result_shape = _jf_as_symbol(d["result_shape"], "result_shape")
    _jf_check(result_shape, (:time_path, :static_point), "result_shape")

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
    dispositions = JapanFiscalAssumptionDisposition[
        _jf_disposition_from_dict(x) for x in d["assumption_disposition"]
    ]
    spec = japan_fiscal_family_spec(family)
    [x.concept for x in dispositions] == vcat(spec.required_concepts, spec.optional_concepts) ||
        throw(
            ArgumentError(
                "$(label): assumption_disposition は family=$(family) の required/optional concepts を" *
                "宣言順にすべて持たなければなりません",
            ),
        )
    _jf_check_result_dispositions(
        label,
        dispositions,
        [ai.concept for ai in applied_inputs],
    )

    diagnostics = _jf_diagnostics_from_dict(d["diagnostics"])
    (
        diagnostics.claim_level === coverage.claim_level &&
        diagnostics.numeric_semantics === coverage.numeric_semantics
    ) || throw(
        ArgumentError(
            "$(label): diagnostics の claim_level/numeric_semantics が coverage と一致しません",
        ),
    )
    permits_timing = result_shape === :time_path && :peak in coverage.permitted_diagnostics
    (diagnostics.peak !== nothing) == permits_timing || throw(
        ArgumentError(
            "$(label): diagnostics の timing 診断（peak/onset/duration/relative_delta）の有無が " *
            "claim_level=$(coverage.claim_level)・result_shape=$(result_shape) と整合しません（H-07・H-17）",
        ),
    )
    for side in ("baseline", "scenario")
        d["model_implied"][side]["numeric_semantics"] ==
        String(coverage.numeric_semantics) || throw(
            ArgumentError(
                "$(label): model_implied.$(side).numeric_semantics が coverage と一致しません（H-08）",
            ),
        )
    end

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
        result_shape,
        applied_inputs,
        dispositions,
        d["observed"],
        Dict{String, Any}[x for x in d["assumed"]],
        d["model_implied"],
        diagnostics,
        coverage,
        d["funding_cost_legs"],
        d["sensitivity"],
        :ok,
        _jf_as_optional(_jf_as_string, d["termination_reason"], "termination_reason"),
        String[_jf_as_string(w, "warnings[]") for w in d["warnings"]],
        _jf_as_string(d["generated_at"], "generated_at"),
        _jf_as_string(d["result_content_hash"], "result_content_hash"),
    )
end

"""
    japan_fiscal_artifact_from_dict(d) -> Union{JapanFiscalScenarioResult,JapanFiscalScenarioRejection}

`artifact_kind` で result / rejection を判別して fail closed decode する。`artifact_kind` が
無い・未知の値は `ArgumentError`。
"""
function japan_fiscal_artifact_from_dict(d::AbstractDict)
    haskey(d, "artifact_kind") || throw(
        ArgumentError(
            "Japan fiscal scenario artifact: artifact_kind がありません（受理: $(_jf_syms(JAPAN_FISCAL_ARTIFACT_KINDS))）",
        ),
    )
    kind = d["artifact_kind"]
    kind == "result" && return japan_fiscal_scenario_result_from_dict(d)
    kind == "rejection" && return japan_fiscal_scenario_rejection_from_dict(d)
    throw(
        ArgumentError(
            "Japan fiscal scenario artifact: 未知の artifact_kind です: $(repr(kind))",
        ),
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

"`bytes` を `path` へ atomic に書く（`.tmp` へ書いて `fsync` した後 `mv` で確定させる。上書きしない）。"
function _jf_atomic_write(path::AbstractString, bytes::AbstractVector{UInt8})
    isfile(path) && throw(
        ArgumentError(
            "japan fiscal scenario artifact ファイルが既に存在します（上書きしません）: $path",
        ),
    )
    mkpath(dirname(path))
    tmp_path = path * ".tmp"
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
    return _jf_atomic_write(
        _jf_result_file_path(base_dir, r),
        canonical_json_bytes(to_dict(r)),
    )
end
