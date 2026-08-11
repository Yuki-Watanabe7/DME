# scripts/update_benchmark_baseline.jl
#
# Julia品質Export Contract v1（Issue #212）: repository 内 versioned baseline
# （`benchmarks/baseline.json`）を、実測済みの quality export から更新する**手動**スクリプト。
#
# ## なぜ手動か
#
# Issue #212 の「baseline更新を自動で常に受理せず、更新理由と対象commitを記録する」に対する
# 実装。CI（slow lane workflow）はこのスクリプトを呼ばない — baseline の書き換えは常に人が
# 行い、`--reason` で理由を明示し、その理由・対象コミット・測定時刻が baseline ファイルへ
# 残る。これにより「いつのまにか遅い値が baseline になっていて回帰が検出されなくなる」
# ことを防ぐ。
#
# ## 手順
#
#   1. 更新したい環境で benchmark export を得る
#      - CI（GitHub Actions ubuntu runner）の baseline: slow lane workflow を
#        `workflow_dispatch` で実行し、Artifact `dme-julia-quality-v1-benchmark-<sha>` を
#        ダウンロードして展開する
#      - ローカルの baseline: `DME_BENCHMARK_RUNNER_LABEL=<マシン識別子> \
#        julia --project=. scripts/quality_export_benchmark.jl`
#   2. 差分を確認する（書き込みなし）
#        julia --project=. scripts/update_benchmark_baseline.jl <export.json> --dry-run
#   3. 理由を付けて書き込む
#        julia --project=. scripts/update_benchmark_baseline.jl <export.json> \
#            --reason "Issue #212 初回 baseline 収集（ubuntu-latest / Julia 1.12）"
#   4. `benchmarks/baseline.json` の差分をレビューしてコミットする
#
# 引数（省略時の既定）:
#   <export.json>   既定: artifacts/quality/quality-export-benchmark.json
#   --reason <text> 必須（`DME_BENCHMARK_BASELINE_REASON` でも可）。空文字は拒否する
#   --dry-run       差分を表示するだけでファイルを書き換えない
#
# 環境変数:
#   DME_BENCHMARK_BASELINE_PATH   既定: benchmarks/baseline.json
#
# 契約・設計判断: docs/contract/julia-quality-export-v1.md §4.4

using DME
using JSON3

const _REPO_ROOT = normpath(joinpath(@__DIR__, ".."))
const BENCHMARK_BASELINE_SCHEMA = "dme-benchmark-baseline/v1"

const _DEFAULT_EXPORT_PATH =
    joinpath(_REPO_ROOT, "artifacts", "quality", "quality-export-benchmark.json")

_baseline_path()::String = get(
    ENV,
    "DME_BENCHMARK_BASELINE_PATH",
    joinpath(_REPO_ROOT, "benchmarks", "baseline.json"),
)

"""
    _parse_args(args) -> (export_path, reason, dry_run)

`--reason <text>` / `--reason=<text>` / `--dry-run` と、位置引数1件（export のパス）を解釈する。
"""
function _parse_args(args::AbstractVector{<:AbstractString})
    export_path = nothing
    reason = get(ENV, "DME_BENCHMARK_BASELINE_REASON", "")
    dry_run = false
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--dry-run"
            dry_run = true
        elseif a == "--reason"
            i += 1
            i <= length(args) || error("--reason の後に理由の文字列が必要です")
            reason = args[i]
        elseif startswith(a, "--reason=")
            reason = a[(length("--reason=") + 1):end]
        elseif startswith(a, "--")
            error("未知のオプションです: $a")
        elseif export_path === nothing
            export_path = a
        else
            error("位置引数は1件（export のパス）だけ指定できます: $a")
        end
        i += 1
    end
    return (
        export_path === nothing ? _DEFAULT_EXPORT_PATH : export_path,
        String(reason),
        dry_run,
    )
end

"""既存の baseline ファイルを読む（無ければ空の schema 付き Dict）。"""
function _load_baseline()::Dict{String, Any}
    path = _baseline_path()
    isfile(path) || return Dict{String, Any}(
        "baseline_schema" => BENCHMARK_BASELINE_SCHEMA,
        "environments" => Dict{String, Any}(),
    )
    raw = DME._qe_to_plain(JSON3.read(read(path, String)))
    raw["baseline_schema"] == BENCHMARK_BASELINE_SCHEMA || error(
        "baseline ファイルの baseline_schema が想定外です（期待: $(BENCHMARK_BASELINE_SCHEMA)、" *
        "実際: $(get(raw, "baseline_schema", nothing))）: $path",
    )
    envs = get(raw, "environments", Dict{String, Any}())
    return Dict{String, Any}(
        "baseline_schema" => BENCHMARK_BASELINE_SCHEMA,
        "environments" => Dict{String, Any}(String(k) => v for (k, v) in envs),
    )
end

"""更新前後の median を並べて表示する（人が受理判断するための材料。`--dry-run` でも表示する）。"""
function _print_diff(old_entry, benchmarks::AbstractVector)
    println("  benchmark                      old median      new median      delta")
    for b in benchmarks
        id = String(b["id"])
        new_ns = Int(b["median_time_ns"])
        old_ns = nothing
        if old_entry !== nothing
            table = get(old_entry, "benchmarks", nothing)
            if table isa AbstractDict && haskey(table, id)
                old_ns = Int(table[id]["median_time_ns"])
            end
        end
        old_str =
            old_ns === nothing ? "        (none)" :
            lpad(round(old_ns / 1e6; digits = 4), 11) * " ms"
        delta_str =
            old_ns === nothing ? "     n/a" :
            lpad(
                string(
                    round(quality_benchmark_delta_percent(new_ns, old_ns); digits = 1),
                    "%",
                ),
                8,
            )
        println(
            "  ",
            rpad(id, 30),
            old_str,
            lpad(round(new_ns / 1e6; digits = 4), 12),
            " ms  ",
            delta_str,
        )
    end
    return nothing
end

function main()
    export_path, reason, dry_run = _parse_args(ARGS)

    isfile(export_path) || error("quality export ファイルが見つかりません: $export_path")
    e = load_quality_export(export_path)
    haskey(e.tools, "BenchmarkTools.jl") ||
        error("この export には BenchmarkTools.jl のエントリがありません: $export_path")
    tool = e.tools["BenchmarkTools.jl"]
    tool.status == :success || error(
        "BenchmarkTools.jl の status が success ではありません（status=$(tool.status)）。" *
        "失敗した測定を baseline にはできません: $export_path",
    )

    isempty(strip(reason)) && error(
        "baseline の更新には理由が必須です（--reason \"...\" もしくは " *
        "DME_BENCHMARK_BASELINE_REASON）。Issue #212「baseline更新を自動で常に受理せず、" *
        "更新理由と対象commitを記録する」",
    )

    result = tool.result
    environment = result["environment"]
    env_key = String(environment["key"])
    benchmarks = result["benchmarks"]

    baseline = _load_baseline()
    old_entry = get(baseline["environments"], env_key, nothing)

    println("=== benchmark baseline の更新（Issue #212） ===")
    println("  export        = ", export_path)
    println("  environment   = ", env_key)
    println("  commit        = ", e.commit)
    println("  measured_at   = ", e.measured_at, "Z")
    println("  reason        = ", reason)
    println("  baseline file = ", _baseline_path())
    println()
    _print_diff(old_entry, benchmarks)
    println()

    baseline["environments"][env_key] = Dict{String, Any}(
        "commit" => e.commit,
        "recorded_at" => DME._qe_format_datetime(e.measured_at),
        "reason" => redact_secrets(strip(reason)),
        "julia_version" => String(environment["julia_version"]),
        "runner_label" => String(environment["runner_label"]),
        "cpu_model" => get(environment, "cpu_model", nothing),
        "manifest_digest" => get(environment, "manifest_digest", nothing),
        "benchmarks" => Dict{String, Any}(
            String(b["id"]) =>
                Dict{String, Any}("median_time_ns" => Int(b["median_time_ns"])) for
            b in benchmarks
        ),
    )

    if dry_run
        println("--dry-run のためファイルは更新していません。")
        return nothing
    end

    path = _baseline_path()
    mkpath(dirname(path))
    # 正準 JSON（キー順が安定するので git 差分が読める）＋ 末尾改行（リポジトリ管理下の
    # テキストファイルとして扱うため。改行は正準バイト列の一部ではない）。
    write(path, canonical_json_string(baseline) * "\n")
    println("baseline を更新しました: ", path)
    println(
        "差分をレビューしてコミットしてください（reason と commit が記録されています）。",
    )
    return nothing
end

main()
