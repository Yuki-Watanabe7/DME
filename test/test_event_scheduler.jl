# 四半期イベントscheduler・時間形状・同時競合解決のテスト
# （src/scenarios/scenario_time.jl・event_scheduler.jl、Issue #198 / `E-2`）。
#
# 統合設計 §10.2（スケジューラ、14項目）の受け入れ条件のうち #198 の対象分（項目1–14、
# `map_event`/`run_scenario` に依存する結線テスト§10.4-6・§10.4-9 を除く）を検査する。
#
# 注意（実装スコープの調整）:
#   - `AppliedModelInput` は本来 `map_event`（Issue #201）が構築するが、本Issueでは未実装のため
#     テスト用ヘルパで直接構築する（fictional な synthetic データのみ、実在企業・実在イベントを
#     用いない）。
#   - 項目7（`path` の `magnitude` 不一致拒否）は `PersistenceSpec` コンストラクタ（Issue #197・
#     `macro_events.jl`）が既に検証しており、本ファイルでは回帰確認のみ行う。
#   - 項目13（`superseded_event`）は `supersedes` 解決が `run_scenario`（Issue #202）の対象で
#     あり、`schedule_events` は `supersedes` を解決しない。本ファイルでは対象外とする。

using Dates: Date

const _ES_PERIODS_28 = collect((-8):(19))

function _es_input(;
    input_id::String,
    assumption_id::String,
    target::Symbol,
    mode::Symbol,
    unit::String,
    magnitude::Float64,
    shape::Symbol,
    t_apply::Int,
    duration::Union{Int, Nothing} = nothing,
    params::NamedTuple = NamedTuple(),
    periods::Vector{Int} = _ES_PERIODS_28,
)
    persistence = PersistenceSpec(; shape = shape, duration = duration, params = params)
    values = shock_shape_path(persistence, magnitude, t_apply, periods, nothing)
    baseline_values = zeros(length(periods))
    prov = EventProvenance(;
        layer = :applied,
        rule_id = "test-rule",
        rule_version = "event-rule/1.0.0",
        generator = "test_event_scheduler.jl",
        derived_from = [assumption_id],
    )
    return AppliedModelInput(;
        input_id = input_id,
        assumption_id = assumption_id,
        model = :capex_credit_cycle,
        target_variable = target,
        application_mode = mode,
        unit = unit,
        magnitude = magnitude,
        persistence = persistence,
        t_apply = t_apply,
        values = values,
        baseline_values = baseline_values,
        mapping_id = "test-mapping",
        mapping_version = "ccc-event-mapping/1.0.0",
        provenance = prov,
    )
end

function _es_baseline()
    n = length(_ES_PERIODS_28)
    return Dict{Symbol, Vector{Float64}}(
        :ai_exp => zeros(n),
        :capex_plan_shock_ex => zeros(n),
        :spread_shock_ex => zeros(n),
        :policy_rate => fill(3.0, n),
        :ext_demand_s2 => zeros(n),
        :ext_demand_s3 => zeros(n),
        :price_s1 => fill(1.0, n),
    )
end

_es_scenario(; kwargs...) =
    Scenario(; id = :SmokeSc, model = :capex_credit_cycle, horizon_runup = 8, horizon_eval = 20, kwargs...)

@testset "四半期イベントscheduler・時間形状・同時競合解決（E-2）" begin
    @testset "quarter_of / quarter_index / quarter_label" begin
        @test quarter_of(Date(2026, 1, 1)) == CalendarQuarter(2026, 1)
        @test quarter_of(Date(2026, 3, 31)) == CalendarQuarter(2026, 1)
        @test quarter_of(Date(2026, 4, 1)) == CalendarQuarter(2026, 2)
        @test quarter_of(Date(2026, 12, 31)) == CalendarQuarter(2026, 4)
        @test quarter_label(CalendarQuarter(2026, 1)) == "2026Q1"

        zero_q = CalendarQuarter(2026, 1)
        # 四半期跨ぎ・Q4 → 翌年Q1（統合設計 §10.2 item 2）
        @test quarter_index(CalendarQuarter(2025, 4), zero_q) == -1
        @test quarter_index(CalendarQuarter(2026, 1), zero_q) == 0
        @test quarter_index(CalendarQuarter(2026, 2), zero_q) == 1
        @test quarter_index(CalendarQuarter(2027, 1), zero_q) == 4
        @test quarter_index(CalendarQuarter(2024, 1), zero_q) == -8
    end

    @testset "cutoff境界日（前日・当日・翌日）" begin
        rs = TimingRuleSet()
        zero_q = CalendarQuarter(2026, 1)
        @test DME._scenario_time_cutoff_date(CalendarQuarter(2026, 1), rs) == Date(2026, 2, 28)

        t_before = DME.resolve_t_apply(
            EventTiming(; basis = :calendar, rule = :cutoff, effective_from = Date(2026, 2, 27)),
            zero_q,
            rs,
        )
        t_on = DME.resolve_t_apply(
            EventTiming(; basis = :calendar, rule = :cutoff, effective_from = Date(2026, 2, 28)),
            zero_q,
            rs,
        )
        t_after = DME.resolve_t_apply(
            EventTiming(; basis = :calendar, rule = :cutoff, effective_from = Date(2026, 3, 1)),
            zero_q,
            rs,
        )
        @test t_before == 0
        @test t_on == 0
        @test t_after == 1
    end

    @testset "割当規則4種（:same_quarter/:next_quarter/:cutoff/:explicit_period）" begin
        zero_q = CalendarQuarter(2026, 1)
        rs = TimingRuleSet()
        same_q = DME.resolve_t_apply(
            EventTiming(; basis = :calendar, rule = :same_quarter, effective_from = Date(2026, 5, 1)),
            zero_q,
            rs,
        )
        @test same_q == 1   # 2026Q2

        next_q = DME.resolve_t_apply(
            EventTiming(; basis = :calendar, rule = :next_quarter, effective_from = Date(2026, 5, 1)),
            zero_q,
            rs,
        )
        @test next_q == 2   # 2026Q2 の翌期

        explicit = DME.resolve_t_apply(
            EventTiming(; basis = :period, rule = :explicit_period, t_apply = 5),
            nothing,
            rs,
        )
        @test explicit == 5

        @test_throws ArgumentError DME.resolve_t_apply(
            EventTiming(; basis = :calendar, rule = :cutoff, effective_from = Date(2026, 5, 1)),
            nothing,
            rs,
        )
    end

    @testset "時間形状6種の離散式一致" begin
        periods = collect(0:6)
        m = 4.0

        p_pulse = PersistenceSpec(; shape = :pulse)
        @test shock_shape_path(p_pulse, m, 2, periods, nothing) == [0.0, 0.0, m, 0.0, 0.0, 0.0, 0.0]

        p_step = PersistenceSpec(; shape = :step, duration = 3)
        @test shock_shape_path(p_step, m, 1, periods, nothing) == [0.0, m, m, m, 0.0, 0.0, 0.0]
        p_step_perm = PersistenceSpec(; shape = :step, duration = nothing)
        @test shock_shape_path(p_step_perm, m, 1, periods, nothing) == [0.0, m, m, m, m, m, m]

        p_ramp = PersistenceSpec(; shape = :ramp, duration = 4)
        expected_ramp = [0.0, m * 1 / 4, m * 2 / 4, m * 3 / 4, m, m, m]
        @test shock_shape_path(p_ramp, m, 1, periods, nothing) == expected_ramp

        p_str = PersistenceSpec(; shape = :step_then_ramp, params = (hold = 2, ramp_down = 2))
        got = shock_shape_path(p_str, m, 0, periods, nothing)
        @test got[1] == m         # t=0: hold
        @test got[2] == m         # t=1: hold
        @test got[3] == m * (1 - (2 - 0 - 2 + 1) / 2)   # t=2: ramp-down 1本目
        @test got[4] == 0.0       # t=3: 打ち切り後
        @test got[5] == 0.0

        h = 4
        p_ar1 = PersistenceSpec(; shape = :ar1_decay, params = (half_life = h,))
        rho = 0.5^(1 / h)
        expected_ar1 = [m * rho^t for t in periods]
        @test shock_shape_path(p_ar1, m, 0, periods, nothing) ≈ expected_ar1

        vals = [1.0, 2.0, 3.0]
        p_path = PersistenceSpec(; shape = :path, params = (values = vals,))
        @test shock_shape_path(p_path, 3.0, 2, periods, nothing) ==
              [0.0, 0.0, 1.0, 2.0, 3.0, 0.0, 0.0]
    end

    @testset "既存4形状が同一パラメータで同一ベクトルを返す（`Y-10`）" begin
        # capex_credit_cycle_scenarios.jl の `_ccc_shock_value`（委譲後）との一致を、
        # `CapexShockSpec` 経由で間接的に確認する（既存回帰は test_capex_credit_cycle.jl の
        # シナリオ Sc0–Sc4 テストが担う）。
        shock = CapexShockSpec(;
            target = :spread_shock_ex,
            meaning = "smoke",
            unit = "bp",
            sign = 1,
            timing = 1,
            shape = :ar1_decay,
            shape_params = (half_life = 4,),
            duration = nothing,
            magnitude = 150.0,
            application_mode = :additive,
        )
        for t in (-1, 1, 2, 5, 10)
            persistence = PersistenceSpec(; shape = :ar1_decay, params = (half_life = 4,))
            expected = t < 1 ? 0.0 : shock_shape_path(persistence, 150.0, 1, [t], nothing)[1]
            @test DME._ccc_shock_value(shock, t) == expected
        end
    end

    @testset "打ち切り（t_until）が6形状すべてに一律適用される（`Y-11`）" begin
        periods = collect(0:5)
        m = 3.0
        specs = [
            PersistenceSpec(; shape = :pulse),
            PersistenceSpec(; shape = :step, duration = nothing),
            PersistenceSpec(; shape = :ramp, duration = 4),
            PersistenceSpec(; shape = :step_then_ramp, params = (hold = 4, ramp_down = 4)),
            PersistenceSpec(; shape = :ar1_decay, params = (half_life = 4,)),
            PersistenceSpec(; shape = :path, params = (values = fill(m, 6),)),
        ]
        for p in specs
            got = shock_shape_path(p, m, 0, periods, 2)
            @test all(iszero, got[4:end])   # t > 2 は 0
        end
    end

    @testset "pathのmagnitude不一致が拒否される（`Y-12`、回帰確認）" begin
        # PersistenceSpec 自体は magnitude を持たないため、path の magnitude 不一致検証は
        # 4層レコード型のコンストラクタ（`_macro_event_check_path_persistence`）が行う
        # （Issue #197 で実装済み）。ここでは回帰確認のみ行う。
        persistence = PersistenceSpec(; shape = :path, params = (values = [1.0, 2.0, 3.0],))
        @test_throws ArgumentError InterpretedSignal(;
            event_id = "IS-path-1",
            event_type = :DemandOutlookRevision,
            announced_at = Date(2026, 1, 1),
            observed_at = Date(2026, 1, 1),
            known_at = Date(2026, 1, 2),
            source = EventSource(; publisher = "fictional wire", document_id = "doc-path-1"),
            provenance = EventProvenance(;
                layer = :interpreted,
                rule_id = "r1",
                rule_version = "1.0.0",
                generator = "human",
                derived_from = ["OE-1"],
            ),
            sector = :s1,
            direction = :down,
            magnitude_source = :observed,
            confidence = 0.8,
            magnitude = 99.0,
            unit = "%",
            target_concepts = [:demand_expectation],
            persistence = persistence,
        )
    end

    @testset "入力shuffleでも order_key 順・合成結果・ログ順が一致する（10回、統合設計 §10.2 item 8）" begin
        baseline = _es_baseline()
        sc = _es_scenario()
        inputs = [
            _es_input(; input_id = "in-1", assumption_id = "as-1", target = :policy_rate, mode = :additive, unit = "%pt", magnitude = -1.0, shape = :step, t_apply = 2, duration = 8),
            _es_input(; input_id = "in-2", assumption_id = "as-2", target = :ai_exp, mode = :multiplicative, unit = "%", magnitude = -10.0, shape = :ar1_decay, t_apply = 0, params = (half_life = 6,)),
            _es_input(; input_id = "in-3", assumption_id = "as-3", target = :spread_shock_ex, mode = :additive, unit = "bp", magnitude = 150.0, shape = :ar1_decay, t_apply = 1, params = (half_life = 4,)),
            _es_input(; input_id = "in-4", assumption_id = "as-4", target = :capex_plan_shock_ex, mode = :multiplicative, unit = "%", magnitude = -15.0, shape = :step_then_ramp, t_apply = 0, duration = 8, params = (hold = 4, ramp_down = 4)),
        ]
        reference = schedule_events(inputs, sc, baseline)
        reference_order = [se.input.input_id for se in reference.events]

        using Random: shuffle
        for _ in 1:10
            shuffled = shuffle(inputs)
            result = schedule_events(shuffled, sc, baseline)
            @test [se.input.input_id for se in result.events] == reference_order
            @test result.paths == reference.paths
        end
    end

    @testset "同一時点10イベント（3クラス混在）の合成が固定順どおり" begin
        n = length(_ES_PERIODS_28)
        baseline = Dict{Symbol, Vector{Float64}}(:price_s1 => fill(2.0, n))
        sc = _es_scenario()

        inputs = AppliedModelInput[]
        for i in 1:4
            push!(inputs, _es_input(; input_id = "mul-$i", assumption_id = "asm-$i", target = :price_s1, mode = :multiplicative, unit = "%", magnitude = Float64(i), shape = :step, t_apply = 0, duration = 20))
        end
        for i in 1:5
            push!(inputs, _es_input(; input_id = "add-$i", assumption_id = "asa-$i", target = :price_s1, mode = :additive, unit = "bn USD (2017 chained)", magnitude = Float64(i) * 0.1, shape = :step, t_apply = 0, duration = 20))
        end
        push!(inputs, _es_input(; input_id = "abs-1", assumption_id = "asb-1", target = :price_s1, mode = :absolute, unit = "bn USD (2017 chained)", magnitude = 9.0, shape = :step, t_apply = 0, duration = 20))
        @test length(inputs) == 10

        result = schedule_events(inputs, sc, baseline)
        idx = 0 + 8 + 1

        # 手計算での固定順合成: absolute(9.0) → multiplicative(1..4%を順に) → additive(0.1..0.5の和)
        x = 9.0
        for i in 1:4
            x *= 1 + Float64(i) / 100
        end
        for i in 1:5
            x += Float64(i) * 0.1
        end
        @test result.paths[:price_s1][idx] ≈ x
        @test isempty(result.rejections)
    end

    @testset "conflicting_absolute が構造化拒否される（自動補正しない）" begin
        n = length(_ES_PERIODS_28)
        baseline = Dict{Symbol, Vector{Float64}}(:price_s1 => fill(1.0, n))
        sc = _es_scenario()
        a1 = _es_input(; input_id = "abs-a", assumption_id = "asa-a", target = :price_s1, mode = :absolute, unit = "bn USD (2017 chained)", magnitude = 5.0, shape = :step, t_apply = 0, duration = 4)
        a2 = _es_input(; input_id = "abs-b", assumption_id = "asa-b", target = :price_s1, mode = :absolute, unit = "bn USD (2017 chained)", magnitude = 6.0, shape = :step, t_apply = 0, duration = 4)
        result = schedule_events([a1, a2], sc, baseline)
        @test any(r.code == :conflicting_absolute for r in result.rejections)
        rej = only(filter(r -> r.code == :conflicting_absolute, result.rejections))
        @test Set(rej.subject_ids) == Set(["abs-a", "abs-b"])
        @test !occursin("影響が無い", rej.detail)
        @test !occursin("効果が無い", rej.detail)
    end

    @testset "out_of_horizon が警告として記録され、無音で切り捨てられない（`Y-09`）" begin
        baseline = _es_baseline()
        sc = _es_scenario()
        inp_ok = _es_input(; input_id = "ok-1", assumption_id = "asok-1", target = :price_s1, mode = :additive, unit = "bn USD (2017 chained)", magnitude = 1.0, shape = :pulse, t_apply = 19)
        inp_over = _es_input(; input_id = "over-1", assumption_id = "asov-1", target = :price_s1, mode = :additive, unit = "bn USD (2017 chained)", magnitude = 1.0, shape = :pulse, t_apply = 20)
        inp_under = _es_input(; input_id = "under-1", assumption_id = "asun-1", target = :price_s1, mode = :additive, unit = "bn USD (2017 chained)", magnitude = 1.0, shape = :pulse, t_apply = -9)

        result = schedule_events([inp_ok, inp_over, inp_under], sc, baseline)
        oh = filter(w -> w.code == :out_of_horizon, result.warnings)
        @test length(oh) == 2
        @test Set(w.subject_ids[1] for w in oh) == Set(["over-1", "under-1"])
        @test any(se.input.input_id == "ok-1" for se in result.events)

        # ホライズンを変えると境界が追随する（`Y-09`）
        sc_wide = _es_scenario(; horizon_runup = 10, horizon_eval = 22)
        baseline_wide = Dict{Symbol, Vector{Float64}}(
            k => fill(v[1], 32) for (k, v) in baseline
        )
        inp_wide = _es_input(;
            input_id = "wide-1",
            assumption_id = "aswide-1",
            target = :price_s1,
            mode = :additive,
            unit = "bn USD (2017 chained)",
            magnitude = 1.0,
            shape = :pulse,
            t_apply = 20,
            periods = collect((-10):(21)),
        )
        result_wide = schedule_events([inp_wide], sc_wide, baseline_wide)
        @test isempty(filter(w -> w.code == :out_of_horizon, result_wide.warnings))
    end

    @testset "offsetting_events で net と両側の粗値が両方ログに残る" begin
        n = length(_ES_PERIODS_28)
        baseline = Dict{Symbol, Vector{Float64}}(:spread_shock_ex => zeros(n))
        sc = _es_scenario()
        up = _es_input(; input_id = "off-up", assumption_id = "asoff-up", target = :spread_shock_ex, mode = :additive, unit = "bp", magnitude = 50.0, shape = :pulse, t_apply = 1)
        down = _es_input(; input_id = "off-down", assumption_id = "asoff-down", target = :spread_shock_ex, mode = :additive, unit = "bp", magnitude = -30.0, shape = :pulse, t_apply = 1)
        result = schedule_events([up, down], sc, baseline)
        w = only(filter(x -> x.code == :offsetting_events, result.warnings))
        @test occursin("net=20.0", w.detail) || occursin("net=20", w.detail)
        @test occursin("50.0", w.detail) && occursin("-30.0", w.detail)
        @test Set(w.subject_ids) == Set(["off-up", "off-down"])
        # 相殺を理由にイベントを除去しない
        @test length(result.events) == 2
    end

    @testset "duplicate_dropped が削除ではなく警告として残る" begin
        baseline = _es_baseline()
        sc = _es_scenario()
        inp = _es_input(; input_id = "dup-1", assumption_id = "asdup-1", target = :price_s1, mode = :additive, unit = "bn USD (2017 chained)", magnitude = 1.0, shape = :pulse, t_apply = 0)
        inp_dup = _es_input(; input_id = "dup-1", assumption_id = "asdup-1", target = :price_s1, mode = :additive, unit = "bn USD (2017 chained)", magnitude = 1.0, shape = :pulse, t_apply = 0)
        result = schedule_events([inp, inp_dup], sc, baseline)
        @test length(result.events) == 1
        @test any(w.code == :duplicate_dropped for w in result.warnings)
    end

    @testset "schedulerがファイル・時計・乱数・モデル状態にアクセスしない" begin
        baseline = _es_baseline()
        sc = _es_scenario()
        inputs = [
            _es_input(; input_id = "pure-1", assumption_id = "aspure-1", target = :policy_rate, mode = :additive, unit = "%pt", magnitude = -0.5, shape = :step, t_apply = 0, duration = 4),
        ]
        r1 = schedule_events(inputs, sc, baseline)
        r2 = schedule_events(inputs, sc, baseline)
        @test r1.paths == r2.paths
        @test [e.order_key for e in r1.events] == [e.order_key for e in r2.events]
        @test length(r1.warnings) == length(r2.warnings)
    end
end
