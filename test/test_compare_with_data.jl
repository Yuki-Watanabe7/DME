@testset "compare_with_data" begin
    model_vars = Dict{String, Vector{Float64}}(
        "K" => [1.0, 1.1, 1.2, 1.3, 1.4],
        "C" => [0.5, 0.52, 0.54, 0.56, 0.58],
    )
    data_vars = Dict{String, Vector{Float64}}(
        "GDP" => [1.05, 1.12, 1.18, 1.28, 1.45],
        "CONS" => [0.48, 0.50, 0.52, 0.55, 0.60],
    )
    model_r = SimulationResult("TestModel", "simulation", model_vars)
    data_r  = SimulationResult("TestData", "actual_data", data_vars)
    mapping = Dict("K" => "GDP", "C" => "CONS")

    @testset "基本的な比較" begin
        cr = compare_with_data(model_r, data_r; mapping = mapping)
        @test cr isa ComparisonResult
        @test cr.model_name == "TestModel"
        @test cr.data_source == "TestData"
        @test cr.comparison_period == (1, 5)
        @test haskey(cr.variables, "K")
        @test haskey(cr.variables, "C")
    end

    @testset "変数別指標: 型と基本値" begin
        cr = compare_with_data(model_r, data_r; mapping = mapping)
        km = cr.variables["K"]

        @test km.model_variable == "K"
        @test km.data_variable == "GDP"
        @test km.n_periods == 5

        expected_ld = model_vars["K"] .- data_vars["GDP"]
        @test km.level_diff ≈ expected_ld

        @test km.rmse >= 0.0
        @test km.mae >= 0.0
        @test !isnan(km.correlation)
        @test -1.0 <= km.correlation <= 1.0
        @test !isnan(km.mean_level_diff)
        @test km.max_abs_level_diff >= 0.0
    end

    @testset "RMSE / MAE の手計算との一致" begin
        cr = compare_with_data(model_r, data_r; mapping = Dict("K" => "GDP"))
        km = cr.variables["K"]
        diff = model_vars["K"] .- data_vars["GDP"]
        expected_rmse = sqrt(sum(diff .^ 2) / 5)
        expected_mae  = sum(abs.(diff)) / 5
        @test km.rmse ≈ expected_rmse
        @test km.mae  ≈ expected_mae
    end

    @testset "pct_diff の計算" begin
        cr = compare_with_data(model_r, data_r; mapping = Dict("K" => "GDP"))
        km = cr.variables["K"]
        for i in 1:5
            expected = (model_vars["K"][i] - data_vars["GDP"][i]) / abs(data_vars["GDP"][i]) * 100.0
            @test km.pct_diff[i] ≈ expected
        end
    end

    @testset "期間不一致: 短い方に合わせる（モデルが短い）" begin
        short_m = SimulationResult("M", "s", Dict{String, Vector{Float64}}("K" => [1.0, 1.1, 1.2]))
        long_d  = SimulationResult("D", "a", Dict{String, Vector{Float64}}("GDP" => [1.0, 1.1, 1.2, 1.3, 1.4]))
        cr = compare_with_data(short_m, long_d; mapping = Dict("K" => "GDP"))
        @test cr.comparison_period == (1, 3)
        @test cr.variables["K"].n_periods == 3
    end

    @testset "期間不一致: 短い方に合わせる（データが短い）" begin
        long_m  = SimulationResult("M", "s", Dict{String, Vector{Float64}}("K" => [1.0, 1.1, 1.2, 1.3, 1.4]))
        short_d = SimulationResult("D", "a", Dict{String, Vector{Float64}}("GDP" => [1.0, 1.1]))
        cr = compare_with_data(long_m, short_d; mapping = Dict("K" => "GDP"))
        @test cr.comparison_period == (1, 2)
        @test cr.variables["K"].n_periods == 2
    end

    @testset "変数不在エラー: モデル側" begin
        @test_throws ArgumentError compare_with_data(model_r, data_r; mapping = Dict("Z" => "GDP"))
    end

    @testset "変数不在エラー: データ側" begin
        @test_throws ArgumentError compare_with_data(model_r, data_r; mapping = Dict("K" => "NOTEXIST"))
    end

    @testset "NaN含む系列: 有効ペアのみで指標計算" begin
        m_nan = SimulationResult("M", "s", Dict{String, Vector{Float64}}("K" => [1.0, NaN, 1.2, 1.3, 1.4]))
        cr = compare_with_data(m_nan, data_r; mapping = Dict("K" => "GDP"))
        km = cr.variables["K"]
        @test isnan(km.level_diff[2])
        @test isnan(km.pct_diff[2])
        # 有効な4ペアで計算されていること
        @test !isnan(km.rmse)
        @test !isnan(km.mae)
        @test !isnan(km.correlation)
    end

    @testset "全値NaN: 指標はNaN" begin
        m_all_nan = SimulationResult(
            "M", "s",
            Dict{String, Vector{Float64}}("K" => [NaN, NaN, NaN, NaN, NaN]),
        )
        cr = compare_with_data(m_all_nan, data_r; mapping = Dict("K" => "GDP"))
        km = cr.variables["K"]
        @test isnan(km.rmse)
        @test isnan(km.mae)
        @test isnan(km.correlation)
        @test isnan(km.mean_level_diff)
        @test isnan(km.max_abs_level_diff)
    end

    @testset "定数系列: correlation は NaN" begin
        m_const = SimulationResult("M", "s", Dict{String, Vector{Float64}}("K" => [1.0, 1.0, 1.0, 1.0, 1.0]))
        cr = compare_with_data(m_const, data_r; mapping = Dict("K" => "GDP"))
        @test isnan(cr.variables["K"].correlation)
    end

    @testset "mapping が copy されていること" begin
        m = copy(mapping)
        cr = compare_with_data(model_r, data_r; mapping = m)
        m["NEW"] = "X"
        @test !haskey(cr.mapping, "NEW")
    end
end

@testset "to_data_comparison_summary" begin
    model_vars = Dict{String, Vector{Float64}}(
        "K" => [1.0, 1.1, 1.2],
        "C" => [0.5, 0.52, 0.54],
    )
    data_vars = Dict{String, Vector{Float64}}(
        "GDP"  => [1.05, 1.12, 1.18],
        "CONS" => [0.48, 0.50, 0.52],
    )
    model_r = SimulationResult("TestModel", "sim", model_vars)
    data_r  = SimulationResult("TestData", "actual", data_vars)
    cr = compare_with_data(model_r, data_r; mapping = Dict("K" => "GDP", "C" => "CONS"))

    @testset "基本フィールド" begin
        dcs = to_data_comparison_summary(cr)
        @test dcs isa DataComparisonSummary
        @test dcs.data_source == "TestData"
        @test dcs.comparison_period == (1, 3)
        @test dcs.data_caveats == String[]
    end

    @testset "deviation_statistics の内容" begin
        dcs = to_data_comparison_summary(cr)
        @test haskey(dcs.deviation_statistics, "K")
        @test haskey(dcs.deviation_statistics, "C")
        ks = dcs.deviation_statistics["K"]
        @test ks["data_variable"] == "GDP"
        @test ks["rmse"] >= 0.0
        @test ks["mae"] >= 0.0
        @test haskey(ks, "correlation")
        @test haskey(ks, "mean_level_diff")
        @test haskey(ks, "max_abs_level_diff")
    end

    @testset "caveats 指定" begin
        dcs = to_data_comparison_summary(cr; caveats = ["対数偏差と水準値の比較"])
        @test dcs.data_caveats == ["対数偏差と水準値の比較"]
    end

    @testset "AnalysisContext への統合" begin
        rbc = RBCModel(0.3, 0.99, 1, 0.025, 1, 0.9)
        raw = DME.shock(rbc, 0.01)
        model_sr = to_simulation_result(rbc, raw, "technology_shock")

        n = nperiods(model_sr)
        dummy_data = SimulationResult(
            "DummyData", "actual",
            Dict{String, Vector{Float64}}("ŷ" => zeros(n)),
        )
        cr2  = compare_with_data(model_sr, dummy_data; mapping = Dict("ŷ" => "ŷ"))
        dcs2 = to_data_comparison_summary(cr2; caveats = ["ダミーデータとの比較"])

        ctx = AnalysisContext(rbc, model_sr; data_comparison_summary = dcs2)
        d   = to_dict(ctx)
        @test haskey(d, "data_comparison_summary")
        @test d["data_comparison_summary"]["data_source"] == "DummyData"
        @test haskey(d["data_comparison_summary"]["deviation_statistics"], "ŷ")
    end
end
