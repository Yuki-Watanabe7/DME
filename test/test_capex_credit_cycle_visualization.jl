# 部門別CAPEX・信用循環モデル（src/analysis/capex_credit_cycle_visualization.jl）の `I-7` テスト
# （Issue #185）。
#
# 対象: `plot_capex_series`（潜在変数の単独提示抑止）・`plot_capex_sector_series`（部門別系列）・
# `plot_capex_scenario_comparison`（dY/dI/dC の baseline 比乖離）・`plot_capex_diagnostic_label`
# （診断ラベルの時間帯表示）・`plot_capex_funding_pressure`（funding_pressure_s の帯グラフ）。
# 対象外: 図の内部数値の期待値固定・LLM 説明（Phase 4）・`capex_diagnostics` 自体の受け入れ条件
# （`test_capex_credit_cycle_diagnostics.jl`）。

ENV["GKSwstype"] = "nul"
using Plots

function _viz_run(m::DME.CapexCreditCycleModel, id::Symbol)
    sc = capex_scenario(id)
    paths = capex_exogenous_paths(m, sc)
    return DME.capex_run(m; scenario = id, exog = paths)
end

@testset "CapexCreditCycleModel 可視化（部門別CAPEX・信用循環モデル、I-7）" begin
    targets = capex_credit_cycle_default_targets()
    m = capex_credit_cycle_model(targets)

    run0 = _viz_run(m, :Sc0)
    run3 = _viz_run(m, :Sc3)
    sr0 = to_simulation_result(m, run0, "Sc0")
    sr3 = to_simulation_result(m, run3, "Sc3")
    diag3 = capex_diagnostics(m, run3)

    @testset "smoke test（CLAUDE.md）" begin
        @test plot_capex_series(sr3; vars = ["y_tot"]) isa Plots.Plot
        @test plot_capex_sector_series(sr3) isa Plots.Plot
        @test plot_capex_scenario_comparison(m, [run0, run3]) isa Plots.Plot
        @test plot_capex_diagnostic_label(diag3, run3) isa Plots.Plot
        @test plot_capex_funding_pressure(diag3, run3) isa Plots.Plot
    end

    @testset "plot_capex_series" begin
        @testset "基本描画（plot_result と同じ挙動）" begin
            p = plot_capex_series(sr3; vars = ["y_tot", "cons"])
            @test p isa Plots.Plot
            labels = [s[:label] for s in p.series_list]
            @test "y_tot" in labels
            @test "cons" in labels
        end

        @testset "存在しない変数名でエラー（plot_result 委譲）" begin
            @test_throws ArgumentError plot_capex_series(sr3; vars = "not_a_var")
        end

        @testset "潜在変数のみを含む図が生成されない（受け入れ条件）" begin
            @test_throws ArgumentError plot_capex_series(sr3; vars = "cost_capital_s1")
            @test_throws ArgumentError plot_capex_series(
                sr3;
                vars = ["ai_exp", "target_cap_s1", "cancel_s1"],
            )
            @test_throws ArgumentError plot_capex_series(sr3; vars = "cancel_s1")
        end

        @testset "潜在変数と観測可能変数の併記は抑止しない" begin
            p = plot_capex_series(sr3; vars = ["ai_exp", "y_tot"])
            @test p isa Plots.Plot
        end

        @testset "observability メタデータが無い SimulationResult は検査をスキップする" begin
            sr_no_obs = SimulationResult(
                "dummy",
                "dummy",
                Dict{String, Vector{Float64}}("x" => [1.0, 2.0]),
            )
            p = plot_capex_series(sr_no_obs; vars = "x")
            @test p isa Plots.Plot
        end
    end

    @testset "plot_capex_sector_series" begin
        @testset "既定（5概念すべて）" begin
            plots = plot_capex_sector_series(sr3; combine = false)
            @test plots isa Vector
            @test length(plots) == 5
            @test all(p -> p isa Plots.Plot, plots)
        end

        @testset "combine=true で結合される" begin
            p = plot_capex_sector_series(sr3)
            @test p isa Plots.Plot
            @test length(p.subplots) >= 5
        end

        @testset "concepts でサブセット指定" begin
            plots =
                plot_capex_sector_series(sr3; concepts = [:orders, :debt], combine = false)
            @test length(plots) == 2
        end

        @testset "各パネルが該当部門系列を重ねている" begin
            plots = plot_capex_sector_series(sr3; combine = false)
            orders_labels = [s[:label] for s in plots[1].series_list]
            @test "S2" in orders_labels
            @test "S3" in orders_labels
            debt_labels = [s[:label] for s in plots[5].series_list]
            @test "S1" in debt_labels
            @test "S2" in debt_labels
            @test "S3" in debt_labels
        end

        @testset "未知の concept でエラー" begin
            @test_throws ArgumentError plot_capex_sector_series(
                sr3;
                concepts = [:not_a_concept],
            )
        end

        @testset "title カスタマイズ" begin
            p = plot_capex_sector_series(sr3; title = "カスタムタイトル")
            @test p[:plot_title] == "カスタムタイトル"
        end
    end

    @testset "plot_capex_scenario_comparison" begin
        @testset "既定（dY・dI・dC の3指標）" begin
            plots = plot_capex_scenario_comparison(m, [run0, run3]; combine = false)
            @test plots isa Vector
            @test length(plots) == 3
        end

        @testset "各パネルにシナリオ名がラベルとして現れる" begin
            plots = plot_capex_scenario_comparison(m, [run0, run3]; combine = false)
            labels = [s[:label] for s in plots[1].series_list]
            @test "Sc0" in labels
            @test "Sc3" in labels
        end

        @testset "labels でシナリオ名を上書きできる" begin
            plots = plot_capex_scenario_comparison(
                m,
                [run0, run3];
                labels = ["baseline", "credit shock"],
                combine = false,
            )
            labels = [s[:label] for s in plots[1].series_list]
            @test "baseline" in labels
            @test "credit shock" in labels
        end

        @testset "combine=true で結合される" begin
            p = plot_capex_scenario_comparison(m, [run0, run3])
            @test p isa Plots.Plot
            @test length(p.subplots) >= 3
        end

        @testset "vars でサブセット指定" begin
            plots = plot_capex_scenario_comparison(
                m,
                [run0, run3];
                vars = [:dY],
                combine = false,
            )
            @test length(plots) == 1
        end

        @testset "runs が空でエラー" begin
            @test_throws ArgumentError plot_capex_scenario_comparison(
                m,
                DME.CapexCreditCycleRun[],
            )
        end

        @testset "未知の var でエラー" begin
            @test_throws ArgumentError plot_capex_scenario_comparison(
                m,
                [run0, run3];
                vars = [:not_a_var],
            )
        end

        @testset "labels の長さ不一致でエラー" begin
            @test_throws ArgumentError plot_capex_scenario_comparison(
                m,
                [run0, run3];
                labels = ["only_one"],
            )
        end

        @testset "title カスタマイズ" begin
            p = plot_capex_scenario_comparison(m, [run0, run3]; title = "比較タイトル")
            @test p[:plot_title] == "比較タイトル"
        end
    end

    @testset "plot_capex_diagnostic_label" begin
        @testset "基本描画" begin
            p = plot_capex_diagnostic_label(diag3, run3)
            @test p isa Plots.Plot
        end

        @testset "凡例にラベルが含まれる" begin
            p = plot_capex_diagnostic_label(diag3, run3)
            labels = [s[:label] for s in p.series_list]
            @test String(diag3.label) in labels
        end

        @testset "met な群のみ帯として現れる" begin
            p = plot_capex_diagnostic_label(diag3, run3)
            n_group_bands =
                count(l -> occursin("breach", l), [s[:label] for s in p.series_list])
            n_met = count(g -> diag3.group_status[g].met, (:G1, :G2, :G3, :G4))
            @test n_group_bands == n_met
        end

        @testset "評価期間が無い run でエラー" begin
            runup_only = DME.CapexCreditCycleRun(
                run3.model_name,
                run3.scenario,
                run3.series,
                run3.exog,
                fill(-1, length(run3.periods)),
                run3.state0,
                run3.warnings,
                run3.termination_reason,
                run3.termination_period,
                run3.divergence_time,
                run3.binding,
                run3.accounting,
                run3.diagnostics,
                run3.options,
                run3.metadata,
            )
            @test_throws ArgumentError plot_capex_diagnostic_label(diag3, runup_only)
        end

        @testset "title カスタマイズ" begin
            p = plot_capex_diagnostic_label(diag3, run3; title = "カスタムタイトル")
            @test p.subplots[1][:title] == "カスタムタイトル"
        end
    end

    @testset "plot_capex_funding_pressure" begin
        @testset "既定（S1-S3の3部門）" begin
            plots = plot_capex_funding_pressure(diag3, run3; combine = false)
            @test plots isa Vector
            @test length(plots) == 3
            @test all(p -> p isa Plots.Plot, plots)
        end

        @testset "combine=true で結合される" begin
            p = plot_capex_funding_pressure(diag3, run3)
            @test p isa Plots.Plot
            @test length(p.subplots) >= 3
        end

        @testset "凡例に funding_pressure ラベルが含まれ Keen のラベルは含まれない" begin
            plots = plot_capex_funding_pressure(diag3, run3; combine = false)
            all_labels = String[]
            for p in plots
                append!(all_labels, [s[:label] for s in p.series_list])
            end
            @test any(l -> startswith(l, "fp_"), all_labels)
            @test !("hedge" in all_labels)
            @test !("speculative" in all_labels)
            @test !("ponzi" in all_labels)
        end

        @testset "sectors でサブセット指定" begin
            plots =
                plot_capex_funding_pressure(diag3, run3; sectors = [:s1], combine = false)
            @test length(plots) == 1
        end

        @testset "未知の sector でエラー" begin
            @test_throws ArgumentError plot_capex_funding_pressure(
                diag3,
                run3;
                sectors = [:s9],
            )
        end

        @testset "title カスタマイズ" begin
            p = plot_capex_funding_pressure(diag3, run3; title = "カスタムタイトル")
            @test p[:plot_title] == "カスタムタイトル"
        end
    end

    @testset "headless CI でのプロット保存" begin
        mktempdir() do dir
            p_sector = plot_capex_sector_series(sr3)
            p_cmp = plot_capex_scenario_comparison(m, [run0, run3])
            p_label = plot_capex_diagnostic_label(diag3, run3)
            p_fp = plot_capex_funding_pressure(diag3, run3)
            savefig(p_sector, joinpath(dir, "sector.png"))
            savefig(p_cmp, joinpath(dir, "comparison.png"))
            savefig(p_label, joinpath(dir, "label.png"))
            savefig(p_fp, joinpath(dir, "funding_pressure.png"))
            @test isfile(joinpath(dir, "sector.png"))
            @test isfile(joinpath(dir, "comparison.png"))
            @test isfile(joinpath(dir, "label.png"))
            @test isfile(joinpath(dir, "funding_pressure.png"))
        end
    end
end
