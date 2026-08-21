# シナリオ比較診断（`src/analysis/scenario_diagnostics.jl`、Issue #204 / `E-8`）のテスト。
#
# Issue #204 本文「テスト期待」（zero baseline・符号反転・複数peak・threshold直上/直下・
# 遅延反応・回復なし・terminated run・latent variable・flow/stock差・shuffle決定性）と
# 統合設計 §5.8 契約1–8を対象とする。数値の境界条件（onset/duration/recovery/peak/trough）は
# `DME._scenario_diag_*` の内部関数を合成データで直接検証し（決定的・高速）、`run_scenario` との
# 結線（比較可能性検証・terminated run・latent variable・flow/stock 差・event_application_periods・
# shuffle決定性）は `CapexCreditCycleModel` を用いた統合テストで検証する。

# ------------------------------------------------------------
# テスト用ヘルパ（fictional。test_scenario_runner.jl の命名規約に倣う）
# ------------------------------------------------------------

_tsd_provenance(; derived_from = ["fictional-source-1"]) = EventProvenance(;
    layer = :assumption,
    rule_id = "test-scenario-diagnostics-rule",
    rule_version = "1.0.0",
    generator = "test_scenario_diagnostics.jl",
    derived_from = derived_from,
)

_tsd_timing(t_apply::Int = 0) =
    EventTiming(; basis = :period, rule = :explicit_period, t_apply = t_apply)

function _tsd_demand_assumption(;
    id::AbstractString = "demand-1",
    magnitude::Float64 = -10.0,
    t_apply::Int = 0,
    magnitude_source::Symbol = :assumed_default,
    shape::Symbol = :step,
    duration::Union{Int, Nothing} = nothing,
)
    return scenario_assumption(;
        assumption_id = id,
        event_type = :DemandOutlookRevision,
        sector = :s1,
        direction = magnitude >= 0 ? :up : :down,
        magnitude = magnitude,
        unit = "%",
        magnitude_source = magnitude_source,
        application_mode = :multiplicative,
        timing = _tsd_timing(t_apply),
        persistence = PersistenceSpec(; shape = shape, duration = duration),
        target_concepts = [:demand_expectation],
        provenance = _tsd_provenance(),
    )
end

function _tsd_scenario(;
    id::Symbol = :test_scenario,
    assumptions = ScenarioAssumption[],
    kwargs...,
)
    return Scenario(;
        id = id,
        model = :capex_credit_cycle,
        assumptions = assumptions,
        kwargs...,
    )
end

"`run.provenance`/`.scenario`/`.model_symbol` のみ差し替えた `ScenarioRun` を返す
（比較可能性検証 §5.8 契約1 の5項目を個別に破るための内部ヘルパー）。"
function _tsd_with(
    run::ScenarioRun;
    status = run.status,
    scenario = run.scenario,
    model_symbol = run.model_symbol,
    provenance = run.provenance,
)
    return ScenarioRun(
        status,
        scenario,
        run.model_name,
        model_symbol,
        run.applied_inputs,
        run.schedule,
        run.exog,
        run.model_run,
        run.accounting,
        run.diagnostics,
        run.result,
        run.rejections,
        run.warnings,
        provenance,
        run.options,
    )
end

function _tsd_provenance_with(
    p::ScenarioProvenance;
    params_hash = p.params_hash,
    initial_state_id = p.initial_state_id,
)
    return ScenarioProvenance(
        p.model_version,
        p.contract_versions,
        p.scenario_id,
        p.scenario_version,
        p.event_set_hash,
        p.rule_version,
        p.mapping_version,
        params_hash,
        initial_state_id,
        p.solver_settings_hash,
        p.timing_rule_set,
    )
end

# ------------------------------------------------------------
# ScenarioDiagnosticThresholds 既定値
# ------------------------------------------------------------

@testset "ScenarioDiagnosticThresholds 既定値" begin
    th = ScenarioDiagnosticThresholds()
    @test th.id == "default"
    @test th.onset_abs == 1e-8
    @test th.onset_rel == 0.001
    @test th.onset_persistence == 2
    @test th.rel_denominator_floor == 1e-6
end

# ------------------------------------------------------------
# 内部関数の合成データ検証（決定的・高速。onset/duration/recovery/peak/troughの境界条件）
# ------------------------------------------------------------

@testset "内部関数: _scenario_diag_rel（統合設計 §5.8 契約3）" begin
    floor = 1e-6
    @test DME._scenario_diag_rel(1.0, 1e-8, floor) === missing # 分母が floor 未満
    @test DME._scenario_diag_rel(0.5, 2.0, floor) == 0.25
    @test isnan(DME._scenario_diag_rel(NaN, 2.0, floor)) # 打ち切り後の欠損はNaNのまま
end

@testset "内部関数: zero baseline（差分ゼロ）" begin
    periods = collect(-2:2)
    diff = zeros(5)
    peak = DME._scenario_diag_extremum(diff, periods, 5, >)
    trough = DME._scenario_diag_extremum(diff, periods, 5, <)
    @test peak.value == 0.0 && peak.sign == 0
    @test trough.value == 0.0 && trough.sign == 0
    rel = Union{Float64, Missing}[0.0 for _ in diff]
    th = ScenarioDiagnosticThresholds()
    breach = DME._scenario_diag_breach(diff, rel, 5, th)
    @test !any(breach)
    @test DME._scenario_diag_onset(breach, periods, th.onset_persistence) === nothing
end

@testset "内部関数: 全てNaN（有効データなし）" begin
    periods = collect(0:2)
    diff = fill(NaN, 3)
    peak = DME._scenario_diag_extremum(diff, periods, 3, >)
    @test isnan(peak.value) && peak.period === nothing && peak.sign == 0
end

@testset "内部関数: 符号反転（peak と trough が別の期・別の符号）" begin
    periods = collect(-3:3) # 7期
    diff = [0.0, 0.0, 3.0, 3.0, -5.0, -5.0, 0.0]
    peak = DME._scenario_diag_extremum(diff, periods, 7, >)
    trough = DME._scenario_diag_extremum(diff, periods, 7, <)
    @test peak.value == 3.0 && peak.sign == 1 && peak.period == -1
    @test trough.value == -5.0 && trough.sign == -1 && trough.period == 1
end

@testset "内部関数: 複数peak（非連続の閾値超過が duration_above に合算される）" begin
    periods = collect(0:8)
    diff = [0.0, 4.0, 0.0, 6.0, 0.0, -7.0, 0.0, 5.0, 0.0]
    rel = Union{Float64, Missing}[0.0 for _ in diff]
    th = ScenarioDiagnosticThresholds(; onset_abs = 1.0, onset_persistence = 1)
    breach = DME._scenario_diag_breach(diff, rel, length(diff), th)
    @test breach == [false, true, false, true, false, true, false, true, false]
    @test count(breach) == 4
    @test DME._scenario_diag_onset(breach, periods, th.onset_persistence) == 1 # 最初の超過期
end

@testset "内部関数: 閾値直上/直下（境界は inclusive）" begin
    periods = collect(0:1)
    th = ScenarioDiagnosticThresholds(; onset_abs = 2.0, onset_persistence = 2)
    diff_at = [2.0, 2.0]
    diff_below = [1.999999, 1.999999]
    rel = Union{Float64, Missing}[0.0, 0.0]
    breach_at = DME._scenario_diag_breach(diff_at, rel, 2, th)
    breach_below = DME._scenario_diag_breach(diff_below, rel, 2, th)
    @test all(breach_at) # 閾値ちょうどは超過とみなす（inclusive）
    @test !any(breach_below)
    @test DME._scenario_diag_onset(breach_at, periods, th.onset_persistence) == 0
    @test DME._scenario_diag_onset(breach_below, periods, th.onset_persistence) === nothing
end

@testset "内部関数: 遅延反応（onset が先頭期ではない）" begin
    periods = collect(0:4)
    breach = [false, false, true, true, true]
    onset = DME._scenario_diag_onset(breach, periods, 2)
    @test onset == 2 # イベント適用期（0）より後
end

@testset "内部関数: 回復なし（recovery_period が nothing）" begin
    periods = collect(0:4)
    breach = [false, true, true, true, true]
    onset = DME._scenario_diag_onset(breach, periods, 2)
    @test onset == 1
    @test DME._scenario_diag_recovery(breach, periods, onset, 2) === nothing
    # onset 自体が無い場合も nothing（反応が無いので回復もない）
    @test DME._scenario_diag_recovery(falses(5), periods, nothing, 2) === nothing
end

@testset "内部関数: 回復あり" begin
    periods = collect(0:5)
    breach = [false, true, true, false, false, true]
    onset = DME._scenario_diag_onset(breach, periods, 2)
    @test onset == 1
    recovery = DME._scenario_diag_recovery(breach, periods, onset, 2)
    @test recovery == 3 # index4開始（0始まりのperiodで3）から2期連続false
end

# ------------------------------------------------------------
# run_scenario との結線（統合設計 §5.8 契約1・2・5・6・7・8）
# ------------------------------------------------------------

@testset "scenario_comparison（Issue #204 / E-8）" begin
    targets = capex_credit_cycle_default_targets()
    m = capex_credit_cycle_model(targets)

    sc_base = _tsd_scenario(; id = :baseline)
    sc_shock = _tsd_scenario(; id = :shock, assumptions = [_tsd_demand_assumption()])
    run_base = run_scenario(m, sc_base)
    run_shock = run_scenario(m, sc_shock)
    @test run_base.status === :completed
    @test run_shock.status === :completed

    @testset "zero baseline: 自分自身との比較は差分ゼロ" begin
        diag = scenario_comparison(run_base, run_base)
        @test all(all(iszero, v) for v in values(diag.abs_diff))
        @test all(v === nothing for v in values(diag.onset_period))
        @test all(v === nothing for v in values(diag.recovery_period))
        @test diag.invalid_reason === nothing
        @test diag.latent_only_onset == false
        @test isempty(diag.propagation_order)
    end

    @testset "flow/stock 差: cumulative は SUM 変数のみ" begin
        diag = scenario_comparison(
            run_base,
            run_shock;
            variables = [:capex_plan_eff_s1, :debt_s1],
        )
        @test diag.cumulative[:capex_plan_eff_s1] !== nothing # SUM（フロー）
        @test diag.cumulative[:debt_s1] === nothing # EOP（ストック）に無差別適用しない
    end

    @testset "event_application_periods と onset_period は別概念" begin
        diag = scenario_comparison(run_base, run_shock)
        @test diag.event_application_periods == [0] # イベント適用期
        # 遅延反応する変数が少なくとも1つ存在し、適用期そのものではない
        delayed = [
            v for v in diag.variables if
            diag.onset_period[v] !== nothing && diag.onset_period[v] > 0
        ]
        @test !isempty(delayed)
    end

    @testset "latent variable: metadata['variable_observability'] による判定" begin
        # capex_plan_eff_s1 は observability="A"（潜在変数として扱う、統合設計 §5.8 契約5）
        diag_latent =
            scenario_comparison(run_base, run_shock; variables = [:capex_plan_eff_s1])
        @test diag_latent.onset_period[:capex_plan_eff_s1] !== nothing
        @test diag_latent.latent_only_onset == true

        # cap_s1 は observability="P"（潜在変数ではない）
        diag_nonlatent = scenario_comparison(run_base, run_shock; variables = [:cap_s1])
        @test diag_nonlatent.latent_only_onset == false
    end

    @testset "shuffle決定性: variables の順序を変えても内容と propagation_order が一致する" begin
        vars_a = [:capex_plan_eff_s1, :cap_s1, :debt_s1, :y_s1]
        vars_b = reverse(vars_a)
        diag_a = scenario_comparison(run_base, run_shock; variables = vars_a)
        diag_b = scenario_comparison(run_base, run_shock; variables = vars_b)
        for v in vars_a
            @test diag_a.abs_diff[v] == diag_b.abs_diff[v]
            @test diag_a.onset_period[v] === diag_b.onset_period[v]
            @test diag_a.peak[v] == diag_b.peak[v]
        end
        @test diag_a.propagation_order == diag_b.propagation_order

        # 仮定の入力順（同時点2件）を入れ替えても event_application_periods・propagation_order
        # が一致する（`schedule_events` 自体の shuffle 決定性は test_event_scheduler.jl の対象。
        # ここでは scenario_comparison がその出力をそのまま用い、独自の非決定性を持ち込まないことを
        # 確認する）。
        a1 = _tsd_demand_assumption(; id = "d1", magnitude = -5.0, t_apply = 0)
        a2 = scenario_assumption(;
            assumption_id = "d2",
            event_type = :CreditSpreadShock,
            sector = :unknown,
            direction = :up,
            magnitude = 30.0,
            unit = "bp",
            magnitude_source = :assumed_default,
            application_mode = :additive,
            timing = _tsd_timing(0),
            persistence = PersistenceSpec(; shape = :step),
            target_concepts = [:credit_spread],
            provenance = _tsd_provenance(),
        )
        sc_12 = _tsd_scenario(; id = :order12, assumptions = [a1, a2])
        sc_21 = _tsd_scenario(; id = :order21, assumptions = [a2, a1])
        run_12 = run_scenario(m, sc_12)
        run_21 = run_scenario(m, sc_21)
        diag_12 = scenario_comparison(run_base, run_12)
        diag_21 = scenario_comparison(run_base, run_21)
        @test diag_12.event_application_periods == diag_21.event_application_periods
        @test diag_12.propagation_order == diag_21.propagation_order
    end

    @testset "名称に causal / contribution を含まない（統合設計 §5.8 契約4）" begin
        diag = scenario_comparison(run_base, run_shock)
        forbidden = ("causal", "contribution")
        names = string.(fieldnames(ScenarioComparisonDiagnostics))
        @test all(n -> !any(f -> occursin(f, lowercase(n)), forbidden), names)
        if !isempty(diag.propagation_order)
            pnames = string.(keys(diag.propagation_order[1]))
            @test all(n -> !any(f -> occursin(f, lowercase(n)), forbidden), pnames)
        end
    end

    @testset "model_diagnostics（任意引数）: CCC 固有の loop_active を propagation_order へ付加" begin
        diag_none = scenario_comparison(run_base, run_shock)
        @test all(isempty(e.active_loops) for e in diag_none.propagation_order)

        @test run_shock.diagnostics isa CapexDiagnostics
        diag_with = scenario_comparison(
            run_base,
            run_shock;
            model_diagnostics = run_shock.diagnostics,
        )
        @test length(diag_with.propagation_order) == length(diag_none.propagation_order)
        # active_loops はCCC固有ループ作動フラグをそのまま引き写すのみ（因果推定ではない）
        @test all(e -> e.active_loops isa Vector{Symbol}, diag_with.propagation_order)
    end

    @testset "terminated run: 有効区間が打ち切り期までで、NaNで埋めない" begin
        m_diverge = capex_credit_cycle_model(targets; behavioral = (bh_wage_slope = 1.0e7,))
        sc_base_d = _tsd_scenario(; id = :baseline_d)
        sc_diverge = _tsd_scenario(;
            id = :diverge,
            assumptions = [_tsd_demand_assumption(; id = "diverge", magnitude = 60.0)],
        )
        run_base_d = run_scenario(m_diverge, sc_base_d)
        run_diverge = run_scenario(m_diverge, sc_diverge)
        @test run_diverge.status === :terminated

        diag = scenario_comparison(run_base_d, run_diverge)
        @test diag.invalid_reason === :scenario_terminated
        @test length(diag.valid_range) < 28
        for v in diag.variables
            valid = diag.abs_diff[v][1:length(diag.valid_range)]
            @test all(isfinite, valid) # 有効区間内はNaNで埋めない
        end
    end

    @testset "比較可能性の事前検証（統合設計 §5.8 契約1）" begin
        @testset "rejected run は比較できない" begin
            sc_bad = Scenario(; id = :bad, model = :not_capex_credit_cycle)
            run_bad = run_scenario(m, sc_bad)
            @test run_bad.status === :rejected_validation
            @test_throws ArgumentError scenario_comparison(run_bad, run_shock)
            @test_throws ArgumentError scenario_comparison(run_base, run_bad)
        end

        @testset "model_symbol 不一致" begin
            run_bad_symbol = _tsd_with(run_shock; model_symbol = :not_capex_credit_cycle)
            @test_throws ArgumentError scenario_comparison(run_base, run_bad_symbol)
        end

        @testset "params_hash 不一致" begin
            bad_prov =
                _tsd_provenance_with(run_shock.provenance; params_hash = "sha256:" * "0"^64)
            run_bad_params = _tsd_with(run_shock; provenance = bad_prov)
            @test_throws ArgumentError scenario_comparison(run_base, run_bad_params)
        end

        @testset "initial_state_id 不一致" begin
            bad_prov = _tsd_provenance_with(
                run_shock.provenance;
                initial_state_id = "not_steady_state",
            )
            run_bad_state = _tsd_with(run_shock; provenance = bad_prov)
            @test_throws ArgumentError scenario_comparison(run_base, run_bad_state)
        end

        @testset "horizon 不一致" begin
            sc_short = _tsd_scenario(; id = :short, horizon_runup = 4, horizon_eval = 10)
            run_short = run_scenario(m, sc_short)
            @test run_short.status === :completed
            @test_throws ArgumentError scenario_comparison(run_base, run_short)
        end

        @testset "period_zero 不一致" begin
            sc_pz = _tsd_scenario(; id = :with_pz, period_zero = CalendarQuarter(2026, 1))
            run_pz = run_scenario(m, sc_pz)
            @test run_pz.status === :completed
            @test_throws ArgumentError scenario_comparison(run_base, run_pz)
        end
    end

    @testset "variables 引数: 存在しない変数は ArgumentError" begin
        @test_throws ArgumentError scenario_comparison(
            run_base,
            run_shock;
            variables = [:not_a_real_variable],
        )
    end
end

# ------------------------------------------------------------
# scenario_timing_sensitivity / scenario_magnitude_sensitivity（`Y-29`・`Y-30`）
# ------------------------------------------------------------

@testset "scenario_timing_sensitivity（`Y-29`）" begin
    targets = capex_credit_cycle_default_targets()
    m = capex_credit_cycle_model(targets)
    sc = _tsd_scenario(; id = :shock, assumptions = [_tsd_demand_assumption(; t_apply = 0)])

    sens = scenario_timing_sensitivity(m, sc; shift = 2)
    @test sens.shift == 2
    @test sens.minus.status === :completed
    @test sens.plus.status === :completed
    @test sens.minus.applied_inputs[1].t_apply == -2
    @test sens.plus.applied_inputs[1].t_apply == 2

    default_sens = scenario_timing_sensitivity(m, sc)
    @test default_sens.shift == 1
end

@testset "scenario_magnitude_sensitivity（`Y-30`）: assumed_default のみ動かす" begin
    targets = capex_credit_cycle_default_targets()
    m = capex_credit_cycle_model(targets)
    assumed = _tsd_demand_assumption(;
        id = "assumed",
        magnitude = -10.0,
        magnitude_source = :assumed_default,
    )
    observed = scenario_assumption(;
        assumption_id = "observed",
        event_type = :CreditSpreadShock,
        sector = :unknown,
        direction = :up,
        magnitude = 30.0,
        unit = "bp",
        magnitude_source = :observed,
        application_mode = :additive,
        timing = _tsd_timing(0),
        persistence = PersistenceSpec(; shape = :step),
        target_concepts = [:credit_spread],
        provenance = _tsd_provenance(),
    )
    sc = _tsd_scenario(; id = :mixed, assumptions = [assumed, observed])

    sens = scenario_magnitude_sensitivity(m, sc; ratio = 0.5)
    @test sens.ratio == 0.5

    minus_assumed =
        only(a for a in sens.minus.scenario.assumptions if a.assumption_id == "assumed")
    plus_assumed =
        only(a for a in sens.plus.scenario.assumptions if a.assumption_id == "assumed")
    @test minus_assumed.magnitude ≈ -10.0 * 0.5
    @test plus_assumed.magnitude ≈ -10.0 * 1.5

    minus_observed =
        only(a for a in sens.minus.scenario.assumptions if a.assumption_id == "observed")
    plus_observed =
        only(a for a in sens.plus.scenario.assumptions if a.assumption_id == "observed")
    @test minus_observed.magnitude == 30.0 # :observed は動かさない
    @test plus_observed.magnitude == 30.0
end
