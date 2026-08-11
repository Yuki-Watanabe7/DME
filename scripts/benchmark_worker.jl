# scripts/benchmark_worker.jl
#
# Julia品質Export Contract v1（Issue #212）: BenchmarkTools.jl の実測を行う worker。
# `scripts/quality_export_benchmark.jl`（driver）が subprocess として起動する想定
# （`julia --startup-file=no --project=. scripts/benchmark_worker.jl <output-json-path>`）。
# 単体でも実行できる（`<output-json-path>` へ生の測定結果 JSON を書き出すだけで、
# baseline との比較や `julia-quality-export/v1` の envelope 組み立ては driver 側の責務）。
#
# ## driver と worker の2プロセス構成（JET.jl slow lane #211 と同じ）
#
# benchmark 自体の失敗/timeout を「遅い結果」として扱わない（Issue #212「benchmark自体の
# 失敗/timeoutを遅い結果として扱わない」）ためには、timeout を `BenchmarkTools.jl` の
# 測定値ではなく実行状態として区別できる必要がある。Julia には実行中の CPU-bound な
# ループを同一プロセス内から安全に打ち切る標準的な方法が無いため、driver が worker を
# subprocess として起動し期限超過で kill する（`scripts/jet_analysis_worker.jl`
# 冒頭コメントと同じ設計判断）。
#
# 加えて benchmark 特有の理由として、**測定プロセスを毎回まっさらにする**という目的もある:
# driver 側で既に走らせた処理（baseline の読み込み・JSON パース等）が残したヒープ状態・
# GC 圧が測定へ混入しない。
#
# ## 環境: なぜ `--project=.` のまま `LOAD_PATH` へ `test/` を積むか
#
# `dme_benchmark_cases()` は DME 本体とその依存（JuMP/Ipopt/Plots 等）を必要とするため
# root の `--project=.` が要る。一方 BenchmarkTools.jl は slow-lane 専用ツールであり
# DME の実行時依存にしない方針（src/quality/quality_capture.jl の BenchmarkTools.jl 節）の
# ため `test/Project.toml` にのみ追加した。
#
# `scripts/jet_analysis_worker.jl`（#211）は `Pkg.activate(test/)` で環境そのものを
# 切り替えているが、本 worker は root プロジェクトを active のまま `LOAD_PATH` の末尾へ
# `test/` を積む方式を採る。理由は2つ:
#
#   1. MathOptInterface（JuMP 経由で root 環境から読み込まれる）は BenchmarkTools.jl に
#      対する weak dependency 拡張（`MathOptInterfaceBenchmarkToolsExt`）を持つ。
#      `Pkg.activate` で active 環境を test/ へ切り替えると、この拡張が root 環境の
#      manifest からは見つからず `Error: Error during loading of extension ...` が
#      毎回ログへ出る（実行自体は継続し測定結果にも影響しないが、CI ログが壊れて見える）。
#      LOAD_PATH へ積む方式なら両方の環境が同時に可視なので拡張が正常に解決する。
#   2. 環境を切り替えると、切り替え後に初めて読み込まれる共有依存が test/ 側の manifest の
#      バージョンで解決されうる。LOAD_PATH の先頭は root のままなので、測定対象である
#      DME の依存は常に root の manifest どおりになる。
#
# `using BenchmarkTools` はトップレベルの逐次文として書く（関数の中に閉じ込めない）ため
# world age の invokelatest は不要。
#
# ## 出力形式
#
# 成功時:
#   {"tool_version": "<BenchmarkTools.jl のバージョン>",
#    "environment": {...}, "config": {...},
#    "measurements": [{"id": ..., "median_time_ns": ..., ...}, ...]}
# 失敗時（測定処理自体が例外を投げた場合）:
#   {"worker_error": {"type": "...", "message": "..."}} を書き出して `exit(1)`
#   （driver 側が exit code と JSON の両方で失敗を判別できるようにする — subprocess の
#   exit code だけでは「kill された（timeout）」と区別できないため）。
#
# 実行方法（単体）:
#   julia --project=. scripts/benchmark_worker.jl /tmp/benchmark-raw.json

using DME
using Dates
using Random

const _REPO_ROOT = normpath(joinpath(@__DIR__, ".."))

function _worker_output_path()::String
    isempty(ARGS) &&
        error("usage: julia --project=. scripts/benchmark_worker.jl <output-json-path>")
    return ARGS[1]
end

# root 環境（DME 自身の依存）はここまでに解決済み。BenchmarkTools.jl だけを test/ 環境から
# 追加で見えるようにする（active 環境は root のまま。ファイル冒頭コメント参照）。
push!(LOAD_PATH, joinpath(_REPO_ROOT, "test"))
using BenchmarkTools

include(joinpath(_REPO_ROOT, "scripts", "benchmark_suite.jl"))

"""測定条件の provenance（`quality_tool_benchmark_result` の `config`）。suite 側の定数を
そのまま写し、export だけから測定条件を再現できるようにする。"""
function _benchmark_config()::Dict{String, Any}
    return Dict{String, Any}(
        "seconds_per_benchmark" => DME_BENCHMARK_SECONDS,
        "samples_max" => DME_BENCHMARK_SAMPLES_MAX,
        "evals_per_sample" => DME_BENCHMARK_EVALS_PER_SAMPLE,
        "warmup_evals" => DME_BENCHMARK_WARMUP_EVALS,
        "seed" => DME_BENCHMARK_SEED,
        "estimator" => "median",
        "tuned" => false,
        "headline_id" => DME_BENCHMARK_HEADLINE_ID,
    )
end

function _run_benchmarks()::Dict{String, Any}
    measurements = dme_benchmark_run_suite()
    tool_version = try
        string(pkgversion(BenchmarkTools))
    catch
        nothing
    end
    return Dict{String, Any}(
        "tool_version" => tool_version,
        "environment" => dme_benchmark_environment(),
        "config" => _benchmark_config(),
        "measurements" => Any[
            Dict{String, Any}(String(k) => v for (k, v) in pairs(m)) for m in measurements
        ],
    )
end

function main()
    output_path = _worker_output_path()
    dir = dirname(output_path)
    isempty(dir) || mkpath(dir)

    payload = try
        _run_benchmarks()
    catch e
        err_payload = Dict{String, Any}(
            "worker_error" => Dict{String, Any}(
                "type" => redact_secrets(string(typeof(e))),
                "message" => redact_secrets(sprint(showerror, e)),
            ),
        )
        write(output_path, canonical_json_string(err_payload))
        println(stderr, "benchmark run failed: ", sprint(showerror, e))
        exit(1)
    end

    write(output_path, canonical_json_string(payload))
    println(
        "BenchmarkTools.jl run complete: ",
        length(payload["measurements"]),
        " benchmarks -> ",
        output_path,
    )
    for m in payload["measurements"]
        println(
            "  ",
            rpad(m["id"], 28),
            lpad(round(m["median_time_ns"] / 1e6; digits = 4), 12),
            " ms  (samples=",
            m["samples"],
            ")",
        )
    end
    return nothing
end

main()
