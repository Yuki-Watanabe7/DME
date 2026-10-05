# japan_fiscal_fixture_cases.jl: Japan Fiscal Scenario Lab の deterministic E2E fixture（Issue #277）を
# `inputs/` から組み立てるテスト用ヘルパ。test/test_japan_fiscal_e2e.jl と regenerate.jl の両方が
# include する。
#
# 入力（すべて手で管理する正本。regenerate.jl は変更しない）:
#   - inputs/fre_context/*.json : FRE current snapshot の fixture（架空。observed context としてのみ使う）
#   - inputs/assumptions/*.json : explicit assumption 集合（FRE context とは独立に magnitude を明示する）
#   - inputs/cases.json         : scenario（family × assumption 集合 × FRE context）・case（scenario ×
#                                 model × horizon × tags）・入力エラー case・固定 generated_at
#
# 生成物（regenerate.jl が書く）:
#   - handoff/v1/      : Market Analyzer 向け versioned consumer fixture（`write_japan_fiscal_handoff`）
#   - invalid_inputs/  : 有効な scenario から 1 事実だけを破った入力（DME 側の fail closed 検証用）

using DME
using Dates

const JF_FIXTURE_ROOT = @__DIR__
const JF_INPUTS_DIR = joinpath(JF_FIXTURE_ROOT, "inputs")
const JF_HANDOFF_DIR = joinpath(JF_FIXTURE_ROOT, "handoff", "v1")
const JF_INVALID_INPUTS_DIR = joinpath(JF_FIXTURE_ROOT, "invalid_inputs")

jf_fixture_json(path::AbstractString) = DME._jf_json_to_plain(DME.json_read(read(path, String)))

"`inputs/cases.json`（fixture の manifest）。"
jf_fixture_manifest() = jf_fixture_json(joinpath(JF_INPUTS_DIR, "cases.json"))

"fixture の固定 `generated_at`（artifact の volatile フィールド。バイト列を決定的にするためだけに固定する）。"
jf_fixture_generated_at() =
    DateTime(chopsuffix(jf_fixture_manifest()["generated_at"], "Z"), dateformat"yyyy-mm-ddTHH:MM:SS")

jf_fixture_negative_source_case_id() = jf_fixture_manifest()["negative_source_case_id"]

"`inputs/fre_context/<name>.json` を fail closed で読む（`context_identity` を検査する）。"
jf_fixture_fre_context(name::AbstractString) = japan_fiscal_fre_context_from_dict(
    jf_fixture_json(joinpath(JF_INPUTS_DIR, "fre_context", "$(name).json")),
)

"`inputs/assumptions/<set_id>.json` の explicit assumption 集合（unit・direction の整合を検査する）。"
function jf_fixture_assumption_set(set_id::AbstractString)
    d = jf_fixture_json(joinpath(JF_INPUTS_DIR, "assumptions", "$(set_id).json"))
    d["set_id"] == set_id || error("assumption set $(set_id): set_id がファイル名と一致しません")
    return JapanFiscalScenarioAssumption[japan_fiscal_assumption_from_dict(a) for a in d["assumptions"]]
end

"manifest の scenario 定義から `JapanFiscalScenario` を組み立てる（scenario_id => scenario）。"
function jf_fixture_scenarios()
    out = Dict{String, JapanFiscalScenario}()
    for s in jf_fixture_manifest()["scenarios"]
        fre = s["fre_context"] === nothing ? nothing : jf_fixture_fre_context(s["fre_context"])
        out[s["scenario_id"]] = JapanFiscalScenario(;
            scenario_id = s["scenario_id"],
            family = Symbol(s["family"]),
            name = s["name"],
            notes = s["notes"],
            fre_context = fre,
            assumptions = jf_fixture_assumption_set(s["assumption_set"]),
            provenance = JapanFiscalScenarioProvenance(; assumption_source = :fixture),
        )
    end
    return out
end

"manifest の case 定義から `JapanFiscalHandoffCase` の列（manifest の順）を組み立てる。"
function jf_fixture_cases()
    scenarios = jf_fixture_scenarios()
    return JapanFiscalHandoffCase[
        JapanFiscalHandoffCase(;
            case_id = c["case_id"],
            purpose = c["purpose"],
            tags = Symbol.(c["tags"]),
            scenario = scenarios[c["scenario_id"]],
            model = Symbol(c["model"]),
            horizon = c["horizon"],
        ) for c in jf_fixture_manifest()["cases"]
    ]
end

"manifest の case を `case_id` で引く。"
jf_fixture_case_entry(case_id::AbstractString) =
    only(c for c in jf_fixture_manifest()["cases"] if c["case_id"] == case_id)

# ---------------------------------------------------------------------------
# invalid inputs（有効な scenario から 1 事実だけを破る。regenerate.jl が書き、テストが読む）
# ---------------------------------------------------------------------------

_jf_scenario_plain(sc) = DME._jf_json_to_plain(DME.json_read(String(canonical_json_bytes(to_dict(sc)))))

function _jf_assumption_index(d, concept)
    return findfirst(a -> a["concept"] == concept, d["assumptions"])
end

"""
    jf_fixture_invalid_inputs() -> Vector{NamedTuple{(:name,:description,:expected_error,:document)}}

DME 側で fail closed を検証する入力（scenario JSON）。`expected_error` は
`japan_fiscal_scenario_from_dict` の `ArgumentError` メッセージに含まれるべき断片。
"""
function jf_fixture_invalid_inputs()
    scenarios = jf_fixture_scenarios()
    f5 = _jf_scenario_plain(scenarios["jf-f5-base"])
    f2 = _jf_scenario_plain(scenarios["jf-f2-base"])
    out = NamedTuple[]

    let d = deepcopy(f5)
        i = _jf_assumption_index(d, "long_rate_funding_condition")
        d["assumptions"][i]["unit"] = "%pt (annualized)"
        push!(out, (
            name = "scenario_unsupported_unit",
            description = "長期金利・funding 条件（bp）の assumption に %pt の単位を付けた。単位は concept から導出され、読み替えない。",
            expected_error = "unit が concept と一致しません",
            document = d,
        ))
    end

    let d = deepcopy(f5)
        i = _jf_assumption_index(d, "long_rate_funding_condition")
        d["assumptions"][i]["magnitude_source"] = "external_belief"
        push!(out, (
            name = "scenario_external_belief_magnitude",
            description = "magnitude_source を external_belief にした（FRE の affinity / share / confidence が外部 belief を経由して magnitude へ入る経路。H-04）。",
            expected_error = "external_belief",
            document = d,
        ))
    end

    let d = deepcopy(f5)
        d["shock_magnitude_from_regime_affinity"] = 0.68
        push!(out, (
            name = "scenario_affinity_as_magnitude_field",
            description = "FRE の regime affinity を shock magnitude として渡す未知フィールドを加えた。",
            expected_error = "未知のキー",
            document = d,
        ))
    end

    let d = deepcopy(f5)
        i = _jf_assumption_index(d, "long_rate_funding_condition")
        d["assumptions"][i]["magnitude"] = 500.0
        push!(out, (
            name = "scenario_tampered_magnitude",
            description = "assumption の magnitude を書き換え、assumption_set_hash / content_hash を据え置いた。",
            expected_error = "assumption_set_hash が内容と一致しません",
            document = d,
        ))
    end

    let d = deepcopy(f2)
        push!(d["assumptions"], Dict{String, Any}(
            "assumption_id" => "a-cb-absorption",
            "concept" => "cb_jgb_absorption",
            "unit" => japan_fiscal_assumption_concept(:cb_jgb_absorption).unit,
            "magnitude" => 2.0,
            "direction" => "up",
            "magnitude_source" => "assumed_default",
            "notes" => "",
        ))
        push!(out, (
            name = "scenario_concept_outside_family",
            description = "財政再建 family に中央銀行の JGB 吸収（family の required / optional に無い概念）を加えた。",
            expected_error = "required/optional concepts に含まれません",
            document = d,
        ))
    end

    let d = deepcopy(f5)
        i = _jf_assumption_index(d, "long_rate_funding_condition")
        d["assumptions"][i]["direction"] = "down"
        push!(out, (
            name = "scenario_direction_mismatch",
            description = "magnitude（+50bp）と矛盾する direction（down）を付けた。direction は magnitude の符号から導出される。",
            expected_error = "direction が magnitude の符号と一致しません",
            document = d,
        ))
    end

    return out
end

"""
    jf_fixture_run_argument_errors() -> Vector{NamedTuple}

`japan_fiscal_run` の入力エラー（artifact を生成しない）。manifest の `input_errors` から読む。
"""
jf_fixture_run_argument_errors() = [
    (
        case_id = e["case_id"],
        scenario_id = e["scenario_id"],
        model = Symbol(e["model"]),
        horizon = e["horizon"],
        expected_error = e["expected_error"],
        description = e["description"],
    ) for e in jf_fixture_manifest()["input_errors"]
]
