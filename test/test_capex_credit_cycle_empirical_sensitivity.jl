# CCC 実証robustness/sensitivity層のテスト（Issue #250 / P-10）。
#
# fixture は test_capex_credit_cycle_historical_replay.jl（#248）と同じ規約（`_hrep_*` に相当する
# 自己完結ヘルパ）だが、本テスト固有の axis を運動させるため独自に prefix `_ces_` を付けて拡張する:
#   - spread に HY（calibration_required・direct）/IG（validation_only・proxy）の2ソースを持たせる
#     （axis :proxy）。
#   - hh_income の観測比較を validation_only の単一 proxy 系列のみで構成する（axis
#     :series_exclusion。calibration_required系列は除外対象にならないことも spread_hy で確認する）。
#   - `magnitude_source = :assumed_default` の assumption を1本持つ episode を使う（axis
#     :event_timing・:event_magnitude）。
#   - `CapexParameterSet.ranges`/`alternate_specs`（W2/W3）を持つ `kind = :estimated` の
#     parameter set を別途組み立てる（axis :parameter_weak_id）。

using DME:
    capex_historical_replay,
    CapexReplayOptions,
    CapexHistoricalReplayRun,
    capex_replay_model,
    CapexHistoricalEpisodeSpec,
    CalendarQuarter,
    capex_credit_cycle_default_targets,
    capex_credit_cycle_model,
    capex_run,
    exogenous_variables,
    parameters,
    CapexCreditCycleOptions,
    build_capex_empirical_dataset,
    calibrate_capex_credit_cycle,
    capex_parameter_set,
    CapexParameterSet,
    CapexIdentificationDiagnostic,
    CapexBlockEstimate,
    CapexBlockEstimateStart,
    CapexEstimationConfig,
    CAPEX_CC_PARAMETER_SET_KINDS,
    CapexSeriesSpec,
    CapexRawObservation,
    CapexRawDataset,
    DataSeries,
    Quarterly,
    CAPEX_CC_EMPIRICAL_INTEGRATION_VERSION,
    ScenarioAssumption,
    EventTiming,
    PersistenceSpec,
    EventProvenance,
    capex_empirical_sensitivity_suite,
    capex_empirical_sensitivity_report_to_dict,
    save_capex_empirical_sensitivity_report,
    EmpiricalRobustnessReport,
    EmpiricalSensitivitySpec,
    EmpiricalSensitivityVariantResult,
    CAPEX_CC_SENSITIVITY_AXES,
    CAPEX_CC_SENSITIVITY_VARIANT_STATUSES,
    CAPEX_CC_SENSITIVITY_STABILITY_DIMENSIONS,
    CAPEX_CC_EMPIRICAL_SENSITIVITY_VERSION

using Test

const JSON3 = DME.JSON3

# ---------------------------------------------------------------------------
# fixture ヘルパ（`_ces_` prefix で自己完結。実 H1–H6 とは無関係）
# ---------------------------------------------------------------------------

# 開始 "2005-Q1"・period_zero 2013Q1（idx 32）・runup 8・eval 20 → window は idx 24–51。
# ±4Q の window shift も idx 20–55 に収まる十分な余白（N=64）を持たせる。
const _CES_N = 64
const _CES_START = "2005-Q1"
const _CES_T_ZERO = 32 # period_zero (2013-Q1) の "2005-Q1" からの相対四半期数
const _CES_POLICY_BUMP = 1.0
const _CES_YS2_AMP = 3.0

function _cesq_dates(start_label::String, n::Int)
    y0, q0 =
        parse(Int, split(start_label, "-Q")[1]), parse(Int, split(start_label, "-Q")[2])
    base = y0 * 4 + (q0 - 1)
    return [string(idx ÷ 4, "-Q", idx % 4 + 1) for idx in base:(base + n - 1)]
end

function _ces_spec(
    key::Symbol;
    model_vars::Vector{Symbol} = [key],
    role::Symbol = :calibration_required,
    methodology::Symbol = :direct,
    observability::Symbol = :D,
    scope_bias::Symbol = :none,
)
    return CapexSeriesSpec(
        key = key,
        model_vars = model_vars,
        provider_series_id = uppercase(string(key)),
        provider = "TEST",
        source_kind = :official_statistic,
        role = role,
        observability = observability,
        methodology = methodology,
        declared_unit = "unit",
        declared_frequency = Quarterly,
        declared_seasonal_adjustment = "SA",
        declared_real_nominal = :real,
        declared_base_year = nothing,
        annualized = false,
        level_form = :level,
        anchor = nothing,
        sector_scope = "test scope",
        scope_bias = scope_bias,
        aggregation = :sum,
        model_timing = :SUM,
        allocation_key = nothing,
        availability_start = "2000-Q1",
        notes = "empirical sensitivity fixture entry",
    )
end

_ces_series(key::Symbol, values::AbstractVector, dates::Vector{String}) = DataSeries(
    uppercase(string(key)),
    string(key),
    "TEST",
    Quarterly,
    "unit",
    dates,
    Vector{Union{Float64, Missing}}(values),
)

_ces_obs(spec::CapexSeriesSpec, series::DataSeries) = CapexRawObservation(
    spec.key,
    spec,
    :ok,
    series,
    "unit",
    Quarterly,
    "SA",
    missing,
    String[],
    nothing,
    :fixture,
    "",
)

# `spread` に HY（calibration_required・direct）/IG（validation_only・proxy）の2ソース、
# `hh_income` に validation_only の単一 proxy を持たせた catalog 拡張。
function _ces_extra_specs()
    return Dict{Symbol, CapexSeriesSpec}(
        :spread_hy => _ces_spec(
            :spread_hy;
            model_vars = [:spread],
            role = :calibration_required,
            methodology = :direct,
        ),
        :spread_ig => _ces_spec(
            :spread_ig;
            model_vars = [:spread],
            role = :validation_only,
            methodology = :proxy,
            observability = :P,
            scope_bias = :indeterminate,
        ),
        :hh_income_proxy => _ces_spec(
            :hh_income_proxy;
            model_vars = [:hh_income],
            role = :validation_only,
            methodology = :proxy,
            observability = :P,
            scope_bias = :over,
        ),
    )
end

function _ces_dataset(entries::AbstractDict; start::String = _CES_START)
    n = length(first(values(entries)))
    dates = _cesq_dates(start, n)
    extra = _ces_extra_specs()
    obs = CapexRawObservation[]
    for (k, vals) in entries
        spec = get(extra, k, _ces_spec(k))
        push!(obs, _ces_obs(spec, _ces_series(k, vals, dates)))
    end
    raw = CapexRawDataset(
        Dict(o.key => o for o in obs),
        "test-catalog-v1",
        CAPEX_CC_EMPIRICAL_INTEGRATION_VERSION,
        "",
        Dict{String, Any}(),
        Dict{String, Any}(),
    )
    return build_capex_empirical_dataset(raw; min_valid_obs = 8)
end

function _ces_fixture_entries(; n::Int = _CES_N, t_zero::Int = _CES_T_ZERO)
    b = capex_credit_cycle_default_targets().values
    flat(v) = Vector{Union{Float64, Missing}}(fill(Float64(v), n))
    policy_rate = Vector{Union{Float64, Missing}}(
        Float64[
            t >= t_zero ? b.policy_rate + _CES_POLICY_BUMP * sinpi((t - t_zero) / 5.0) :
            b.policy_rate for t in 0:(n - 1)
        ],
    )
    y_s2 = Vector{Union{Float64, Missing}}(
        Float64[
            t >= t_zero ? b.y_s2 + _CES_YS2_AMP * sinpi((t - t_zero) / 6.0) : b.y_s2 for
            t in 0:(n - 1)
        ],
    )
    order_s2_flat = b.y_s2 - b.order_cap_s2 - b.ext_demand_s2
    order_s3_flat = b.y_s3 - b.order_cap_s3 - b.order_inv_s3 - b.ext_demand_s3
    entries = Dict{Symbol, Vector{Union{Float64, Missing}}}(
        :y_s1 => flat(b.y_s1),
        :y_s2 => y_s2,
        :y_s3 => flat(b.y_s3),
        :y_tot => flat(b.y_s5 + b.va_s1 + b.va_s2 + b.va_s3),
        :util_s2 => flat(b.util_s2),
        :util_s3 => flat(b.util_s3),
        :emp_s1 => flat(b.emp_s1),
        :emp_s2 => flat(b.emp_s2),
        :emp_s3 => flat(b.emp_s3),
        :emp_tot => flat(b.emp_s5 + b.emp_s1 + b.emp_s2 + b.emp_s3),
        :cap_s1 => flat(b.cap_s1),
        :cap_s2 => flat(b.cap_s2),
        :cap_s3 => flat(b.cap_s3),
        :dep_s1 => flat(b.dep_s1),
        :dep_s2 => flat(b.dep_s2),
        :dep_s3 => flat(b.dep_s3),
        :order_cap_s2 => flat(b.order_cap_s2),
        :order_cap_s3 => flat(b.order_cap_s3),
        :order_inv_s3 => flat(b.order_inv_s3),
        :order_s2 => flat(order_s2_flat),
        :order_s3 => flat(order_s3_flat),
        :backlog_s2 => flat(b.backlog_s2),
        :backlog_s3 => flat(b.backlog_s3),
        :inv_s2 => flat(b.inv_s2),
        :inv_s3 => flat(b.inv_s3),
        :va_s1 => flat(b.va_s1),
        :va_s2 => flat(b.va_s2),
        :va_s3 => flat(b.va_s3),
        :wagebill_s1 => flat(b.wagebill_s1),
        :wagebill_s2 => flat(b.wagebill_s2),
        :wagebill_s3 => flat(b.wagebill_s3),
        :wagebill_tot =>
            flat(b.wagebill_s5 + b.wagebill_s1 + b.wagebill_s2 + b.wagebill_s3),
        :spread_hy => flat(b.spread),
        :spread_ig => flat(b.spread * 0.6),
        :policy_rate => policy_rate,
        :cons => flat(b.cons),
        :debt_s1 => flat(b.debt_s1),
        :debt_s2 => flat(b.debt_s2),
        :debt_s3 => flat(b.debt_s3),
        :cash_s1 => flat(b.cash_s1),
        :cash_s2 => flat(b.cash_s2),
        :cash_s3 => flat(b.cash_s3),
        :capex_exec_s1 => flat(b.dep_s1),
        :hh_income_proxy =>
            flat(b.wagebill_s5 + b.wagebill_s1 + b.wagebill_s2 + b.wagebill_s3),
    )
    return entries, b
end

function _ces_calibration(entries::AbstractDict, b::NamedTuple; start::String = _CES_START)
    ds = _ces_dataset(entries; start = start)
    cal = calibrate_capex_credit_cycle(
        ds;
        baseline_start = start,
        baseline_end = _cesq_dates(start, 12)[end],
        literature = (
            cost_capital_intercept_s1 = b.cost_capital_s1 - b.spread / 100,
            cost_capital_intercept_s2 = b.cost_capital_s2 - b.spread / 100,
            cost_capital_intercept_s3 = b.cost_capital_s3 - b.spread / 100,
        ),
        assumptions = (cons_s1 = b.cons_s1,),
    )
    return ds, cal
end

"""
`start`（`YYYY-Qn` 形式）から `t_zero` 四半期後の `CalendarQuarter` を返す。`_ces_setup` が
`t_zero`（`_ces_fixture_entries` の摂動開始点）と episode の `period_zero` を一致させるために使う
（一致させないと baseline 自体が window 外になり `:rejected_input` になる）。
"""
function _ces_period_zero(start::String, t_zero::Int)::CalendarQuarter
    y0, q0 = parse(Int, split(start, "-Q")[1]), parse(Int, split(start, "-Q")[2])
    abs_idx = y0 * 4 + (q0 - 1) + t_zero
    return CalendarQuarter(fld(abs_idx, 4), mod(abs_idx, 4) + 1)
end

function _ces_episode(;
    assumptions::Vector{ScenarioAssumption} = ScenarioAssumption[],
    in_sample::Bool = true,
    period_zero::CalendarQuarter = _ces_period_zero(_CES_START, _CES_T_ZERO),
)
    return CapexHistoricalEpisodeSpec(;
        id = :H1,
        label = "sensitivity test episode",
        period_zero = period_zero,
        runup_quarters = 8,
        eval_quarters = 20,
        assumptions = assumptions,
        in_sample = in_sample,
        notes = "test_capex_credit_cycle_empirical_sensitivity.jl の合成 episode（実 H1 とは無関係）",
    )
end

_ces_provenance() = EventProvenance(;
    layer = :assumption,
    rule_id = "test-empirical-sensitivity-rule",
    rule_version = "1.0.0",
    generator = "test_capex_credit_cycle_empirical_sensitivity.jl",
    derived_from = ["fictional-source-1"],
)

_ces_timing(t_apply::Int) =
    EventTiming(; basis = :period, rule = :explicit_period, t_apply = t_apply)

_ces_persistence() = PersistenceSpec(; shape = :step, duration = 4, params = NamedTuple())

# H6-SA1（実 episode、capex_credit_cycle_history.jl）と同じ event_type/sector/direction/
# magnitude_source を用いる assumed_default assumption。
function _ces_assumed_default_assumption()
    return ScenarioAssumption(;
        assumption_id = "ces-sa1",
        event_type = :DemandOutlookRevision,
        sector = :s2,
        direction = :down,
        magnitude = -10.0,
        unit = "%",
        magnitude_source = :assumed_default,
        application_mode = :multiplicative,
        timing = _ces_timing(0),
        persistence = _ces_persistence(),
        target_concepts = [:demand_expectation],
        provenance = _ces_provenance(),
        notes = "assumed_default event magnitude 感応度のテスト用（実データに基づかない合成仮定）",
    )
end

function _ces_setup(;
    kind::Symbol = :calibrated,
    n::Int = _CES_N,
    t_zero::Int = _CES_T_ZERO,
)
    entries, b = _ces_fixture_entries(; n = n, t_zero = t_zero)
    ds, cal = _ces_calibration(entries, b)
    ps = capex_parameter_set(cal, CapexIdentificationDiagnostic[]; kind = kind)
    m = capex_replay_model(cal, ps; kind = kind)
    ep = _ces_episode(;
        assumptions = [_ces_assumed_default_assumption()],
        period_zero = _ces_period_zero(_CES_START, t_zero),
    )
    return (; ds, cal, ps, m, ep, b)
end

# W2 範囲報告（`bh_cc_elas_s1`）・W3 複数仕様（`bh_alpha_capex_s1`）を持つ `CapexBlockEstimate`。
# 点推定は一切返さず全面降格した状態（`status = :demoted`）として、axis :parameter_weak_id が
# `ps.ranges`/`ps.alternate_specs` だけから variant を作れることを確認する。
function _ces_weak_id_block_estimate()
    return CapexBlockEstimate(
        :EB5,
        5,
        :demoted,
        String[],
        Dict{Symbol, Float64}(),
        Dict{Symbol, Tuple{Float64, Float64}}(:bh_cc_elas_s1 => (0.5, 3.0)),
        Dict{Symbol, Dict{String, Float64}}(
            :bh_alpha_capex_s1 => Dict("const" => 0.2, "compute_dem" => 0.3),
        ),
        Dict{Symbol, Symbol}(:bh_cc_elas_s1 => :W2, :bh_alpha_capex_s1 => :W3),
        Dict{Symbol, Tuple{Float64, Float64}}(
            :bh_cc_elas_s1 => (0.0, 20.0),
            :bh_alpha_capex_s1 => (1e-6, 1.0),
        ),
        Dict{Symbol, Float64}(),
        NaN,
        Dict{String, Float64}(),
        NaN,
        Symbol[],
        String[],
        Dict{Symbol, Float64}(),
        0,
        0,
        String[],
        Dict{String, Float64}(),
        false,
        0,
        0,
        CapexBlockEstimateStart[],
        false,
        :weakly_identified,
        String["test fixture: 全パラメータをW2/W3へ事前固定"],
        String[],
        CapexEstimationConfig(),
        "sha256:test-block-spec",
        Dict{String, Any}(),
    )
end

function _ces_setup_estimated()
    entries, b = _ces_fixture_entries()
    ds, cal = _ces_calibration(entries, b)
    ps = capex_parameter_set(
        cal,
        CapexIdentificationDiagnostic[],
        [_ces_weak_id_block_estimate()];
        kind = :estimated,
    )
    m = capex_replay_model(cal, ps; kind = :estimated)
    ep = _ces_episode(; assumptions = [_ces_assumed_default_assumption()])
    return (; ds, cal, ps, m, ep, b)
end

# ---------------------------------------------------------------------------

@testset "CCC 実証robustness/sensitivity層（Issue #250 / P-10）" begin
    @testset "smoke test: 7 axis を持つ EmpiricalRobustnessReport を返す" begin
        setup = _ces_setup()
        report = capex_empirical_sensitivity_suite(setup.m, setup.ep, setup.ds, setup.ps)

        @test report isa EmpiricalRobustnessReport
        @test report.episode === :H1
        @test report.parameter_set_kind === :calibrated
        @test Set(keys(report.axis_status)) == Set(CAPEX_CC_SENSITIVITY_AXES)
        @test Set(keys(report.variants)) == Set(CAPEX_CC_SENSITIVITY_AXES)

        @test report.axis_status[:proxy].status === :available
        @test report.axis_status[:proxy].n_variants == 2
        @test report.axis_status[:series_exclusion].status === :available
        @test report.axis_status[:event_timing].status === :available
        @test report.axis_status[:event_timing].n_variants == 2
        @test report.axis_status[:event_magnitude].status === :available
        @test report.axis_status[:event_magnitude].n_variants == 2
        @test report.axis_status[:diagnostic_threshold].status === :available
        @test report.axis_status[:diagnostic_threshold].n_variants == 16
        @test report.axis_status[:sample_window].status === :available
        @test report.axis_status[:sample_window].n_variants == 4

        # kind = :calibrated では ps.ranges/alternate_specs が空 → variant を生成できない
        @test report.axis_status[:parameter_weak_id].status === :unavailable
        @test report.axis_status[:parameter_weak_id].n_variants == 0
        @test report.axis_status[:parameter_weak_id].unavailable_reason !== nothing
    end

    @testset "axis :proxy は spread の HY/IG を単独採用した2 variantを生成する" begin
        setup = _ces_setup()
        report = capex_empirical_sensitivity_suite(setup.m, setup.ep, setup.ds, setup.ps)
        proxy_variants = report.variants[:proxy]

        @test length(proxy_variants) == 2
        ids = Set(v.spec.id for v in proxy_variants)
        @test ids == Set(["proxy_spread_only_spread_hy", "proxy_spread_only_spread_ig"])
        @test all(v -> v.status === :evaluated, proxy_variants)

        hy_variant =
            only(v for v in proxy_variants if v.spec.id == "proxy_spread_only_spread_hy")
        ig_variant =
            only(v for v in proxy_variants if v.spec.id == "proxy_spread_only_spread_ig")
        # 単独採用したソースの methodology が evidence_tier に反映される（direct vs proxy）。
        @test hy_variant.report.fits[:spread].evidence_tier === :direct
        @test ig_variant.report.fits[:spread].evidence_tier === :proxy
    end

    @testset "axis :series_exclusion は calibration_required 系列を除外しない" begin
        setup = _ces_setup()
        report = capex_empirical_sensitivity_suite(setup.m, setup.ep, setup.ds, setup.ps)
        excl_variants = report.variants[:series_exclusion]

        @test !isempty(excl_variants)
        @test all(v -> v.spec.metadata["excluded_key"] != "spread_hy", excl_variants)
        @test any(v -> v.spec.metadata["excluded_key"] == "hh_income_proxy", excl_variants)
        @test any(v -> v.spec.metadata["role"] == "validation_only", excl_variants)
        @test all(v -> v.status === :evaluated, excl_variants)
    end

    @testset "axis :event_timing / :event_magnitude は assumed_default のみを動かす" begin
        setup = _ces_setup()
        report = capex_empirical_sensitivity_suite(setup.m, setup.ep, setup.ds, setup.ps)

        timing_variants = report.variants[:event_timing]
        @test length(timing_variants) == 2
        @test Set(v.spec.id for v in timing_variants) ==
              Set(["event_timing_shift_-1", "event_timing_shift_1"])
        @test all(v -> v.status === :evaluated, timing_variants)

        magnitude_variants = report.variants[:event_magnitude]
        @test length(magnitude_variants) == 2
        @test all(v -> v.status === :evaluated, magnitude_variants)
        @test all(
            v -> occursin("scenario assumption sensitivity", v.spec.description),
            magnitude_variants,
        )

        # assumptions が無い episode では両 axis とも空になる（対象がない、という明示的な状態）。
        ep_no_assumptions = _ces_episode()
        report_no_assumptions = capex_empirical_sensitivity_suite(
            setup.m,
            ep_no_assumptions,
            setup.ds,
            setup.ps,
        )
        @test report_no_assumptions.axis_status[:event_timing].status === :unavailable
        @test report_no_assumptions.axis_status[:event_magnitude].status === :unavailable
    end

    @testset "axis :parameter_weak_id はW2範囲・W3複数仕様のvariantを生成する" begin
        setup = _ces_setup_estimated()
        report = capex_empirical_sensitivity_suite(setup.m, setup.ep, setup.ds, setup.ps)
        weak_id_variants = report.variants[:parameter_weak_id]

        @test length(weak_id_variants) == 4
        ids = Set(v.spec.id for v in weak_id_variants)
        @test ids == Set([
            "weak_id_range_bh_cc_elas_s1_lo",
            "weak_id_range_bh_cc_elas_s1_hi",
            "weak_id_altspec_bh_alpha_capex_s1_const",
            "weak_id_altspec_bh_alpha_capex_s1_compute_dem",
        ])
        @test all(v -> v.status === :evaluated, weak_id_variants)
        @test report.axis_status[:parameter_weak_id].status === :available
    end

    @testset "axis :diagnostic_threshold は capex_label_sensitivity を再利用する" begin
        setup = _ces_setup()
        report = capex_empirical_sensitivity_suite(setup.m, setup.ep, setup.ds, setup.ps)
        threshold_variants = report.variants[:diagnostic_threshold]

        @test length(threshold_variants) == 16
        @test all(v -> v.status === :evaluated, threshold_variants)
        @test all(v -> v.report === nothing, threshold_variants)
        @test all(v -> v.stability[:onset_order] === nothing, threshold_variants)
        @test all(v -> v.stability[:credit_amplification] === nothing, threshold_variants)
        @test all(v -> v.stability[:diagnostic_label] isa Bool, threshold_variants)
    end

    @testset "失敗したvariantを除外せずfailure_reasonとともに保持する（sample_window境界）" begin
        # historical_replay と同じ狭い window（N=32、period_zero idx 12）。窓を+方向へ
        # ずらすと dataset の末尾を超え rejected_input になる。
        setup = _ces_setup(; n = 32, t_zero = 12)
        report = capex_empirical_sensitivity_suite(setup.m, setup.ep, setup.ds, setup.ps)
        window_variants = report.variants[:sample_window]

        @test length(window_variants) == 4
        failed = [v for v in window_variants if v.status === :failed]
        @test !isempty(failed)
        @test all(v -> v.failure_reason !== nothing, failed)
        @test all(v -> v.report === nothing, failed)
        @test report.axis_status[:sample_window].status === :partially_available
        @test report.axis_status[:sample_window].n_failed == length(failed)
        @test report.axis_status[:sample_window].n_variants == 4
    end

    @testset "baseline が rejected_input のとき全 axis を :unavailable にする（fail closed）" begin
        entries, b = _ces_fixture_entries()
        entries_gap = Dict{Symbol, Vector{Union{Float64, Missing}}}(
            k => copy(v) for (k, v) in entries
        )
        # 評価区間内の order_cap_s2 を欠損させ baseline replay 自体を rejected_input にする。
        entries_gap[:order_cap_s2][_CES_T_ZERO + 5] = missing
        ds_gap, cal_gap = _ces_calibration(entries_gap, b)
        ps_gap = capex_parameter_set(
            cal_gap,
            CapexIdentificationDiagnostic[];
            kind = :calibrated,
        )
        m_gap = capex_replay_model(cal_gap, ps_gap)
        ep = _ces_episode()

        report = capex_empirical_sensitivity_suite(m_gap, ep, ds_gap, ps_gap)
        @test all(status.status === :unavailable for status in values(report.axis_status))
        @test all(isempty(vs) for vs in values(report.variants))
        @test any(occursin("rejected_input", w) for w in report.warnings)
    end

    @testset "安定性は axis×dimension 別に分離される（総合スコアを作らない）" begin
        setup = _ces_setup()
        report = capex_empirical_sensitivity_suite(setup.m, setup.ep, setup.ds, setup.ps)

        @test !haskey(report.metadata, "overall_score")
        for axis in CAPEX_CC_SENSITIVITY_AXES
            @test haskey(report.stability_summary, axis)
            @test Set(keys(report.stability_summary[axis])) ==
                  Set(CAPEX_CC_SENSITIVITY_STABILITY_DIMENSIONS)
            for dim_summary in values(report.stability_summary[axis])
                @test dim_summary.n_applicable ==
                      dim_summary.n_stable + dim_summary.n_unstable
            end
        end
        @test report.label_boundary_variants isa Vector{String}
    end

    @testset "決定的再実行（同一spec/configから同一variant setとreportを生成する）" begin
        setup = _ces_setup()
        report1 = capex_empirical_sensitivity_suite(setup.m, setup.ep, setup.ds, setup.ps)
        report2 = capex_empirical_sensitivity_suite(setup.m, setup.ep, setup.ds, setup.ps)

        for axis in CAPEX_CC_SENSITIVITY_AXES
            ids1 = [v.spec.id for v in report1.variants[axis]]
            ids2 = [v.spec.id for v in report2.variants[axis]]
            @test ids1 == ids2
            statuses1 = [v.status for v in report1.variants[axis]]
            statuses2 = [v.status for v in report2.variants[axis]]
            @test statuses1 == statuses2
        end
        d1 = capex_empirical_sensitivity_report_to_dict(report1)
        d2 = capex_empirical_sensitivity_report_to_dict(report2)
        @test d1["baseline_report"] == d2["baseline_report"]
    end

    @testset "capex_empirical_sensitivity_report_to_dict / save の往復" begin
        setup = _ces_setup()
        report = capex_empirical_sensitivity_suite(setup.m, setup.ep, setup.ds, setup.ps)
        d = capex_empirical_sensitivity_report_to_dict(report)

        @test d["sensitivity_version"] == CAPEX_CC_EMPIRICAL_SENSITIVITY_VERSION
        @test haskey(d, "baseline_report")
        @test haskey(d, "variants")
        @test haskey(d, "axis_status")
        @test haskey(d, "stability_summary")
        @test haskey(d, "label_boundary_variants")
        @test haskey(d, "warnings")
        @test haskey(d, "caveats")
        @test !haskey(d, "overall_score")
        @test !isempty(d["caveats"])

        mktempdir() do dir
            path = joinpath(dir, "sensitivity.json")
            save_capex_empirical_sensitivity_report(path, report)
            @test isfile(path)
            parsed = JSON3.read(read(path, String))
            @test parsed.sensitivity_version == CAPEX_CC_EMPIRICAL_SENSITIVITY_VERSION
        end
    end
end
