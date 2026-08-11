# scripts/jet_analysis_worker.jl
#
# Julia品質Export Contract v1（Issue #211）: JET.jl（静的解析）を実際に実行する worker。
# `scripts/quality_export_jet.jl`（driver）が subprocess として起動する想定
# （`julia --project=. --startup-file=no scripts/jet_analysis_worker.jl <output-json-path>`）。
# 単体でも実行できる（`<output-json-path>` へ生の解析結果 JSON を書き出すだけで、
# `julia-quality-export/v1` の envelope は組み立てない — envelope 組み立ては driver 側の責務）。
#
# ## なぜ driver と worker の2プロセスに分けるか
#
# JET.jl の解析（`report_package`）はローカル実測で約30〜90秒（Issue #211 作業中に複数回
# 計測、docs/contract/julia-quality-export-v1.md §4.3 参照）と短いが、契約上は
# timeout/crash を明示的な `status` として区別できる必要がある（Issue #211「0件成功、
# 複数finding、timeout、crash、未導入を区別できる」）。Julia には実行中の CPU-bound な
# 呼び出し（yield しない型推論処理）を同一プロセス内から安全に打ち切る標準的な方法が無いため、
# 「driver プロセスが worker を subprocess として起動し、期限を超えたら kill する」という
# OS プロセスレベルの制御に頼る（`scripts/quality_export_coverage.jl` が `Pkg.test()` の
# サブプロセス実行に依存しているのと同種の設計判断 — ただし理由は異なる: あちらは `.cov` の
# flush タイミング、こちらは timeout 制御）。
#
# ## 環境: なぜ `--project=.` で起動した後に `test/` へ切り替えるか
#
# `report_package(DME; ...)` を呼ぶには DME 自身とその依存（JuMP/Ipopt/Plots 等）が
# ロード済みである必要があり、それには root の `--project=.` が要る。一方 JET.jl は
# slow-lane 専用ツールであり DME の実行時依存にしない方針（src/quality/quality_capture.jl
# 冒頭コメント参照）のため `test/Project.toml` にのみ追加した。`scripts/
# quality_export_coverage.jl` と同じトリック（`using DME` を先に済ませてから
# `Pkg.activate(test/)` へ切り替えて `using JET`）を使う: 一度ロードされたモジュールは
# その後の環境切り替えの影響を受けない。`using JET` はトップレベルの逐次文として書く
# （関数の中に閉じ込めない）ため world age の invokelatest は不要
# （quality_export_coverage.jl 冒頭コメントの「world age に関する注意」と同じ理由）。
#
# ## 出力形式
#
# 成功時: `{"tool_version": "<JET.jlのバージョン>", "result": <quality_tool_jet_result の出力>}`
# 失敗時（解析処理自体が例外を投げた場合。JET.jl 自体のバグ・OOM 等）:
#   `{"worker_error": {"type": "...", "message": "..."}}` を書き出し、
#   `exit(1)` する（driver 側が exit code と JSON の両方で失敗を判別できるようにする —
#   subprocess の exit code だけでは「kill された（timeout）」と区別できないため、JSON の
#   内容が「正常系の result」か「worker_error」かで crash/timeout を driver が仕分ける）。
#
# 実行方法（単体）:
#   julia --project=. scripts/jet_analysis_worker.jl /tmp/jet-raw.json

using DME

const _REPO_ROOT = normpath(joinpath(@__DIR__, ".."))

function _worker_output_path()::String
    isempty(ARGS) &&
        error("usage: julia --project=. scripts/jet_analysis_worker.jl <output-json-path>")
    return ARGS[1]
end

# root 環境（DME 自身の依存）はここまでに解決済み。ここから test/ 環境（JET.jl 等）へ
# 切り替える（`using DME` 実行後、かつトップレベルの逐次文として — ファイル冒頭コメント参照）。
import Pkg
Pkg.activate(joinpath(_REPO_ROOT, "test"))
using JET

include(joinpath(_REPO_ROOT, "scripts", "jet_report_extract.jl"))

function _run_jet_analysis()::Dict{String, Any}
    res = report_package(DME; target_modules = (DME,))
    reports = JET.get_reports(res)
    findings = jet_findings_from_reports(reports; repo_root = _REPO_ROOT)
    result = quality_tool_jet_result(; findings = findings, target_modules = ["DME"])
    jet_version = try
        string(pkgversion(JET))
    catch
        nothing
    end
    return Dict{String, Any}("tool_version" => jet_version, "result" => result)
end

function main()
    output_path = _worker_output_path()
    dir = dirname(output_path)
    isempty(dir) || mkpath(dir)

    payload = try
        _run_jet_analysis()
    catch e
        err_payload = Dict{String, Any}(
            "worker_error" => Dict{String, Any}(
                "type" => redact_secrets(string(typeof(e))),
                "message" => redact_secrets(sprint(showerror, e)),
            ),
        )
        write(output_path, canonical_json_string(err_payload))
        println(stderr, "JET analysis failed: ", sprint(showerror, e))
        exit(1)
    end

    write(output_path, canonical_json_string(payload))
    println(
        "JET.jl analysis complete: error_count=",
        payload["result"]["error_count"],
        " -> ",
        output_path,
    )
    return nothing
end

main()
