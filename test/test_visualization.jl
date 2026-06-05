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
