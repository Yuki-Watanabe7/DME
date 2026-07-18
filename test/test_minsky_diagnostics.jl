@testset "Minsky continuous diagnostics & summary (Phase 2)" begin
    # Grasselli & Costa Lima (2012) の数値例
    m = KeenModel(0.025, 0.02, 0.01, 3.0, 0.03, 0.0400641, 6.41e-5, -0.0065, exp(-5), 20.0)
    ss = steady_state(m)
    r = m.r

    @testset "MinskyDiagnosticObservation: Hedge/Ponzi 入力（amortization_rate=0）で式通り" begin
        cfg = FinancingRegimeConfig(; amortization_rate = 0.0)
        ω = [0.3, 0.99]
        d = [0.5, 10.0]
        g = [0.04, 0.01]
        diag = minsky_diagnostics(m, (ω = ω, d = d, g = g); config = cfg)

        o1 = diag.observations[1]
        @test o1.debt_ratio == d[1]
        @test o1.operating_surplus_share ≈ 1 - ω[1]
        @test o1.net_profit_share ≈ 1 - ω[1] - r * d[1]
        @test o1.interest_burden ≈ r * d[1]
        @test o1.principal_commitment_proxy ≈ 0.0
        @test o1.ponzi_margin ≈ o1.operating_surplus_share - o1.interest_burden
        @test o1.hedge_margin ≈ o1.ponzi_margin  # amortization_rate=0 => hedge_margin == ponzi_margin
        @test o1.interest_coverage_ratio ≈ o1.operating_surplus_share / o1.interest_burden
        @test o1.debt_service_coverage_ratio ≈ o1.interest_coverage_ratio
        @test isnan(o1.debt_change)  # 前期が存在しない
        @test o1.growth_rate == g[1]
        @test o1.divergence_status == DME.no_divergence
        @test o1.methodology_version == DME.MINSKY_DIAGNOSTICS_METHODOLOGY_VERSION
        @test diag.regime_diagnostics.observations[1].regime == hedge

        o2 = diag.observations[2]
        @test o2.debt_change ≈ d[2] - d[1]
        @test diag.regime_diagnostics.observations[2].regime == ponzi
        @test o2.ponzi_margin < 0
        # Ponzi は「利払いを賄えない」(ratio < 1) であり、営業余剰自体が正であれば ratio も正
        @test 0 < o2.interest_coverage_ratio < 1
    end

    @testset "MinskyDiagnosticObservation: Speculative 入力（amortization_rate>0）で式通り" begin
        cfg = FinancingRegimeConfig(; amortization_rate = 0.5)
        ω = [0.5, 0.5]
        d = [1.0, 1.0]
        g = [0.03, 0.03]
        diag = minsky_diagnostics(m, (ω = ω, d = d, g = g); config = cfg)
        @test diag.regime_diagnostics.observations[1].regime == speculative

        o1 = diag.observations[1]
        @test o1.ponzi_margin >= 0
        @test o1.hedge_margin < 0
        @test o1.interest_coverage_ratio > 1  # 利払いは賄える
        # Speculative は「元本返済代理までは賄えない」(ratio < 1) だが営業余剰自体は正
        @test 0 < o1.debt_service_coverage_ratio < 1
        @test o1.debt_service_coverage_ratio ≈
              o1.operating_surplus_share /
              (o1.interest_burden + o1.principal_commitment_proxy)
    end

    @testset "MinskyDiagnosticObservation: 無借金・負の債務比率で coverage ratio が Inf" begin
        cfg = FinancingRegimeConfig()
        ω = [0.5, 0.5]
        d = [0.0, -2.0]  # d <= 0 => interest_burden/debt_service が厳密に 0.0
        g = [0.04, 0.04]
        diag = minsky_diagnostics(m, (ω = ω, d = d, g = g); config = cfg)
        for i in 1:2
            o = diag.observations[i]
            @test o.interest_burden == 0.0
            @test o.principal_commitment_proxy == 0.0
            @test o.interest_coverage_ratio == Inf
            @test o.debt_service_coverage_ratio == Inf
            @test diag.regime_diagnostics.observations[i].regime == unlevered
        end
    end

    @testset "MinskyDiagnosticObservation: unlevered域内でも d>0 の微小値では厳密な Inf にならない" begin
        cfg = FinancingRegimeConfig()  # debt_tolerance 既定 1e-8
        ω = [0.5]
        d = [1e-9]  # d <= debt_tolerance のため regime は unlevered だが d > 0 厳密
        g = [0.04]
        diag = minsky_diagnostics(m, (ω = ω, d = d, g = g); config = cfg)
        o = diag.observations[1]
        @test diag.regime_diagnostics.observations[1].regime == unlevered
        @test o.interest_burden > 0.0  # 厳密には非ゼロ
        @test isfinite(o.interest_coverage_ratio)  # d<=0 の場合と異なり Inf にはならない
        @test o.interest_coverage_ratio > 1e6  # ただし非常に大きい値になる
    end

    @testset "MinskyDiagnosticObservation: 非有限値で NaN（Ponzi/Hedge に誤分類されない）" begin
        cfg = FinancingRegimeConfig()
        # ω のみ非有限（period 2）・d のみ非有限（period 3）のいずれでも、
        # interest_burden 等 d・r のみに依存する量まで含めてすべて NaN になることを確認する
        # （NaN 伝播だけに頼ると ω のみ非有限な場合に interest_burden 等が有限のまま残る）
        ω = [0.5, NaN, 0.5]
        d = [1.0, 1.0, Inf]
        g = [0.03, 0.03, 0.03]
        diag = minsky_diagnostics(m, (ω = ω, d = d, g = g); config = cfg)

        o2 = diag.observations[2]
        @test isnan(o2.operating_surplus_share)
        @test isnan(o2.net_profit_share)
        @test isnan(o2.interest_burden)
        @test isnan(o2.principal_commitment_proxy)
        @test isnan(o2.interest_coverage_ratio)
        @test isnan(o2.debt_service_coverage_ratio)
        @test isnan(o2.ponzi_margin)
        @test isnan(o2.hedge_margin)
        @test o2.debt_ratio == d[2]  # 入力値そのまま保持（d 自体は有限）
        @test diag.regime_diagnostics.observations[2].regime == invalid

        o3 = diag.observations[3]
        @test isnan(o3.operating_surplus_share)
        @test isnan(o3.interest_burden)
        @test isnan(o3.interest_coverage_ratio)
        @test isnan(o3.debt_service_coverage_ratio)
        @test isnan(o3.debt_change)  # 前期 d[2]=1.0 は有限だが当期が非有限のため NaN
        @test diag.regime_diagnostics.observations[3].regime == invalid
    end

    @testset "MinskyDiagnostics: 崩壊経路で divergence_status が onset/continued/no_divergence を区別" begin
        result = simulate(m, ss.ω, ss.λ, 5.0; T = 300)
        diag = minsky_diagnostics(m, result)

        @test diag.divergence_time !== nothing
        t0 = diag.divergence_time
        @test all(
            diag.observations[i].divergence_status == DME.no_divergence for i in 1:(t0 - 1)
        )
        @test diag.observations[t0].divergence_status == DME.divergence_onset
        @test all(
            diag.observations[i].divergence_status == DME.divergence_continued for
            i in (t0 + 1):300
        )
        @test diag.valid_periods == collect(1:(t0 - 1))
        @test diag.invalid_periods == collect(t0:300)
    end

    @testset "MinskyDiagnostics: 微小攪乱（発散なし）では divergence_time が nothing" begin
        result = simulate(m, ss.ω, ss.λ, ss.d + 0.01; T = 300)
        diag = minsky_diagnostics(m, result)
        @test diag.divergence_time === nothing
        @test all(o -> o.divergence_status == DME.no_divergence, diag.observations)
        @test length(diag.valid_periods) == 300
        @test isempty(diag.invalid_periods)
    end

    @testset "MinskyDiagnostics: NamedTuple と SimulationResult で同一結果" begin
        result = simulate(m, ss.ω, ss.λ, 5.0; T = 300)
        sr = to_simulation_result(m, result, "simulate")

        diag_nt = minsky_diagnostics(m, result; scenario_name = "simulate")
        diag_sr = minsky_diagnostics(sr)

        @test length(diag_nt.observations) == length(diag_sr.observations)
        for (o1, o2) in zip(diag_nt.observations, diag_sr.observations)
            @test isequal(o1.debt_ratio, o2.debt_ratio)
            @test isequal(o1.interest_coverage_ratio, o2.interest_coverage_ratio)
            @test isequal(o1.debt_service_coverage_ratio, o2.debt_service_coverage_ratio)
            @test isequal(o1.ponzi_margin, o2.ponzi_margin)
            @test isequal(o1.hedge_margin, o2.hedge_margin)
            @test isequal(o1.debt_change, o2.debt_change)
            @test o1.divergence_status == o2.divergence_status
        end
        @test diag_nt.divergence_time == diag_sr.divergence_time
        @test diag_nt.metadata["debt_change_method"] == "discrete_diff"
        @test diag_sr.metadata["debt_change_method"] == "discrete_diff"
    end

    @testset "MinskyDiagnostics: 決定性・入力非破壊" begin
        result = simulate(m, ss.ω, ss.λ, 5.0; T = 300)
        result_before = deepcopy(result)

        diag1 = minsky_diagnostics(m, result)
        diag2 = minsky_diagnostics(m, result)

        for (o1, o2) in zip(diag1.observations, diag2.observations)
            @test isequal(o1.interest_coverage_ratio, o2.interest_coverage_ratio)
            @test isequal(o1.debt_change, o2.debt_change)
            @test o1.divergence_status == o2.divergence_status
        end

        @test isequal(result.ω, result_before.ω)
        @test isequal(result.d, result_before.d)
        @test isequal(result.g, result_before.g)
    end

    @testset "MinskyDiagnostics: amortization_rate を変えても元の simulate 結果は変更しない" begin
        result = simulate(m, ss.ω, ss.λ, ss.d + 0.01; T = 300)
        result_before = deepcopy(result)

        diag_low = minsky_diagnostics(
            m,
            result;
            config = FinancingRegimeConfig(; amortization_rate = 0.0),
        )
        diag_high = minsky_diagnostics(
            m,
            result;
            config = FinancingRegimeConfig(; amortization_rate = 0.5),
        )

        @test isequal(result.ω, result_before.ω)
        @test isequal(result.d, result_before.d)
        @test isequal(result.g, result_before.g)

        for i in eachindex(diag_low.observations)
            @test diag_high.observations[i].hedge_margin <=
                  diag_low.observations[i].hedge_margin
            @test diag_high.observations[i].ponzi_margin ≈
                  diag_low.observations[i].ponzi_margin
            @test diag_high.observations[i].debt_ratio ==
                  diag_low.observations[i].debt_ratio
        end
    end

    @testset "minsky_diagnostics_summary: 明確な区分遷移で first/recovery/peak/min が off-by-one なし" begin
        cfg = FinancingRegimeConfig(; amortization_rate = 0.1)
        d_level = 2.0
        debt_service_rate = r + cfg.amortization_rate
        ω_hedge_boundary = 1 - debt_service_rate * d_level
        ω_ponzi_boundary = 1 - r * d_level

        # 期1: hedge / 期2: speculative / 期3: ponzi / 期4: hedge（回復）
        ω = [
            ω_hedge_boundary - 0.05,
            ω_hedge_boundary + 0.05,
            ω_ponzi_boundary + 0.05,
            ω_hedge_boundary - 0.05,
        ]
        d = fill(d_level, 4)
        g = [0.02, 0.02, 0.02, 0.02]

        diag = minsky_diagnostics(m, (ω = ω, d = d, g = g); config = cfg)
        regimes = [o.regime for o in diag.regime_diagnostics.observations]
        @test regimes == [hedge, speculative, ponzi, hedge]

        s = minsky_diagnostics_summary(diag)
        @test s.n_periods == 4
        @test s.n_valid == 4
        @test s.n_invalid == 0
        @test s.first_speculative_time == 2
        @test s.first_ponzi_time == 3
        @test s.recovery_to_hedge_time == 4
        @test s.diverged == false
        @test s.divergence_time === nothing

        @test s.regime_counts[hedge] == 2
        @test s.regime_counts[speculative] == 1
        @test s.regime_counts[ponzi] == 1
        @test s.regime_counts[unlevered] == 0
        @test s.regime_counts[invalid] == 0
        @test s.regime_share_of_valid[hedge] ≈ 0.5
        @test s.regime_share_of_valid[speculative] ≈ 0.25
        @test s.regime_share_of_valid[ponzi] ≈ 0.25
        @test s.regime_share_of_valid[invalid] ≈ 0.0

        # d は全期間一定 -> peak はタイの先頭（期1）
        @test s.peak_debt_ratio ≈ d_level
        @test s.peak_debt_ratio_time == 1

        # debt_change は期2-4 で 0（d 一定）、期1 は NaN で除外される
        @test s.max_debt_change ≈ 0.0
        @test s.max_debt_change_time == 2

        # ponzi 期（期3）が ponzi_margin の最小
        @test s.min_ponzi_margin_time == 3
        # hedge_margin の最小も ponzi 期であるはず（最も逼迫）
        @test s.min_hedge_margin_time == 3
    end

    @testset "minsky_diagnostics_summary: イベントが存在しない場合は nothing" begin
        result = simulate(m, ss.ω, ss.λ, ss.d + 0.01; T = 300)  # 均衡近傍、崩壊なし
        diag = minsky_diagnostics(m, result)
        s = minsky_diagnostics_summary(diag)

        @test s.first_speculative_time === nothing
        @test s.first_ponzi_time === nothing
        @test s.recovery_to_hedge_time === nothing
        @test s.diverged == false
        @test s.divergence_time === nothing
        @test s.peak_debt_ratio !== nothing
        @test s.min_interest_coverage_ratio !== nothing
    end

    @testset "minsky_diagnostics_summary: 崩壊経路では発散後の観測が peak/min から除外される" begin
        result = simulate(m, ss.ω, ss.λ, 5.0; T = 300)
        diag = minsky_diagnostics(m, result)
        s = minsky_diagnostics_summary(diag)

        @test s.diverged == true
        @test s.divergence_time == diag.divergence_time
        @test s.n_valid + s.n_invalid == s.n_periods
        @test s.n_invalid > 0

        # 発散後は NaN のため、抽出された peak/min は非有限値であってはならない
        @test isfinite(s.peak_debt_ratio)
        @test isfinite(s.min_interest_coverage_ratio)
        @test isfinite(s.min_debt_service_coverage_ratio)
        @test isfinite(s.min_ponzi_margin)
        @test isfinite(s.min_hedge_margin)
        @test s.peak_debt_ratio_time < diag.divergence_time
        @test s.min_ponzi_margin_time < diag.divergence_time
    end

    @testset "minsky_diagnostics_comparison: baseline と高債務シナリオで診断差が検出される" begin
        diag_base = minsky_diagnostics(
            m,
            simulate(m, ss.ω, ss.λ, ss.d + 0.01; T = 300);
            scenario_name = "baseline",
        )
        diag_high_debt = minsky_diagnostics(
            m,
            simulate(m, ss.ω, ss.λ, 5.0; T = 300);
            scenario_name = "high_debt",
        )

        cmp = minsky_diagnostics_comparison([
            "baseline" => diag_base,
            "high_debt" => diag_high_debt,
        ],)
        @test cmp.scenario_names == ["baseline", "high_debt"]
        @test length(cmp.summaries) == 2

        s_base, s_high = cmp.summaries
        @test s_base.diverged == false
        @test s_high.diverged == true
        @test s_high.peak_debt_ratio > s_base.peak_debt_ratio
        @test s_high.first_ponzi_time !== nothing
        @test s_base.first_ponzi_time === nothing
    end

    @testset "minsky_diagnostics_comparison: amortization_rate 感応度シナリオを比較" begin
        result = simulate(m, ss.ω, ss.λ, ss.d + 0.01; T = 300)
        diag_low = minsky_diagnostics(
            m,
            result;
            config = FinancingRegimeConfig(; amortization_rate = 0.0),
            scenario_name = "amortization_low",
        )
        diag_high = minsky_diagnostics(
            m,
            result;
            config = FinancingRegimeConfig(; amortization_rate = 0.5),
            scenario_name = "amortization_high",
        )

        cmp = minsky_diagnostics_comparison([
            "amortization_low" => diag_low,
            "amortization_high" => diag_high,
        ],)
        @test cmp.summaries[1].config.amortization_rate == 0.0
        @test cmp.summaries[2].config.amortization_rate == 0.5
        # 各シナリオの methodology version はそれぞれ保持される（暗黙の同列比較をしない）
        @test cmp.summaries[1].config.methodology_version ==
              cmp.summaries[2].config.methodology_version ==
              "minsky-regime/1.0.0"
    end

    @testset "minsky_diagnostics_comparison: 空配列はエラー" begin
        @test_throws ArgumentError minsky_diagnostics_comparison(
            Pair{String, MinskyDiagnosticsResult}[],
        )
    end

    @testset "minsky_diagnostics(NamedTuple): 必須フィールドがない・長さ不一致はエラー" begin
        @test_throws ArgumentError minsky_diagnostics(m, (λ = [0.9], d = [0.1]))
        @test_throws ArgumentError minsky_diagnostics(
            m,
            (ω = [0.5, 0.5], d = [0.1], g = [0.04, 0.04]),
        )
    end

    @testset "minsky_diagnostics(SimulationResult): エラーケース" begin
        sr_missing_g = SimulationResult(
            "Keen Model",
            "simulate",
            Dict("ω" => [0.5, 0.5], "d" => [0.1, 0.1]),
            Dict{String, Any}("parameters" => (r = 0.03,)),
        )
        @test_throws ArgumentError minsky_diagnostics(sr_missing_g)

        sr_missing_r = SimulationResult(
            "Keen Model",
            "simulate",
            Dict("ω" => [0.5, 0.5], "d" => [0.1, 0.1], "g" => [0.04, 0.04]),
            Dict{String, Any}("parameters" => (α = 0.025,)),
        )
        @test_throws ArgumentError minsky_diagnostics(sr_missing_r)

        sr_no_metadata = SimulationResult(
            "Keen Model",
            "simulate",
            Dict("ω" => [0.5, 0.5], "d" => [0.1, 0.1], "g" => [0.04, 0.04]),
        )
        @test_throws ArgumentError minsky_diagnostics(sr_no_metadata)
    end
end
