# scripts/quality_export_docs.jl
#
# Julia品質Export Contract v1（Issue #213）: Documenter.jl のドキュメントビルド結果を含めた
# quality export を書き出す driver。`scripts/docs_build_worker.jl` を独立した subprocess
# として起動し、期限を超えたら kill して `status=:timeout` として報告する
# （2プロセス構成の理由は docs_build_worker.jl 冒頭コメント・契約 §8 方法F 参照）。
#
# fast lane（`scripts/quality_export_coverage.jl`）・JET slow lane
# （`scripts/quality_export_jet.jl`）・benchmark slow lane
# （`scripts/quality_export_benchmark.jl`）のいずれともマージしない、独立した自己完結型の
# export ファイルを生成する。Documenter.jl 以外の6予約ツールは `status=:skipped` の
# プレースホルダで埋める。
#
# 実行方法:
#   julia --project=. scripts/quality_export_docs.jl
#
# 環境変数（省略時の既定）:
#   DME_QUALITY_EXPORT_OUTPUT                 既定: artifacts/quality/quality-export-docs.json
#   DME_QUALITY_EXPORT_DOCS_TIMEOUT_SECONDS   既定: 1800（30分）
#   DME_QUALITY_EXPORT_BRANCH                 既定: 自動検出（GITHUB_HEAD_REF/GITHUB_REF_NAME → git → "unknown"）
#   DME_QUALITY_EXPORT_REPO_OWNER             既定: "Yuki-Watanabe7"
#   DME_QUALITY_EXPORT_REPO_NAME              既定: "DME"
#
# この driver 自身は Documenter.jl を `using` しない（`--project=.`（root環境）のまま実行し、
# 実際のビルドは `--project=docs` で起動する worker subprocess に委譲する）。
#
# 終了コード: ドキュメントビルドの成否（`build_status`）・warning の有無・worker の
# timeout/crash のいずれも終了コードへは影響しない（export の書き出し自体が失敗しない限り 0）。
# ビルド失敗を CI の失敗として扱うのは workflow 側の責務
# （.github/workflows/docs.yml。契約 §8 方法F「失敗の扱い」）。
#
# 契約・設計判断: docs/contract/julia-quality-export-v1.md §4.5 / §8 方法F、ADR 0017

using DME
using Dates
using JSON3

const _REPO_ROOT = normpath(joinpath(@__DIR__, ".."))
const _WORKER_PATH = joinpath(@__DIR__, "docs_build_worker.jl")
const _DOCS_PROJECT = joinpath(_REPO_ROOT, "docs")

const _TIMEOUT_ENV = "DME_QUALITY_EXPORT_DOCS_TIMEOUT_SECONDS"
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
        joinpath(_REPO_ROOT, "artifacts", "quality", "quality-export-docs.json"),
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

worker subprocess（`scripts/docs_build_worker.jl`）を `--project=docs` で起動し、
`timeout_seconds` を期限として poll する。`outcome ∈ (:completed, :timeout)`。
`:completed` は worker が自発的に終了したことのみを意味し、成功/失敗の判定は呼び出し側が
exit code・出力ファイルの内容から別途行う。
"""
function _run_worker(
    output_path::AbstractString,
    timeout_seconds::Real,
)::Tuple{Symbol, Base.Process}
    julia_bin = joinpath(Sys.BINDIR, Base.julia_exename())
    cmd = `$julia_bin --startup-file=no --project=$(_DOCS_PROJECT) $(_WORKER_PATH) $(output_path)`
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
    _docs_tool_execution(raw_output_path, started_at) -> QualityToolExecution

worker の実行結果（timeout/exit code/出力ファイルの内容）から `Documenter.jl` の
`QualityToolExecution` を組み立てる。

**ビルド失敗（`build_status = "failed"`）は `status=:success`** である点に注意
（「ビルドを実行して失敗を観測できた」＝測定成功。`:failure` は worker がビルド結果を
出せなかった場合に限る）。Issue #213「build failure時にもvalid partial exportを残す」と
「tool crash/未導入を成功扱いしない」を同時に満たすための区別。
"""
function _docs_tool_execution(
    raw_output_path::AbstractString,
    started_at::DateTime,
)::QualityToolExecution
    outcome, proc = _run_worker(raw_output_path, _timeout_seconds())

    if outcome == :timeout
        return QualityToolExecution(;
            tool_name = "Documenter.jl",
            status = :timeout,
            started_at = started_at,
            completed_at = _now_utc(),
            error = QualityToolError(;
                type = "Timeout",
                message = "Documenter build exceeded the configured timeout " *
                          "($(_timeout_seconds())s) and the worker subprocess was killed",
            ),
        )
    end

    completed_at = _now_utc()

    if !isfile(raw_output_path)
        return QualityToolExecution(;
            tool_name = "Documenter.jl",
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
            tool_name = "Documenter.jl",
            status = :failure,
            started_at = started_at,
            completed_at = completed_at,
            error = QualityToolError(;
                type = "MalformedOutput",
                message = "failed to parse worker output as JSON: " * sprint(showerror, e),
            ),
        )
    end

    # Documenter が docs 環境に無い（instantiate 前・依存の解決に失敗）場合。
    # 「ビルドして0件だった」とも「ビルドに失敗した」とも区別する（契約 §4）。
    worker_status = get(raw, "worker_status", nothing)
    if worker_status !== nothing && String(worker_status) == "not_installed"
        return quality_tool_not_run(
            "Documenter.jl",
            String(get(raw, "message", "Documenter.jl is not installed"));
            status = :not_installed,
        )
    end

    if haskey(raw, "worker_error")
        werr = raw["worker_error"]
        return QualityToolExecution(;
            tool_name = "Documenter.jl",
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
        tool_name = "Documenter.jl",
        status = :success,
        version = version === nothing ? nothing : String(version),
        started_at = started_at,
        completed_at = completed_at,
        result = raw["result"],
    )
end

"""docs lane の export は Documenter.jl 以外の6予約ツールを実測しない
（`scripts/quality_export_jet.jl` の `_non_jet_placeholder_tools()` と同じく、
「1件も測定しないexportにしない」ためのプレースホルダに理由を明記する）。"""
function _non_docs_placeholder_tools()::Vector{QualityToolExecution}
    return [
        quality_tool_not_run(
            name,
            "measured by another lane (fast lane: scripts/quality_export_coverage.jl, " *
            "JET/benchmark slow lane: scripts/quality_export_jet.jl / " *
            "scripts/quality_export_benchmark.jl), not by this docs export",
        ) for name in QUALITY_EXPORT_RESERVED_TOOL_NAMES if name != "Documenter.jl"
    ]
end

function build_export()::QualityExport
    measured_at = _now_utc()
    raw_output_path, io = mktemp()
    close(io)
    docs_tool = try
        _docs_tool_execution(raw_output_path, measured_at)
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
        tools = vcat(QualityToolExecution[docs_tool], _non_docs_placeholder_tools()),
    )
end

function print_summary(e::QualityExport, path::AbstractString)
    docs = e.tools["Documenter.jl"]
    println("=== Julia品質Export（Documenter.jl docs lane、Issue #213） ===")
    println("  export_schema = ", e.export_schema)
    println("  branch/commit = ", e.branch, " / ", e.commit)
    println("  Documenter.jl status = ", docs.status)
    if docs.result !== nothing
        println("  build_status  = ", docs.result["build_status"])
        println("  warnings      = ", docs.result["warnings"])
        println("  errors        = ", docs.result["errors"])
    elseif docs.error !== nothing
        println("  error         = ", docs.error.type, ": ", docs.error.message)
    elseif docs.reason !== nothing
        println("  reason        = ", docs.reason)
    end
    println("  saved to: ", path)
    println("契約: docs/contract/julia-quality-export-v1.md §4.5")
    return nothing
end

function main()
    export_ = build_export()
    path = save_quality_export(export_, _output_path())
    print_summary(export_, path)
    return export_
end

main()
