@testset "MundellFlemingModel" begin
    # 標準パラメータ（ISLMModelのパラメータを継承し、開放経済パラメータを追加）
    # c0=100, c1=0.8, I0=200, b=50, G=100, T=100, l1=0.2, l2=100, M=1000, P=1.0
    # r_star=0.02, nx0=50, nx1=10
    m = MundellFlemingModel(
        100.0,
        0.8,
        200.0,
        50.0,
        100.0,
        100.0,
        0.2,
        100.0,
        1000.0,
        1.0,
        0.02,
        50.0,
        10.0,
    )

    @testset "model_name" begin
        @test model_name(m) == "Mundell-Fleming Model"
    end

    @testset "state_variables / control_variables / parameters" begin
        @test state_variables(m) == Symbol[]
        @test control_variables(m) == [:Y, :r, :e, :NX]
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
        @test p.r_star == 0.02
        @test p.nx0 == 50.0
        @test p.nx1 == 10.0
    end

    @testset "mf_equilibrium（解析的均衡）" begin
        Y, r, e, NX, C, I = DME.mf_equilibrium(m)

        # UIP条件: r = r*
        @test r ≈ m.r_star atol = 1e-12

        # LM均衡: M/P = l1*Y - l2*r
        @test m.M / m.P ≈ m.l1 * Y - m.l2 * r atol = 1e-10

        # 消費関数: C = c0 + c1*(Y-T)
        @test C ≈ m.c0 + m.c1 * (Y - m.T) atol = 1e-10

        # 投資関数: I = I0 - b*r
        @test I ≈ m.I0 - m.b * r atol = 1e-10

        # NX関数: NX = nx0 + nx1*e
        @test NX ≈ m.nx0 + m.nx1 * e atol = 1e-10

        # 財市場の均衡（国民所得恒等式）: Y = C + I + G + NX
        @test Y ≈ C + I + m.G + NX atol = 1e-10

        # 合理的な値域
        @test Y > 0
        @test C > 0
        @test I > 0
    end

    @testset "mf_equilibrium（数値アンカー）" begin
        # 実装と独立に計算した数値アンカー
        Y, r, e, NX, C, I = DME.mf_equilibrium(m)
        @test Y ≈ 5010.0 atol = 1e-8
        @test r ≈ 0.02 atol = 1e-12
        @test e ≈ 63.3 atol = 1e-8
        @test NX ≈ 683.0 atol = 1e-8
        @test C ≈ 4028.0 atol = 1e-8
        @test I ≈ 199.0 atol = 1e-8
    end

    @testset "政策乗数が閉形式と一致する" begin
        # LM から Y = (M/P + l2·r*)/l1 なので:
        #   dY/dM = 1/(l1·P), dY/dr* = l2/l1
        # 国民所得恒等式 NX = Y-C-I-G, C=c0+c1(Y-T) より
        #   dNX/dM = (1-c1)·dY/dM, de/dM = dNX/dM / nx1
        ss = steady_state(m)
        m_m = MundellFlemingModel(
            100.0,
            0.8,
            200.0,
            50.0,
            100.0,
            100.0,
            0.2,
            100.0,
            1200.0,
            1.0,
            0.02,
            50.0,
            10.0,
        )
        ss_m = steady_state(m_m)
        ΔM = m_m.M - m.M
        dY = ΔM / (m.l1 * m.P)
        @test ss_m.Y - ss.Y ≈ dY atol = 1e-8
        @test ss_m.NX - ss.NX ≈ (1 - m.c1) * dY atol = 1e-8
        @test ss_m.e - ss.e ≈ (1 - m.c1) * dY / m.nx1 atol = 1e-8

        m_r = MundellFlemingModel(
            100.0,
            0.8,
            200.0,
            50.0,
            100.0,
            100.0,
            0.2,
            100.0,
            1000.0,
            1.0,
            0.04,
            50.0,
            10.0,
        )
        ss_r = steady_state(m_r)
        Δrstar = m_r.r_star - m.r_star
        @test ss_r.Y - ss.Y ≈ Δrstar * m.l2 / m.l1 atol = 1e-8
    end

    @testset "steady_state" begin
        ss = steady_state(m)
        @test haskey(NamedTuple(ss), :Y)
        @test haskey(NamedTuple(ss), :r)
        @test haskey(NamedTuple(ss), :e)
        @test haskey(NamedTuple(ss), :NX)
        @test haskey(NamedTuple(ss), :C)
        @test haskey(NamedTuple(ss), :I)
        # mf_equilibrium と一致
        Y, r, e, NX, C, I = DME.mf_equilibrium(m)
        @test ss.Y ≈ Y atol = 1e-12
        @test ss.r ≈ r atol = 1e-12
        @test ss.e ≈ e atol = 1e-12
        @test ss.NX ≈ NX atol = 1e-12
        @test ss.C ≈ C atol = 1e-12
        @test ss.I ≈ I atol = 1e-12
    end

    @testset "simulate（長さ1ベクトル）" begin
        result = simulate(m)
        @test length(result.Y) == 1
        @test length(result.r) == 1
        @test length(result.e) == 1
        @test length(result.NX) == 1
        @test length(result.C) == 1
        @test length(result.I) == 1
        ss = steady_state(m)
        @test result.Y[1] ≈ ss.Y atol = 1e-12
        @test result.r[1] ≈ ss.r atol = 1e-12
        @test result.e[1] ≈ ss.e atol = 1e-12
        @test result.NX[1] ≈ ss.NX atol = 1e-12
    end

    @testset "to_simulation_result" begin
        sim = simulate(m)
        sr = to_simulation_result(m, sim, "equilibrium")
        @test sr.model_name == "Mundell-Fleming Model"
        @test sr.scenario_name == "equilibrium"
        @test haskey(sr, "Y")
        @test haskey(sr, "r")
        @test haskey(sr, "e")
        @test haskey(sr, "NX")
        @test haskey(sr, "C")
        @test haskey(sr, "I")
        @test nperiods(sr) == 1
        @test "parameters" in keys(sr.metadata)
    end

    @testset "財政政策（変動相場制でのクラウドアウト）" begin
        # G を100から150に増加 → 変動相場制では Y 不変、e 増価（自国通貨高）、NX 減少
        m_fiscal = MundellFlemingModel(
            100.0,
            0.8,
            200.0,
            50.0,
            150.0,
            100.0,
            0.2,
            100.0,
            1000.0,
            1.0,
            0.02,
            50.0,
            10.0,
        )
        ss_base = steady_state(m)
        ss_fiscal = steady_state(m_fiscal)

        # Mundell-Fleming定理: 変動相場制では財政政策無効（Y 不変）
        @test ss_fiscal.Y ≈ ss_base.Y atol = 1e-10

        # 金利は r* に固定
        @test ss_fiscal.r ≈ ss_base.r atol = 1e-12

        # e が減少（自国通貨高）し、NX が減少（クラウドアウト）
        @test ss_fiscal.e < ss_base.e
        @test ss_fiscal.NX < ss_base.NX

        # クラウドアウトの量: ΔNX = -ΔG
        ΔG = 150.0 - 100.0
        ΔNX = ss_fiscal.NX - ss_base.NX
        @test ΔNX ≈ -ΔG atol = 1e-10
    end

    @testset "金融政策（マネーサプライ増加→Y増加・e減価）" begin
        # M を1000から1200に増加 → Y 増加、e 減価（自国通貨安）、NX 改善
        m_monetary = MundellFlemingModel(
            100.0,
            0.8,
            200.0,
            50.0,
            100.0,
            100.0,
            0.2,
            100.0,
            1200.0,
            1.0,
            0.02,
            50.0,
            10.0,
        )
        ss_base = steady_state(m)
        ss_monetary = steady_state(m_monetary)

        @test ss_monetary.Y > ss_base.Y
        @test ss_monetary.e > ss_base.e   # e 増加 = 自国通貨安
        @test ss_monetary.NX > ss_base.NX  # NX 改善

        # 金利は r* に固定
        @test ss_monetary.r ≈ ss_base.r atol = 1e-12
    end

    @testset "海外金利ショック（r* 上昇→Y増加・e変化）" begin
        # r_star を0.02から0.04に上昇
        m_rstar = MundellFlemingModel(
            100.0,
            0.8,
            200.0,
            50.0,
            100.0,
            100.0,
            0.2,
            100.0,
            1000.0,
            1.0,
            0.04,
            50.0,
            10.0,
        )
        ss_base = steady_state(m)
        ss_rstar = steady_state(m_rstar)

        # LM: Y = (M/P + l2*r*)/l1 より r* 上昇 → Y 増加
        @test ss_rstar.Y > ss_base.Y
        @test ss_rstar.r > ss_base.r
    end

    @testset "外需ショック（nx0 低下→NX減少・e減価）" begin
        # nx0 を50から30に低下（貿易相手国の景気後退）
        m_demand = MundellFlemingModel(
            100.0,
            0.8,
            200.0,
            50.0,
            100.0,
            100.0,
            0.2,
            100.0,
            1000.0,
            1.0,
            0.02,
            30.0,
            10.0,
        )
        ss_base = steady_state(m)
        ss_demand = steady_state(m_demand)

        # Y は LM で決まるため変化なし
        @test ss_demand.Y ≈ ss_base.Y atol = 1e-10

        # NX = Y - C - I - G も変化なし（完全な為替調整が起きる）
        @test ss_demand.NX ≈ ss_base.NX atol = 1e-10

        # e は減価（e 増加）して nx0 の低下を完全に吸収する
        @test ss_demand.e > ss_base.e
    end

    @testset "mf_policy_shock" begin
        m_monetary = MundellFlemingModel(
            100.0,
            0.8,
            200.0,
            50.0,
            100.0,
            100.0,
            0.2,
            100.0,
            1200.0,
            1.0,
            0.02,
            50.0,
            10.0,
        )
        result = DME.mf_policy_shock(
            m,
            m_monetary;
            scenario_names = ("baseline", "monetary_easing"),
        )

        @test result.model_name == "Mundell-Fleming Model"
        @test result.scenario_name == "policy_comparison"
        @test haskey(result, "Y")
        @test haskey(result, "r")
        @test haskey(result, "e")
        @test haskey(result, "NX")
        @test haskey(result, "C")
        @test haskey(result, "I")
        @test nperiods(result) == 2
        @test "scenario_names" in keys(result.metadata)
        @test result.metadata["scenario_names"] == ["baseline", "monetary_easing"]

        # インデックス1がベースライン、2が政策後
        ss_base = steady_state(m)
        ss_monetary = steady_state(m_monetary)
        @test result["Y"][1] ≈ ss_base.Y atol = 1e-12
        @test result["Y"][2] ≈ ss_monetary.Y atol = 1e-12
        @test result["e"][1] ≈ ss_base.e atol = 1e-12
        @test result["e"][2] ≈ ss_monetary.e atol = 1e-12
    end
end
