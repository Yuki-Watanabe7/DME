@testset "FredClient" begin
    fixture_dir = joinpath(@__DIR__, "fixtures")

    @testset "デフォルト構築（fixture モード）" begin
        withenv("FRED_API_KEY" => nothing, "DME_DATA_MODE" => nothing) do
            c = FredClient(; fixture_dir=fixture_dir)
            @test c.mode == :fixture
            @test c.api_key === nothing
        end
    end

    @testset "API キーがあれば live モード" begin
        withenv("FRED_API_KEY" => "dummy_key", "DME_DATA_MODE" => nothing) do
            c = FredClient(; fixture_dir=fixture_dir)
            @test c.mode == :live
            @test c.api_key == "dummy_key"
        end
    end

    @testset "DME_DATA_MODE=fixture が優先される" begin
        withenv("FRED_API_KEY" => "dummy_key", "DME_DATA_MODE" => "fixture") do
            c = FredClient(; fixture_dir=fixture_dir)
            @test c.mode == :fixture
        end
    end

    @testset "mode キーワードが環境変数より優先" begin
        withenv("FRED_API_KEY" => "dummy_key", "DME_DATA_MODE" => "live") do
            c = FredClient(; mode=:fixture, fixture_dir=fixture_dir)
            @test c.mode == :fixture
        end
    end

    @testset "api_key キーワードが環境変数より優先" begin
        withenv("FRED_API_KEY" => "env_key") do
            c = FredClient(; api_key="direct_key", fixture_dir=fixture_dir)
            @test c.api_key == "direct_key"
        end
    end

    @testset ":rest_api モード（DME_DATA_MODE=rest_api）" begin
        withenv("FRED_API_KEY" => nothing, "DME_DATA_MODE" => "rest_api",
                "DATA_PROVIDER_BASE_URL" => "http://localhost:8000") do
            c = FredClient(; fixture_dir=fixture_dir)
            @test c.mode == :rest_api
            @test c.rest_api_url == "http://localhost:8000"
        end
    end

    @testset ":rest_api モード（mode キーワード）" begin
        withenv("FRED_API_KEY" => nothing, "DME_DATA_MODE" => nothing,
                "DATA_PROVIDER_BASE_URL" => nothing) do
            c = FredClient(; mode=:rest_api, rest_api_url="http://test-server:9000",
                           fixture_dir=fixture_dir)
            @test c.mode == :rest_api
            @test c.rest_api_url == "http://test-server:9000"
        end
    end

    @testset "DATA_PROVIDER_BASE_URL デフォルト値" begin
        withenv("DATA_PROVIDER_BASE_URL" => nothing) do
            c = FredClient(; mode=:rest_api, fixture_dir=fixture_dir)
            @test c.rest_api_url == "http://localhost:8000"
        end
    end
end

@testset "fetch_fred_series（fixture モード）" begin
    fixture_dir = joinpath(@__DIR__, "fixtures")
    client = FredClient(; mode=:fixture, fixture_dir=fixture_dir)

    @testset "GDPC1（実質 GDP・四半期）" begin
        gdp = fetch_fred_series("GDPC1"; client=client)

        @test gdp.id       == "FRED_GDPC1"
        @test gdp.source   == "FRED"
        @test gdp.frequency == Quarterly
        @test gdp.unit     == "Billions of Chained 2017 Dollars"
        @test length(gdp)  == 12
        @test gdp["2020-Q1"] == 19254.0
        @test gdp["2020-Q2"] == 17302.0
        @test haskey(gdp, "2018-Q1")
        @test !haskey(gdp, "2021-Q1")
        @test gdp.metadata["seasonal_adjustment"] == "Seasonally Adjusted Annual Rate"
    end

    @testset "CPIAUCSL（CPI・月次）" begin
        cpi = fetch_fred_series("CPIAUCSL"; client=client)

        @test cpi.id       == "FRED_CPIAUCSL"
        @test cpi.frequency == Monthly
        @test length(cpi)  == 12
        @test cpi["2020-01"] ≈ 258.678
        @test cpi["2020-04"] ≈ 256.143
    end

    @testset "UNRATE（失業率・月次）" begin
        ur = fetch_fred_series("UNRATE"; client=client)

        @test ur.id       == "FRED_UNRATE"
        @test ur.frequency == Monthly
        @test ur.unit     == "Percent"
        @test length(ur)  == 12
        @test ur["2020-04"] ≈ 14.7
        @test ur["2020-01"] ≈ 3.5
    end

    @testset "FEDFUNDS（FFR・月次）" begin
        ff = fetch_fred_series("FEDFUNDS"; client=client)

        @test ff.id       == "FRED_FEDFUNDS"
        @test ff.frequency == Monthly
        @test ff["2020-01"] ≈ 1.55
        @test ff["2020-04"] ≈ 0.05
    end

    @testset "GS10（10 年国債利回り・月次）" begin
        gs10 = fetch_fred_series("GS10"; client=client)

        @test gs10.id       == "FRED_GS10"
        @test gs10.frequency == Monthly
        @test gs10["2020-01"] ≈ 1.76
        @test gs10["2020-03"] ≈ 0.87
    end

    @testset "quarterly 日付ラベル変換（四半期）" begin
        gdp = fetch_fred_series("GDPC1"; client=client)
        dates = gdp.dates
        @test "2018-Q1" in dates
        @test "2018-Q2" in dates
        @test "2018-Q3" in dates
        @test "2018-Q4" in dates
        @test "2020-Q4" in dates
    end

    @testset "monthly 日付ラベル変換（月次）" begin
        cpi = fetch_fred_series("CPIAUCSL"; client=client)
        @test "2020-01" in cpi.dates
        @test "2020-12" in cpi.dates
    end
end

@testset "fetch_fred_dataset（fixture モード）" begin
    fixture_dir = joinpath(@__DIR__, "fixtures")
    client = FredClient(; mode=:fixture, fixture_dir=fixture_dir)

    ids = ["GDPC1", "CPIAUCSL", "UNRATE", "FEDFUNDS", "GS10"]
    ds = fetch_fred_dataset(ids; client=client, name="US Macro 2020")

    @test ds.name   == "US Macro 2020"
    @test length(ds) == 5
    @test haskey(ds, "FRED_GDPC1")
    @test haskey(ds, "FRED_CPIAUCSL")
    @test haskey(ds, "FRED_UNRATE")
    @test haskey(ds, "FRED_FEDFUNDS")
    @test haskey(ds, "FRED_GS10")

    gdp = get_series(ds, "FRED_GDPC1")
    @test gdp["2020-Q1"] == 19254.0

    @test sort(series_ids(ds)) == sort(["FRED_GDPC1", "FRED_CPIAUCSL", "FRED_UNRATE", "FRED_FEDFUNDS", "FRED_GS10"])
end

@testset "エラーハンドリング" begin
    fixture_dir = joinpath(@__DIR__, "fixtures")

    @testset "live モードで API キー未設定" begin
        withenv("FRED_API_KEY" => nothing) do
            client = FredClient(; mode=:live, fixture_dir=fixture_dir)
            @test_throws ErrorException fetch_fred_series("GDPC1"; client=client)
        end
    end

    @testset "fixture が存在しない系列" begin
        client = FredClient(; mode=:fixture, fixture_dir=fixture_dir)
        @test_throws ErrorException fetch_fred_series("NONEXISTENT_SERIES"; client=client)
    end
end

@testset "欠損値のパース" begin
    fixture_dir = joinpath(@__DIR__, "fixtures")

    missing_json = """
    {
      "series": {
        "id": "TEST_MISSING",
        "title": "Test Series With Missing",
        "frequency": "Monthly",
        "units": "Percent",
        "seasonal_adjustment": "Not Seasonally Adjusted"
      },
      "observations": [
        {"date": "2020-01-01", "value": "1.5"},
        {"date": "2020-02-01", "value": "."},
        {"date": "2020-03-01", "value": "2.0"}
      ]
    }
    """

    s = DME._parse_fred_json(missing_json)
    @test length(s)       == 3
    @test missing_count(s) == 1
    @test s["2020-01"]    == 1.5
    @test s["2020-03"]    == 2.0
    @test ismissing(s["2020-02"])
end
