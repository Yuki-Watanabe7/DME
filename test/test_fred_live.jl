# FRED API live 統合テスト
#
# 実際の FRED API を使用するため、FRED_API_KEY が必要。
# CI では実行しない（runtests.jl には含まれない）。
#
# 実行方法:
#   julia --project=. test/test_fred_live.jl
#
# または .env を読み込んで実行:
#   set -a && source .env && set +a && julia --project=. test/test_fred_live.jl

using DME
using Test

# .env が存在し、かつ FRED_API_KEY が未設定の場合はロードする
let dotenv = joinpath(@__DIR__, "..", ".env")
    if isfile(dotenv) && !haskey(ENV, "FRED_API_KEY")
        for line in eachline(dotenv)
            line = strip(line)
            (isempty(line) || startswith(line, "#")) && continue
            m = match(r"^([A-Z_][A-Z0-9_]*)=(.*)$", line)
            m !== nothing && (ENV[m[1]] = m[2])
        end
    end
end

if !haskey(ENV, "FRED_API_KEY") || isempty(ENV["FRED_API_KEY"]) ||
        ENV["FRED_API_KEY"] == "your_fred_api_key_here"
    @info "FRED_API_KEY が未設定のため live テストをスキップします。"
    exit(0)
end

client = FredClient(mode=:live)
@info "live モードで FRED API テスト開始" base_url=client.base_url

@testset "FRED API live 統合テスト" begin

    @testset "GDPC1（実質 GDP・四半期）" begin
        gdp = fetch_fred_series("GDPC1"; client=client, start_date="2020-01-01", end_date="2021-12-31")

        @test gdp.id        == "FRED_GDPC1"
        @test gdp.source    == "FRED"
        @test gdp.frequency == Quarterly
        @test !isempty(gdp.unit)
        @test length(gdp)   >= 4           # 最低でも 2020 年分
        @test all(d -> occursin(r"^\d{4}-Q[1-4]$", d), gdp.dates)
        @test all(v -> !ismissing(v) && v > 0, gdp.values)
        @test haskey(gdp, "2020-Q1")
        @test haskey(gdp, "2021-Q4")
        @info "GDPC1" len=length(gdp) sample_date=gdp.dates[1] sample_val=gdp.values[1]
    end

    @testset "CPIAUCSL（CPI・月次）" begin
        cpi = fetch_fred_series("CPIAUCSL"; client=client, start_date="2020-01-01", end_date="2020-12-31")

        @test cpi.id        == "FRED_CPIAUCSL"
        @test cpi.frequency == Monthly
        @test length(cpi)   == 12
        @test all(d -> occursin(r"^\d{4}-\d{2}$", d), cpi.dates)
        @test cpi.dates[1]  == "2020-01"
        @test cpi.dates[end] == "2020-12"
        @test all(v -> !ismissing(v) && v > 0, cpi.values)
        @info "CPIAUCSL" len=length(cpi) sample_val=cpi["2020-01"]
    end

    @testset "UNRATE（失業率・月次）" begin
        ur = fetch_fred_series("UNRATE"; client=client, start_date="2020-01-01", end_date="2020-12-31")

        @test ur.id        == "FRED_UNRATE"
        @test ur.frequency == Monthly
        @test ur.unit      == "Percent"
        @test length(ur)   == 12
        @test all(v -> !ismissing(v) && 0 <= v <= 100, ur.values)
        @info "UNRATE" peak=maximum(skipmissing(ur.values))
    end

    @testset "FEDFUNDS（FFR・月次）" begin
        ff = fetch_fred_series("FEDFUNDS"; client=client, start_date="2020-01-01", end_date="2020-12-31")

        @test ff.id        == "FRED_FEDFUNDS"
        @test ff.frequency == Monthly
        @test length(ff)   == 12
        @test all(v -> !ismissing(v) && v >= 0, ff.values)
        @info "FEDFUNDS" min=minimum(skipmissing(ff.values)) max=maximum(skipmissing(ff.values))
    end

    @testset "GS10（10 年国債利回り・月次）" begin
        gs10 = fetch_fred_series("GS10"; client=client, start_date="2020-01-01", end_date="2020-12-31")

        @test gs10.id        == "FRED_GS10"
        @test gs10.frequency == Monthly
        @test length(gs10)   == 12
        @test all(v -> !ismissing(v) && v >= 0, gs10.values)
        @info "GS10" min=minimum(skipmissing(gs10.values)) max=maximum(skipmissing(gs10.values))
    end

    @testset "fetch_fred_dataset（複数系列一括取得）" begin
        ids = ["GDPC1", "CPIAUCSL", "UNRATE"]
        ds = fetch_fred_dataset(
            ids;
            client=client,
            start_date="2020-01-01",
            end_date="2020-12-31",
            name="Live Test Dataset",
        )

        @test ds.name    == "Live Test Dataset"
        @test length(ds) == 3
        @test haskey(ds, "FRED_GDPC1")
        @test haskey(ds, "FRED_CPIAUCSL")
        @test haskey(ds, "FRED_UNRATE")

        gdp = get_series(ds, "FRED_GDPC1")
        @test gdp.frequency == Quarterly
        @test length(gdp) >= 4
        @info "dataset" n_series=length(ds)
    end

    @testset "期間指定なしで全期間取得" begin
        ff_all = fetch_fred_series("FEDFUNDS"; client=client)

        @test ff_all.id       == "FRED_FEDFUNDS"
        @test length(ff_all)  >= 100  # 1954年以降の長期系列
        @info "FEDFUNDS 全期間" len=length(ff_all) first_date=ff_all.dates[1]
    end

    @testset "DataSeries と preprocess の連携" begin
        cpi = fetch_fred_series("CPIAUCSL"; client=client, start_date="2019-01-01", end_date="2020-12-31")

        vals = nonmissing_values(cpi)
        @test length(vals) == 24
        @test all(v -> v > 0, vals)

        log_cpi = apply_log(cpi)
        @test log_cpi.id == "FRED_CPIAUCSL"   # apply_log は id を変えない
        @test log_cpi.unit == "log($(cpi.unit))"
        @test all(v -> !ismissing(v), log_cpi.values)
        @info "log CPI" sample=log_cpi.values[1]
    end
end
