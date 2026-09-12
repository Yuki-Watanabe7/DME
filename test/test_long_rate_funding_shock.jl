# `:LongRateFundingShock`・`FundingShockComponents`・`FundingShockPassThrough`・
# `funding_shock_magnitude_bps`・`long_rate_funding_scenario_assumption` のテスト
# （src/scenarios/long_rate_funding_shock.jl・src/scenarios/event_type_registry.jl、
# Issue #260 Part A）。
#
# 政策金利変更（`:PolicyRateChange`）とは別入力として長期金利repricing・secured funding
# stressを表現できること（受け入れ条件）・pass-throughが明示parameterであること（暗黙の1:1に
# しない）・nominal - real - inflation compensationの残差をterm premiumと呼ばないことを対象
# とする。

using Dates: Date

# ------------------------------------------------------------
# テスト用ヘルパ（fictional。実在の金利水準・イベントを用いない）
# ------------------------------------------------------------

_lrf_source() = EventSource(publisher = "fictional wire", document_id = "doc-lrf-1")

_lrf_provenance() = EventProvenance(;
    layer = :assumption,
    rule_id = "test-long-rate-funding-shock-rule",
    rule_version = "1.0.0",
    generator = "test_long_rate_funding_shock.jl",
    derived_from = ["IS-lrf-1"],
)

_lrf_timing(; t_apply::Int = 0) =
    EventTiming(; basis = :period, rule = :explicit_period, t_apply = t_apply)

_lrf_persistence() = PersistenceSpec(; shape = :ar1_decay, params = (half_life = 4,))

function _lrf_assumption(; components, kwargs...)
    return long_rate_funding_scenario_assumption(;
        assumption_id = "lrf-1",
        components = components,
        timing = _lrf_timing(),
        persistence = _lrf_persistence(),
        provenance = _lrf_provenance(),
        kwargs...,
    )
end

@testset "長期金利・funding-cost shock（Issue #260 Part A）" begin
    @testset "smoke test（CLAUDE.md）" begin
        c = FundingShockComponents(;
            long_nominal_yield_shift_bps = 40.0,
            secured_funding_spread_shift_bps = 10.0,
        )
        @test c isa FundingShockComponents
        @test macro_event_type_spec(:LongRateFundingShock) isa MacroEventTypeSpec
        @test _lrf_assumption(components = c) isa ScenarioAssumption
    end

    @testset "FundingShockComponents: 必須/欠測フィールドと残差" begin
        # 必須フィールドはmissingを受け付けない（型で保証、Float64のみ）
        @test_throws TypeError FundingShockComponents(;
            long_nominal_yield_shift_bps = missing,
            secured_funding_spread_shift_bps = 10.0,
        )

        # real/inflation compensationが欠測のときはresidualもmissing（0へ丸めない）
        c1 = FundingShockComponents(;
            long_nominal_yield_shift_bps = 40.0,
            secured_funding_spread_shift_bps = 10.0,
        )
        @test c1.long_real_yield_shift_bps === missing
        @test c1.inflation_compensation_shift_bps === missing
        @test c1.decomposition_residual_bps === missing

        # 両方観測できるときのみresidualを算出する
        c2 = FundingShockComponents(;
            long_nominal_yield_shift_bps = 40.0,
            secured_funding_spread_shift_bps = 10.0,
            long_real_yield_shift_bps = 25.0,
            inflation_compensation_shift_bps = 10.0,
        )
        @test c2.decomposition_residual_bps == 40.0 - (25.0 + 10.0)

        # 片方だけの観測ではresidualを算出しない（missingのまま）
        c3 = FundingShockComponents(;
            long_nominal_yield_shift_bps = 40.0,
            secured_funding_spread_shift_bps = 10.0,
            long_real_yield_shift_bps = 25.0,
        )
        @test c3.decomposition_residual_bps === missing

        # NaN/Infは全フィールドで拒否する
        @test_throws ArgumentError FundingShockComponents(;
            long_nominal_yield_shift_bps = NaN,
            secured_funding_spread_shift_bps = 10.0,
        )
        @test_throws ArgumentError FundingShockComponents(;
            long_nominal_yield_shift_bps = 40.0,
            secured_funding_spread_shift_bps = 10.0,
            long_real_yield_shift_bps = Inf,
        )
    end

    @testset "FundingShockPassThrough: 既定値の明示性と検証" begin
        p = FundingShockPassThrough()
        @test p.long_nominal_yield_pass_through == 1.0
        @test p.secured_funding_pass_through == 1.0
        @test p.version == FUNDING_SHOCK_PASS_THROUGH_VERSION

        p2 = FundingShockPassThrough(; long_nominal_yield_pass_through = 0.6, version = "custom/2.0.0")
        @test p2.long_nominal_yield_pass_through == 0.6
        @test p2.secured_funding_pass_through == 1.0
        @test p2.version == "custom/2.0.0"

        @test_throws ArgumentError FundingShockPassThrough(; version = "")
    end

    @testset "funding_shock_magnitude_bps: nominal・secured fundingのみを合成する" begin
        c = FundingShockComponents(;
            long_nominal_yield_shift_bps = 40.0,
            secured_funding_spread_shift_bps = 10.0,
            long_real_yield_shift_bps = 25.0,
            inflation_compensation_shift_bps = 10.0,
        )
        # 既定pass_through（1:1）
        @test funding_shock_magnitude_bps(c) == 50.0

        # real/inflation compensation/residualは含めない（二重計上しない）
        p_zero_secured = FundingShockPassThrough(; secured_funding_pass_through = 0.0)
        @test funding_shock_magnitude_bps(c, p_zero_secured) == 40.0

        # pass-throughは明示parameterであり上書きが反映される
        p_half = FundingShockPassThrough(;
            long_nominal_yield_pass_through = 0.5,
            secured_funding_pass_through = 0.5,
        )
        @test funding_shock_magnitude_bps(c, p_half) == 25.0
    end

    @testset "long_rate_funding_scenario_assumption: 型・単位・方向の自動決定" begin
        c_up = FundingShockComponents(;
            long_nominal_yield_shift_bps = 40.0,
            secured_funding_spread_shift_bps = 10.0,
        )
        a_up = _lrf_assumption(components = c_up)
        @test a_up.event_type === :LongRateFundingShock
        @test a_up.target_concepts == [:long_rate_funding_condition]
        @test a_up.unit == "bp"
        @test a_up.application_mode === :additive
        @test a_up.magnitude == funding_shock_magnitude_bps(c_up)
        @test a_up.direction === :up
        @test a_up.magnitude_source === :derived

        c_down = FundingShockComponents(;
            long_nominal_yield_shift_bps = -30.0,
            secured_funding_spread_shift_bps = -5.0,
        )
        a_down = _lrf_assumption(components = c_down)
        @test a_down.direction === :down
        @test a_down.magnitude < 0

        c_zero = FundingShockComponents(;
            long_nominal_yield_shift_bps = 0.0,
            secured_funding_spread_shift_bps = 0.0,
        )
        a_zero = _lrf_assumption(components = c_zero)
        @test a_zero.direction === :none
        @test a_zero.magnitude == 0.0
    end

    @testset "caveats: 内訳・pass-through版・term premium不使用・二重計上防止を自動記録する" begin
        c = FundingShockComponents(;
            long_nominal_yield_shift_bps = 40.0,
            secured_funding_spread_shift_bps = 10.0,
            long_real_yield_shift_bps = 25.0,
            inflation_compensation_shift_bps = 10.0,
        )
        a = _lrf_assumption(components = c, caveats = "呼び出し側の追記")
        @test occursin("long_nominal_yield_shift_bps=40.0", a.caveats)
        @test occursin("secured_funding_spread_shift_bps=10.0", a.caveats)
        @test occursin("decomposition_residual_bps=5.0", a.caveats)
        @test occursin("term premiumではない", a.caveats)
        @test occursin(FUNDING_SHOCK_PASS_THROUGH_VERSION, a.caveats)
        @test occursin("二重計上防止", a.caveats)
        @test occursin("呼び出し側の追記", a.caveats)
    end

    @testset "PolicyRateChange・CreditSpreadShockとの混同を型で拒否する" begin
        c = FundingShockComponents(;
            long_nominal_yield_shift_bps = 40.0,
            secured_funding_spread_shift_bps = 10.0,
        )
        # :LongRateFundingShock に :policy_rate / :credit_spread は割り当てられない
        # （レジストリの allowed_target_concepts による強制）
        @test_throws ArgumentError scenario_assumption(;
            assumption_id = "bad-1",
            event_type = :LongRateFundingShock,
            sector = :unknown,
            direction = :up,
            magnitude = funding_shock_magnitude_bps(c),
            unit = "bp",
            magnitude_source = :derived,
            application_mode = :additive,
            timing = _lrf_timing(),
            persistence = _lrf_persistence(),
            target_concepts = [:policy_rate],
            provenance = _lrf_provenance(),
        )

        # 逆方向: :PolicyRateChange に :long_rate_funding_condition は割り当てられない
        @test_throws ArgumentError scenario_assumption(;
            assumption_id = "bad-2",
            event_type = :PolicyRateChange,
            sector = :out_of_model,
            direction = :up,
            magnitude = 0.25,
            unit = "%pt",
            magnitude_source = :assumed_default,
            application_mode = :additive,
            timing = _lrf_timing(),
            persistence = PersistenceSpec(; shape = :step),
            target_concepts = [:long_rate_funding_condition],
            provenance = _lrf_provenance(),
        )
    end

    @testset "unit・application_mode の許容表と一致する" begin
        c = FundingShockComponents(;
            long_nominal_yield_shift_bps = 40.0,
            secured_funding_spread_shift_bps = 10.0,
        )
        spec = macro_event_type_spec(:LongRateFundingShock)
        @test spec.allowed_units == ["bp"]
        @test spec.allowed_application_modes == [:additive]
        @test spec.allowed_target_concepts == [:long_rate_funding_condition]
        @test spec.default_timing_rule === :same_quarter
        @test spec.default_shape === :ar1_decay
        @test spec.default_shape_params.half_life == 4

        # "%"（率）や :multiplicative は許容表に無い
        @test_throws ArgumentError scenario_assumption(;
            assumption_id = "bad-unit",
            event_type = :LongRateFundingShock,
            sector = :unknown,
            direction = :up,
            magnitude = funding_shock_magnitude_bps(c),
            unit = "%",
            magnitude_source = :derived,
            application_mode = :additive,
            timing = _lrf_timing(),
            persistence = _lrf_persistence(),
            target_concepts = [:long_rate_funding_condition],
            provenance = _lrf_provenance(),
        )
    end

    @testset "MACRO_EVENT_TYPES・レジストリに登録されている" begin
        @test :LongRateFundingShock in MACRO_EVENT_TYPES
        @test haskey(MACRO_EVENT_TYPE_REGISTRY, :LongRateFundingShock)
        @test :long_rate_funding_condition in MACRO_EVENT_TARGET_CONCEPTS
    end
end
