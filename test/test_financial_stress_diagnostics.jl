# 金融ストレス観測から導出する差分・変化指標のテスト
# （src/analysis/financial_stress_diagnostics.jl、Issue #260 Part B）。
#
# fixtureは test/fixtures/data/financial_stress/series/*.json（fictional）。

const _FSD_FIXTURE_DIR = joinpath(@__DIR__, "fixtures", "data", "financial_stress")

_fsd_dataset() = build_financial_stress_raw_dataset(;
    client = DataProviderClient(mode = :fixture, fixture_dir = _FSD_FIXTURE_DIR),
)

_fsd_series(; dates, values, key = :x, unit = "Percent") = FinancialStressSeries(;
    key = key, provider_series_id = "TEST", name = "test series", unit = unit,
    dates = dates, values = values,
)

@testset "aligned_daily_spread_bp（Issue #260 Part B）" begin
    @testset "smoke test（CLAUDE.md）" begin
        d = _fsd_dataset()
        spread = ccc_minus_broad_hy_oas_bp(d)
        @test spread isa AlignedDailySpread
        @test spread.n_common > 0
    end

    @testset "同日の値のみを使い、片方欠測の日は除外する（0や補完をしない）" begin
        a = _fsd_series(; key = :a, dates = ["2026-01-01", "2026-01-02", "2026-01-03"],
            values = [1.0, missing, 3.0])
        b = _fsd_series(; key = :b, dates = ["2026-01-01", "2026-01-02", "2026-01-04"],
            values = [0.5, 0.6, 0.7])
        spread = aligned_daily_spread_bp(a, b)
        # 2026-01-01: a=1.0,b=0.5 -> common. 2026-01-02: a missing -> excluded.
        # 2026-01-03: bに不在 -> excluded. 2026-01-04: aに不在 -> excluded.
        @test spread.dates == ["2026-01-01"]
        @test spread.values ≈ [(1.0 - 0.5) * 100.0]
        @test spread.n_common == 1
        @test spread.n_a_only_missing == 2   # 01-02（値欠測）・01-04（aに不在）
        @test spread.n_b_only_missing == 1   # 01-03（bに不在）
    end

    @testset "unitがPercentでない場合はArgumentError" begin
        a = _fsd_series(; dates = ["2026-01-01"], values = [1.0], unit = "bp")
        b = _fsd_series(; dates = ["2026-01-01"], values = [1.0])
        @test_throws ArgumentError aligned_daily_spread_bp(a, b)
    end

    @testset "latest_aligned: 最新日と0件時のnothing" begin
        a = _fsd_series(; dates = ["2026-01-01", "2026-01-02"], values = [1.0, 2.0])
        b = _fsd_series(; dates = ["2026-01-01", "2026-01-02"], values = [0.0, 0.0])
        spread = aligned_daily_spread_bp(a, b)
        @test latest_aligned(spread) == ("2026-01-02", 200.0)

        empty_a = _fsd_series(; dates = ["2026-01-01"], values = [missing])
        empty_b = _fsd_series(; dates = ["2026-01-01"], values = [missing])
        @test latest_aligned(aligned_daily_spread_bp(empty_a, empty_b)) === nothing
    end

    @testset "4種の名前付きwrapperがdatasetの正しい系列ペアを使う" begin
        d = _fsd_dataset()
        s1 = ccc_minus_broad_hy_oas_bp(d)
        @test (s1.a_key, s1.b_key) == (:ccc_oas, :broad_hy_oas)
        s2 = sofr_minus_iorb_bp(d)
        @test (s2.a_key, s2.b_key) == (:sofr, :iorb)
        s3 = tgcr_minus_iorb_bp(d)
        @test (s3.a_key, s3.b_key) == (:tgcr, :iorb)
        s4 = sofr_minus_tgcr_bp(d)
        @test (s4.a_key, s4.b_key) == (:sofr, :tgcr)
    end
end

@testset "yield_shift_bps（Issue #260 Part B）" begin
    @testset "smoke test（CLAUDE.md）" begin
        s = _fsd_series(; dates = ["2026-01-01", "2026-01-02"], values = [1.0, 1.5])
        @test yield_shift_bps(s, "2026-01-01", "2026-01-02") ≈ 50.0
    end

    @testset "どちらかの日付が欠測ならmissing（0へ変換しない）" begin
        s = _fsd_series(; dates = ["2026-01-01", "2026-01-02"], values = [1.0, missing])
        @test yield_shift_bps(s, "2026-01-01", "2026-01-02") === missing
        @test yield_shift_bps(s, "2026-01-01", "2026-01-03") === missing  # 不在日
    end

    @testset "unitがPercentでない場合はArgumentError" begin
        s = _fsd_series(; dates = ["2026-01-01"], values = [1.0], unit = "bp")
        @test_throws ArgumentError yield_shift_bps(s, "2026-01-01", "2026-01-01")
    end
end

@testset "long_rate_shift_components（Issue #260 Part B）" begin
    @testset "smoke test（CLAUDE.md）" begin
        d = _fsd_dataset()
        c = long_rate_shift_components(d, "2026-08-25", "2026-09-04")
        @test c.long_nominal_yield_shift_bps isa Float64
        @test c.long_real_yield_shift_bps isa Float64
        @test c.inflation_compensation_shift_bps isa Float64
        @test c.secured_funding_spread_shift_bps isa Float64
        # フィールド名は Part A（PR #267）の FundingShockComponents のキーワード引数と
        # 1:1 対応する設計だが、本PRはPart Aへ依存しない（field名の一致は docstring 上の
        # 設計意図であり、実行時の依存関係ではない）。
    end

    @testset "secured_funding_spread_shift_bpsはsofr-anchorの変化として計算する" begin
        d = _fsd_dataset()
        c = long_rate_shift_components(d, "2026-08-25", "2026-09-04")
        sofr = DME._fs_dataset_series(d, :sofr)
        iorb = DME._fs_dataset_series(d, :iorb)
        expected = yield_shift_bps(sofr, "2026-08-25", "2026-09-04") -
                   yield_shift_bps(iorb, "2026-08-25", "2026-09-04")
        @test c.secured_funding_spread_shift_bps ≈ expected
    end

    @testset "secured_funding_referenceを差し替えられる" begin
        d = _fsd_dataset()
        c_tgcr = long_rate_shift_components(
            d, "2026-08-25", "2026-09-04"; secured_funding_reference = :tgcr,
        )
        @test c_tgcr.secured_funding_reference === :tgcr
    end

    @testset "構成要素のいずれかが欠測日なら、その要素だけmissing" begin
        d = _fsd_dataset()
        # 2026-08-28はinflation_compensation（T10YIE）がfixtureでnull（他系列は非欠測）
        c = long_rate_shift_components(d, "2026-08-27", "2026-08-28")
        @test c.inflation_compensation_shift_bps === missing
        @test c.long_nominal_yield_shift_bps isa Float64  # DGS10は28日も非欠測
    end
end
