@testset "ISLMModel" begin
    # 標準的なパラメータ
    # c0=100, c1=0.8, I0=200, b=50, G=100, T=100, l1=0.2, l2=100, M=1000, P=1.0
    m = ISLMModel(100.0, 0.8, 200.0, 50.0, 100.0, 100.0, 0.2, 100.0, 1000.0, 1.0)

    @testset "model_name" begin
        @test model_name(m) == "IS-LM Model"
    end

    @testset "state_variables / control_variables / parameters" begin
        @test state_variables(m) == Symbol[]
        @test control_variables(m) == [:Y, :r]
        p = parameters(m)
        @test p.c0 == 100.0
        @test p.c1 == 0.8
        @test p.I0 == 200.0
        @test p.b == 50.0
        @test p.G == 100.0
        @test p.T == 100.0
        @test p.l1 == 0.2
        @test p.l2 == 100.0
        @test p.M == 1000.0
        @test p.P == 1.0
    end

    @testset "islm_equilibrium（解析的均衡）" begin
        Y, r, C, I = DME.islm_equilibrium(m)
        # 財市場の均衡: Y = C + I + G
        @test Y ≈ C + I + m.G atol = 1e-10
        # 貨幣市場の均衡: M/P = l1*Y - l2*r
        @test m.M / m.P ≈ m.l1 * Y - m.l2 * r atol = 1e-10
        # 消費関数: C = c0 + c1*(Y-T)
        @test C ≈ m.c0 + m.c1 * (Y - m.T) atol = 1e-10
        # 投資関数: I = I0 - b*r
        @test I ≈ m.I0 - m.b * r atol = 1e-10
        # 合理的な値域
        @test Y > 0
        @test C > 0
        @test I > 0
    end

    @testset "steady_state" begin
        ss = steady_state(m)
        @test haskey(NamedTuple(ss), :Y)
        @test haskey(NamedTuple(ss), :r)
        @test haskey(NamedTuple(ss), :C)
        @test haskey(NamedTuple(ss), :I)
        # islm_equilibrium と一致
        Y, r, C, I = DME.islm_equilibrium(m)
        @test ss.Y ≈ Y atol = 1e-12
        @test ss.r ≈ r atol = 1e-12
        @test ss.C ≈ C atol = 1e-12
        @test ss.I ≈ I atol = 1e-12
    end

    @testset "simulate（長さ1ベクトル）" begin
        result = simulate(m)
        @test length(result.Y) == 1
        @test length(result.r) == 1
        @test length(result.C) == 1
        @test length(result.I) == 1
        ss = steady_state(m)
        @test result.Y[1] ≈ ss.Y atol = 1e-12
        @test result.r[1] ≈ ss.r atol = 1e-12
    end

    @testset "to_simulation_result" begin
        sim = simulate(m)
        sr = to_simulation_result(m, sim, "equilibrium")
        @test sr.model_name == "IS-LM Model"
        @test sr.scenario_name == "equilibrium"
        @test haskey(sr, "Y")
        @test haskey(sr, "r")
        @test haskey(sr, "C")
        @test haskey(sr, "I")
        @test nperiods(sr) == 1
        @test "parameters" in keys(sr.metadata)
    end

    @testset "財政政策の効果（政府支出増加→Yが増加）" begin
        # G を100から150に増加
        m_fiscal = ISLMModel(100.0, 0.8, 200.0, 50.0, 150.0, 100.0, 0.2, 100.0, 1000.0, 1.0)
        ss_base = steady_state(m)
        ss_fiscal = steady_state(m_fiscal)
        # クラウディングアウトがあってもYは増加するはず
        @test ss_fiscal.Y > ss_base.Y
        # 利子率も上昇（LM曲線上で右上方向へ移動）
        @test ss_fiscal.r > ss_base.r
    end

    @testset "金融政策の効果（マネーサプライ増加→Yが増加、rが低下）" begin
        # M を1000から1200に増加
        m_monetary = ISLMModel(100.0, 0.8, 200.0, 50.0, 100.0, 100.0, 0.2, 100.0, 1200.0, 1.0)
        ss_base = steady_state(m)
        ss_monetary = steady_state(m_monetary)
        @test ss_monetary.Y > ss_base.Y
        @test ss_monetary.r < ss_base.r
    end

    @testset "islm_policy_shock" begin
        m_fiscal = ISLMModel(100.0, 0.8, 200.0, 50.0, 150.0, 100.0, 0.2, 100.0, 1000.0, 1.0)
        result = DME.islm_policy_shock(m, m_fiscal; scenario_names = ("baseline", "fiscal_expansion"))
        @test result.model_name == "IS-LM Model"
        @test result.scenario_name == "policy_comparison"
        @test haskey(result, "Y")
        @test haskey(result, "r")
        @test haskey(result, "C")
        @test haskey(result, "I")
        @test nperiods(result) == 2
        @test "scenario_names" in keys(result.metadata)
        @test result.metadata["scenario_names"] == ["baseline", "fiscal_expansion"]
        # インデックス1がベースライン、2が政策後
        ss_base = steady_state(m)
        ss_fiscal = steady_state(m_fiscal)
        @test result["Y"][1] ≈ ss_base.Y atol = 1e-12
        @test result["Y"][2] ≈ ss_fiscal.Y atol = 1e-12
    end
end
