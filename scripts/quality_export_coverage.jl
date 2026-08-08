# scripts/quality_export_coverage.jl
#
# Julia品質Export Contract v1（`julia-quality-export/v1`）: `Coverage.jl`（line coverage）を
# 含めて quality export を書き出す driver スクリプト（Issue #209）。
#
# 実行方法:
#   julia --project=. scripts/quality_export_coverage.jl
#   # 出力先の指定（優先順）: 環境変数 DME_QUALITY_EXPORT_OUTPUT >
#   #   既定 artifacts/quality/quality-export.json（scripts/quality_export.jl と同じ既定値）
#
# `--project=.`（ルートプロジェクト）で起動すること。`Pkg.test()` は「現在アクティブな
# プロジェクトがテスト対象パッケージ（DME）そのもの」という前提に依存するため。
#
# ## 設計: なぜ Coverage.jl だけ2段階に分かれているか
#
# Julia のコード coverage（`.cov` トレースファイル）は、計測対象を実行した julia プロセス自身が
# **終了したとき**にのみディスクへ書き出される（Coverage.jl 側の制約であり DME 側の実装選択では
# ない。`--code-coverage=user` を付けたプロセスの実行中に `.cov` を読みに行っても存在しないことを
# 本 Issue の作業中に実測で確認済み）。
#
# 一方 `Pkg.test()` は常に `test/runtests.jl` を**別のサブプロセス**として spawn する。したがって:
#
#   1. 本スクリプト（driver プロセス、`--project=.` で起動）が `DME_QUALITY_EXPORT_ENABLED=1` を
#      設定した上で `Pkg.test(coverage=true)` を呼ぶ。
#      → 子サブプロセス内では `test/quality_capture_runner.jl` の `run_quality_capture` が
#        `Pkg.test`/`Aqua.jl`/`JuliaFormatter.jl` を実測し、`Coverage.jl` は「coverage は
#        driver プロセス側で後段計測する」という reason 付きの `:skipped` プレースホルダで
#        埋めた quality export をディスクへ書き出す（子プロセス自身はまだ `src/**.cov` を
#        読めない — 自分自身がまさに書き込んでいる最中のファイルだから）。
#   2. 子サブプロセスが終了し、`Pkg.test()` が driver プロセスへ制御を返す。この時点で
#      `src/**/*.jl.<pid>.cov` はすべて確定している。
#   3. driver プロセスが `Coverage.process_folder("src")` で集計し、1 で書き出された export
#      ファイルを読み込み、`Coverage.jl` のエントリだけを実測値へ置き換えて
#      （`quality_export_with_tool`）再保存する。
#   4. `.cov` ファイルを `Coverage.clean_folder` で削除する（取り残し対策として `.gitignore` にも
#      `*.jl.cov`/`*.jl.[0-9]*.cov` を追加済み）。
#
# `Pkg.test(coverage=true)` は1回しか呼ばない（`DME_QUALITY_EXPORT_ENABLED` 無し版ともう一度
# coverage 版で計2回テストスイート全体を実行するのは CI 時間の浪費であり、Issue #209 が求める
# 「現行 Pkg.test() と整合するcoverage計測コマンド」に反する）。
#
# ## 失敗の扱い（Issue #209「Coverage.jl自体の失敗でテスト成功を上書きするか、品質jobのみ
# 失敗させるかを明示する」への回答）
#
# - `Pkg.test()` 自体が失敗した（テスト失敗・エラー）場合: 本スクリプトは export 更新後に
#   その例外を re-throw する。CI の exit code は変えない（今までどおりテスト失敗で CI が落ちる）。
# - coverage の集計だけが失敗した場合（`Coverage.process_folder` が例外を投げた、
#   `coverable_lines <= 0` で計測不能とみなした等）: `Coverage.jl` のエントリを
#   `status=:failure` にするだけで、本スクリプトの終了コードには影響させない。テストが成功して
#   いる限り CI 全体は成功のまま終わる（Issue #209「初期導入では Quality Gate で merge を
#   阻止せず、baseline 収集を優先する」という明示的な決定）。
#
# ## world age に関する注意（test/quality_capture_runner.jl 冒頭コメントと対）
#
# 本スクリプトは `Pkg.activate` → `using Coverage` を**トップレベルの逐次文**として書く
# （関数の中に閉じ込めない）。`quality_capture_runner.jl` の `run_quality_capture` が
# `Base.invokelatest` を必要とするのは、`using Aqua`/`using JuliaFormatter` が「実行中の1つの
# 関数呼び出しの内側」で（nested `include` 経由で）新しい world を作ってしまうため。本スクリプト
# はそのような入れ子がなく、`using Coverage` はそれより後のトップレベル文・関数呼び出しからだけ
# 参照されるため、`invokelatest` は不要。

using Pkg
using Dates

const _REPO_ROOT = normpath(joinpath(@__DIR__, ".."))

# DME 自体は --project=. が要求する root project から読み込む（Pkg.test() の前提と同じ）。
using DME

_now_utc()::DateTime = Dates.floor(Dates.unix2datetime(time()), Dates.Second)

function _output_path()::String
    return get(
        ENV,
        "DME_QUALITY_EXPORT_OUTPUT",
        joinpath(_REPO_ROOT, "artifacts", "quality", "quality-export.json"),
    )
end

# --- フェーズ1: Pkg.test(coverage=true) を一度だけ実行する ------------------------------

ENV["DME_QUALITY_EXPORT_ENABLED"] = "1"
const _TEST_EXCEPTION = try
    Pkg.test(; coverage = true)
    nothing
catch e
    e
end

const _COVERAGE_STARTED_AT = _now_utc()
const _OUTPUT_PATH = _output_path()

if !isfile(_OUTPUT_PATH)
    # 子プロセス側が quality export 自体を書き出せなかった（初期化の致命的失敗等）。
    # 更新対象が無いため、ここで打ち切る。テストの失敗があればそちらを優先して報告する。
    println(stderr, "quality export ファイルが見つかりません: ", _OUTPUT_PATH)
    _TEST_EXCEPTION === nothing || throw(_TEST_EXCEPTION)
    error(
        "Pkg.test(coverage=true) は完了しましたが quality export が書き出されていません: " *
        _OUTPUT_PATH,
    )
end

# --- フェーズ2: サブプロセス終了により確定した .cov を集計する --------------------------

# test/Project.toml（test/Manifest.toml でバージョン固定済み）の Coverage.jl を、ルート
# Project.toml の [deps] を汚さずに使う。scripts/format.sh の
# `Pkg.activate(temp=true); Pkg.add(...)` と同じ「後段で環境を切り替えて using する」パターン
# だが、こちらは temp env ではなく test/ の固定バージョンを再利用する
# （docs/development/quality_checks.md §2.1「テスト依存のバージョン固定」方針を踏襲）。
# Pkg.test() を呼び終えた**後**にのみ切り替えること（呼ぶ前に active project を変えると
# Pkg.test() が「現在のパッケージ」を見失う）。
Pkg.activate(joinpath(_REPO_ROOT, "test"))
using Coverage

"""
`Coverage.process_folder`/`Coverage.get_summary` で `src/` 配下の line coverage を集計し、
`Coverage.clean_folder` でトレースファイルを削除した上で `QualityToolExecution` を返す。
集計自体が失敗した場合、および `coverable_lines <= 0`（`.cov` が1件も生成されなかった等の
計測不能）の場合は `status=:failure` を返す（呼び出し元では re-throw しない。ファイル冒頭
コメント「失敗の扱い」参照）。
"""
function _coverage_tool_execution(
    started_at::DateTime,
    completed_at::DateTime,
)::QualityToolExecution
    version = try
        string(pkgversion(Coverage))
    catch
        nothing
    end

    target_dir = joinpath(_REPO_ROOT, DME.QUALITY_COVERAGE_TARGET_PATHS[1])
    summary = try
        file_coverages = process_folder(target_dir)
        result = get_summary(file_coverages)
        clean_folder(target_dir)
        result
    catch e
        return QualityToolExecution(;
            tool_name = "Coverage.jl",
            status = :failure,
            version = version,
            started_at = started_at,
            completed_at = completed_at,
            error = QualityToolError(;
                type = string(typeof(e)),
                message = "Coverage.process_folder/get_summary failed: " *
                          sprint(showerror, e),
            ),
        )
    end
    covered, coverable = summary

    if coverable <= 0
        return QualityToolExecution(;
            tool_name = "Coverage.jl",
            status = :failure,
            version = version,
            started_at = started_at,
            completed_at = completed_at,
            error = QualityToolError(;
                type = "NoCoverableLines",
                message = "Coverage.process_folder(\"src\") reported 0 coverable lines " *
                          "(no .cov tracefiles were found under src/). This means coverage " *
                          "was not actually collected -- it is not the same as 0% coverage.",
            ),
        )
    end

    return QualityToolExecution(;
        tool_name = "Coverage.jl",
        status = :success,
        version = version,
        started_at = started_at,
        completed_at = completed_at,
        result = DME.quality_tool_coverage_result(;
            covered_lines = covered,
            coverable_lines = coverable,
            target_paths = DME.QUALITY_COVERAGE_TARGET_PATHS,
            excluded_paths = DME.QUALITY_COVERAGE_EXCLUDED_PATHS,
        ),
    )
end

coverage_tool = _coverage_tool_execution(_COVERAGE_STARTED_AT, _now_utc())

existing_export = load_quality_export(_OUTPUT_PATH)
updated_export =
    quality_export_with_tool(existing_export, coverage_tool; generated_at = _now_utc())
save_quality_export(updated_export, _OUTPUT_PATH)

println("=== Coverage.jl（Issue #209） ===")
println("  status = ", coverage_tool.status)
if coverage_tool.result !== nothing
    println(
        "  covered_lines/coverable_lines = ",
        coverage_tool.result["covered_lines"],
        "/",
        coverage_tool.result["coverable_lines"],
    )
elseif coverage_tool.error !== nothing
    println("  error = ", coverage_tool.error.type, ": ", coverage_tool.error.message)
end
println("  saved to: ", _OUTPUT_PATH)
println("契約: docs/contract/julia-quality-export-v1.md")

# テストが失敗していた場合は、export 更新後にここで初めて CI の exit code を落とす
# （coverage 側の成否とは独立。ファイル冒頭コメント「失敗の扱い」参照）。
_TEST_EXCEPTION === nothing || throw(_TEST_EXCEPTION)
