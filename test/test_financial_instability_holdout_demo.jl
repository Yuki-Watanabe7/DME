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

    @testset "run_manifest.json（Issue #271 Part A）" begin
        dir = mktempdir()
        out = run_financial_instability_holdout_demo(; outdir = dir, verbose = false)
        @test isfile(out.manifest_path)
        @test filesize(out.manifest_path) > 0

        m = out.manifest
        @test m["data_mode"] == "fixture"
        @test m["dme_code_revision"] isa String
        @test !isempty(m["dme_code_revision"])
        @test m["rule_version"] == out.assessment.thresholds.version
        @test m["assessment_version"] == out.assessment.version
        @test m["financial_stress_catalog_version"] isa String

        d = financial_instability_assessment_to_dict(out.assessment)
        @test m["assessment_identity_hash"] == d["identity_hash"]

        window = m["observation_window"]
        @test window["from_date"] == out.assessment.from_date
        @test window["to_date"] == out.assessment.to_date
        @test window["auto_selected"] == false
        @test window["selection_rule"] isa String
        @test !isempty(window["selection_rule"])

        provenance = m["series_provenance"]
        @test length(provenance) == 10  # EDP8系列 + NFCI + SLOOS
        keys_seen = Set(entry["key"] for entry in provenance)
        @test keys_seen == Set([
            "long_nominal_yield", "long_real_yield", "inflation_compensation",
            "ccc_oas", "broad_hy_oas", "sofr", "tgcr", "iorb", "NFCI", "DRTSCILM",
        ])
        for entry in provenance
            @test entry["status"] in ("ok", "missing_series", "provider_error", "invalid_response")
            @test entry["mode"] == "fixture"
        end

        # liveでない実行では EDP identity を取りに行かない
        @test m["edp_identity"] === nothing
    end

    @testset "select_observation_window（Issue #271 Part A の観測ウィンドウ選定ルール）" begin
        raw = build_financial_stress_raw_dataset(;
            client = DataProviderClient(; mode = :fixture, fixture_dir = _fih_demo_fixture_dir()),
        )

        @testset "通常ケース: cutoffちょうどの日付が両端とも存在する" begin
            w = select_observation_window(raw; to_date_cutoff = "2026-09-04", lookback_days = 7)
            @test w.to_date == "2026-09-04"
            @test w.from_date == "2026-08-28"
        end

        @testset "cutoffが非営業日: 直前の実観測日へ遡る" begin
            w = select_observation_window(raw; to_date_cutoff = "2026-08-30", lookback_days = 1)
            @test w.to_date == "2026-08-28"
        end

        @testset "lookback_daysが観測期間より長い場合はArgumentError" begin
            @test_throws ArgumentError select_observation_window(
                raw; to_date_cutoff = "2026-09-04", lookback_days = 28,
            )
        end

        @testset "lookback_daysは正でなければならない" begin
            @test_throws ArgumentError select_observation_window(raw; lookback_days = 0)
        end
    end

    @testset "run_financial_instability_holdout_live_snapshot はDME_DATA_MODE=liveを要求する" begin
        @test get(ENV, "DME_DATA_MODE", "") != "live"
        dir = mktempdir()
        @test_throws ArgumentError run_financial_instability_holdout_live_snapshot(;
            outdir = dir, verbose = false,
        )
    end

    @testset "post-FOMC比較（Issue #271 Part B・C・D）" begin
        @testset "run_financial_instability_post_fomc_comparison もDME_DATA_MODE=liveを要求する" begin
            @test get(ENV, "DME_DATA_MODE", "") != "live"
            pre_dir = mktempdir()
            run_financial_instability_holdout_demo(; outdir = pre_dir, verbose = false)
            @test_throws ArgumentError run_financial_instability_post_fomc_comparison(;
                pre_dir = pre_dir, outdir = mktempdir(), verbose = false,
            )
        end

        @testset "_fih_load_snapshot_dicts は保存済みassessment.json/run_manifest.jsonを読める" begin
            dir = mktempdir()
            out = run_financial_instability_holdout_demo(; outdir = dir, verbose = false)
            loaded = _fih_load_snapshot_dicts(dir)
            @test loaded.assessment["identity_hash"] == out.manifest["assessment_identity_hash"]
            @test loaded.manifest["dme_code_revision"] == out.manifest["dme_code_revision"]
        end

        @testset "compare_financial_instability_assessments + handoff + report（2つの保存済みsnapshotから）" begin
            pre_dir = mktempdir()
            post_dir = mktempdir()
            run_financial_instability_holdout_demo(;
                outdir = pre_dir, from_date = "2026-08-25", to_date = "2026-08-28", verbose = false,
            )
            post_out = run_financial_instability_holdout_demo(;
                outdir = post_dir, from_date = "2026-08-25", to_date = "2026-09-04", verbose = false,
            )
            pre = _fih_load_snapshot_dicts(pre_dir)
            post_assessment = financial_instability_assessment_to_dict(post_out.assessment)
            comparison = compare_financial_instability_assessments(
                pre.assessment, pre.manifest, post_assessment, post_out.manifest,
            )
            @test comparison.conclusion in FINANCIAL_INSTABILITY_COMPARISON_CONCLUSIONS
            @test comparison.pre_window["to_date"] == "2026-08-28"
            @test comparison.post_window["to_date"] == "2026-09-04"

            handoff = build_financial_instability_handoff(
                pre.assessment, pre.manifest, post_assessment, post_out.manifest,
            )
            report_path = _fih_write_comparison_report(
                joinpath(post_dir, "comparison_report.md"), comparison, handoff,
            )
            @test isfile(report_path)
            report = read(report_path, String)
            @test occursin("危機確率", report)
            @test occursin("投資判断", report)
            @test occursin(string(comparison.conclusion), report)
            @test occursin("unverified_economic_interpretation", report)
        end
    end
end
