# cross_model_input.jl: 上流モデル由来入力 `ModelDerivedInput`（`X4`）の型・構築・シリアライズ
# （Issue #282 / `PN-2`）。
#
# `ModelDerivedInput` は event 由来の `ScenarioAssumption`（`L3`）と同じ位置に置く**出自の異なる
# 兄弟型**であり、`AbstractMacroEvent` の subtype にしない（`map_event`・`validate_event`・
# `observed_events.json` の経路へ入らないことを型で担保する。設計 `UM-1`・ADR 0024 決定 1）。
# 構築経路は accepted な compatibility report を経た `build_model_derived_inputs` を基本とする
# （設計 `UM-4`）。モデル固有の変換（`X5`）は `adapters/capex_credit_cycle_cross_model_adapter.jl`、
# 実行・保存・replay（`X6`/`X7`）は `cross_model_runner.jl` が担う。
#
# 設計契約:
#   docs/architecture/pne_sector_output_integration.md §3.3・§9.5・§9.6・§12.2
#   docs/adr/0024-pne-sector-output-cross-model-input-contract.md 決定 1・2・13

# ===========================================================================
# 語彙
# ===========================================================================

"`ModelDerivedInput.input_origin` の固定値（設計 §3.2）。"
const MODEL_DERIVED_INPUT_ORIGIN = :upstream_model_derived

"`ModelDerivedInput.input_id` の必須接頭辞（event 由来の ID と名前空間を分ける、設計 §10.4）。"
const MODEL_DERIVED_INPUT_ID_PREFIX = "xm-"

"`ModelDerivedInput` の配置基準（設計 §9.5。`Scenario.period_zero` の有無と一致しなければならない）。"
const MODEL_DERIVED_INPUT_TIMING_BASES = (:calendar, :period)

"PNE horizon 後の扱い（v1 は回復済みのみ、設計 §9.6）。"
const MODEL_DERIVED_INPUT_POST_HORIZON = :recovered_at_source_horizon_end

"target concept ごとに許される値の意味（設計 §8.3）。"
const _MODEL_DERIVED_CONCEPT_SEMANTICS = (
    :derived_out_of_model_demand => :target_relative_change,
    :sector_supply_capacity => :group_realized_output_ratio,
    :aggregate_realized_output => :group_realized_output_ratio,
)

_model_derived_fail(msg::AbstractString) =
    throw(ArgumentError("invalid_model_derived_input: $(msg)"))

function _model_derived_expected_semantics(concept::Symbol)
    for p in _MODEL_DERIVED_CONCEPT_SEMANTICS
        first(p) === concept && return last(p)
    end
    return nothing
end

# ===========================================================================
# ModelDerivedInput
# ===========================================================================

"""
    ModelDerivedInput

上流モデル（PNE）由来の、特定 DME モデル向けに mapping 済みの入力（設計 §3.3、`X4`）。
`values[k]` は DME 四半期 `k = 0 … Q-1` の値（意味は `value_semantics`。CCC の派生需要では
target 変数の baseline に対する相対変化 `−Σ w_j (1 − r_j)`）。

時間軸への配置（設計 §9.5）は `timing_basis` で宣言し、実行時に `Scenario.period_zero` の有無と
照合する（不一致は `timing_basis_conflict`）。
- `:calendar`: `anchor_quarter` 必須・`t_start` は `nothing`。`t0 = quarter_index(anchor_quarter, period_zero)`。
- `:period`: `t_start` 必須（`anchor_quarter` は保持してよいが配置に使わない）。

構築時に検査する（層(1)）: `input_id` の `"xm-"` 接頭辞・`values` の有限性と非空・
`value_semantics` と `target_concept` の整合・`:target_relative_change` の値が `[-1, 0]`・
語彙・hash の形式・配置基準の整合。

**`AbstractMacroEvent` の subtype ではない**（設計 `UM-1`）。
"""
struct ModelDerivedInput
    input_id::String
    input_origin::Symbol
    upstream::UpstreamModelArtifactRef
    mapping_id::String
    mapping_version::String
    mapping_hash::String
    compatibility_report_hash::String
    target_model::Symbol
    target_concept::Symbol
    target_group::Symbol
    value_semantics::Symbol
    values::Vector{Float64}
    timing_basis::Symbol
    anchor_quarter::Union{CalendarQuarter, Nothing}
    t_start::Union{Int, Nothing}
    post_horizon::Symbol
    transmission_mode::Symbol
    claim_scope::Symbol
    coverage::Dict{String, Any}
    notes::String

    function ModelDerivedInput(;
        input_id::AbstractString,
        upstream::UpstreamModelArtifactRef,
        mapping_id::AbstractString,
        mapping_version::AbstractString,
        mapping_hash::AbstractString,
        compatibility_report_hash::AbstractString,
        target_model::Symbol,
        target_concept::Symbol,
        target_group::Symbol,
        value_semantics::Symbol,
        values::Vector{Float64},
        timing_basis::Symbol,
        transmission_mode::Symbol,
        claim_scope::Symbol,
        coverage::Dict{String, Any},
        anchor_quarter::Union{CalendarQuarter, Nothing} = nothing,
        t_start::Union{Int, Nothing} = nothing,
        post_horizon::Symbol = MODEL_DERIVED_INPUT_POST_HORIZON,
        input_origin::Symbol = MODEL_DERIVED_INPUT_ORIGIN,
        notes::AbstractString = "",
    )
        startswith(input_id, MODEL_DERIVED_INPUT_ID_PREFIX) &&
        length(input_id) > length(MODEL_DERIVED_INPUT_ID_PREFIX) || _model_derived_fail(
            "input_id=\"$(input_id)\" は \"xm-\" で始まらなければなりません（設計 §10.4）",
        )
        input_origin === MODEL_DERIVED_INPUT_ORIGIN || _model_derived_fail(
            "input_origin は :upstream_model_derived でなければなりません",
        )
        isempty(mapping_id) && _model_derived_fail("mapping_id は空であってはいけません")
        isempty(mapping_version) &&
            _model_derived_fail("mapping_version は空であってはいけません")
        for (label, h) in (
            ("mapping_hash", mapping_hash),
            ("compatibility_report_hash", compatibility_report_hash),
        )
            occursin(_PNE_HASH_PATTERN, h) || _model_derived_fail(
                "$(label) は \"sha256:\" + 64桁の小文字16進でなければなりません",
            )
        end
        expected = _model_derived_expected_semantics(target_concept)
        expected === nothing && _model_derived_fail(
            "target_concept=$(target_concept) は $(collect(CROSS_MODEL_TARGET_CONCEPTS)) のいずれかでなければなりません",
        )
        value_semantics === expected || _model_derived_fail(
            "target_concept=$(target_concept) の value_semantics は $(expected) でなければなりません" *
            "（実値: $(value_semantics)。設計 §8.3）",
        )
        isempty(values) && _model_derived_fail("values は空であってはいけません")
        all(isfinite, values) || _model_derived_fail("values は有限でなければなりません")
        if value_semantics === :target_relative_change
            all(v -> -1.0 - PNE_RATIO_ABS_TOL <= v <= 0.0, values) || _model_derived_fail(
                "target_relative_change の values は [-1, 0] に含まれなければなりません（符号規約 non_positive、設計 §7.4）",
            )
        else
            all(v -> 0.0 <= v <= 1.0, values) || _model_derived_fail(
                "group_realized_output_ratio の values は [0, 1] に含まれなければなりません",
            )
        end
        timing_basis in MODEL_DERIVED_INPUT_TIMING_BASES || _model_derived_fail(
            "timing_basis は :calendar / :period のいずれかでなければなりません",
        )
        if timing_basis === :calendar
            anchor_quarter === nothing && throw(
                ArgumentError(
                    "calendar_anchor_required: timing_basis=:calendar の入力 $(input_id) には " *
                    "anchor_quarter が必須です（PNE artifact に calendar_anchor がありません。設計 §9.5）",
                ),
            )
            t_start === nothing || _model_derived_fail(
                "timing_basis=:calendar の入力に t_start を指定できません（配置は anchor から導く。設計 §9.5）",
            )
        else
            t_start === nothing && _model_derived_fail(
                "timing_basis=:period の入力には t_start（PNE 期 0 を置くモデル期）が必須です（設計 §9.5）",
            )
        end
        post_horizon === MODEL_DERIVED_INPUT_POST_HORIZON || _model_derived_fail(
            "post_horizon は :recovered_at_source_horizon_end のみ受理します（設計 §9.6）",
        )
        transmission_mode in CROSS_MODEL_TRANSMISSION_MODES ||
            _model_derived_fail("transmission_mode=$(transmission_mode) は未知の値です")
        transmission_mode === :explicit_cross_economy && _model_derived_fail(
            "transmission_mode=:explicit_cross_economy の入力は v1 では受理されません（設計 §6.4）",
        )
        claim_scope in CROSS_MODEL_CLAIM_SCOPES ||
            _model_derived_fail("claim_scope=$(claim_scope) は未知の値です")
        expected_scope =
            transmission_mode === :same_economy ? :same_economy_model_derived :
            :hypothetical_fictional
        claim_scope === expected_scope || _model_derived_fail(
            "transmission_mode=$(transmission_mode) の claim_scope は $(expected_scope) でなければなりません（設計 §13）",
        )
        return new(
            String(input_id),
            input_origin,
            upstream,
            String(mapping_id),
            String(mapping_version),
            String(mapping_hash),
            String(compatibility_report_hash),
            target_model,
            target_concept,
            target_group,
            value_semantics,
            copy(values),
            timing_basis,
            anchor_quarter,
            t_start,
            post_horizon,
            transmission_mode,
            claim_scope,
            coverage,
            String(notes),
        )
    end
end

# ===========================================================================
# 構築（X4）
# ===========================================================================

"""
    build_model_derived_inputs(artifact::PNESectorOutputPath, mapping::CrossModelMapping,
                               report::CrossModelCompatibilityReport;
                               timing_basis::Symbol, t_start = nothing,
                               input_id_base::AbstractString = mapping.mapping_id)
        -> Vector{ModelDerivedInput}

accepted な compatibility report に限り、`apply_cross_model_mapping`（`X3`）の結果から target
group ごとの `ModelDerivedInput` を構築する（`X4`、設計 §4）。`report` の検証（accepted・
再計算した report との hash 一致）は `apply_cross_model_mapping` が行う。

- `timing_basis = :calendar`: PNE の `calendar_anchor` から配置する（`t_start` は指定しない）。
  anchor の無い artifact では `calendar_anchor_required` の `ArgumentError`。
- `timing_basis = :period`: `t_start`（PNE 期 0 を置くモデル期）を明示する。anchor は保持するが
  配置には使わない。

`input_id` は `"xm-" * input_id_base * ":" * target_group`。戻り値は `target_group` 昇順。
`coverage` には member・有効 weight・producer set・被覆率・unmapped source sector を記録する
（「PNE shock が DME のどの入力に変換されたか」の診断用、#282 Scope 6）。
"""
function build_model_derived_inputs(
    a::PNESectorOutputPath,
    m::CrossModelMapping,
    r::CrossModelCompatibilityReport;
    timing_basis::Symbol,
    t_start::Union{Int, Nothing} = nothing,
    input_id_base::AbstractString = m.mapping_id,
)
    paths = apply_cross_model_mapping(a, m, r)
    inputs = ModelDerivedInput[]
    for p in paths
        coverage = Dict{String, Any}(
            "members" => copy(p.members),
            "effective_weights" => copy(p.effective_weights),
            "producer_set" => copy(p.producer_set),
            "covered_share" => p.covered_share,
            "uncovered_share" => p.uncovered_share,
            "uncovered_share_treatment" =>
                String(CROSS_MODEL_UNCOVERED_SHARE_TREATMENT),
            "unmapped_source_sectors" => copy(r.unmapped_source_sectors),
            "source_period_unit" => String(p.source_period_unit),
            "aggregation_rule" => String(p.aggregation_rule),
        )
        push!(
            inputs,
            ModelDerivedInput(;
                input_id = MODEL_DERIVED_INPUT_ID_PREFIX *
                           String(input_id_base) *
                           ":" *
                           String(p.target_group),
                upstream = r.upstream,
                mapping_id = p.mapping_id,
                mapping_version = p.mapping_version,
                mapping_hash = p.mapping_hash,
                compatibility_report_hash = p.compatibility_report_hash,
                target_model = p.target_model,
                target_concept = p.target_concept,
                target_group = p.target_group,
                value_semantics = p.value_semantics,
                values = p.values,
                timing_basis = timing_basis,
                anchor_quarter = p.anchor_quarter,
                t_start = t_start,
                transmission_mode = p.transmission_mode,
                claim_scope = p.claim_scope,
                coverage = coverage,
            ),
        )
    end
    return inputs
end

# ===========================================================================
# シリアライズ・hash（設計 §12.2・§12.4）
# ===========================================================================

"""
    upstream_artifact_ref_from_dict(d::AbstractDict) -> UpstreamModelArtifactRef

`upstream_artifact_ref_to_dict` の逆変換（fail closed: 必須キー欠落・未知キーは `ArgumentError`）。
`source_bytes_sha256` は省略可（`include_audit = false` で書いた dict）。
"""
function upstream_artifact_ref_from_dict(d::AbstractDict)
    keys_ = (
        "producer",
        "producer_version",
        "exporter_version",
        "algorithm_versions",
        "contract_version",
        "artifact_id",
        "content_hash",
        "network_id",
        "source_input_hash",
        "dynamic_artifact_id",
        "dynamic_artifact_hash",
        "scenario_hash",
        "scenario_policy_hash",
        "scenario_config_hash",
        "export_config_hash",
        "geography",
        "classification",
        "is_synthetic",
        "network_as_of",
        "node_estimation_status_counts",
        "edge_estimation_status_counts",
        "result_role",
    )
    present = Set(String(k) for k in keys(d))
    missing_keys = sort([k for k in keys_ if !(k in present)])
    unknown = sort([k for k in present if !(k in keys_) && k != "source_bytes_sha256"])
    (isempty(missing_keys) && isempty(unknown)) ||
        _model_derived_fail("upstream の必須キー欠落 $(missing_keys)・未知キー $(unknown)")
    d["result_role"] == String(UPSTREAM_MODEL_DERIVED_RESULT_ROLE) || _model_derived_fail(
        "upstream.result_role は upstream_model_derived_endogenous_result でなければなりません",
    )
    counts(c) = Dict{Symbol, Int}(Symbol(String(k)) => Int(v) for (k, v) in c)
    return UpstreamModelArtifactRef(
        String(d["producer"]),
        String(d["producer_version"]),
        String(d["exporter_version"]),
        Dict{String, String}(String(k) => String(v) for (k, v) in d["algorithm_versions"]),
        String(d["contract_version"]),
        String(d["artifact_id"]),
        String(d["content_hash"]),
        get(d, "source_bytes_sha256", nothing) === nothing ? nothing :
        String(d["source_bytes_sha256"]),
        String(d["network_id"]),
        String(d["source_input_hash"]),
        String(d["dynamic_artifact_id"]),
        String(d["dynamic_artifact_hash"]),
        String(d["scenario_hash"]),
        String(d["scenario_policy_hash"]),
        String(d["scenario_config_hash"]),
        String(d["export_config_hash"]),
        String(d["geography"]["system"]),
        String(d["geography"]["economy_id"]),
        String(d["classification"]["system"]),
        String(d["classification"]["version"]),
        String(d["classification"]["level"]),
        Bool(d["is_synthetic"]),
        String(d["network_as_of"]),
        counts(d["node_estimation_status_counts"]),
        counts(d["edge_estimation_status_counts"]),
        UPSTREAM_MODEL_DERIVED_RESULT_ROLE,
    )
end

const _MODEL_DERIVED_INPUT_KEYS = (
    "input_id",
    "input_origin",
    "upstream",
    "mapping_id",
    "mapping_version",
    "mapping_hash",
    "compatibility_report_hash",
    "target_model",
    "target_concept",
    "target_group",
    "value_semantics",
    "values",
    "timing_basis",
    "anchor_quarter",
    "t_start",
    "post_horizon",
    "transmission_mode",
    "claim_scope",
    "coverage",
    "notes",
)

"""
    model_derived_input_to_dict(x::ModelDerivedInput; include_audit::Bool = true) -> Dict{String,Any}

ASCII キーの `Dict` へ写す。`include_audit = false` のとき、hash 対象外の
`upstream.source_bytes_sha256` と `notes` を含めない（hash 計算用、設計 §12.2）。
"""
function model_derived_input_to_dict(x::ModelDerivedInput; include_audit::Bool = true)
    d = Dict{String, Any}(
        "input_id" => x.input_id,
        "input_origin" => String(x.input_origin),
        "upstream" =>
            upstream_artifact_ref_to_dict(x.upstream; include_audit = include_audit),
        "mapping_id" => x.mapping_id,
        "mapping_version" => x.mapping_version,
        "mapping_hash" => x.mapping_hash,
        "compatibility_report_hash" => x.compatibility_report_hash,
        "target_model" => String(x.target_model),
        "target_concept" => String(x.target_concept),
        "target_group" => String(x.target_group),
        "value_semantics" => String(x.value_semantics),
        "values" => copy(x.values),
        "timing_basis" => String(x.timing_basis),
        "anchor_quarter" =>
            x.anchor_quarter === nothing ? nothing :
            Dict{String, Any}(
                "year" => x.anchor_quarter.year,
                "quarter" => x.anchor_quarter.quarter,
            ),
        "t_start" => x.t_start,
        "post_horizon" => String(x.post_horizon),
        "transmission_mode" => String(x.transmission_mode),
        "claim_scope" => String(x.claim_scope),
        "coverage" => _scenario_hash_encode(x.coverage),
    )
    include_audit && (d["notes"] = x.notes)
    return d
end

"""
    model_derived_input_from_dict(d::AbstractDict) -> ModelDerivedInput

`model_derived_input_to_dict` の逆変換（fail closed: 必須キー欠落・未知キーは `ArgumentError`。
値の不変条件は `ModelDerivedInput` の構築時検査が担う）。
"""
function model_derived_input_from_dict(d::AbstractDict)
    present = Set(String(k) for k in keys(d))
    expected = Set(_MODEL_DERIVED_INPUT_KEYS)
    present == expected || _model_derived_fail(
        "ModelDerivedInput の必須キー欠落 $(sort(collect(setdiff(expected, present))))・" *
        "未知キー $(sort(collect(setdiff(present, expected))))",
    )
    aq = d["anchor_quarter"]
    return ModelDerivedInput(;
        input_id = String(d["input_id"]),
        input_origin = Symbol(String(d["input_origin"])),
        upstream = upstream_artifact_ref_from_dict(d["upstream"]),
        mapping_id = String(d["mapping_id"]),
        mapping_version = String(d["mapping_version"]),
        mapping_hash = String(d["mapping_hash"]),
        compatibility_report_hash = String(d["compatibility_report_hash"]),
        target_model = Symbol(String(d["target_model"])),
        target_concept = Symbol(String(d["target_concept"])),
        target_group = Symbol(String(d["target_group"])),
        value_semantics = Symbol(String(d["value_semantics"])),
        values = Float64[Float64(v) for v in d["values"]],
        timing_basis = Symbol(String(d["timing_basis"])),
        anchor_quarter = aq === nothing ? nothing :
                         CalendarQuarter(Int(aq["year"]), Int(aq["quarter"])),
        t_start = d["t_start"] === nothing ? nothing : Int(d["t_start"]),
        post_horizon = Symbol(String(d["post_horizon"])),
        transmission_mode = Symbol(String(d["transmission_mode"])),
        claim_scope = Symbol(String(d["claim_scope"])),
        coverage = Dict{String, Any}(String(k) => v for (k, v) in d["coverage"]),
        notes = String(d["notes"]),
    )
end

"""
    cross_model_input_set_hash(xs::AbstractVector{ModelDerivedInput}) -> String

`ModelDerivedInput` 全件（`input_id` 昇順）の RFC 8785 正準 JSON の SHA-256（設計 §12.2）。
`notes`・`upstream.source_bytes_sha256` を除く。入力順に依存しない。
"""
function cross_model_input_set_hash(xs::AbstractVector{ModelDerivedInput})
    sorted = sort(collect(xs); by = x -> x.input_id)
    payload = Dict{String, Any}(
        "contract_version" => CROSS_MODEL_INPUT_CONTRACT_VERSION,
        "inputs" =>
            Any[model_derived_input_to_dict(x; include_audit = false) for x in sorted],
    )
    return "sha256:" * sha256_hex_of_canonical(payload)
end
