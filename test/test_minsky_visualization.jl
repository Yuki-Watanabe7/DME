# GR バックエンドをヘッドレスモードで動作させる（CI / 無表示環境対応）
ENV["GKSwstype"] = "nul"
using Plots

@testset "Minsky visualization (Phase 2)" begin
    m = KeenModel(0.025, 0.02, 0.01, 3.0, 0.03, 0.0400641, 6.41e-5, -0.0065, exp(-5), 20.0)

    # unlevered → hedge → hedge(同一regime継続) → speculative → ponzi → invalid → invalid
    # の7時点フィクスチャ。全regime（unlevered/hedge/speculative/ponzi/invalid）と
    # 同一regime継続（帯の結合）、発散（invalid）を1本の系列でカバーする。
    ω_fixture = [0.5, 0.5, 0.5, 0.5, 0.99, NaN, NaN]
    d_fixture = [0.0, 0.1, 0.1, 1.0, 10.0, NaN, NaN]
    g_fixture = fill(0.03, 7)
    cfg = FinancingRegimeConfig(; amortization_rate = 0.5)

    diag = minsky_diagnostics(
        m,
        (ω = ω_fixture, d = d_fixture, g = g_fixture);
        config = cfg,
        scenario_name = "fixture",
    )

    regimes = [o.regime for o in diag.regime_diagnostics.observations]

    @testset "フィクスチャの前提（5 regime すべてを含む）" begin
        @test regimes == [unlevered, hedge, hedge, speculative, ponzi, invalid, invalid]
        @test length(diag.regime_diagnostics.transitions) == 4
        @test diag.divergence_time == 6
    end

    @testset "plot_financing_regimes" begin
        @testset "基本描画" begin
            p = plot_financing_regimes(diag)
            @test p isa Plots.Plot
        end

        @testset "凡例に代理診断である旨とregimeラベルが含まれる" begin
            p = plot_financing_regimes(diag)
            labels = [s[:label] for s in p.series_list]
            @test "unlevered" in labels
            @test "hedge" in labels
            @test "speculative" in labels
            @test "ponzi" in labels
            @test "invalid (unobservable / simulation truncated)" in labels
            # invalid は ponzi のラベル・帯へ混入しない（別ラベルとして独立に存在）
            @test count(==("ponzi"), labels) == 1
            @test occursin("aggregate proxy diagnostic", p.subplots[1][:title])
        end

        @testset "同一regimeの連続時点は1つの帯に結合される" begin
            # hedge が t=2,3 の2時点続くが、帯ラベル("hedge")は1回しか現れない
            p = plot_financing_regimes(diag)
            labels = [s[:label] for s in p.series_list]
            @test count(==("hedge"), labels) == 1
        end

        @testset "show_transitions=true/false で遷移マーカー数が transitions 数と一致する" begin
            p_with = plot_financing_regimes(diag; show_transitions = true)
            p_without = plot_financing_regimes(diag; show_transitions = false)
            @test p_with.n - p_without.n == length(diag.regime_diagnostics.transitions)
        end

        @testset "title カスタマイズ" begin
            p = plot_financing_regimes(diag; title = "カスタムタイトル")
            @test p.subplots[1][:title] == "カスタムタイトル"
        end

        @testset "観測が空でエラー" begin
            empty_diag = MinskyDiagnosticsResult(
                diag.model_name,
                diag.scenario_name,
                DME.MinskyDiagnosticObservation[],
                DME.FinancingRegimeDiagnostics(
                    DME.FinancingRegimeObservation[],
                    DME.FinancingRegimeTransition[],
                    cfg,
                    Int[],
                    Int[],
                ),
                cfg,
                diag.methodology_version,
                Int[],
                Int[],
                nothing,
                Dict{String, Any}(),
            )
            @test_throws ArgumentError plot_financing_regimes(empty_diag)
        end
    end

    @testset "plot_minsky_diagnostics" begin
        @testset "既定（5パネル結合）" begin
            p = plot_minsky_diagnostics(diag)
            @test p isa Plots.Plot
            @test length(p.subplots) >= 5
        end

        @testset "combine=false で Vector{Plots.Plot} を返す" begin
            plots = plot_minsky_diagnostics(diag; combine = false)
            @test plots isa Vector
            @test length(plots) == 5
            @test all(p -> p isa Plots.Plot, plots)
        end

        @testset "panels でサブセット指定" begin
            plots = plot_minsky_diagnostics(
                diag;
                panels = [:debt_ratio, :margin],
                combine = false,
            )
            @test length(plots) == 2
            p_combined = plot_minsky_diagnostics(diag; panels = [:debt_ratio, :margin])
            @test p_combined isa Plots.Plot
        end

        @testset "coverage ratio パネルに coverage=1 の境界線が追加される" begin
            plots = plot_minsky_diagnostics(diag; combine = false)
            coverage_panel = plots[3]
            labels = [s[:label] for s in coverage_panel.series_list]
            @test "coverage = 1" in labels
        end

        @testset "margin パネルに margin=0 の境界線が追加される" begin
            plots = plot_minsky_diagnostics(diag; combine = false)
            margin_panel = plots[4]
            labels = [s[:label] for s in margin_panel.series_list]
            @test "margin = 0" in labels
        end

        @testset "発散ガード作動時点の縦線が各パネルに追加される" begin
            plots = plot_minsky_diagnostics(diag; combine = false)
            for p in plots
                labels = [s[:label] for s in p.series_list]
                @test "divergence guard" in labels
            end
        end

        @testset "発散後のNaNを含む結果でも例外なく描画できる" begin
            p = plot_minsky_diagnostics(diag)
            @test p isa Plots.Plot
        end

        @testset "未知の panel キーでエラー" begin
            @test_throws ArgumentError plot_minsky_diagnostics(
                diag;
                panels = [:unknown_panel],
            )
        end

        @testset "観測が空でエラー" begin
            empty_diag = MinskyDiagnosticsResult(
                diag.model_name,
                diag.scenario_name,
                DME.MinskyDiagnosticObservation[],
                diag.regime_diagnostics,
                cfg,
                diag.methodology_version,
                Int[],
                Int[],
                nothing,
                Dict{String, Any}(),
            )
            @test_throws ArgumentError plot_minsky_diagnostics(empty_diag)
        end
    end

    @testset "plot_minsky_scenario_comparison" begin
        # baseline: 良い均衡近傍からの回帰（invalid なし）
        ω_baseline = [0.5, 0.5, 0.5, 0.5]
        d_baseline = [0.0, 0.1, 0.1, 1.0]
        g_baseline = fill(0.03, 4)
        diag_baseline = minsky_diagnostics(
            m,
            (ω = ω_baseline, d = d_baseline, g = g_baseline);
            config = cfg,
            scenario_name = "baseline",
        )
        cmp = minsky_diagnostics_comparison([
            "baseline" => diag_baseline,
            "high_debt" => diag,
        ],)

        @testset "基本比較プロット（既定 var=:debt_ratio）" begin
            p = plot_minsky_scenario_comparison(cmp)
            @test p isa Plots.Plot
            labels = [s[:label] for s in p.series_list]
            @test "baseline" in labels
            @test "high_debt" in labels
        end

        @testset "var 指定で他の指標も比較できる" begin
            for v in (
                :interest_coverage_ratio,
                :debt_service_coverage_ratio,
                :ponzi_margin,
                :hedge_margin,
                :net_profit_share,
                :growth_rate,
                :debt_change,
            )
                p = plot_minsky_scenario_comparison(cmp; var = v)
                @test p isa Plots.Plot
            end
        end

        @testset "未知の var でエラー" begin
            @test_throws ArgumentError plot_minsky_scenario_comparison(
                cmp;
                var = :not_a_var,
            )
        end

        @testset "シナリオ数が2未満でエラー" begin
            cmp_single = minsky_diagnostics_comparison(["only" => diag_baseline])
            @test_throws ArgumentError plot_minsky_scenario_comparison(cmp_single)
        end

        @testset "methodology_version/config 不一致は既定(strict=true)で拒否する" begin
            cfg_other = FinancingRegimeConfig(; amortization_rate = 0.1)
            diag_other = minsky_diagnostics(
                m,
                (ω = ω_baseline, d = d_baseline, g = g_baseline);
                config = cfg_other,
                scenario_name = "other_config",
            )
            cmp_mismatch = minsky_diagnostics_comparison([
                "baseline" => diag_baseline,
                "other" => diag_other,
            ])
            @test_throws ArgumentError plot_minsky_scenario_comparison(cmp_mismatch)
        end

        @testset "strict=false で不一致でも比較を継続する（警告のみ）" begin
            cfg_other = FinancingRegimeConfig(; amortization_rate = 0.1)
            diag_other = minsky_diagnostics(
                m,
                (ω = ω_baseline, d = d_baseline, g = g_baseline);
                config = cfg_other,
                scenario_name = "other_config",
            )
            cmp_mismatch = minsky_diagnostics_comparison([
                "baseline" => diag_baseline,
                "other" => diag_other,
            ])
            p = plot_minsky_scenario_comparison(cmp_mismatch; strict = false)
            @test p isa Plots.Plot
        end

        @testset "発散後NaNを含むシナリオを含めても例外なく描画できる" begin
            p = plot_minsky_scenario_comparison(cmp; var = :debt_ratio)
            @test p isa Plots.Plot
        end

        @testset "title カスタマイズ" begin
            p = plot_minsky_scenario_comparison(cmp; title = "比較タイトル")
            @test p.subplots[1][:title] == "比較タイトル"
        end
    end

    @testset "headless CI でのプロット保存" begin
        mktempdir() do dir
            p_regimes = plot_financing_regimes(diag)
            p_diag = plot_minsky_diagnostics(diag)
            path_regimes = joinpath(dir, "regimes.png")
            path_diag = joinpath(dir, "diagnostics.png")
            savefig(p_regimes, path_regimes)
            savefig(p_diag, path_diag)
            @test isfile(path_regimes)
            @test isfile(path_diag)
        end
    end
end
