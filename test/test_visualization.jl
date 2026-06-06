# GR バックエンドをヘッドレスモードで動作させる（CI / 無表示環境対応）
ENV["GKSwstype"] = "nul"
using Plots

@testset "Visualization" begin
    vars_dict =
        Dict{String,Vector{Float64}}("K" => [1.0, 1.1, 1.2], "C" => [0.5, 0.55, 0.6])
    sr = SimulationResult("TestModel", "test_scenario", vars_dict)

    @testset "vars省略で全変数プロット" begin
        p = plot_result(sr)
        @test p isa Plots.Plot
    end

    @testset "単一変数（String）" begin
        p = plot_result(sr; vars = "K")
        @test p isa Plots.Plot
    end

    @testset "単一変数（Symbol）" begin
        p = plot_result(sr; vars = :C)
        @test p isa Plots.Plot
    end

    @testset "複数変数（String 配列）" begin
        p = plot_result(sr; vars = ["K", "C"])
        @test p isa Plots.Plot
    end

    @testset "複数変数（Symbol 配列）" begin
        p = plot_result(sr; vars = [:K, :C])
        @test p isa Plots.Plot
    end

    @testset "title / xlabel / ylabel オプション" begin
        p = plot_result(sr; vars = "K", title = "テスト", xlabel = "t", ylabel = "K")
        @test p isa Plots.Plot
    end

    @testset "存在しない変数でエラー" begin
        @test_throws ArgumentError plot_result(sr; vars = "Z")
    end

    @testset "エラーメッセージに利用可能変数名が含まれる" begin
        ex = try
            plot_result(sr; vars = ["K", "X", "Z"])
            nothing
        catch e
            e
        end
        @test ex isa ArgumentError
        @test occursin("X", ex.msg)
        @test occursin("Z", ex.msg)
        # K と C は利用可能変数のリストとしてメッセージに含まれる
        @test occursin("K", ex.msg) || occursin("C", ex.msg)
    end

    @testset "Ramseyモデルの出力でプロット" begin
        m = RamseyModel(0.3, 0.99, 0.25)
        ep = DME.calc_ep(m)
        raw = DME.find_path(m, ep[1] / 2)
        result = to_simulation_result(m, raw, "find_path")
        p = plot_result(result; vars = ["K", "C"])
        @test p isa Plots.Plot
    end

    @testset "RBCモデルの出力でプロット" begin
        m = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)
        raw = DME.shock(m, 0.01)
        result = to_simulation_result(m, raw, "shock")
        p = plot_result(result)
        @test p isa Plots.Plot
    end
end

@testset "plot_comparison" begin
    vars_a = Dict{String,Vector{Float64}}("K" => [1.0, 1.1, 1.2], "C" => [0.5, 0.55, 0.6])
    vars_b = Dict{String,Vector{Float64}}("K" => [0.8, 0.9, 1.0], "C" => [0.4, 0.45, 0.5])
    sr_a = SimulationResult("TestModel", "scenario_a", vars_a)
    sr_b = SimulationResult("TestModel", "scenario_b", vars_b)

    @testset "基本比較プロット（String 変数名）" begin
        p = plot_comparison([sr_a, sr_b]; var = "K")
        @test p isa Plots.Plot
    end

    @testset "基本比較プロット（Symbol 変数名）" begin
        p = plot_comparison([sr_a, sr_b]; var = :K)
        @test p isa Plots.Plot
    end

    @testset "labels 指定で凡例上書き" begin
        p = plot_comparison([sr_a, sr_b]; var = "K", labels = ["シナリオA", "シナリオB"])
        @test p isa Plots.Plot
    end

    @testset "title / xlabel / ylabel オプション" begin
        p = plot_comparison([sr_a, sr_b]; var = "K",
                            title = "K の比較", xlabel = "t", ylabel = "資本")
        @test p isa Plots.Plot
    end

    @testset "期間長が異なる場合に :truncate で正常動作" begin
        vars_short = Dict{String,Vector{Float64}}("K" => [1.0, 1.1])
        sr_short = SimulationResult("TestModel", "short", vars_short)
        p = plot_comparison([sr_a, sr_short]; var = "K", on_length_mismatch = :truncate)
        @test p isa Plots.Plot
    end

    @testset "期間長が異なる場合に :error でエラー" begin
        vars_short = Dict{String,Vector{Float64}}("K" => [1.0, 1.1])
        sr_short = SimulationResult("TestModel", "short", vars_short)
        @test_throws ArgumentError plot_comparison([sr_a, sr_short]; var = "K",
                                                   on_length_mismatch = :error)
    end

    @testset "存在しない変数でエラー" begin
        @test_throws ArgumentError plot_comparison([sr_a, sr_b]; var = "Z")
    end

    @testset "エラーメッセージに変数名と利用可能変数が含まれる" begin
        ex = try
            plot_comparison([sr_a, sr_b]; var = "Z")
            nothing
        catch e
            e
        end
        @test ex isa ArgumentError
        @test occursin("Z", ex.msg)
        @test occursin("K", ex.msg) || occursin("C", ex.msg)
    end

    @testset "results が空でエラー" begin
        @test_throws ArgumentError plot_comparison(SimulationResult[]; var = "K")
    end

    @testset "labels の長さ不一致でエラー" begin
        @test_throws ArgumentError plot_comparison([sr_a, sr_b]; var = "K",
                                                   labels = ["one"])
    end

    @testset "New Keynesian モデル: 需要ショック vs 金融政策ショック比較" begin
        m = NewKeynesianModel(1.0, 0.02, 0.99, 0.1, 1.5, 0.5, 0.02, 0.8, 0.5, 0.5)
        irf_demand   = impulse_response(m; shock = :demand,   T = 10)
        irf_monetary = impulse_response(m; shock = :monetary, T = 10)
        sr_demand   = to_simulation_result(m, irf_demand,   "demand_shock")
        sr_monetary = to_simulation_result(m, irf_monetary, "monetary_shock")
        p = plot_comparison([sr_demand, sr_monetary]; var = "π",
                            labels = ["需要ショック", "金融政策ショック"],
                            title  = "インフレ率の比較")
        @test p isa Plots.Plot
    end
end
