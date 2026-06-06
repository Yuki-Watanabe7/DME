@testset "NewKeynesianModel" begin
    # 標準的なパラメータ
    # σ=1.0, r_n=0.02, β=0.99, κ=0.1
    # φ_π=1.5, φ_x=0.5, π_star=0.02
    # ρ_x=0.8, ρ_c=0.5, ρ_m=0.5
    m = NewKeynesianModel(1.0, 0.02, 0.99, 0.1, 1.5, 0.5, 0.02, 0.8, 0.5, 0.5)

    @testset "model_name" begin
        @test model_name(m) == "New Keynesian Model"
    end

    @testset "state_variables / control_variables / parameters" begin
        @test state_variables(m) == Symbol[]
        @test control_variables(m) == [:x, :π, :i]
        p = parameters(m)
        @test p.σ      == 1.0
        @test p.r_n    == 0.02
        @test p.β      == 0.99
        @test p.κ      == 0.1
        @test p.φ_π    == 1.5
        @test p.φ_x    == 0.5
        @test p.π_star == 0.02
        @test p.ρ_x    == 0.8
        @test p.ρ_c    == 0.5
        @test p.ρ_m    == 0.5
    end

    @testset "steady_state" begin
        ss = steady_state(m)
        @test ss.x ≈ 0.0 atol = 1e-12
        @test ss.π ≈ 0.02 atol = 1e-12
        @test ss.i ≈ 0.04 atol = 1e-12   # r_n + π_star = 0.02 + 0.02
    end

    @testset "simulate（長さ1ベクトル）" begin
        result = simulate(m)
        @test length(result.x) == 1
        @test length(result.π) == 1
        @test length(result.i) == 1
        ss = steady_state(m)
        @test result.x[1] ≈ ss.x atol = 1e-12
        @test result.π[1] ≈ ss.π atol = 1e-12
        @test result.i[1] ≈ ss.i atol = 1e-12
    end

    @testset "to_simulation_result" begin
        sim = simulate(m)
        sr = to_simulation_result(m, sim, "equilibrium")
        @test sr.model_name == "New Keynesian Model"
        @test sr.scenario_name == "equilibrium"
        @test haskey(sr, "x")
        @test haskey(sr, "π")
        @test haskey(sr, "i")
        @test nperiods(sr) == 1
        @test "parameters" in keys(sr.metadata)
    end

    @testset "impulse_response: 需要ショック（x↑, π↑, i↑）" begin
        irf = impulse_response(m, 1.0; shock = :demand, T = 20)
        @test length(irf.x) == 20
        @test length(irf.π) == 20
        @test length(irf.i) == 20
        # 需要ショック → 産出ギャップ上昇・インフレ上昇・利子率上昇
        @test irf.x[1] > 0
        @test irf.π[1] > 0
        @test irf.i[1] > 0
        # ショック持続性に従って減衰
        @test abs(irf.x[10]) < abs(irf.x[1])
        @test abs(irf.π[10]) < abs(irf.π[1])
        # MSV解: AS曲線との整合（定常状態近傍のirfが収束）
        @test abs(irf.x[20]) < abs(irf.x[1])
    end

    @testset "impulse_response: コストプッシュショック（x↓, π↑, i↑）" begin
        irf = impulse_response(m, 1.0; shock = :cost_push, T = 20)
        # コストプッシュ → インフレ上昇・産出ギャップ低下（中銀が利上げ）
        @test irf.π[1] > 0
        @test irf.x[1] < 0
        @test irf.i[1] > 0
    end

    @testset "impulse_response: 金融政策ショック（予期せぬ利上げ: x↓, π↓, i↑）" begin
        irf = impulse_response(m, 1.0; shock = :monetary, T = 20)
        # 予期せぬ利上げ → 産出ギャップ低下・インフレ低下・名目利子率上昇
        @test irf.x[1] < 0
        @test irf.π[1] < 0
        @test irf.i[1] > 0
    end

    @testset "impulse_response: shock_size スケーリング" begin
        irf1 = impulse_response(m, 1.0; shock = :demand, T = 5)
        irf2 = impulse_response(m, 2.0; shock = :demand, T = 5)
        @test irf2.x ≈ 2.0 .* irf1.x atol = 1e-12
        @test irf2.π ≈ 2.0 .* irf1.π atol = 1e-12
        @test irf2.i ≈ 2.0 .* irf1.i atol = 1e-12
    end

    @testset "impulse_response: 不明なショックでエラー" begin
        @test_throws ArgumentError impulse_response(m, 1.0; shock = :unknown)
    end

    @testset "impulse_response: to_simulation_result で変換可能" begin
        irf = impulse_response(m, 1.0; shock = :demand, T = 20)
        sr = to_simulation_result(m, irf, "irf_demand")
        @test sr.model_name == "New Keynesian Model"
        @test sr.scenario_name == "irf_demand"
        @test haskey(sr, "x")
        @test haskey(sr, "π")
        @test haskey(sr, "i")
        @test nperiods(sr) == 20
    end

    @testset "Taylor ruleパラメータ変更の効果（コストプッシュショック）" begin
        # タカ派（高い φ_π）はコストプッシュショックのインフレ影響を小さくする
        m_hawkish = NewKeynesianModel(1.0, 0.02, 0.99, 0.1, 2.0, 0.5, 0.02, 0.8, 0.5, 0.5)
        m_dovish  = NewKeynesianModel(1.0, 0.02, 0.99, 0.1, 1.5, 0.5, 0.02, 0.8, 0.5, 0.5)
        irf_hawk = impulse_response(m_hawkish, 1.0; shock = :cost_push, T = 20)
        irf_dove = impulse_response(m_dovish,  1.0; shock = :cost_push, T = 20)
        # より積極的なインフレ反応 → インフレ影響が小さい
        @test abs(irf_hawk.π[1]) < abs(irf_dove.π[1])
        # 一方で産出ギャップの犠牲は大きくなる（より深い景気後退）
        @test abs(irf_hawk.x[1]) > abs(irf_dove.x[1])
    end

    @testset "nk_irf_compare" begin
        m_hawk = NewKeynesianModel(1.0, 0.02, 0.99, 0.1, 2.0, 0.5, 0.02, 0.8, 0.5, 0.5)
        result = DME.nk_irf_compare(m, m_hawk;
            shock = :cost_push,
            scenario_names = ("dovish", "hawkish"),
        )
        @test result.model_name == "New Keynesian Model"
        @test result.scenario_name == "irf_comparison"
        @test haskey(result, "x_base")
        @test haskey(result, "π_base")
        @test haskey(result, "i_base")
        @test haskey(result, "x_alt")
        @test haskey(result, "π_alt")
        @test haskey(result, "i_alt")
        @test nperiods(result) == 20
        @test result.metadata["scenario_names"] == ["dovish", "hawkish"]
        @test result.metadata["shock"] == "cost_push"
    end
end
