# cross_model_mapping.jl: PNE sector-output-path → DME の cross-model mapping artifact と
# target model profile（Issue #281 / `PN-1`）。
#
# PNE → DME の部門対応・集約・weight・経済圏の組・時間集約規則は **DME consumer 側の責務**
# であり、DME が所有する versioned な mapping artifact（`dme.cross-model-mapping/1.0.0`）として
# 宣言する（設計 §8.1）。LLM による自動生成・ラベル類似による推定を行わない。
#
# 本ファイルは mapping artifact の型・decode/encode・hash と、target model profile（v1 は CCC の
# 1 件のみ）を定義する。互換性判定（`X2`）と mapping の適用（`X3`）は
# `cross_model_compatibility.jl` が担う。
#
# 失敗の返し方（設計 §11.1）: mapping artifact として成立しない値（必須キー欠落・未知キー・
# 語彙違反・group 内部の矛盾）は `ArgumentError`。artifact と照合して初めて分かる不整合
# （weight の不正・未知 sector・geography 不一致など）は互換性判定の構造化拒否で返す。
#
# 設計契約:
#   docs/architecture/pne_sector_output_integration.md §6.1–§6.4・§7.2・§8・§9
#   docs/adr/0024-pne-sector-output-cross-model-input-contract.md 決定 5・6・10・11・12

# ===========================================================================
# 契約 version と語彙
# ===========================================================================

"cross-model mapping artifact の schema version（設計 §8.2）。"
const CROSS_MODEL_MAPPING_SCHEMA_VERSION = "dme.cross-model-mapping/1.0.0"

"target model profile の version（設計 §7.2）。"
const CROSS_MODEL_TARGET_PROFILE_VERSION = "cross-model-target-profile/1.0.0"

"""
CCC 向け cross-model mapping registry の version（設計 §10.2）。registry 本体
（`CCC_CROSS_MODEL_MAPPING_RULES`）は #282 が実装する。本定数は CCC target profile が参照する。
"""
const CCC_CROSS_MODEL_MAPPING_VERSION = "ccc-cross-model-mapping/1.0.0"

"""
transmission mode 3 値（設計 §6.2）。mapping artifact は既定値なしで宣言しなければならない。

- `:same_economy`: source と target が同一経済圏。
- `:explicit_cross_economy`: version 管理された transmission artifact が伝播を担う。
  **v1 では受理先なし**（`ACCEPTED_CROSS_ECONOMY_TRANSMISSION_CONTRACTS` が空）。
- `:hypothetical_override`: 実在経済間の伝播を主張しない架空入力。synthetic source に限る。
"""
const CROSS_MODEL_TRANSMISSION_MODES =
    (:same_economy, :explicit_cross_economy, :hypothetical_override)

"""
受理する cross-economy transmission contract version の集合（設計 §6.4）。v1 は**空**。
追加は ADR 0024 の改訂を要する。
"""
const ACCEPTED_CROSS_ECONOMY_TRANSMISSION_CONTRACTS = ()

"""
cross-model 入力の target concept 語彙（設計 §7.3・§7.4）。

- `:derived_out_of_model_demand`: モデル外顧客の実現産出比から導く派生中間需要（CCC が受理）。
- `:sector_supply_capacity`: 部門自身の供給能力（v1 で受理するモデルなし、`PG-01`）。
- `:aggregate_realized_output`: 部門・総産出の実現値（内生変数の上書きになるため受理しない）。
"""
const CROSS_MODEL_TARGET_CONCEPTS =
    (:derived_out_of_model_demand, :sector_supply_capacity, :aggregate_realized_output)

"""
部門集約の weight basis（設計 §8.3）。

- `:source_baseline_output`: PNE の `baseline_output` で群内正規化（単位の完全一致が必要）。
- `:direct_one_to_one`: member 1 件、weight 1。
- `:declared_target_share`: target 変数の baseline に占める割合を宣言。**再正規化しない**
  （`Σw ≤ 1`）。
"""
const CROSS_MODEL_WEIGHT_BASES =
    (:source_baseline_output, :direct_one_to_one, :declared_target_share)

"""
mapping 適用後の群の値の意味（設計 §8.3）。

- `:group_realized_output_ratio`: 群の実現産出の baseline 比（`:source_baseline_output`・
  `:direct_one_to_one`）。
- `:target_relative_change`: target 変数の baseline に対する相対変化 `−Σ w_j (1 − r_j)`
  （`:declared_target_share`）。
"""
const CROSS_MODEL_VALUE_SEMANTICS = (:group_realized_output_ratio, :target_relative_change)

"""
結果の claim scope（設計 §13）。

- `:same_economy_model_derived`: `:same_economy` で受理。
- `:hypothetical_fictional`: `:hypothetical_override` で受理。
"""
const CROSS_MODEL_CLAIM_SCOPES = (:same_economy_model_derived, :hypothetical_fictional)

"source → 四半期の時間集約規則（設計 §9.1）。"
const CROSS_MODEL_AGGREGATION_RULES = (:identity, :mean_of_three_months)

"source の `period_unit` と時間集約規則の対応（v1 で受理する 2 種、設計 §9.1）。"
const _CROSS_MODEL_UNIT_RULES = (:quarter => :identity, :month => :mean_of_three_months)

"カバーされない target の割合の扱い（固定、設計 §8.4）。「影響が無い」ではなく「本入力の対象外」。"
const CROSS_MODEL_UNCOVERED_SHARE_TREATMENT = :not_covered_by_upstream_input

const _CROSS_MODEL_GROUP_PATTERN = r"^[a-z][a-z0-9_]*$"

# ===========================================================================
# decode ヘルパ（層(1)）
# ===========================================================================

_cross_model_mapping_fail(msg::AbstractString) =
    throw(ArgumentError("invalid_cross_model_mapping: $(msg)"))

function _cross_model_mapping_keys(v, label::AbstractString, keys_)
    v isa AbstractDict ||
        _cross_model_mapping_fail("$(label) はオブジェクトでなければなりません")
    present = Set(String(k) for k in keys(v))
    expected = Set{String}(keys_)
    missing_keys = sort(collect(setdiff(expected, present)))
    unknown = sort(collect(setdiff(present, expected)))
    isempty(missing_keys) ||
        _cross_model_mapping_fail("$(label) に必須キーがありません: $(missing_keys)")
    isempty(unknown) ||
        _cross_model_mapping_fail("$(label) に未知のキーがあります: $(unknown)")
    return v
end

function _cross_model_mapping_string(v, label::AbstractString; nonempty::Bool = true)
    v isa AbstractString ||
        _cross_model_mapping_fail("$(label) は文字列でなければなりません")
    (!nonempty || !isempty(v)) ||
        _cross_model_mapping_fail("$(label) は空であってはいけません")
    return String(v)
end

_cross_model_mapping_optional_string(v, label::AbstractString) =
    v === nothing ? nothing : _cross_model_mapping_string(v, label; nonempty = false)

function _cross_model_mapping_identifier(v, label::AbstractString)
    s = _cross_model_mapping_string(v, label)
    occursin(_PNE_IDENTIFIER_PATTERN, s) ||
        _cross_model_mapping_fail("$(label)=\"$(s)\" は識別子の形式に一致しません")
    return s
end

function _cross_model_mapping_symbol(v, label::AbstractString, vocab)
    s = _cross_model_mapping_string(v, label)
    sym = Symbol(s)
    sym in vocab || _cross_model_mapping_fail(
        "$(label)=\"$(s)\" は $(collect(vocab)) のいずれかでなければなりません",
    )
    return sym
end

function _cross_model_mapping_string_list(
    v,
    label::AbstractString;
    identifiers::Bool = false,
)
    v isa AbstractVector || _cross_model_mapping_fail("$(label) は配列でなければなりません")
    return String[
        identifiers ? _cross_model_mapping_identifier(x, "$(label)[$(i)]") :
        _cross_model_mapping_string(x, "$(label)[$(i)]"; nonempty = false) for
        (i, x) in enumerate(v)
    ]
end

function _cross_model_check_enum(label::AbstractString, value::Symbol, vocab)
    value in vocab || throw(
        ArgumentError(
            "invalid_cross_model_mapping: $(label)=$(value) は $(collect(vocab)) のいずれかでなければなりません",
        ),
    )
    return value
end

# ===========================================================================
# 型
# ===========================================================================

"経済圏 identity の参照（`(system, economy_id)` の完全一致のみで比較する、設計 §6.1）。"
struct CrossModelGeographyRef
    system::String
    economy_id::String

    function CrossModelGeographyRef(system::AbstractString, economy_id::AbstractString)
        isempty(system) &&
            _cross_model_mapping_fail("geography.system は空であってはいけません")
        occursin(_PNE_IDENTIFIER_PATTERN, economy_id) || _cross_model_mapping_fail(
            "geography.economy_id=\"$(economy_id)\" は識別子の形式に一致しません",
        )
        return new(String(system), String(economy_id))
    end
end

Base.:(==)(a::CrossModelGeographyRef, b::CrossModelGeographyRef) =
    a.system == b.system && a.economy_id == b.economy_id
Base.hash(a::CrossModelGeographyRef, h::UInt) = hash((a.system, a.economy_id), h)

"classification identity の参照（`(system, version, level)` の完全一致で比較する、設計 §8.5）。"
struct CrossModelClassificationRef
    system::String
    version::String
    level::String

    function CrossModelClassificationRef(
        system::AbstractString,
        version::AbstractString,
        level::AbstractString,
    )
        (isempty(system) || isempty(version) || isempty(level)) &&
            _cross_model_mapping_fail(
                "source_classification の system・version・level は空であってはいけません",
            )
        return new(String(system), String(version), String(level))
    end
end

Base.:(==)(a::CrossModelClassificationRef, b::CrossModelClassificationRef) =
    a.system == b.system && a.version == b.version && a.level == b.level
Base.hash(a::CrossModelClassificationRef, h::UInt) = hash((a.system, a.version, a.level), h)

"""
    CrossEconomyTransmissionRef

`:explicit_cross_economy` の transmission artifact への参照（設計 §6.4）。v1 では identity を
検査したうえで、受理する contract version が無いため常に拒否される。
"""
struct CrossEconomyTransmissionRef
    contract_version::String
    artifact_id::String
    content_hash::String
    source_economy::CrossModelGeographyRef
    target_economy::CrossModelGeographyRef
    target_model::Symbol
    mechanism::String
    evidence::Vector{String}

    function CrossEconomyTransmissionRef(;
        contract_version::AbstractString,
        artifact_id::AbstractString,
        content_hash::AbstractString,
        source_economy::CrossModelGeographyRef,
        target_economy::CrossModelGeographyRef,
        target_model::Symbol,
        mechanism::AbstractString,
        evidence::Vector{String},
    )
        isempty(contract_version) && _cross_model_mapping_fail(
            "transmission_ref.contract_version は空であってはいけません",
        )
        occursin(_PNE_IDENTIFIER_PATTERN, artifact_id) || _cross_model_mapping_fail(
            "transmission_ref.artifact_id は識別子の形式に一致しません",
        )
        occursin(_PNE_HASH_PATTERN, content_hash) || _cross_model_mapping_fail(
            "transmission_ref.content_hash は \"sha256:\" + 64桁の小文字16進でなければなりません",
        )
        isempty(mechanism) &&
            _cross_model_mapping_fail("transmission_ref.mechanism は空であってはいけません")
        isempty(evidence) && _cross_model_mapping_fail(
            "transmission_ref.evidence は 1 件以上でなければなりません",
        )
        return new(
            String(contract_version),
            String(artifact_id),
            String(content_hash),
            source_economy,
            target_economy,
            target_model,
            String(mechanism),
            sort(evidence),
        )
    end
end

"""
    CrossModelTransmission

transmission の宣言（設計 §6.2）。`mode` と必須フィールドの整合（override の
`justification`・cross-economy の `transmission_ref`）は互換性判定が
`transmission_mode_inconsistent` として検査する。
"""
struct CrossModelTransmission
    mode::Symbol
    justification::String
    transmission_ref::Union{CrossEconomyTransmissionRef, Nothing}

    function CrossModelTransmission(;
        mode::Symbol,
        justification::AbstractString = "",
        transmission_ref::Union{CrossEconomyTransmissionRef, Nothing} = nothing,
    )
        _cross_model_check_enum("transmission.mode", mode, CROSS_MODEL_TRANSMISSION_MODES)
        return new(mode, String(justification), transmission_ref)
    end
end

"""
群の member。`weight` は `:declared_target_share` のときのみ数値を持つ。非有限の weight は
JSON で表せず hash も計算できないため構築時に拒否する（層(1)）。weight の値の妥当性
（正・`Σw ≤ 1`）は互換性判定が `invalid_weights` として検査する。
"""
struct CrossModelGroupMember
    sector_id::String
    weight::Union{Float64, Nothing}

    function CrossModelGroupMember(sector_id::AbstractString, weight::Union{Real, Nothing})
        occursin(_PNE_IDENTIFIER_PATTERN, sector_id) || _cross_model_mapping_fail(
            "member.sector_id=\"$(sector_id)\" は識別子の形式に一致しません",
        )
        weight isa Bool && _cross_model_mapping_fail(
            "member[$(sector_id)].weight は数値または null でなければなりません",
        )
        weight === nothing ||
            isfinite(weight) ||
            _cross_model_mapping_fail(
                "member[$(sector_id)].weight は有限でなければなりません（実値: $(weight)）",
            )
        return new(String(sector_id), weight === nothing ? nothing : Float64(weight))
    end
end

"`:declared_target_share` の weight の出所（設計 §7.4 `DD-4`）。"
struct CrossModelWeightProvenance
    source::String
    version::String
    method::String
    data_hash::Union{String, Nothing}

    function CrossModelWeightProvenance(;
        source::AbstractString,
        version::AbstractString,
        method::AbstractString,
        data_hash::Union{AbstractString, Nothing} = nothing,
    )
        data_hash === nothing ||
            occursin(_PNE_HASH_PATTERN, data_hash) ||
            _cross_model_mapping_fail(
                "weight_provenance.data_hash は \"sha256:\" + 64桁の小文字16進または null でなければなりません",
            )
        return new(
            String(source),
            String(version),
            String(method),
            data_hash === nothing ? nothing : String(data_hash),
        )
    end
end

"""
    CrossModelMappingGroup

1 つの target group への many-to-one 対応（設計 §8.2）。`members`・`producer_set` は
`sector_id` 昇順に整列して保持する。

構築時に検査する（層(1)）:
- `target_concept = :derived_out_of_model_demand` の群は `customer_scope = :out_of_model` と
  1 件以上の `identifying_assumptions` を必須とする（`DD-5` の宣言。識別仮定として記録する）。
- それ以外の concept の群は `producer_set`・`producer_set_absent_reason`・`customer_scope` を
  持たない。
- `members` は 1 件以上。
"""
struct CrossModelMappingGroup
    target_group::Symbol
    target_concept::Symbol
    weight_basis::Symbol
    members::Vector{CrossModelGroupMember}
    producer_set::Vector{String}
    producer_set_absent_reason::Union{String, Nothing}
    customer_scope::Union{Symbol, Nothing}
    weight_provenance::Union{CrossModelWeightProvenance, Nothing}
    identifying_assumptions::Vector{String}

    function CrossModelMappingGroup(;
        target_group::Symbol,
        target_concept::Symbol,
        weight_basis::Symbol,
        members::Vector{CrossModelGroupMember},
        producer_set::Vector{String} = String[],
        producer_set_absent_reason::Union{AbstractString, Nothing} = nothing,
        customer_scope::Union{Symbol, Nothing} = nothing,
        weight_provenance::Union{CrossModelWeightProvenance, Nothing} = nothing,
        identifying_assumptions::Vector{String} = String[],
    )
        occursin(_CROSS_MODEL_GROUP_PATTERN, String(target_group)) ||
            _cross_model_mapping_fail(
                "target_group=$(target_group) は小文字の snake_case でなければなりません",
            )
        _cross_model_check_enum(
            "groups[$(target_group)].target_concept",
            target_concept,
            CROSS_MODEL_TARGET_CONCEPTS,
        )
        _cross_model_check_enum(
            "groups[$(target_group)].weight_basis",
            weight_basis,
            CROSS_MODEL_WEIGHT_BASES,
        )
        isempty(members) && _cross_model_mapping_fail(
            "groups[$(target_group)].members は 1 件以上でなければなりません",
        )
        for p in producer_set
            occursin(_PNE_IDENTIFIER_PATTERN, p) || _cross_model_mapping_fail(
                "groups[$(target_group)].producer_set の \"$(p)\" は識別子の形式に一致しません",
            )
        end
        if target_concept === :derived_out_of_model_demand
            customer_scope === :out_of_model || _cross_model_mapping_fail(
                "groups[$(target_group)]: derived_out_of_model_demand の群は " *
                "customer_scope=\"out_of_model\" を宣言しなければなりません（設計 §7.4 DD-5）",
            )
            isempty(identifying_assumptions) && _cross_model_mapping_fail(
                "groups[$(target_group)]: derived_out_of_model_demand の群は identifying_assumptions を " *
                "1 件以上宣言しなければなりません（ext_demand_s の顧客別構成は識別されない。設計 §7.4 DD-5）",
            )
        else
            (isempty(producer_set) && producer_set_absent_reason === nothing) ||
                _cross_model_mapping_fail(
                    "groups[$(target_group)]: producer_set・producer_set_absent_reason は " *
                    "derived_out_of_model_demand の群でのみ宣言できます",
                )
            customer_scope === nothing || _cross_model_mapping_fail(
                "groups[$(target_group)]: customer_scope は derived_out_of_model_demand の群でのみ宣言できます",
            )
        end
        customer_scope === nothing ||
            customer_scope === :out_of_model ||
            _cross_model_mapping_fail(
                "groups[$(target_group)].customer_scope は \"out_of_model\" または null でなければなりません",
            )
        return new(
            target_group,
            target_concept,
            weight_basis,
            sort(members; by = m -> m.sector_id),
            sort(producer_set),
            producer_set_absent_reason === nothing ? nothing :
            String(producer_set_absent_reason),
            customer_scope,
            weight_provenance,
            identifying_assumptions,
        )
    end
end

"""
    CrossModelTimeMapping

時間 mapping の宣言（設計 §9）。`(expected_source_period_unit, aggregation_rule)` は
`(:quarter, :identity)` か `(:month, :mean_of_three_months)` のみ。`partial_quarter` は
`:reject`、`post_horizon` は `:require_recovered` の 1 値のみ（v1）。
"""
struct CrossModelTimeMapping
    expected_source_period_unit::Symbol
    target_frequency::Symbol
    aggregation_rule::Symbol
    partial_quarter::Symbol
    post_horizon::Symbol

    function CrossModelTimeMapping(;
        expected_source_period_unit::Symbol,
        aggregation_rule::Symbol,
        target_frequency::Symbol = :quarter,
        partial_quarter::Symbol = :reject,
        post_horizon::Symbol = :require_recovered,
    )
        _cross_model_check_enum("time.target_frequency", target_frequency, (:quarter,))
        _cross_model_check_enum("time.partial_quarter", partial_quarter, (:reject,))
        _cross_model_check_enum("time.post_horizon", post_horizon, (:require_recovered,))
        _cross_model_check_enum(
            "time.aggregation_rule",
            aggregation_rule,
            CROSS_MODEL_AGGREGATION_RULES,
        )
        (expected_source_period_unit => aggregation_rule) in _CROSS_MODEL_UNIT_RULES ||
            _cross_model_mapping_fail(
                "time: expected_source_period_unit=$(expected_source_period_unit) と " *
                "aggregation_rule=$(aggregation_rule) の組は受理されません" *
                "（quarter→identity・month→mean_of_three_months のみ。設計 §9.1）",
            )
        return new(
            expected_source_period_unit,
            target_frequency,
            aggregation_rule,
            partial_quarter,
            post_horizon,
        )
    end
end

"""
    CrossModelMapping

DME が所有する cross-model mapping artifact（`dme.cross-model-mapping/1.0.0`、設計 §8.2）。
`groups` は `target_group` 昇順、`declared_unmapped_source_sectors` は昇順に整列して保持する。

`mapping_hash` は `notes` を除く全フィールドの RFC 8785 正準 JSON の SHA-256
（`cross_model_mapping_hash`）。本型自身は hash フィールドを持たない（自己参照の排除）。
"""
struct CrossModelMapping
    mapping_id::String
    mapping_version::String
    source_contract::String
    source_geography::CrossModelGeographyRef
    target_geography::CrossModelGeographyRef
    source_classification::CrossModelClassificationRef
    target_model::Symbol
    target_model_mapping_version::String
    transmission::CrossModelTransmission
    groups::Vector{CrossModelMappingGroup}
    declared_unmapped_source_sectors::Vector{String}
    time::CrossModelTimeMapping
    assumptions::Vector{String}
    notes::String

    function CrossModelMapping(;
        mapping_id::AbstractString,
        mapping_version::AbstractString,
        source_geography::CrossModelGeographyRef,
        target_geography::CrossModelGeographyRef,
        source_classification::CrossModelClassificationRef,
        target_model::Symbol,
        target_model_mapping_version::AbstractString,
        transmission::CrossModelTransmission,
        groups::Vector{CrossModelMappingGroup},
        declared_unmapped_source_sectors::Vector{String},
        time::CrossModelTimeMapping,
        source_contract::AbstractString = PNE_SECTOR_OUTPUT_PATH_CONTRACT,
        assumptions::Vector{String} = String[],
        notes::AbstractString = "",
    )
        occursin(_PNE_IDENTIFIER_PATTERN, mapping_id) || _cross_model_mapping_fail(
            "mapping_id=\"$(mapping_id)\" は識別子の形式に一致しません",
        )
        isempty(mapping_version) &&
            _cross_model_mapping_fail("mapping_version は空であってはいけません")
        source_contract in PNE_SECTOR_OUTPUT_PATH_ACCEPTED_SCHEMA_VERSIONS ||
            _cross_model_mapping_fail(
                "source_contract=\"$(source_contract)\" は受理される上流契約 " *
                "$(collect(PNE_SECTOR_OUTPUT_PATH_ACCEPTED_SCHEMA_VERSIONS)) のいずれでもありません",
            )
        isempty(target_model_mapping_version) && _cross_model_mapping_fail(
            "target_model_mapping_version は空であってはいけません",
        )
        isempty(groups) &&
            _cross_model_mapping_fail("groups は 1 件以上でなければなりません")
        group_names = [g.target_group for g in groups]
        length(unique(group_names)) == length(group_names) || _cross_model_mapping_fail(
            "groups の target_group が重複しています: $(group_names)",
        )
        for s in declared_unmapped_source_sectors
            occursin(_PNE_IDENTIFIER_PATTERN, s) || _cross_model_mapping_fail(
                "declared_unmapped_source_sectors の \"$(s)\" は識別子の形式に一致しません",
            )
        end
        length(unique(declared_unmapped_source_sectors)) ==
        length(declared_unmapped_source_sectors) ||
            _cross_model_mapping_fail("declared_unmapped_source_sectors に重複があります")
        return new(
            String(mapping_id),
            String(mapping_version),
            String(source_contract),
            source_geography,
            target_geography,
            source_classification,
            target_model,
            String(target_model_mapping_version),
            transmission,
            sort(groups; by = g -> String(g.target_group)),
            sort(declared_unmapped_source_sectors),
            time,
            assumptions,
            String(notes),
        )
    end
end

# ===========================================================================
# decode / encode / hash
# ===========================================================================

const _CROSS_MODEL_MAPPING_TOP_KEYS = (
    "schema_version",
    "mapping_id",
    "mapping_version",
    "source_contract",
    "source_geography",
    "target_geography",
    "source_classification",
    "target_model",
    "target_model_mapping_version",
    "transmission",
    "groups",
    "declared_unmapped_source_sectors",
    "time",
    "assumptions",
    "notes",
)

const _CROSS_MODEL_GROUP_KEYS = (
    "target_group",
    "target_concept",
    "weight_basis",
    "members",
    "producer_set",
    "producer_set_absent_reason",
    "customer_scope",
    "weight_provenance",
    "identifying_assumptions",
)

function _cross_model_geography_from_dict(v, label::AbstractString)
    _cross_model_mapping_keys(v, label, ("system", "economy_id"))
    return CrossModelGeographyRef(
        _cross_model_mapping_string(v["system"], "$(label).system"),
        _cross_model_mapping_identifier(v["economy_id"], "$(label).economy_id"),
    )
end

_cross_model_geography_to_dict(g::CrossModelGeographyRef) =
    Dict{String, Any}("system" => g.system, "economy_id" => g.economy_id)

function _cross_model_transmission_ref_from_dict(v)
    v === nothing && return nothing
    label = "transmission.transmission_ref"
    _cross_model_mapping_keys(
        v,
        label,
        (
            "contract_version",
            "artifact_id",
            "content_hash",
            "source_economy",
            "target_economy",
            "target_model",
            "mechanism",
            "evidence",
        ),
    )
    return CrossEconomyTransmissionRef(;
        contract_version = _cross_model_mapping_string(
            v["contract_version"],
            "$(label).contract_version",
        ),
        artifact_id = _cross_model_mapping_identifier(
            v["artifact_id"],
            "$(label).artifact_id",
        ),
        content_hash = _cross_model_mapping_string(
            v["content_hash"],
            "$(label).content_hash",
        ),
        source_economy = _cross_model_geography_from_dict(
            v["source_economy"],
            "$(label).source_economy",
        ),
        target_economy = _cross_model_geography_from_dict(
            v["target_economy"],
            "$(label).target_economy",
        ),
        target_model = Symbol(
            _cross_model_mapping_identifier(v["target_model"], "$(label).target_model"),
        ),
        mechanism = _cross_model_mapping_string(v["mechanism"], "$(label).mechanism"),
        evidence = _cross_model_mapping_string_list(v["evidence"], "$(label).evidence"),
    )
end

function _cross_model_transmission_ref_to_dict(
    r::Union{CrossEconomyTransmissionRef, Nothing},
)
    r === nothing && return nothing
    return Dict{String, Any}(
        "contract_version" => r.contract_version,
        "artifact_id" => r.artifact_id,
        "content_hash" => r.content_hash,
        "source_economy" => _cross_model_geography_to_dict(r.source_economy),
        "target_economy" => _cross_model_geography_to_dict(r.target_economy),
        "target_model" => String(r.target_model),
        "mechanism" => r.mechanism,
        "evidence" => copy(r.evidence),
    )
end

function _cross_model_member_from_dict(v, label::AbstractString)
    _cross_model_mapping_keys(v, label, ("sector_id", "weight"))
    w = v["weight"]
    weight = if w === nothing
        nothing
    elseif w isa Real && !(w isa Bool)
        Float64(w)
    else
        _cross_model_mapping_fail("$(label).weight は数値または null でなければなりません")
    end
    return CrossModelGroupMember(
        _cross_model_mapping_identifier(v["sector_id"], "$(label).sector_id"),
        weight,
    )
end

function _cross_model_weight_provenance_from_dict(v, label::AbstractString)
    v === nothing && return nothing
    _cross_model_mapping_keys(v, label, ("source", "version", "method", "data_hash"))
    return CrossModelWeightProvenance(;
        source = _cross_model_mapping_string(
            v["source"],
            "$(label).source";
            nonempty = false,
        ),
        version = _cross_model_mapping_string(
            v["version"],
            "$(label).version";
            nonempty = false,
        ),
        method = _cross_model_mapping_string(
            v["method"],
            "$(label).method";
            nonempty = false,
        ),
        data_hash = _cross_model_mapping_optional_string(
            v["data_hash"],
            "$(label).data_hash",
        ),
    )
end

function _cross_model_group_from_dict(v, i::Int)
    label = "groups[$(i)]"
    _cross_model_mapping_keys(v, label, _CROSS_MODEL_GROUP_KEYS)
    members_raw = v["members"]
    members_raw isa AbstractVector ||
        _cross_model_mapping_fail("$(label).members は配列でなければなりません")
    scope_raw = v["customer_scope"]
    return CrossModelMappingGroup(;
        target_group = Symbol(
            _cross_model_mapping_string(v["target_group"], "$(label).target_group"),
        ),
        target_concept = _cross_model_mapping_symbol(
            v["target_concept"],
            "$(label).target_concept",
            CROSS_MODEL_TARGET_CONCEPTS,
        ),
        weight_basis = _cross_model_mapping_symbol(
            v["weight_basis"],
            "$(label).weight_basis",
            CROSS_MODEL_WEIGHT_BASES,
        ),
        members = CrossModelGroupMember[
            _cross_model_member_from_dict(m, "$(label).members[$(j)]") for
            (j, m) in enumerate(members_raw)
        ],
        producer_set = _cross_model_mapping_string_list(
            v["producer_set"],
            "$(label).producer_set";
            identifiers = true,
        ),
        producer_set_absent_reason = _cross_model_mapping_optional_string(
            v["producer_set_absent_reason"],
            "$(label).producer_set_absent_reason",
        ),
        customer_scope = scope_raw === nothing ? nothing :
                         _cross_model_mapping_symbol(
            scope_raw,
            "$(label).customer_scope",
            (:out_of_model,),
        ),
        weight_provenance = _cross_model_weight_provenance_from_dict(
            v["weight_provenance"],
            "$(label).weight_provenance",
        ),
        identifying_assumptions = _cross_model_mapping_string_list(
            v["identifying_assumptions"],
            "$(label).identifying_assumptions",
        ),
    )
end

function _cross_model_group_to_dict(g::CrossModelMappingGroup)
    wp = g.weight_provenance
    return Dict{String, Any}(
        "target_group" => String(g.target_group),
        "target_concept" => String(g.target_concept),
        "weight_basis" => String(g.weight_basis),
        "members" => Any[
            Dict{String, Any}("sector_id" => m.sector_id, "weight" => m.weight) for
            m in g.members
        ],
        "producer_set" => copy(g.producer_set),
        "producer_set_absent_reason" => g.producer_set_absent_reason,
        "customer_scope" =>
            g.customer_scope === nothing ? nothing : String(g.customer_scope),
        "weight_provenance" =>
            wp === nothing ? nothing :
            Dict{String, Any}(
                "source" => wp.source,
                "version" => wp.version,
                "method" => wp.method,
                "data_hash" => wp.data_hash,
            ),
        "identifying_assumptions" => copy(g.identifying_assumptions),
    )
end

"""
    cross_model_mapping_from_dict(d::AbstractDict) -> CrossModelMapping

mapping artifact の plain `Dict` を decode する。fail closed: 未知 `schema_version`・必須キー
欠落・未知キー・語彙違反は `ArgumentError`（メッセージは `invalid_cross_model_mapping:` または
`unsupported_cross_model_mapping_schema_version:` で始まる）。
"""
function cross_model_mapping_from_dict(d::AbstractDict)
    haskey(d, "schema_version") ||
        _cross_model_mapping_fail("必須キーがありません: [\"schema_version\"]")
    d["schema_version"] == CROSS_MODEL_MAPPING_SCHEMA_VERSION || throw(
        ArgumentError(
            "unsupported_cross_model_mapping_schema_version: このパッケージが受理するのは " *
            "$(CROSS_MODEL_MAPPING_SCHEMA_VERSION) のみです（実値: $(repr(d["schema_version"]))）",
        ),
    )
    _cross_model_mapping_keys(d, "mapping", _CROSS_MODEL_MAPPING_TOP_KEYS)
    cls = d["source_classification"]
    _cross_model_mapping_keys(cls, "source_classification", ("system", "version", "level"))
    tr = d["transmission"]
    _cross_model_mapping_keys(
        tr,
        "transmission",
        ("mode", "justification", "transmission_ref"),
    )
    tm = d["time"]
    _cross_model_mapping_keys(
        tm,
        "time",
        (
            "expected_source_period_unit",
            "target_frequency",
            "aggregation_rule",
            "partial_quarter",
            "post_horizon",
        ),
    )
    groups_raw = d["groups"]
    groups_raw isa AbstractVector ||
        _cross_model_mapping_fail("groups は配列でなければなりません")
    return CrossModelMapping(;
        mapping_id = _cross_model_mapping_identifier(d["mapping_id"], "mapping_id"),
        mapping_version = _cross_model_mapping_string(
            d["mapping_version"],
            "mapping_version",
        ),
        source_contract = _cross_model_mapping_string(
            d["source_contract"],
            "source_contract",
        ),
        source_geography = _cross_model_geography_from_dict(
            d["source_geography"],
            "source_geography",
        ),
        target_geography = _cross_model_geography_from_dict(
            d["target_geography"],
            "target_geography",
        ),
        source_classification = CrossModelClassificationRef(
            _cross_model_mapping_string(cls["system"], "source_classification.system"),
            _cross_model_mapping_string(cls["version"], "source_classification.version"),
            _cross_model_mapping_string(cls["level"], "source_classification.level"),
        ),
        target_model = Symbol(
            _cross_model_mapping_identifier(d["target_model"], "target_model"),
        ),
        target_model_mapping_version = _cross_model_mapping_string(
            d["target_model_mapping_version"],
            "target_model_mapping_version",
        ),
        transmission = CrossModelTransmission(;
            mode = _cross_model_mapping_symbol(
                tr["mode"],
                "transmission.mode",
                CROSS_MODEL_TRANSMISSION_MODES,
            ),
            justification = _cross_model_mapping_string(
                tr["justification"],
                "transmission.justification";
                nonempty = false,
            ),
            transmission_ref = _cross_model_transmission_ref_from_dict(
                tr["transmission_ref"],
            ),
        ),
        groups = CrossModelMappingGroup[
            _cross_model_group_from_dict(g, i) for (i, g) in enumerate(groups_raw)
        ],
        declared_unmapped_source_sectors = _cross_model_mapping_string_list(
            d["declared_unmapped_source_sectors"],
            "declared_unmapped_source_sectors";
            identifiers = true,
        ),
        time = CrossModelTimeMapping(;
            expected_source_period_unit = _cross_model_mapping_symbol(
                tm["expected_source_period_unit"],
                "time.expected_source_period_unit",
                PNE_PERIOD_UNITS,
            ),
            target_frequency = _cross_model_mapping_symbol(
                tm["target_frequency"],
                "time.target_frequency",
                (:quarter,),
            ),
            aggregation_rule = _cross_model_mapping_symbol(
                tm["aggregation_rule"],
                "time.aggregation_rule",
                CROSS_MODEL_AGGREGATION_RULES,
            ),
            partial_quarter = _cross_model_mapping_symbol(
                tm["partial_quarter"],
                "time.partial_quarter",
                (:reject,),
            ),
            post_horizon = _cross_model_mapping_symbol(
                tm["post_horizon"],
                "time.post_horizon",
                (:require_recovered,),
            ),
        ),
        assumptions = _cross_model_mapping_string_list(d["assumptions"], "assumptions"),
        notes = _cross_model_mapping_string(d["notes"], "notes"; nonempty = false),
    )
end

"""
    load_cross_model_mapping(path::AbstractString) -> CrossModelMapping

JSON ファイルから mapping artifact を decode する（`cross_model_mapping_from_dict` の fail closed
契約を適用する）。
"""
function load_cross_model_mapping(path::AbstractString)
    parsed = try
        JSON3.read(read(path, String))
    catch e
        _cross_model_mapping_fail(
            "$(basename(path)) を JSON として解釈できません（$(typeof(e))）",
        )
    end
    d = _scenario_json_to_plain(parsed)
    d isa AbstractDict || _cross_model_mapping_fail(
        "mapping artifact のトップレベルはオブジェクトでなければなりません",
    )
    return cross_model_mapping_from_dict(d)
end

"""
    cross_model_mapping_to_dict(m::CrossModelMapping) -> Dict{String,Any}

ASCII キーの `Dict` へ写す（`cross_model_mapping_from_dict` の逆変換）。配列は構築時に
整列済みであり、同じ意味内容から同じ `Dict` を得る。
"""
function cross_model_mapping_to_dict(m::CrossModelMapping)
    t = m.time
    return Dict{String, Any}(
        "schema_version" => CROSS_MODEL_MAPPING_SCHEMA_VERSION,
        "mapping_id" => m.mapping_id,
        "mapping_version" => m.mapping_version,
        "source_contract" => m.source_contract,
        "source_geography" => _cross_model_geography_to_dict(m.source_geography),
        "target_geography" => _cross_model_geography_to_dict(m.target_geography),
        "source_classification" => Dict{String, Any}(
            "system" => m.source_classification.system,
            "version" => m.source_classification.version,
            "level" => m.source_classification.level,
        ),
        "target_model" => String(m.target_model),
        "target_model_mapping_version" => m.target_model_mapping_version,
        "transmission" => Dict{String, Any}(
            "mode" => String(m.transmission.mode),
            "justification" => m.transmission.justification,
            "transmission_ref" =>
                _cross_model_transmission_ref_to_dict(m.transmission.transmission_ref),
        ),
        "groups" => Any[_cross_model_group_to_dict(g) for g in m.groups],
        "declared_unmapped_source_sectors" => copy(m.declared_unmapped_source_sectors),
        "time" => Dict{String, Any}(
            "expected_source_period_unit" => String(t.expected_source_period_unit),
            "target_frequency" => String(t.target_frequency),
            "aggregation_rule" => String(t.aggregation_rule),
            "partial_quarter" => String(t.partial_quarter),
            "post_horizon" => String(t.post_horizon),
        ),
        "assumptions" => copy(m.assumptions),
        "notes" => m.notes,
    )
end

"""
    cross_model_mapping_hash(m::CrossModelMapping) -> String

`notes` を除く mapping artifact の RFC 8785 正準 JSON の SHA-256（`"sha256:…"`、設計 §8.2・§12.2）。
"""
function cross_model_mapping_hash(m::CrossModelMapping)
    d = cross_model_mapping_to_dict(m)
    delete!(d, "notes")
    return "sha256:" * sha256_hex_of_canonical(d)
end

# ===========================================================================
# target model profile（設計 §7.2）
# ===========================================================================

"""
    CrossModelTargetProfile

PNE 由来入力を受理する target model の受理プロファイル（設計 §7.2）。v1 は CCC の 1 件のみ
（`CROSS_MODEL_TARGET_PROFILES`）。互換性判定はこの registry からのみ profile を引き、
呼び出し側が profile（特に経済圏）を差し替える経路を持たない（設計 §6.5・§15）。

## フィールド
- `model::Symbol`: `model_symbol` の値。
- `profile_version::String`
- `geography::CrossModelGeographyRef`: target model の経済圏 identity。
- `frequency::Symbol`: `:quarter`。
- `model_mapping_version::String`: モデル固有 mapping registry の version。
- `target_groups::Tuple`: `target_group => target_concept` の組。
- `allowed_weight_bases::Tuple`: `target_concept => (weight_basis, …)` の組。
- `accepted_source_period_units::Tuple`: 受理する source の `period_unit`。
"""
struct CrossModelTargetProfile
    model::Symbol
    profile_version::String
    geography::CrossModelGeographyRef
    frequency::Symbol
    model_mapping_version::String
    target_groups::Tuple{Vararg{Pair{Symbol, Symbol}}}
    allowed_weight_bases::Tuple{Vararg{Pair{Symbol, Tuple{Vararg{Symbol}}}}}
    accepted_source_period_units::Tuple{Vararg{Symbol}}
end

"""
CCC の受理プロファイル（設計 §7.2）。経済圏は CCC の分析契約の基準経済（米国）を識別子にした
ものであり、CCC が米国に較正済みであることを意味しない。受理する概念は派生中間需要チャネル
（`ext_demand_s2` / `ext_demand_s3`）のみ、weight basis は `:declared_target_share` のみ。
"""
const _CCC_CROSS_MODEL_TARGET_PROFILE = CrossModelTargetProfile(
    :capex_credit_cycle,
    CROSS_MODEL_TARGET_PROFILE_VERSION,
    CrossModelGeographyRef("ISO 3166-1 alpha-2", "US"),
    :quarter,
    CCC_CROSS_MODEL_MAPPING_VERSION,
    (
        :ext_demand_s2_customers => :derived_out_of_model_demand,
        :ext_demand_s3_customers => :derived_out_of_model_demand,
    ),
    (:derived_out_of_model_demand => (:declared_target_share,),),
    (:quarter, :month),
)

"v1 の target model profile registry（CCC の 1 件のみ。不変の `Tuple`）。"
const CROSS_MODEL_TARGET_PROFILES = (_CCC_CROSS_MODEL_TARGET_PROFILE,)

"""
    cross_model_target_profile(model::Symbol) -> Union{CrossModelTargetProfile,Nothing}

registry から target profile を引く。無ければ `nothing`（`unsupported_target_model`）。
"""
function cross_model_target_profile(model::Symbol)
    for p in CROSS_MODEL_TARGET_PROFILES
        p.model === model && return p
    end
    return nothing
end

"profile が受理する target concept（重複なし、宣言順）。"
cross_model_accepted_concepts(p::CrossModelTargetProfile) =
    Tuple(unique(last(g) for g in p.target_groups))

"profile の `target_group` に対応する concept（無ければ `nothing`）。"
function _cross_model_profile_group_concept(p::CrossModelTargetProfile, group::Symbol)
    for g in p.target_groups
        first(g) === group && return last(g)
    end
    return nothing
end

"profile が `concept` に許す weight basis（無ければ空の `Tuple`）。"
function _cross_model_profile_allowed_bases(p::CrossModelTargetProfile, concept::Symbol)
    for a in p.allowed_weight_bases
        first(a) === concept && return last(a)
    end
    return ()
end
