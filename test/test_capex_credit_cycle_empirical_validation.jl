# CCC 履歴再生の dimension 別検証（Issue #249 / P-9）。
#
# 小さな人工 run を直接組み立てる。ここで検証するのはモデル方程式の水準ではなく、
# validation 層が (a) baseline 比乖離を使うこと、(b) 各 dimension を単一 score に
# 縮約しないこと、(c) proxy / latent / terminated を安全に扱うことである。

using DME
using Test

function _ccv_dates(n::Int)
    return ["2010-Q$(mod(i - 1, 4) + 1)" for i in 1:n]
end

function _ccv_proxy_spec()
    return CapexSeriesSpec(
        key = :hh_income_proxy,
        model_vars = [:hh_income],
        provider_series_id = "TEST_HH_INCOME_PROXY",
        provider = "TEST",
        source_kind = :official_statistic,
        role = :validation_only,
        observability = :P,
        methodology = :proxy,
        declared_unit = "unit",
        declared_frequency = Quarterly,
        declared_seasonal_adjustment = "SA",
        declared_real_nominal = :real,
        level_form = :level,
        sector_scope = "test proxy",
        scope_bias = :over,
        aggregation = :sum,
        model_timing = :SUM,
        notes = "validation-only proxy fixture",
    )
end

function _ccv_dataset(hash::String, n::Int)
    dates = _ccv_dates(n)
    spec = _ccv_proxy_spec()
    values = Vector{Union{Float64, Missing}}(fill(1.0, n))
    series = DataSeries(
        "TEST_HH_INCOME_PROXY",
        "proxy",
        "TEST",
        Quarterly,
        "unit",
        dates,
        values,
    )
    measurement = CapexMeasurement(
        spec.key,
        spec,
        Pair{String, DataSeries}["measured" => series],
        series,
        "fixture",
        nothing,
        nothing,
        nothing,
        nothing,
        0,
        0,
        String[],
    )
    raw = CapexRawDataset(
        Dict{Symbol, CapexRawObservation}(),
        "test-catalog",
        CAPEX_CC_EMPIRICAL_INTEGRATION_VERSION,
        "",
        Dict{String, Any}(),
        Dict{String, Any}(),
    )
    return CapexEmpiricalDataset(
        [spec],
        Dict(spec.key => measurement),
        dates,
        Float64.(1:n),
        Dict(spec.key => values),
        Dict(spec.key => :validation_only),
        Dict(spec.key => :P),
        CapexSampleWindow(
            first(dates),
            last(dates),
            n,
            Symbol[],
            String[],
            Dict{String, Int}(),
        ),
        :latest_only,
        Dict{String, Any}(),
        raw,
        Dict("dataset_hash" => hash),
    )
end

function _ccv_parameter_set(hash::String; kind::Symbol = :calibrated)
    return CapexParameterSet(
        CAPEX_CC_ESTIMATION_VERSION,
        kind,
        hash,
        "sha256:targets",
        "sha256:identification",
        Dict{Symbol, Float64}(),
        Dict{Symbol, Float64}(),
        Dict{Symbol, Float64}(),
        Dict{Symbol, Tuple{Float64, Float64}}(),
        Dict{Symbol, Dict{String, Float64}}(),
        Dict{Symbol, Symbol}(),
        Dict(:bh_fc_pol => :demoted_W2),
        CapexBlockEstimate[],
        CapexEstimationConfig(),
        "sha256:parameter-$(kind)",
        String[],
        Dict{String, Any}(),
    )
end

function _ccv_replace_series(run::CapexCreditCycleRun, series::NamedTuple)
    return CapexCreditCycleRun(
        run.model_name,
        run.scenario,
        series,
        run.exog,
        run.periods,
        run.state0,
        run.warnings,
        run.termination_reason,
        run.termination_period,
        run.divergence_time,
        run.binding,
        run.accounting,
        run.diagnostics,
        run.options,
        run.metadata,
    )
end

function _ccv_run(
    model::CapexCreditCycleModel,
    model_run::CapexCreditCycleRun,
    ds::CapexEmpiricalDataset,
    observed::Dict{Symbol, Vector{Union{Float64, Missing}}};
    kind::Symbol = :calibrated,
    status::Symbol = :completed,
    in_sample::Bool = true,
)
    ep = CapexHistoricalEpisodeSpec(
        id = :H1,
        label = "validation fixture",
        period_zero = CalendarQuarter(2012, 1),
        runup_quarters = 8,
        eval_quarters = 20,
        in_sample = in_sample,
        notes = "synthetic validation fixture",
    )
    ps = _ccv_parameter_set(ds.metadata["dataset_hash"]; kind = kind)
    return CapexHistoricalReplayRun(
        status,
        ep,
        ps,
        model,
        model_run.exog,
        EventLogEntry[],
        AppliedModelInput[],
        EventRejection[],
        model_run,
        to_simulation_result(model, model_run, "H1"),
        observed,
        in_sample,
        ds.metadata["dataset_hash"],
        ps.parameter_set_hash,
        "sha256:episode",
        "sha256:events",
        "sha256:replay-$(kind)-$(status)",
        String[],
        Dict{String, Any}(),
    )
end

function _ccv_fixture()
    model = capex_credit_cycle_model(capex_credit_cycle_default_targets())
    baseline = DME._ccc_baseline_exog(model, 28)
    model_run =
        capex_run(model; exog = baseline, validate_accounting = false, diagnostics = false)
    ds = _ccv_dataset("sha256:validation-dataset", length(model_run.periods))
    base_y = sum(model_run.series.y_tot[1:8]) / 8
    deviations =
        Float64[0, -5, -10, -5, 0, -5, -10, -5, 0, -4, -8, -4, 0, -3, -6, -3, 0, 0, 0, 0]
    model_y = vcat(fill(base_y, 8), base_y .+ deviations)
    changed_series = merge(model_run.series, (y_tot = model_y,))
    changed_run = _ccv_replace_series(model_run, changed_series)
    observed = Dict{Symbol, Vector{Union{Float64, Missing}}}(
        :y_tot => Vector{Union{Float64, Missing}}(model_y),
        :hh_income => Vector{Union{Float64, Missing}}(changed_run.series.hh_income),
        :ai_exp => Vector{Union{Float64, Missing}}(changed_run.series.ai_exp),
    )
    return (; model, changed_run, ds, observed, base_y)
end

@testset "CCC empirical validation（Issue #249 / P-9）" begin
    @testset "fit・turning point・timing・direction を分離する" begin
        fixture = _ccv_fixture()
        report = validate_capex_empirical(
            _ccv_run(fixture.model, fixture.changed_run, fixture.ds, fixture.observed),
            fixture.ds,
        )

        @test report.fits[:y_tot].applicability === :applicable
        @test report.fits[:y_tot].rmse ≈ 0.0
        @test report.fits[:y_tot].mae ≈ 0.0
        @test report.direction_agreement[:y_tot] ≈ 1.0
        @test report.turning_points[:y_tot].model_peak_count >= 2
        @test report.turning_points[:y_tot].peak_timing_error ≈ 0.0
        @test report.dimension_status[:numerical_fit].status in CAPEX_CC_VALIDATION_STATUSES
        @test report.metadata["turning_point_rule_version"] ==
              DME.SCENARIO_TURNING_POINT_RULE_VERSION
        @test !haskey(report.metadata, "official_recession_agreement")

        # evaluation 期間だけの level shift は fit を悪化させる。
        shifted = copy(fixture.observed)
        shifted[:y_tot] = Union{Float64, Missing}[
            v + (i > 8 ? 4.0 : 0.0) for (i, v) in enumerate(fixture.observed[:y_tot])
        ]
        level_report = validate_capex_empirical(
            _ccv_run(fixture.model, fixture.changed_run, fixture.ds, shifted),
            fixture.ds,
        )
        @test level_report.fits[:y_tot].rmse ≈ 4.0

        # onset が 1 期遅れた観測を与えると、lead/lag は別 field に残る。
        delayed = copy(fixture.observed)
        delayed_values = copy(fixture.observed[:y_tot])
        delayed_values[9:end] =
            vcat([fixture.base_y], fixture.observed[:y_tot][9:(end - 1)])
        delayed[:y_tot] = delayed_values
        timing_report = validate_capex_empirical(
            _ccv_run(fixture.model, fixture.changed_run, fixture.ds, delayed),
            fixture.ds,
        )
        @test timing_report.turning_points[:y_tot].onset_lead_lag == -1

        reversed = copy(fixture.observed)
        reversed[:y_tot] = Union{Float64, Missing}[
            i <= 8 ? fixture.base_y : 2 * fixture.base_y - value for
            (i, value) in enumerate(fixture.observed[:y_tot])
        ]
        direction_report = validate_capex_empirical(
            _ccv_run(fixture.model, fixture.changed_run, fixture.ds, reversed),
            fixture.ds,
        )
        @test direction_report.direction_agreement[:y_tot] < 1.0
    end

    @testset "proxy・latent・terminated を 0 補完せず扱う" begin
        fixture = _ccv_fixture()
        report = validate_capex_empirical(
            _ccv_run(fixture.model, fixture.changed_run, fixture.ds, fixture.observed),
            fixture.ds,
        )
        @test report.fits[:hh_income].applicability === :not_applicable_role
        @test report.fits[:hh_income].evidence_tier === :proxy
        @test report.fits[:hh_income].rmse === nothing
        @test report.fits[:ai_exp].applicability === :not_applicable_latent
        @test report.fits[:ai_exp].rmse === nothing

        terminated_options = CapexCreditCycleOptions(; guard_max = 5.0)
        terminated = capex_run(
            fixture.model;
            exog = DME._ccc_baseline_exog(fixture.model, 28),
            options = terminated_options,
            validate_accounting = false,
            diagnostics = false,
        )
        terminated_observed = Dict{Symbol, Vector{Union{Float64, Missing}}}(
            :y_tot => Vector{Union{Float64, Missing}}(
                replace(terminated.series.y_tot, NaN => fixture.base_y),
            ),
        )
        terminated_report = validate_capex_empirical(
            _ccv_run(
                fixture.model,
                terminated,
                fixture.ds,
                terminated_observed;
                status = :terminated,
            ),
            fixture.ds,
        )
        @test terminated_report.fits[:y_tot].n_excluded > 0
        @test any(
            occursin("0 補完しない", warning) for warning in terminated_report.warnings
        )
    end

    @testset "parameter kind・credit-off・machine-readable report" begin
        fixture = _ccv_fixture()
        calibrated = validate_capex_empirical(
            _ccv_run(
                fixture.model,
                fixture.changed_run,
                fixture.ds,
                fixture.observed;
                kind = :calibrated,
            ),
            fixture.ds,
        )
        literature = validate_capex_empirical(
            _ccv_run(
                fixture.model,
                fixture.changed_run,
                fixture.ds,
                fixture.observed;
                kind = :literature_default,
                in_sample = false,
            ),
            fixture.ds,
        )
        @test calibrated.parameter_set_kind === :calibrated
        @test literature.parameter_set_kind === :literature_default
        @test literature.in_sample === false
        @test fieldnames(typeof(calibrated)) == fieldnames(typeof(literature))

        # 信用増幅は観測からではなく、既存 credit-off 反実仮想の定義だけを参照する。
        @test !haskey(calibrated.credit_amplification, "observed_amplification")
        @test occursin("credit_off", calibrated.metadata["credit_amplification_definition"])

        # A=1 は full と credit-off の peak に差がないケース、A≠1 は差が生じるケース。
        # どちらも観測から A を作らず、同じ `capex_counterfactual(:credit_off)` 定義を
        # 内部で再利用した report を確認する。
        function credit_report(shock::Float64)
            exog = DME._ccc_baseline_exog(fixture.model, 28)
            exog[:ai_exp][9] += shock
            credit_run = capex_run(
                fixture.model;
                exog = exog,
                validate_accounting = false,
                diagnostics = false,
            )
            credit_observed = Dict{Symbol, Vector{Union{Float64, Missing}}}(
                :y_tot => Vector{Union{Float64, Missing}}(credit_run.series.y_tot),
                :hh_income =>
                    Vector{Union{Float64, Missing}}(credit_run.series.hh_income),
                :ai_exp => Vector{Union{Float64, Missing}}(credit_run.series.ai_exp),
            )
            return validate_capex_empirical(
                _ccv_run(fixture.model, credit_run, fixture.ds, credit_observed),
                fixture.ds,
            )
        end
        credit_off_equal = credit_report(0.1)
        credit_off_differs = credit_report(10.0)
        @test credit_off_equal.credit_amplification["A_credit_off"] ≈ 1.0
        @test abs(credit_off_differs.credit_amplification["A_credit_off"] - 1.0) > 1e-6

        artifact = capex_empirical_validation_report_to_dict(calibrated)
        @test haskey(artifact, "dimension_status")
        @test haskey(artifact, "propagation")
        @test !haskey(artifact, "overall_score")
        mktempdir() do dir
            path = joinpath(dir, "validation.json")
            save_capex_empirical_validation_report(path, calibrated)
            @test isfile(path)
        end
    end
end
