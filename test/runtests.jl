using DME
using Test
using Dates

const DME_TEST_FILES = [
    "test_util.jl",
    "test_data_series.jl",
    "test_fred.jl",
    "test_estat.jl",
    "test_preprocess.jl",
    "test_keen_empirical_data.jl",
    "test_keen_calibration.jl",
    "test_keen_validation.jl",
    "test_ramsey.jl",
    "test_rbc.jl",
    "test_solow.jl",
    "test_cli.jl",
    "test_islm.jl",
    "test_adas.jl",
    "test_new_keynesian.jl",
    "test_var.jl",
    "test_mundell_fleming.jl",
    "test_keen.jl",
    "test_minsky_regimes.jl",
    "test_minsky_diagnostics.jl",
    "test_simulation_result.jl",
    "test_compare_with_data.jl",
    "test_compare_v2.jl",
    "test_json_canonical.jl",
    "test_real_rate_model_artifact.jl",
    "test_real_rate_model_artifact_export.jl",
    "test_quality_export.jl",
    "test_sfc_primitives.jl",
    "test_sfc_accounting.jl",
    "test_sfc_sim.jl",
    "test_macro_event_types.jl",
    "test_event_scheduler.jl",
    "test_real_economy_events.jl",
    "test_capex_credit_cycle.jl",
    "test_capex_credit_cycle_accounting.jl",
    "test_capex_credit_cycle_diagnostics.jl",
    "test_capex_credit_cycle_visualization.jl",
    "test_analysis_context.jl",
    "test_keen_empirical_context.jl",
    "test_doc_context.jl",
    "test_prompts.jl",
    "test_keen_empirical_prompts.jl",
    "test_keen_empirical_safety.jl",
    "test_cross_model_reasoning.jl",
    "test_model_capabilities.jl",
    "test_keen_sfc_comparison.jl",
    "test_provider.jl",
    "test_visualization.jl",
    "test_minsky_visualization.jl",
    "test_keen_empirical_demo.jl",
    "test_keen_empirical_ai_economist_demo.jl",
    "test_sfc_ai_economist_demo.jl",
    "test_capex_credit_cycle_demo.jl",
    "test_quality_capture.jl",
    "test_quality.jl",
]

# JET.jl 統合の回帰テスト（Issue #211）: `DME_QUALITY_EXPORT_JET_ENABLED` が設定されている
# ときだけ test_quality_jet.jl を追加で実行する。JET.jl は slow lane 専用ツールであり、
# 通常の Pkg.test()（fast lane）には `using JET` が一切含まれないようにする
# （test_quality_jet.jl 冒頭コメント参照。「通常CIの所要時間へ影響しない」という
# Issue #211 の要件を満たすため）。`DME_TEST_FILES` は `const` だが `Vector` 自体は
# mutable なので `push!` で末尾に追加できる。
if get(ENV, "DME_QUALITY_EXPORT_JET_ENABLED", "") in ("1", "true")
    push!(DME_TEST_FILES, "test_quality_jet.jl")
end

# BenchmarkTools.jl 統合の回帰テスト（Issue #212）: JET.jl（上）と同じ opt-in 方式。
# `DME_QUALITY_EXPORT_BENCHMARK_ENABLED` が設定されているときだけ test_quality_benchmark.jl を
# 追加で実行する（通常の Pkg.test()（fast lane）には `using BenchmarkTools` が一切含まれない
# ようにする。test_quality_benchmark.jl 冒頭コメント参照）。
if get(ENV, "DME_QUALITY_EXPORT_BENCHMARK_ENABLED", "") in ("1", "true")
    push!(DME_TEST_FILES, "test_quality_benchmark.jl")
end

# Julia品質Export Contract v1（Issue #208）: `DME_QUALITY_EXPORT_ENABLED` が設定されている
# ときだけ、Pkg.test/Aqua.jl/JuliaFormatter.jl の構造化結果を捕捉する opt-in の実行経路を使う
# （test/quality_capture_runner.jl 冒頭コメント参照）。未設定時（既定）は今までどおり
# 逐次 `include` するだけで、挙動は一切変わらない
# （Issue #208「Export disabled時は通常の Pkg.test() 動作を変更しない」）。
if get(ENV, "DME_QUALITY_EXPORT_ENABLED", "") in ("1", "true")
    include("quality_capture_runner.jl")
    run_quality_capture(DME_TEST_FILES)
else
    for f in DME_TEST_FILES
        include(f)
    end
end
