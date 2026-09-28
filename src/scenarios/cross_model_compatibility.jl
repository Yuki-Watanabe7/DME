# cross_model_compatibility.jl: PNE sector-output-path の互換性判定（`X2`）と mapping の適用
# （`X3`）（Issue #281 / `PN-1`）。
#
# `check_cross_model_compatibility(artifact, mapping)` は、上流 artifact・DME の mapping artifact・
# target model profile（registry から引く。呼び出し側が差し替える経路は持たない）を照合し、
# geography / classification / sector 割当 / weight / 時間軸のすべての不整合を **1 件目で
# 打ち切らずに全件列挙** した machine-readable な `CrossModelCompatibilityReport` を返す
# （ADR 0015 の失敗 3 層のうち層(2)「集合の整合」）。例外は投げない。
#
# `apply_cross_model_mapping(artifact, mapping, report)` は accepted な report に限り、
# 時間集約（部門ごと）→ 部門集約（group ごと）の固定順で target group ごとの四半期パス
# （`MappedGroupPath`）を返す。欠損を 0 ショック（比 1）で埋めない・`:declared_target_share` を
# 再正規化しない・部分四半期を按分しない（設計 `UM-6`）。
#
# 本ファイルはモデルへの適用（`ModelDerivedInput`・`map_model_derived_input`・
# `run_cross_model_scenario`）を実装しない（#282）。
#
# 設計契約:
#   docs/architecture/pne_sector_output_integration.md §6–§9・§11・§12.2
#   docs/adr/0024-pne-sector-output-cross-model-input-contract.md 決定 5–13・15

# ===========================================================================
# 語彙
# ===========================================================================

"compatibility report の schema version（設計 §11.4）。"
const CROSS_MODEL_COMPATIBILITY_REPORT_SCHEMA_VERSION = "dme.cross-model-compatibility-report/1.0.0"

"""
cross-model の構造化拒否コード 30 種（設計 §11.2）。実装はこれ以外のコードを生成しない。
`MACRO_EVENT_REJECTION_CODES` とは独立の語彙である（ADR 0024 決定 15）。
"""
const CROSS_MODEL_REJECTION_CODES = (
    :upstream_status_unsupported,
    :upstream_error_warning,
    :geography_mismatch,
    :geography_declaration_inconsistent,
    :transmission_mode_inconsistent,
    :cross_economy_transmission_unavailable,
    :hypothetical_override_requires_synthetic_source,
    :classification_mismatch,
    :unknown_source_sector,
    :duplicate_sector_assignment,
    :unmapped_sector_undeclared,
    :invalid_weights,
    :weight_basis_not_allowed,
    :baseline_output_missing,
    :baseline_output_unit_mismatch,
    :unmapped_target_concept,
    :unsupported_target_model,
    :own_supply_constraint_present,
    :producer_set_undeclared,
    :unsupported_source_period_unit,
    :ambiguous_source_period_unit,
    :calendar_anchor_required,
    :calendar_anchor_invalid,
    :calendar_anchor_misaligned,
    :partial_quarter,
    :upstream_path_unrecovered_at_horizon_end,
    :upstream_path_in_runup,
    :timing_basis_conflict,
    :duplicate_input_id,
    :provenance_chain_broken,
)

"""
cross-model の警告コード 10 種（設計 §11.3）。実装はこれ以外のコードを生成しない。
`MACRO_EVENT_WARNING_CODES` とは独立の語彙である。
"""
const CROSS_MODEL_WARNING_CODES = (
    :upstream_warning_carried,
    :synthetic_upstream_source,
    :upstream_estimated_inputs,
    :hypothetical_transmission,
    :unmapped_source_sectors_present,
    :partial_target_coverage,
    :producer_set_absent,
    :upstream_calendar_anchor_unused,
    :upstream_path_truncated,
    :upstream_event_same_target,
)

"拒否が生じた処理段（設計 §4・§11.2）。本 Issue（`X2`）が生成するのは `:compatibility` のみ。"
const CROSS_MODEL_STAGES = (:compatibility, :model_mapping, :run_validation)

# ===========================================================================
# 拒否・警告の型
# ===========================================================================

function _cross_model_check_detail(code::Symbol, detail::AbstractString)
    isempty(detail) &&
        throw(ArgumentError("CrossModelRejection.detail は空であってはいけません"))
    for forbidden in ("影響が無い", "効果が無い")
        occursin(forbidden, detail) && throw(
            ArgumentError(
                "detail に「$(forbidden)」を含めることはできません。モデル・契約が構造上その事象を" *
                "表現しない／受理しない旨を記述する（設計 §11.2）",
            ),
        )
    end
    if code === :unmapped_target_concept
        any(occursin(kw, detail) for kw in ("構造上", "表現しない", "表現できない")) ||
            throw(
                ArgumentError(
                    "CrossModelRejection(code=:unmapped_target_concept).detail は「モデルが構造上その概念を" *
                    "表現しない」旨を含めなければなりません（設計 §7.3）",
                ),
            )
    end
    return nothing
end

"""
    CrossModelRejection

cross-model の構造化拒否（設計 §11.2）。`CROSS_MODEL_REJECTION_CODES` のいずれかの `code` と、
`CROSS_MODEL_STAGES` のいずれかの `stage` を持つ。`detail` は日本語で、「影響が無い」
「効果が無い」を含めない。
"""
struct CrossModelRejection
    code::Symbol
    stage::Symbol
    subject_ids::Vector{String}
    detail::String

    function CrossModelRejection(;
        code::Symbol,
        detail::AbstractString,
        stage::Symbol = :compatibility,
        subject_ids::Vector{String} = String[],
    )
        code in CROSS_MODEL_REJECTION_CODES || throw(
            ArgumentError(
                "CrossModelRejection.code=$(code) は CROSS_MODEL_REJECTION_CODES のいずれかでなければなりません",
            ),
        )
        stage in CROSS_MODEL_STAGES || throw(
            ArgumentError(
                "CrossModelRejection.stage=$(stage) は $(collect(CROSS_MODEL_STAGES)) のいずれかでなければなりません",
            ),
        )
        _cross_model_check_detail(code, detail)
        return new(code, stage, sort(subject_ids), String(detail))
    end
end

"""
    CrossModelWarning

cross-model の警告（設計 §11.3）。実行を妨げない。
"""
struct CrossModelWarning
    code::Symbol
    subject_ids::Vector{String}
    detail::String

    function CrossModelWarning(;
        code::Symbol,
        detail::AbstractString,
        subject_ids::Vector{String} = String[],
    )
        code in CROSS_MODEL_WARNING_CODES || throw(
            ArgumentError(
                "CrossModelWarning.code=$(code) は CROSS_MODEL_WARNING_CODES のいずれかでなければなりません",
            ),
        )
        isempty(detail) &&
            throw(ArgumentError("CrossModelWarning.detail は空であってはいけません"))
        return new(code, sort(subject_ids), String(detail))
    end
end

_cross_model_rejection_to_dict(r::CrossModelRejection) = Dict{String, Any}(
    "code" => String(r.code),
    "stage" => String(r.stage),
    "subject_ids" => copy(r.subject_ids),
    "detail" => r.detail,
)

_cross_model_warning_to_dict(w::CrossModelWarning) = Dict{String, Any}(
    "code" => String(w.code),
    "subject_ids" => copy(w.subject_ids),
    "detail" => w.detail,
)

# ===========================================================================
# compatibility report
# ===========================================================================

"""
    CrossModelGroupCoverage

target group ごとの被覆（設計 §8.4）。`covered_share` は `:declared_target_share` では
`Σ w_j`、他の basis では 1.0。weight が不正で計算できない場合は `nothing`。
`uncovered_share` の扱いは `CROSS_MODEL_UNCOVERED_SHARE_TREATMENT`（本入力の対象外）。
"""
struct CrossModelGroupCoverage
    target_group::Symbol
    target_concept::Symbol
    weight_basis::Symbol
    members::Vector{String}
    producer_set::Vector{String}
    covered_share::Union{Float64, Nothing}
    uncovered_share::Union{Float64, Nothing}
end

"""
    CrossModelCompatibilityReport

`check_cross_model_compatibility` の戻り値（設計 §11.4）。`decision` は `rejections` が空の
ときに限り `:accepted`（構築時に検査する）。

## フィールド
- `decision::Symbol`: `:accepted` / `:rejected`。
- `upstream::UpstreamModelArtifactRef`
- `mapping_id` / `mapping_version` / `mapping_hash`
- `target_model::Symbol` / `target_profile_version` / `target_geography`: profile が無い場合
  `nothing`。
- `transmission_mode::Symbol` / `geography_status::Symbol`（`:accepted`/`:rejected`/
  `:not_evaluated`。target profile が無く判定できない場合は `:not_evaluated`）/
  `claim_scope`（geography 受理時のみ非 `nothing`）
- `classification_status::Symbol`
- `time_status::Symbol` / `source_period_unit::Symbol` / `aggregation_rule` /
  `calendar_anchor::Union{Date,Nothing}` / `timing_quarters`（受理時の四半期数）
- `source_sectors_total::Int` / `member_sectors` / `producer_set_sectors` /
  `unmapped_source_sectors` / `group_coverage` / `target_groups_without_source`
- `rejections::Vector{CrossModelRejection}`: 全件。
- `warnings::Vector{CrossModelWarning}`
"""
struct CrossModelCompatibilityReport
    decision::Symbol
    upstream::UpstreamModelArtifactRef
    mapping_id::String
    mapping_version::String
    mapping_hash::String
    target_model::Symbol
    target_profile_version::Union{String, Nothing}
    target_geography::Union{CrossModelGeographyRef, Nothing}
    transmission_mode::Symbol
    geography_status::Symbol
    claim_scope::Union{Symbol, Nothing}
    classification_status::Symbol
    time_status::Symbol
    source_period_unit::Symbol
    aggregation_rule::Union{Symbol, Nothing}
    calendar_anchor::Union{Date, Nothing}
    timing_quarters::Union{Int, Nothing}
    source_sectors_total::Int
    member_sectors::Vector{String}
    producer_set_sectors::Vector{String}
    unmapped_source_sectors::Vector{String}
    group_coverage::Vector{CrossModelGroupCoverage}
    target_groups_without_source::Vector{Symbol}
    rejections::Vector{CrossModelRejection}
    warnings::Vector{CrossModelWarning}

    function CrossModelCompatibilityReport(args...)
        length(args) == fieldcount(CrossModelCompatibilityReport) || throw(
            ArgumentError("CrossModelCompatibilityReport のフィールド数が一致しません"),
        )
        decision = args[1]
        rejections = args[end - 1]
        decision === (isempty(rejections) ? :accepted : :rejected) || throw(
            ArgumentError(
                "CrossModelCompatibilityReport.decision=$(decision) は rejections の有無と一致しなければなりません" *
                "（accepted は拒否 0 件のときに限る。設計 §3.4 UM-4）",
            ),
        )
        return new(args...)
    end
end

# ===========================================================================
# 判定の内部ヘルパ
# ===========================================================================

"`YYYY-MM-DD`（ISO 8601 基本形の日付のみ）を解釈する。それ以外は `nothing`（設計 §9.3）。"
function _cross_model_parse_anchor(s::AbstractString)
    occursin(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$", s) || return nothing
    return tryparse(Date, s, dateformat"yyyy-mm-dd")
end

_cross_model_is_quarter_start(d::Date) =
    Dates.day(d) == 1 && Dates.month(d) in (1, 4, 7, 10)

"""
    _cross_model_quarterly_ratios(ratios, unit) -> Vector{Float64}

source 期間の実現産出比を DME 四半期へ集約する（設計 §9.2）。`:quarter` は恒等、`:month` は
連続する 3 か月の算術平均（PNE の各期間が同一の baseline 1 期間分で正規化されているため厳密）。
呼び出し側が `length(ratios)` の 3 の倍数性を保証する。
"""
function _cross_model_quarterly_ratios(ratios::Vector{Float64}, unit::Symbol)
    unit === :quarter && return copy(ratios)
    unit === :month || throw(ArgumentError("未対応の period_unit: $(unit)"))
    q = length(ratios) ÷ 3
    return Float64[
        (ratios[3k + 1] + ratios[3k + 2] + ratios[3k + 3]) / 3 for k in 0:(q - 1)
    ]
end

"""
    _cross_model_group_values(weight_basis, ratios, weights) -> (values, value_semantics)

時間集約済みの member ごとの四半期比 `ratios`（`sector_id` 昇順）と有効 weight `weights` から、
群の四半期パスを計算する（設計 §8.3）。加算は `sector_id` 昇順の逐次加算に固定する（設計 §9.7）。

- `:declared_target_share`: `−Σ w_j (1 − r_j)`（`:target_relative_change`）。再正規化しない。
- `:source_baseline_output` / `:direct_one_to_one`: `Σ w_j r_j`（`:group_realized_output_ratio`）。
  `weights` は呼び出し側が群内正規化済み（和 1）で渡す。
"""
function _cross_model_group_values(
    weight_basis::Symbol,
    ratios::Vector{Vector{Float64}},
    weights::Vector{Float64},
)
    isempty(ratios) && throw(ArgumentError("群の member が空です"))
    length(ratios) == length(weights) ||
        throw(ArgumentError("ratios と weights の長さが一致しません"))
    q = length(ratios[1])
    all(r -> length(r) == q, ratios) ||
        throw(ArgumentError("member の四半期数が一致しません"))
    values = zeros(Float64, q)
    if weight_basis === :declared_target_share
        for k in 1:q
            s = 0.0
            for (r, w) in zip(ratios, weights)
                s -= w * (1.0 - r[k])
            end
            values[k] = s
        end
        return values, :target_relative_change
    elseif weight_basis in (:source_baseline_output, :direct_one_to_one)
        for k in 1:q
            s = 0.0
            for (r, w) in zip(ratios, weights)
                s += w * r[k]
            end
            values[k] = s
        end
        return values, :group_realized_output_ratio
    end
    throw(ArgumentError("未知の weight_basis: $(weight_basis)"))
end

"`:source_baseline_output` の有効 weight（`baseline_output` を `sector_id` 昇順に逐次加算して正規化）。"
function _cross_model_baseline_weights(baselines::Vector{Float64})
    total = 0.0
    for b in baselines
        total += b
    end
    total > 0.0 || throw(ArgumentError("baseline_output の合計が 0 です"))
    return Float64[b / total for b in baselines]
end

_cross_model_estimated_count(c::Dict{Symbol, Int}) =
    get(c, :estimated, 0) + get(c, :inferred, 0)

# ===========================================================================
# check_cross_model_compatibility（`X2`）
# ===========================================================================

"""
    check_cross_model_compatibility(artifact::PNESectorOutputPath, mapping::CrossModelMapping)
        -> CrossModelCompatibilityReport

上流 artifact と mapping artifact を target model profile（`mapping.target_model` で registry から
引く）と照合し、互換性 report を返す（設計 §6–§9・§11.4、`X2`）。**例外を投げない**
（引数の型が不正な場合を除く）。不整合は `rejections` へ全件列挙する。

判定の概要（すべて独立に評価する）:
1. 上流の状態: `status = unsupported`・error 警告は拒否。info/warning 警告は転記。
2. target profile: registry に無いモデル・mapping registry version の不一致は
   `unsupported_target_model`。
3. geography: `(system, economy_id)` の完全一致で判定し既定 fail closed（設計 §6）。
4. classification: `(system, version, level)` の完全一致（設計 §8.5）。
5. sector 割当: 未知 sector・重複割当・unmapped の宣言漏れ（設計 §8.4）。
6. group: 概念・target group・weight basis・weight・`DD-6`（producer set の産出不変）。
7. 時間軸: 受理する `period_unit`・anchor・部分四半期・horizon 末の回復（設計 §9）。
"""
function check_cross_model_compatibility(a::PNESectorOutputPath, m::CrossModelMapping)
    rejections = CrossModelRejection[]
    warnings = CrossModelWarning[]
    reject!(code, detail; subjects = String[]) = push!(
        rejections,
        CrossModelRejection(; code = code, detail = detail, subject_ids = subjects),
    )
    warn!(code, detail; subjects = String[]) = push!(
        warnings,
        CrossModelWarning(; code = code, detail = detail, subject_ids = subjects),
    )

    upstream = upstream_artifact_ref(a)

    # ---- 1. 上流の状態（設計 §5.2） ----------------------------------------
    if a.status === :unsupported
        reject!(
            :upstream_status_unsupported,
            "PNE artifact の status が unsupported です（理由: " *
            join([r.code for r in a.unsupported_reasons], ", ") *
            "）。部分値は診断用にのみ保持し、モデルへ適用しません",
            subjects = [a.artifact_id],
        )
    end
    error_codes = [w.code for w in a.warnings if w.severity === :error]
    if !isempty(error_codes)
        reject!(
            :upstream_error_warning,
            "PNE artifact に severity=error の警告があります: $(error_codes)",
            subjects = error_codes,
        )
    end
    for w in a.warnings
        w.severity === :error && continue
        warn!(
            :upstream_warning_carried,
            "PNE 警告（$(w.severity)・$(w.source)）: $(w.message)",
            subjects = [w.code],
        )
    end
    if a.source_provenance.is_synthetic
        warn!(
            :synthetic_upstream_source,
            "上流 network は synthetic です。実在の経済・部門・企業を表しません",
            subjects = [a.source.network_id],
        )
    end
    n_est =
        _cross_model_estimated_count(a.source_provenance.node_estimation_status_counts) +
        _cross_model_estimated_count(a.source_provenance.edge_estimation_status_counts)
    if n_est > 0
        warn!(
            :upstream_estimated_inputs,
            "上流 network に estimated / inferred の node・edge が $(n_est) 件含まれます。観測された取引網ではありません",
            subjects = [a.source.network_id],
        )
    end

    # ---- 2. target profile（設計 §7.1–§7.2） --------------------------------
    profile = cross_model_target_profile(m.target_model)
    if profile === nothing
        reject!(
            :unsupported_target_model,
            "target_model=$(m.target_model) には cross-model の target profile が登録されていません" *
            "（v1 で受理するのは :capex_credit_cycle のみ。設計 §7.1）",
            subjects = [String(m.target_model)],
        )
    elseif m.target_model_mapping_version != profile.model_mapping_version
        reject!(
            :unsupported_target_model,
            "mapping の target_model_mapping_version=\"$(m.target_model_mapping_version)\" は " *
            "target profile の \"$(profile.model_mapping_version)\" と一致しません",
            subjects = [String(m.target_model)],
        )
    end

    # ---- 3. geography（設計 §6） -------------------------------------------
    n_before_geo = length(rejections)
    source_geo = CrossModelGeographyRef(a.geography.system, a.geography.economy_id)
    mode = m.transmission.mode
    claim_scope = nothing
    if m.source_geography != source_geo
        reject!(
            :geography_declaration_inconsistent,
            "mapping の source_geography=($(m.source_geography.system), $(m.source_geography.economy_id)) が " *
            "PNE artifact の geography=($(source_geo.system), $(source_geo.economy_id)) と一致しません",
            subjects = [m.mapping_id],
        )
    end
    if profile !== nothing && m.target_geography != profile.geography
        reject!(
            :geography_declaration_inconsistent,
            "mapping の target_geography=($(m.target_geography.system), $(m.target_geography.economy_id)) が " *
            "target profile の経済圏=($(profile.geography.system), $(profile.geography.economy_id)) と一致しません",
            subjects = [m.mapping_id],
        )
    end
    if m.transmission.transmission_ref !== nothing && mode !== :explicit_cross_economy
        reject!(
            :transmission_mode_inconsistent,
            "transmission_ref は mode=explicit_cross_economy のときのみ宣言できます（実際の mode: $(mode)）",
            subjects = [m.mapping_id],
        )
    end
    if profile !== nothing
        target_geo = profile.geography
        if source_geo == target_geo
            if mode === :same_economy
                claim_scope = :same_economy_model_derived
            else
                reject!(
                    :transmission_mode_inconsistent,
                    "source と target は同一経済圏（$(source_geo.system):$(source_geo.economy_id)）です。" *
                    "同一経済圏に $(mode) を宣言できません（設計 §6.2）",
                    subjects = [m.mapping_id],
                )
            end
        elseif mode === :same_economy
            reject!(
                :geography_mismatch,
                "source 経済圏（$(source_geo.system):$(source_geo.economy_id)）と target model の経済圏" *
                "（$(target_geo.system):$(target_geo.economy_id)）が異なります。部門ラベル・経済圏名の" *
                "一致は対応の根拠になりません（設計 §6.1・§6.5）",
                subjects = [source_geo.economy_id, target_geo.economy_id],
            )
        elseif mode === :explicit_cross_economy
            ref = m.transmission.transmission_ref
            if ref === nothing
                reject!(
                    :transmission_mode_inconsistent,
                    "mode=explicit_cross_economy には transmission_ref が必須です（設計 §6.4）",
                    subjects = [m.mapping_id],
                )
            else
                if ref.source_economy != source_geo ||
                   ref.target_economy != target_geo ||
                   ref.target_model !== m.target_model
                    reject!(
                        :geography_declaration_inconsistent,
                        "transmission_ref の source/target economy・target_model が PNE artifact・" *
                        "target profile・mapping と一致しません",
                        subjects = [ref.artifact_id],
                    )
                end
                if !(ref.contract_version in ACCEPTED_CROSS_ECONOMY_TRANSMISSION_CONTRACTS)
                    reject!(
                        :cross_economy_transmission_unavailable,
                        "transmission contract \"$(ref.contract_version)\" は受理されません。v1 が受理する " *
                        "cross-economy transmission contract は存在しません（設計 §6.4）",
                        subjects = [ref.artifact_id],
                    )
                end
            end
        else # :hypothetical_override
            if isempty(strip(m.transmission.justification))
                reject!(
                    :transmission_mode_inconsistent,
                    "mode=hypothetical_override には justification（何のための架空入力か）が必須です（設計 §6.3）",
                    subjects = [m.mapping_id],
                )
            end
            if pne_is_synthetic_source(a)
                claim_scope = :hypothetical_fictional
                warn!(
                    :hypothetical_transmission,
                    "hypothetical_override: 実在経済間の伝播を主張しない架空入力として " *
                    "$(source_geo.economy_id) の結果を $(target_geo.economy_id) の target model へ入れます",
                    subjects = [source_geo.economy_id, target_geo.economy_id],
                )
            else
                reject!(
                    :hypothetical_override_requires_synthetic_source,
                    "hypothetical_override は synthetic source（is_synthetic=true かつ全部門 " *
                    "source_data_status=synthetic）に限ります。実データの結果を別経済のモデルへ入れる" *
                    "経路はありません（設計 §6.3）",
                    subjects = [a.artifact_id],
                )
            end
        end
    end
    geography_rejected = length(rejections) > n_before_geo
    geography_status =
        geography_rejected ? :rejected : (profile === nothing ? :not_evaluated : :accepted)
    geography_status === :accepted || (claim_scope = nothing)

    # ---- 4. classification（設計 §8.5） -------------------------------------
    cls = a.classification
    classification_ok =
        m.source_classification ==
        CrossModelClassificationRef(cls.system, cls.version, cls.level)
    if !classification_ok
        reject!(
            :classification_mismatch,
            "mapping の source_classification=($(m.source_classification.system), " *
            "$(m.source_classification.version), $(m.source_classification.level)) が PNE artifact の " *
            "classification=($(cls.system), $(cls.version), $(cls.level)) と一致しません",
            subjects = [m.mapping_id],
        )
    end

    # ---- 5. sector 割当（設計 §8.4・§8.5） ------------------------------------
    all_ids = pne_sector_ids(a)
    id_set = Set(all_ids)
    assigned_counts = Dict{String, Int}()
    member_ids = String[]
    producer_ids = String[]
    for g in m.groups
        for mem in g.members
            assigned_counts[mem.sector_id] = get(assigned_counts, mem.sector_id, 0) + 1
            push!(member_ids, mem.sector_id)
        end
        for p in g.producer_set
            assigned_counts[p] = get(assigned_counts, p, 0) + 1
            push!(producer_ids, p)
        end
    end
    unknown = sort(
        unique([
            s for
            s in vcat(member_ids, producer_ids, m.declared_unmapped_source_sectors) if
            !(s in id_set)
        ]),
    )
    if !isempty(unknown)
        reject!(
            :unknown_source_sector,
            "mapping が PNE artifact に存在しない sector_id を参照しています: $(unknown)",
            subjects = unknown,
        )
    end
    duplicated = sort([s for (s, c) in assigned_counts if c > 1])
    if !isempty(duplicated)
        reject!(
            :duplicate_sector_assignment,
            "1 つの PNE 部門が複数の group・member・producer set に割り当てられています: $(duplicated)" *
            "（one-to-many の按分は v1 では受理しません。設計 §8.5）",
            subjects = duplicated,
        )
    end
    actual_unmapped = sort([s for s in all_ids if !haskey(assigned_counts, s)])
    declared_unmapped = m.declared_unmapped_source_sectors
    if Set(actual_unmapped) != Set(declared_unmapped)
        undeclared = sort(collect(setdiff(Set(actual_unmapped), Set(declared_unmapped))))
        over = sort(collect(setdiff(Set(declared_unmapped), Set(actual_unmapped))))
        reject!(
            :unmapped_sector_undeclared,
            "どの group にも属さない PNE 部門は declared_unmapped_source_sectors に明示しなければなりません" *
            "（宣言漏れ: $(undeclared)・宣言と実際の不一致: $(over)。設計 §8.4）",
            subjects = sort(vcat(undeclared, over)),
        )
    end
    if !isempty(actual_unmapped)
        warn!(
            :unmapped_source_sectors_present,
            "$(length(actual_unmapped)) 件の PNE 部門はどの target group にも属さず、入力に用いません" *
            "（0 としても 1 としても扱いません）",
            subjects = actual_unmapped,
        )
    end

    # ---- 6. group ごとの概念・weight・producer set ----------------------------
    sector_by_id = Dict(s.sector_id => s for s in a.sectors)
    coverages = CrossModelGroupCoverage[]
    for g in m.groups
        gname = String(g.target_group)
        mem_ids = [mem.sector_id for mem in g.members]
        if profile !== nothing
            concept_ok = g.target_concept in cross_model_accepted_concepts(profile)
            group_concept = _cross_model_profile_group_concept(profile, g.target_group)
            if !concept_ok
                reject!(
                    :unmapped_target_concept,
                    "target model $(profile.model) は target_concept=$(g.target_concept) を構造上表現しません" *
                    "（受理する概念: $(collect(cross_model_accepted_concepts(profile)))。近い変数への代理は" *
                    "行いません。設計 §7.3）",
                    subjects = [gname],
                )
            elseif group_concept !== g.target_concept
                reject!(
                    :unmapped_target_concept,
                    "target model $(profile.model) は target_group=$(g.target_group) を構造上表現しません" *
                    "（$(g.target_concept) の target group: " *
                    "$([first(x) for x in profile.target_groups if last(x) === g.target_concept])）",
                    subjects = [gname],
                )
            end
            allowed = _cross_model_profile_allowed_bases(profile, g.target_concept)
            if concept_ok && !(g.weight_basis in allowed)
                reject!(
                    :weight_basis_not_allowed,
                    "target_concept=$(g.target_concept) は weight_basis=$(g.weight_basis) を許しません" *
                    "（許容: $(collect(allowed))。設計 §7.2・§8.3）",
                    subjects = [gname],
                )
            end
        end

        covered = nothing
        if g.weight_basis === :declared_target_share
            ws = [mem.weight for mem in g.members]
            bad = [
                mem.sector_id for mem in g.members if
                mem.weight === nothing || !isfinite(mem.weight) || mem.weight <= 0.0
            ]
            wp = g.weight_provenance
            problems = String[]
            isempty(bad) || push!(problems, "weight が欠落・非有限・非正の member: $(bad)")
            if isempty(bad)
                total = 0.0
                for w in ws
                    total += w
                end
                if total > 1.0 + PNE_RATIO_ABS_TOL
                    push!(problems, "Σw=$(total) が 1 を超えています（再正規化しません）")
                else
                    covered = total
                end
            end
            if wp === nothing ||
               isempty(wp.source) ||
               isempty(wp.version) ||
               isempty(wp.method)
                push!(
                    problems,
                    "weight_provenance（source・version・method）が欠落しています",
                )
            end
            if !isempty(problems)
                reject!(
                    :invalid_weights,
                    "group $(gname): " * join(problems, "／") * "（設計 §7.4 DD-4）",
                    subjects = [gname],
                )
            end
        elseif g.weight_basis === :source_baseline_output
            given = [mem.sector_id for mem in g.members if mem.weight !== nothing]
            if !isempty(given)
                reject!(
                    :invalid_weights,
                    "group $(gname): weight_basis=source_baseline_output の member は weight を宣言できません: $(given)",
                    subjects = [gname],
                )
            end
            known = [sector_by_id[i] for i in mem_ids if haskey(sector_by_id, i)]
            no_base = [s.sector_id for s in known if s.baseline_output === nothing]
            if !isempty(no_base)
                reject!(
                    :baseline_output_missing,
                    "group $(gname): baseline_output を持たない member があります: $(no_base)" *
                    "（非加重平均へ落としません。設計 §8.3）",
                    subjects = no_base,
                )
            else
                units = unique([s.baseline_output.unit for s in known])
                if length(units) > 1
                    reject!(
                        :baseline_output_unit_mismatch,
                        "group $(gname): member の baseline_output の単位が一致しません: $(units)",
                        subjects = [gname],
                    )
                elseif !isempty(known) && all(s -> s.baseline_output.value == 0.0, known)
                    reject!(
                        :invalid_weights,
                        "group $(gname): baseline_output の合計が 0 で正規化できません",
                        subjects = [gname],
                    )
                end
            end
            covered = 1.0
        else # :direct_one_to_one
            problems = String[]
            length(g.members) == 1 ||
                push!(problems, "member はちょうど 1 件でなければなりません")
            w = g.members[1].weight
            (w === nothing || w == 1.0) ||
                push!(problems, "weight は null または 1 でなければなりません")
            if !isempty(problems)
                reject!(
                    :invalid_weights,
                    "group $(gname): weight_basis=direct_one_to_one: " *
                    join(problems, "／"),
                    subjects = [gname],
                )
            end
            covered = 1.0
        end

        if g.target_concept === :derived_out_of_model_demand
            if isempty(g.producer_set)
                reason = g.producer_set_absent_reason
                if reason === nothing || isempty(strip(reason))
                    reject!(
                        :producer_set_undeclared,
                        "group $(gname): derived_out_of_model_demand には target 製品の producer_set か " *
                        "producer_set_absent_reason が必須です（設計 §7.4 DD-6）",
                        subjects = [gname],
                    )
                else
                    warn!(
                        :producer_set_absent,
                        "group $(gname): producer set が空です（理由: $(reason)）。DD-6 は宣言に基づきます",
                        subjects = [gname],
                    )
                end
            else
                constrained = String[]
                for p in g.producer_set
                    s = get(sector_by_id, p, nothing)
                    s === nothing && continue
                    all(r -> abs(1.0 - r) <= PNE_RATIO_ABS_TOL, s.realized_output_ratio) ||
                        push!(constrained, p)
                end
                if !isempty(constrained)
                    reject!(
                        :own_supply_constraint_present,
                        "group $(gname): target 製品の producer set の産出が baseline を下回る期があります: " *
                        "$(constrained)。顧客の産出低下は target 製品の供給制約の結果であり、派生需要として" *
                        "読めません（設計 §7.4 DD-6）",
                        subjects = constrained,
                    )
                end
            end
        end

        uncovered = covered === nothing ? nothing : max(0.0, 1.0 - covered)
        if g.weight_basis === :declared_target_share &&
           covered !== nothing &&
           covered < 1.0 - PNE_RATIO_ABS_TOL
            warn!(
                :partial_target_coverage,
                "group $(gname): mapping が target 変数の baseline のうち $(covered) をカバーします。" *
                "残り $(uncovered) は本入力の対象外です（再正規化しません。設計 §8.4）",
                subjects = [gname],
            )
        end
        push!(
            coverages,
            CrossModelGroupCoverage(
                g.target_group,
                g.target_concept,
                g.weight_basis,
                mem_ids,
                copy(g.producer_set),
                covered,
                uncovered,
            ),
        )
    end
    groups_without_source =
        profile === nothing ? Symbol[] :
        sort(
            [
                first(x) for x in profile.target_groups if
                !any(g -> g.target_group === first(x), m.groups)
            ];
            by = String,
        )

    # ---- 7. 時間軸（設計 §9） ----------------------------------------------
    n_before_time = length(rejections)
    unit = a.time.period_unit
    aggregation_rule = nothing
    if unit in (:week, :day, :year)
        reject!(
            :unsupported_source_period_unit,
            "period_unit=$(unit) は受理しません（v1 は quarter と month のみ。year → quarter の分解・" *
            "week/day の按分は行いません。設計 §9.1）",
            subjects = [String(unit)],
        )
    elseif unit === :baseline_period
        reject!(
            :ambiguous_source_period_unit,
            "period_unit=baseline_period は期間の長さを宣言していません（設計 §9.1）",
            subjects = [String(unit)],
        )
    elseif unit !== m.time.expected_source_period_unit
        reject!(
            :unsupported_source_period_unit,
            "PNE artifact の period_unit=$(unit) は mapping の expected_source_period_unit=" *
            "$(m.time.expected_source_period_unit) と一致しません",
            subjects = [String(unit)],
        )
    else
        aggregation_rule = m.time.aggregation_rule
    end
    anchor = nothing
    raw_anchor = a.time.calendar_anchor
    if raw_anchor !== nothing
        parsed = _cross_model_parse_anchor(raw_anchor)
        if parsed === nothing
            reject!(
                :calendar_anchor_invalid,
                "calendar_anchor=\"$(raw_anchor)\" は YYYY-MM-DD 形式の日付ではありません（設計 §9.3）",
                subjects = [raw_anchor],
            )
        elseif !_cross_model_is_quarter_start(parsed)
            reject!(
                :calendar_anchor_misaligned,
                "calendar_anchor=$(parsed) は四半期初日（1/4/7/10 月の 1 日）ではありません（設計 §9.3）",
                subjects = [raw_anchor],
            )
        else
            anchor = parsed
        end
    elseif unit === :month
        reject!(
            :calendar_anchor_required,
            "period_unit=month には四半期の区切りを決める calendar_anchor が必須です（設計 §9.3）",
            subjects = [a.artifact_id],
        )
    end
    n = a.time.available_periods
    if unit === :month && n % 3 != 0
        reject!(
            :partial_quarter,
            "period_unit=month の available_periods=$(n) が 3 の倍数ではありません。部分四半期を" *
            "外挿・補完しません（設計 §9.4）",
            subjects = [a.artifact_id],
        )
    end
    timing_quarters = nothing
    time_ok_for_path =
        aggregation_rule !== nothing && n > 0 && !(unit === :month && n % 3 != 0)
    if time_ok_for_path
        unrecovered = String[]
        for g in m.groups, mem in g.members
            s = get(sector_by_id, mem.sector_id, nothing)
            s === nothing && continue
            q = _cross_model_quarterly_ratios(s.realized_output_ratio, unit)
            abs(1.0 - q[end]) <= PNE_RATIO_ABS_TOL || push!(unrecovered, mem.sector_id)
        end
        unrecovered = sort(unique(unrecovered))
        if !isempty(unrecovered)
            reject!(
                :upstream_path_unrecovered_at_horizon_end,
                "PNE horizon 末の四半期で回復していない member があります: $(unrecovered)。horizon 後の" *
                "持続・回復を仮定しません（設計 §9.6）",
                subjects = unrecovered,
            )
        end
    end
    time_status = length(rejections) > n_before_time ? :rejected : :accepted
    if time_status === :accepted && time_ok_for_path
        timing_quarters = unit === :quarter ? n : n ÷ 3
    end

    decision = isempty(rejections) ? :accepted : :rejected
    return CrossModelCompatibilityReport(
        decision,
        upstream,
        m.mapping_id,
        m.mapping_version,
        cross_model_mapping_hash(m),
        m.target_model,
        profile === nothing ? nothing : profile.profile_version,
        profile === nothing ? nothing : profile.geography,
        mode,
        geography_status,
        claim_scope,
        classification_ok ? :accepted : :rejected,
        time_status,
        unit,
        aggregation_rule,
        anchor,
        timing_quarters,
        length(all_ids),
        sort(unique(member_ids)),
        sort(unique(producer_ids)),
        actual_unmapped,
        coverages,
        groups_without_source,
        rejections,
        warnings,
    )
end

# ===========================================================================
# report の dict 化・hash
# ===========================================================================

function _cross_model_coverage_to_dict(c::CrossModelGroupCoverage)
    return Dict{String, Any}(
        "target_group" => String(c.target_group),
        "target_concept" => String(c.target_concept),
        "weight_basis" => String(c.weight_basis),
        "members" => copy(c.members),
        "producer_set" => copy(c.producer_set),
        "covered_share" => c.covered_share,
        "uncovered_share" => c.uncovered_share,
        "uncovered_share_treatment" => String(CROSS_MODEL_UNCOVERED_SHARE_TREATMENT),
    )
end

_cross_model_issue_sort_key(d::Dict{String, Any}) =
    (get(d, "stage", ""), d["code"], join(d["subject_ids"], "\u1f"), d["detail"])

"""
    cross_model_compatibility_report_to_dict(r::CrossModelCompatibilityReport;
                                             include_audit::Bool = true) -> Dict{String,Any}

report を ASCII キーの `Dict` へ写す（設計 §11.4）。`rejections`・`warnings` は
`(stage, code, subject_ids, detail)` で整列する。生成時刻を含めない。`include_audit = false` の
とき hash 対象外の `upstream.source_bytes_sha256` を含めない。
"""
function cross_model_compatibility_report_to_dict(
    r::CrossModelCompatibilityReport;
    include_audit::Bool = true,
)
    rej = [_cross_model_rejection_to_dict(x) for x in r.rejections]
    wrn = [_cross_model_warning_to_dict(x) for x in r.warnings]
    sort!(rej; by = _cross_model_issue_sort_key)
    sort!(wrn; by = _cross_model_issue_sort_key)
    return Dict{String, Any}(
        "schema_version" => CROSS_MODEL_COMPATIBILITY_REPORT_SCHEMA_VERSION,
        "contract_version" => CROSS_MODEL_INPUT_CONTRACT_VERSION,
        "decision" => String(r.decision),
        "upstream" =>
            upstream_artifact_ref_to_dict(r.upstream; include_audit = include_audit),
        "mapping" => Dict{String, Any}(
            "mapping_id" => r.mapping_id,
            "mapping_version" => r.mapping_version,
            "mapping_hash" => r.mapping_hash,
        ),
        "target" => Dict{String, Any}(
            "model" => String(r.target_model),
            "profile_version" => r.target_profile_version,
            "geography" =>
                r.target_geography === nothing ? nothing :
                _cross_model_geography_to_dict(r.target_geography),
        ),
        "geography" => Dict{String, Any}(
            "status" => String(r.geography_status),
            "source" => Dict{String, Any}(
                "system" => r.upstream.geography_system,
                "economy_id" => r.upstream.geography_economy_id,
            ),
            "transmission_mode" => String(r.transmission_mode),
            "claim_scope" =>
                r.claim_scope === nothing ? nothing : String(r.claim_scope),
        ),
        "classification" => Dict{String, Any}(
            "status" => String(r.classification_status),
            "source" => Dict{String, Any}(
                "system" => r.upstream.classification_system,
                "version" => r.upstream.classification_version,
                "level" => r.upstream.classification_level,
            ),
        ),
        "time" => Dict{String, Any}(
            "status" => String(r.time_status),
            "source_period_unit" => String(r.source_period_unit),
            "aggregation_rule" =>
                r.aggregation_rule === nothing ? nothing : String(r.aggregation_rule),
            "calendar_anchor" =>
                r.calendar_anchor === nothing ? nothing :
                Dates.format(r.calendar_anchor, "yyyy-mm-dd"),
            "timing_quarters" => r.timing_quarters,
            "partial_quarter" => "reject",
            "post_horizon" => "require_recovered",
        ),
        "coverage" => Dict{String, Any}(
            "source_sectors_total" => r.source_sectors_total,
            "member_sectors" => copy(r.member_sectors),
            "producer_set_sectors" => copy(r.producer_set_sectors),
            "unmapped_source_sectors" => copy(r.unmapped_source_sectors),
            "groups" => Any[_cross_model_coverage_to_dict(c) for c in r.group_coverage],
            "target_groups_without_source" =>
                String[String(g) for g in r.target_groups_without_source],
        ),
        "rejections" => rej,
        "warnings" => wrn,
    )
end

"""
    cross_model_compatibility_report_hash(r::CrossModelCompatibilityReport) -> String

report の RFC 8785 正準 JSON の SHA-256（`"sha256:…"`、設計 §12.2）。監査属性
`upstream.source_bytes_sha256` は hash 対象から除く（同じ内容を別のバイト列で受け取っても
同じ hash になる）。
"""
cross_model_compatibility_report_hash(r::CrossModelCompatibilityReport) =
    "sha256:" * sha256_hex_of_canonical(
        cross_model_compatibility_report_to_dict(r; include_audit = false),
    )

# ===========================================================================
# apply_cross_model_mapping（`X3`）
# ===========================================================================

"""
    MappedGroupPath

target group ごとの DME 四半期パス（`X3` の出力、設計 §4・§8.3・§9）。`values[k]` は
四半期 `k = 0 … Q-1`（PNE 期 0 を含む四半期が `k = 0`）の値で、意味は `value_semantics`。
モデル時間軸への配置（`t0`）は #282（`ModelDerivedInput`）が `anchor_quarter` または明示の
`t_start` から決める。

provenance: `upstream_content_hash`・`mapping_hash`・`compatibility_report_hash` により、
PNE artifact・mapping artifact・report へ遡れる。
"""
struct MappedGroupPath
    target_group::Symbol
    target_concept::Symbol
    weight_basis::Symbol
    value_semantics::Symbol
    values::Vector{Float64}
    anchor_quarter::Union{CalendarQuarter, Nothing}
    source_period_unit::Symbol
    aggregation_rule::Symbol
    members::Vector{String}
    effective_weights::Vector{Float64}
    covered_share::Float64
    uncovered_share::Float64
    producer_set::Vector{String}
    transmission_mode::Symbol
    claim_scope::Symbol
    target_model::Symbol
    upstream_content_hash::String
    mapping_id::String
    mapping_version::String
    mapping_hash::String
    compatibility_report_hash::String
end

"""
    apply_cross_model_mapping(artifact::PNESectorOutputPath, mapping::CrossModelMapping,
                              report::CrossModelCompatibilityReport) -> Vector{MappedGroupPath}

accepted な report に限り、mapping を適用して target group ごとの四半期パスを返す（`X3`）。
戻り値は `target_group` 昇順。

処理順序は **時間集約（部門ごと）→ 部門集約（group ごと）** に固定する（設計 §9.7）。

`report` は `check_cross_model_compatibility(artifact, mapping)` を再計算した report と hash が
一致しなければならない（別の artifact・mapping の report を流用できない）。不一致は
`provenance_chain_broken`、`decision = :rejected` は `cross_model_mapping_rejected` の
`ArgumentError`（accepted でない report から入力を作る経路を持たない。設計 `UM-4`）。
"""
function apply_cross_model_mapping(
    a::PNESectorOutputPath,
    m::CrossModelMapping,
    report::CrossModelCompatibilityReport,
)
    report.decision === :accepted || throw(
        ArgumentError(
            "cross_model_mapping_rejected: report.decision=$(report.decision) です。accepted な " *
            "report 以外から mapping を適用できません（拒否 $(length(report.rejections)) 件。設計 §3.4 UM-4）",
        ),
    )
    recomputed = check_cross_model_compatibility(a, m)
    report_hash = cross_model_compatibility_report_hash(report)
    report_hash == cross_model_compatibility_report_hash(recomputed) || throw(
        ArgumentError(
            "provenance_chain_broken: 渡された report が artifact（$(a.content_hash)）と mapping" *
            "（$(cross_model_mapping_hash(m))）から再計算した report と一致しません（設計 §12.1）",
        ),
    )

    unit = report.source_period_unit
    rule = report.aggregation_rule
    anchor_quarter =
        report.calendar_anchor === nothing ? nothing : quarter_of(report.calendar_anchor)
    sector_by_id = Dict(s.sector_id => s for s in a.sectors)
    mapping_hash = cross_model_mapping_hash(m)

    paths = MappedGroupPath[]
    for g in m.groups
        ids = [mem.sector_id for mem in g.members]
        ratios = Vector{Float64}[
            _cross_model_quarterly_ratios(sector_by_id[i].realized_output_ratio, unit)
            for i in ids
        ]
        weights = if g.weight_basis === :declared_target_share
            Float64[mem.weight for mem in g.members]
        elseif g.weight_basis === :source_baseline_output
            _cross_model_baseline_weights(
                Float64[sector_by_id[i].baseline_output.value for i in ids],
            )
        else
            [1.0]
        end
        values, semantics = _cross_model_group_values(g.weight_basis, ratios, weights)
        covered = if g.weight_basis === :declared_target_share
            total = 0.0
            for w in weights
                total += w
            end
            total
        else
            1.0
        end
        push!(
            paths,
            MappedGroupPath(
                g.target_group,
                g.target_concept,
                g.weight_basis,
                semantics,
                values,
                anchor_quarter,
                unit,
                rule,
                ids,
                weights,
                covered,
                max(0.0, 1.0 - covered),
                copy(g.producer_set),
                m.transmission.mode,
                report.claim_scope,
                m.target_model,
                a.content_hash,
                m.mapping_id,
                m.mapping_version,
                mapping_hash,
                report_hash,
            ),
        )
    end
    return paths
end

"""
    mapped_group_path_to_dict(p::MappedGroupPath) -> Dict{String,Any}

`MappedGroupPath` を ASCII キーの `Dict` へ写す（監査・保存用）。
"""
function mapped_group_path_to_dict(p::MappedGroupPath)
    return Dict{String, Any}(
        "target_group" => String(p.target_group),
        "target_concept" => String(p.target_concept),
        "weight_basis" => String(p.weight_basis),
        "value_semantics" => String(p.value_semantics),
        "values" => copy(p.values),
        "anchor_quarter" =>
            p.anchor_quarter === nothing ? nothing : quarter_label(p.anchor_quarter),
        "source_period_unit" => String(p.source_period_unit),
        "aggregation_rule" => String(p.aggregation_rule),
        "members" => copy(p.members),
        "effective_weights" => copy(p.effective_weights),
        "covered_share" => p.covered_share,
        "uncovered_share" => p.uncovered_share,
        "uncovered_share_treatment" => String(CROSS_MODEL_UNCOVERED_SHARE_TREATMENT),
        "producer_set" => copy(p.producer_set),
        "transmission_mode" => String(p.transmission_mode),
        "claim_scope" => String(p.claim_scope),
        "target_model" => String(p.target_model),
        "upstream_content_hash" => p.upstream_content_hash,
        "mapping_id" => p.mapping_id,
        "mapping_version" => p.mapping_version,
        "mapping_hash" => p.mapping_hash,
        "compatibility_report_hash" => p.compatibility_report_hash,
    )
end
