# scripts/validate_quality_export.jl
#
# `julia-quality-export/v1` の JSON ファイルを検証するスタンドアロンヘルパー
# （Issue #208 で追加。#209/#211/#212/#213 が result 構造を追加していく際も
# 変更なしで再利用できる想定）。
#
# 検証内容:
#   1. `DME.load_quality_export` で読み込み、Julia 側の validator
#      （`quality_export_from_dict`）を通す
#   2. `to_json` → `quality_export_from_json` の往復で自己無矛盾性を確認
#   3. `schemas/julia-quality-export-v1.schema.json` に対して Python `jsonschema`
#      が使える場合はスキーマ検証も行う（無ければスキップし、その旨を表示するだけで
#      失敗にはしない — DME は Julia 側に汎用 JSON Schema バリデータを持たない方針のため、
#      これはベストエフォートの二重チェック）
#   4. 各 tool の status・result 有無のサマリーを表示する
#
# 実行方法:
#   julia --project=. scripts/validate_quality_export.jl [path]
#   # 既定 path: artifacts/quality/quality-export.json
#
# 契約: docs/contract/julia-quality-export-v1.md

using DME

function _path()::String
    isempty(ARGS) || return ARGS[1]
    return joinpath(@__DIR__, "..", "artifacts", "quality", "quality-export.json")
end

function _print_summary(e)
    println("  export_schema = ", e.export_schema)
    println("  package       = ", e.package.name, " ", e.package.version)
    println("  branch/commit = ", e.branch, " / ", e.commit)
    println("  tools:")
    for name in sort(collect(keys(e.tools)))
        t = e.tools[name]
        extra = t.result === nothing ? (t.reason === nothing ? "" : "  ($(t.reason))") : ""
        println("    ", rpad(name, 20), " status=", t.status, extra)
    end
    return nothing
end

function _schema_check(path::AbstractString)::Nothing
    schema_path = joinpath(@__DIR__, "..", "schemas", "julia-quality-export-v1.schema.json")
    python = Sys.which("python3")
    if python === nothing
        println("  (python3 が見つからないため schema 検証はスキップ)")
        return nothing
    end
    script = """
import json, sys
try:
    import jsonschema
except ImportError:
    print("  (jsonschema パッケージが無いため schema 検証はスキップ)")
    sys.exit(0)
schema = json.load(open(sys.argv[1]))
data = json.load(open(sys.argv[2]))
jsonschema.validate(instance=data, schema=schema)
print("  schema 検証: OK")
"""
    try
        run(`$python -c $script $schema_path $path`)
    catch e
        println(stderr, "  schema 検証: FAILED (", e, ")")
        rethrow()
    end
    return nothing
end

function main()
    path = _path()
    isfile(path) || error("quality export ファイルが見つかりません: $path")

    println("=== quality export 検証: ", path, " ===")
    e = load_quality_export(path)
    println("  load_quality_export: OK")

    j1 = to_json(e)
    e2 = quality_export_from_json(j1)
    to_json(e2) == j1 || error("round-trip mismatch: to_json/from_json が安定していません")
    println("  round-trip (to_json/from_json): OK")

    _schema_check(path)
    println()
    _print_summary(e)
    return e
end

main()
