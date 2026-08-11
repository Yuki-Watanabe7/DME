# test/test_quality_benchmark.jl
#
# BenchmarkTools.jl 統合（Issue #212）の回帰テスト。`scripts/benchmark_suite.jl`
# （suite 定義と1 case の実測ロジック）を、実際に `BenchmarkTools` を動かして検証する。
#
# **opt-in専用**: `test/runtests.jl` は `DME_QUALITY_EXPORT_BENCHMARK_ENABLED` が設定されて
# いるときだけ本ファイルを実行する（既定の `Pkg.test()` には含まれない）。BenchmarkTools.jl は
# slow lane 専用ツールであり、fast lane の所要時間へ影響を与えないという Issue #212 の要件
# （「通常CIの所要時間へ影響しない」）を保つため、`using BenchmarkTools` はこのファイル
# （および `scripts/benchmark_worker.jl`）に限定する。
#
# 測定時間予算は本番（`DME_BENCHMARK_SECONDS` = 5秒/case）ではなくテスト用の極小値を使う。
# ここで検証するのは**測定値そのものではなく測定経路の構造**（suite 定義の健全性・
# 戻り値の形・`QualityBenchmarkResult` へそのまま渡せること）である。実行時間の絶対値に
# 対する期待値はテストに固定しない（マシン依存で不安定になるため）。
#
# `scripts/quality_export_benchmark.jl` 自体（subprocess・timeout制御・baseline 突き合わせを
# 含む driver 経路）はここでは検証しない — `scripts/quality_export_coverage.jl`・
# `scripts/quality_export_jet.jl` と同じく実行（手動/CI slow lane）がその役割を担う
# （docs/contract/julia-quality-export-v1.md §8 方法E）。
#
# 実行方法:
#   DME_QUALITY_EXPORT_BENCHMARK_ENABLED=1 julia --project=. -e "using Pkg; Pkg.test()"

using BenchmarkTools
using Random

include(joinpath(@__DIR__, "..", "scripts", "benchmark_suite.jl"))

#: テスト用の極小の測定予算（本番は DME_BENCHMARK_SECONDS = 5秒）。
const _BENCH_TEST_KWARGS = (seconds = 0.05, samples_max = 5, evals = 1, warmup_evals = 1)

@testset "dme_benchmark_cases: suite 定義の健全性" begin
    cases = dme_benchmark_cases()
    @test !isempty(cases)

    ids = [c.id for c in cases]
    @test length(unique(ids)) == length(ids)
    @test all(!isempty(c.id) for c in cases)
    @test all(!isempty(c.group) for c in cases)
    @test all(!isempty(c.description) for c in cases)
    @test all(c.margin_percent > 0 for c in cases)

    # headline は suite 内に存在する id でなければならない
    # （`quality_tool_benchmark_result` が同じ不変条件を実行時に検査する）
    @test DME_BENCHMARK_HEADLINE_ID in ids
end

@testset "dme_benchmark_environment: 必須キーと environment_key の一致" begin
    env = dme_benchmark_environment()
    for key in ("key", "runner_label", "os", "arch", "julia_version")
        @test haskey(env, key)
        @test !isempty(env[key])
    end
    # key は個別要素から再構成できる（baseline 突き合わせの前提）
    @test env["key"] == quality_benchmark_environment_key(;
        runner_label = env["runner_label"],
        os = env["os"],
        arch = env["arch"],
        julia_version = env["julia_version"],
    )
    @test env["julia_version"] == string(VERSION)
    # key に含めない provenance も持つ（runner 差・dependency 更新差の記録）
    @test haskey(env, "cpu_threads")
    @test haskey(env, "manifest_digest")
end

@testset "dme_benchmark_run_case: 測定値の形と QualityBenchmarkResult への受け渡し" begin
    # suite 中で最も軽い case を1件だけ実測する（テストの所要時間を抑える）。
    case = only(filter(c -> c.id == "sfc_sim_simulate", dme_benchmark_cases()))
    m = dme_benchmark_run_case(case; _BENCH_TEST_KWARGS...)

    @test m.id == case.id
    @test m.group == case.group
    @test m.margin_percent == case.margin_percent
    # 実行時間の絶対値は固定しない。正であること（＝測定不能でないこと）だけを検査する。
    @test m.median_time_ns > 0
    @test m.memory_bytes >= 0
    @test m.allocs >= 0
    @test 1 <= m.samples <= _BENCH_TEST_KWARGS.samples_max
    @test m.evals_per_sample == _BENCH_TEST_KWARGS.evals

    # 測定値がそのまま QualityBenchmarkResult のキーワードとして通ること
    # （worker → driver → export の受け渡しで名前がずれていないことの回帰テスト）。
    r = QualityBenchmarkResult(;
        id = m.id,
        group = m.group,
        description = m.description,
        median_time_ns = m.median_time_ns,
        memory_bytes = m.memory_bytes,
        allocs = m.allocs,
        samples = m.samples,
        evals_per_sample = m.evals_per_sample,
        margin_percent = m.margin_percent,
    )
    @test r.regression_status == "unavailable"
    @test r.unavailable_reason == "baseline_missing"

    # baseline を与えれば同じ測定値から回帰判定が出る
    r_cmp = QualityBenchmarkResult(;
        id = m.id,
        group = m.group,
        description = m.description,
        median_time_ns = m.median_time_ns,
        memory_bytes = m.memory_bytes,
        allocs = m.allocs,
        samples = m.samples,
        evals_per_sample = m.evals_per_sample,
        margin_percent = m.margin_percent,
        baseline_median_time_ns = m.median_time_ns,
        unavailable_reason = nothing,
    )
    @test r_cmp.delta_percent == 0.0
    @test r_cmp.regression_status == "stable"
end

@testset "dme_benchmark_run_suite: 全 case が実測できる" begin
    # 全 case を極小予算で1周し、workload が例外を投げないこと・id が suite 定義と一致する
    # ことを確認する（本番の測定予算では時間がかかりすぎるためここでは使わない）。
    measurements = dme_benchmark_run_suite(; _BENCH_TEST_KWARGS...)
    @test length(measurements) == length(dme_benchmark_cases())
    @test [m.id for m in measurements] == [c.id for c in dme_benchmark_cases()]
    @test all(m.median_time_ns > 0 for m in measurements)
end
