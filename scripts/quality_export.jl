# scripts/quality_export.jl
#
# Julia品質Export Contract v1（`julia-quality-export/v1`）の Exporter 骨格（Issue #207）。
#
# DME 自身の package identity（`Project.toml` 由来）・git commit/branch・実行時刻から
# `QualityExport` を構築し、`schemas/julia-quality-export-v1.schema.json` に準拠した
# 正準 JSON を atomic 保存する。予約 7 ツール（`QUALITY_EXPORT_RESERVED_TOOL_NAMES`）は
# すべて `status=:skipped` のプレースホルダとして埋める。実際のツール実行・結果構造化は
# 本 Issue の対象外（後続 Issue が個別に置き換える）:
#   - #208: Pkg.test / Aqua.jl / JuliaFormatter.jl
#   - #209: Coverage.jl
#   - #211: JET.jl
#   - #212: BenchmarkTools.jl
#   - #213: Documenter.jl
#
# 実行方法:
#   julia --project=. scripts/quality_export.jl [output-path]
#
# 出力先の指定（優先順）: CLI引数 > 環境変数 `DME_QUALITY_EXPORT_OUTPUT` >
#   既定 `artifacts/quality/quality-export.json`（`/artifacts/` は .gitignore 対象）。
#
# その他の環境変数（省略時は自動検出、失敗時はプレースホルダ）:
#   DME_QUALITY_EXPORT_BRANCH       既定: 自動検出（GITHUB_HEAD_REF/GITHUB_REF_NAME → git → "unknown"）
#   DME_QUALITY_EXPORT_REPO_OWNER   既定: "Yuki-Watanabe7"
#   DME_QUALITY_EXPORT_REPO_NAME    既定: "DME"
#
# 契約・設計判断: schemas/julia-quality-export-v1.schema.json /
#   docs/contract/julia-quality-export-v1.md / docs/adr/0016-julia-quality-export-contract.md

using DME
using Dates

const _OUTPUT_ENV = "DME_QUALITY_EXPORT_OUTPUT"
const _BRANCH_ENV = "DME_QUALITY_EXPORT_BRANCH"
const _REPO_OWNER_ENV = "DME_QUALITY_EXPORT_REPO_OWNER"
const _REPO_NAME_ENV = "DME_QUALITY_EXPORT_REPO_NAME"

function _output_path()::String
    isempty(ARGS) || return ARGS[1]
    return get(
        ENV,
        _OUTPUT_ENV,
        joinpath(@__DIR__, "..", "artifacts", "quality", "quality-export.json"),
    )
end

"""現在時刻を UTC の秒精度 `DateTime` として返す（`TimeZones.jl` を使わない既存の
`Dates.unix2datetime` 慣行。real-rate model artifact の UTC 固定方針と同じ MVP 制約）。"""
_now_utc()::DateTime = Dates.floor(Dates.unix2datetime(time()), Dates.Second)

function _commit_sha()::String
    sha = DME._detect_git_commit_sha()
    sha === nothing || return sha
    return "0"^40  # .git が存在しない配布環境向けのフォールバック（40桁hex形式を維持する）
end

function _branch()::String
    b = get(ENV, _BRANCH_ENV, "")
    isempty(b) || return b
    detected = DME._qe_detect_branch()
    detected === nothing || return detected
    return "unknown"
end

"""
    placeholder_tools() -> Vector{QualityToolExecution}

予約 7 ツールすべてを `status=:skipped` として埋める。空の `tools` を返すと「1件も測定しない
export」という別の意味になってしまう（`QualityExport` は `tools` が最低1件必要）ため、
「予約はしたが未配線」という状態を明示的に表現する。
"""
function placeholder_tools()::Vector{QualityToolExecution}
    return [
        quality_tool_not_run(
            name,
            "not wired up yet: Issue #207 defines the julia-quality-export/v1 contract " *
            "and exporter skeleton only; per-tool execution is added by a later issue",
        ) for name in QUALITY_EXPORT_RESERVED_TOOL_NAMES
    ]
end

function build_export()::QualityExport
    measured_at = _now_utc()
    return QualityExport(;
        package = quality_export_package_identity(),
        repository = QualityExportRepository(;
            owner = get(ENV, _REPO_OWNER_ENV, "Yuki-Watanabe7"),
            name = get(ENV, _REPO_NAME_ENV, "DME"),
        ),
        branch = _branch(),
        commit = _commit_sha(),
        measured_at = measured_at,
        generated_at = _now_utc(),
        tools = placeholder_tools(),
    )
end

function print_summary(e::QualityExport, path::AbstractString)
    println("=== Julia品質Export（Issue #207 骨格） ===")
    println("  export_schema = ", e.export_schema)
    println("  package       = ", e.package.name, " ", e.package.version)
    println("  repository    = ", e.repository.owner, "/", e.repository.name)
    println("  branch        = ", e.branch)
    println("  commit        = ", e.commit)
    println("  julia_version = ", e.julia_version)
    println("  tools:")
    for name in sort(collect(keys(e.tools)))
        t = e.tools[name]
        reason_suffix = t.reason === nothing ? "" : "  ($(t.reason))"
        println("    ", rpad(name, 20), " status=", t.status, reason_suffix)
    end
    println("  saved to: ", path)
    println()
    println("すべて status=skipped（実測は #208/#209/#211/#212/#213 が個別に置き換える）。")
    println("契約: schemas/julia-quality-export-v1.schema.json")
    println("詳細: docs/contract/julia-quality-export-v1.md")
    return nothing
end

function main()
    export_ = build_export()
    path = save_quality_export(export_, _output_path())
    print_summary(export_, path)
    return export_
end

main()
