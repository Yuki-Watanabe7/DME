@testset "DataSeries" begin
    dates = ["2020-Q1", "2020-Q2", "2020-Q3", "2020-Q4"]
    vals  = [19254.0, 17302.0, 18638.0, 18878.0]

    s = DataSeries(
        id        = "FRED_GDPC1",
        name      = "Real GDP",
        source    = "FRED",
        frequency = Quarterly,
        unit      = "Billions of Chained 2017 Dollars",
        dates     = dates,
        values    = vals,
    )

    @testset "基本フィールド" begin
        @test s.id        == "FRED_GDPC1"
        @test s.name      == "Real GDP"
        @test s.source    == "FRED"
        @test s.frequency == Quarterly
        @test s.unit      == "Billions of Chained 2017 Dollars"
        @test s.metadata  == Dict{String,Any}()
    end

    @testset "長さ・取得・存在確認" begin
        @test length(s) == 4
        @test s["2020-Q1"] == 19254.0
        @test s["2020-Q3"] == 18638.0
        @test haskey(s, "2020-Q1")
        @test !haskey(s, "2021-Q1")
        @test_throws KeyError s["9999-Q1"]
    end

    @testset "欠損値" begin
        vals_m = Union{Float64,Missing}[100.0, missing, 120.0]
        sm = DataSeries(
            id        = "TEST_M",
            name      = "With Missing",
            source    = "test",
            frequency = Annual,
            unit      = "index",
            dates     = ["2020", "2021", "2022"],
            values    = vals_m,
        )
        @test missing_count(sm) == 1
        @test nonmissing_values(sm) == [100.0, 120.0]
    end

    @testset "dates/values 長さ不一致でエラー" begin
        @test_throws ArgumentError DataSeries(
            id        = "BAD",
            name      = "bad",
            source    = "test",
            frequency = Monthly,
            unit      = "unit",
            dates     = ["2020-01"],
            values    = [1.0, 2.0],
        )
    end

    @testset "metadata キーワード引数" begin
        s2 = DataSeries(
            id        = "T",
            name      = "Test",
            source    = "src",
            frequency = Annual,
            unit      = "unit",
            dates     = ["2020"],
            values    = [1.0],
            metadata  = Dict{String,Any}("seasonal_adjustment" => "SA"),
        )
        @test s2.metadata["seasonal_adjustment"] == "SA"
    end
end

@testset "MacroDataset" begin
    s1 = DataSeries(
        id        = "GDP",
        name      = "Real GDP",
        source    = "FRED",
        frequency = Quarterly,
        unit      = "Billions USD",
        dates     = ["2020-Q1", "2020-Q2"],
        values    = [100.0, 90.0],
    )
    s2 = DataSeries(
        id        = "CPI",
        name      = "CPI",
        source    = "BLS",
        frequency = Monthly,
        unit      = "index",
        dates     = ["2020-01", "2020-02"],
        values    = [260.0, 261.0],
    )

    @testset "空データセットの作成" begin
        ds = MacroDataset("Empty")
        @test ds.name == "Empty"
        @test length(ds) == 0
        @test series_ids(ds) == String[]
    end

    @testset "ベクタから作成" begin
        ds = MacroDataset("Test", [s1, s2])
        @test length(ds) == 2
        @test haskey(ds, "GDP")
        @test haskey(ds, "CPI")
        @test !haskey(ds, "UNKNOWN")
    end

    @testset "push! と get_series" begin
        ds = MacroDataset("Test")
        push!(ds, s1)
        push!(ds, s2)
        @test length(ds) == 2

        gdp = get_series(ds, "GDP")
        @test gdp.name == "Real GDP"
        @test gdp["2020-Q1"] == 100.0

        @test_throws KeyError get_series(ds, "UNKNOWN")
    end

    @testset "series_ids" begin
        ds = MacroDataset("Test", [s1, s2])
        ids = sort(series_ids(ds))
        @test ids == ["CPI", "GDP"]
    end

    @testset "同一 id の上書き" begin
        ds = MacroDataset("Test")
        push!(ds, s1)
        s1b = DataSeries(
            id        = "GDP",
            name      = "GDP v2",
            source    = "FRED",
            frequency = Quarterly,
            unit      = "Billions USD",
            dates     = ["2020-Q1"],
            values    = [99.0],
        )
        push!(ds, s1b)
        @test length(ds) == 1
        @test get_series(ds, "GDP").name == "GDP v2"
    end
end

@testset "DataFrequency" begin
    @test Annual    isa DataFrequency
    @test Quarterly isa DataFrequency
    @test Monthly   isa DataFrequency
    @test Annual != Quarterly
    @test Quarterly != Monthly
end
