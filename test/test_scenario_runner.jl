# `run_scenario`（`Scenario` → `SimulationResult` の実行層、Issue #202 / `E-6`）のテスト。
#
# 統合設計 §10.4（実行・互換・再現、14項目）のうち #202 の受け入れ条件（同 §11 `E-6` 行）が
# 対象とする 1–5・7–10・14 を中心に検証する。§10.4 の 6・11–13 は Issue #201（`capex_exogenous_paths`
# 委譲）・Issue #203（`scenario_provenance.jl` の完全な hash 契約）の対象。

using Dates: Date

# ------------------------------------------------------------
# テスト用ヘルパ（fictional）
# ------------------------------------------------------------

_tsr_provenance(; derived_from = ["fictional-source-1"]) = EventProvenance(;
    layer = :assumption,
    rule_id = "test-scenario-runner-rule",
    rule_version = "1.0.0",
    generator = "test_scenario_runner.jl",
    derived_from = derived_from,
)

_tsr_timing(t_apply::Int = 0) =
    EventTiming(; basis = :period, rule = :explicit_period, t_apply = t_apply)

_tsr_persistence(; shape::Symbol = :step, duration = nothing, params::NamedTuple = NamedTuple()) =
    PersistenceSpec(; shape = shape, duration = duration, params = params)

function _tsr_assumption(;
    id::AbstractString,
    event_type::Symbol,
    sector::Symbol,
    direction::Symbol,
    magnitude::Float64,
    unit::AbstractString,
    application_mode::Symbol,
    target_concepts::Vector{Symbol},
    timing::EventTiming = _tsr_timing(),
    persistence::PersistenceSpec = _tsr_persistence(),
    notes::AbstractString = "",
    confidence::Union{Float64, Nothing} = nothing,
)
    return scenario_assumption(;
        assumption_id = id,
        event_type = event_type,
        sector = sector,
        direction = direction,
        magnitude = magnitude,
        unit = unit,
        magnitude_source = :assumed_default,
        application_mode = application_mode,
        timing = timing,
        persistence = persistence,
        target_concepts = target_concepts,
        provenance = _tsr_provenance(),
        notes = notes,
        confidence = confidence,
    )
end

_tsr_demand_assumption(; id = "demand-1", magnitude = 5.0, t_apply = 0) = _tsr_assumption(;
    id = id,
    event_type = :DemandOutlookRevision,
    sector = :s1,
    direction = magnitude >= 0 ? :up : :down,
    magnitude = magnitude,
    unit = "%",
    application_mode = :multiplicative,
    target_concepts = [:demand_expectation],
    timing = _tsr_timing(t_apply),
)

_tsr_credit_assumption(; id = "credit-1", magnitude = 50.0, t_apply = 0) = _tsr_assumption(;
    id = id,
    event_type = :CreditSpreadShock,
    sector = :unknown,
    direction = magnitude >= 0 ? :up : :down,
    magnitude = magnitude,
    unit = "bp",
    application_mode = :additive,
    target_concepts = [:credit_spread],
    timing = _tsr_timing(t_apply),
)

_tsr_employment_assumption(; id = "emp-1") = _tsr_assumption(;
    id = id,
    event_type = :EmploymentPlanRevision,
    sector = :s1,
    direction = :down,
    magnitude = -5.0,
    unit = "%",
    application_mode = :multiplicative,
    target_concepts = [:employment_plan],
)

function _tsr_scenario(; id::Symbol = :test_scenario, assumptions = ScenarioAssumption[], kwargs...)
    return Scenario(; id = id, model = :capex_credit_cycle, assumptions = assumptions, kwargs...)
end

@testset "run_scenario（Issue #202 / E-6）" begin
    targets = capex_credit_cycle_default_targets()
    m = capex_credit_cycle_model(targets)

    @testset "SCENARIO_EXECUTION_STATUSES / ScenarioRunOptions 既定値" begin
        @test SCENARIO_EXECUTION_STATUSES ==
              (:completed, :rejected_validation, :rejected_mapping, :terminated)
        opts = ScenarioRunOptions()
        @test opts.on_unmapped === :reject
        @test opts.confidence_threshold === nothing
        @test opts.validate_accounting == true
        @test opts.diagnostics == true
    end

    @testset "項目1: 空 assumptions（baseline）が完走する" begin
        sc = _tsr_scenario()
        run = run_scenario(m, sc)
        @test run.status === :completed
        @test run.result !== nothing
        @test run.exog !== nothing
        @test isempty(run.rejections)
        # baseline は外生パスが定常値のまま
        @test run.exog[:ai_exp] == fill(1.0, 28)
    end

    @testset "項目2: 実行順が validation → mapping → schedule → model → result で固定される" begin
        # validation失敗（model不一致）が mapping へ進まないことは
        # 「Scenario全体検証: model_mismatch」testset で確認する。
        sc = _tsr_scenario(; assumptions = [_tsr_demand_assumption()])
        run = run_scenario(m, sc)
        @test run.status === :completed
        @test !isempty(run.applied_inputs)
        @test run.schedule !== nothing
        @test run.model_run !== nothing
    end

    @testset "項目3: rejected_* で result===nothing・exog===nothing" begin
        dup_a = _tsr_demand_assumption(; id = "dup")
        dup_b = _tsr_credit_assumption(; id = "dup")
        sc = _tsr_scenario(; assumptions = [dup_a, dup_b])
        run = run_scenario(m, sc)
        @test run.status === :rejected_validation
        @test run.result === nothing
        @test run.exog === nothing
        @test any(r.code === :duplicate_event_id for r in run.rejections)

        sc_emp = _tsr_scenario(; assumptions = [_tsr_employment_assumption()])
        run_emp = run_scenario(m, sc_emp)
        @test run_emp.status === :rejected_mapping
        @test run_emp.result === nothing
        @test run_emp.exog === nothing
        @test any(r.code === :unmapped_target for r in run_emp.rejections)
    end

    @testset "Scenario全体検証: model_mismatch" begin
        sc = Scenario(; id = :bad, model = :not_capex_credit_cycle)
        run = run_scenario(m, sc)
        @test run.status === :rejected_validation
        @test any(r.code === :model_mismatch for r in run.rejections)
    end

    @testset "Scenario全体検証: mixed_timing_basis" begin
        cal = _tsr_assumption(;
            id = "cal-1",
            event_type = :DemandOutlookRevision,
            sector = :s1,
            direction = :up,
            magnitude = 5.0,
            unit = "%",
            application_mode = :multiplicative,
            target_concepts = [:demand_expectation],
            timing = EventTiming(;
                basis = :calendar,
                rule = :same_quarter,
                effective_from = Date(2026, 2, 1),
            ),
        )
        per = _tsr_credit_assumption(; id = "per-1")
        sc = _tsr_scenario(;
            assumptions = [cal, per],
            period_zero = CalendarQuarter(2026, 1),
        )
        run = run_scenario(m, sc)
        @test run.status === :rejected_validation
        @test any(r.code === :mixed_timing_basis for r in run.rejections)
    end

    @testset "Scenario全体検証: period_zero_required" begin
        cal = _tsr_assumption(;
            id = "cal-only",
            event_type = :DemandOutlookRevision,
            sector = :s1,
            direction = :up,
            magnitude = 5.0,
            unit = "%",
            application_mode = :multiplicative,
            target_concepts = [:demand_expectation],
            timing = EventTiming(;
                basis = :calendar,
                rule = :same_quarter,
                effective_from = Date(2026, 2, 1),
            ),
        )
        sc = _tsr_scenario(; assumptions = [cal])
        run = run_scenario(m, sc)
        @test run.status === :rejected_validation
        @test any(r.code === :period_zero_required for r in run.rejections)
    end

    @testset "項目14: horizon_mismatch" begin
        sc = _tsr_scenario(; horizon_runup = 8, horizon_eval = 20)
        opts = ScenarioRunOptions(;
            model_options = CapexCreditCycleOptions(; horizon_runup = 4, horizon_eval = 10),
        )
        run = run_scenario(m, sc; options = opts)
        @test run.status === :rejected_validation
        @test any(r.code === :horizon_mismatch for r in run.rejections)
    end

    @testset "項目4: on_unmapped の既定 :reject（fail closed）と :warn" begin
        sc = _tsr_scenario(; assumptions = [_tsr_employment_assumption()])
        run_reject = run_scenario(m, sc)
        @test run_reject.status === :rejected_mapping
        @test run_reject.result === nothing

        run_warn = run_scenario(m, sc; options = ScenarioRunOptions(; on_unmapped = :warn))
        @test run_warn.status === :completed
        @test run_warn.result !== nothing
        @test any(w.code === :unmapped_target_accepted for w in run_warn.warnings)
        @test run_warn.result.metadata["unmapped_policy"] == "warn"

        @test_throws ArgumentError run_scenario(
            m,
            sc;
            options = ScenarioRunOptions(; on_unmapped = :bogus),
        )
    end

    @testset "項目5: terminated で有効区間まで返り、打ち切り後はNaNのまま" begin
        m_diverge = capex_credit_cycle_model(targets; behavioral = (bh_wage_slope = 1.0e7,))
        shock = _tsr_demand_assumption(; id = "diverge", magnitude = 60.0, t_apply = 0)
        sc = _tsr_scenario(; assumptions = [shock])
        run = run_scenario(m_diverge, sc)
        @test run.status === :terminated
        @test run.result !== nothing
        @test run.exog !== nothing
        @test run.model_run.termination_reason !== :completed
        idx_term = findfirst(==(run.model_run.termination_period), run.model_run.periods)
        @test idx_term !== nothing
        @test all(isnan, run.result["wage"][idx_term:end])
        @test !any(isnan, run.result["cap_s1"][1:(idx_term - 1)])
        @test run.result.metadata["event_execution_status"] == "terminated"
    end

    @testset "項目7・8: capex_scenario_assumptions(id) 経由が capex_exogenous_paths と一致（Sc0–Sc4）" begin
        for id in CAPEX_CC_SCENARIO_IDS
            legacy_scenario = capex_scenario(id)
            legacy_exog = capex_exogenous_paths(m, legacy_scenario)

            assumptions = capex_scenario_assumptions(id)
            sc = _tsr_scenario(; id = id, assumptions = assumptions)
            run = run_scenario(m, sc)

            @test run.status === :completed
            for target in exogenous_variables(m)
                @test run.exog[target] ≈ legacy_exog[target]
            end
            legacy_series = simulate(m; scenario = id, exog = legacy_exog)
            for (k, v) in pairs(run.result.variables)
                @test v ≈ getproperty(legacy_series, Symbol(k)) nans = true
            end
        end
    end

    @testset "項目9: 既存 test_capex_credit_cycle.jl の Sc0–Sc4 テストへ影響しない" begin
        # 本テストは capex_run/capex_exogenous_paths を変更していないことの補助的な確認。
        # 実質的な回帰確認は test_capex_credit_cycle.jl 自体（無変更）で行う。
        @test capex_exogenous_paths(m, capex_scenario(:Sc0)) ==
              Dict{Symbol, Vector{Float64}}(
            v => fill(getproperty(
                (
                    ai_exp = 1.0,
                    capex_plan_shock_ex = 1.0,
                    spread_shock_ex = 0.0,
                    policy_rate = parameters(m).st_pol_ref,
                    ext_demand_s2 = parameters(m).st_extdem_s2,
                    ext_demand_s3 = parameters(m).st_extdem_s3,
                    price_s1 = 1.0,
                ),
                v,
            ), 28) for v in exogenous_variables(m)
        )
    end

    @testset "項目10: 同一Scenarioの再実行でexog・warnings順・rejections順が一致" begin
        sc = _tsr_scenario(;
            assumptions = [
                _tsr_demand_assumption(; id = "a1", magnitude = 3.0),
                _tsr_credit_assumption(; id = "a2", magnitude = 25.0, t_apply = 2),
            ],
        )
        run1 = run_scenario(m, sc)
        run2 = run_scenario(m, sc)
        @test run1.status === run2.status === :completed
        @test run1.exog == run2.exog
        @test [w.code for w in run1.warnings] == [w.code for w in run2.warnings]
        @test [r.code for r in run1.rejections] == [r.code for r in run2.rejections]
        @test run1.result.variables == run2.result.variables
    end

    @testset "metadata: イベント層予約キー（event_log を除く）が設定される" begin
        sc = _tsr_scenario(; assumptions = [_tsr_demand_assumption()])
        run = run_scenario(m, sc)
        md = run.result.metadata
        for key in (
            "event_contract_version",
            "time_semantics_version",
            "event_runtime_version",
            "event_rule_version",
            "event_mapping_version",
            "scenario_id",
            "scenario_version",
            "scenario_content_hash",
            "event_set_hash",
            "period_zero",
            "period_labels",
            "shock_origin_index",
            "timing_rule_set",
            "event_warnings",
            "event_rejections",
            "event_execution_status",
            "unmapped_policy",
            "params_hash",
            "initial_state_id",
        )
            @test haskey(md, key)
        end
        @test !haskey(md, "event_log") # event_log は Issue #203 の対象
        @test md["scenario_id"] == "test_scenario"
        @test md["shock_origin_index"] == 9 # horizon_runup=8 → periods[9] == 0
        @test md["period_zero"] === nothing
        @test md["period_labels"][1] == "t-8"
        @test md["period_labels"][end] == "t+19"
        # 既存 CCC 予約キーを上書きしない
        @test haskey(md, "parameters")
        @test haskey(md, "termination_reason")
    end

    @testset "event_set_hash / scenario_content_hash: 決定性" begin
        a1 = _tsr_demand_assumption(; id = "h1", magnitude = 3.0)
        a2 = _tsr_credit_assumption(; id = "h2", magnitude = 10.0, t_apply = 1)
        sc = _tsr_scenario(; assumptions = [a1, a2])
        sc_reordered = _tsr_scenario(; assumptions = [a2, a1])
        @test event_set_hash(sc) == event_set_hash(sc_reordered)
        @test scenario_content_hash(sc) == scenario_content_hash(sc_reordered)

        a1_bigger = _tsr_demand_assumption(; id = "h1", magnitude = 3.0 + eps(3.0))
        sc_changed = _tsr_scenario(; assumptions = [a1_bigger, a2])
        @test event_set_hash(sc) != event_set_hash(sc_changed)

        sc_empty = _tsr_scenario()
        @test startswith(event_set_hash(sc_empty), "sha256:")
        @test startswith(scenario_content_hash(sc_empty), "sha256:")
    end
end
