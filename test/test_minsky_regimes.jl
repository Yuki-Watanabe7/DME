@testset "Minsky financing regime diagnostics" begin
    # Grasselli & Costa Lima (2012) の数値例
    m = KeenModel(0.025, 0.02, 0.01, 3.0, 0.03, 0.0400641, 6.41e-5, -0.0065, exp(-5), 20.0)
    ss = steady_state(m)

    @testset "FinancingRegimeConfig: 既定値・検証" begin
        cfg = FinancingRegimeConfig()
        @test cfg.amortization_rate == 0.05
        @test cfg.debt_tolerance == 1e-8
        @test cfg.classification_tolerance == 1e-9
        @test cfg.methodology_version == "minsky-regime/1.0.0"

        cfg2 = FinancingRegimeConfig(; amortization_rate = 0.1)
        @test cfg2.amortization_rate == 0.1

        @test_throws ArgumentError FinancingRegimeConfig(; amortization_rate = -0.01)
        @test_throws ArgumentError FinancingRegimeConfig(; amortization_rate = NaN)
        @test_throws ArgumentError FinancingRegimeConfig(; classification_tolerance = -1e-9)
        @test_throws ArgumentError FinancingRegimeConfig(; debt_tolerance = Inf)
    end

    @testset "classify_financing_regime: 明確な Hedge / Speculative / Ponzi 入力" begin
        # amortization_rate=0 とし debt_service = interest_commitment とすることで
        # Hedge/Ponzi のみの単純な境界で明確な入力を作る
        cfg = FinancingRegimeConfig(; amortization_rate = 0.0)

        # Hedge: operating_surplus が利払いを大きく上回る（ω 小さい, d 小さい）
        obs_hedge = classify_financing_regime(m, 0.3, 0.5; config = cfg)
        @test obs_hedge.regime == hedge
        @test obs_hedge.hedge_margin > 0
        @test obs_hedge.ponzi_margin > 0

        # Ponzi: operating_surplus が利払いすら賄わない（ω が 1 に近く d が大きい）
        obs_ponzi = classify_financing_regime(m, 0.99, 10.0; config = cfg)
        @test obs_ponzi.regime == ponzi
        @test obs_ponzi.hedge_margin < 0
        @test obs_ponzi.ponzi_margin < 0

        # Speculative: amortization_rate > 0 で、利払いは賄うが元本返済代理までは賄わない
        cfg2 = FinancingRegimeConfig(; amortization_rate = 0.5)
        # ω, d を選び π はプラスだが π - principal_commitment はマイナスになるよう調整
        obs_spec = classify_financing_regime(m, 0.5, 1.0; config = cfg2)
        @test obs_spec.regime == speculative
        @test obs_spec.ponzi_margin >= 0
        @test obs_spec.hedge_margin < 0
    end

    @testset "classify_financing_regime: Hedge–Speculative / Speculative–Ponzi 境界許容差" begin
        cfg = FinancingRegimeConfig(;
            amortization_rate = 0.1,
            classification_tolerance = 1e-6,
        )
        r = m.r
        d = 2.0
        debt_service_rate = r + cfg.amortization_rate
        ω_hedge_boundary = 1 - debt_service_rate * d

        obs_exact = classify_financing_regime(m, ω_hedge_boundary, d; config = cfg)
        @test abs(obs_exact.hedge_margin) < 1e-10
        @test obs_exact.regime == hedge

        # 許容差内のわずかな超過（margin が -τ より大きい）は hedge に留まる
        obs_within = classify_financing_regime(m, ω_hedge_boundary + 5e-7, d; config = cfg)
        @test obs_within.hedge_margin < 0
        @test obs_within.hedge_margin >= -cfg.classification_tolerance
        @test obs_within.regime == hedge

        # 許容差を超えるマイナスは speculative に落ちる
        obs_beyond = classify_financing_regime(m, ω_hedge_boundary + 1e-4, d; config = cfg)
        @test obs_beyond.hedge_margin < -cfg.classification_tolerance
        @test obs_beyond.regime == speculative

        # Speculative-Ponzi 境界（ponzi_margin = operating_surplus - interest_commitment = 0）
        ω_ponzi_boundary = 1 - r * d
        obs_ponzi_exact = classify_financing_regime(m, ω_ponzi_boundary, d; config = cfg)
        @test abs(obs_ponzi_exact.ponzi_margin) < 1e-10
        @test obs_ponzi_exact.regime == speculative  # 賄える側(speculative)に確定

        obs_ponzi_beyond =
            classify_financing_regime(m, ω_ponzi_boundary + 1e-4, d; config = cfg)
        @test obs_ponzi_beyond.ponzi_margin < -cfg.classification_tolerance
        @test obs_ponzi_beyond.regime == ponzi
    end

    @testset "classify_financing_regime: d=0・微小正債務・負の債務比率" begin
        @test classify_financing_regime(m, 0.5, 0.0).regime == unlevered
        @test classify_financing_regime(m, 0.5, 1e-9).regime == unlevered  # < debt_tolerance 既定 1e-8
        @test classify_financing_regime(m, 0.5, -2.0).regime == unlevered  # 純貸し手

        # debt_tolerance を超える微小正債務は unlevered から外れる
        obs = classify_financing_regime(m, 0.1, 1e-6)
        @test obs.regime != unlevered
    end

    @testset "classify_financing_regime: 非有限値" begin
        @test classify_financing_regime(m, NaN, 1.0).regime == invalid
        @test classify_financing_regime(m, 0.5, NaN).regime == invalid
        @test classify_financing_regime(m, Inf, 1.0).regime == invalid
        @test classify_financing_regime(m, 0.5, -Inf).regime == invalid

        obs = classify_financing_regime(m, NaN, NaN)
        @test isnan(obs.operating_surplus)
        @test isnan(obs.interest_commitment)
        @test isnan(obs.principal_commitment)
        @test isnan(obs.debt_service)
        @test isnan(obs.ponzi_margin)
        @test isnan(obs.hedge_margin)
    end

    @testset "classify_financing_regime: 判定根拠の追跡（再計算不要）" begin
        obs = classify_financing_regime(m, ss.ω, ss.d; time = 42)
        @test obs.time == 42
        @test obs.ω == ss.ω
        @test obs.d == ss.d
        @test obs.r == m.r
        @test obs.operating_surplus ≈ 1 - ss.ω
        @test obs.interest_commitment ≈ m.r * ss.d
        @test obs.principal_commitment ≈ 0.05 * ss.d  # 既定 amortization_rate
        @test obs.debt_service ≈ obs.interest_commitment + obs.principal_commitment
        @test obs.ponzi_margin ≈ obs.operating_surplus - obs.interest_commitment
        @test obs.hedge_margin ≈ obs.operating_surplus - obs.debt_service
        @test obs.methodology_version == "minsky-regime/1.0.0"
    end

    @testset "diagnose_financing_regime: 微小攪乱（発散なし）の時系列" begin
        result = simulate(m, ss.ω, ss.λ, ss.d + 0.01; T = 300)
        diag = diagnose_financing_regime(m, result)

        @test length(diag.observations) == 300
        @test isempty(diag.invalid_periods)
        @test length(diag.valid_periods) == 300
        @test all(obs.regime != invalid for obs in diag.observations)
        @test diag.config.methodology_version == "minsky-regime/1.0.0"
    end

    @testset "diagnose_financing_regime: 崩壊経路（発散後 NaN）の時系列" begin
        result = simulate(m, ss.ω, ss.λ, 5.0; T = 300)
        diag = diagnose_financing_regime(m, result)

        @test length(diag.observations) == 300  # 元系列長を保持（切り詰めない）

        first_nan = findfirst(isnan, result.ω)
        @test first_nan !== nothing

        # 発散前は invalid でない
        @test all(diag.observations[i].regime != invalid for i in 1:(first_nan - 1))
        # 発散後はすべて invalid（Ponzi へ誤分類されない）
        @test all(diag.observations[i].regime == invalid for i in first_nan:300)
        @test all(diag.observations[i].regime != ponzi for i in first_nan:300)

        @test diag.valid_periods == collect(1:(first_nan - 1))
        @test diag.invalid_periods == collect(first_nan:300)
    end

    @testset "financing regime transitions: 順序・時点・margin" begin
        # 崩壊経路: hedge/speculative/ponzi を経て最終的に invalid へ移行するはず
        result = simulate(m, ss.ω, ss.λ, 5.0; T = 300)
        diag = diagnose_financing_regime(m, result)

        @test !isempty(diag.transitions)
        # 遷移は時点順に並んでいる
        @test issorted([t.time for t in diag.transitions])
        for t in diag.transitions
            @test diag.observations[t.time].regime == t.to
            @test diag.observations[t.time - 1].regime == t.from
            @test t.from_observation.time == t.time - 1
            @test t.to_observation.time == t.time
            @test isequal(t.ponzi_margin, t.to_observation.ponzi_margin)
            @test isequal(t.hedge_margin, t.to_observation.hedge_margin)
        end

        # 最終的に invalid への遷移が含まれる（発散イベント）
        @test any(t.to == invalid for t in diag.transitions)
        # invalid への遷移の前は経済的区分（hedge/speculative/ponzi/unlevered）
        invalid_transition = first(t for t in diag.transitions if t.to == invalid)
        @test invalid_transition.from in (hedge, speculative, ponzi, unlevered)
    end

    @testset "diagnose_financing_regime: amortization_rate 感応度" begin
        result = simulate(m, ss.ω, ss.λ, ss.d + 0.01; T = 300)

        diag_low = diagnose_financing_regime(
            m,
            result;
            config = FinancingRegimeConfig(; amortization_rate = 0.0),
        )
        diag_high = diagnose_financing_regime(
            m,
            result;
            config = FinancingRegimeConfig(; amortization_rate = 0.5),
        )

        # amortization_rate=0 では speculative 帯が消失する（hedge/ponzi の境界のみ）
        @test count(o -> o.regime == speculative, diag_low.observations) == 0

        # amortization_rate を引き上げると hedge_margin は狭まる（より小さくなる）
        for i in eachindex(diag_low.observations)
            @test diag_high.observations[i].hedge_margin <=
                  diag_low.observations[i].hedge_margin
            # ponzi_margin は amortization_rate に依存しない
            @test diag_high.observations[i].ponzi_margin ≈
                  diag_low.observations[i].ponzi_margin
        end
    end

    @testset "diagnose_financing_regime: NamedTuple と SimulationResult で同一結果" begin
        result = simulate(m, ss.ω, ss.λ, 5.0; T = 300)  # 崩壊経路を含める
        sr = to_simulation_result(m, result, "simulate")

        diag_nt = diagnose_financing_regime(m, result)
        diag_sr = diagnose_financing_regime(sr)

        @test length(diag_nt.observations) == length(diag_sr.observations)
        for (o1, o2) in zip(diag_nt.observations, diag_sr.observations)
            @test o1.regime == o2.regime
            @test isequal(o1.ω, o2.ω)
            @test isequal(o1.d, o2.d)
            @test o1.r == o2.r
            @test isequal(o1.operating_surplus, o2.operating_surplus)
            @test isequal(o1.ponzi_margin, o2.ponzi_margin)
            @test isequal(o1.hedge_margin, o2.hedge_margin)
        end
        @test length(diag_nt.transitions) == length(diag_sr.transitions)
        @test diag_nt.valid_periods == diag_sr.valid_periods
        @test diag_nt.invalid_periods == diag_sr.invalid_periods
    end

    @testset "diagnose_financing_regime(SimulationResult): エラーケース" begin
        sr_missing_var = SimulationResult(
            "Keen Model",
            "simulate",
            Dict("ω" => [0.5, 0.5], "λ" => [0.9, 0.9]),  # "d" 欠落
            Dict{String, Any}("parameters" => (r = 0.03,)),
        )
        @test_throws ArgumentError diagnose_financing_regime(sr_missing_var)

        sr_missing_r = SimulationResult(
            "Keen Model",
            "simulate",
            Dict("ω" => [0.5, 0.5], "d" => [0.1, 0.1]),
            Dict{String, Any}("parameters" => (α = 0.025,)),  # r 欠落
        )
        @test_throws ArgumentError diagnose_financing_regime(sr_missing_r)

        sr_no_metadata = SimulationResult(
            "Keen Model",
            "simulate",
            Dict("ω" => [0.5, 0.5], "d" => [0.1, 0.1]),
        )
        @test_throws ArgumentError diagnose_financing_regime(sr_no_metadata)
    end

    @testset "diagnose_financing_regime: 決定性・入力非破壊" begin
        result = simulate(m, ss.ω, ss.λ, 5.0; T = 300)
        result_before = deepcopy(result)

        diag1 = diagnose_financing_regime(m, result)
        diag2 = diagnose_financing_regime(m, result)

        @test length(diag1.observations) == length(diag2.observations)
        for (o1, o2) in zip(diag1.observations, diag2.observations)
            @test o1.regime == o2.regime
            @test isequal(o1.ponzi_margin, o2.ponzi_margin)
            @test isequal(o1.hedge_margin, o2.hedge_margin)
        end

        # 入力（simulate の結果）は変更されない
        @test isequal(result.ω, result_before.ω)
        @test isequal(result.λ, result_before.λ)
        @test isequal(result.d, result_before.d)
    end

    @testset "classify_financing_regime: 長さ不一致の NamedTuple はエラー" begin
        bad_result = (ω = [0.5, 0.5], λ = [0.9, 0.9], d = [0.1])
        @test_throws ArgumentError diagnose_financing_regime(m, bad_result)
    end

    @testset "diagnose_financing_regime: NamedTuple に必須フィールドがない" begin
        bad_result = (λ = [0.9], d = [0.1])
        @test_throws ArgumentError diagnose_financing_regime(m, bad_result)
    end
end
