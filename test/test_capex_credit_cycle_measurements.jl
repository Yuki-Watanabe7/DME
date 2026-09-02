# CCC measurement / empirical dataset contract tests (Issue #243 / P-3).
# 受け入れ条件は docs/architecture/capex_credit_cycle_empirical_integration.md §12.3（項目 18–28）。

function _meas_spec(;
    key::Symbol,
    role::Symbol = :calibration_required,
    observability::Symbol = :D,
    methodology::Symbol = :direct,
    frequency::DataFrequency = Quarterly,
    aggregation::Symbol = :sum,
    model_timing::Symbol = :SUM,
    annualized::Bool = false,
    level_form::Symbol = :level,
    anchor::Union{Symbol, Nothing} = nothing,
    scope_bias::Symbol = :none,
    allocation_key::Union{Symbol, Nothing} = nothing,
    declared_real_nominal::Symbol = :real,
    declared_base_year::Union{Int, Nothing} = nothing,
)
    return CapexSeriesSpec(
        key = key,
        model_vars = [:y_tot],
        provider_series_id = uppercase(string(key)),
        provider = "TEST",
        source_kind = :official_statistic,
        role = role,
        observability = observability,
        methodology = methodology,
        declared_unit = "test unit",
        declared_frequency = frequency,
        declared_seasonal_adjustment = "SA",
        declared_real_nominal = declared_real_nominal,
        declared_base_year = declared_base_year,
        annualized = annualized,
        level_form = level_form,
        anchor = anchor,
        sector_scope = "test scope",
        scope_bias = scope_bias,
        aggregation = aggregation,
        model_timing = model_timing,
        allocation_key = allocation_key,
        availability_start = "2000-Q1",
        notes = "test measurement entry",
    )
end

function _meas_obs(
    spec::CapexSeriesSpec,
    series::Union{DataSeries, Nothing};
    status::Symbol = :ok,
    provider_vintage::Union{String, Missing} = missing,
)
    return CapexRawObservation(
        spec.key,
        spec,
        status,
        series,
        series === nothing ? missing : series.unit,
        series === nothing ? missing : series.frequency,
        "SA",
        provider_vintage,
        String[],
        nothing,
        :fixture,
        "",
    )
end

function _meas_raw(observations::Vector{CapexRawObservation})
    return CapexRawDataset(
        Dict(obs.key => obs for obs in observations),
        "test-catalog-v1",
        CAPEX_CC_EMPIRICAL_INTEGRATION_VERSION,
        "",
        Dict{String, Any}(),
        Dict{String, Any}(),
    )
end

function _q_dates(start_label::String, n::Int)
    year0, quarter0 = _capex_split_q(start_label)
    base = year0 * 4 + (quarter0 - 1)
    return [string(idx ÷ 4, "-Q", idx % 4 + 1) for idx in base:(base + n - 1)]
end

_capex_split_q(label::String) =
    (parse(Int, split(label, "-Q")[1]), parse(Int, split(label, "-Q")[2]))

function _q_series(id::String, start_label::String, values::Vector)
    dates = _q_dates(start_label, length(values))
    return DataSeries(
        id,
        id,
        "TEST",
        Quarterly,
        "test unit",
        dates,
        Vector{Union{Float64, Missing}}(values),
    )
end

function _m_series(id::String, start_label::String, values::Vector)
    year0, month0 =
        parse(Int, split(start_label, "-")[1]), parse(Int, split(start_label, "-")[2])
    dates = String[]
    for i in 0:(length(values) - 1)
        offset = (month0 - 1) + i
        push!(dates, string(year0 + offset ÷ 12, "-", lpad(offset % 12 + 1, 2, "0")))
    end
    return DataSeries(
        id,
        id,
        "TEST",
        Monthly,
        "test unit",
        dates,
        Vector{Union{Float64, Missing}}(values),
    )
end

@testset "CCC measurement / empirical dataset (Issue #243 / P-3)" begin
    @testset "§12.3-18: monthly flow/stock/rate frequency conversion is exact" begin
        flow_spec = _meas_spec(
            key = :flow,
            frequency = Monthly,
            aggregation = :sum,
            model_timing = :SUM,
        )
        flow = DME._capex_measure_series(
            _meas_obs(flow_spec, _m_series("F", "2010-01", Float64[1, 2, 3, 4, 5, 6])),
        )
        @test flow.measured.dates == ["2010-Q1", "2010-Q2"]
        @test flow.measured.values == [6.0, 15.0]

        stock_spec = _meas_spec(
            key = :stock,
            frequency = Monthly,
            aggregation = :end,
            model_timing = :EOP,
        )
        stock = DME._capex_measure_series(
            _meas_obs(
                stock_spec,
                _m_series("S", "2010-01", Float64[10, 11, 12, 13, 14, 15]),
            ),
        )
        @test stock.measured.values == [12.0, 15.0]

        rate_spec = _meas_spec(
            key = :rate,
            frequency = Monthly,
            aggregation = :mean,
            model_timing = :AVG,
        )
        rate = DME._capex_measure_series(
            _meas_obs(rate_spec, _m_series("R", "2010-01", Float64[2, 4, 6, 8, 10, 12])),
        )
        @test rate.measured.values == [4.0, 10.0]
    end

    @testset "§12.3-19: annualized series are divided by 4, others are not" begin
        saar = _meas_spec(key = :saar, annualized = true)
        m = DME._capex_measure_series(
            _meas_obs(saar, _q_series("Y", "2010-Q1", Float64[40, 80, 120])),
        )
        @test m.measured.values == [10.0, 20.0, 30.0]
        @test occursin("÷4", m.conversion_formula)

        level = _meas_spec(key = :lvl, annualized = false)
        m2 = DME._capex_measure_series(
            _meas_obs(level, _q_series("Y2", "2010-Q1", Float64[40, 80, 120])),
        )
        @test m2.measured.values == [40.0, 80.0, 120.0]
        @test !occursin("÷4", m2.conversion_formula)
    end

    @testset "§12.3-20: index series are anchored and keep the base year" begin
        idx_spec = _meas_spec(
            key = :idx,
            role = :estimation_input,
            observability = :D,
            methodology = :aggregation,
            level_form = :index,
            anchor = :baseline_mean_one,
            aggregation = :mean,
            model_timing = :AVG,
            declared_real_nominal = :index,
            declared_base_year = 2017,
        )
        m = DME._capex_measure_series(
            _meas_obs(idx_spec, _q_series("I", "2010-Q1", Float64[90, 100, 110])),
        )
        @test m.measured.values ≈ [0.9, 1.0, 1.1]
        @test m.anchor_detail !== nothing
        @test occursin("2017", m.anchor_detail)
        @test occursin("mean=1", m.anchor_detail)

        zero_spec = _meas_spec(
            key = :idx0,
            role = :validation_only,
            observability = :P,
            methodology = :proxy,
            scope_bias = :indeterminate,
            level_form = :index,
            anchor = :baseline_mean_zero,
            aggregation = :mean,
            model_timing = :AVG,
            declared_real_nominal = :index,
        )
        mz = DME._capex_measure_series(
            _meas_obs(zero_spec, _q_series("Z", "2010-Q1", Float64[1, 2, 3])),
        )
        @test mz.measured.values ≈ [-1.0, 0.0, 1.0]

        # external-series anchor stays in index form with a recorded, deferred detail
        deferred_spec = _meas_spec(
            key = :idxbea,
            role = :estimation_input,
            observability = :C,
            methodology = :proxy,
            scope_bias = :over,
            level_form = :index,
            anchor = :bea_annual_real_value_added,
            aggregation = :mean,
            model_timing = :AVG,
            declared_real_nominal = :index,
            declared_base_year = 2017,
        )
        md = DME._capex_measure_series(
            _meas_obs(deferred_spec, _q_series("B", "2010-Q1", Float64[100, 101, 102])),
        )
        @test md.measured.values == [100.0, 101.0, 102.0]
        @test occursin("deferred", md.anchor_detail)
        @test any(w -> occursin("deferred", w), md.warnings)
    end

    @testset "§12.3-21: annual series use capex_annual_to_quarterly and record the method" begin
        annual = DataSeries(
            "K",
            "K",
            "TEST",
            Annual,
            "test unit",
            ["2018", "2019", "2020"],
            Vector{Union{Float64, Missing}}([100.0, 120.0, 140.0]),
        )
        eoy = capex_annual_to_quarterly(annual)
        @test eoy.frequency == Quarterly
        @test eoy.dates[1] == "2018-Q1"
        @test all(ismissing, eoy.values[1:3])
        @test eoy.values[4] == 100.0
        @test eoy.values[5:8] == [105.0, 110.0, 115.0, 120.0]
        @test "capex_annual_to_quarterly(method=end_of_year_allocation)" in
              eoy.metadata["transformations"]

        flat = capex_annual_to_quarterly(annual; method = :flat)
        @test flat.values[1:4] == [100.0, 100.0, 100.0, 100.0]

        @test_throws ArgumentError capex_annual_to_quarterly(annual; method = :spline)
        @test_throws ArgumentError capex_annual_to_quarterly(
            _q_series("Q", "2010-Q1", Float64[1, 2]),
        )

        # inside the measurement pipeline: EOP stock → interpolation, SUM flow → flat
        stock_spec = _meas_spec(
            key = :capstock,
            frequency = Annual,
            aggregation = :end,
            model_timing = :EOP,
        )
        sm = DME._capex_measure_series(_meas_obs(stock_spec, annual))
        @test occursin(
            "capex_annual_to_quarterly(:end_of_year_allocation)",
            sm.conversion_formula,
        )
        @test any(w -> occursin("high-frequency", w), sm.warnings)
    end

    @testset "§12.3-22: BOP is the one-quarter lag of an EOP series" begin
        eop = _q_series("E", "2010-Q1", Float64[10, 11, 12, 13])
        bop = DME._capex_eop_to_bop(eop)
        @test bop.dates == eop.dates
        @test ismissing(bop.values[1])
        @test bop.values[2:4] == [10.0, 11.0, 12.0]
        @test "eop_to_bop_lag(1)" in bop.metadata["transformations"]
        # a gap in the EOP series propagates a missing BOP, never a zero
        gapped = _q_series("G", "2010-Q1", [10.0, missing, 12.0, 13.0])
        @test isequal(DME._capex_eop_to_bop(gapped).values, [missing, 10.0, missing, 12.0])
        @test_throws ArgumentError DME._capex_eop_to_bop(
            DataSeries("M", "M", "T", Monthly, "u", ["2010-01"], [1.0]),
        )
    end

    @testset "§12.3-23: every transformation stage is retained" begin
        spec = _meas_spec(
            key = :chain,
            frequency = Monthly,
            aggregation = :mean,
            model_timing = :AVG,
            annualized = true,
            level_form = :index,
            anchor = :baseline_mean_one,
            declared_real_nominal = :index,
            declared_base_year = 2012,
        )
        m = DME._capex_measure_series(
            _meas_obs(spec, _m_series("C", "2010-01", Float64[12, 24, 36, 48, 60, 72])),
        )
        stage_names = first.(m.stages)
        @test stage_names[1] == "source"
        @test length(m.stages) >= 4          # source → quarterly → deannualized → anchored
        @test last(m.stages).second === m.measured
        @test m.stages[1].second.frequency == Monthly
        @test length(m.stages[1].second) == 6
        @test occursin("→", m.conversion_formula)
    end

    @testset "§12.3-24,25: sample from :calibration_required inner join; :estimation_input never shrinks it" begin
        a = _meas_spec(key = :a)
        b = _meas_spec(key = :b)
        c = _meas_spec(key = :c)
        est = _meas_spec(key = :est, role = :estimation_input)
        raw = _meas_raw([
            _meas_obs(a, _q_series("A", "2010-Q1", collect(1.0:12.0))),
            _meas_obs(b, _q_series("B", "2010-Q3", collect(1.0:10.0))),
            _meas_obs(c, _q_series("C", "2010-Q1", collect(1.0:10.0))),
            _meas_obs(est, _q_series("E", "2011-Q1", collect(1.0:4.0))),
        ])
        ds = build_capex_empirical_dataset(raw; min_valid_obs = 8)
        @test ds.sample.sample_start == "2010-Q3"
        @test ds.sample.sample_end == "2012-Q2"
        @test ds.sample.n_obs == 8
        @test length(ds.dates) == 8
        @test Set(ds.sample.binding_series) == Set([:b, :c])
        @test ds.observation_times[1] == 2010.5
        @test ds.observation_times[2] == 2010.75
        # :estimation_input coverage is only 2011 but the window is unchanged
        @test count(!ismissing, ds.values[:est]) == 4
        @test ds.sample.n_obs == 8

        # a missing :estimation_input series still does not shrink the sample
        raw_missing_est = _meas_raw([
            _meas_obs(a, _q_series("A", "2010-Q1", collect(1.0:12.0))),
            _meas_obs(b, _q_series("B", "2010-Q3", collect(1.0:10.0))),
            _meas_obs(c, _q_series("C", "2010-Q1", collect(1.0:10.0))),
            _meas_obs(est, nothing; status = :missing_series),
        ])
        ds2 = build_capex_empirical_dataset(raw_missing_est; min_valid_obs = 8)
        @test ds2.sample.n_obs == 8
        @test all(ismissing, ds2.values[:est])
    end

    @testset "§12.3-24: a missing :calibration_required series fails closed" begin
        a = _meas_spec(key = :a)
        b = _meas_spec(key = :b)
        raw = _meas_raw([
            _meas_obs(a, _q_series("A", "2010-Q1", collect(1.0:12.0))),
            _meas_obs(b, nothing; status = :unavailable_upstream),
        ])
        @test_throws ArgumentError build_capex_empirical_dataset(raw; min_valid_obs = 4)
    end

    @testset "§12.3-26: :validation_only is identifiable and mechanically excludable" begin
        calib = _meas_spec(key = :calib)
        val = _meas_spec(
            key = :val,
            role = :validation_only,
            observability = :P,
            methodology = :proxy,
            scope_bias = :under,
        )
        raw = _meas_raw([
            _meas_obs(calib, _q_series("C", "2010-Q1", collect(1.0:10.0))),
            _meas_obs(val, _q_series("V", "2010-Q1", collect(10.0:19.0))),
        ])
        ds = build_capex_empirical_dataset(raw; min_valid_obs = 8)
        @test ds.roles[:val] == :validation_only
        @test haskey(ds.values, :val)                       # validation_only IS in values
        calibration_keys = [k for (k, r) in ds.roles if r == :calibration_required]
        @test calibration_keys == [:calib]
        @test !(:val in calibration_keys)
        # validation_only did not influence the sample
        @test ds.sample.binding_series == [:calib]
    end

    @testset "§12.3-27: structurally latent (:E / :A) keys carry no values" begin
        calib = _meas_spec(key = :calib)
        latent_e = _meas_spec(
            key = :late,
            role = :validation_only,
            observability = :E,
            methodology = :proxy,
            scope_bias = :indeterminate,
        )
        latent_a = _meas_spec(
            key = :lata,
            role = :diagnostic_only,
            observability = :A,
            methodology = :proxy,
            scope_bias = :indeterminate,
        )
        raw = _meas_raw([
            _meas_obs(calib, _q_series("C", "2010-Q1", collect(1.0:10.0))),
            _meas_obs(latent_e, _q_series("LE", "2010-Q1", collect(1.0:10.0))),
            _meas_obs(latent_a, _q_series("LA", "2010-Q1", collect(1.0:10.0))),
        ])
        ds = build_capex_empirical_dataset(raw; min_valid_obs = 8)
        @test !haskey(ds.values, :late)
        @test !haskey(ds.values, :lata)
        @test !haskey(ds.measurements, :late)
        @test !haskey(ds.measurements, :lata)
        @test ds.roles[:late] == :validation_only
        @test ds.observability[:lata] == :A
        @test Set(ds.quality_flags["latent_keys"]) == Set(["late", "lata"])
    end

    @testset "§12.3-28: dataset identity is independent of input and Dict order" begin
        a = _meas_spec(key = :a)
        b = _meas_spec(key = :b)
        c = _meas_spec(key = :c)
        sa = _q_series("A", "2010-Q1", collect(1.0:12.0))
        sb = _q_series("B", "2010-Q1", collect(2.0:13.0))
        sc = _q_series("C", "2010-Q1", collect(3.0:14.0))
        ds1 = build_capex_empirical_dataset(
            _meas_raw([_meas_obs(a, sa), _meas_obs(b, sb), _meas_obs(c, sc)]);
            min_valid_obs = 8,
        )
        ds2 = build_capex_empirical_dataset(
            _meas_raw([_meas_obs(c, sc), _meas_obs(a, sa), _meas_obs(b, sb)]);
            min_valid_obs = 8,
        )
        # shuffled dates within each source series
        shuffled(s) = DataSeries(
            s.id,
            s.name,
            s.source,
            s.frequency,
            s.unit,
            reverse(s.dates),
            reverse(s.values),
        )
        ds3 = build_capex_empirical_dataset(
            _meas_raw([
                _meas_obs(a, shuffled(sa)),
                _meas_obs(b, shuffled(sb)),
                _meas_obs(c, shuffled(sc)),
            ]);
            min_valid_obs = 8,
        )
        @test ds1.metadata["dataset_hash"] == ds2.metadata["dataset_hash"]
        @test ds1.metadata["dataset_hash"] == ds3.metadata["dataset_hash"]
        @test startswith(ds1.metadata["dataset_hash"], "sha256:")
    end

    @testset "manual sample window overrides the automatic endpoints and records it" begin
        a = _meas_spec(key = :a)
        b = _meas_spec(key = :b)
        raw = _meas_raw([
            _meas_obs(a, _q_series("A", "2010-Q1", collect(1.0:16.0))),
            _meas_obs(b, _q_series("B", "2010-Q1", collect(1.0:16.0))),
        ])
        ds = build_capex_empirical_dataset(
            raw;
            sample_start = "2011-Q1",
            sample_end = "2012-Q4",
            min_valid_obs = 8,
        )
        @test ds.sample.sample_start == "2011-Q1"
        @test ds.sample.sample_end == "2012-Q4"
        @test ds.sample.n_obs == 8
        @test ds.metadata["manual_sample_window"] === true
        @test !isempty(ds.quality_flags["window_overrides"])
    end

    @testset "interior calibration gaps are dropped with a reason, never zero-filled" begin
        a = _meas_spec(key = :a)
        b = _meas_spec(key = :b)
        gapped =
            _q_series("B", "2010-Q1", vcat(collect(1.0:5.0), [missing], collect(7.0:12.0)))
        raw = _meas_raw([
            _meas_obs(a, _q_series("A", "2010-Q1", collect(1.0:12.0))),
            _meas_obs(b, gapped),
        ])
        ds = build_capex_empirical_dataset(raw; min_valid_obs = 8)
        # 2010-Q1..2012-Q4 (12) minus the one quarter where B is missing (2011-Q2)
        @test ds.sample.n_obs == 11
        @test "2011-Q2" in ds.sample.dropped_dates
        @test ds.sample.exclusion_reasons["partial_calibration_coverage"] == 1
        @test !any(ismissing, ds.values[:a])
        @test !any(ismissing, ds.values[:b])   # the gap quarter is excluded from the axis
        @test length(ds.values[:a]) == ds.sample.n_obs
    end

    @testset "dataset_hash ignores retrieved_at, provider location, and transport mode" begin
        a = _meas_spec(key = :a)
        b = _meas_spec(key = :b)
        sa = _q_series("A", "2010-Q1", collect(1.0:12.0))
        sb = _q_series("B", "2010-Q1", collect(2.0:13.0))
        obs_fixture = [_meas_obs(a, sa), _meas_obs(b, sb)]
        obs_rest = [
            CapexRawObservation(
                a.key,
                a,
                :ok,
                sa,
                sa.unit,
                sa.frequency,
                "SA",
                missing,
                String[],
                "2026-09-02T00:00:00.000Z",
                :rest_api,
                "",
            ),
            CapexRawObservation(
                b.key,
                b,
                :ok,
                sb,
                sb.unit,
                sb.frequency,
                "SA",
                missing,
                String[],
                "2026-09-02T09:30:00.000Z",
                :rest_api,
                "",
            ),
        ]
        ds_fixture =
            build_capex_empirical_dataset(_meas_raw(obs_fixture); min_valid_obs = 8)
        raw_rest = CapexRawDataset(
            Dict(o.key => o for o in obs_rest),
            "test-catalog-v1",
            CAPEX_CC_EMPIRICAL_INTEGRATION_VERSION,
            "https://provider.invalid",
            Dict{String, Any}(),
            Dict{String, Any}(),
        )
        ds_rest = build_capex_empirical_dataset(raw_rest; min_valid_obs = 8)
        @test ds_fixture.metadata["dataset_hash"] == ds_rest.metadata["dataset_hash"]
    end

    @testset "a malformed quarterly label becomes a measurement failure, not a crash" begin
        calib = _meas_spec(key = :calib)
        bad = _meas_spec(
            key = :bad,
            role = :validation_only,
            observability = :P,
            methodology = :proxy,
            scope_bias = :indeterminate,
        )
        bad_series = DataSeries(
            "BAD",
            "BAD",
            "TEST",
            Quarterly,
            "test unit",
            ["2010Q1", "2010Q2", "2010Q3"],
            Vector{Union{Float64, Missing}}([1.0, 2.0, 3.0]),
        )
        raw = _meas_raw([
            _meas_obs(calib, _q_series("C", "2010-Q1", collect(1.0:10.0))),
            _meas_obs(bad, bad_series),
        ])
        ds = build_capex_empirical_dataset(raw; min_valid_obs = 8)
        @test !haskey(ds.measurements, :bad)
        @test haskey(ds.quality_flags["measurement_failures"], "bad")
        @test all(ismissing, ds.values[:bad])
    end

    @testset "shipped catalog has no EDP series yet, so the dataset build fails closed" begin
        raw = build_capex_raw_dataset(;
            client = DataProviderClient(
                mode = :fixture,
                fixture_dir = joinpath(@__DIR__, "fixtures", "data", "capex_credit_cycle"),
            ),
        )
        @test all(o -> o.status != :ok, values(raw.observations))
        @test_throws ArgumentError build_capex_empirical_dataset(raw)
    end

    @testset "vintage_mode is fixed to :latest_only and data_vintage defaults to unknown" begin
        a = _meas_spec(key = :a)
        raw = _meas_raw([_meas_obs(a, _q_series("A", "2010-Q1", collect(1.0:10.0)))])
        ds = build_capex_empirical_dataset(raw; min_valid_obs = 8)
        @test ds.vintage_mode == :latest_only
        @test ds.metadata["vintage_mode"] == "latest_only"
        @test ds.metadata["data_vintage"] == "unknown"
    end
end
