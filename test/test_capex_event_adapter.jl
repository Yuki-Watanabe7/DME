# 部門別CAPEX・信用循環モデル（CCC）向けイベント mapping adapter のテスト
# （src/scenarios/adapters/capex_credit_cycle_event_adapter.jl、Issue #201 / `E-5`）。
#
# 統合設計 §10.3（mapping、10項目）を対象とする。fixture は
# `test/fixtures/events/capex_mapping/*.json`（本ファイルと同じ synthetic データを人間可読な
# 形で記録した参考資料であり、他のイベント系テストと同様プログラム的には読み込まない）。

using Dates: Date

# ------------------------------------------------------------
# テスト用ヘルパ（fictional）
# ------------------------------------------------------------

_cea_provenance(layer::Symbol = :assumption) = EventProvenance(;
    layer = layer,
    rule_id = "test-capex-event-adapter-rule",
    rule_version = "1.0.0",
    generator = "test_capex_event_adapter.jl",
    derived_from = ["fictional-source-1"],
)

_cea_timing(t_apply::Int = 0) =
    EventTiming(; basis = :period, rule = :explicit_period, t_apply = t_apply)

_cea_persistence(; shape::Symbol = :step, duration = 4, params::NamedTuple = NamedTuple()) =
    PersistenceSpec(; shape = shape, duration = duration, params = params)

function _cea_assumption(;
    id::AbstractString,
    event_type::Symbol,
    sector::Symbol,
    direction::Symbol,
    magnitude::Float64,
    unit::AbstractString,
    application_mode::Symbol,
    target_concepts::Vector{Symbol},
    timing::EventTiming = _cea_timing(),
    persistence::PersistenceSpec = _cea_persistence(),
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
        provenance = _cea_provenance(),
        notes = notes,
        confidence = confidence,
    )
end

struct _CeaDummyModel <: AbstractMacroModel end

@testset "CCC イベント mapping adapter（Issue #201 / E-5）" begin
    targets = capex_credit_cycle_default_targets()
    m = capex_credit_cycle_model(targets)
    options = CapexCreditCycleOptions()
    n = options.horizon_runup + options.horizon_eval
    periods = collect((-options.horizon_runup):(options.horizon_eval - 1))
    baseline = DME._ccc_baseline_exog(m, n)

    map_kwargs = (periods = periods, baseline = baseline)

    @testset "EventMappingRule: レジストリの内部整合" begin
        @test !isempty(CAPEX_CC_EVENT_MAPPING_RULES)
        for r in CAPEX_CC_EVENT_MAPPING_RULES
            @test r.event_type in MACRO_EVENT_TYPES
            if r.target_variable !== nothing
                @test r.target_variable in exogenous_variables(m)   # §10.3 item 2
                @test r.unmapped_reason === nothing
            else
                @test r.unmapped_reason isa Symbol
            end
        end
    end

    @testset "item 3: 7変数すべてが少なくとも1つの event_type から到達可能（被覆）" begin
        mapped_targets =
            Set(r.target_variable for r in CAPEX_CC_EVENT_MAPPING_RULES if r.target_variable !== nothing)
        @test mapped_targets == Set(exogenous_variables(m))
    end

    @testset "item 1・2: 9イベント型それぞれのmapping可否が契約と一致する" begin
        # :DemandOutlookRevision（row 1・1b） — S1/S2/S3 いずれも可
        a1 = _cea_assumption(;
            id = "a-demand-s1",
            event_type = :DemandOutlookRevision,
            sector = :s1,
            direction = :down,
            magnitude = -10.0,
            unit = "%",
            application_mode = :multiplicative,
            target_concepts = [:demand_expectation],
        )
        r1 = map_event(m, a1; map_kwargs...)
        @test r1 isa AppliedModelInput
        @test r1.target_variable === :ai_exp

        a1b_s2 = _cea_assumption(;
            id = "a-demand-s2",
            event_type = :DemandOutlookRevision,
            sector = :s2,
            direction = :down,
            magnitude = -5.0,
            unit = "%",
            application_mode = :multiplicative,
            target_concepts = [:demand_expectation],
        )
        r1b_s2 = map_event(m, a1b_s2; map_kwargs...)
        @test r1b_s2 isa AppliedModelInput
        @test r1b_s2.target_variable === :ext_demand_s2

        a1b_s3 = _cea_assumption(;
            id = "a-demand-s3",
            event_type = :DemandOutlookRevision,
            sector = :s3,
            direction = :down,
            magnitude = -5.0,
            unit = "%",
            application_mode = :multiplicative,
            target_concepts = [:demand_expectation],
        )
        r1b_s3 = map_event(m, a1b_s3; map_kwargs...)
        @test r1b_s3 isa AppliedModelInput
        @test r1b_s3.target_variable === :ext_demand_s3

        # :CapexGuidanceRevision（row 2） — S1 可
        a2 = _cea_assumption(;
            id = "a-capex-guidance",
            event_type = :CapexGuidanceRevision,
            sector = :s1,
            direction = :down,
            magnitude = -15.0,
            unit = "%",
            application_mode = :multiplicative,
            target_concepts = [:capex_plan],
        )
        r2 = map_event(m, a2; map_kwargs...)
        @test r2 isa AppliedModelInput
        @test r2.target_variable === :capex_plan_shock_ex

        # :OrderCancellation（row 3・3b） — S1 率／S2・S3 金額 いずれも可
        a3 = _cea_assumption(;
            id = "a-order-cancel-s1",
            event_type = :OrderCancellation,
            sector = :s1,
            direction = :down,
            magnitude = -8.0,
            unit = "%",
            application_mode = :multiplicative,
            target_concepts = [:order_flow],
        )
        r3 = map_event(m, a3; map_kwargs...)
        @test r3 isa AppliedModelInput
        @test r3.target_variable === :capex_plan_shock_ex

        a3b_s2 = _cea_assumption(;
            id = "a-order-cancel-s2",
            event_type = :OrderCancellation,
            sector = :s2,
            direction = :down,
            magnitude = -3.0,
            unit = "bn USD (2017 chained)",
            application_mode = :additive,
            target_concepts = [:order_flow],
        )
        r3b_s2 = map_event(m, a3b_s2; map_kwargs...)
        @test r3b_s2 isa AppliedModelInput
        @test r3b_s2.target_variable === :ext_demand_s2

        # :PriceOrMarginShock（row 4 可・4b 不可） — S1 のみ可
        a4 = _cea_assumption(;
            id = "a-price-s1",
            event_type = :PriceOrMarginShock,
            sector = :s1,
            direction = :down,
            magnitude = -4.0,
            unit = "%",
            application_mode = :multiplicative,
            target_concepts = [:output_price_margin],
        )
        r4 = map_event(m, a4; map_kwargs...)
        @test r4 isa AppliedModelInput
        @test r4.target_variable === :price_s1

        a4b = _cea_assumption(;
            id = "a-price-s2",
            event_type = :PriceOrMarginShock,
            sector = :s2,
            direction = :down,
            magnitude = -4.0,
            unit = "%",
            application_mode = :multiplicative,
            target_concepts = [:output_price_margin],
        )
        r4b = map_event(m, a4b; map_kwargs...)
        @test r4b isa EventRejection
        @test r4b.code === :unmapped_target
        @test r4b.upstream_issue == "D1"

        # :CreditSpreadShock（row 5） — 部門横断で可
        a5 = _cea_assumption(;
            id = "a-credit-spread",
            event_type = :CreditSpreadShock,
            sector = :unknown,
            direction = :up,
            magnitude = 150.0,
            unit = "bp",
            application_mode = :additive,
            target_concepts = [:credit_spread],
        )
        r5 = map_event(m, a5; map_kwargs...)
        @test r5 isa AppliedModelInput
        @test r5.target_variable === :spread_shock_ex

        # :LendingStandardChange（row 6） — 不可
        a6 = _cea_assumption(;
            id = "a-lending-standard",
            event_type = :LendingStandardChange,
            sector = :s4,
            direction = :down,
            magnitude = -20.0,
            unit = "%",
            application_mode = :multiplicative,
            target_concepts = [:lending_standard],
        )
        r6 = map_event(m, a6; map_kwargs...)
        @test r6 isa EventRejection
        @test r6.code === :unmapped_target
        @test r6.upstream_issue == "D2"

        # :RefinancingOrRatingEvent（row 7 可・7b 不可、notesのreason codeで判定）
        a7 = _cea_assumption(;
            id = "a-refinancing-rating",
            event_type = :RefinancingOrRatingEvent,
            sector = :s1,
            direction = :up,
            magnitude = 80.0,
            unit = "bp",
            application_mode = :additive,
            target_concepts = [:refinancing_condition],
            notes = "reason=rating_downgrade",
        )
        r7 = map_event(m, a7; map_kwargs...)
        @test r7 isa AppliedModelInput
        @test r7.target_variable === :spread_shock_ex

        a7b = _cea_assumption(;
            id = "a-refinancing-unavailable",
            event_type = :RefinancingOrRatingEvent,
            sector = :s1,
            direction = :up,
            magnitude = 80.0,
            unit = "bp",
            application_mode = :additive,
            target_concepts = [:refinancing_condition],
            notes = "reason=refinancing_unavailable",
        )
        r7b = map_event(m, a7b; map_kwargs...)
        @test r7b isa EventRejection
        @test r7b.code === :unmapped_target
        @test r7b.upstream_issue == "D3"

        # :EmploymentPlanRevision（row 8） — 不可
        a8 = _cea_assumption(;
            id = "a-employment-plan",
            event_type = :EmploymentPlanRevision,
            sector = :s1,
            direction = :down,
            magnitude = -5.0,
            unit = "%",
            application_mode = :multiplicative,
            target_concepts = [:employment_plan],
        )
        r8 = map_event(m, a8; map_kwargs...)
        @test r8 isa EventRejection
        @test r8.code === :unmapped_target
        @test r8.upstream_issue == "D4"

        # :PolicyRateChange（row 9） — :absolute・:additive いずれも可
        a9_abs = _cea_assumption(;
            id = "a-policy-rate-abs",
            event_type = :PolicyRateChange,
            sector = :out_of_model,
            direction = :up,
            magnitude = 3.0,
            unit = "%pt",
            application_mode = :absolute,
            target_concepts = [:policy_rate],
        )
        r9_abs = map_event(m, a9_abs; map_kwargs...)
        @test r9_abs isa AppliedModelInput
        @test r9_abs.target_variable === :policy_rate
        @test r9_abs.application_mode === :absolute

        a9_add = _cea_assumption(;
            id = "a-policy-rate-add",
            event_type = :PolicyRateChange,
            sector = :out_of_model,
            direction = :down,
            magnitude = -1.0,
            unit = "%pt",
            application_mode = :additive,
            target_concepts = [:policy_rate],
        )
        r9_add = map_event(m, a9_add; map_kwargs...)
        @test r9_add isa AppliedModelInput
        @test r9_add.target_variable === :policy_rate
        @test r9_add.application_mode === :additive
    end

    @testset "item 4: unmapped_target の理由と upstream_issue（D1–D4）" begin
        cases = Dict(
            "D1" => (:PriceOrMarginShock, :s2, "%", :multiplicative, [:output_price_margin]),
            "D2" => (:LendingStandardChange, :s4, "%", :multiplicative, [:lending_standard]),
            "D4" => (:EmploymentPlanRevision, :s1, "%", :multiplicative, [:employment_plan]),
        )
        for (upstream, (et, sec, unit, mode, tcs)) in cases
            a = _cea_assumption(;
                id = "a-d-code-$(upstream)",
                event_type = et,
                sector = sec,
                direction = :down,
                magnitude = -1.0,
                unit = unit,
                application_mode = mode,
                target_concepts = tcs,
            )
            rej = map_event(m, a; map_kwargs...)
            @test rej isa EventRejection
            @test rej.code === :unmapped_target
            @test rej.upstream_issue == upstream
            @test occursin("構造上", rej.detail)
        end

        # row 3c（着工済み案件のOrderCancellation）は D コードを持たない（#166 改訂、D未割当）。
        row_3c = only(
            filter(
                r -> r.event_type === :OrderCancellation && r.target_variable === nothing,
                CAPEX_CC_EVENT_MAPPING_RULES,
            ),
        )
        @test row_3c.unmapped_reason === :pipeline_cancellation_irreversible
        @test row_3c.upstream_issue == ""
    end

    @testset "item 5: unmapped_target は近似・代理変数で適用されない（baseline不変）" begin
        a4b = _cea_assumption(;
            id = "a-price-s3-unmapped",
            event_type = :PriceOrMarginShock,
            sector = :s3,
            direction = :down,
            magnitude = -6.0,
            unit = "%",
            application_mode = :multiplicative,
            target_concepts = [:output_price_margin],
        )
        rej = map_event(m, a4b; map_kwargs...)
        @test rej isa EventRejection
        # baseline は map_event 呼び出し前後で不変（unmapped は AppliedModelInput を生成しない
        # ため、baseline へ合成される候補にもならない）。
        baseline2 = DME._ccc_baseline_exog(m, n)
        @test baseline2 == baseline
    end

    @testset "item 6: confidence を変えても L4 の values は不変" begin
        a_lo = _cea_assumption(;
            id = "a-confidence-lo",
            event_type = :DemandOutlookRevision,
            sector = :s1,
            direction = :down,
            magnitude = -10.0,
            unit = "%",
            application_mode = :multiplicative,
            target_concepts = [:demand_expectation],
            persistence = _cea_persistence(; shape = :ar1_decay, duration = nothing,
                                            params = (half_life = 6,)),
            confidence = 0.2,
        )
        a_hi = _cea_assumption(;
            id = "a-confidence-hi",
            event_type = :DemandOutlookRevision,
            sector = :s1,
            direction = :down,
            magnitude = -10.0,
            unit = "%",
            application_mode = :multiplicative,
            target_concepts = [:demand_expectation],
            persistence = _cea_persistence(; shape = :ar1_decay, duration = nothing,
                                            params = (half_life = 6,)),
            confidence = 0.95,
        )
        r_lo = map_event(m, a_lo; map_kwargs...)
        r_hi = map_event(m, a_hi; map_kwargs...)
        @test r_lo isa AppliedModelInput && r_hi isa AppliedModelInput
        @test r_lo.values == r_hi.values
    end

    @testset "item 7: baseline_values の保持と :multiplicative の baseline比適用" begin
        a = _cea_assumption(;
            id = "a-mult-baseline",
            event_type = :DemandOutlookRevision,
            sector = :s1,
            direction = :down,
            magnitude = -10.0,
            unit = "%",
            application_mode = :multiplicative,
            target_concepts = [:demand_expectation],
            timing = _cea_timing(0),
            persistence = _cea_persistence(; shape = :step, duration = 4),
        )
        r = map_event(m, a; map_kwargs...)
        @test r isa AppliedModelInput
        @test r.baseline_values == baseline[:ai_exp]
        idx0 = findfirst(==(0), periods)
        # :multiplicative の a_t は "%" 単位（baseline 比）。合成は compose_exogenous_paths /
        # capex_exogenous_paths の責務だが、L4.values 自体は magnitude をそのまま反映する。
        @test r.values[idx0] == -10.0
        @test r.values[idx0 - 1] == 0.0   # t < t_apply では非作用
    end

    @testset "item 8: 既定メソッドは unsupported_model を返す" begin
        dummy = _CeaDummyModel()
        a = _cea_assumption(;
            id = "a-unsupported-model",
            event_type = :DemandOutlookRevision,
            sector = :s1,
            direction = :down,
            magnitude = -10.0,
            unit = "%",
            application_mode = :multiplicative,
            target_concepts = [:demand_expectation],
        )
        rej = map_event(dummy, a; map_kwargs...)
        @test rej isa EventRejection
        @test rej.code === :unsupported_model
    end

    @testset "item 9: entity付きイベントの部門集約は本層の対象外（Y-03、構造で防止）" begin
        # ScenarioAssumption（L3）は entity フィールドを持たない（Y-03）。企業レベルの
        # InterpretedSignal（L2）を集約せずそのまま L3 化することは型として不可能であり、
        # 「aggregation_not_implemented」相当の防止は本 adapter 到達前の型で保証される
        # （L2→L3 の集約器は本Issueの対象外。統合設計 §12.4 事項2）。
        @test !(:entity in fieldnames(ScenarioAssumption))
        sig = interpreted_signal(;
            event_id = "sig-entity-1",
            event_type = :DemandOutlookRevision,
            announced_at = Date(2026, 1, 15),
            observed_at = Date(2026, 1, 15),
            known_at = Date(2026, 1, 15),
            source = EventSource(; publisher = "fictional issuer", document_id = "doc-1"),
            provenance = _cea_provenance(:interpreted),
            sector = :s1,
            direction = :down,
            magnitude_source = :disclosed,
            confidence = 0.7,
            entity = "Fictional Corp",
            magnitude = -8.0,
            unit = "%",
            target_concepts = [:demand_expectation],
        )
        @test sig.entity == "Fictional Corp"
        # sig を直接 map_event へ渡すことはできない（引数型が ScenarioAssumption のみ）。
        @test !applicable(map_event, m, sig)
    end

    @testset "item 10: event_id → assumption_id → input_id の追跡" begin
        assumption_id = "a-traceability"
        a = _cea_assumption(;
            id = assumption_id,
            event_type = :CreditSpreadShock,
            sector = :unknown,
            direction = :up,
            magnitude = 100.0,
            unit = "bp",
            application_mode = :additive,
            target_concepts = [:credit_spread],
        )
        r = map_event(m, a; map_kwargs...)
        @test r isa AppliedModelInput
        @test r.assumption_id == assumption_id
        @test occursin(assumption_id, r.input_id)
        @test r.provenance.derived_from == [assumption_id]
    end

    @testset "Phase 1互換: capex_scenario_assumptions が Sc0–Sc4 を再現する" begin
        sc_options = CapexCreditCycleOptions()
        for id in CAPEX_CC_SCENARIO_IDS
            legacy_paths = capex_exogenous_paths(m, capex_scenario(id), sc_options)
            assumptions = capex_scenario_assumptions(id)
            if id === :Sc0
                @test isempty(assumptions)
            end

            inputs = AppliedModelInput[]
            for a in assumptions
                r = map_event(m, a; periods = periods, baseline = baseline)
                @test r isa AppliedModelInput
                push!(inputs, r)
            end

            sc = Scenario(;
                id = id,
                model = :capex_credit_cycle,
                horizon_runup = sc_options.horizon_runup,
                horizon_eval = sc_options.horizon_eval,
                assumptions = assumptions,
            )
            schedule = schedule_events(inputs, sc, baseline)
            @test isempty(schedule.rejections)

            for target in exogenous_variables(m)
                @test schedule.paths[target] ≈ legacy_paths[target]
            end
        end
    end

    @testset "決定性: 入力順をshuffleしても mapping 結果は同一" begin
        id = :Sc4
        assumptions = capex_scenario_assumptions(id)
        inputs1 = [map_event(m, a; periods = periods, baseline = baseline) for a in assumptions]
        inputs2 = [
            map_event(m, a; periods = periods, baseline = baseline) for
            a in reverse(assumptions)
        ]
        @test Set(i.input_id for i in inputs1) == Set(i.input_id for i in inputs2)
        for i1 in inputs1
            i2 = only(filter(x -> x.input_id == i1.input_id, inputs2))
            @test i1.values == i2.values
            @test i1.baseline_values == i2.baseline_values
        end
    end
end
