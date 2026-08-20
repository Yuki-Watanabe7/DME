# 4層概念階層の共通型（src/scenarios/scenario_time.jl・macro_events.jl・scenario_types.jl）の
# テスト（Issue #197 / `E-1`）。
#
# 統合設計 §10.1（型と契約、16項目）のうち本Issueの受け入れ条件である 1–9・13–16 を対象と
# する。10–12（イベント型レジストリとの逐語照合・`CAPEX_CC_EVENT_MAPPING_RULES` の行数一致）は
# レジストリ（Issue #199・#200）と mapping adapter（Issue #201）の対象であり、本ファイルでは
# 検査しない。
#
# 注意（実装スコープの調整）:
#   - 項目2（`L1`/`L2`から`AppliedModelInput`を生成する公開メソッドが存在しないこと）は、
#     `map_event`（Issue #201 / `E-5`で定義）の引数型が `ScenarioAssumption`（L3）限定である
#     ことを `applicable` で確認する形へ更新した（型注釈自体による強制、統合設計 §5.2 契約2）。
#     4層が構造的に独立した型であり暗黙の変換経路（`Base.convert` 等）を持たないことも
#     あわせて確認する。`CAPEX_CC_EVENT_MAPPING_RULES` の逐語照合等 mapping adapter 固有の
#     検査（項目10–12相当）は test/test_capex_event_adapter.jl（Issue #201）が対象とする。
#   - 項目13のうち `SCENARIO_EXECUTION_STATUSES`（4値）は `run_scenario`（Issue #202）が
#     定義するため対象外とし、本ファイルでは `MACRO_EVENT_REJECTION_CODES`（12種）・
#     `MACRO_EVENT_WARNING_CODES`（12種）のみを検査する。
#   - `MACRO_EVENT_TYPES`（9種の型シンボルの確定集合）は本Issueの実施内容の明示的な
#     語彙定数一覧には無いが、項目7・8（未登録`event_type`の拒否・`:other`の層限定）を
#     実装するために必須であるため、`macro_events.jl` で定義している（同ファイル冒頭の
#     コメント参照）。型別の詳細規則（許可部門・許可単位等）は Issue #199・#200 が持つ
#     `MacroEventTypeSpec` レジストリの対象であり、本ファイルでは検査しない。

using Dates: Date

# ------------------------------------------------------------
# テスト用ヘルパ（fictional。実在企業・実在イベントを用いない）
# ------------------------------------------------------------

struct _MevDummyModel <: AbstractMacroModel end

_mev_source(; document_id::String = "doc-1") =
    EventSource(publisher = "fictional wire", document_id = document_id)

_mev_provenance(layer::Symbol; derived_from::Vector{String} = String[], rule_id = "r1") =
    EventProvenance(; layer = layer, rule_id = rule_id, rule_version = "1.0.0", generator = "human", derived_from = derived_from)

_mev_timing(; t_apply::Int = 0) = EventTiming(; basis = :period, rule = :explicit_period, t_apply = t_apply)

_mev_persistence(; shape::Symbol = :step, duration = nothing, params = NamedTuple()) =
    PersistenceSpec(; shape = shape, duration = duration, params = params)

function _mev_observed(; event_id = "OE-1", event_type = :DemandOutlookRevision, kwargs...)
    return ObservedEvent(;
        event_id = event_id, event_type = event_type,
        announced_at = Date(2026, 1, 15), observed_at = Date(2026, 1, 15), known_at = Date(2026, 1, 16),
        source = _mev_source(), provenance = _mev_provenance(:observed),
        kwargs...,
    )
end

function _mev_interpreted(; event_id = "IS-1", event_type = :DemandOutlookRevision, kwargs...)
    return InterpretedSignal(;
        event_id = event_id, event_type = event_type,
        announced_at = Date(2026, 1, 15), observed_at = Date(2026, 1, 15), known_at = Date(2026, 1, 16),
        source = _mev_source(), provenance = _mev_provenance(:interpreted; derived_from = ["OE-1"]),
        sector = :s1, direction = :down, magnitude_source = :external_belief, confidence = 0.6,
        target_concepts = [:demand_expectation],
        kwargs...,
    )
end

function _mev_assumption(; assumption_id = "SA-1", event_type = :DemandOutlookRevision, kwargs...)
    return ScenarioAssumption(;
        assumption_id = assumption_id, event_type = event_type,
        sector = :s1, direction = :down, magnitude = -10.0, unit = "%",
        magnitude_source = :assumed_default, application_mode = :multiplicative,
        timing = _mev_timing(), persistence = _mev_persistence(),
        target_concepts = [:demand_expectation],
        provenance = _mev_provenance(:assumption; derived_from = ["IS-1"]),
        kwargs...,
    )
end

function _mev_applied(; input_id = "AI-1", kwargs...)
    return AppliedModelInput(;
        input_id = input_id, assumption_id = "SA-1", model = :capex_credit_cycle,
        target_variable = :ai_exp, application_mode = :multiplicative, unit = "%",
        magnitude = -10.0, persistence = _mev_persistence(), t_apply = 0,
        values = [0.0, -10.0], baseline_values = [1.0, 1.0],
        mapping_id = "map-1", mapping_version = "1.0.0",
        provenance = _mev_provenance(:applied; derived_from = ["SA-1"]),
        kwargs...,
    )
end

@testset "AbstractMacroEvent 4層と共通型（Issue #197 / E-1）" begin
    @testset "smoke test（CLAUDE.md）" begin
        @test _mev_observed() isa ObservedEvent
        @test _mev_interpreted() isa InterpretedSignal
        @test _mev_assumption() isa ScenarioAssumption
        @test _mev_applied() isa AppliedModelInput
    end

    @testset "統合設計 §10.1-1: 4層が別型であり AbstractMacroEvent の部分型" begin
        @test ObservedEvent <: AbstractMacroEvent
        @test InterpretedSignal <: AbstractMacroEvent
        @test ScenarioAssumption <: AbstractMacroEvent
        @test AppliedModelInput <: AbstractMacroEvent
        @test ObservedEvent !== InterpretedSignal !== ScenarioAssumption !== AppliedModelInput
    end

    @testset "統合設計 §10.1-2: L1/L2 から AppliedModelInput への直接経路が無い（map_event は #201）" begin
        # `map_event`（#201/`E-5`で定義）の引数型は `ScenarioAssumption`（L3）のみであり、
        # `ObservedEvent`（L1）・`InterpretedSignal`（L2）を直接受け取るメソッドは存在しない
        # （統合設計 §5.2 契約2「L1/L2からL4を生成する公開関数を提供しない」）。暗黙のconvertも
        # 存在しないことをあわせて確認する。
        @test isdefined(DME, :map_event)
        dummy = _MevDummyModel()
        @test !applicable(map_event, dummy, _mev_observed())
        @test !applicable(map_event, dummy, _mev_interpreted())
        @test !hasmethod(convert, Tuple{Type{AppliedModelInput}, ObservedEvent})
        @test !hasmethod(convert, Tuple{Type{AppliedModelInput}, InterpretedSignal})
    end

    @testset "統合設計 §10.1-3: magnitude 未設定（missing）と 0.0 が区別される（L1・L2）" begin
        oe_missing = _mev_observed()
        oe_zero = _mev_observed(event_id = "OE-2", magnitude = 0.0, unit = "%")
        @test oe_missing.magnitude === missing
        @test oe_zero.magnitude === 0.0
        @test oe_missing.magnitude !== oe_zero.magnitude

        is_missing = _mev_interpreted()
        is_zero = _mev_interpreted(event_id = "IS-2", magnitude = 0.0, unit = "%")
        @test is_missing.magnitude === missing
        @test is_zero.magnitude === 0.0
    end

    @testset "統合設計 §10.1-4: L3 の magnitude は Float64 であり missing を代入できない" begin
        @test fieldtype(ScenarioAssumption, :magnitude) === Float64
        @test fieldtype(AppliedModelInput, :magnitude) === Float64
        @test_throws Exception _mev_assumption(magnitude = missing)
    end

    @testset "統合設計 §10.1-5: NaN/Inf の magnitude が全層で ArgumentError" begin
        for bad in (NaN, Inf, -Inf)
            @test_throws ArgumentError _mev_observed(event_id = "x", magnitude = bad, unit = "%")
            @test_throws ArgumentError _mev_interpreted(event_id = "x", magnitude = bad, unit = "%")
            @test_throws ArgumentError _mev_assumption(assumption_id = "x", magnitude = bad)
            @test_throws ArgumentError _mev_applied(input_id = "x", magnitude = bad)
        end
    end

    @testset "統合設計 §10.1-6: 空ID・confidence∉[0,1]・quarter∉1:4・duration≤0 が ArgumentError" begin
        # 空ID
        @test_throws ArgumentError _mev_observed(event_id = "")
        @test_throws ArgumentError _mev_assumption(assumption_id = "")
        @test_throws ArgumentError _mev_applied(input_id = "")
        @test_throws ArgumentError EventSource(publisher = "p", document_id = "")

        # confidence ∉ [0,1]
        @test_throws ArgumentError _mev_interpreted(event_id = "x", confidence = 1.5)
        @test_throws ArgumentError _mev_interpreted(event_id = "y", confidence = -0.1)
        @test_throws ArgumentError _mev_assumption(assumption_id = "x", confidence = 1.1)

        # quarter ∉ 1:4
        @test_throws ArgumentError CalendarQuarter(2026, 0)
        @test_throws ArgumentError CalendarQuarter(2026, 5)
        @test CalendarQuarter(2026, 1) isa CalendarQuarter

        # duration ≤ 0
        @test_throws ArgumentError _mev_persistence(shape = :ramp, duration = 0)
        @test_throws ArgumentError _mev_persistence(shape = :ramp, duration = -4)
        @test_throws ArgumentError _mev_persistence(shape = :step, duration = -1)
        @test _mev_persistence(shape = :ramp, duration = 4) isa PersistenceSpec
    end

    @testset "統合設計 §10.1-7: 未登録 event_type が全層で ArgumentError（generic eventへ落ちない）" begin
        @test_throws ArgumentError _mev_observed(event_id = "x", event_type = :NotARealEventType)
        @test_throws ArgumentError _mev_interpreted(event_id = "x", event_type = :NotARealEventType)
        @test_throws ArgumentError _mev_assumption(assumption_id = "x", event_type = :NotARealEventType)
        @test length(MACRO_EVENT_TYPES) == 9
    end

    @testset "統合設計 §10.1-8: :other が L1・L2 で許容され、L3 で unsupported_event_type になる（Y-01）" begin
        @test _mev_observed(event_id = "x", event_type = :other) isa ObservedEvent
        @test _mev_interpreted(event_id = "x", event_type = :other) isa InterpretedSignal
        err = try
            _mev_assumption(assumption_id = "x", event_type = :other)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("unsupported_event_type", sprint(showerror, err))
    end

    @testset "統合設計 §10.1-9: unit × application_mode の許容表（#168 §3.3、§12.1改訂後）" begin
        # 許容される組み合わせ
        @test _mev_assumption(assumption_id = "a", unit = "%", application_mode = :multiplicative) isa ScenarioAssumption
        @test _mev_assumption(
            assumption_id = "b", event_type = :CreditSpreadShock, unit = "bp",
            application_mode = :additive, target_concepts = [:credit_spread],
        ) isa ScenarioAssumption
        @test _mev_assumption(
            assumption_id = "c", event_type = :PolicyRateChange, unit = "%pt",
            application_mode = :absolute, target_concepts = [:policy_rate],
        ) isa ScenarioAssumption
        @test _mev_assumption(
            assumption_id = "d", event_type = :OrderCancellation, unit = "bn USD (2017 chained)",
            application_mode = :additive, target_concepts = [:order_flow],
        ) isa ScenarioAssumption

        # 非許容の組み合わせ（invalid_unit_mode）
        err = try
            _mev_assumption(assumption_id = "e", event_type = :CreditSpreadShock, unit = "bp", application_mode = :multiplicative, target_concepts = [:credit_spread])
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("invalid_unit_mode", sprint(showerror, err))
        @test_throws ArgumentError _mev_assumption(assumption_id = "f", unit = "%", application_mode = :additive)
        # 単位語彙に無い unit
        @test_throws ArgumentError _mev_assumption(assumption_id = "g", unit = "EUR", application_mode = :additive)

        # AppliedModelInput でも同一表を適用する
        @test _mev_applied(input_id = "h", unit = "%", application_mode = :multiplicative) isa AppliedModelInput
        @test_throws ArgumentError _mev_applied(input_id = "i", unit = "bp", application_mode = :multiplicative)
    end

    @testset "統合設計 §10.1-13: REJECTION_CODES/WARNING_CODES が各12種（SCENARIO_EXECUTION_STATUSESは#202対象）" begin
        @test length(MACRO_EVENT_REJECTION_CODES) == 12
        @test length(unique(MACRO_EVENT_REJECTION_CODES)) == 12
        @test length(MACRO_EVENT_WARNING_CODES) == 12
        @test length(unique(MACRO_EVENT_WARNING_CODES)) == 12
        @test_throws ArgumentError EventRejection(code = :not_a_real_code, layer = :assumption, detail = "x")
        @test_throws ArgumentError ScenarioWarning(code = :not_a_real_code, detail = "x")
    end

    @testset "統合設計 §10.1-14: EventRejection.detail が「影響が無い」「効果が無い」を含まない" begin
        @test_throws ArgumentError EventRejection(code = :unmapped_target, layer = :assumption, detail = "影響が無いため無視")
        @test_throws ArgumentError EventRejection(code = :unmapped_target, layer = :assumption, detail = "効果が無い")
        # unmapped_target の detail は構造上の非表現である旨を含む
        @test_throws ArgumentError EventRejection(code = :unmapped_target, layer = :assumption, detail = "適用先が見つかりません")
        rej = EventRejection(code = :unmapped_target, layer = :assumption, detail = "モデルが構造上この事象を表現しません")
        @test rej isa EventRejection
        # 他のコードでは同じ制約を課さない（構造上の非表現である必要はない）
        @test EventRejection(code = :duplicate_event_id, layer = :observed, detail = "同一event_idが2件あります") isa EventRejection
    end

    @testset "統合設計 §10.1-15: entity フィールドが ScenarioAssumption に存在しない（Y-03）" begin
        @test !(:entity in fieldnames(ScenarioAssumption))
        @test !(:entity_weight in fieldnames(ScenarioAssumption))
        @test :entity in fieldnames(ObservedEvent)
        @test :entity in fieldnames(InterpretedSignal)
    end

    @testset "統合設計 §10.1-16: 全レコード型が immutable でフィールド順が固定" begin
        for T in (
            EventSource, EventProvenance, PersistenceSpec, EventTiming,
            ObservedEvent, InterpretedSignal, ScenarioAssumption, AppliedModelInput,
            CalendarQuarter, TimingRuleSet, Scenario, ScenarioWarning, EventRejection,
        )
            @test !ismutabletype(T)
        end
        @test fieldnames(ObservedEvent) == (
            :event_id, :event_type, :schema_version, :announced_at, :observed_at, :known_at,
            :effective_from, :effective_until, :source, :entity, :sector, :geography, :direction,
            :magnitude, :unit, :supersedes, :provenance, :notes,
        )
        @test fieldnames(ScenarioAssumption) == (
            :assumption_id, :event_type, :schema_version, :sector, :geography, :direction,
            :magnitude, :unit, :magnitude_source, :application_mode, :timing, :persistence,
            :target_concepts, :is_scenario_assumption, :confidence, :uncertainty, :provenance,
            :notes, :caveats,
        )
        @test fieldnames(AppliedModelInput) == (
            :input_id, :assumption_id, :model, :target_variable, :application_mode, :unit,
            :magnitude, :persistence, :t_apply, :values, :baseline_values, :mapping_id,
            :mapping_version, :warnings, :provenance,
        )
    end

    @testset "version 定数6個（統合設計 §5.1）" begin
        @test MACRO_EVENT_CONTRACT_VERSION == "macro-event-contract/1.0.2"
        @test SCENARIO_TIME_SEMANTICS_VERSION == "scenario-time-semantics/1.1.0"
        @test MACRO_EVENT_RUNTIME_VERSION == "macro-event-runtime/1.0.0"
        @test EVENT_RULE_VERSION isa String
        @test CAPEX_CC_EVENT_MAPPING_VERSION isa String
        @test SCENARIO_ARTIFACT_SCHEMA_VERSION isa String
    end

    @testset "validate_event は正常に構築済みの値に対して常に nothing を返す" begin
        @test validate_event(_mev_observed(event_id = "v1")) === nothing
        @test validate_event(_mev_interpreted(event_id = "v2")) === nothing
        @test validate_event(_mev_assumption(assumption_id = "v3")) === nothing
        @test validate_event(_mev_applied(input_id = "v4")) === nothing
    end

    @testset "EventProvenance: layer不整合・derived_from欠落（provenance欠落）" begin
        @test_throws ArgumentError _mev_observed(event_id = "x", provenance = _mev_provenance(:applied))
        @test_throws ArgumentError EventProvenance(layer = :interpreted, rule_id = "r", rule_version = "1", generator = "human")
        @test EventProvenance(layer = :observed, rule_id = "r", rule_version = "1", generator = "human") isa EventProvenance
        @test_throws ArgumentError EventProvenance(layer = :observed, rule_id = "", rule_version = "1", generator = "human")
    end

    @testset "EventTiming: :calendar と :period の2基準が排他的（Y-02）" begin
        @test EventTiming(basis = :period, rule = :explicit_period, t_apply = 3) isa EventTiming
        @test EventTiming(basis = :calendar, rule = :same_quarter, effective_from = Date(2026, 3, 1)) isa EventTiming
        @test_throws ArgumentError EventTiming(basis = :calendar, rule = :same_quarter, t_apply = 1)
        @test_throws ArgumentError EventTiming(basis = :calendar, rule = :same_quarter)
        @test_throws ArgumentError EventTiming(basis = :period, rule = :explicit_period, effective_from = Date(2026, 3, 1))
        @test_throws ArgumentError EventTiming(basis = :period, rule = :explicit_period)
        @test_throws ArgumentError EventTiming(basis = :calendar, rule = :explicit_period, effective_from = Date(2026, 3, 1))
        @test_throws ArgumentError EventTiming(basis = :period, rule = :same_quarter, t_apply = 1)
    end

    @testset "PersistenceSpec: 6形状の shape_params 検証（Y-11・Y-12）" begin
        @test PersistenceSpec(shape = :pulse) isa PersistenceSpec
        @test PersistenceSpec(shape = :step) isa PersistenceSpec
        @test PersistenceSpec(shape = :step, duration = 4) isa PersistenceSpec
        @test PersistenceSpec(shape = :ramp, duration = 4) isa PersistenceSpec
        @test_throws ArgumentError PersistenceSpec(shape = :ramp)
        @test PersistenceSpec(shape = :step_then_ramp, params = (hold = 4, ramp_down = 4)) isa PersistenceSpec
        @test_throws ArgumentError PersistenceSpec(shape = :step_then_ramp)
        @test_throws ArgumentError PersistenceSpec(shape = :step_then_ramp, params = (hold = 0, ramp_down = 4))
        @test PersistenceSpec(shape = :ar1_decay, params = (half_life = 6,)) isa PersistenceSpec
        @test_throws ArgumentError PersistenceSpec(shape = :ar1_decay)
        @test_throws ArgumentError PersistenceSpec(shape = :ar1_decay, params = (half_life = -1,))
        @test PersistenceSpec(shape = :path, params = (values = [1.0, 2.0],)) isa PersistenceSpec
        @test_throws ArgumentError PersistenceSpec(shape = :path)
        @test_throws ArgumentError PersistenceSpec(shape = :path, params = (values = Float64[],))
    end

    @testset "path の magnitude 不一致・magnitude_source 制約（Y-12）" begin
        path_persist = _mev_persistence(shape = :path, params = (values = [4.0, -8.0, 2.0],))
        @test _mev_assumption(
            assumption_id = "p1", event_type = :CreditSpreadShock, unit = "bp", application_mode = :additive,
            magnitude = 8.0, magnitude_source = :observed, persistence = path_persist,
            target_concepts = [:credit_spread],
        ) isa ScenarioAssumption
        @test_throws ArgumentError _mev_assumption(
            assumption_id = "p2", event_type = :CreditSpreadShock, unit = "bp", application_mode = :additive,
            magnitude = 5.0, magnitude_source = :observed, persistence = path_persist,
            target_concepts = [:credit_spread],
        )
        # :assumed_default の path は許容されない（マクロイベント変換契約 §5.2-4）
        @test_throws ArgumentError _mev_assumption(
            assumption_id = "p3", event_type = :CreditSpreadShock, unit = "bp", application_mode = :additive,
            magnitude = 8.0, magnitude_source = :assumed_default, persistence = path_persist,
            target_concepts = [:credit_spread],
        )
    end

    @testset "ScenarioAssumption.direction=:unknown は許容されない" begin
        @test_throws ArgumentError _mev_assumption(assumption_id = "x", direction = :unknown)
    end

    @testset "target_concepts: 未知concept拒否・ScenarioAssumptionは非空必須" begin
        @test_throws ArgumentError _mev_assumption(assumption_id = "x", target_concepts = Symbol[])
        @test_throws ArgumentError _mev_assumption(assumption_id = "y", target_concepts = [:not_a_real_concept])
        @test length(MACRO_EVENT_TARGET_CONCEPTS) == 9
    end

    @testset "AppliedModelInput: values/baseline_values の長さ一致・warnings語彙" begin
        @test_throws ArgumentError _mev_applied(input_id = "x", values = [0.0, -10.0, -5.0])
        @test_throws ArgumentError _mev_applied(input_id = "y", values = Float64[], baseline_values = Float64[])
        @test_throws ArgumentError _mev_applied(input_id = "z", warnings = [:not_a_real_warning])
        @test _mev_applied(input_id = "w", warnings = [:extreme_shock]) isa AppliedModelInput
    end

    @testset "Scenario: 空 assumptions は正当な baseline" begin
        sc = Scenario(id = :baseline, model = :capex_credit_cycle)
        @test isempty(sc.assumptions)
        @test sc.timing_rules isa TimingRuleSet
        sc2 = Scenario(id = :with_one, model = :capex_credit_cycle, assumptions = [_mev_assumption()])
        @test length(sc2.assumptions) == 1
    end

    @testset "TimingRuleSet: 既定値" begin
        trs = TimingRuleSet()
        @test trs.id == "default"
        @test trs.cutoff_month_offset == 2
        @test isempty(trs.rules)
    end
end
