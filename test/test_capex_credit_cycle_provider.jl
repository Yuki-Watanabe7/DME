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
end
