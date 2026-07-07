@testset "ADASModel" begin
    # 標準的なパラメータ
    # c0=100, c1=0.8, I0=200, b=50, G=100, T=100
    # l1=0.2, l2=100, M=300
    # Y_n=1500, v=500, P_e=1.0
    m = ADASModel(
        100.0,
        0.8,
        200.0,
        50.0,
        100.0,
        100.0,
        0.2,
        100.0,
        300.0,
        1500.0,
        500.0,
        1.0,
    )

    @testset "model_name" begin
        @test model_name(m) == "AD-AS Model"
    end

    @testset "state_variables / control_variables / parameters" begin
        @test state_variables(m) == Symbol[]
        @test control_variables(m) == [:Y, :P]
        p = parameters(m)
        @test p.c0 == 100.0
        @test p.c1 == 0.8
        @test p.I0 == 200.0
        @test p.b == 50.0
        @test p.G == 100.0
        @test p.T == 100.0
        @test p.l1 == 0.2
        @test p.l2 == 100.0
        @test p.M == 300.0
        @test p.Y_n == 1500.0
        @test p.v == 500.0
        @test p.P_e == 1.0
    end

    @testset "adas_equilibrium（均衡条件の確認）" begin
        Y, P, r, C, I = DME.adas_equilibrium(m)
        A = m.c0 + m.I0 + m.G - m.c1 * m.T
        D = m.b * m.l1 + m.l2 * (1 - m.c1)
        # AD曲線: Y = (l2*A + b*M/P) / D
        @test Y ≈ (m.l2 * A + m.b * m.M / P) / D atol = 1e-8
        # SRAS曲線: Y = Y_n + v*(P - P_e)
        @test Y ≈ m.Y_n + m.v * (P - m.P_e) atol = 1e-8
        # LM均衡: M/P = l1*Y - l2*r
        @test m.M / P ≈ m.l1 * Y - m.l2 * r atol = 1e-8
        # 消費関数: C = c0 + c1*(Y-T)
        @test C ≈ m.c0 + m.c1 * (Y - m.T) atol = 1e-8
        # 投資関数: I = I0 - b*r
        @test I ≈ m.I0 - m.b * r atol = 1e-8
        # 合理的な値域
        @test Y > 0
        @test P > 0
        @test C > 0
        @test I > 0
    end

    @testset "adas_equilibrium（数値アンカー）" begin
        # 実装と独立に計算した数値アンカー
        Y, P, r, C, I = DME.adas_equilibrium(m)
        @test Y ≈ 1534.4432126124 atol = 1e-8
        @test P ≈ 1.0688864252 atol = 1e-8
        @test r ≈ 0.2622271496 atol = 1e-8
        @test C ≈ 1247.5545700899 atol = 1e-8
        @test I ≈ 186.8886425225 atol = 1e-8
    end

    @testset "AD-AS と IS-LM のクロス検証（P を固定した場合の一致）" begin
        # AD-AS の均衡物価 P* で P を固定した ISLMModel は、AD-AS と
        # 同じ Y・r・C・I を返すはず（AD 曲線は IS-LM から導出されているため）
        Y, P, r, C, I = DME.adas_equilibrium(m)
        m_islm = ISLMModel(m.c0, m.c1, m.I0, m.b, m.G, m.T, m.l1, m.l2, m.M, P)
        Yi, ri, Ci, Ii = DME.islm_equilibrium(m_islm)
        @test Y ≈ Yi atol = 1e-8
        @test r ≈ ri atol = 1e-10
        @test C ≈ Ci atol = 1e-8
        @test I ≈ Ii atol = 1e-8
    end

    @testset "長期均衡: P_e が長期均衡物価なら Y*=Y_n" begin
        # P_e を長期均衡物価 P_LR に設定すると SRAS が Y_n で
        # 垂直な長期供給曲線と同じ点を通り、Y* = Y_n が成立する
        A = m.c0 + m.I0 + m.G - m.c1 * m.T
        D = m.b * m.l1 + m.l2 * (1 - m.c1)
        P_LR = m.b * m.M / (D * m.Y_n - m.l2 * A)
        m_lr = ADASModel(m.c0, m.c1, m.I0, m.b, m.G, m.T, m.l1, m.l2, m.M, m.Y_n, m.v, P_LR)
        Y_lr, P_lr, _, _, _ = DME.adas_equilibrium(m_lr)
        @test Y_lr ≈ m.Y_n atol = 1e-6
        @test P_lr ≈ P_LR atol = 1e-8
    end

    @testset "極限ケース: v→∞ で P→P_e、v→0 で Y→Y_n" begin
        # SRAS が垂直に近づく（v 大）と価格調整が支配的になり P → P_e
        m_v_big =
            ADASModel(m.c0, m.c1, m.I0, m.b, m.G, m.T, m.l1, m.l2, m.M, m.Y_n, 1e10, m.P_e)
        _, P_big, _, _, _ = DME.adas_equilibrium(m_v_big)
        @test P_big ≈ m.P_e atol = 1e-6

        # SRAS が水平に近づく（v 小）と数量調整が支配的になり Y → Y_n
        m_v_small =
            ADASModel(m.c0, m.c1, m.I0, m.b, m.G, m.T, m.l1, m.l2, m.M, m.Y_n, 1e-10, m.P_e)
        Y_small, _, _, _, _ = DME.adas_equilibrium(m_v_small)
        @test Y_small ≈ m.Y_n atol = 1e-6
    end

    @testset "steady_state" begin
        ss = steady_state(m)
        @test haskey(NamedTuple(ss), :Y)
        @test haskey(NamedTuple(ss), :P)
        @test haskey(NamedTuple(ss), :r)
        @test haskey(NamedTuple(ss), :C)
        @test haskey(NamedTuple(ss), :I)
        # adas_equilibrium と一致
        Y, P, r, C, I = DME.adas_equilibrium(m)
        @test ss.Y ≈ Y atol = 1e-12
        @test ss.P ≈ P atol = 1e-12
        @test ss.r ≈ r atol = 1e-12
        @test ss.C ≈ C atol = 1e-12
        @test ss.I ≈ I atol = 1e-12
    end

    @testset "simulate（長さ1ベクトル）" begin
        result = simulate(m)
        @test length(result.Y) == 1
        @test length(result.P) == 1
        @test length(result.r) == 1
        @test length(result.C) == 1
        @test length(result.I) == 1
        ss = steady_state(m)
        @test result.Y[1] ≈ ss.Y atol = 1e-12
        @test result.P[1] ≈ ss.P atol = 1e-12
    end

    @testset "to_simulation_result" begin
        sim = simulate(m)
        sr = to_simulation_result(m, sim, "equilibrium")
        @test sr.model_name == "AD-AS Model"
        @test sr.scenario_name == "equilibrium"
        @test haskey(sr, "Y")
        @test haskey(sr, "P")
        @test haskey(sr, "r")
        @test haskey(sr, "C")
        @test haskey(sr, "I")
        @test nperiods(sr) == 1
        @test "parameters" in keys(sr.metadata)
    end

    @testset "需要ショック（G増加→Y上昇・P上昇）" begin
        # G を100から150に増加（拡張的財政政策）
        m_demand = ADASModel(
            100.0,
            0.8,
            200.0,
            50.0,
            150.0,
            100.0,
            0.2,
            100.0,
            300.0,
            1500.0,
            500.0,
            1.0,
        )
        ss_base = steady_state(m)
        ss_demand = steady_state(m_demand)
        # 需要増加 → Y上昇・P上昇（AD曲線の右シフト）
        @test ss_demand.Y > ss_base.Y
        @test ss_demand.P > ss_base.P
    end

    @testset "需要ショック（M増加→Y上昇・P上昇）" begin
        # M を300から400に増加（金融緩和）
        m_monetary = ADASModel(
            100.0,
            0.8,
            200.0,
            50.0,
            100.0,
            100.0,
            0.2,
            100.0,
            400.0,
            1500.0,
            500.0,
            1.0,
        )
        ss_base = steady_state(m)
        ss_monetary = steady_state(m_monetary)
        @test ss_monetary.Y > ss_base.Y
        @test ss_monetary.P > ss_base.P
    end

    @testset "供給ショック（Y_n増加→Y上昇・P低下）" begin
        # Y_n を1500から1600に増加（技術改善などの正の供給ショック）
        m_supply = ADASModel(
            100.0,
            0.8,
            200.0,
            50.0,
            100.0,
            100.0,
            0.2,
            100.0,
            300.0,
            1600.0,
            500.0,
            1.0,
        )
        ss_base = steady_state(m)
        ss_supply = steady_state(m_supply)
        # SRAS右シフト → Y上昇・P低下
        @test ss_supply.Y > ss_base.Y
        @test ss_supply.P < ss_base.P
    end

    @testset "供給ショック（P_e上昇→Y低下・P上昇）" begin
        # P_e を1.0から1.1に上昇（インフレ期待の悪化）
        m_pe_shock = ADASModel(
            100.0,
            0.8,
            200.0,
            50.0,
            100.0,
            100.0,
            0.2,
            100.0,
            300.0,
            1500.0,
            500.0,
            1.1,
        )
        ss_base = steady_state(m)
        ss_pe_shock = steady_state(m_pe_shock)
        # SRAS上方シフト → Y低下・P上昇（スタグフレーション的）
        @test ss_pe_shock.Y < ss_base.Y
        @test ss_pe_shock.P > ss_base.P
    end

    @testset "adas_shock_compare" begin
        m_demand = ADASModel(
            100.0,
            0.8,
            200.0,
            50.0,
            150.0,
            100.0,
            0.2,
            100.0,
            300.0,
            1500.0,
            500.0,
            1.0,
        )
        result = DME.adas_shock_compare(
            m,
            m_demand;
            scenario_names = ("baseline", "demand_expansion"),
        )
        @test result.model_name == "AD-AS Model"
        @test result.scenario_name == "shock_comparison"
        @test haskey(result, "Y")
        @test haskey(result, "P")
        @test haskey(result, "r")
        @test haskey(result, "C")
        @test haskey(result, "I")
        @test nperiods(result) == 2
        @test "scenario_names" in keys(result.metadata)
        @test result.metadata["scenario_names"] == ["baseline", "demand_expansion"]
        # インデックス1がベースライン、2がショック後
        ss_base = steady_state(m)
        ss_demand = steady_state(m_demand)
        @test result["Y"][1] ≈ ss_base.Y atol = 1e-12
        @test result["Y"][2] ≈ ss_demand.Y atol = 1e-12
        @test result["P"][1] ≈ ss_base.P atol = 1e-12
        @test result["P"][2] ≈ ss_demand.P atol = 1e-12
    end
end
