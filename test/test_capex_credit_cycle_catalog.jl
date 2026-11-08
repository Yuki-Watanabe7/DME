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
    declared_frequency::DataFrequency = Quarterly,
    daily_reduction::Union{Symbol, Nothing} = nothing,
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
        declared_frequency = declared_frequency,
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
        daily_reduction = daily_reduction,
    )
end

@testset "CCC empirical series catalog (Issue #241 / P-1)" begin
    @testset "§12.1-1: shipped catalog is valid and filterable" begin
        @test validate_capex_series_catalog() === nothing
        @test validate_capex_series_catalog(CAPEX_CC_SERIES_CATALOG) === nothing
        @test length(CAPEX_CC_SERIES_CATALOG) == 51
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

    @testset "spread uses redistributable series only (Issue #312 / ADR 0029)" begin
        ids = Set(spec.provider_series_id for spec in CAPEX_CC_SERIES_CATALOG)
        for excluded in keys(DME._REDISTRIBUTION_EXCLUDED_SERIES)
            @test !(excluded in ids)
            @test !("FRED_" * excluded in ids)
            @test_throws ArgumentError validate_capex_series_catalog([
                _ccc_catalog_spec(provider_series_id = "FRED_" * excluded),
            ])
            @test_throws ArgumentError validate_capex_series_catalog([
                _ccc_catalog_spec(provider_series_id = excluded),
            ])
        end
        spread_sources = sort([
            spec.key for spec in CAPEX_CC_SERIES_CATALOG if :spread in spec.model_vars
        ])
        @test spread_sources == [:spread_cp_a2p2, :spread_hqm_corporate]
        primary = only(s for s in CAPEX_CC_SERIES_CATALOG if s.key == :spread_hqm_corporate)
        @test primary.provider_series_id == "HQMCB10YRP"
        @test primary.role == :calibration_required
        @test (primary.observability, primary.methodology, primary.scope_bias) ==
              (:C, :proxy, :under)
        @test primary.reference_key == :treasury_10y
        alternative = only(s for s in CAPEX_CC_SERIES_CATALOG if s.key == :spread_cp_a2p2)
        @test alternative.provider_series_id == "RIFSPPNA2P2D90NB"
        @test alternative.role == :validation_only
        @test alternative.reference_key == :treasury_bill_3m
        # EDP serves the CP rate daily and does not downsample it (EDP ADR 073)
        @test alternative.daily_reduction == :mean
        @test primary.daily_reduction === nothing
        refs = Dict(s.key => s for s in CAPEX_CC_SERIES_CATALOG)
        @test refs[:treasury_10y].provider_series_id == "GS10"
        @test refs[:treasury_bill_3m].provider_series_id == "TB3MS"
        # reference legs are not model variables, and every declared reference exists
        @test isempty(refs[:treasury_10y].model_vars)
        @test isempty(refs[:treasury_bill_3m].model_vars)
        for spec in CAPEX_CC_SERIES_CATALOG
            spec.reference_key === nothing || @test haskey(refs, spec.reference_key)
        end
        # the reference leg of a calibration-required spread binds the same sample
        @test refs[:treasury_10y].role == :calibration_required
    end

    @testset "FRED IDs are bare and daily_reduction is declared (Issue #314 / EDP ADR 073)" begin
        fred = capex_series_catalog(; provider = "FRED")
        @test length(fred) == 18
        @test all(spec -> occursin(r"^[A-Z0-9]+$", spec.provider_series_id), fred)
        @test !any(spec -> startswith(spec.provider_series_id, "FRED_"), CAPEX_CC_SERIES_CATALOG)
        # the prefixed form EDP no longer resolves is rejected for provider = "FRED"
        fred_spec(id) = _ccc_catalog_spec(provider_series_id = id)
        bare = CapexSeriesSpec(;
            (f => getfield(fred_spec("GS10"), f) for f in fieldnames(CapexSeriesSpec) if f != :provider)...,
            provider = "FRED",
        )
        @test validate_capex_series_catalog([bare]) === nothing
        for bad in ("FRED_GS10", "gs10", "GS-10")
            spec = CapexSeriesSpec(;
                (f => getfield(bare, f) for f in fieldnames(CapexSeriesSpec) if f != :provider_series_id)...,
                provider_series_id = bad,
            )
            @test_throws ArgumentError validate_capex_series_catalog([spec])
        end
        # non-FRED providers keep their DME-side stable IDs
        @test validate_capex_series_catalog([_ccc_catalog_spec(provider_series_id = "TEST_SERIES")]) === nothing

        @test CAPEX_CC_DAILY_REDUCTIONS == (:mean,)
        daily = [s for s in CAPEX_CC_SERIES_CATALOG if s.daily_reduction !== nothing]
        @test [s.key for s in daily] == [:spread_cp_a2p2]
        monthly_mean(; kwargs...) = _ccc_catalog_spec(;
            declared_frequency = Monthly, model_timing = :AVG, aggregation = :mean, kwargs...,
        )
        @test validate_capex_series_catalog([monthly_mean(daily_reduction = :mean)]) === nothing
        @test_throws ArgumentError validate_capex_series_catalog([monthly_mean(daily_reduction = :last)])
        @test_throws ArgumentError validate_capex_series_catalog([
            _ccc_catalog_spec(declared_frequency = Monthly, daily_reduction = :mean),  # SUM, not AVG
        ])
        @test_throws ArgumentError validate_capex_series_catalog([
            _ccc_catalog_spec(model_timing = :AVG, aggregation = :mean, daily_reduction = :mean),  # Quarterly
        ])
        d = capex_series_catalog_to_dict()
        cp = only(x for x in d["series"] if x["key"] == "spread_cp_a2p2")
        @test cp["daily_reduction"] == "mean"
        @test all(haskey(x, "daily_reduction") for x in d["series"])
    end

    @testset "reference_key validation is fail-closed (ADR 0029)" begin
        leg(; kwargs...) = _ccc_catalog_spec(;
            key = :ref_leg, provider_series_id = "TEST_REF", model_timing = :AVG,
            aggregation = :mean, kwargs...,
        )
        diff_spec(; kwargs...) = CapexSeriesSpec(;
            key = :diff, model_vars = [:spread], provider_series_id = "TEST_DIFF",
            provider = "TEST", source_kind = :market_data, role = :calibration_required,
            observability = :C, methodology = :proxy, declared_unit = "Test unit",
            declared_frequency = Quarterly, declared_seasonal_adjustment = "SA",
            declared_real_nominal = :ratio, level_form = :level, sector_scope = "test scope",
            scope_bias = :under, aggregation = :mean, model_timing = :AVG,
            notes = "test difference entry", reference_key = :ref_leg, kwargs...,
        )
        @test validate_capex_series_catalog([diff_spec(), leg()]) === nothing
        # a reference that is absent from a partial catalog is allowed (measurement fails closed)
        @test validate_capex_series_catalog([diff_spec()]) === nothing
        @test_throws ArgumentError validate_capex_series_catalog([diff_spec(reference_key = :diff)])
        @test_throws ArgumentError validate_capex_series_catalog([diff_spec(observability = :D), leg()])
        @test_throws ArgumentError validate_capex_series_catalog([
            diff_spec(methodology = :aggregation, scope_bias = :none), leg(),
        ])
        @test_throws ArgumentError validate_capex_series_catalog([
            diff_spec(level_form = :index, anchor = :baseline_mean), leg(),
        ])
        # unit / timing / aggregation mismatches between the legs
        @test_throws ArgumentError validate_capex_series_catalog([
            diff_spec(declared_unit = "Other unit"), leg(),
        ])
        @test_throws ArgumentError validate_capex_series_catalog([
            diff_spec(), leg(model_timing = :EOP, aggregation = :end),
        ])
        # no chained references
        chained = CapexSeriesSpec(;
            key = :ref_leg, model_vars = Symbol[], provider_series_id = "TEST_REF",
            provider = "TEST", source_kind = :market_data, role = :calibration_required,
            observability = :C, methodology = :proxy, declared_unit = "Test unit",
            declared_frequency = Quarterly, declared_seasonal_adjustment = "SA",
            declared_real_nominal = :ratio, level_form = :level, sector_scope = "test scope",
            scope_bias = :under, aggregation = :mean, model_timing = :AVG,
            notes = "chained", reference_key = :other,
        )
        @test_throws ArgumentError validate_capex_series_catalog([diff_spec(), chained])
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
        hqm = only(x for x in d["series"] if x["key"] == "spread_hqm_corporate")
        @test hqm["reference_key"] == "treasury_10y"
        @test all(haskey(x, "reference_key") for x in d["series"])
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
