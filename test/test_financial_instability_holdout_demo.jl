# 2026-09 Financial-Instability Live Holdoutデモ
# （examples/financial_instability_holdout_demo.jl）のテスト（Issue #260 Part D）。

const FIH_DEMO_SCRIPT_PATH =
    joinpath(@__DIR__, "..", "examples", "financial_instability_holdout_demo.jl")
include(FIH_DEMO_SCRIPT_PATH)

@testset "2026-09 Financial-Instability Live Holdoutデモ" begin
    @testset "smoke test（CLAUDE.md）: fixtureモードで完走し成果物を保存する" begin
        dir = mktempdir()
        out = run_financial_instability_holdout_demo(; outdir = dir, verbose = false)
        @test out.assessment isa FinancialInstabilityAssessment
        @test isfile(out.assessment_path)
        @test isfile(out.report_path)
        @test filesize(out.assessment_path) > 0
        @test filesize(out.report_path) > 0
    end

    @testset "決定性: 2回実行で同じidentity_hashになる" begin
        dir1 = mktempdir()
        dir2 = mktempdir()
        out1 = run_financial_instability_holdout_demo(; outdir = dir1, verbose = false)
        out2 = run_financial_instability_holdout_demo(; outdir = dir2, verbose = false)
        d1 = financial_instability_assessment_to_dict(out1.assessment)
        d2 = financial_instability_assessment_to_dict(out2.assessment)
        @test d1["identity_hash"] == d2["identity_hash"]
        @test d1["overall_status"] == d2["overall_status"]
    end

    @testset "from_date/to_dateを指定できる" begin
        dir = mktempdir()
        out = run_financial_instability_holdout_demo(;
            outdir = dir, from_date = "2026-08-25", to_date = "2026-08-28", verbose = false,
        )
        @test out.assessment.from_date == "2026-08-25"
        @test out.assessment.to_date == "2026-08-28"
    end

    @testset "FredClient/DataProviderClientをネットワーク非依存で使う（fixtureモード既定）" begin
        # DME_DATA_MODE が未設定（liveでない）限り、live/rest_apiのHTTPを呼ばない。
        @test get(ENV, "DME_DATA_MODE", "") != "live"
        dir = mktempdir()
        out = run_financial_instability_holdout_demo(; outdir = dir, verbose = false)
        @test out.assessment.broad_conditions_state.nfci_latest !== nothing
        @test out.assessment.broad_conditions_state.sloos_latest !== nothing
    end

    @testset "成果物・報告に必須の禁止表現チェックを含む注意事項が出力される" begin
        dir = mktempdir()
        out = run_financial_instability_holdout_demo(; outdir = dir, verbose = false)
        report = read(out.report_path, String)
        @test occursin("危機確率", report)
        @test occursin("投資判断", report)
        @test occursin("fictional", report)

        d = financial_instability_assessment_to_dict(out.assessment)
        @test occursin("危機確率", join(d["caveats"], " "))
    end

    @testset "overall_statusが型で強制された語彙に収まる" begin
        dir = mktempdir()
        out = run_financial_instability_holdout_demo(; outdir = dir, verbose = false)
        @test out.assessment.overall_status in FINANCIAL_INSTABILITY_STATUSES
    end
end
