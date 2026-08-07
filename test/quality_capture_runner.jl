# test/quality_capture_runner.jl
#
# Julia品質Export Contract v1（Issue #208）: `Pkg.test()` の単一実行から
# Pkg.test/Aqua.jl/JuliaFormatter.jl の構造化結果を捕捉し quality export を書き出す、
# opt-in の実行経路。`test/runtests.jl` が `DME_QUALITY_EXPORT_ENABLED` 環境変数
# （`"1"`/`"true"`）が設定されているときだけ `include` する。無効時（既定）は
# `test/runtests.jl` は本ファイルの存在すら知らず、今までどおり全 `include` を逐次実行する
# （Issue #208「Export disabled時は通常の Pkg.test() 動作を変更しない」を満たす）。
#
# 実行方法:
#   DME_QUALITY_EXPORT_ENABLED=1 julia --project=. -e "using Pkg; Pkg.test()"
#   # 出力先の指定（優先順）: 環境変数 DME_QUALITY_EXPORT_OUTPUT >
#   #   既定 artifacts/quality/quality-export.json（scripts/quality_export.jl と同じ既定値）
#
# 設計判断・Test internals依存の制約:
#   - すべての `include(...)` 呼び出しを1つの外側の `@testset "DME (quality capture)" begin
#     ... end` で包む。標準の `@testset` マクロは「深さ0（親テストセットが無い）でなければ、
#     子テストセットが失敗しても例外を投げず親へ `record` するだけ」という Test.jl 自身の
#     既存の仕様（stdlib `Test.jl` の `finish(ts::DefaultTestSet)`）を持つ。これを利用し、
#     `run_quality_capture` を呼ぶことで各テストファイル自身の `@testset` は「深さ0」で
#     なくなり、失敗しても即座には投げず `record` されるだけになる。
#   - **意図的な副作用**: `DME_QUALITY_EXPORT_ENABLED` が有効なときに限り、「あるテスト
#     ファイルの失敗で以降のファイル（Aqua.jl/JuliaFormatter.jl を含む test_quality.jl 等）が
#     実行されなくなる」という、無効時には残っている挙動（各ファイルの `@testset` が深さ0の
#     まま独立して即座に例外を投げ、`include` チェーン全体を打ち切る）を変える。有効時は
#     常に全ファイルを実行しきってから、失敗があれば最後に1回だけ例外を投げる。これにより
#     Aqua.jl/JuliaFormatter.jl は他のテストファイルの成否に関わらず必ず実行され捕捉される
#     （Issue #208 が問題視する「Pkg.test途中終了によって後続品質チェックが未実行になったか
#     Dashboard が区別できない」を、区別可能にするだけでなく構造的に起きにくくする）。
#     無効時の挙動は一切変えない（今までどおり最初に失敗したファイルで打ち切り）。
#   - `Test.get_test_counts`・`Test.TestSetException` の `pass`/`fail`/`error`/`broken`/
#     `errors_and_fails` フィールドに依存する（`src/quality/quality_capture.jl` 冒頭コメントと
#     対）。これらは Julia の Test stdlib が意味を明記して公開している準内部 API だが、将来の
#     マイナーバージョンで構造が変わる可能性はある。取得できない場合は例外を握りつぶさず
#     `status=:failure`（`CaptureFailure`）として報告する（本ファイルの各 `_qc_*_tool` 関数）。
#   - 失敗時も CI の exit code を隠さない: 捕捉した `Test.TestSetException` は export 書き出し
#     後に必ず再 throw する。
#   - **Julia 1.12+ の world age**: `run_quality_capture` 内の `include(f)` ループが
#     `QUALITY_CAPTURE_AQUA`/`QUALITY_CAPTURE_FORMATTER`（test_quality.jl 側の `const`）や
#     `Aqua`/`JuliaFormatter`（同ファイルの `using`）を新しい world で定義する。ループの外側
#     （`run_quality_capture` 自体）は古い world のまま実行され続けるため、それらを読む
#     残りの処理をそのまま呼ぶと `"access to binding ... in a world prior to its definition
#     world"` という警告が出る（Julia 1.12 時点では警告のみで動作はするが、将来の
#     バージョンではエラーになると明記されている）。そのため tools 構築以降は
#     `Base.invokelatest` 越しに呼び、最新の world で解決させる（`_qc_finish`）。

using Test
using Dates

# `QUALITY_CAPTURE_AQUA`/`QUALITY_CAPTURE_FORMATTER`（`Aqua.jl`/`JuliaFormatter.jl` の実行結果を
# 書き込む先）は test/test_quality.jl 側で定義する（`DME_QUALITY_EXPORT_ENABLED` が無効な
# 通常経路でも test_quality.jl は必ず実行されるため、定義箇所をそちらに一本化する。ここで
# 二重に `const` 宣言すると再定義エラーになる）。`_qc_aqua_tool`/`_qc_formatter_tool` は
# test_quality.jl が実行済みであることを前提に、それらのグローバルを名前参照する。

"""
    _qc_failure_messages(ts::Test.DefaultTestSet) -> Vector{String}

`ts` 配下（再帰的）の `Test.Fail`/`Test.Error` を `string(...)` へ変換した一覧。
`quality_tool_aqua_result` が `redact_secrets` を適用する前提の生メッセージ。
"""
function _qc_failure_messages(ts::Test.DefaultTestSet)::Vector{String}
    out = String[]
    for r in ts.results
        if r isa Test.DefaultTestSet
            append!(out, _qc_failure_messages(r))
        elseif r isa Union{Test.Fail, Test.Error}
            push!(out, string(r))
        end
    end
    return out
end

function _qc_branch()::String
    b = get(ENV, "DME_QUALITY_EXPORT_BRANCH", "")
    isempty(b) || return b
    detected = DME._qe_detect_branch()
    detected === nothing || return detected
    return "unknown"
end

function _qc_commit_sha()::String
    sha = DME._detect_git_commit_sha()
    sha === nothing || return sha
    return "0"^40
end

function _qc_pkgtest_tool(
    started_at::DateTime,
    completed_at::DateTime,
    result_ts,
    caught_exc,
)::QualityToolExecution
    if result_ts !== nothing
        tc = Test.get_test_counts(result_ts)
        passes = tc.passes + tc.cumulative_passes
        fails = tc.fails + tc.cumulative_fails
        errs = tc.errors + tc.cumulative_errors
        broken = tc.broken + tc.cumulative_broken
    elseif caught_exc !== nothing
        passes = caught_exc.pass
        fails = caught_exc.fail
        errs = caught_exc.error
        broken = caught_exc.broken
    else
        # 深さ0の @testset "DME (quality capture)" 自体が Test.jl の try/catch では
        # 拾わない例外（LoadError 等）で中断した場合。result_ts/caught_exc のどちらも
        # 得られず、構造化した測定値が1つも無い（= 「実行に失敗した」であり「0件」ではない）。
        return QualityToolExecution(;
            tool_name = "Pkg.test",
            status = :failure,
            started_at = started_at,
            completed_at = completed_at,
            error = QualityToolError(;
                type = "CaptureFailure",
                message = "test suite ended before Test.jl produced a structured result " *
                          "(likely a LoadError or other error outside the @testset mechanism)",
            ),
        )
    end
    result = quality_tool_pkgtest_result(;
        assertions_total = passes + fails + errs + broken,
        assertions_passed = passes,
        failures = fails,
        errors = errs,
        broken = broken,
    )
    return QualityToolExecution(;
        tool_name = "Pkg.test",
        status = :success,
        version = string(VERSION),
        started_at = started_at,
        completed_at = completed_at,
        result = result,
    )
end

function _qc_aqua_tool(started_at::DateTime, completed_at::DateTime)::QualityToolExecution
    captured = QUALITY_CAPTURE_AQUA[]
    if captured === nothing
        return quality_tool_not_run(
            "Aqua.jl",
            "not reached before the test suite ended (test_quality.jl's Aqua.jl testset " *
            "never finished — see Pkg.test.error for the likely cause)",
        )
    end
    ts = captured.testset
    checks = QualityAquaCheck[]
    for r in ts.results
        if r isa Test.DefaultTestSet
            tc = Test.get_test_counts(r)
            passed =
                (tc.fails + tc.cumulative_fails + tc.errors + tc.cumulative_errors) == 0
            msg = passed ? nothing : join(_qc_failure_messages(r), "\n")
            push!(
                checks,
                QualityAquaCheck(; name = r.description, passed = passed, message = msg),
            )
        elseif r isa Union{Test.Fail, Test.Error}
            # Aqua.test_all 自体が check 用の子テストセットを作る前に落ちた場合の保険。
            push!(
                checks,
                QualityAquaCheck(;
                    name = "Aqua.test_all",
                    passed = false,
                    message = string(r),
                ),
            )
        end
    end
    if isempty(checks)
        return QualityToolExecution(;
            tool_name = "Aqua.jl",
            status = :failure,
            started_at = started_at,
            completed_at = completed_at,
            error = QualityToolError(;
                type = "CaptureFailure",
                message = "Aqua.test_all produced no recognizable check results",
            ),
        )
    end
    aqua_version = try
        string(pkgversion(Aqua))
    catch
        nothing
    end
    return QualityToolExecution(;
        tool_name = "Aqua.jl",
        status = :success,
        version = aqua_version,
        started_at = started_at,
        completed_at = completed_at,
        result = quality_tool_aqua_result(; checks = checks, settings = captured.settings),
    )
end

function _qc_formatter_tool(
    started_at::DateTime,
    completed_at::DateTime,
)::QualityToolExecution
    captured = QUALITY_CAPTURE_FORMATTER[]
    if captured === nothing
        return quality_tool_not_run(
            "JuliaFormatter.jl",
            "not reached before the test suite ended",
        )
    end
    formatter_version = try
        string(pkgversion(JuliaFormatter))
    catch
        nothing
    end
    return QualityToolExecution(;
        tool_name = "JuliaFormatter.jl",
        status = :success,
        version = formatter_version,
        started_at = started_at,
        completed_at = completed_at,
        result = quality_tool_formatter_result(;
            formatted = captured.formatted,
            unformatted_files = captured.unformatted_files,
        ),
    )
end

#: まだ配線されていない予約ツール（後続 Issue が個別に置き換える。scripts/quality_export.jl の
#: 骨格と同じプレースホルダ文言）。
const _QC_NOT_YET_WIRED = ("Coverage.jl", "JET.jl", "BenchmarkTools.jl", "Documenter.jl")

"""
    run_quality_capture(test_files::Vector{String}) -> Nothing

`test_files`（`test/runtests.jl` の `DME_TEST_FILES` と同じ相対パス一覧）を1つの外側の
`@testset` で包んで実行し、`Pkg.test`/`Aqua.jl`/`JuliaFormatter.jl` の構造化結果を含む
`QualityExport` を `DME_QUALITY_EXPORT_OUTPUT`（既定 `artifacts/quality/quality-export.json`）
へ保存する。予約7ツールのうち残り4ツール（Coverage.jl/JET.jl/BenchmarkTools.jl/Documenter.jl。
#209/#211/#212/#213）は `status=:skipped` のプレースホルダで埋める。

テスト失敗時の exit code を隠さないため、捕捉した `Test.TestSetException` は export 保存後に
必ず再 throw する。
"""
function run_quality_capture(test_files::Vector{String})::Nothing
    started_at = DME._qc_now_utc()
    result_ts = nothing
    caught_exc = nothing
    try
        result_ts = @testset "DME (quality capture)" begin
            for f in test_files
                include(f)
            end
        end
    catch e
        if e isa Test.TestSetException
            caught_exc = e
        else
            rethrow()
        end
    end
    completed_at = DME._qc_now_utc()

    # world age: 上の include ループが新しい world で定義した binding
    # （QUALITY_CAPTURE_AQUA/QUALITY_CAPTURE_FORMATTER・Aqua・JuliaFormatter）を
    # _qc_finish（およびそこから呼ぶ _qc_aqua_tool/_qc_formatter_tool）が読めるよう、
    # invokelatest 越しに呼ぶ（ファイル冒頭コメント参照）。
    Base.invokelatest(_qc_finish, started_at, completed_at, result_ts, caught_exc)
    return nothing
end

function _qc_finish(
    started_at::DateTime,
    completed_at::DateTime,
    result_ts,
    caught_exc,
)::Nothing
    tools = QualityToolExecution[
        _qc_pkgtest_tool(started_at, completed_at, result_ts, caught_exc),
        _qc_aqua_tool(started_at, completed_at),
        _qc_formatter_tool(started_at, completed_at),
    ]
    for name in _QC_NOT_YET_WIRED
        push!(
            tools,
            quality_tool_not_run(
                name,
                "not wired up yet: Issue #208 wires up Pkg.test/Aqua.jl/JuliaFormatter.jl only; " *
                "per-tool execution for this tool is added by a later issue",
            ),
        )
    end

    export_ = QualityExport(;
        package = quality_export_package_identity(),
        repository = QualityExportRepository(;
            owner = get(ENV, "DME_QUALITY_EXPORT_REPO_OWNER", "Yuki-Watanabe7"),
            name = get(ENV, "DME_QUALITY_EXPORT_REPO_NAME", "DME"),
        ),
        branch = _qc_branch(),
        commit = _qc_commit_sha(),
        measured_at = started_at,
        generated_at = completed_at,
        tools = tools,
    )
    output_path = get(
        ENV,
        "DME_QUALITY_EXPORT_OUTPUT",
        joinpath(@__DIR__, "..", "artifacts", "quality", "quality-export.json"),
    )
    saved_path = save_quality_export(export_, output_path)
    println("Julia品質Export（Issue #208）を書き出しました: ", saved_path)

    caught_exc === nothing || throw(caught_exc)
    return nothing
end
