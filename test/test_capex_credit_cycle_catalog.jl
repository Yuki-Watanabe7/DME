# CCC実証catalog（Issue #241 / P-1）の契約テスト。取得・measurement・較正は後続Issueの責務。

function _ccc_catalog_spec(;
    key::Symbol = :test_series,
    provider_series_id::String = "TEST_SERIES",
    source_kind::Symbol = :official_statistic,
    role::Symbol = :validation_only,
    observability::Symbol = :D,
    methodology::Symbol = :direct,
    declared_real_nominal::Symbol = :real,
    level_form::Symbol = :level,
    anchor::Union{Symbol, Nothing} = nothing,
    scope_bias::Symbol = :none,
    aggregation::Symbol = :sum,
    model_timing::Symbol = :SUM,
    allocation_key::Union{Symbol, Nothing} = nothing,
)
    return CapexSeriesSpec(
        key = key,
        model_vars = [:y_tot],
        provider_series_id = provider_series_id,
        provider = "TEST",
        source_kind = source_kind,
        role = role,
        observability = observability,
        methodology = methodology,
        declared_unit = "Test unit",
        declared_frequency = Quarterly,
        declared_seasonal_adjustment = "SA",
        declared_real_nominal = declared_real_nominal,
        level_form = level_form,
        anchor = anchor,
        sector_scope = "test scope",
        scope_bias = scope_bias,
        aggregation = aggregation,
        model_timing = model_timing,
        allocation_key = allocation_key,
        availability_start = "2000-Q1",
        notes = "test catalog entry",
    )
end

@testset "CCC empirical series catalog (Issue #241 / P-1)" begin
    @testset "§12.1-1: shipped catalog is valid and filterable" begin
        @test validate_capex_series_catalog() === nothing
        @test validate_capex_series_catalog(CAPEX_CC_SERIES_CATALOG) === nothing
        @test length(CAPEX_CC_SERIES_CATALOG) == 49
        @test length(capex_series_catalog(; role = :calibration_required)) > 0
        @test all(
            spec -> spec.role == :calibration_required,
            capex_series_catalog(; role = :calibration_required),
        )
        @test all(
            spec -> spec.provider == "FRED",
            capex_series_catalog(; provider = "FRED"),
        )
        @test_throws ArgumentError capex_series_catalog(; role = :unknown)
    end

    @testset "§12.1-2–7: fail-closed validator" begin
        @test_throws ArgumentError validate_capex_series_catalog([
            _ccc_catalog_spec(source_kind = :firm_disclosure, role = :calibration_required),
        ])
        @test_throws ArgumentError validate_capex_series_catalog([
            _ccc_catalog_spec(level_form = :index, declared_real_nominal = :index),
        ])
        @test_throws ArgumentError validate_capex_series_catalog([
            _ccc_catalog_spec(methodology = :allocation),
        ])
        @test_throws ArgumentError validate_capex_series_catalog([
            _ccc_catalog_spec(methodology = :proxy, scope_bias = :none),
        ])
        @test_throws ArgumentError validate_capex_series_catalog([
            _ccc_catalog_spec(observability = :E, role = :estimation_input),
        ])
        @test_throws ArgumentError validate_capex_series_catalog([
            _ccc_catalog_spec(key = :duplicate),
            _ccc_catalog_spec(key = :duplicate, provider_series_id = "TEST_SERIES_2"),
        ])
        @test_throws ArgumentError validate_capex_series_catalog([
            _ccc_catalog_spec(model_timing = :SUM, aggregation = :mean),
        ])
    end

    @testset "§12.1-8: documentation and registry have the same series-ID set" begin
        doc_path =
            joinpath(@__DIR__, "..", "docs", "data", "capex_credit_cycle_series_catalog.md")
        doc_ids = Set{String}()
        in_coverage_matrix = false
        for line in eachline(doc_path)
            line == "## coverage matrix" && (in_coverage_matrix = true)
            line == "## primary-source confirmation" && (in_coverage_matrix = false)
            in_coverage_matrix || continue
            m = match(r"^\| `([^`]+)` \|", line)
            m === nothing || push!(doc_ids, m.captures[1])
        end
        catalog_ids = Set(spec.provider_series_id for spec in CAPEX_CC_SERIES_CATALOG)
        @test doc_ids == catalog_ids
        @test length(doc_ids) == length(CAPEX_CC_SERIES_CATALOG)
    end

    @testset "provider gaps are series-level cross-repository handoffs" begin
        catalog_keys = Set(spec.key for spec in CAPEX_CC_SERIES_CATALOG)
        @test !isempty(CAPEX_CC_PROVIDER_GAPS)
        @test all(gap -> gap.key in catalog_keys, CAPEX_CC_PROVIDER_GAPS)
        @test all(gap -> !isempty(gap.blocking), CAPEX_CC_PROVIDER_GAPS)
        @test Set(gap.kind for gap in CAPEX_CC_PROVIDER_GAPS) == Set((
            :missing_series,
            :missing_metadata,
            :missing_frequency,
            :missing_history,
            :missing_fixture_parity,
            :missing_vintage,
        ))
    end

    @testset "canonical JSON handoff and atomic save" begin
        d = capex_series_catalog_to_dict()
        @test d["catalog_version"] == CAPEX_CC_EMPIRICAL_INTEGRATION_VERSION
        @test length(d["series"]) == length(CAPEX_CC_SERIES_CATALOG)
        @test length(d["provider_gaps"]) == length(CAPEX_CC_PROVIDER_GAPS)
        @test canonical_json_string(d) ==
              canonical_json_string(capex_series_catalog_to_dict())

        path = joinpath(mktempdir(), "capex-series-catalog.json")
        @test save_capex_series_catalog(path) == path
        @test isfile(path)
        @test !isfile(path * ".tmp")
        first_bytes = read(path)
        @test save_capex_series_catalog(path) == path
        @test read(path) == first_bytes
    end
end
