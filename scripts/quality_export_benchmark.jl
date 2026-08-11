# scripts/quality_export_benchmark.jl
#
# Julia品質Export Contract v1（Issue #212）: BenchmarkTools.jl（性能測定）を含めた
# quality export を書き出す driver。`scripts/benchmark_worker.jl` を独立した subprocess
# として起動し、期限を超えたら kill して `status=:timeout` として報告する
# （2プロセス構成の理由は benchmark_worker.jl 冒頭コメント参照。JET.jl slow lane
# `scripts/quality_export_jet.jl` と同じ構造）。
#
# fast lane（`scripts/quality_export_coverage.jl`）とも JET.jl slow lane
# （`scripts/quality_export_jet.jl`）とも独立した自己完結型の export ファイルを生成する。
# BenchmarkTools.jl 以外の6予約ツールは `status=:skipped` のプレースホルダで埋める
# （3つの export はマージせず、別ファイル・別 Artifact として扱う。詳細は
# docs/contract/julia-quality-export-v1.md §8「方法E」）。
#
# ## baseline と回帰判定
#
# baseline は repository 内 versioned baseline（既定 `benchmarks/baseline.json`）のみを使う。
# 現在の実行環境（`environment_key`）と一致するエントリがある benchmark だけを比較し、
# 以下はすべて `regression_status = "unavailable"` として報告する（pass にしない —
# Issue #212「baseline不存在時はpassにせずcomparison unavailableとして扱う」）:
#
#   - baseline ファイルが無い/空                 → `baseline_missing`
#   - `environment_key` が一致しない             → `baseline_environment_mismatch`
#   - 環境は一致するが benchmark id が未収録     → `baseline_benchmark_missing`
#
# baseline の更新は `scripts/update_benchmark_baseline.jl`（手動、更新理由が必須）でのみ行う。
# この driver は baseline を書き換えない（Issue #212「baseline更新を自動で常に受理しない」）。
#
# ## 終了コード
#
# 回帰（`regressed`）が検出されても終了コードは0のまま（Issue #212「性能回帰をコード品質fail
# と即時同一視せず、初期はadvisory/unratedで運用する」「PR必須performance gate」は対象外）。
# 終了コードが非0になるのは export の書き出し自体が失敗した場合のみ。
#
# 実行方法:
#   julia --project=. scripts/quality_export_benchmark.jl
#
# 環境変数（省略時の既定）:
#   DME_QUALITY_EXPORT_OUTPUT                      既定: artifacts/quality/quality-export-benchmark.json
#   DME_QUALITY_EXPORT_BENCHMARK_TIMEOUT_SECONDS   既定: 1800（30分）
#   DME_BENCHMARK_BASELINE_PATH                    既定: benchmarks/baseline.json
#   DME_BENCHMARK_RUNNER_LABEL                     既定: 自動検出（scripts/benchmark_suite.jl）
#   DME_QUALITY_EXPORT_BRANCH                      既定: 自動検出（GITHUB_HEAD_REF/GITHUB_REF_NAME → git → "unknown"）
#   DME_QUALITY_EXPORT_REPO_OWNER                  既定: "Yuki-Watanabe7"
#   DME_QUALITY_EXPORT_REPO_NAME                   既定: "DME"
#
# この driver 自身は BenchmarkTools.jl を `using` しない（`--project=.`（root環境）のまま
# 実行し、実際の測定は worker subprocess に委譲する）。
#
# 契約・設計判断: docs/contract/julia-quality-export-v1.md §4.4 / §8

using DME
using Dates
using JSON3

const _REPO_ROOT = normpath(joinpath(@__DIR__, ".."))
const _WORKER_PATH = joinpath(@__DIR__, "benchmark_worker.jl")

const _TIMEOUT_ENV = "DME_QUALITY_EXPORT_BENCHMARK_TIMEOUT_SECONDS"
const _OUTPUT_ENV = "DME_QUALITY_EXPORT_OUTPUT"
const _BASELINE_ENV = "DME_BENCHMARK_BASELINE_PATH"
const _BRANCH_ENV = "DME_QUALITY_EXPORT_BRANCH"
const _REPO_OWNER_ENV = "DME_QUALITY_EXPORT_REPO_OWNER"
const _REPO_NAME_ENV = "DME_QUALITY_EXPORT_REPO_NAME"

const _DEFAULT_TIMEOUT_SECONDS = 1800.0
#: worker を SIGTERM してから SIGKILL するまでの猶予（秒）。
const _KILL_GRACE_SECONDS = 10.0
#: process_running を確認する poll 間隔（秒）。
const _POLL_INTERVAL_SECONDS = 1.0

#: baseline ファイルの schema 識別子（`julia-quality-export/v1` とは別物 — こちらは DME 内部
#: だけで使う repository-local なファイルであり、他リポジトリとの契約ではない）。
const BENCHMARK_BASELINE_SCHEMA = "dme-benchmark-baseline/v1"

"""現在時刻を UTC の秒精度 `DateTime` として返す（他の quality_export_*.jl driver と同じ
MVP 制約: `TimeZones.jl` を使わない `Dates.unix2datetime` 慣行）。"""
_now_utc()::DateTime = Dates.floor(Dates.unix2datetime(time()), Dates.Second)

_output_path()::String = get(
    ENV,
    _OUTPUT_ENV,
    joinpath(_REPO_ROOT, "artifacts", "quality", "quality-export-benchmark.json"),
)

#: baseline ファイルの絶対パス。
_baseline_path()::String =
    get(ENV, _BASELINE_ENV, joinpath(_REPO_ROOT, "benchmarks", "baseline.json"))

#: export へ記録する baseline パス（リポジトリ相対。CI ランナー固有の絶対パスを残さない）。
function _baseline_display_path()::String
    p = _baseline_path()
    return startswith(p, _REPO_ROOT) ? relpath(p, _REPO_ROOT) : p
end

function _timeout_seconds()::Float64
    raw = get(ENV, _TIMEOUT_ENV, "")
    isempty(raw) && return _DEFAULT_TIMEOUT_SECONDS
    parsed = tryparse(Float64, raw)
    (parsed === nothing || parsed <= 0) && return _DEFAULT_TIMEOUT_SECONDS
    return parsed
end

function _commit_sha()::String
    sha = DME._detect_git_commit_sha()
    sha === nothing || return sha
    return "0"^40
end

function _branch()::String
    b = get(ENV, _BRANCH_ENV, "")
    isempty(b) || return b
    detected = DME._qe_detect_branch()
    detected === nothing || return detected
    return "unknown"
end

function _kill_with_grace(proc::Base.Process)::Nothing
    process_running(proc) || return nothing
    kill(proc)  # SIGTERM
    grace_deadline = time() + _KILL_GRACE_SECONDS
    while process_running(proc) && time() < grace_deadline
        sleep(_POLL_INTERVAL_SECONDS)
    end
    process_running(proc) && kill(proc, Base.SIGKILL)
    wait(proc)  # zombie化を防ぐため終了を待ってから返す
    return nothing
end

"""
    _run_worker(output_path, timeout_seconds) -> (outcome::Symbol, proc::Base.Process)

worker subprocess（`scripts/benchmark_worker.jl`）を起動し、`timeout_seconds` を期限として
poll する。`outcome ∈ (:completed, :timeout)`。`:completed` は worker が自発的に終了した
ことのみを意味し、成功/失敗の判定は呼び出し側が exit code・出力ファイルの内容から別途行う。
"""
function _run_worker(
    output_path::AbstractString,
    timeout_seconds::Real,
)::Tuple{Symbol, Base.Process}
    julia_bin = joinpath(Sys.BINDIR, Base.julia_exename())
    cmd = `$julia_bin --startup-file=no --project=$(_REPO_ROOT) $(_WORKER_PATH) $(output_path)`
    proc = run(pipeline(cmd; stdout = stdout, stderr = stderr); wait = false)
    deadline = time() + timeout_seconds
    while process_running(proc)
        if time() > deadline
            _kill_with_grace(proc)
            return (:timeout, proc)
        end
        sleep(_POLL_INTERVAL_SECONDS)
    end
    return (:completed, proc)
end

# ---------------------------------------------------------------------------
# baseline の読み込みと突き合わせ
# ---------------------------------------------------------------------------

"""
    _load_baseline_environment(environment_key) -> (entry, missing_reason)

baseline ファイルから `environment_key` に一致するエントリを探し、
`(entry::Dict, "")`（見つかった）または `(nothing, reason)` を返す。`reason` は
`QUALITY_BENCHMARK_UNAVAILABLE_REASONS` のうち `baseline_missing`（ファイルが無い・壊れて
いる・環境エントリが1件も無い）か `baseline_environment_mismatch`（他環境のエントリはあるが
この環境のものが無い）。この driver は baseline の欠落を致命的な失敗として扱わない
（benchmark 側を `unavailable` として報告するだけ）。ファイルが壊れている場合は警告を出す
（黙って `baseline_missing` に丸めると「更新したのに読まれていない」ことに気づけないため）。
"""
function _load_baseline_environment(environment_key::AbstractString)
    path = _baseline_path()
    isfile(path) || return (nothing, "baseline_missing")
    raw = try
        DME._qe_to_plain(JSON3.read(read(path, String)))
    catch e
        @warn "baseline ファイルを JSON として解析できませんでした（比較を unavailable として続行します）" path =
            path exception = e
        return (nothing, "baseline_missing")
    end
    schema = get(raw, "baseline_schema", nothing)
    if schema != BENCHMARK_BASELINE_SCHEMA
        @warn "baseline ファイルの baseline_schema が想定外です（比較を unavailable として続行します）" path =
            path expected = BENCHMARK_BASELINE_SCHEMA actual = schema
        return (nothing, "baseline_missing")
    end
    envs = get(raw, "environments", nothing)
    # 環境エントリが1件も無いファイル（初期状態）は「まだ baseline が無い」であって
    # 「環境が違う」ではない。
    (envs isa AbstractDict && !isempty(envs)) || return (nothing, "baseline_missing")
    entry = get(envs, String(environment_key), nothing)
    entry isa AbstractDict || return (nothing, "baseline_environment_mismatch")
    return (Dict{String, Any}(String(k) => v for (k, v) in entry), "")
end

"""
    _baseline_ref(entry, environment_key) -> QualityBenchmarkBaselineRef

baseline エントリ（`_load_baseline_environment` の戻り値）から export 用の provenance を作る。
`entry === nothing`（＝比較しなかった）のときは `available=false`。
"""
function _baseline_ref(
    entry::Union{AbstractDict, Nothing},
    environment_key::AbstractString,
)::QualityBenchmarkBaselineRef
    path = _baseline_display_path()
    entry === nothing &&
        return QualityBenchmarkBaselineRef(; available = false, path = path)
    return QualityBenchmarkBaselineRef(;
        available = true,
        path = path,
        environment_key = environment_key,
        commit = String(entry["commit"]),
        recorded_at = String(entry["recorded_at"]),
        reason = String(entry["reason"]),
    )
end

#: baseline エントリの `benchmarks` テーブル（無ければ `nothing`）。`entry === nothing`
#: との分岐を `Union` の絞り込みではなく多重ディスパッチで書く（呼び出し側の可読性と、
#: 静的解析が `get(::Nothing, ...)` を候補に挙げないようにするため）。
_baseline_benchmarks(::Nothing) = nothing
function _baseline_benchmarks(entry::AbstractDict)
    table = get(entry, "benchmarks", nothing)
    return table isa AbstractDict ? table : nothing
end

"""
    _benchmark_results(measurements, entry) -> Vector{QualityBenchmarkResult}

worker の生の測定値と baseline エントリを突き合わせて `QualityBenchmarkResult` を作る。
baseline が無い理由を3値（`baseline_missing`/`baseline_environment_mismatch`/
`baseline_benchmark_missing`）で区別する（ファイル冒頭「baseline と回帰判定」参照）。
`missing_reason` は「環境一致のエントリが見つからなかった理由」であり、エントリはあるが
その benchmark だけ無い場合は `baseline_benchmark_missing` を使う。
"""
function _benchmark_results(
    measurements::AbstractVector,
    entry::Union{AbstractDict, Nothing},
    missing_reason::AbstractString,
)::Vector{QualityBenchmarkResult}
    baseline_benchmarks = _baseline_benchmarks(entry)

    results = QualityBenchmarkResult[]
    for m in measurements
        id = String(m["id"])
        baseline_ns = nothing
        if baseline_benchmarks !== nothing && haskey(baseline_benchmarks, id)
            baseline_ns = Int(baseline_benchmarks[id]["median_time_ns"])
        end
        reason =
            baseline_ns !== nothing ? nothing :
            (entry === nothing ? String(missing_reason) : "baseline_benchmark_missing")
        push!(
            results,
            QualityBenchmarkResult(;
                id = id,
                group = String(m["group"]),
                description = String(m["description"]),
                median_time_ns = Int(m["median_time_ns"]),
                memory_bytes = Int(m["memory_bytes"]),
                allocs = Int(m["allocs"]),
                samples = Int(m["samples"]),
                evals_per_sample = Int(m["evals_per_sample"]),
                margin_percent = Float64(m["margin_percent"]),
                baseline_median_time_ns = baseline_ns,
                unavailable_reason = reason,
            ),
        )
    end
    return results
end

# ---------------------------------------------------------------------------
# QualityToolExecution の組み立て
# ---------------------------------------------------------------------------

_tool_failure(started_at, completed_at, type, message) = QualityToolExecution(;
    tool_name = "BenchmarkTools.jl",
    status = :failure,
    started_at = started_at,
    completed_at = completed_at,
    error = QualityToolError(; type = type, message = message),
)

"""
    _benchmark_tool_execution(raw_output_path, started_at) -> QualityToolExecution

worker の実行結果（timeout/exit code/出力ファイルの内容）と baseline から
`BenchmarkTools.jl` の `QualityToolExecution` を組み立てる。timeout/crash を「遅い結果」
として扱わず、`status` で区別する（Issue #212「benchmark自体の失敗/timeoutを遅い結果として
扱わない」）。
"""
function _benchmark_tool_execution(
    raw_output_path::AbstractString,
    started_at::DateTime,
)::QualityToolExecution
    outcome, proc = _run_worker(raw_output_path, _timeout_seconds())

    if outcome == :timeout
        return QualityToolExecution(;
            tool_name = "BenchmarkTools.jl",
            status = :timeout,
            started_at = started_at,
            completed_at = _now_utc(),
            error = QualityToolError(;
                type = "Timeout",
                message = "benchmark suite exceeded the configured timeout " *
                          "($(_timeout_seconds())s) and the worker subprocess was killed",
            ),
        )
    end

    completed_at = _now_utc()

    isfile(raw_output_path) || return _tool_failure(
        started_at,
        completed_at,
        "MissingOutput",
        "worker process exited (exitcode=$(proc.exitcode)) but did not write an " *
        "output file at $raw_output_path",
    )

    raw = try
        DME._qe_to_plain(JSON3.read(read(raw_output_path, String)))
    catch e
        return _tool_failure(
            started_at,
            completed_at,
            "MalformedOutput",
            "failed to parse worker output as JSON: " * sprint(showerror, e),
        )
    end

    if haskey(raw, "worker_error")
        werr = raw["worker_error"]
        return _tool_failure(
            started_at,
            completed_at,
            String(werr["type"]),
            String(werr["message"]),
        )
    end

    environment = Dict{String, Any}(String(k) => v for (k, v) in raw["environment"])
    config = Dict{String, Any}(String(k) => v for (k, v) in raw["config"])
    environment_key = String(environment["key"])

    entry, missing_reason = _load_baseline_environment(environment_key)
    results = _benchmark_results(raw["measurements"], entry, missing_reason)

    result = try
        quality_tool_benchmark_result(;
            results = results,
            environment = environment,
            baseline = _baseline_ref(entry, environment_key),
            config = config,
            headline_id = String(config["headline_id"]),
        )
    catch e
        return _tool_failure(
            started_at,
            completed_at,
            string(typeof(e)),
            "failed to assemble the BenchmarkTools.jl result: " * sprint(showerror, e),
        )
    end

    version = get(raw, "tool_version", nothing)
    return QualityToolExecution(;
        tool_name = "BenchmarkTools.jl",
        status = :success,
        version = version === nothing ? nothing : String(version),
        started_at = started_at,
        completed_at = completed_at,
        result = result,
    )
end

"""slow lane（benchmark）の export は BenchmarkTools.jl 以外の6予約ツールを実測しない。
どの経路が実測する（あるいはまだ実装されていない）のかを reason に明記する
（`scripts/quality_export_jet.jl` の `_non_jet_placeholder_tools()` と同じ方針）。"""
function _placeholder_reason(name::AbstractString)::String
    name == "JET.jl" && return "measured by the JET.jl slow lane export " *
           "(scripts/quality_export_jet.jl), not by this benchmark export"
    name == "Documenter.jl" && return "not wired to any export path yet (Issue #213)"
    return "measured by the fast lane export (scripts/quality_export_coverage.jl), not " *
           "by this slow lane (BenchmarkTools.jl-only) export"
end

function _non_benchmark_placeholder_tools()::Vector{QualityToolExecution}
    return [
        quality_tool_not_run(name, _placeholder_reason(name)) for
        name in QUALITY_EXPORT_RESERVED_TOOL_NAMES if name != "BenchmarkTools.jl"
    ]
end

function build_export()::QualityExport
    measured_at = _now_utc()
    raw_output_path, io = mktemp()
    close(io)
    tool = try
        _benchmark_tool_execution(raw_output_path, measured_at)
    finally
        isfile(raw_output_path) && rm(raw_output_path; force = true)
    end

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
        tools = vcat(QualityToolExecution[tool], _non_benchmark_placeholder_tools()),
    )
end

function print_summary(e::QualityExport, path::AbstractString)
    t = e.tools["BenchmarkTools.jl"]
    println("=== Julia品質Export（BenchmarkTools.jl slow lane、Issue #212） ===")
    println("  export_schema = ", e.export_schema)
    println("  branch/commit = ", e.branch, " / ", e.commit)
    println("  status        = ", t.status)
    if t.result !== nothing
        println("  environment   = ", t.result["environment"]["key"])
        println(
            "  baseline      = ",
            t.result["baseline"]["available"] ?
            "$(t.result["baseline"]["path"]) @ $(t.result["baseline"]["commit"])" :
            "(none — comparisons are reported as unavailable, not as pass)",
        )
        println("  benchmarks:")
        for b in t.result["benchmarks"]
            delta =
                b["delta_percent"] === nothing ? "     n/a" :
                lpad(string(round(b["delta_percent"]; digits = 1), "%"), 8)
            println(
                "    ",
                rpad(b["id"], 28),
                lpad(round(b["median_time_ns"] / 1e6; digits = 4), 11),
                " ms  Δ",
                delta,
                "  ",
                b["regression_status"],
                b["unavailable_reason"] === nothing ? "" : " ($(b["unavailable_reason"]))",
            )
        end
        s = t.result["regression_summary"]
        println(
            "  regression_summary = improved=$(s["improved"]) stable=$(s["stable"]) " *
            "regressed=$(s["regressed"]) unavailable=$(s["unavailable"])",
        )
        println("  （regression は advisory であり CI の合否判定には使わない）")
    elseif t.error !== nothing
        println("  error         = ", t.error.type, ": ", t.error.message)
    end
    println("  saved to: ", path)
    println("契約: docs/contract/julia-quality-export-v1.md §4.4")
    return nothing
end

function main()
    export_ = build_export()
    path = save_quality_export(export_, _output_path())
    print_summary(export_, path)
    return export_
end

main()
