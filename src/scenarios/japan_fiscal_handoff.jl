# japan_fiscal_handoff.jl: Japan Fiscal Scenario Lab の deterministic E2E・Market Analyzer
# handoff bundle・replay（Issue #277）。
#
# #275 の scenario・#276 の result / rejection artifact・#274/#285/#275/#276 の機械可読契約を、
# consumer（Market Analyzer）が Julia 内部型なしで読める versioned なファイル束（handoff bundle）
# としてまとめる。bundle は `index.json` を入口とし、各ファイルの SHA-256 を index が保持する。
#
# 設計方針（ADR 0025）:
#   - bundle の全ファイルは RFC 8785 正準 JSON（`canonical_json_bytes`）で書く。同一の case 集合と
#     `generated_at` から同一バイト列を得る（決定論）。
#   - index は case ごとの要約（`japan_fiscal_handoff_case_summary`）を持つが、要約は artifact から
#     機械的に導出する値であり、load 時に artifact から再導出して一致を検査する（要約と本体の乖離を
#     受理しない）。
#   - case の `tags`（`JAPAN_FISCAL_HANDOFF_CASE_TAGS`）は consumer が normal / partial / adverse の
#     ケースを選ぶための語彙であり、load 時に artifact・scenario の内容と整合することを検査する。
#   - consumer が fail closed を検証するための negative artifact（`JAPAN_FISCAL_HANDOFF_NEGATIVE_KINDS`）
#     を bundle に含める。load はそれらが DME の decoder で**拒否されること**を検査する。
#   - load は fail closed: index / 契約 version・bundle hash・ファイル SHA-256・未列挙ファイル・
#     scenario と artifact の identity 連結・要約・tags・契約 export の一致のいずれかが崩れれば
#     `ArgumentError`。
#   - replay は保存済み scenario から `japan_fiscal_run` を再実行し、保存済み artifact と比較する。
#     数値以外（identity・構造・診断の離散値）は完全一致、数値は許容誤差内の一致を要求し、
#     content hash の完全一致は `exact_match` として別に報告する（BLAS 等のプラットフォーム差で
#     最終桁が変わりうるため、hash 一致を replay 成立の必要条件にしない）。
#
# 依存: scenarios/japan_fiscal_result.jl（japan_fiscal_run・japan_fiscal_artifact_from_dict・
# _jf_atomic_write）・scenarios/japan_fiscal_scenario_schema.jl（scenario decode・契約 export）・
# scenarios/japan_fiscal_claim_contract.jl・scenarios/japan_fiscal_capability.jl・
# artifacts/json_canonical.jl。
#
# 設計契約:
#   docs/architecture/japan_fiscal_scenario_handoff.md
#   docs/adr/0025-japan-fiscal-scenario-handoff-contract.md

"handoff bundle（index）の契約 version。"
const JAPAN_FISCAL_HANDOFF_SCHEMA_VERSION = "japan-fiscal-scenario-handoff/1.0.0"

"handoff index の JSON Schema（DME 所有。リポジトリルートからの相対パス）。"
const JAPAN_FISCAL_HANDOFF_JSON_SCHEMA = "schemas/japan-fiscal-scenario-handoff-v1.schema.json"

"scenario 入力 record（`to_dict(::JapanFiscalScenario)`）の JSON Schema（DME 所有）。"
const JAPAN_FISCAL_SCENARIO_JSON_SCHEMA = "schemas/japan-fiscal-scenario-v1.schema.json"

"""
consumer が fail closed を検証するための negative artifact の種類（bundle の `negative/`）。
いずれも DME の decoder（`japan_fiscal_artifact_from_dict`）が拒否する。

- `:content_hash_mismatch` … 系列の値を書き換え、content hash を据え置いた（改変・破損）
- `:unsupported_schema_version` … `schema_version` の major を上げた（hash は再計算済み）
- `:missing_required_field` … 必須フィールド `coverage` を削除した（hash は再計算済み）
- `:claim_level_exceeds_contract` … `coverage.claim_level` を `:magnitude`（日本の量）へ書き換えた
  （hash は再計算済み。#285 registry と一致しない）
- `:not_representable_presented_as_result` … not_representable セルの result を装った
  （hash は再計算済み）
- `:missing_assumption_presented_as_zero` … 必須概念の explicit assumption を取り除き、
  baseline 保持（= 0 の変化）として result を装った（hash は再計算済み）
"""
const JAPAN_FISCAL_HANDOFF_NEGATIVE_KINDS = (
    :content_hash_mismatch,
    :unsupported_schema_version,
    :missing_required_field,
    :claim_level_exceeds_contract,
    :not_representable_presented_as_result,
    :missing_assumption_presented_as_zero,
)

"""
handoff case の tag 語彙。consumer が normal / partial / adverse のケースを選ぶための分類で、
`load_japan_fiscal_handoff` が artifact・scenario の内容との整合を検査する。

- `:representable` / `:partial` … 実行された result のセル representability
- `:not_representable` … not_representable セルの拒否（`rejection_code=:not_adopted`）
- `:partial_not_adopted` … partial だが #274 が採用しなかったセルの拒否
- `:missing_required_assumption` / `:conversion_not_implemented` … 同名 `rejection_code` の拒否
- `:missing_fre_context` … scenario が FRE context を持たない
- `:fre_unavailable` … FRE context の `regime_determination = :unavailable`
- `:fre_context_variant` … 同一 model・同一 assumption 集合で FRE context だけが異なる case が他にある
- `:explicit_zero_assumption` … magnitude = 0.0 の explicit assumption（「変化なし」の主張）を含む
- `:optional_concept_held_at_baseline` … 未指定の任意概念をモデルが baseline 値のまま保持した
- `:explicit_assumption_not_accepted` … モデルが受け取れない概念の explicit assumption を含む（開示のみ）
"""
const JAPAN_FISCAL_HANDOFF_CASE_TAGS = (
    :representable,
    :partial,
    :not_representable,
    :partial_not_adopted,
    :missing_required_assumption,
    :conversion_not_implemented,
    :missing_fre_context,
    :fre_unavailable,
    :fre_context_variant,
    :explicit_zero_assumption,
    :optional_concept_held_at_baseline,
    :explicit_assumption_not_accepted,
)

"bundle 内のファイル名に使う ID の形式（case_id・scenario_id）。"
const _JF_HANDOFF_ID_PATTERN = r"^[a-z0-9][a-z0-9._-]*$"

function _jf_handoff_check_id(label::AbstractString, id::AbstractString)
    occursin(_JF_HANDOFF_ID_PATTERN, id) || throw(
        ArgumentError(
            "$(label) は $(_JF_HANDOFF_ID_PATTERN.pattern) に一致しなければなりません" *
            "（bundle 内のファイル名に使う。実値: $(repr(id))）",
        ),
    )
    return nothing
end

# ===========================================================================
# JapanFiscalHandoffCase
# ===========================================================================

"""
    JapanFiscalHandoffCase

handoff bundle に含める 1 実行（scenario × model × horizon）。

## フィールド
- `case_id::String` : bundle 内で一意（`artifacts/<case_id>.json` のファイル名になる）
- `purpose::String` : 人が読む説明
- `tags::Vector{Symbol}` : `JAPAN_FISCAL_HANDOFF_CASE_TAGS`（load 時に内容との整合を検査する）
- `scenario::JapanFiscalScenario`
- `model::Symbol`
- `horizon::Int`
"""
struct JapanFiscalHandoffCase
    case_id::String
    purpose::String
    tags::Vector{Symbol}
    scenario::JapanFiscalScenario
    model::Symbol
    horizon::Int

    function JapanFiscalHandoffCase(;
        case_id::AbstractString,
        scenario::JapanFiscalScenario,
        model::Symbol,
        purpose::AbstractString,
        tags::Vector{Symbol} = Symbol[],
        horizon::Int = JAPAN_FISCAL_DEFAULT_HORIZON,
    )
        _jf_handoff_check_id("JapanFiscalHandoffCase.case_id", case_id)
        _jf_handoff_check_id("scenario_id", scenario.scenario_id)
        _jf_require_nonempty("JapanFiscalHandoffCase.purpose", purpose)
        _jf_check_subset(tags, JAPAN_FISCAL_HANDOFF_CASE_TAGS, "tags")
        _jf_check(model, JAPAN_FISCAL_CANDIDATE_MODELS, "model")
        horizon >= 1 || throw(
            ArgumentError("JapanFiscalHandoffCase.horizon は1以上（実値: $(horizon)）"),
        )
        return new(
            String(case_id),
            String(purpose),
            sort(unique(tags)),
            scenario,
            model,
            horizon,
        )
    end
end

# ===========================================================================
# case summary（index の要約。artifact から機械的に導出する）
# ===========================================================================

"""
    japan_fiscal_handoff_case_summary(artifact_dict) -> Dict{String,Any}

result / rejection artifact の dict（`to_dict` の出力、または JSON を読んだ plain dict）から
index の要約を導出する。要約は artifact の値の写しであり、新しい主張を追加しない
（`:direction_only` のセルでは timing 診断の値を載せない。数値系列そのものも載せない）。
"""
function japan_fiscal_handoff_case_summary(d::AbstractDict)
    kind = d["artifact_kind"]
    cov = d["coverage"]
    common = Dict{String, Any}(
        "artifact_kind" => kind,
        "family" => d["family"],
        "model" => d["model"],
        "scenario_id" => d["scenario_id"],
        "representability" => cov["representability"],
        "adoption" => cov["adoption"],
        "claim_level" => cov["claim_level"],
        "numeric_semantics" => cov["numeric_semantics"],
        "family_complete" => cov["family_complete"],
        "unsupported_concepts" => cov["unsupported_concepts"],
        "unsupported_outputs" => cov["unsupported_outputs"],
        "uncovered_channels" => cov["uncovered_channels"],
        "fre_context_identity" => d["fre_context_identity"],
    )
    if kind == "result"
        diag = d["diagnostics"]
        disp = d["assumption_disposition"]
        common["artifact_content_hash"] = d["result_content_hash"]
        common["result_shape"] = d["result_shape"]
        common["n_periods"] = length(d["periods"])
        common["variables"] = diag["variables"]
        common["direction"] = diag["direction"]
        common["has_timing_diagnostics"] = haskey(diag, "peak")
        common["explicit_concepts"] =
            [x["concept"] for x in disp if x["assumption_state"] == "explicit"]
        common["held_at_baseline_concepts"] =
            [x["concept"] for x in disp if x["model_input"] == "held_at_baseline"]
        common["explicit_not_accepted_concepts"] = [
            x["concept"] for x in disp if
            x["assumption_state"] == "explicit" && x["model_input"] == "not_accepted"
        ]
        common["has_funding_cost_legs"] = d["funding_cost_legs"] !== nothing
        common["warning_count"] = length(d["warnings"])
    elseif kind == "rejection"
        common["artifact_content_hash"] = d["rejection_content_hash"]
        common["rejection_code"] = d["rejection_code"]
        common["concepts"] = d["concepts"]
    else
        throw(
            ArgumentError(
                "japan_fiscal_handoff_case_summary: 未知の artifact_kind: $(repr(kind))",
            ),
        )
    end
    return common
end

# ===========================================================================
# negative artifacts（consumer の fail closed 検証用）
# ===========================================================================

function _jf_rehash!(d::Dict{String, Any})
    key = d["artifact_kind"] == "result" ? "result_content_hash" : "rejection_content_hash"
    d[key] = _japan_fiscal_artifact_content_hash(d, key)
    return d
end

"""
    japan_fiscal_handoff_negative_artifacts(source::JapanFiscalScenarioResult)
        -> Vector{NamedTuple{(:kind,:description,:artifact)}}

`source`（有効な result）から、`JAPAN_FISCAL_HANDOFF_NEGATIVE_KINDS` の各種類について 1 事実だけを
破った artifact dict を決定的に生成する。`source` は time_path の result で、必須概念の
`:applied` を少なくとも 1 つ持たなければならない（`:missing_assumption_presented_as_zero` の生成に
使う）。
"""
function japan_fiscal_handoff_negative_artifacts(source::JapanFiscalScenarioResult)
    base = _jf_json_to_plain(JSON3.read(String(canonical_json_bytes(to_dict(source)))))
    source.result_shape === :time_path || throw(
        ArgumentError(
            "negative artifact の source は result_shape=:time_path の result でなければなりません",
        ),
    )
    out = NamedTuple{
        (:kind, :description, :artifact),
        Tuple{Symbol, String, Dict{String, Any}},
    }[]

    # content_hash_mismatch: 系列の値を書き換え、hash を据え置く
    let d = deepcopy(base)
        series = d["model_implied"]["scenario"]["series"]
        v = first(sort(collect(keys(series))))
        series[v][end] = series[v][end] + 1.0
        push!(
            out,
            (
                kind = :content_hash_mismatch,
                description = "model_implied.scenario.series.$(v) の最終値を書き換え、result_content_hash を据え置いた（改変・破損）。",
                artifact = d,
            ),
        )
    end

    # unsupported_schema_version: major を上げる（hash は再計算）
    let d = deepcopy(base)
        d["schema_version"] = "japan-fiscal-scenario-result/3.0.0"
        _jf_rehash!(d)
        push!(
            out,
            (
                kind = :unsupported_schema_version,
                description = "schema_version を未知の major（3.0.0）へ変えた。hash は再計算済みで、version だけが不正。",
                artifact = d,
            ),
        )
    end

    # missing_required_field: coverage を削除する（hash は再計算）
    let d = deepcopy(base)
        delete!(d, "coverage")
        _jf_rehash!(d)
        push!(
            out,
            (
                kind = :missing_required_field,
                description = "必須フィールド coverage を削除した。hash は再計算済み。",
                artifact = d,
            ),
        )
    end

    # claim_level_exceeds_contract: coverage を :magnitude / :japan_magnitude へ書き換える
    let d = deepcopy(base)
        d["coverage"]["claim_level"] = "magnitude"
        d["coverage"]["numeric_semantics"] = "japan_magnitude"
        _jf_rehash!(d)
        push!(
            out,
            (
                kind = :claim_level_exceeds_contract,
                description = "coverage.claim_level を magnitude・numeric_semantics を japan_magnitude へ書き換えた（日本の量としての提示）。hash は再計算済み。",
                artifact = d,
            ),
        )
    end

    # not_representable_presented_as_result: 同一 family の not_adopted セルの result を装う
    let d = deepcopy(base)
        target = first(
            m for m in japan_fiscal_model_mappings(; family = source.family) if
            m.representability === :not_representable
        )
        d["model"] = String(target.model)
        d["model_name"] = String(target.model)
        d["coverage"] = to_dict(japan_fiscal_coverage(target.family, target.model))
        _jf_rehash!(d)
        push!(
            out,
            (
                kind = :not_representable_presented_as_result,
                description = "not_representable セル（family=$(target.family), model=$(target.model)）を実行済み result として装った。coverage は registry どおり、hash は再計算済み。",
                artifact = d,
            ),
        )
    end

    # missing_assumption_presented_as_zero: 必須概念の assumption を取り除き baseline 保持として装う
    let d = deepcopy(base)
        idx = findfirst(
            x -> x["requirement"] == "required" && x["model_input"] == "applied",
            d["assumption_disposition"],
        )
        idx === nothing && throw(
            ArgumentError(
                "negative artifact の source は必須概念の :applied を持たなければなりません",
            ),
        )
        entry = d["assumption_disposition"][idx]
        concept = entry["concept"]
        aid = entry["assumption_id"]
        entry["assumption_state"] = "not_specified"
        entry["assumption_id"] = nothing
        entry["model_input"] = "held_at_baseline"
        d["applied_inputs"] = [x for x in d["applied_inputs"] if x["concept"] != concept]
        d["assumed"] = [x for x in d["assumed"] if x["assumption_id"] != aid]
        _jf_rehash!(d)
        push!(
            out,
            (
                kind = :missing_assumption_presented_as_zero,
                description = "必須概念 $(concept) の explicit assumption を取り除き、baseline 保持（変化 0）の result として装った。hash は再計算済み。",
                artifact = d,
            ),
        )
    end

    [x.kind for x in out] == collect(JAPAN_FISCAL_HANDOFF_NEGATIVE_KINDS) || error(
        "japan_fiscal_handoff_negative_artifacts: 生成順が JAPAN_FISCAL_HANDOFF_NEGATIVE_KINDS と一致しません",
    )
    return out
end

# ===========================================================================
# build（in-memory bundle）
# ===========================================================================

"bundle に含める機械可読契約（名前 => export 関数）。"
const _JF_HANDOFF_CONTRACTS = (
    ("capability_matrix", japan_fiscal_capability_matrix),
    ("downstream_contract", japan_fiscal_downstream_contract),
    ("scenario_schema_contract", japan_fiscal_scenario_schema_contract),
    ("result_artifact_contract", japan_fiscal_result_artifact_contract),
)

_jf_handoff_contract_versions() = Dict{String, Any}(
    "handoff" => JAPAN_FISCAL_HANDOFF_SCHEMA_VERSION,
    "result_artifact" => JAPAN_FISCAL_RESULT_ARTIFACT_SCHEMA_VERSION,
    "scenario_schema" => JAPAN_FISCAL_SCENARIO_SCHEMA_VERSION,
    "capability" => JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION,
    "claim" => JAPAN_FISCAL_CLAIM_CONTRACT_VERSION,
    "adapter" => JAPAN_FISCAL_ADAPTER_CONTRACT_VERSION,
)

_jf_handoff_json_schemas() = Dict{String, Any}(
    "handoff_index" => JAPAN_FISCAL_HANDOFF_JSON_SCHEMA,
    "result_artifact" => JAPAN_FISCAL_RESULT_ARTIFACT_JSON_SCHEMA,
    "scenario" => JAPAN_FISCAL_SCENARIO_JSON_SCHEMA,
)

"family 一覧（catalog の要約と 11 モデル分の representability）。registry から導出する。"
function _jf_handoff_families()
    return Any[
        Dict{String, Any}(
            "family" => String(f),
            "display_name" => japan_fiscal_family_spec(f).display_name,
            "required_concepts" => _jf_syms(japan_fiscal_family_spec(f).required_concepts),
            "optional_concepts" => _jf_syms(japan_fiscal_family_spec(f).optional_concepts),
            "implementation_candidates" =>
                _jf_syms(japan_fiscal_implementation_candidates(f)),
            "representability" => Dict{String, Any}(
                String(m.model) => String(m.representability) for
                m in japan_fiscal_model_mappings(; family = f)
            ),
        ) for f in JAPAN_FISCAL_SCENARIO_FAMILIES
    ]
end

_jf_sha256_bytes(bytes) = "sha256:" * bytes2hex(SHA.sha256(bytes))

"""
    build_japan_fiscal_handoff(cases; generated_at, negative_source_case_id=nothing)
        -> Dict{String,Any}

`cases` を実行し、bundle の全ファイルを `相対パス => JSON 値（Dict）` として返す（`"index.json"`
を含む）。ファイルを書かない。同一の `cases`・`generated_at` から常に同一の内容を返す。

`negative_source_case_id` を与えると、その case の result から negative artifact
（`JAPAN_FISCAL_HANDOFF_NEGATIVE_KINDS`）を生成して `negative/` に含める。
"""
function build_japan_fiscal_handoff(
    cases::Vector{JapanFiscalHandoffCase};
    generated_at::DateTime,
    negative_source_case_id::Union{AbstractString, Nothing} = nothing,
)
    isempty(cases) && throw(ArgumentError("build_japan_fiscal_handoff: cases が空です"))
    ids = [c.case_id for c in cases]
    length(unique(ids)) == length(ids) ||
        throw(ArgumentError("build_japan_fiscal_handoff: case_id が重複しています"))

    files = Dict{String, Any}()
    entry(path) = Dict{String, Any}(
        "path" => path,
        "sha256" => _jf_sha256_bytes(canonical_json_bytes(files[path])),
    )

    contracts = Any[]
    for (name, f) in _JF_HANDOFF_CONTRACTS
        path = "contracts/$(name).json"
        files[path] = f()
        push!(contracts, merge(Dict{String, Any}("name" => name), entry(path)))
    end

    # scenario: 同一 scenario_id は同一内容でなければならない
    scenario_by_id = Dict{String, JapanFiscalScenario}()
    for c in cases
        sid = c.scenario.scenario_id
        if haskey(scenario_by_id, sid)
            japan_fiscal_scenario_content_hash(scenario_by_id[sid]) ==
            japan_fiscal_scenario_content_hash(c.scenario) || throw(
                ArgumentError(
                    "build_japan_fiscal_handoff: scenario_id=$(sid) が異なる内容で複数回使われています",
                ),
            )
        else
            scenario_by_id[sid] = c.scenario
        end
    end
    scenarios = Any[]
    for sid in sort(collect(keys(scenario_by_id)))
        sc = scenario_by_id[sid]
        path = "scenarios/$(sid).json"
        files[path] = to_dict(sc)
        push!(
            scenarios,
            merge(
                Dict{String, Any}(
                    "scenario_id" => sid,
                    "family" => String(sc.family),
                    "name" => sc.name,
                    "scenario_content_hash" => japan_fiscal_scenario_content_hash(sc),
                    "assumption_set_hash" => japan_fiscal_assumption_set_hash(sc),
                    "fre_context_identity" =>
                        sc.fre_context === nothing ? nothing :
                        japan_fiscal_fre_context_identity(sc.fre_context),
                    "fre_regime_determination" =>
                        sc.fre_context === nothing ? nothing :
                        String(sc.fre_context.regime_determination),
                    "explicit_assumption_concepts" =>
                        sort([String(a.concept) for a in sc.assumptions]),
                ),
                entry(path),
            ),
        )
    end

    results = Dict{String, Any}()
    case_entries = Any[]
    for c in cases
        r = japan_fiscal_run(
            c.model,
            c.scenario;
            horizon = c.horizon,
            generated_at = generated_at,
        )
        results[c.case_id] = r
        path = "artifacts/$(c.case_id).json"
        files[path] = to_dict(r)
        push!(
            case_entries,
            merge(
                Dict{String, Any}(
                    "case_id" => c.case_id,
                    "purpose" => c.purpose,
                    "tags" => _jf_syms(c.tags),
                    "scenario_id" => c.scenario.scenario_id,
                    "model" => String(c.model),
                    "horizon" => c.horizon,
                    "summary" => japan_fiscal_handoff_case_summary(files[path]),
                ),
                entry(path),
            ),
        )
    end

    negatives = Any[]
    if negative_source_case_id !== nothing
        haskey(results, negative_source_case_id) || throw(
            ArgumentError(
                "build_japan_fiscal_handoff: negative_source_case_id=$(negative_source_case_id) が cases にありません",
            ),
        )
        src = results[negative_source_case_id]
        src isa JapanFiscalScenarioResult || throw(
            ArgumentError(
                "build_japan_fiscal_handoff: negative_source_case_id は result を返す case でなければなりません",
            ),
        )
        for n in japan_fiscal_handoff_negative_artifacts(src)
            path = "negative/$(n.kind).json"
            files[path] = n.artifact
            push!(
                negatives,
                merge(
                    Dict{String, Any}(
                        "name" => String(n.kind),
                        "expected_failure" => String(n.kind),
                        "source_case_id" => String(negative_source_case_id),
                        "description" => n.description,
                    ),
                    entry(path),
                ),
            )
        end
    end

    index = Dict{String, Any}(
        "schema_version" => JAPAN_FISCAL_HANDOFF_SCHEMA_VERSION,
        "artifact_kind" => "handoff_index",
        "producer" => Dict{String, Any}(
            "repository" => "Yuki-Watanabe7/DME",
            "component" => "japan_fiscal_scenario_lab",
        ),
        "contract_versions" => _jf_handoff_contract_versions(),
        "json_schemas" => _jf_handoff_json_schemas(),
        "families" => _jf_handoff_families(),
        "contracts" => contracts,
        "scenarios" => scenarios,
        "cases" => case_entries,
        "negative_artifacts" => negatives,
        "generated_at" => _jf_result_format_datetime(generated_at),
    )
    index["bundle_content_hash"] =
        _japan_fiscal_artifact_content_hash(index, "bundle_content_hash")
    files["index.json"] = index
    return files
end

"""
    write_japan_fiscal_handoff(dir, cases; generated_at, negative_source_case_id=nothing) -> String

`build_japan_fiscal_handoff` の結果を `dir` へ正準 JSON で書く。`dir` は存在してはならない
（上書きしない）。同じ親ディレクトリの一時ディレクトリへ全ファイルを書いてから `mv` で確定させる
（途中で失敗した bundle を残さない）。`dir` を返す。
"""
function write_japan_fiscal_handoff(
    dir::AbstractString,
    cases::Vector{JapanFiscalHandoffCase};
    generated_at::DateTime,
    negative_source_case_id::Union{AbstractString, Nothing} = nothing,
)
    ispath(dir) && throw(
        ArgumentError(
            "write_japan_fiscal_handoff: $(dir) は既に存在します（上書きしません）",
        ),
    )
    files = build_japan_fiscal_handoff(
        cases;
        generated_at = generated_at,
        negative_source_case_id = negative_source_case_id,
    )
    parent = dirname(abspath(dir))
    mkpath(parent)
    tmp = mktempdir(parent; prefix = ".jf-handoff-", cleanup = false)
    try
        for rel in sort(collect(keys(files)))
            _jf_atomic_write(
                joinpath(tmp, split(rel, '/')...),
                canonical_json_bytes(files[rel]),
            )
        end
        mv(tmp, dir; force = false)
    catch
        rm(tmp; recursive = true, force = true)
        rethrow()
    end
    return dir
end

# ===========================================================================
# load（fail closed）
# ===========================================================================

"""
    JapanFiscalHandoffBundle

`load_japan_fiscal_handoff` の戻り値。ディレクトリの位置に依存しない（絶対パスを保持しない）。

## フィールド
- `index::Dict{String,Any}`
- `scenarios::Dict{String,JapanFiscalScenario}` : scenario_id => scenario
- `artifacts::Dict{String,Union{JapanFiscalScenarioResult,JapanFiscalScenarioRejection}}` : case_id => artifact
- `artifact_dicts::Dict{String,Dict{String,Any}}` : case_id => 保存済み artifact の plain dict
- `contracts::Dict{String,Dict{String,Any}}` : 契約名 => export
- `negative_errors::Dict{String,String}` : negative artifact 名 => DME decoder の拒否メッセージ
"""
struct JapanFiscalHandoffBundle
    index::Dict{String, Any}
    scenarios::Dict{String, JapanFiscalScenario}
    artifacts::Dict{String, Union{JapanFiscalScenarioResult, JapanFiscalScenarioRejection}}
    artifact_dicts::Dict{String, Dict{String, Any}}
    contracts::Dict{String, Dict{String, Any}}
    negative_errors::Dict{String, String}
end

function _jf_handoff_read(dir::AbstractString, entry::AbstractDict, label::AbstractString)
    rel = _jf_as_string(entry["path"], "$(label).path")
    (startswith(rel, "/") || occursin("..", rel) || occursin('\\', rel)) && throw(
        ArgumentError(
            "$(label): path は bundle 内の相対パスでなければなりません（実値: $(rel)）",
        ),
    )
    path = joinpath(dir, split(rel, '/')...)
    isfile(path) || throw(ArgumentError("$(label): ファイルがありません: $(rel)"))
    bytes = read(path)
    got = _jf_sha256_bytes(bytes)
    got == entry["sha256"] || throw(
        ArgumentError(
            "$(label): $(rel) の SHA-256 が index と一致しません（index: $(entry["sha256"])、実値: $(got)）",
        ),
    )
    return rel, _jf_json_to_plain(JSON3.read(String(bytes)))
end

"case の tags が artifact / scenario の内容と整合することを検査する。"
function _jf_handoff_check_tags(
    case_id::AbstractString,
    tags,
    d::AbstractDict,
    scenario::JapanFiscalScenario,
    variant_ok::Bool,
)
    kind = d["artifact_kind"]
    cov = d["coverage"]
    check(cond, tag) =
        cond || throw(
            ArgumentError(
                "handoff case $(case_id): tag $(tag) が artifact / scenario の内容と整合しません",
            ),
        )
    for tag in tags
        if tag == "representable"
            check(kind == "result" && cov["representability"] == "representable", tag)
        elseif tag == "partial"
            check(kind == "result" && cov["representability"] == "partial", tag)
        elseif tag == "not_representable"
            check(
                kind == "rejection" &&
                    d["rejection_code"] == "not_adopted" &&
                    cov["representability"] == "not_representable",
                tag,
            )
        elseif tag == "partial_not_adopted"
            check(
                kind == "rejection" &&
                    d["rejection_code"] == "not_adopted" &&
                    cov["representability"] == "partial",
                tag,
            )
        elseif tag in ("missing_required_assumption", "conversion_not_implemented")
            check(kind == "rejection" && d["rejection_code"] == tag, tag)
        elseif tag == "missing_fre_context"
            check(
                scenario.fre_context === nothing && d["fre_context_identity"] === nothing,
                tag,
            )
        elseif tag == "fre_unavailable"
            check(
                scenario.fre_context !== nothing &&
                    scenario.fre_context.regime_determination === :unavailable,
                tag,
            )
        elseif tag == "fre_context_variant"
            check(variant_ok, tag)
        elseif tag == "explicit_zero_assumption"
            check(any(a -> a.magnitude == 0.0, scenario.assumptions), tag)
        elseif tag == "optional_concept_held_at_baseline"
            check(
                kind == "result" && any(
                    x ->
                        x["requirement"] == "optional" &&
                        x["model_input"] == "held_at_baseline",
                    d["assumption_disposition"],
                ),
                tag,
            )
        elseif tag == "explicit_assumption_not_accepted"
            check(
                kind == "result" && any(
                    x ->
                        x["assumption_state"] == "explicit" &&
                        x["model_input"] == "not_accepted",
                    d["assumption_disposition"],
                ),
                tag,
            )
        else
            throw(ArgumentError("handoff case $(case_id): 未知の tag $(repr(tag))"))
        end
    end
    return nothing
end

const _JF_HANDOFF_INDEX_KEYS = (
    "schema_version",
    "artifact_kind",
    "producer",
    "contract_versions",
    "json_schemas",
    "families",
    "contracts",
    "scenarios",
    "cases",
    "negative_artifacts",
    "generated_at",
    "bundle_content_hash",
)

"""
    load_japan_fiscal_handoff(dir) -> JapanFiscalHandoffBundle

bundle を fail closed で読む。次のいずれかが崩れれば `ArgumentError`:

- index のキー集合・`schema_version`・`artifact_kind`・`bundle_content_hash`・`contract_versions`・
  `json_schemas`・`families`（registry からの再導出と一致）
- 列挙された各ファイルの存在・SHA-256・bundle 内相対パス。列挙されていないファイル（隠しファイルを除く）が無いこと
- 契約 export が現在の DME の export と一致すること
- scenario の fail closed decode（hash 検査を含む）と index の scenario 要約の一致
- 各 case の artifact の fail closed decode・scenario との identity 連結（scenario_content_hash・
  assumption_set_hash・fre_context_identity・model・horizon）・要約（`japan_fiscal_handoff_case_summary`）
  の一致・tags の整合
- not_representable セルが result として含まれていないこと・`claim_level = :magnitude` が無いこと（H-13）
- negative artifact が DME の decoder で**拒否される**こと
"""
function load_japan_fiscal_handoff(dir::AbstractString)::JapanFiscalHandoffBundle
    index_path = joinpath(dir, "index.json")
    isfile(index_path) ||
        throw(ArgumentError("load_japan_fiscal_handoff: index.json がありません"))
    index = _jf_json_to_plain(JSON3.read(read(index_path, String)))
    _jf_check_keys("handoff index", index, _JF_HANDOFF_INDEX_KEYS)
    index["schema_version"] == JAPAN_FISCAL_HANDOFF_SCHEMA_VERSION || throw(
        ArgumentError(
            "handoff index: 未対応の schema_version です（受理: $(JAPAN_FISCAL_HANDOFF_SCHEMA_VERSION)、実値: $(index["schema_version"])）",
        ),
    )
    index["artifact_kind"] == "handoff_index" || throw(
        ArgumentError(
            "handoff index: artifact_kind は \"handoff_index\" でなければなりません",
        ),
    )
    _jf_check_content_hash("handoff index", index, "bundle_content_hash")
    canonical_json_bytes(index["contract_versions"]) ==
    canonical_json_bytes(_jf_handoff_contract_versions()) || throw(
        ArgumentError(
            "handoff index: contract_versions が現在の DME の契約 version と一致しません",
        ),
    )
    canonical_json_bytes(index["json_schemas"]) ==
    canonical_json_bytes(_jf_handoff_json_schemas()) ||
        throw(ArgumentError("handoff index: json_schemas が現在の契約と一致しません"))
    canonical_json_bytes(index["families"]) ==
    canonical_json_bytes(_jf_handoff_families()) || throw(
        ArgumentError("handoff index: families が #274 registry からの導出と一致しません"),
    )

    listed = Set{String}(["index.json"])

    contracts = Dict{String, Dict{String, Any}}()
    expected_contracts = Dict(name => f for (name, f) in _JF_HANDOFF_CONTRACTS)
    Set(c["name"] for c in index["contracts"]) == Set(keys(expected_contracts)) ||
        throw(ArgumentError("handoff index: contracts の集合が契約と一致しません"))
    for c in index["contracts"]
        rel, body = _jf_handoff_read(dir, c, "contracts[$(c["name"])]")
        push!(listed, rel)
        canonical_json_bytes(body) ==
        canonical_json_bytes(expected_contracts[c["name"]]()) || throw(
            ArgumentError(
                "handoff contracts[$(c["name"])]: 現在の DME の export と一致しません（bundle が古い）",
            ),
        )
        contracts[c["name"]] = body
    end

    scenarios = Dict{String, JapanFiscalScenario}()
    for s in index["scenarios"]
        sid = _jf_as_string(s["scenario_id"], "scenarios[].scenario_id")
        haskey(scenarios, sid) &&
            throw(ArgumentError("handoff index: scenario_id=$(sid) が重複しています"))
        rel, body = _jf_handoff_read(dir, s, "scenarios[$(sid)]")
        push!(listed, rel)
        sc = japan_fiscal_scenario_from_dict(body)
        sc.scenario_id == sid || throw(
            ArgumentError(
                "handoff scenarios[$(sid)]: scenario_id がファイルと一致しません",
            ),
        )
        (
            s["family"] == String(sc.family) &&
            s["name"] == sc.name &&
            s["scenario_content_hash"] == japan_fiscal_scenario_content_hash(sc) &&
            s["assumption_set_hash"] == japan_fiscal_assumption_set_hash(sc) &&
            s["fre_context_identity"] == (
                sc.fre_context === nothing ? nothing :
                japan_fiscal_fre_context_identity(sc.fre_context)
            ) &&
            s["fre_regime_determination"] == (
                sc.fre_context === nothing ? nothing :
                String(sc.fre_context.regime_determination)
            ) &&
            s["explicit_assumption_concepts"] ==
            sort([String(a.concept) for a in sc.assumptions])
        ) || throw(
            ArgumentError(
                "handoff scenarios[$(sid)]: index の要約が scenario と一致しません",
            ),
        )
        scenarios[sid] = sc
    end

    artifacts =
        Dict{String, Union{JapanFiscalScenarioResult, JapanFiscalScenarioRejection}}()
    artifact_dicts = Dict{String, Dict{String, Any}}()
    for c in index["cases"]
        cid = _jf_as_string(c["case_id"], "cases[].case_id")
        haskey(artifacts, cid) &&
            throw(ArgumentError("handoff index: case_id=$(cid) が重複しています"))
        rel, body = _jf_handoff_read(dir, c, "cases[$(cid)]")
        push!(listed, rel)
        a = japan_fiscal_artifact_from_dict(body)
        sid = c["scenario_id"]
        haskey(scenarios, sid) || throw(
            ArgumentError(
                "handoff cases[$(cid)]: scenario_id=$(sid) が scenarios にありません",
            ),
        )
        sc = scenarios[sid]
        (
            a.scenario_id == sid &&
            a.scenario_content_hash == japan_fiscal_scenario_content_hash(sc) &&
            a.assumption_set_hash == japan_fiscal_assumption_set_hash(sc) &&
            a.fre_context_identity == (
                sc.fre_context === nothing ? nothing :
                japan_fiscal_fre_context_identity(sc.fre_context)
            ) &&
            a.family === sc.family &&
            String(a.model) == c["model"] &&
            a.horizon == c["horizon"]
        ) || throw(
            ArgumentError(
                "handoff cases[$(cid)]: artifact の scenario / model / horizon identity が index・scenario と一致しません",
            ),
        )
        canonical_json_bytes(c["summary"]) ==
        canonical_json_bytes(japan_fiscal_handoff_case_summary(body)) || throw(
            ArgumentError(
                "handoff cases[$(cid)]: index の summary が artifact から導出した値と一致しません",
            ),
        )
        a.coverage.claim_level === :magnitude && throw(
            ArgumentError(
                "handoff cases[$(cid)]: claim_level=:magnitude の artifact は含められません（H-13）",
            ),
        )
        a isa JapanFiscalScenarioResult &&
            a.coverage.representability === :not_representable &&
            throw(
                ArgumentError(
                    "handoff cases[$(cid)]: not_representable セルを result として含めています",
                ),
            )
        artifacts[cid] = a
        artifact_dicts[cid] = body
    end

    # tags（fre_context_variant は同一 model・同一 assumption 集合で FRE identity が異なる case の存在）
    for c in index["cases"]
        cid = c["case_id"]
        a = artifacts[cid]
        variant_ok = any(
            other ->
                other["case_id"] != cid &&
                other["model"] == c["model"] &&
                artifacts[other["case_id"]].assumption_set_hash == a.assumption_set_hash &&
                artifacts[other["case_id"]].fre_context_identity != a.fre_context_identity,
            index["cases"],
        )
        _jf_handoff_check_tags(
            cid,
            c["tags"],
            artifact_dicts[cid],
            scenarios[c["scenario_id"]],
            variant_ok,
        )
    end

    negative_errors = Dict{String, String}()
    for n in index["negative_artifacts"]
        name = _jf_as_string(n["name"], "negative_artifacts[].name")
        Symbol(n["expected_failure"]) in JAPAN_FISCAL_HANDOFF_NEGATIVE_KINDS || throw(
            ArgumentError(
                "handoff negative_artifacts[$(name)]: 未知の expected_failure $(repr(n["expected_failure"]))",
            ),
        )
        haskey(artifacts, n["source_case_id"]) || throw(
            ArgumentError(
                "handoff negative_artifacts[$(name)]: source_case_id が cases にありません",
            ),
        )
        rel, body = _jf_handoff_read(dir, n, "negative_artifacts[$(name)]")
        push!(listed, rel)
        msg = try
            japan_fiscal_artifact_from_dict(body)
            nothing
        catch e
            e isa ArgumentError || rethrow()
            e.msg
        end
        msg === nothing && throw(
            ArgumentError(
                "handoff negative_artifacts[$(name)]: negative artifact が DME の decoder に受理されました（fail closed 違反）",
            ),
        )
        negative_errors[name] = msg
    end

    # 隠しファイル（`.DS_Store` 等の OS / エディタの生成物）は bundle の内容として扱わない
    present = Set{String}()
    for (root, _, fs) in walkdir(dir)
        for f in fs
            startswith(f, ".") && continue
            push!(present, join(splitpath(relpath(joinpath(root, f), dir)), "/"))
        end
    end
    unlisted = sort(collect(setdiff(present, listed)))
    isempty(unlisted) || throw(
        ArgumentError(
            "load_japan_fiscal_handoff: index に列挙されていないファイルがあります: $(unlisted)",
        ),
    )

    return JapanFiscalHandoffBundle(
        index,
        scenarios,
        artifacts,
        artifact_dicts,
        contracts,
        negative_errors,
    )
end

# ===========================================================================
# replay
# ===========================================================================

"""
    JapanFiscalReplayReport

`replay_japan_fiscal_handoff_case` の結果。

## フィールド
- `case_id::String` / `artifact_kind::Symbol`
- `saved_content_hash::String` / `replayed_content_hash::String`
- `exact_match::Bool` : content hash が完全一致した（同一プラットフォーム・同一依存での再現）
- `within_tolerance::Bool` : 数値以外が完全一致し、数値が許容誤差内で一致した（replay 成立）
- `max_abs_diff::Float64` : 数値フィールドの最大絶対差
- `mismatches::Vector{String}` : 不一致の位置（`within_tolerance = false` の理由）
"""
struct JapanFiscalReplayReport
    case_id::String
    artifact_kind::Symbol
    saved_content_hash::String
    replayed_content_hash::String
    exact_match::Bool
    within_tolerance::Bool
    max_abs_diff::Float64
    mismatches::Vector{String}
end

_jf_is_number(x) = x isa Real && !(x isa Bool)

function _jf_compare_json!(
    a,
    b,
    path::String,
    rtol::Float64,
    atol::Float64,
    mismatches::Vector{String},
    maxdiff::Base.RefValue{Float64},
)
    if _jf_is_number(a) && _jf_is_number(b)
        fa = Float64(a)
        fb = Float64(b)
        diff = abs(fa - fb)
        isfinite(diff) && (maxdiff[] = max(maxdiff[], diff))
        isapprox(fa, fb; rtol = rtol, atol = atol) ||
            push!(mismatches, "$(path): $(fa) != $(fb)")
    elseif a isa AbstractDict && b isa AbstractDict
        ka = Set(String.(keys(a)))
        kb = Set(String.(keys(b)))
        ka == kb ||
            push!(mismatches, "$(path): キー集合が異なる $(sort(collect(symdiff(ka, kb))))")
        for k in sort(collect(intersect(ka, kb)))
            _jf_compare_json!(a[k], b[k], "$(path).$(k)", rtol, atol, mismatches, maxdiff)
        end
    elseif a isa AbstractVector && b isa AbstractVector
        length(a) == length(b) ||
            push!(mismatches, "$(path): 長さが異なる $(length(a)) != $(length(b))")
        for i in 1:min(length(a), length(b))
            _jf_compare_json!(a[i], b[i], "$(path)[$(i)]", rtol, atol, mismatches, maxdiff)
        end
    else
        isequal(a, b) || push!(mismatches, "$(path): $(repr(a)) != $(repr(b))")
    end
    return nothing
end

"""
    replay_japan_fiscal_handoff_case(bundle, case_id; rtol=1e-9, atol=1e-12) -> JapanFiscalReplayReport

bundle に保存された scenario（`scenarios/<scenario_id>.json`）から、case の `model`・`horizon`・
保存済み artifact の `generated_at` で `japan_fiscal_run` を再実行し、保存済み artifact と比較する。
content hash 以外のすべてのフィールドを比較し、数値は `isapprox(rtol, atol)`、それ以外は完全一致を
要求する（`within_tolerance`）。hash の完全一致は `exact_match` として別に報告する。
bundle の元ディレクトリも FRE / 外部データも必要としない。
"""
function replay_japan_fiscal_handoff_case(
    bundle::JapanFiscalHandoffBundle,
    case_id::AbstractString;
    rtol::Float64 = 1e-9,
    atol::Float64 = 1e-12,
)
    idx = findfirst(c -> c["case_id"] == case_id, bundle.index["cases"])
    idx === nothing &&
        throw(ArgumentError("replay: case_id=$(case_id) が bundle にありません"))
    c = bundle.index["cases"][idx]
    saved = bundle.artifact_dicts[case_id]
    scenario = bundle.scenarios[c["scenario_id"]]
    rerun = japan_fiscal_run(
        Symbol(c["model"]),
        scenario;
        horizon = Int(c["horizon"]),
        generated_at = _jf_as_datetime(saved["generated_at"], "generated_at"),
    )
    replayed = _jf_json_to_plain(JSON3.read(String(canonical_json_bytes(to_dict(rerun)))))
    kind = Symbol(saved["artifact_kind"])
    hash_key = kind === :result ? "result_content_hash" : "rejection_content_hash"
    replayed["artifact_kind"] == saved["artifact_kind"] || return JapanFiscalReplayReport(
        String(case_id),
        kind,
        saved[hash_key],
        get(replayed, "result_content_hash", get(replayed, "rejection_content_hash", "")),
        false,
        false,
        NaN,
        ["artifact_kind: $(saved["artifact_kind"]) != $(replayed["artifact_kind"])"],
    )
    mismatches = String[]
    maxdiff = Ref(0.0)
    strip_hash(d) = Dict{String, Any}(k => v for (k, v) in d if k != hash_key)
    _jf_compare_json!(
        strip_hash(saved),
        strip_hash(replayed),
        "\$",
        rtol,
        atol,
        mismatches,
        maxdiff,
    )
    return JapanFiscalReplayReport(
        String(case_id),
        kind,
        saved[hash_key],
        replayed[hash_key],
        saved[hash_key] == replayed[hash_key],
        isempty(mismatches),
        maxdiff[],
        mismatches,
    )
end
