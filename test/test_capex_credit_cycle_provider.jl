# CCC raw provider adapter contract tests (Issue #242 / P-2).

const _CCC_PROVIDER_FIXTURE_DIR =
    joinpath(@__DIR__, "fixtures", "data", "capex_credit_cycle")

function _ccc_provider_spec(;
    key::Symbol,
    provider_series_id::String,
    declared_unit::String,
    declared_frequency::DataFrequency,
    declared_seasonal_adjustment::String = "SA",
)
    return CapexSeriesSpec(
        key = key,
        model_vars = [:y_tot],
        provider_series_id = provider_series_id,
        provider = "TEST",
        source_kind = :official_statistic,
        role = :validation_only,
        observability = :D,
        methodology = :direct,
        declared_unit = declared_unit,
        declared_frequency = declared_frequency,
        declared_seasonal_adjustment = declared_seasonal_adjustment,
        declared_real_nominal = :not_applicable,
        level_form = :level,
        sector_scope = "test scope",
        scope_bias = :none,
        aggregation = declared_frequency == Quarterly ? :sum : :mean,
        model_timing = declared_frequency == Quarterly ? :SUM : :AVG,
        notes = "test provider entry",
    )
end

const _CCC_PROVIDER_TEST_CATALOG = [
    _ccc_provider_spec(
        key = :test_capex_s1,
        provider_series_id = "TEST_CAPEX_S1",
        declared_unit = "Billions of dollars",
        declared_frequency = Quarterly,
    ),
    _ccc_provider_spec(
        key = :test_capex_s2,
        provider_series_id = "TEST_CAPEX_S2",
        declared_unit = "Thousands of persons",
        declared_frequency = Monthly,
    ),
]

function _ccc_fixture_response(endpoint::String)::String
    endpoint == "/v1/catalog/series" &&
        return read(joinpath(_CCC_PROVIDER_FIXTURE_DIR, "catalog.json"), String)
    prefix = "/v1/series/"
    startswith(endpoint, prefix) || throw(ArgumentError("unexpected endpoint: $endpoint"))
    id = endpoint[(lastindex(prefix) + 1):end]
    return read(joinpath(_CCC_PROVIDER_FIXTURE_DIR, "series", "$(id).json"), String)
end

function _ccc_rest_client(
    ;
    catalog_json::String = _ccc_fixture_response("/v1/catalog/series"),
    series_json::Dict{String, String} = Dict(
        spec.provider_series_id => _ccc_fixture_response("/v1/series/$(spec.provider_series_id)") for
        spec in _CCC_PROVIDER_TEST_CATALOG
    ),
    requester::Union{Function, Nothing} = nothing,
)
    request = requester === nothing ? (url, timeout) -> begin
        endswith(url, "/v1/catalog/series") && return catalog_json
        for (id, body) in series_json
            endswith(url, "/v1/series/$id") && return body
        end
        throw(DME._DataProviderHTTPError(404, "not found"))
    end : requester
    return DataProviderClient(
        mode = :rest_api,
        base_url = "https://user:secret@example.invalid",
        requester = request,
    )
end

function _ccc_status(raw::CapexRawDataset, key::Symbol)::Symbol
    return raw.observations[key].status
end

@testset "CCC EDP provider adapter (Issue #242 / P-2)" begin
    @testset "generic EDP client uses catalog-controlled IDs and no local fallback" begin
        fixture_client = DataProviderClient(mode = :fixture, fixture_dir = _CCC_PROVIDER_FIXTURE_DIR)
        @test occursin("\"items\"", fetch_provider_catalog(; client = fixture_client))
        @test occursin(
            "TEST_CAPEX_S1",
            fetch_provider_series("TEST_CAPEX_S1"; client = fixture_client),
        )
        @test_throws ArgumentError fetch_provider_series("bad/id"; client = fixture_client)
        withenv("DATA_PROVIDER_BASE_URL" => nothing) do
            client = DataProviderClient(mode = :fixture)
            @test client.base_url == ""
            @test !occursin("localhost", client.base_url)
        end
    end

    @testset "normal fixture response preserves raw values and provider provenance" begin
        raw = build_capex_raw_dataset(
            catalog = _CCC_PROVIDER_TEST_CATALOG,
            client = DataProviderClient(mode = :fixture, fixture_dir = _CCC_PROVIDER_FIXTURE_DIR),
        )
        first = raw.observations[:test_capex_s1]
        second = raw.observations[:test_capex_s2]
        @test first.status == :ok
        @test first.series !== nothing
        @test first.series.id == "TEST_CAPEX_S1"
        @test first.series["2020-Q1"] == 10.0
        @test ismissing(first.series["2020-Q2"])
        @test first.provider_unit == "Billions of dollars"
        @test first.provider_frequency == Quarterly
        @test first.provider_seasonal_adjustment == "SA"
        @test ismissing(first.provider_vintage)
        @test first.series.metadata["source_agency"] == "Test Statistical Agency"
        @test first.series.metadata["source_name"] == "Test Capital Expenditure"
        @test first.retrieved_at === nothing
        @test second.status == :ok
        @test raw.metadata["provider_catalog_version"] == "test-catalog-v1"
        @test startswith(raw.metadata["raw_identity"], "sha256:")
        @test raw.quality_flags["status_counts"]["ok"] == 2
    end

    @testset "fixture and REST responses use the same raw decoder" begin
        fixture_raw = build_capex_raw_dataset(
            catalog = _CCC_PROVIDER_TEST_CATALOG,
            client = DataProviderClient(mode = :fixture, fixture_dir = _CCC_PROVIDER_FIXTURE_DIR),
        )
        rest_raw = build_capex_raw_dataset(
            catalog = _CCC_PROVIDER_TEST_CATALOG,
            client = _ccc_rest_client(),
        )
        for key in (:test_capex_s1, :test_capex_s2)
            fixture_obs = fixture_raw.observations[key]
            rest_obs = rest_raw.observations[key]
            @test fixture_obs.status == rest_obs.status == :ok
            @test fixture_obs.series.id == rest_obs.series.id
            @test fixture_obs.series.dates == rest_obs.series.dates
            @test isequal(fixture_obs.series.values, rest_obs.series.values)
            @test fixture_obs.provider_unit == rest_obs.provider_unit
            @test fixture_obs.provider_frequency == rest_obs.provider_frequency
            @test fixture_obs.provider_seasonal_adjustment == rest_obs.provider_seasonal_adjustment
        end
        @test fixture_raw.metadata["raw_identity"] == rest_raw.metadata["raw_identity"]
        @test rest_raw.provider_base == "https://example.invalid"
        @test rest_raw.observations[:test_capex_s1].retrieved_at !== nothing
    end

    @testset "empty, malformed, unknown-unit, and request failures stay distinct from zeros" begin
        base_catalog = _ccc_fixture_response("/v1/catalog/series")
        normal = _ccc_fixture_response("/v1/series/TEST_CAPEX_S1")

        empty = replace(normal, r"\"points\"\s*:\s*\[[\s\S]*\]" => "\"points\": []")
        raw_empty = build_capex_raw_dataset(
            catalog = [_CCC_PROVIDER_TEST_CATALOG[1]],
            client = _ccc_rest_client(series_json = Dict("TEST_CAPEX_S1" => empty)),
        )
        @test _ccc_status(raw_empty, :test_capex_s1) == :missing_series
        @test raw_empty.observations[:test_capex_s1].series === nothing

        missing_field = replace(normal, "\"unit\": \"Billions of dollars\",\n" => "")
        raw_missing_field = build_capex_raw_dataset(
            catalog = [_CCC_PROVIDER_TEST_CATALOG[1]],
            client = _ccc_rest_client(series_json = Dict("TEST_CAPEX_S1" => missing_field)),
        )
        @test _ccc_status(raw_missing_field, :test_capex_s1) == :invalid_response

        unknown_unit = replace(normal, "Billions of dollars" => "unknown")
        raw_unknown_unit = build_capex_raw_dataset(
            catalog = [_CCC_PROVIDER_TEST_CATALOG[1]],
            client = _ccc_rest_client(series_json = Dict("TEST_CAPEX_S1" => unknown_unit)),
        )
        @test _ccc_status(raw_unknown_unit, :test_capex_s1) == :invalid_response

        http_client = _ccc_rest_client(
            requester = (url, timeout) -> throw(DME._DataProviderHTTPError(503, "unavailable")),
        )
        raw_http = build_capex_raw_dataset(
            catalog = [_CCC_PROVIDER_TEST_CATALOG[1]],
            client = http_client,
        )
        @test _ccc_status(raw_http, :test_capex_s1) == :provider_error

        timeout_client = _ccc_rest_client(
            requester = (url, timeout) -> throw(ErrorException("timeout")),
        )
        raw_timeout = build_capex_raw_dataset(
            catalog = [_CCC_PROVIDER_TEST_CATALOG[1]],
            client = timeout_client,
        )
        @test _ccc_status(raw_timeout, :test_capex_s1) == :provider_error
        @test raw_timeout.observations[:test_capex_s1].series === nothing
        @test !occursin("secret", raw_timeout.observations[:test_capex_s1].detail)
        @test base_catalog != ""
    end

    @testset "missing metadata, metadata mismatches, catalog mismatch, and upstream gaps" begin
        catalog_without_sa = replace(
            _ccc_fixture_response("/v1/catalog/series"),
            "\"seasonal_adjustment\": \"SA\",\n" => "",
        )
        raw_missing_metadata = build_capex_raw_dataset(
            catalog = [_CCC_PROVIDER_TEST_CATALOG[1]],
            client = _ccc_rest_client(catalog_json = catalog_without_sa),
        )
        missing_metadata_obs = raw_missing_metadata.observations[:test_capex_s1]
        @test missing_metadata_obs.status == :ok
        @test ismissing(missing_metadata_obs.provider_seasonal_adjustment)

        mismatched_unit = replace(
            _ccc_fixture_response("/v1/series/TEST_CAPEX_S1"),
            "Billions of dollars" => "Percent",
        )
        raw_mismatch = build_capex_raw_dataset(
            catalog = [_CCC_PROVIDER_TEST_CATALOG[1]],
            client = _ccc_rest_client(series_json = Dict("TEST_CAPEX_S1" => mismatched_unit)),
        )
        mismatch_obs = raw_mismatch.observations[:test_capex_s1]
        @test mismatch_obs.status == :ok
        @test any(contains("unit:"), mismatch_obs.metadata_mismatches)

        catalog_only_s1 = replace(
            _ccc_fixture_response("/v1/catalog/series"),
            r",\s*\{\s*\"series_id\": \"TEST_CAPEX_S2\"[\s\S]*?\"estimation_method\": \"published\"\s*\}" => "",
        )
        raw_catalog_mismatch = build_capex_raw_dataset(
            catalog = _CCC_PROVIDER_TEST_CATALOG,
            client = _ccc_rest_client(catalog_json = catalog_only_s1),
        )
        @test _ccc_status(raw_catalog_mismatch, :test_capex_s1) == :ok
        @test _ccc_status(raw_catalog_mismatch, :test_capex_s2) == :missing_series

        policy_rate_spec = only(filter(spec -> spec.key == :policy_rate, CAPEX_CC_SERIES_CATALOG))
        raw_gap = build_capex_raw_dataset(
            catalog = [policy_rate_spec],
            client = DataProviderClient(
                mode = :rest_api,
                base_url = "https://user:secret@example.invalid",
                requester = (url, timeout) -> error("must not request a known gap"),
            ),
        )
        @test _ccc_status(raw_gap, :policy_rate) == :unavailable_upstream
        @test raw_gap.observations[:policy_rate].series === nothing
    end

    @testset "selected key order does not change raw identity or leak credentials" begin
        client = _ccc_rest_client()
        ordered = build_capex_raw_dataset(
            catalog = _CCC_PROVIDER_TEST_CATALOG,
            client = client,
            keys = [:test_capex_s1, :test_capex_s2],
        )
        shuffled = build_capex_raw_dataset(
            catalog = _CCC_PROVIDER_TEST_CATALOG,
            client = client,
            keys = [:test_capex_s2, :test_capex_s1],
        )
        @test ordered.metadata["raw_identity"] == shuffled.metadata["raw_identity"]
        @test ordered.metadata["selected_keys"] == ["test_capex_s1", "test_capex_s2"]
        @test ordered.provider_base == "https://example.invalid"
        @test !occursin("secret", repr(ordered))
        @test !occursin("user", repr(ordered))
    end
    @testset "EDP 6.1.0: bare FRED IDs, daily CP reduction, seasonal-adjustment wording (Issue #314)" begin
        # 合成（fictional）の応答。形は EDP 6.1.0（EDP ADR 073）の /v1/catalog/series・
        # /v1/series/{id} に合わせる（us_credit_spread ブロック・"Not Seasonally Adjusted"・
        # 日次ラベル・null の日）。値は実データではない。
        spread_keys = [:spread_hqm_corporate, :treasury_10y, :spread_cp_a2p2, :treasury_bill_3m]
        catalog_item(id, frequency) = Dict{String, Any}(
            "series_id" => id, "title" => "fictional $id", "country" => "US",
            "rate_types" => Any[], "role" => "credit_spread_credit_leg", "unit" => "Percent",
            "frequency" => frequency, "source" => "fred", "provider" => "fred",
            "source_status" => "available",
            "seasonal_adjustment" => "Not Seasonally Adjusted",
            "us_credit_spread" => Dict{String, Any}("pair" => "fictional", "leg" => "credit"),
        )
        catalog_json = DME.json_write(Dict{String, Any}(
            "items" => Any[
                catalog_item("HQMCB10YRP", "monthly"), catalog_item("GS10", "monthly"),
                catalog_item("RIFSPPNA2P2D90NB", "daily"), catalog_item("TB3MS", "monthly"),
            ],
            "pagination" => Dict{String, Any}("total" => 4, "limit" => nothing, "next_cursor" => nothing),
            "snapshot" => Dict{String, Any}("version" => "fictional", "contract_version" => "6.1.0"),
        ))
        point(label, value) = Dict{String, Any}(
            "label" => label, "value" => value, "release_date" => nothing,
            "provenance" => Dict{String, Any}("observation_date" => label, "quality_status" => "ok"),
        )
        series_json(id, frequency, points) = DME.json_write(Dict{String, Any}(
            "id" => id, "source_id" => id, "name" => "fictional $id", "unit" => "Percent",
            "frequency" => frequency, "currency" => nothing, "points" => points,
        ))
        monthly(id, base) = series_json(
            id, "monthly",
            Any[point("2026-0$m", base + 0.01 * m) for m in 3:8],
        )
        daily_points = Any[
            point("2026-08-24", 4.60), point("2026-08-25", nothing), point("2026-08-26", 4.62),
            point("2026-08-27", nothing), point("2026-08-28", 4.64), point("2026-08-31", nothing),
            point("2026-09-01", 4.70), point("2026-09-02", nothing), point("2026-09-03", nothing),
            point("2026-09-04", 4.80),
        ]
        responses = Dict(
            "HQMCB10YRP" => monthly("HQMCB10YRP", 5.0),
            "GS10" => monthly("GS10", 4.0),
            "RIFSPPNA2P2D90NB" => series_json("RIFSPPNA2P2D90NB", "daily", daily_points),
            "TB3MS" => monthly("TB3MS", 3.8),
        )
        requested = String[]
        function client_for(responses)
            return DataProviderClient(
                mode = :rest_api,
                base_url = "https://example.invalid",
                requester = (url, timeout) -> begin
                    push!(requested, url)
                    endswith(url, "/v1/catalog/series") && return catalog_json
                    id = last(split(url, '/'))
                    haskey(responses, id) && return responses[id]
                    throw(DME._DataProviderHTTPError(404, "not found", "unsupported_symbol", nothing))
                end,
            )
        end

        @test !any(gap -> gap.key in spread_keys, CAPEX_CC_PROVIDER_GAPS)
        raw = build_capex_raw_dataset(; client = client_for(responses), keys = spread_keys)
        # bare FRED IDs only (EDP 6.1.0 rejects FRED_<id> with 404 unsupported_symbol)
        @test !any(url -> occursin("FRED_", url), requested)
        @test any(url -> endswith(url, "/v1/series/HQMCB10YRP"), requested)
        for key in spread_keys
            obs = raw.observations[key]
            @test obs.status == :ok
            # "Not Seasonally Adjusted" and the catalog's "NSA" are the same declaration
            @test obs.provider_seasonal_adjustment == "Not Seasonally Adjusted"
            @test isempty(obs.metadata_mismatches)
        end
        @test raw.observations[:treasury_10y].provider_frequency == Monthly
        @test raw.observations[:treasury_10y].series.id == "GS10"

        cp = raw.observations[:spread_cp_a2p2]
        @test cp.provider_frequency == :daily
        @test cp.series.frequency == Monthly
        @test cp.series.dates == ["2026-08", "2026-09"]
        @test cp.series.values[1] ≈ (4.60 + 4.62 + 4.64) / 3
        @test cp.series.values[2] ≈ (4.70 + 4.80) / 2
        reduction = cp.series.metadata["daily_reduction"]
        @test reduction["method"] == "mean"
        @test reduction["n_daily_points"] == 10
        @test reduction["n_daily_missing"] == 5
        @test reduction["n_months"] == 2
        @test reduction["n_months_without_observation"] == 0
        @test reduction["min_days_per_month"] == 2
        @test (reduction["first_daily_date"], reduction["last_daily_date"]) ==
              ("2026-08-24", "2026-09-04")
        @test any(t -> occursin("daily_to_monthly_mean", t), cp.series.metadata["transformations"])
        # the measurement formula records the reduction
        @test startswith(
            DME._capex_measure_series(cp).conversion_formula,
            "source(daily → monthly :mean)",
        )

        # determinism: the same responses give the same raw identity
        again = build_capex_raw_dataset(; client = client_for(responses), keys = spread_keys)
        @test again.metadata["raw_identity"] == raw.metadata["raw_identity"]
        # a different daily value inside a month changes the identity
        changed = copy(responses)
        changed["RIFSPPNA2P2D90NB"] = series_json(
            "RIFSPPNA2P2D90NB", "daily",
            Any[daily_points[1:end-1]..., point("2026-09-04", 4.90)],
        )
        @test build_capex_raw_dataset(; client = client_for(changed), keys = spread_keys).metadata["raw_identity"] !=
              raw.metadata["raw_identity"]

        # a month with no published day stays missing; it is not filled
        sparse = copy(responses)
        sparse["RIFSPPNA2P2D90NB"] = series_json(
            "RIFSPPNA2P2D90NB", "daily",
            Any[point("2026-07-30", nothing), point("2026-07-31", nothing), daily_points...],
        )
        sparse_cp = build_capex_raw_dataset(; client = client_for(sparse), keys = [:spread_cp_a2p2]).observations[:spread_cp_a2p2]
        @test sparse_cp.status == :ok
        @test sparse_cp.series.dates == ["2026-07", "2026-08", "2026-09"]
        @test ismissing(sparse_cp.series.values[1])
        @test sparse_cp.series.metadata["daily_reduction"]["n_months_without_observation"] == 1
        @test any(
            w -> occursin("had no daily observation", w),
            DME._capex_measure_series(sparse_cp).warnings,
        )

        # daily data for an entry without daily_reduction is rejected, not reduced
        daily_gs10 = copy(responses)
        daily_gs10["GS10"] = series_json("GS10", "daily", daily_points)
        rejected = build_capex_raw_dataset(; client = client_for(daily_gs10), keys = [:treasury_10y])
        @test _ccc_status(rejected, :treasury_10y) == :invalid_response
        @test occursin("daily_reduction", rejected.observations[:treasury_10y].detail)

        # weekly and malformed daily labels are decode errors
        weekly = copy(responses)
        weekly["RIFSPPNA2P2D90NB"] = series_json("RIFSPPNA2P2D90NB", "weekly", daily_points)
        @test _ccc_status(
            build_capex_raw_dataset(; client = client_for(weekly), keys = [:spread_cp_a2p2]),
            :spread_cp_a2p2,
        ) == :invalid_response
        bad_label = copy(responses)
        bad_label["RIFSPPNA2P2D90NB"] =
            series_json("RIFSPPNA2P2D90NB", "daily", Any[point("2026-08", 4.6)])
        @test _ccc_status(
            build_capex_raw_dataset(; client = client_for(bad_label), keys = [:spread_cp_a2p2]),
            :spread_cp_a2p2,
        ) == :invalid_response

        # a real seasonal-adjustment difference is still reported
        @test DME._capex_normalized_seasonal_adjustment("Seasonally Adjusted Annual Rate") == "SAAR"
        @test DME._capex_normalized_seasonal_adjustment("Not Seasonally Adjusted") == "NSA"
        @test DME._capex_normalized_seasonal_adjustment("SA") == "SA"
        sa_series = copy(responses)
        sa_catalog = replace(catalog_json, "Not Seasonally Adjusted" => "Seasonally Adjusted")
        sa_client = DataProviderClient(
            mode = :rest_api,
            base_url = "https://example.invalid",
            requester = (url, timeout) -> endswith(url, "/v1/catalog/series") ? sa_catalog :
                                          sa_series[last(split(url, '/'))],
        )
        sa_raw = build_capex_raw_dataset(; client = sa_client, keys = [:treasury_10y])
        @test any(m -> startswith(m, "seasonal_adjustment"), sa_raw.observations[:treasury_10y].metadata_mismatches)
    end
end
