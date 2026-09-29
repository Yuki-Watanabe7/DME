# Japan Fiscal Scenario Lab 実行例（examples/japan_fiscal_scenario_lab_demo.jl）のテスト（Issue #277）。
#
#   - 例スクリプトが公開 API だけで完走し、handoff bundle を書いて fail closed に読み戻せる
#   - 各 family の primary セルが実行され、表現不能セル・必須 assumption 未指定が実行されない
#   - 同一プロセスでの replay が content hash まで一致する
#   - FRE context・ネットワーク・API キーを必要としない

# 例スクリプトは PROGRAM_FILE ガードで直接実行時のみ走る。include では関数定義のみ読み込まれる。
include(joinpath(@__DIR__, "..", "examples", "japan_fiscal_scenario_lab_demo.jl"))

@testset "Japan Fiscal Scenario Lab 実行例（Issue #277）" begin
    outdir = joinpath(mktempdir(), "demo")
    out = run_japan_fiscal_scenario_lab_demo(;
        outdir = outdir,
        verbose = false,
        generated_at = DateTime(2026, 9, 30),
    )
    @test isfile(joinpath(out.bundle_dir, "index.json"))
    @test out.bundle.index["schema_version"] == JAPAN_FISCAL_HANDOFF_SCHEMA_VERSION
    @test all(r -> r.exact_match && r.within_tolerance, out.replays)

    for f in JAPAN_FISCAL_SCENARIO_FAMILIES
        primary = first(japan_fiscal_implementation_candidates(f))
        hits = [
            a for a in values(out.bundle.artifacts) if
            a isa JapanFiscalScenarioResult && a.family === f && a.model === primary
        ]
        @test length(hits) == 1
    end
    rejections = [a for a in values(out.bundle.artifacts) if a isa JapanFiscalScenarioRejection]
    @test Set(r.rejection_code for r in rejections) ==
          Set([:not_adopted, :missing_required_assumption])

    # 既存の出力先へは上書きしない
    @test_throws ArgumentError run_japan_fiscal_scenario_lab_demo(;
        outdir = outdir,
        verbose = false,
    )
end
