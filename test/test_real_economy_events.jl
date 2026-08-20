# イベント型レジストリと実体経済イベント型5種のテスト（src/scenarios/event_type_registry.jl、
# Issue #199 / `E-3`）。
#
# 統合設計 §10.1（型と契約）のうち本Issue対象の項目10（レジストリ5行がマクロイベント変換契約
# §4.2・§4.3の表と逐語一致）と、Issue #199本文「テスト期待」（各イベント型の正常系・
# 定性的イベント・数量付きイベント・符号不一致・unit不一致・期間不一致・unknown sector・
# duplicate）を対象とする。`unmapped_target` の判定自体（#201 mapping adapter の責務）は
# 対象外とし、本ファイルは `inapplicable_conditions` が宣言として保持されていることのみを
# 確認する。
#
# fixture: `test/fixtures/events/real_economy/*.json` は本ファイルと同じ synthetic
# （fictional）データを人間可読な形で記録した参考資料であり、`test/fixtures/capex_credit_cycle/`
# と同様プログラム的には読み込まない。

using Dates: Date

# ------------------------------------------------------------
# テスト用ヘルパ（fictional。実在企業・実在イベントを用いない）
# ------------------------------------------------------------

_ree_source(; document_id::String = "doc-ree-1") =
    EventSource(publisher = "fictional wire", document_id = document_id)

_ree_provenance(layer::Symbol; derived_from::Vector{String} = String[]) = EventProvenance(;
    layer = layer,
    rule_id = "test-real-economy-rule",
    rule_version = "1.0.0",
    generator = "test_real_economy_events.jl",
    derived_from = derived_from,
)

_ree_timing(; t_apply::Int = 0) =
    EventTiming(; basis = :period, rule = :explicit_period, t_apply = t_apply)

_ree_persistence(; shape::Symbol = :step, duration = 4, params::NamedTuple = NamedTuple()) =
    PersistenceSpec(; shape = shape, duration = duration, params = params)

function _ree_observed(;
    event_id::String = "OE-ree-1",
    event_type::Symbol = :DemandOutlookRevision,
    kwargs...,
)
    return observed_event(;
        event_id = event_id,
        event_type = event_type,
        announced_at = Date(2026, 2, 10),
        observed_at = Date(2026, 2, 10),
        known_at = Date(2026, 2, 11),
        source = _ree_source(),
        provenance = _ree_provenance(:observed),
        kwargs...,
    )
end

function _ree_interpreted(;
    event_id::String = "IS-ree-1",
    event_type::Symbol = :DemandOutlookRevision,
    sector::Symbol = :s1,
    direction::Symbol = :down,
    magnitude_source::Symbol = :external_belief,
    confidence::Float64 = 0.6,
    target_concepts::Vector{Symbol} = [:demand_expectation],
    kwargs...,
)
    return interpreted_signal(;
        event_id = event_id,
        event_type = event_type,
        announced_at = Date(2026, 2, 10),
        observed_at = Date(2026, 2, 10),
        known_at = Date(2026, 2, 11),
        source = _ree_source(),
        provenance = _ree_provenance(:interpreted; derived_from = ["OE-ree-1"]),
        sector = sector,
        direction = direction,
        magnitude_source = magnitude_source,
        confidence = confidence,
        target_concepts = target_concepts,
        kwargs...,
    )
end

function _ree_assumption(;
    assumption_id::String = "SA-ree-1",
    event_type::Symbol = :DemandOutlookRevision,
    sector::Symbol = :s1,
    direction::Symbol = :down,
    magnitude::Float64 = -10.0,
    unit::String = "%",
    magnitude_source::Symbol = :assumed_default,
    application_mode::Symbol = :multiplicative,
    target_concepts::Vector{Symbol} = [:demand_expectation],
    timing = _ree_timing(),
    persistence = _ree_persistence(),
    kwargs...,
)
    return scenario_assumption(;
        assumption_id = assumption_id,
        event_type = event_type,
        sector = sector,
        direction = direction,
        magnitude = magnitude,
        unit = unit,
        magnitude_source = magnitude_source,
        application_mode = application_mode,
        timing = timing,
        persistence = persistence,
        target_concepts = target_concepts,
        provenance = _ree_provenance(:assumption; derived_from = ["IS-ree-1"]),
        kwargs...,
    )
end

const _REE_TYPES = (
    :DemandOutlookRevision,
    :CapexGuidanceRevision,
    :OrderCancellation,
    :PriceOrMarginShock,
    :EmploymentPlanRevision,
)

# 各型の「正常系」引数一式（sector・unit・application_mode・target_concepts の組）。
# マクロイベント変換契約 §4.2 row 1/2/3/4/8 から1:1で写す。
const _REE_HAPPY_PATH = Dict{Symbol, NamedTuple}(
    :DemandOutlookRevision => (
        sector = :s1, unit = "%", application_mode = :multiplicative,
        target_concepts = [:demand_expectation],
    ),
    :CapexGuidanceRevision => (
        sector = :s1, unit = "%", application_mode = :multiplicative,
        target_concepts = [:capex_plan],
    ),
    :OrderCancellation => (
        sector = :s1, unit = "%", application_mode = :multiplicative,
        target_concepts = [:order_flow],
    ),
    :PriceOrMarginShock => (
        sector = :s1, unit = "%", application_mode = :multiplicative,
        target_concepts = [:output_price_margin],
    ),
    :EmploymentPlanRevision => (
        sector = :s1, unit = "%", application_mode = :multiplicative,
        target_concepts = [:employment_plan],
    ),
)

@testset "イベント型レジストリと実体経済イベント型5種（Issue #199 / E-3）" begin
    @testset "smoke test（CLAUDE.md）" begin
        @test _ree_observed() isa ObservedEvent
        @test _ree_interpreted() isa InterpretedSignal
        @test _ree_assumption() isa ScenarioAssumption
        @test macro_event_type_spec(:DemandOutlookRevision) isa MacroEventTypeSpec
    end

    @testset "レジストリに実体経済側5種が登録されている" begin
        for t in _REE_TYPES
            @test haskey(MACRO_EVENT_TYPE_REGISTRY, t)
            spec = macro_event_type_spec(t)
            @test spec.event_type === t
            @test spec isa MacroEventTypeSpec
        end
        @test length(MACRO_EVENT_TYPE_REGISTRY) == 5
    end

    @testset "未登録 event_type は macro_event_type_spec で ArgumentError（generic へ縮約しない）" begin
        @test_throws ArgumentError macro_event_type_spec(:NotARealEventType)
        # 信用・政策側4種は Issue #200 が登録するため、本Issue時点では未登録
        @test_throws ArgumentError macro_event_type_spec(:CreditSpreadShock)
        @test_throws ArgumentError macro_event_type_spec(:other)
    end

    @testset "レジストリ5行がマクロイベント変換契約 §4.2・§4.3 の表と逐語一致する" begin
        # (allowed_units, allowed_application_modes, default_timing_rule, default_shape)
        expected = Dict{Symbol, Tuple}(
            :DemandOutlookRevision => (["%"], [:multiplicative], :cutoff, :ar1_decay),
            :CapexGuidanceRevision => (["%"], [:multiplicative], :cutoff, :step_then_ramp),
            :OrderCancellation =>
                (["%", "bn USD (2017 chained)"], [:multiplicative, :additive], :same_quarter, :step),
            :PriceOrMarginShock => (["%"], [:multiplicative], :cutoff, :ar1_decay),
            :EmploymentPlanRevision => (["%"], [:multiplicative], nothing, nothing),
        )
        for (t, (units, modes, rule, shape)) in expected
            spec = macro_event_type_spec(t)
            @test spec.allowed_units == units
            @test spec.allowed_application_modes == modes
            @test spec.default_timing_rule === rule
            @test spec.default_shape === shape
        end
        # 半減期・hold/ramp_down・duration の既定値（契約 §4.3）
        @test macro_event_type_spec(:DemandOutlookRevision).default_shape_params.half_life == 6
        @test macro_event_type_spec(:PriceOrMarginShock).default_shape_params.half_life == 4
        @test macro_event_type_spec(:CapexGuidanceRevision).default_shape_params.hold == 4
        @test macro_event_type_spec(:CapexGuidanceRevision).default_shape_params.ramp_down == 4
        @test macro_event_type_spec(:OrderCancellation).default_duration == 4
    end

    @testset "MacroEventTypeSpec: 未知の登録値は ArgumentError（レジストリ実装の自己検査）" begin
        @test_throws ArgumentError MacroEventTypeSpec(;
            event_type = :NotARealEventType, display_name = "x", allowed_sectors = Symbol[],
            allowed_scope = Symbol[], allowed_target_concepts = [:demand_expectation],
            allowed_units = String[], allowed_application_modes = Symbol[],
            contract_section = "test",
        )
        @test_throws ArgumentError MacroEventTypeSpec(;
            event_type = :DemandOutlookRevision, display_name = "x", allowed_sectors = Symbol[],
            allowed_scope = [:not_a_real_scope], allowed_target_concepts = [:demand_expectation],
            allowed_units = String[], allowed_application_modes = Symbol[],
            contract_section = "test",
        )
        @test_throws ArgumentError MacroEventTypeSpec(;
            event_type = :DemandOutlookRevision, display_name = "x", allowed_sectors = Symbol[],
            allowed_scope = Symbol[], allowed_target_concepts = Symbol[],
            allowed_units = String[], allowed_application_modes = Symbol[],
            contract_section = "test",
        )
        @test_throws ArgumentError MacroEventTypeSpec(;
            event_type = :DemandOutlookRevision, display_name = "x", allowed_sectors = Symbol[],
            allowed_scope = Symbol[], allowed_target_concepts = [:demand_expectation],
            allowed_units = ["EUR"], allowed_application_modes = Symbol[],
            contract_section = "test",
        )
        # default_shape と default_timing_rule は両方 nothing か両方非 nothing
        @test_throws ArgumentError MacroEventTypeSpec(;
            event_type = :DemandOutlookRevision, display_name = "x", allowed_sectors = Symbol[],
            allowed_scope = Symbol[], allowed_target_concepts = [:demand_expectation],
            allowed_units = ["%"], allowed_application_modes = [:multiplicative],
            contract_section = "test", default_shape = :step, default_timing_rule = nothing,
        )
        # shape_params 欠落はレジストリ登録時に検出される
        @test_throws ArgumentError MacroEventTypeSpec(;
            event_type = :DemandOutlookRevision, display_name = "x", allowed_sectors = Symbol[],
            allowed_scope = Symbol[], allowed_target_concepts = [:demand_expectation],
            allowed_units = ["%"], allowed_application_modes = [:multiplicative],
            contract_section = "test", default_shape = :ar1_decay, default_timing_rule = :cutoff,
            default_shape_params = NamedTuple(),
        )
    end

    @testset "各型の正常系（observed_event/interpreted_signal/scenario_assumption）" begin
        for t in _REE_TYPES
            hp = _REE_HAPPY_PATH[t]
            @test _ree_observed(event_type = t, sector = hp.sector, unit = hp.unit) isa
                  ObservedEvent
            @test _ree_interpreted(
                event_type = t, sector = hp.sector, unit = hp.unit,
                target_concepts = hp.target_concepts,
            ) isa InterpretedSignal
            @test _ree_assumption(
                event_type = t, sector = hp.sector, unit = hp.unit,
                application_mode = hp.application_mode, target_concepts = hp.target_concepts,
                magnitude = hp.application_mode === :multiplicative ? -10.0 : -1.0,
            ) isa ScenarioAssumption
        end
    end

    @testset "定性的イベント（magnitude 欠測）を生成する" begin
        for t in _REE_TYPES
            oe = _ree_observed(event_type = t, sector = _REE_HAPPY_PATH[t].sector)
            @test oe.magnitude === missing
            @test oe.unit === nothing
            is = _ree_interpreted(
                event_type = t, sector = _REE_HAPPY_PATH[t].sector,
                target_concepts = _REE_HAPPY_PATH[t].target_concepts,
            )
            @test is.magnitude === missing
        end
    end

    @testset "数量付きイベント（magnitude・unit を伴う）を生成する" begin
        oe = _ree_observed(
            event_id = "OE-q1", event_type = :CapexGuidanceRevision, sector = :s1,
            direction = :up, magnitude = 12.5, unit = "%",
        )
        @test oe.magnitude == 12.5
        @test oe.unit == "%"
    end

    @testset "direction と magnitude の符号不一致は ArgumentError" begin
        # :up なのに magnitude が負
        @test_throws ArgumentError _ree_observed(
            event_id = "x", direction = :up, magnitude = -5.0, unit = "%",
        )
        @test_throws ArgumentError _ree_interpreted(
            event_id = "x", direction = :up, magnitude = -5.0, unit = "%",
        )
        @test_throws ArgumentError _ree_assumption(direction = :up, magnitude = -5.0)
        # :down なのに magnitude が正
        @test_throws ArgumentError _ree_observed(
            event_id = "x", direction = :down, magnitude = 5.0, unit = "%",
        )
        @test_throws ArgumentError _ree_assumption(direction = :down, magnitude = 5.0)
        # :none なのに magnitude が非ゼロ
        @test_throws ArgumentError _ree_observed(
            event_id = "x", direction = :none, magnitude = 1.0, unit = "%",
        )
        @test_throws ArgumentError _ree_assumption(direction = :none, magnitude = 1.0)
        # magnitude が欠測、または direction=:unknown のときは検証をスキップする（正常に構築できる）
        @test _ree_observed(event_id = "x") isa ObservedEvent
        @test _ree_interpreted(event_id = "x", direction = :unknown, magnitude = 5.0, unit = "%") isa
              InterpretedSignal
    end

    @testset "unit 不一致（型の許容単位に無い unit）は ArgumentError" begin
        @test_throws ArgumentError _ree_observed(
            event_id = "x", event_type = :DemandOutlookRevision, unit = "bp", magnitude = 1.0,
        )
        @test_throws ArgumentError _ree_interpreted(
            event_id = "x", event_type = :CapexGuidanceRevision, unit = "bp", magnitude = 1.0,
        )
        @test_throws ArgumentError _ree_assumption(
            event_type = :PriceOrMarginShock, unit = "bp", application_mode = :additive,
        )
    end

    @testset "target_concepts 不一致（型の許容 concept に無い concept）は ArgumentError" begin
        @test_throws ArgumentError _ree_interpreted(
            event_type = :DemandOutlookRevision, target_concepts = [:capex_plan],
        )
        # EmploymentPlanRevision を消費・所得への直接ショックへ変換しない
        @test_throws ArgumentError _ree_assumption(
            event_type = :EmploymentPlanRevision, target_concepts = [:demand_expectation],
        )
    end

    @testset "OrderCancellation: 率（S1・%・multiplicative）と数量（S2/S3・bn USD・additive）の混同" begin
        # 正常系: S1 は率
        @test _ree_assumption(
            event_type = :OrderCancellation, sector = :s1, unit = "%",
            application_mode = :multiplicative, target_concepts = [:order_flow],
            magnitude = -8.0,
        ) isa ScenarioAssumption
        # 正常系: S2/S3 は数量
        @test _ree_assumption(
            event_type = :OrderCancellation, sector = :s2, unit = "bn USD (2017 chained)",
            application_mode = :additive, target_concepts = [:order_flow], magnitude = -1.2,
        ) isa ScenarioAssumption
        @test _ree_assumption(
            event_type = :OrderCancellation, sector = :s3, unit = "bn USD (2017 chained)",
            application_mode = :additive, target_concepts = [:order_flow], magnitude = -0.8,
        ) isa ScenarioAssumption

        # 混同: S1 に数量単位を与える
        @test_throws ArgumentError _ree_assumption(
            event_type = :OrderCancellation, sector = :s1, unit = "bn USD (2017 chained)",
            application_mode = :additive, target_concepts = [:order_flow], magnitude = -1.0,
        )
        # 混同: S2 に率単位を与える
        @test_throws ArgumentError _ree_assumption(
            event_type = :OrderCancellation, sector = :s2, unit = "%",
            application_mode = :multiplicative, target_concepts = [:order_flow], magnitude = -8.0,
        )
        # observed_event/interpreted_signal でも同様に検証される
        @test_throws ArgumentError _ree_observed(
            event_id = "x", event_type = :OrderCancellation, sector = :s1,
            unit = "bn USD (2017 chained)", magnitude = -1.0,
        )
        @test_throws ArgumentError _ree_interpreted(
            event_id = "x", event_type = :OrderCancellation, sector = :s3, unit = "%",
            target_concepts = [:order_flow], magnitude = -8.0,
        )
    end

    @testset "PriceOrMarginShock: 価格（%）と margin（%pt）の混同" begin
        @test _ree_assumption(
            event_type = :PriceOrMarginShock, sector = :s1, unit = "%",
            application_mode = :multiplicative, target_concepts = [:output_price_margin],
            magnitude = -3.0,
        ) isa ScenarioAssumption
        err = try
            _ree_assumption(
                event_type = :PriceOrMarginShock, sector = :s1, unit = "%pt",
                application_mode = :additive, target_concepts = [:output_price_margin],
                magnitude = -3.0,
            )
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("margin", sprint(showerror, err))
        @test_throws ArgumentError _ree_observed(
            event_id = "x", event_type = :PriceOrMarginShock, unit = "%pt", magnitude = -3.0,
        )
    end

    @testset "unknown sector・型契約に無い sector も構築は拒否しない（unmapped_target 判定は #201）" begin
        # sector=:unknown（未分類）・:out_of_model・型契約が「不可」とする部門（S4/S5）は、
        # 本Issueのレジストリでは宣言的データにとどまり構築時には強制しない（#199コメントに
        # よる本文からの変更点3。判定は#201のmapping adapterが行う）。
        @test _ree_observed(event_id = "x", sector = :unknown) isa ObservedEvent
        @test _ree_observed(event_id = "x", sector = :out_of_model) isa ObservedEvent
        @test _ree_observed(event_id = "x", event_type = :CapexGuidanceRevision, sector = :s4) isa
              ObservedEvent
    end

    @testset "duplicate: macro_event_dedup_key は内容重複キーを決定的に返す（契約 §5.5）" begin
        base = _ree_observed(event_id = "OE-d1", magnitude = -4.0, unit = "%")
        same_content =
            _ree_observed(event_id = "OE-d2", magnitude = -4.0, unit = "%", notes = "別の書き方")
        different_magnitude = _ree_observed(event_id = "OE-d3", magnitude = -4.000001, unit = "%")

        # magnitude が Union{Float64,Missing} を含むため、タプルの `==` は missing どうしで
        # missing を返す（三値論理）。決定的な等価判定には `isequal` を用いる。
        @test isequal(macro_event_dedup_key(base), macro_event_dedup_key(same_content))
        @test !isequal(macro_event_dedup_key(base), macro_event_dedup_key(different_magnitude))

        is_base = _ree_interpreted(event_id = "IS-d1")
        is_same = _ree_interpreted(event_id = "IS-d2", confidence = 0.9, notes = "別の書き方")
        is_diff_entity = _ree_interpreted(event_id = "IS-d3", entity = "fictional-corp-a")
        @test isequal(macro_event_dedup_key(is_base), macro_event_dedup_key(is_same))
        @test !isequal(macro_event_dedup_key(is_base), macro_event_dedup_key(is_diff_entity))

        # magnitude が欠測どうしなら一致する（isequal(missing, missing) === true）
        qualitative_a = _ree_observed(event_id = "OE-q-a")
        qualitative_b = _ree_observed(event_id = "OE-q-b", notes = "別の記述")
        @test isequal(macro_event_dedup_key(qualitative_a), macro_event_dedup_key(qualitative_b))
    end

    @testset ":other は smart constructor では扱えない（型別規則が定義されないため）" begin
        @test_throws ArgumentError _ree_observed(event_id = "x", event_type = :other)
        @test_throws ArgumentError _ree_interpreted(event_id = "x", event_type = :other)
        # 層別コンストラクタを直接使えば :other は L1/L2 で従来どおり許容される（Y-01・E-1）
        @test ObservedEvent(;
            event_id = "x", event_type = :other, announced_at = Date(2026, 1, 1),
            observed_at = Date(2026, 1, 1), known_at = Date(2026, 1, 1), source = _ree_source(),
            provenance = _ree_provenance(:observed),
        ) isa ObservedEvent
    end
end
