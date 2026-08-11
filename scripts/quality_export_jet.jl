# scripts/quality_export_jet.jl
#
# Julia品質Export Contract v1（Issue #211）: JET.jl（静的解析）を含めた quality export を
# 書き出す driver。`scripts/jet_analysis_worker.jl` を独立した subprocess として起動し、
# 期限を超えたら kill して `status=:timeout` として報告する（設計判断・2プロセス構成の理由は
# jet_analysis_worker.jl 冒頭コメント参照）。
#
# fast lane（`scripts/quality_export_coverage.jl`）とは独立した slow lane 専用の export
# ファイルを生成する。JET.jl 以外の6予約ツールは `status=:skipped` のプレースホルダで埋める
# （fast lane の export とマージしない — 2つの export は別ファイル・別 Artifact として扱う。
# 詳細は docs/contract/julia-quality-export-v1.md §8「方法D」）。
#
# 実行方法:
#   julia --project=. scripts/quality_export_jet.jl
#
# 環境変数（省略時の既定）:
#   DME_QUALITY_EXPORT_OUTPUT               既定: artifacts/quality/quality-export-jet.json
#   DME_QUALITY_EXPORT_JET_TIMEOUT_SECONDS   既定: 1800（30分）
#   DME_QUALITY_EXPORT_BRANCH                既定: 自動検出（GITHUB_HEAD_REF/GITHUB_REF_NAME → git → "unknown"）
#   DME_QUALITY_EXPORT_REPO_OWNER            既定: "Yuki-Watanabe7"
#   DME_QUALITY_EXPORT_REPO_NAME             既定: "DME"
#
# この driver 自身は JET.jl を `using` しない（`--project=.`（root環境）のまま実行し、
# 実際の解析は worker subprocess に委譲する）。
#
# 契約・設計判断: docs/contract/julia-quality-export-v1.md §4.3 / §8

using DME
using Dates
using JSON3

const _REPO_ROOT = normpath(joinpath(@__DIR__, ".."))
const _WORKER_PATH = joinpath(@__DIR__, "jet_analysis_worker.jl")

const _TIMEOUT_ENV = "DME_QUALITY_EXPORT_JET_TIMEOUT_SECONDS"
const _OUTPUT_ENV = "DME_QUALITY_EXPORT_OUTPUT"
const _BRANCH_ENV = "DME_QUALITY_EXPORT_BRANCH"
const _REPO_OWNER_ENV = "DME_QUALITY_EXPORT_REPO_OWNER"
const _REPO_NAME_ENV = "DME_QUALITY_EXPORT_REPO_NAME"

const _DEFAULT_TIMEOUT_SECONDS = 1800.0
#: worker を SIGTERM してから SIGKILL するまでの猶予（秒）。
const _KILL_GRACE_SECONDS = 10.0
#: process_running を確認する poll 間隔（秒）。
const _POLL_INTERVAL_SECONDS = 1.0

"""現在時刻を UTC の秒精度 `DateTime` として返す（他の quality_export_*.jl driver と同じ
MVP 制約: `TimeZones.jl` を使わない `Dates.unix2datetime` 慣行）。"""
_now_utc()::DateTime = Dates.floor(Dates.unix2datetime(time()), Dates.Second)

function _output_path()::String
    return get(
        ENV,
        _OUTPUT_ENV,
        joinpath(_REPO_ROOT, "artifacts", "quality", "quality-export-jet.json"),
    )
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

worker subprocess（`scripts/jet_analysis_worker.jl`）を起動し、`timeout_seconds` を期限として
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

"""
    _jet_tool_execution(raw_output_path, started_at) -> QualityToolExecution

worker の実行結果（timeout/exit code/出力ファイルの内容）から `JET.jl` の
`QualityToolExecution` を組み立てる。0件成功・複数finding・timeout・crashを区別する
（Issue #211「0件成功、複数finding、timeout、crash、未導入を区別できる」要件）。
"""
function _jet_tool_execution(
    raw_output_path::AbstractString,
    started_at::DateTime,
)::QualityToolExecution
    outcome, proc = _run_worker(raw_output_path, _timeout_seconds())

    if outcome == :timeout
        return QualityToolExecution(;
            tool_name = "JET.jl",
            status = :timeout,
            started_at = started_at,
            completed_at = _now_utc(),
            error = QualityToolError(;
                type = "Timeout",
                message = "JET.jl analysis exceeded the configured timeout " *
                          "($(_timeout_seconds())s) and the worker subprocess was killed",
            ),
        )
    end

    completed_at = _now_utc()

    if !isfile(raw_output_path)
        return QualityToolExecution(;
            tool_name = "JET.jl",
            status = :failure,
            started_at = started_at,
            completed_at = completed_at,
            error = QualityToolError(;
                type = "MissingOutput",
                message = "worker process exited (exitcode=$(proc.exitcode)) but did not " *
                          "write an output file at $raw_output_path",
            ),
        )
    end

    raw = try
        DME._qe_to_plain(JSON3.read(read(raw_output_path, String)))
    catch e
        return QualityToolExecution(;
            tool_name = "JET.jl",
            status = :failure,
            started_at = started_at,
            completed_at = completed_at,
            error = QualityToolError(;
                type = "MalformedOutput",
                message = "failed to parse worker output as JSON: " * sprint(showerror, e),
            ),
        )
    end

    if haskey(raw, "worker_error")
        werr = raw["worker_error"]
        return QualityToolExecution(;
            tool_name = "JET.jl",
            status = :failure,
            started_at = started_at,
            completed_at = completed_at,
            error = QualityToolError(;
                type = String(werr["type"]),
                message = String(werr["message"]),
            ),
        )
    end

    version = get(raw, "tool_version", nothing)
    return QualityToolExecution(;
        tool_name = "JET.jl",
        status = :success,
        version = version === nothing ? nothing : String(version),
        started_at = started_at,
        completed_at = completed_at,
        result = raw["result"],
    )
end

"""slow lane export は JET.jl 以外の6予約ツールを埋めない（`scripts/quality_export.jl` の
`placeholder_tools()` と同じ「1件も測定しないexportにしない」目的だが、こちらは
「fast laneが別途測定するので slow lane では対象外」という理由を reason に明記する）。"""
function _non_jet_placeholder_tools()::Vector{QualityToolExecution}
    return [
        quality_tool_not_run(
            name,
            "measured by the fast lane export (scripts/quality_export_coverage.jl), not " *
            "by this slow lane (JET.jl-only) export",
        ) for name in QUALITY_EXPORT_RESERVED_TOOL_NAMES if name != "JET.jl"
    ]
end

function build_export()::QualityExport
    measured_at = _now_utc()
    raw_output_path, io = mktemp()
    close(io)
    jet_tool = try
        _jet_tool_execution(raw_output_path, measured_at)
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
        tools = vcat(QualityToolExecution[jet_tool], _non_jet_placeholder_tools()),
    )
end

function print_summary(e::QualityExport, path::AbstractString)
    jet = e.tools["JET.jl"]
    println("=== Julia品質Export（JET.jl slow lane、Issue #211） ===")
    println("  export_schema = ", e.export_schema)
    println("  branch/commit = ", e.branch, " / ", e.commit)
    println("  JET.jl status = ", jet.status)
    if jet.result !== nothing
        println("  error_count   = ", jet.result["error_count"])
    elseif jet.error !== nothing
        println("  error         = ", jet.error.type, ": ", jet.error.message)
    end
    println("  saved to: ", path)
    println("契約: docs/contract/julia-quality-export-v1.md §4.3")
    return nothing
end

function main()
    export_ = build_export()
    path = save_quality_export(export_, _output_path())
    print_summary(export_, path)
    return export_
end

main()
