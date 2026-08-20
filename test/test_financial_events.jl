# イベント型レジストリの信用・金融政策側イベント型4種のテスト（src/scenarios/event_type_registry.jl、
# Issue #200 / `E-4`）。
#
# 統合設計 §10.1（型と契約）のうち本Issue対象の項目10（レジストリ4行がマクロイベント変換契約
# §4.2・§4.3の表と逐語一致）と、Issue #200本文・コメント「テスト期待」（bp/decimal・
# level/change・upgrade/downgrade・refinancing unavailable・定性 tightening・
# 同時 policy/spread・duplicate・将来 effective date）を対象とする。`unmapped_target` の
# 判定自体（#201 mapping adapter の責務）は対象外とし、本ファイルは `inapplicable_conditions`
# が宣言として保持されていることのみを確認する。`:RefinancingOrRatingEvent` の
# rating action / outlook / refinancing availability / maturity wall は新しい struct
# （subtype）ではなく `reason_codes` 語彙として宣言されるにとどまる（#200 コメントによる
# 本文からの変更点3）ため、本ファイルは個々のレコードを `direction`/`magnitude`/`notes` の
# 組み合わせで区別する。
#
# fixture: `test/fixtures/events/financial/*.json` は本ファイルと同じ synthetic
# （fictional）データを人間可読な形で記録した参考資料であり、`test/fixtures/capex_credit_cycle/`
# と同様プログラム的には読み込まない。

using Dates: Date

# ------------------------------------------------------------
# テスト用ヘルパ（fictional。実在企業・実在イベントを用いない）
# ------------------------------------------------------------

_fe_source(; document_id::String = "doc-fin-1") =
    EventSource(publisher = "fictional wire", document_id = document_id)

_fe_provenance(layer::Symbol; derived_from::Vector{String} = String[]) = EventProvenance(;
    layer = layer,
    rule_id = "test-financial-events-rule",
    rule_version = "1.0.0",
    generator = "test_financial_events.jl",
    derived_from = derived_from,
)

_fe_timing(; t_apply::Int = 0) =
    EventTiming(; basis = :period, rule = :explicit_period, t_apply = t_apply)

_fe_persistence(; shape::Symbol = :ar1_decay, duration = nothing, params::NamedTuple = (half_life = 4,)) =
    PersistenceSpec(; shape = shape, duration = duration, params = params)

function _fe_observed(;
    event_id::String = "OE-fin-1",
    event_type::Symbol = :CreditSpreadShock,
    kwargs...,
)
    return observed_event(;
        event_id = event_id,
        event_type = event_type,
        announced_at = Date(2026, 3, 1),
        observed_at = Date(2026, 3, 1),
        known_at = Date(2026, 3, 2),
        source = _fe_source(),
        provenance = _fe_provenance(:observed),
        kwargs...,
    )
end

function _fe_interpreted(;
    event_id::String = "IS-fin-1",
    event_type::Symbol = :CreditSpreadShock,
    sector::Symbol = :s4,
    direction::Symbol = :up,
    magnitude_source::Symbol = :external_belief,
    confidence::Float64 = 0.6,
    target_concepts::Vector{Symbol} = [:credit_spread],
    kwargs...,
)
    return interpreted_signal(;
        event_id = event_id,
        event_type = event_type,
        announced_at = Date(2026, 3, 1),
        observed_at = Date(2026, 3, 1),
        known_at = Date(2026, 3, 2),
        source = _fe_source(),
        provenance = _fe_provenance(:interpreted; derived_from = ["OE-fin-1"]),
        sector = sector,
        direction = direction,
        magnitude_source = magnitude_source,
        confidence = confidence,
        target_concepts = target_concepts,
        kwargs...,
    )
end

function _fe_assumption(;
    assumption_id::String = "SA-fin-1",
    event_type::Symbol = :CreditSpreadShock,
    sector::Symbol = :s4,
    direction::Symbol = :up,
    magnitude::Float64 = 25.0,
    unit::String = "bp",
    magnitude_source::Symbol = :assumed_default,
    application_mode::Symbol = :additive,
    target_concepts::Vector{Symbol} = [:credit_spread],
    timing = _fe_timing(),
    persistence = _fe_persistence(),
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
        provenance = _fe_provenance(:assumption; derived_from = ["IS-fin-1"]),
        kwargs...,
    )
end

const _FE_TYPES = (
    :CreditSpreadShock,
    :LendingStandardChange,
    :RefinancingOrRatingEvent,
    :PolicyRateChange,
)

# 各型の「正常系」引数一式（sector・unit・application_mode・target_concepts の組・
# scenario_assumption 用の persistence）。マクロイベント変換契約 §4.2 row 5/6/7/9 から
# 1:1 で写す。
const _FE_HAPPY_PATH = Dict{Symbol, NamedTuple}(
    :CreditSpreadShock => (
        sector = :s4, unit = "bp", application_mode = :additive,
        target_concepts = [:credit_spread],
        persistence = PersistenceSpec(; shape = :ar1_decay, params = (half_life = 4,)),
    ),
    :LendingStandardChange => (
        sector = :s4, unit = "%", application_mode = :multiplicative,
        target_concepts = [:lending_standard],
        persistence = PersistenceSpec(; shape = :step, duration = 4),
    ),
    :RefinancingOrRatingEvent => (
        sector = :s4, unit = "bp", application_mode = :additive,
        target_concepts = [:refinancing_condition],
        persistence = PersistenceSpec(; shape = :ar1_decay, params = (half_life = 4,)),
    ),
    :PolicyRateChange => (
        sector = :out_of_model, unit = "%pt", application_mode = :additive,
        target_concepts = [:policy_rate],
        persistence = PersistenceSpec(; shape = :step),
    ),
)

@testset "イベント型レジストリと信用・金融政策側イベント型4種（Issue #200 / E-4）" begin
    @testset "smoke test（CLAUDE.md）" begin
        @test _fe_observed() isa ObservedEvent
        @test _fe_interpreted() isa InterpretedSignal
        @test _fe_assumption() isa ScenarioAssumption
        @test macro_event_type_spec(:CreditSpreadShock) isa MacroEventTypeSpec
    end

    @testset "レジストリに信用・金融政策側4種が登録されている（実体経済側5種と合わせて9種）" begin
        for t in _FE_TYPES
            @test haskey(MACRO_EVENT_TYPE_REGISTRY, t)
            spec = macro_event_type_spec(t)
            @test spec.event_type === t
            @test spec isa MacroEventTypeSpec
        end
        @test length(MACRO_EVENT_TYPE_REGISTRY) == length(MACRO_EVENT_TYPES)
        @test Set(keys(MACRO_EVENT_TYPE_REGISTRY)) == Set(MACRO_EVENT_TYPES)
    end

    @testset "レジストリ4行がマクロイベント変換契約 §4.2・§4.3 の表と逐語一致する" begin
        # (allowed_units, allowed_application_modes, default_timing_rule, default_shape)
        expected = Dict{Symbol, Tuple}(
            :CreditSpreadShock => (["bp"], [:additive], :same_quarter, :ar1_decay),
            :LendingStandardChange => (["%"], [:multiplicative], nothing, nothing),
            :RefinancingOrRatingEvent => (["bp"], [:additive], :same_quarter, :ar1_decay),
            :PolicyRateChange => (["%pt"], [:absolute, :additive], :same_quarter, :step),
        )
        for (t, (units, modes, rule, shape)) in expected
            spec = macro_event_type_spec(t)
            @test spec.allowed_units == units
            @test spec.allowed_application_modes == modes
            @test spec.default_timing_rule === rule
            @test spec.default_shape === shape
        end
        # 半減期の既定値（契約 §4.3）
        @test macro_event_type_spec(:CreditSpreadShock).default_shape_params.half_life == 4
        @test macro_event_type_spec(:RefinancingOrRatingEvent).default_shape_params.half_life == 4
    end

    @testset "unit × application_mode の許容表と一致する（bp/decimal の混同を拒否）" begin
        # 契約 §3.3 の単位語彙に無い表記（decimal 等）は全層で ArgumentError
        @test_throws ArgumentError _fe_observed(
            event_id = "x", event_type = :CreditSpreadShock, unit = "decimal", magnitude = 0.0025,
        )
        @test_throws ArgumentError _fe_assumption(
            event_type = :CreditSpreadShock, unit = "decimal", application_mode = :additive,
            magnitude = 0.0025,
        )
        # "bp" は :additive のみ（乗算・絶対は許容表に無い）
        @test_throws ArgumentError _fe_assumption(
            event_type = :CreditSpreadShock, unit = "bp", application_mode = :multiplicative,
        )
        # "%pt" と "bp" の暗黙換算（100bp = 1%pt）を行わない: PolicyRateChange に bp を渡すと拒否
        @test_throws ArgumentError _fe_observed(
            event_id = "x", event_type = :PolicyRateChange, unit = "bp", magnitude = 25.0,
        )
    end

    @testset "PolicyRateChange: 水準（:absolute）と変化幅（:additive）を区別する" begin
        # 水準指定
        level = _fe_assumption(;
            event_type = :PolicyRateChange, sector = :out_of_model, unit = "%pt",
            application_mode = :absolute, target_concepts = [:policy_rate], magnitude = 4.5,
            direction = :up, persistence = _FE_HAPPY_PATH[:PolicyRateChange].persistence,
        )
        @test level isa ScenarioAssumption
        @test level.application_mode === :absolute
        # 変化幅指定
        change = _fe_assumption(;
            event_type = :PolicyRateChange, sector = :out_of_model, unit = "%pt",
            application_mode = :additive, target_concepts = [:policy_rate], magnitude = -0.25,
            direction = :down, persistence = _FE_HAPPY_PATH[:PolicyRateChange].persistence,
        )
        @test change isa ScenarioAssumption
        @test change.application_mode === :additive
        # 水準と変化幅は別の application_mode であり、混同してもエラーにはならないが値としては
        # 区別される（構造化拒否はスケジューラ/実行層の責務、統合設計 §7.5・#198）
        @test level.application_mode !== change.application_mode
    end

    @testset "RefinancingOrRatingEvent: rating upgrade/downgrade を direction・magnitude・notes で区別する" begin
        # direction は magnitude の符号規約（:up は正、:down は負）であり、rating upgrade
        # （社債スプレッドが縮小＝ bp の負変化）は direction=:down、downgrade（拡大＝正変化）は
        # direction=:up になる。upgrade/downgrade の区別自体は reason code（notes に記録）が担う。
        upgrade = _fe_observed(;
            event_id = "OE-rr-up", event_type = :RefinancingOrRatingEvent, sector = :s1,
            direction = :down, magnitude = -15.0, unit = "bp",
            notes = "reason_code=rating_upgrade（社債市場価格に反映された分のみ）",
        )
        @test upgrade.direction === :down
        @test upgrade.magnitude == -15.0
        downgrade = _fe_observed(;
            event_id = "OE-rr-down", event_type = :RefinancingOrRatingEvent, sector = :s1,
            direction = :up, magnitude = 40.0, unit = "bp",
            notes = "reason_code=rating_downgrade（社債市場価格に反映された分のみ）",
        )
        @test downgrade.direction === :up
        @test downgrade.magnitude == 40.0
        # 符号不一致（direction=:up なのに magnitude が負）は ArgumentError
        @test_throws ArgumentError _fe_observed(
            event_id = "x", event_type = :RefinancingOrRatingEvent, direction = :up,
            magnitude = -15.0, unit = "bp",
        )
    end

    @testset "RefinancingOrRatingEvent: refinancing unavailable・maturity wall（定性、magnitude欠測）" begin
        # 借換不能（refinancing unavailable）: 市場価格への換算根拠が無いため magnitude 欠測のまま
        refi_unavailable = _fe_observed(;
            event_id = "OE-rr-refi", event_type = :RefinancingOrRatingEvent, sector = :s1,
            direction = :down, notes = "reason_code=refinancing_unavailable",
        )
        @test refi_unavailable.magnitude === missing
        @test refi_unavailable.unit === nothing
        # maturity wall: 満期到来の期限は effective_from/effective_until で追跡する
        maturity_wall = _fe_observed(;
            event_id = "OE-rr-wall", event_type = :RefinancingOrRatingEvent, sector = :s1,
            direction = :unknown, effective_from = Date(2027, 6, 30),
            notes = "reason_code=maturity_wall",
        )
        @test maturity_wall.effective_from == Date(2027, 6, 30)
        # reason code 語彙はレジストリに宣言されている（#200 コメントによる本文からの変更点3）
        spec = macro_event_type_spec(:RefinancingOrRatingEvent)
        @test :rating_upgrade in spec.reason_codes
        @test :rating_downgrade in spec.reason_codes
        @test :outlook_change in spec.reason_codes
        @test :refinancing_unavailable in spec.reason_codes
        @test :maturity_wall in spec.reason_codes
        # 他の event_type は reason_codes を持たない
        @test isempty(macro_event_type_spec(:CreditSpreadShock).reason_codes)
        @test isempty(macro_event_type_spec(:PolicyRateChange).reason_codes)
    end

    @testset "LendingStandardChange: 定性的 tightening は magnitude を捏造しない（欠測のまま保持）" begin
        qualitative = _fe_observed(;
            event_id = "OE-lend-1", event_type = :LendingStandardChange, sector = :s4,
            direction = :up, notes = "SLOOS: C&I 貸出基準の引締め（定性報告、数量無し）",
        )
        @test qualitative.magnitude === missing
        @test qualitative.unit === nothing
        # 定量表現（純引締め率等）がある場合は unit="%" で保持できる
        quantitative = _fe_observed(;
            event_id = "OE-lend-2", event_type = :LendingStandardChange, sector = :s4,
            direction = :up, magnitude = 38.0, unit = "%",
        )
        @test quantitative.magnitude == 38.0
        @test quantitative.unit == "%"
        # L3 へ変換する際は :assumed_default で既定値を与える（欠測のまま L3 を作ることはできない、
        # ScenarioAssumption.magnitude は Float64 のみ）
        l3 = _fe_assumption(;
            event_type = :LendingStandardChange, sector = :s4, direction = :up, magnitude = 10.0,
            unit = "%", application_mode = :multiplicative, magnitude_source = :assumed_default,
            target_concepts = [:lending_standard],
            persistence = _FE_HAPPY_PATH[:LendingStandardChange].persistence,
        )
        @test l3 isa ScenarioAssumption
        @test l3.magnitude_source === :assumed_default
    end

    @testset "各型の正常系（observed_event/interpreted_signal/scenario_assumption）" begin
        for t in _FE_TYPES
            hp = _FE_HAPPY_PATH[t]
            @test _fe_observed(event_type = t, sector = hp.sector, unit = hp.unit) isa
                  ObservedEvent
            @test _fe_interpreted(
                event_type = t, sector = hp.sector, unit = hp.unit,
                target_concepts = hp.target_concepts,
            ) isa InterpretedSignal
            @test _fe_assumption(
                event_type = t, sector = hp.sector, unit = hp.unit,
                application_mode = hp.application_mode, target_concepts = hp.target_concepts,
                persistence = hp.persistence,
                magnitude = hp.application_mode === :multiplicative ? 10.0 : 25.0,
            ) isa ScenarioAssumption
        end
    end

    @testset "target_concepts 不一致（型の許容 concept に無い concept）は ArgumentError" begin
        @test_throws ArgumentError _fe_interpreted(
            event_type = :CreditSpreadShock, target_concepts = [:policy_rate],
        )
        # PolicyRateChange を信用スプレッドの target concept へ変換しない（自動 netting 禁止）
        @test_throws ArgumentError _fe_assumption(
            event_type = :PolicyRateChange, sector = :out_of_model, unit = "%pt",
            application_mode = :additive, target_concepts = [:credit_spread], magnitude = -0.25,
            direction = :down, persistence = _FE_HAPPY_PATH[:PolicyRateChange].persistence,
        )
    end

    @testset "同時 policy/spread: 政策金利変更と信用スプレッドショックは別イベントとして保持される" begin
        policy = _fe_assumption(;
            event_type = :PolicyRateChange, sector = :out_of_model, unit = "%pt",
            application_mode = :additive, target_concepts = [:policy_rate], magnitude = -0.25,
            direction = :down, persistence = _FE_HAPPY_PATH[:PolicyRateChange].persistence,
            timing = _fe_timing(t_apply = 3),
        )
        spread = _fe_assumption(;
            event_type = :CreditSpreadShock, sector = :s4, unit = "bp", application_mode = :additive,
            target_concepts = [:credit_spread], magnitude = 30.0, direction = :up,
            persistence = _FE_HAPPY_PATH[:CreditSpreadShock].persistence, timing = _fe_timing(t_apply = 3),
        )
        # 別 event_type・別 target_concepts の独立したレコードであり、どちらも自身の magnitude を
        # 保つ（自動 netting されない）
        @test policy.event_type === :PolicyRateChange
        @test spread.event_type === :CreditSpreadShock
        @test policy.target_concepts == [:policy_rate]
        @test spread.target_concepts == [:credit_spread]
        @test policy.magnitude == -0.25
        @test spread.magnitude == 30.0
    end

    @testset "duplicate: macro_event_dedup_key は内容重複キーを決定的に返す（契約 §5.5）" begin
        base = _fe_observed(event_id = "OE-fd1", magnitude = 25.0, unit = "bp")
        same_content =
            _fe_observed(event_id = "OE-fd2", magnitude = 25.0, unit = "bp", notes = "別の書き方")
        different_type = _fe_observed(
            event_id = "OE-fd3", event_type = :RefinancingOrRatingEvent, magnitude = 25.0,
            unit = "bp",
        )
        @test isequal(macro_event_dedup_key(base), macro_event_dedup_key(same_content))
        @test !isequal(macro_event_dedup_key(base), macro_event_dedup_key(different_type))

        # 同時 policy/spread は event_type が異なるため duplicate と判定されない
        policy_oe = _fe_observed(
            event_id = "OE-fd4", event_type = :PolicyRateChange, sector = :out_of_model,
            magnitude = -0.25, unit = "%pt",
        )
        @test !isequal(macro_event_dedup_key(base), macro_event_dedup_key(policy_oe))
    end

    @testset "将来 effective date（effective_from が announced_at より先）を保持できる" begin
        future = _fe_observed(;
            event_id = "OE-future", event_type = :PolicyRateChange, sector = :out_of_model,
            announced_at = Date(2026, 3, 1), observed_at = Date(2026, 3, 1),
            known_at = Date(2026, 3, 2), effective_from = Date(2026, 6, 15), direction = :down,
            magnitude = -0.25, unit = "%pt",
        )
        @test future.effective_from == Date(2026, 6, 15)
        @test future.effective_from > future.announced_at
    end

    @testset "unknown sector・型契約に無い sector も構築は拒否しない（unmapped_target 判定は #201）" begin
        @test _fe_observed(event_id = "x", event_type = :CreditSpreadShock, sector = :unknown) isa
              ObservedEvent
        @test _fe_observed(event_id = "x", event_type = :LendingStandardChange, sector = :s1) isa
              ObservedEvent
    end

    @testset "適用不能条件（inapplicable_conditions）が宣言として保持されている" begin
        @test :credit_market_scope_mismatch in
              macro_event_type_spec(:CreditSpreadShock).inapplicable_conditions
        @test :lending_standard_has_no_target_variable in
              macro_event_type_spec(:LendingStandardChange).inapplicable_conditions
        @test :rating_change_not_reflected_in_market_price in
              macro_event_type_spec(:RefinancingOrRatingEvent).inapplicable_conditions
        @test :refinancing_condition_target_unavailable in
              macro_event_type_spec(:RefinancingOrRatingEvent).inapplicable_conditions
        @test :policy_rate_negative_after_application in
              macro_event_type_spec(:PolicyRateChange).inapplicable_conditions
    end

    @testset ":other は smart constructor では扱えない（型別規則が定義されないため）" begin
        @test_throws ArgumentError _fe_observed(event_id = "x", event_type = :other)
        @test_throws ArgumentError _fe_interpreted(event_id = "x", event_type = :other)
    end

    @testset "MacroEventTypeSpec: reason_codes に未知の値・重複を与えると ArgumentError" begin
        @test_throws ArgumentError MacroEventTypeSpec(;
            event_type = :RefinancingOrRatingEvent, display_name = "x", allowed_sectors = Symbol[],
            allowed_scope = Symbol[], allowed_target_concepts = [:refinancing_condition],
            allowed_units = String[], allowed_application_modes = Symbol[],
            contract_section = "test", reason_codes = [:not_a_real_reason_code],
        )
        @test_throws ArgumentError MacroEventTypeSpec(;
            event_type = :RefinancingOrRatingEvent, display_name = "x", allowed_sectors = Symbol[],
            allowed_scope = Symbol[], allowed_target_concepts = [:refinancing_condition],
            allowed_units = String[], allowed_application_modes = Symbol[],
            contract_section = "test", reason_codes = [:rating_upgrade, :rating_upgrade],
        )
    end
end
