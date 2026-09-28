# regenerate.jl: PNE sector-output-path 互換性判定の golden fixture（Issue #281）を決定的に
# 再生成する。
#
# 使い方（リポジトリルートから）:
#   julia --project=. test/fixtures/pne/regenerate.jl
#
# 生成物（`golden/`、すべて RFC 8785 正準 JSON）:
#   - report_ccc_hypothetical_quarterly.json: synthetic 四半期 artifact + hypothetical_override
#     mapping（accepted）の compatibility report（監査属性 source_bytes_sha256 を除く）
#   - mapped_ccc_hypothetical_quarterly.json: 同じ組の `apply_cross_model_mapping` の出力
#   - report_jp_like_same_economy.json: Japan-profile 形の artifact を US CCC へ same_economy で
#     入れようとした mapping（geography_mismatch で rejected）の compatibility report
#   - pne_contract_surface_v1.json: vendor した PNE schema の contract surface（Issue #283、drift 検出）
#   - report_ccc_producer_{quarterly,monthly}.json: PNE の実 producer 経路で生成した synthetic
#     artifact（`producer/v1/`）+ hypothetical_override mapping の compatibility report（Issue #283）
#   - e2e_producer_inputs.json: 同じ組の hash chain（content hash・mapping hash・report hash・
#     cross_model_input_set_hash）と `ModelDerivedInput`（Issue #283）
#   - report_official_jp_ccc.json: official Japan 由来 bridge の identity（`official_jp/`）を
#     US CCC へ 3 mode で入れようとした compatibility report（すべて rejected、Issue #283）
#
# 入力は `pne_fixture_builders.jl` の決定的な builder と `mappings/*.json`（DME 所有の mapping
# artifact）。vendor した PNE fixture（`sector_output_path/v1/`）・producer fixture（`producer/`）・
# official identity（`official_jp/`）は本スクリプトでは変更しない（前者は PNE 側から再コピーし
# `MANIFEST.json` を更新する。後二者は `regenerate_cross_repo.jl` が PNE / EDP の実 producer 経路で
# 生成する）。

using DME

include(joinpath(@__DIR__, "pne_fixture_builders.jl"))
include(joinpath(@__DIR__, "pne_contract_surface.jl"))

const HERE = @__DIR__

function write_canonical_json(relpath::String, d)
    path = joinpath(HERE, relpath)
    mkpath(dirname(path))
    open(path, "w") do io
        write(io, canonical_json_bytes(d))
    end
    println("wrote ", relpath)
end

mapping(name) = load_cross_model_mapping(joinpath(HERE, "mappings", name))

let a = pne_sector_output_path_from_dict(synthetic_quarterly_dict()),
    m = mapping("ccc_hypothetical_quarterly.json")

    r = check_cross_model_compatibility(a, m)
    r.decision === :accepted || error("golden の前提（accepted）が崩れています: $(r.rejections)")
    write_canonical_json(
        "golden/report_ccc_hypothetical_quarterly.json",
        cross_model_compatibility_report_to_dict(r; include_audit = false),
    )
    paths = apply_cross_model_mapping(a, m, r)
    write_canonical_json(
        "golden/mapped_ccc_hypothetical_quarterly.json",
        Dict{String, Any}("paths" => Any[mapped_group_path_to_dict(p) for p in paths]),
    )
end

let a = pne_sector_output_path_from_dict(jp_like_dict()),
    m = mapping("ccc_same_economy_jp_like.json")

    r = check_cross_model_compatibility(a, m)
    [x.code for x in r.rejections] == [:geography_mismatch] ||
        error("golden の前提（geography_mismatch のみ）が崩れています: $(r.rejections)")
    write_canonical_json(
        "golden/report_jp_like_same_economy.json",
        cross_model_compatibility_report_to_dict(r; include_audit = false),
    )
end

# ---- Issue #283: cross-repository fixture の golden ---------------------------

write_canonical_json("golden/pne_contract_surface_v1.json", pne_contract_surface(pne_vendored_schema()))

const PRODUCER_CASE_MAPPINGS = (
    ("quarterly_supplier_disruption", "ccc_producer_hypothetical_quarterly.json", "report_ccc_producer_quarterly.json"),
    ("monthly_supplier_disruption", "ccc_producer_hypothetical_monthly.json", "report_ccc_producer_monthly.json"),
)

let chain = Dict{String, Any}()
    for (case_id, mapping_file, report_file) in PRODUCER_CASE_MAPPINGS
        a = load_pne_sector_output_path(pne_producer_path(case_id))
        m = mapping(mapping_file)
        r = check_cross_model_compatibility(a, m)
        r.decision === :accepted || error("golden の前提（accepted）が崩れています: $(case_id) $(r.rejections)")
        write_canonical_json("golden/$(report_file)", cross_model_compatibility_report_to_dict(r; include_audit = false))
        xs = build_model_derived_inputs(a, m, r; timing_basis = :calendar)
        chain[case_id] = Dict{String, Any}(
            "content_hash" => a.content_hash,
            "source_bytes_sha256" => a.source_bytes_sha256,
            "mapping_id" => m.mapping_id,
            "mapping_hash" => cross_model_mapping_hash(m),
            "compatibility_report_hash" => cross_model_compatibility_report_hash(r),
            "cross_model_input_set_hash" => cross_model_input_set_hash(xs),
            "model_derived_inputs" => Any[model_derived_input_to_dict(x) for x in xs],
        )
    end
    write_canonical_json("golden/e2e_producer_inputs.json", chain)
end

let a = pne_sector_output_path_from_dict(official_jp_reconstructed_dict()),
    reports = Dict{String, Any}()

    for mode in ("same_economy", "explicit_cross_economy", "hypothetical_override")
        r = check_cross_model_compatibility(a, mapping("ccc_official_jp_$(mode).json"))
        r.decision === :rejected || error("golden の前提（rejected）が崩れています: $(mode)")
        reports[mode] = cross_model_compatibility_report_to_dict(r; include_audit = false)
    end
    write_canonical_json("golden/report_official_jp_ccc.json", reports)
end
