# 金融ストレス観測 catalog/provider のテスト（src/data/financial_stress_catalog.jl・
# src/data/financial_stress_provider.jl、Issue #260 Part B）。
#
# fixtureは test/fixtures/data/financial_stress/series/*.json（fictional。実在の
# 金利水準・日付の観測値を用いない）。EDPの `/v1/catalog/series` 突合は行わないため
# catalog.json fixtureは無い。credit-tier の2系列は Issue #312・ADR 0029 で ICE BofA OAS から
# FRB の非金融 CP 金利へ置き換えた。

const _FS_PROVIDER_FIXTURE_DIR = joinpath(@__DIR__, "fixtures", "data", "financial_stress")

_fs_fixture_client(; fixture_dir::String = _FS_PROVIDER_FIXTURE_DIR) =
    DataProviderClient(mode = :fixture, fixture_dir = fixture_dir)

@testset "金融ストレス観測 catalog（Issue #260 Part B）" begin
    @testset "smoke test（CLAUDE.md）" begin
        @test length(FINANCIAL_STRESS_SERIES_CATALOG) == 8
        @test financial_stress_spec(:cp_a2p2_nonfinancial_30d) isa FinancialStressSeriesSpec
    end

    @testset "catalogの8系列が確定している" begin
        keys = Set(getfield.(FINANCIAL_STRESS_SERIES_CATALOG, :key))
        @test keys == Set([
            :cp_a2p2_nonfinancial_30d, :cp_aa_nonfinancial_30d, :sofr, :tgcr, :iorb,
            :long_nominal_yield, :long_real_yield, :inflation_compensation,
        ])
        @test FINANCIAL_STRESS_CATALOG_VERSION == "financial-stress-catalog/2.0.0"
        # 下位/上位階層は同じ release・同じ満期の別 series_id（暗黙fallbackしない）
        lower = financial_stress_spec(:cp_a2p2_nonfinancial_30d)
        upper = financial_stress_spec(:cp_aa_nonfinancial_30d)
        @test lower.provider_series_id == "RIFSPPNA2P2D30NB"
        @test upper.provider_series_id == "RIFSPPNAAD30NB"
        @test lower.comparison_key == :cp_aa_nonfinancial_30d
        @test upper.comparison_key === nothing
        @test (lower.role, upper.role) ==
              (:credit_tier_lower_cp_rate, :credit_tier_upper_cp_rate)
    end

    @testset "EDPが提供を停止したICE BofA系列はcatalogに登録できない（Issue #312）" begin
        ids = Set(spec.provider_series_id for spec in FINANCIAL_STRESS_SERIES_CATALOG)
        @test isempty(intersect(ids, Set(keys(DME._REDISTRIBUTION_EXCLUDED_SERIES))))
        @test !(:credit_stress_ccc_oas in FINANCIAL_STRESS_ROLES)
        @test !(:credit_stress_broad_hy_oas in FINANCIAL_STRESS_ROLES)
        # 大文字小文字・前後の空白を無視して拒否する（FREDのIDは大文字小文字を区別しない）
        for id in ("BAMLH0A3HYC", "bamlh0a0hym2", " BAMLC0A0CM ")
            @test_throws ArgumentError FinancialStressSeriesSpec(;
                key = :x, provider_series_id = id, role = :policy_anchor_rate,
                unit = "Percent", description = "",
            )
        end
    end

    @testset "role が FINANCIAL_STRESS_ROLES のいずれかである" begin
        for spec in FINANCIAL_STRESS_SERIES_CATALOG
            @test spec.role in FINANCIAL_STRESS_ROLES
        end
    end

    @testset "未知の key は ArgumentError" begin
        @test_throws ArgumentError financial_stress_spec(:not_a_real_key)
    end

    @testset "重複key・存在しないcomparison_keyはArgumentError" begin
        bad_dup = [
            FinancialStressSeriesSpec(;
                key = :x, provider_series_id = "A", role = :policy_anchor_rate, unit = "Percent",
                description = "",
            ),
            FinancialStressSeriesSpec(;
                key = :x, provider_series_id = "B", role = :policy_anchor_rate, unit = "Percent",
                description = "",
            ),
        ]
        @test_throws ArgumentError DME._financial_stress_check_catalog(bad_dup)

        bad_ref = [
            FinancialStressSeriesSpec(;
                key = :x, provider_series_id = "A", role = :secured_funding_rate,
                comparison_key = :does_not_exist, unit = "Percent", description = "",
            ),
        ]
        @test_throws ArgumentError DME._financial_stress_check_catalog(bad_ref)
    end
end

@testset "金融ストレス観測 provider（Issue #260 Part B）" begin
    @testset "smoke test（CLAUDE.md）" begin
        raw = build_financial_stress_raw_dataset(; client = _fs_fixture_client())
        @test raw isa FinancialStressRawDataset
        @test raw.observations[:cp_a2p2_nonfinancial_30d].status == :ok
    end

    @testset "fixtureからraw観測を構築する（欠測日を0や直近値へ変換しない）" begin
        raw = build_financial_stress_raw_dataset(; client = _fs_fixture_client())
        for spec in FINANCIAL_STRESS_SERIES_CATALOG
            obs = raw.observations[spec.key]
            @test obs.status == :ok
            @test obs.series !== nothing
            @test obs.series.provider_series_id == spec.provider_series_id
            @test obs.series.unit == "Percent"
            @test issorted(obs.series.dates)
        end
        lower = raw.observations[:cp_a2p2_nonfinancial_30d].series
        @test ismissing(value_on_date(lower, "2026-08-27"))        # fixtureのnull
        @test value_on_date(lower, "2026-08-28") == 4.5
        @test value_on_date(lower, "2026-01-01") === missing        # 不在日も missing
        @test raw.catalog_version == FINANCIAL_STRESS_CATALOG_VERSION
        @test startswith(raw.metadata["raw_identity"], "sha256:")
        @test raw.metadata["status_counts"]["ok"] == 8
        @test raw.metadata["status_counts"]["distribution_stopped"] == 0
    end

    @testset "keys引数で部分集合のみ取得する" begin
        raw = build_financial_stress_raw_dataset(;
            client = _fs_fixture_client(),
            keys = [:sofr, :iorb],
        )
        @test Set(keys(raw.observations)) == Set([:sofr, :iorb])
        @test_throws ArgumentError build_financial_stress_raw_dataset(;
            client = _fs_fixture_client(),
            keys = [:not_a_real_key],
        )
        @test_throws ArgumentError build_financial_stress_raw_dataset(;
            client = _fs_fixture_client(),
            keys = [:sofr, :sofr],
        )
    end

    @testset "fixtureが無い系列は :missing_series（0や空データに変換しない）" begin
        raw = build_financial_stress_raw_dataset(;
            catalog = [
                FinancialStressSeriesSpec(;
                    key = :missing_test,
                    provider_series_id = "NOT_A_REAL_SERIES_ID",
                    role = :policy_anchor_rate,
                    unit = "Percent",
                    description = "",
                ),
            ],
            client = _fs_fixture_client(),
        )
        obs = raw.observations[:missing_test]
        @test obs.status == :missing_series
        @test obs.series === nothing
        @test !isempty(obs.detail)
    end

    @testset "HTTP失敗・不正JSON・空系列・frequency不一致がそれぞれ別statusになる" begin
        make_client(requester) =
            DataProviderClient(mode = :rest_api, base_url = "https://example.invalid", requester = requester)
        spec = financial_stress_spec(:sofr)

        # HTTP 500 -> :provider_error
        raw_500 = build_financial_stress_raw_dataset(;
            catalog = [spec],
            client = make_client((url, t) -> throw(DME._DataProviderHTTPError(500, "boom"))),
        )
        @test raw_500.observations[:sofr].status == :provider_error

        # HTTP 404 -> :missing_series
        raw_404 = build_financial_stress_raw_dataset(;
            catalog = [spec],
            client = make_client((url, t) -> throw(DME._DataProviderHTTPError(404, "not found"))),
        )
        @test raw_404.observations[:sofr].status == :missing_series

        # HTTP 410 distribution_stopped -> :distribution_stopped（障害・データなしと区別する、
        # Issue #312・EDP ADR 072）。reason_code を detail に残す
        raw_410 = build_financial_stress_raw_dataset(;
            catalog = [spec],
            client = make_client(
                (url, t) -> throw(
                    DME._DataProviderHTTPError(
                        410, "EDP returned a non-success response",
                        "distribution_stopped", "redistribution_rights",
                    ),
                ),
            ),
        )
        obs_410 = raw_410.observations[:sofr]
        @test obs_410.status == :distribution_stopped
        @test obs_410.series === nothing
        @test occursin("distribution_stopped", obs_410.detail)
        @test occursin("redistribution_rights", obs_410.detail)
        @test raw_410.metadata["status_counts"]["distribution_stopped"] == 1

        # 410 でも code が distribution_stopped でなければ提供停止として扱わない
        raw_410_other = build_financial_stress_raw_dataset(;
            catalog = [spec],
            client = make_client(
                (url, t) -> throw(DME._DataProviderHTTPError(410, "gone", "symbol_migrated", nothing)),
            ),
        )
        @test raw_410_other.observations[:sofr].status == :provider_error
        @test occursin("symbol_migrated", raw_410_other.observations[:sofr].detail)

        # code の無い 410 も :provider_error
        raw_410_plain = build_financial_stress_raw_dataset(;
            catalog = [spec],
            client = make_client((url, t) -> throw(DME._DataProviderHTTPError(410, "gone"))),
        )
        @test raw_410_plain.observations[:sofr].status == :provider_error

        # 不正JSON -> :invalid_response
        raw_bad_json = build_financial_stress_raw_dataset(;
            catalog = [spec],
            client = make_client((url, t) -> "not json"),
        )
        @test raw_bad_json.observations[:sofr].status == :invalid_response

        # 空系列 -> :missing_series
        empty_json = "{\"id\":\"SOFR\",\"name\":\"x\",\"unit\":\"Percent\",\"frequency\":\"daily\",\"points\":[]}"
        raw_empty = build_financial_stress_raw_dataset(;
            catalog = [spec],
            client = make_client((url, t) -> empty_json),
        )
        @test raw_empty.observations[:sofr].status == :missing_series

        # frequency不一致（monthly）-> :invalid_response
        monthly_json = "{\"id\":\"SOFR\",\"name\":\"x\",\"unit\":\"Percent\",\"frequency\":\"monthly\"," *
                       "\"points\":[{\"label\":\"2026-08-01\",\"value\":4.3}]}"
        raw_monthly = build_financial_stress_raw_dataset(;
            catalog = [spec],
            client = make_client((url, t) -> monthly_json),
        )
        @test raw_monthly.observations[:sofr].status == :invalid_response

        # id不一致 -> :invalid_response
        wrong_id_json = "{\"id\":\"NOT_SOFR\",\"name\":\"x\",\"unit\":\"Percent\",\"frequency\":\"daily\"," *
                        "\"points\":[{\"label\":\"2026-08-01\",\"value\":4.3}]}"
        raw_wrong_id = build_financial_stress_raw_dataset(;
            catalog = [spec],
            client = make_client((url, t) -> wrong_id_json),
        )
        @test raw_wrong_id.observations[:sofr].status == :invalid_response
    end

    @testset "EDPのエラー本文から detail.code・reason_code だけを取り出す（Issue #312）" begin
        body = "{\"detail\": {\"code\": \"distribution_stopped\", " *
               "\"reason_code\": \"redistribution_rights\", \"canonical_id\": \"BAMLH0A3HYC\", " *
               "\"symbol\": \"BAMLH0A3HYC\", \"message\": \"free text\"}}"
        @test DME._data_provider_error_codes(body) ==
              ("distribution_stopped", "redistribution_rights")
        @test DME._data_provider_error_codes("{\"detail\": \"Not Found\"}") == (nothing, nothing)
        @test DME._data_provider_error_codes("not json") == (nothing, nothing)
        @test DME._data_provider_error_codes("[1, 2]") == (nothing, nothing)
        # 短い小文字トークン以外（自由記述・URL等）は保持しない
        @test DME._data_provider_error_codes(
            "{\"detail\": {\"code\": \"See https://example.invalid/x\", \"reason_code\": 3}}",
        ) == (nothing, nothing)
        e = DME._DataProviderHTTPError(410, "x", "distribution_stopped", "redistribution_rights")
        @test DME._data_provider_distribution_stopped(e)
        @test !DME._data_provider_distribution_stopped(DME._DataProviderHTTPError(410, "x"))
        @test !DME._data_provider_distribution_stopped(
            DME._DataProviderHTTPError(404, "x", "distribution_stopped", nothing),
        )
    end

    @testset "FinancialStressSeries: dates/valuesの長さ不一致・非昇順を拒否する" begin
        @test_throws ArgumentError FinancialStressSeries(;
            key = :x, provider_series_id = "A", name = "n", unit = "Percent",
            dates = ["2026-01-01", "2026-01-02"], values = [1.0],
        )
        @test_throws ArgumentError FinancialStressSeries(;
            key = :x, provider_series_id = "A", name = "n", unit = "Percent",
            dates = ["2026-01-02", "2026-01-01"], values = [1.0, 2.0],
        )
    end

    @testset "FinancialStressRawObservation: status=:ok/非:okとseriesの整合" begin
        spec = financial_stress_spec(:sofr)
        series = FinancialStressSeries(;
            key = :sofr, provider_series_id = "SOFR", name = "n", unit = "Percent",
            dates = ["2026-01-01"], values = [4.3],
        )
        @test_throws ArgumentError FinancialStressRawObservation(;
            key = :sofr, spec = spec, status = :ok, series = nothing,
            retrieved_at = nothing, mode = :fixture,
        )
        @test_throws ArgumentError FinancialStressRawObservation(;
            key = :sofr, spec = spec, status = :missing_series, series = series,
            retrieved_at = nothing, mode = :fixture,
        )
        @test_throws ArgumentError FinancialStressRawObservation(;
            key = :sofr, spec = spec, status = :not_a_real_status, series = nothing,
            retrieved_at = nothing, mode = :fixture,
        )
    end
end
