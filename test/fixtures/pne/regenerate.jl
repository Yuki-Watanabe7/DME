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
#
# 入力は `pne_fixture_builders.jl` の決定的な builder と `mappings/*.json`（DME 所有の mapping
# artifact）。vendor した PNE fixture（`sector_output_path/v1/`）は本スクリプトでは変更しない
# （PNE 側から再コピーし `MANIFEST.json` を更新する）。

using DME

include(joinpath(@__DIR__, "pne_fixture_builders.jl"))

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
