@testset "EStatClient" begin
    fixture_dir = joinpath(@__DIR__, "fixtures")

    @testset "デフォルト構築（fixture モード）" begin
        withenv("ESTAT_APP_ID" => nothing, "DME_DATA_MODE" => nothing) do
            c = EStatClient(; fixture_dir = fixture_dir)
            @test c.mode == :fixture
            @test c.app_id === nothing
        end
    end

    @testset "appId があれば live モード" begin
        withenv("ESTAT_APP_ID" => "dummy_appid", "DME_DATA_MODE" => nothing) do
            c = EStatClient(; fixture_dir = fixture_dir)
            @test c.mode == :live
            @test c.app_id == "dummy_appid"
        end
    end

    @testset "DME_DATA_MODE=fixture が優先される" begin
        withenv("ESTAT_APP_ID" => "dummy_appid", "DME_DATA_MODE" => "fixture") do
            c = EStatClient(; fixture_dir = fixture_dir)
            @test c.mode == :fixture
        end
    end

    @testset "mode キーワードが環境変数より優先" begin
        withenv("ESTAT_APP_ID" => "dummy_appid", "DME_DATA_MODE" => "live") do
            c = EStatClient(; mode = :fixture, fixture_dir = fixture_dir)
            @test c.mode == :fixture
        end
    end

    @testset "app_id キーワードが環境変数より優先" begin
        withenv("ESTAT_APP_ID" => "env_appid") do
            c = EStatClient(; app_id = "direct_appid", fixture_dir = fixture_dir)
            @test c.app_id == "direct_appid"
        end
    end

    @testset ":rest_api モード（DME_DATA_MODE=rest_api）" begin
        withenv("ESTAT_APP_ID" => nothing, "DME_DATA_MODE" => "rest_api",
                "DATA_PROVIDER_BASE_URL" => "http://localhost:8000") do
            c = EStatClient(; fixture_dir = fixture_dir)
            @test c.mode == :rest_api
            @test c.rest_api_url == "http://localhost:8000"
        end
    end

    @testset ":rest_api モード（mode キーワード）" begin
        withenv("ESTAT_APP_ID" => nothing, "DME_DATA_MODE" => nothing,
                "DATA_PROVIDER_BASE_URL" => nothing) do
            c = EStatClient(; mode = :rest_api, rest_api_url = "http://test-server:9000",
                            fixture_dir = fixture_dir)
            @test c.mode == :rest_api
            @test c.rest_api_url == "http://test-server:9000"
        end
    end

    @testset "DATA_PROVIDER_BASE_URL デフォルト値" begin
        withenv("DATA_PROVIDER_BASE_URL" => nothing) do
            c = EStatClient(; mode = :rest_api, fixture_dir = fixture_dir)
            @test c.rest_api_url == "http://localhost:8000"
        end
    end
end

@testset "fetch_estat_series（fixture モード）" begin
    fixture_dir = joinpath(@__DIR__, "fixtures")
    client = EStatClient(; mode = :fixture, fixture_dir = fixture_dir)

    @testset "CPI（月次）" begin
        cpi = fetch_estat_series("0003427113"; client = client)

        @test cpi.id        == "ESTAT_0003427113"
        @test cpi.source    == "e-Stat"
        @test cpi.frequency == Monthly
        @test cpi.unit      == "2020年=100"
        @test length(cpi)   == 12
        @test cpi["2020-01"] ≈ 101.2
        @test cpi["2020-04"] ≈ 100.7
        @test cpi["2020-12"] ≈ 99.9
        @test haskey(cpi, "2020-01")
        @test !haskey(cpi, "2021-01")
    end

    @testset "完全失業率・労働力調査（月次）" begin
        ur = fetch_estat_series("0003307059"; client = client)

        @test ur.id        == "ESTAT_0003307059"
        @test ur.source    == "e-Stat"
        @test ur.frequency == Monthly
        @test ur.unit      == "%"
        @test length(ur)   == 12
        @test ur["2020-01"] ≈ 2.4
        @test ur["2020-05"] ≈ 2.9
        @test ur["2020-10"] ≈ 3.1
    end

    @testset "消費支出・家計調査（月次）" begin
        exp = fetch_estat_series("0003343671"; client = client)

        @test exp.id        == "ESTAT_0003343671"
        @test exp.frequency == Monthly
        @test exp.unit      == "円"
        @test length(exp)   == 12
        @test exp["2020-01"] ≈ 292453.0
        @test exp["2020-04"] ≈ 239564.0
        @test exp["2020-12"] ≈ 325678.0
    end

    @testset "総人口・人口推計（年次）" begin
        pop = fetch_estat_series("0003445078"; client = client)

        @test pop.id        == "ESTAT_0003445078"
        @test pop.frequency == Annual
        @test pop.unit      == "千人"
        @test length(pop)   == 6
        @test pop["2020"] ≈ 125708.0
        @test pop["2015"] ≈ 127095.0
        @test haskey(pop, "2019")
        @test !haskey(pop, "2021")
    end

    @testset "月次日付ラベル変換" begin
        cpi = fetch_estat_series("0003427113"; client = client)
        dates = cpi.dates
        @test "2020-01" in dates
        @test "2020-06" in dates
        @test "2020-12" in dates
        @test !("2020-00" in dates)
    end

    @testset "年次日付ラベル変換" begin
        pop = fetch_estat_series("0003445078"; client = client)
        dates = pop.dates
        @test "2015" in dates
        @test "2020" in dates
    end

    @testset "series_id / series_name の上書き" begin
        cpi = fetch_estat_series(
            "0003427113";
            client      = client,
            series_id   = "MY_CPI",
            series_name = "日本CPI",
        )
        @test cpi.id   == "MY_CPI"
        @test cpi.name == "日本CPI"
    end
end

@testset "fetch_estat_dataset（fixture モード）" begin
    fixture_dir = joinpath(@__DIR__, "fixtures")
    client = EStatClient(; mode = :fixture, fixture_dir = fixture_dir)

    ids = ["0003427113", "0003307059", "0003343671", "0003445078"]
    ds = fetch_estat_dataset(ids; client = client, name = "Japan Macro 2020")

    @test ds.name   == "Japan Macro 2020"
    @test length(ds) == 4
    @test haskey(ds, "ESTAT_0003427113")
    @test haskey(ds, "ESTAT_0003307059")
    @test haskey(ds, "ESTAT_0003343671")
    @test haskey(ds, "ESTAT_0003445078")

    cpi = get_series(ds, "ESTAT_0003427113")
    @test cpi["2020-01"] ≈ 101.2

    @test sort(series_ids(ds)) == sort([
        "ESTAT_0003427113", "ESTAT_0003307059",
        "ESTAT_0003343671", "ESTAT_0003445078",
    ])
end

@testset "エラーハンドリング" begin
    fixture_dir = joinpath(@__DIR__, "fixtures")

    @testset "live モードで appId 未設定" begin
        withenv("ESTAT_APP_ID" => nothing) do
            client = EStatClient(; mode = :live, fixture_dir = fixture_dir)
            @test_throws ErrorException fetch_estat_series("0003427113"; client = client)
        end
    end

    @testset "fixture が存在しない統計表 ID" begin
        client = EStatClient(; mode = :fixture, fixture_dir = fixture_dir)
        @test_throws ErrorException fetch_estat_series("9999999999"; client = client)
    end
end

@testset "欠損値のパース" begin
    fixture_dir = joinpath(@__DIR__, "fixtures")

    missing_json = """
    {
      "GET_STATS_DATA": {
        "RESULT": {"STATUS": 0, "ERROR_MSG": "正常に終了しました。"},
        "STATISTICAL_DATA": {
          "TABLE_INF": {
            "STATISTICS_NAME": "テスト統計",
            "TITLE": {"\$": "テスト系列"},
            "CYCLE": "月次",
            "UNIT": "%"
          },
          "CLASS_INF": {
            "CLASS_OBJ": {
              "@id": "time",
              "@name": "時間軸(月次)",
              "CLASS": [
                {"@code": "2020010101", "@name": "2020年1月"},
                {"@code": "2020020101", "@name": "2020年2月"},
                {"@code": "2020030101", "@name": "2020年3月"}
              ]
            }
          },
          "DATA_INF": {
            "VALUE": [
              {"@time": "2020010101", "@unit": "%", "\$": "1.5"},
              {"@time": "2020020101", "@unit": "%", "\$": "-"},
              {"@time": "2020030101", "@unit": "%", "\$": "2.0"}
            ]
          }
        }
      }
    }
    """

    s = DME._parse_estat_json(missing_json, "TEST_MISSING")
    @test length(s)        == 3
    @test missing_count(s) == 1
    @test s["2020-01"]     == 1.5
    @test s["2020-03"]     == 2.0
    @test ismissing(s["2020-02"])
end

@testset "_estat_code_to_label" begin
    @testset "月次 YYYYMM0101 形式" begin
        @test DME._estat_code_to_label("2020010101", Monthly) == "2020-01"
        @test DME._estat_code_to_label("2020060101", Monthly) == "2020-06"
        @test DME._estat_code_to_label("2020120101", Monthly) == "2020-12"
    end

    @testset "月次 YYYY00MMDD 形式（代替フォーマット）" begin
        @test DME._estat_code_to_label("2020000101", Monthly) == "2020-01"
        @test DME._estat_code_to_label("2020001201", Monthly) == "2020-12"
    end

    @testset "年次" begin
        @test DME._estat_code_to_label("2020000000", Annual) == "2020"
        @test DME._estat_code_to_label("2015000000", Annual) == "2015"
    end

    @testset "四半期" begin
        @test DME._estat_code_to_label("2020010101", Quarterly) == "2020-Q1"
        @test DME._estat_code_to_label("2020040101", Quarterly) == "2020-Q2"
        @test DME._estat_code_to_label("2020070101", Quarterly) == "2020-Q3"
        @test DME._estat_code_to_label("2020100101", Quarterly) == "2020-Q4"
    end
end
