# regenerate.jl: Japan Fiscal Scenario Lab の deterministic E2E fixture（Issue #277）を再生成する。
#
# 使い方（リポジトリルートから）:
#   julia --project=. test/fixtures/japan_fiscal/regenerate.jl
#
# 生成物（すべて RFC 8785 正準 JSON）:
#   - handoff/v1/      : Market Analyzer 向け versioned consumer fixture。`inputs/cases.json` の全 case を
#                        `write_japan_fiscal_handoff` で書き、`load_japan_fiscal_handoff` で fail closed に
#                        読み戻して自己検査する。negative artifact（`negative/`）を含む。
#   - invalid_inputs/  : 有効な scenario から 1 事実だけを破った scenario JSON（DME 側の fail closed 検証用）と、
#                        その一覧 `index.json`。
#
# 入力（`inputs/`）は変更しない。artifact の `generated_at` は `inputs/cases.json` の固定値を使うため、
# 同じコード・同じ入力からは同じバイト列が得られる（数値系列の最終桁は BLAS 等のプラットフォーム差で
# 変わりうる。テストは数値を許容誤差で比較する）。
#
# 契約の version を上げたとき・case を追加したときに実行し、差分をレビューしてからコミットする。

using DME

include(joinpath(@__DIR__, "japan_fiscal_fixture_cases.jl"))

rm(JF_HANDOFF_DIR; recursive = true, force = true)
write_japan_fiscal_handoff(
    JF_HANDOFF_DIR,
    jf_fixture_cases();
    generated_at = jf_fixture_generated_at(),
    negative_source_case_id = jf_fixture_negative_source_case_id(),
)
bundle = load_japan_fiscal_handoff(JF_HANDOFF_DIR)
println(
    "wrote handoff/v1: cases=",
    length(bundle.artifacts),
    " scenarios=",
    length(bundle.scenarios),
    " negative_artifacts=",
    length(bundle.negative_errors),
)

rm(JF_INVALID_INPUTS_DIR; recursive = true, force = true)
mkpath(JF_INVALID_INPUTS_DIR)
entries = Any[]
for x in jf_fixture_invalid_inputs()
    msg = try
        japan_fiscal_scenario_from_dict(x.document)
        nothing
    catch e
        e isa ArgumentError || rethrow()
        e.msg
    end
    (msg !== nothing && occursin(x.expected_error, msg)) ||
        error("invalid input $(x.name) が期待どおりに拒否されません: $(repr(msg))")
    open(joinpath(JF_INVALID_INPUTS_DIR, "$(x.name).json"), "w") do io
        write(io, canonical_json_bytes(x.document))
    end
    push!(
        entries,
        Dict{String, Any}(
            "name" => x.name,
            "path" => "$(x.name).json",
            "description" => x.description,
            "expected_error" => x.expected_error,
        ),
    )
end
open(joinpath(JF_INVALID_INPUTS_DIR, "index.json"), "w") do io
    write(io, canonical_json_bytes(Dict{String, Any}("invalid_inputs" => entries)))
end
println("wrote invalid_inputs: ", length(entries))
