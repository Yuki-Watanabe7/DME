# CCC 履歴再生実行層の契約テスト（Issue #248 / P-8）。
# 受け入れ条件は docs/architecture/capex_credit_cycle_empirical_integration.md §12.6
# （項目 52–55・59・60。項目 56–58 は P-9/P-10 の対象であり本ファイルの対象外）と
# Issue #248 本文の「テスト」節。
#
# fixture は独自の合成 episode（`:H1` id を再利用するが `CAPEX_CC_EPISODE_SPECS` の実 episode
# とは無関係）で完結させ、実 `H1`–`H6` に対する `assess_capex_episodes` は呼ばない
# （#248 は #247 が選定した episode の *実行* を担当し、選定ロジックには触れない）。
#
# 対応する §12.6 項目:
# - 52: 助走区間の外生が定常値に固定され、`exog_runup_mode` が記録される
#       → 「正常episode: baseline再構成」
# - 53: 内生変数へ観測値を上書きする経路が無い（外生は7変数のみ）
#       → 「正常episode: baseline再構成」（`run.exog` のキー集合検査）
# - 54: `:literature_default` と `:calibrated` が同一 episode / 入力で別 run として比較できる
#       → 「literature_default 対 calibrated」
# - 55: 打ち切り run で有効区間のみ評価され、残りが `0` 補完されない
#       → 「打ち切りrun」
# - 59: fixture モードで catalog→…→replay を公開APIのみで完走する
#       → 「smoke test」
# - 60: 2回実行で canonical artifact と主要数値が一致する
#       → 「決定的再実行」

using DME:
    capex_historical_replay,
    CapexReplayOptions,
    CapexHistoricalReplayRun,
    CAPEX_CC_HISTORICAL_REPLAY_VERSION,
    CAPEX_CC_REPLAY_STATUSES,
    capex_replay_model,
    capex_historical_replay_run_to_dict,
    save_capex_historical_replay_run,
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
    EventProvenance

const JSON3 = DME.JSON3

# ---------------------------------------------------------------------------
# fixture ヘルパ（test_capex_credit_cycle_estimation.jl / test_capex_credit_cycle_history.jl
# と同じ規約だが、本テストは runup+eval の全期間で実現値パスを必要とするため独自にプレフィックス
# `_hrep_` を付けて自己完結させる）
# ---------------------------------------------------------------------------

function _hrepq_dates(start_label::String, n::Int)
    y0, q0 =
        parse(Int, split(start_label, "-Q")[1]), parse(Int, split(start_label, "-Q")[2])
    base = y0 * 4 + (q0 - 1)
    return [string(idx ÷ 4, "-Q", idx % 4 + 1) for idx in base:(base + n - 1)]
end

function _hrep_spec(key::Symbol; model_vars::Vector{Symbol} = [key])
    return CapexSeriesSpec(
        key = key,
        model_vars = model_vars,
        provider_series_id = uppercase(string(key)),
        provider = "TEST",
        source_kind = :official_statistic,
        role = :calibration_required,
        observability = :D,
        methodology = :direct,
        declared_unit = "unit",
        declared_frequency = Quarterly,
        declared_seasonal_adjustment = "SA",
        declared_real_nominal = :real,
        declared_base_year = nothing,
        annualized = false,
        level_form = :level,
        anchor = nothing,
        sector_scope = "test scope",
        scope_bias = :none,
        aggregation = :sum,
        model_timing = :SUM,
        allocation_key = nothing,
        availability_start = "2000-Q1",
        notes = "historical replay fixture entry",
    )
end

_hrep_series(key::Symbol, values::AbstractVector, dates::Vector{String}) = DataSeries(
    uppercase(string(key)),
    string(key),
    "TEST",
    Quarterly,
    "unit",
    dates,
    Vector{Union{Float64, Missing}}(values),
)

_hrep_obs(spec::CapexSeriesSpec, series::DataSeries) = CapexRawObservation(
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

function _hrep_dataset(entries::AbstractDict; start::String = "2010-Q1")
    n = length(first(values(entries)))
    dates = _hrepq_dates(start, n)
    obs = CapexRawObservation[]
    for (k, vals) in entries
        length(vals) == n || error("historical replay fixture: 系列 $k の長さが不揃いです")
        push!(obs, _hrep_obs(_hrep_spec(k), _hrep_series(k, vals, dates)))
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

# n=32 四半期（"2010-Q1"–"2017-Q4"）。baseline_start/end = "2010-Q1"/"2012-Q4"（idx 0–11）。
# 合成 episode の period_zero = "2013-Q1"（idx 12）・runup=8（idx 4–11）・eval=20（idx 12–31）。
# policy_rate・y_s2 のみ idx>=12（評価区間）で摂動を与え、他はすべて定常値で一定（`_ccc_baseline_exog`
# が既に助走を定常固定するため、この摂動が re-construction の「上書き」経路を実際に通ることを
# 検証できれば十分であり、経済的リアリズムを追求しない）。
const _HREP_N = 32
const _HREP_POLICY_BUMP = 1.0
const _HREP_YS2_AMP = 3.0

function _hrep_fixture_entries()
    b = capex_credit_cycle_default_targets().values
    flat(v) = Vector{Union{Float64, Missing}}(fill(Float64(v), _HREP_N))
    policy_rate = Vector{Union{Float64, Missing}}(Float64[
        t >= 12 ? b.policy_rate + _HREP_POLICY_BUMP * sinpi((t - 12) / 5.0) : b.policy_rate for
        t in 0:(_HREP_N - 1)
    ])
    y_s2 = Vector{Union{Float64, Missing}}(Float64[
        t >= 12 ? b.y_s2 + _HREP_YS2_AMP * sinpi((t - 12) / 6.0) : b.y_s2 for
        t in 0:(_HREP_N - 1)
    ])
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
        :wagebill_tot => flat(b.wagebill_s5 + b.wagebill_s1 + b.wagebill_s2 + b.wagebill_s3),
        :spread => flat(b.spread),
        :policy_rate => policy_rate,
        :cons => flat(b.cons),
        :debt_s1 => flat(b.debt_s1),
        :debt_s2 => flat(b.debt_s2),
        :debt_s3 => flat(b.debt_s3),
        :cash_s1 => flat(b.cash_s1),
        :cash_s2 => flat(b.cash_s2),
        :cash_s3 => flat(b.cash_s3),
        :capex_exec_s1 => flat(b.dep_s1),
    )
    return entries, b
end

function _hrep_calibration(entries::AbstractDict, b::NamedTuple)
    ds = _hrep_dataset(entries; start = "2010-Q1")
    cal = calibrate_capex_credit_cycle(
        ds;
        baseline_start = "2010-Q1",
        baseline_end = "2012-Q4",
        literature = (
            cost_capital_intercept_s1 = b.cost_capital_s1 - b.spread / 100,
            cost_capital_intercept_s2 = b.cost_capital_s2 - b.spread / 100,
            cost_capital_intercept_s3 = b.cost_capital_s3 - b.spread / 100,
        ),
        assumptions = (cons_s1 = b.cons_s1,),
    )
    return ds, cal
end

function _hrep_episode(; id::Symbol = :H1, assumptions::Vector{ScenarioAssumption} = ScenarioAssumption[],
                        in_sample::Bool = true)
    return CapexHistoricalEpisodeSpec(;
        id = id,
        label = "synthetic test episode ($(id))",
        period_zero = CalendarQuarter(2013, 1),
        runup_quarters = 8,
        eval_quarters = 20,
        assumptions = assumptions,
        in_sample = in_sample,
        notes = "test_capex_credit_cycle_historical_replay.jl の合成 episode（実 H1 とは無関係）",
    )
end

_hrep_provenance() = EventProvenance(;
    layer = :assumption,
    rule_id = "test-historical-replay-rule",
    rule_version = "1.0.0",
    generator = "test_capex_credit_cycle_historical_replay.jl",
    derived_from = ["fictional-source-1"],
)

_hrep_timing(t_apply::Int) = EventTiming(; basis = :period, rule = :explicit_period, t_apply = t_apply)

_hrep_persistence() = PersistenceSpec(; shape = :step, duration = 4, params = NamedTuple())

# event_type=:LendingStandardChange・sector=:s4 は CAPEX_CC_EVENT_MAPPING_RULES に
# target_variable が無い既知の unmapped 組（test_capex_event_adapter.jl item「row 6」参照）。
function _hrep_unmapped_assumption()
    return ScenarioAssumption(;
        assumption_id = "hrep-unmapped-1",
        event_type = :LendingStandardChange,
        sector = :s4,
        direction = :down,
        magnitude = -20.0,
        unit = "%",
        magnitude_source = :assumed_default,
        application_mode = :multiplicative,
        timing = _hrep_timing(0),
        persistence = _hrep_persistence(),
        target_concepts = [:lending_standard],
        provenance = _hrep_provenance(),
        notes = "unmapped_target 経路のテスト用（実データに基づかない合成仮定）",
    )
end

function _hrep_setup(; kind::Symbol = :calibrated, assumptions::Vector{ScenarioAssumption} = ScenarioAssumption[])
    entries, b = _hrep_fixture_entries()
    ds, cal = _hrep_calibration(entries, b)
    ps = capex_parameter_set(cal, CapexIdentificationDiagnostic[]; kind = kind)
    m = capex_replay_model(cal, ps; kind = kind)
    ep = _hrep_episode(; assumptions = assumptions)
    return (; ds, cal, ps, m, ep, b)
end

@testset "CCC 履歴再生実行層（Issue #248 / P-8）" begin
    @testset "smoke test（CLAUDE.md・§12.6-59）" begin
        setup = _hrep_setup()
        run = capex_historical_replay(setup.m, setup.ep, setup.ds, setup.ps)
        @test run isa CapexHistoricalReplayRun
        @test run.status in CAPEX_CC_REPLAY_STATUSES
        @test run.status === :completed
        @test run.model_run !== nothing
        @test run.result !== nothing
        @test startswith(run.replay_hash, "sha256:")
    end

    @testset "正常episode: baseline再構成（§12.6-52・53）" begin
        setup = _hrep_setup()
        run = capex_historical_replay(setup.m, setup.ep, setup.ds, setup.ps)
        @test run.status === :completed

        # 53: 外生は7変数のみ（内生変数へ観測値を上書きする経路が無い）
        @test Set(keys(run.exog)) == Set(exogenous_variables(setup.m))

        # 52: 助走区間は定常値固定、評価区間は実現値。exog_runup_mode が記録される。
        st_pol_ref = parameters(setup.m).st_pol_ref
        @test all(==(st_pol_ref), run.exog[:policy_rate][1:8])
        @test !all(==(st_pol_ref), run.exog[:policy_rate][9:end])
        @test run.metadata["exog_runup_mode"] == "steady_state_fixed"
        @test run.metadata["parameter_set_kind"] == "calibrated"
        @test run.metadata["price_s1_realized_path"] == "unavailable_no_catalog_entry"

        # price_s1・ai_exp・capex_plan_shock_ex・spread_shock_ex は全期間定常値のまま
        baseline28 = DME._ccc_baseline_exog(setup.m, 28)
        @test run.exog[:price_s1] == baseline28[:price_s1]
        @test run.exog[:ai_exp] == baseline28[:ai_exp]
        @test run.exog[:capex_plan_shock_ex] == baseline28[:capex_plan_shock_ex]
        @test run.exog[:spread_shock_ex] == baseline28[:spread_shock_ex]

        # ext_demand_s2 の再構成（Z-12 の識別仮定を四半期ごとに適用）が baseline の
        # ext_demand_s2^{ss} 近辺で妥当な値を返す（y_s2 の摂動分だけ乖離する）
        ss_ext2 = setup.m.targets.values.ext_demand_s2
        @test maximum(abs.(run.exog[:ext_demand_s2][9:end] .- ss_ext2)) <= _HREP_YS2_AMP + 1e-6
        @test !all(==(ss_ext2), run.exog[:ext_demand_s2][9:end])
    end

    @testset "literature_default 対 calibrated（§12.6-54）" begin
        setup_lit = _hrep_setup(; kind = :literature_default)
        setup_cal = _hrep_setup(; kind = :calibrated)
        run_lit = capex_historical_replay(
            setup_lit.m,
            setup_lit.ep,
            setup_lit.ds,
            setup_lit.ps;
            options = CapexReplayOptions(; parameter_set_kind = :literature_default),
        )
        run_cal = capex_historical_replay(setup_cal.m, setup_cal.ep, setup_cal.ds, setup_cal.ps)

        @test run_lit.status === :completed
        @test run_cal.status === :completed
        @test run_lit.parameter_set.kind === :literature_default
        @test run_cal.parameter_set.kind === :calibrated
        @test run_lit.metadata["parameter_set_kind"] != run_cal.metadata["parameter_set_kind"]
        # kind が hash payload に含まれるため parameter_set_hash は必ず異なる（§11.3）
        @test run_lit.parameter_set_hash != run_cal.parameter_set_hash
        @test run_lit.replay_hash != run_cal.replay_hash
    end

    @testset "打ち切りrun（§12.6-55）" begin
        setup = _hrep_setup()
        options = CapexReplayOptions(; model_options = CapexCreditCycleOptions(; guard_max = 5.0))
        run = capex_historical_replay(setup.m, setup.ep, setup.ds, setup.ps; options = options)

        @test run.status === :terminated
        @test run.model_run !== nothing
        @test run.model_run.termination_reason !== :completed
        @test run.model_run.termination_period !== nothing
        # 有効区間のみ評価され、残りは 0 補完ではなく NaN で保持される
        wage_series = getproperty(run.model_run.series, :wage)
        term_idx = findfirst(==(run.model_run.termination_period), run.model_run.periods)
        @test term_idx !== nothing
        @test all(isnan, wage_series[term_idx:end])
        # 0 補完ではないことの確認（zero-fill の回帰ならここで isnan が0件になり検出できる）
        @test count(isnan, wage_series) > 0
        @test run.metadata["termination_reason"] == String(run.model_run.termination_reason)
    end

    @testset "欠損データ → :rejected_input" begin
        entries, b = _hrep_fixture_entries()
        entries_gap = Dict{Symbol, Vector{Union{Float64, Missing}}}(
            k => copy(v) for (k, v) in entries
        )
        # 評価区間内（idx 20 = 2015Q1）の order_cap_s2 を欠損させる（inner join によりその
        # 四半期だけが dataset から落ちる、_capex_hist_index_map 経由で検出される）。
        entries_gap[:order_cap_s2][21] = missing
        ds_gap, cal_gap = _hrep_calibration(entries_gap, b)
        ps_gap = capex_parameter_set(cal_gap, CapexIdentificationDiagnostic[]; kind = :calibrated)
        m_gap = capex_replay_model(cal_gap, ps_gap)
        ep = _hrep_episode()

        run = capex_historical_replay(m_gap, ep, ds_gap, ps_gap)
        @test run.status === :rejected_input
        @test run.exog === nothing
        @test run.model_run === nothing
        @test run.result === nothing
        @test any(occursin("abs=", w) for w in run.warnings)
        @test startswith(run.replay_hash, "sha256:")
    end

    @testset "in_sample / out_of_sample" begin
        setup_in = _hrep_setup()
        ep_out = _hrep_episode(; in_sample = false)
        run_in = capex_historical_replay(setup_in.m, setup_in.ep, setup_in.ds, setup_in.ps)
        run_out = capex_historical_replay(setup_in.m, ep_out, setup_in.ds, setup_in.ps)

        @test run_in.in_sample === true
        @test run_out.in_sample === false
        @test run_in.metadata["in_sample"] === true
        @test run_out.metadata["in_sample"] === false
    end

    @testset "unmapped event: on_unmapped 契約" begin
        setup_reject = _hrep_setup(; assumptions = [_hrep_unmapped_assumption()])
        run_reject = capex_historical_replay(setup_reject.m, setup_reject.ep, setup_reject.ds, setup_reject.ps)
        @test run_reject.status === :rejected_input
        @test !isempty(run_reject.rejections)
        @test any(r -> r.code === :unmapped_target, run_reject.rejections)

        setup_warn = _hrep_setup(; assumptions = [_hrep_unmapped_assumption()])
        run_warn = capex_historical_replay(
            setup_warn.m,
            setup_warn.ep,
            setup_warn.ds,
            setup_warn.ps;
            options = CapexReplayOptions(; on_unmapped = :warn),
        )
        @test run_warn.status !== :rejected_input
        @test any(occursin("unmapped_target_accepted", w) for w in run_warn.warnings)
    end

    @testset "決定的再実行（§12.6-60）" begin
        setup = _hrep_setup()
        run1 = capex_historical_replay(setup.m, setup.ep, setup.ds, setup.ps)
        run2 = capex_historical_replay(setup.m, setup.ep, setup.ds, setup.ps)
        @test run1.replay_hash == run2.replay_hash
        @test run1.model_run.series == run2.model_run.series
        @test run1.exog == run2.exog
    end

    @testset "capex_historical_replay_run_to_dict / save の往復" begin
        setup = _hrep_setup()
        options = CapexReplayOptions(; model_options = CapexCreditCycleOptions(; guard_max = 5.0))
        run = capex_historical_replay(setup.m, setup.ep, setup.ds, setup.ps; options = options)
        d = capex_historical_replay_run_to_dict(run)
        @test d["status"] == "terminated"
        @test d["replay_hash"] == run.replay_hash
        @test haskey(d, "series")
        @test haskey(d, "observed")
        @test haskey(d, "event_log")
        @test haskey(d, "warnings")
        @test haskey(d, "metadata")

        mktempdir() do dir
            path = joinpath(dir, "replay.json")
            save_capex_historical_replay_run(path, run)
            parsed = JSON3.read(read(path, String))
            @test parsed.status == "terminated"
            wage_vec = parsed.series.wage
            @test any(v -> v === nothing, wage_vec)
        end
    end

    # 会計失敗（status = :accounting_failed）パスは、正常な capex_run 出力から意図的に
    # 会計恒等式を破る実行を安価に構成する方法が無い（AccountingCheckReport を捏造しない
    # という規律、実証統合設計 §6.1）。会計検証自体は「打ち切りrun」テストと「smoke test」で
    # 既定 validate_accounting=true のまま実行しており（§12.7-62 相当）、会計失敗判定ロジック
    # （accounting_passed(accounting) の分岐）はコードレビューで確認済み。ここでは意図的に
    # スキップする。
end
