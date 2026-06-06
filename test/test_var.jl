@testset "VARModel" begin
    # 2変数 VAR(1): y (GDP) と π (インフレ)
    # y_t = 0.5 + 0.8*y_{t-1} + 0.1*π_{t-1}
    # π_t = 0.3 + 0.2*y_{t-1} + 0.7*π_{t-1}
    # 固有値 ≈ 0.9, 0.6 → 定常
    # 定常状態: y*=4.5, π*=4.0 (解析値)
    var_names = [:y, :π]
    A = [0.8 0.1; 0.2 0.7]
    c = [0.5, 0.3]
    m = VARModel(var_names, A, c)

    @testset "コンストラクタ: 正常系" begin
        @test m isa VARModel
        @test m.var_names == [:y, :π]
        @test m.A == A
        @test m.c == c
    end

    @testset "コンストラクタ: 異常系" begin
        # A のサイズ不一致
        @test_throws ArgumentError VARModel([:y, :π], [1.0 0.0 0.0; 0.0 1.0 0.0], [0.0, 0.0])
        # c の長さ不一致
        @test_throws ArgumentError VARModel([:y, :π], [0.8 0.1; 0.2 0.7], [0.5])
    end

    @testset "モデルメタ情報" begin
        @test model_name(m) == "VAR Model"
        @test state_variables(m) == [:y, :π]
        @test control_variables(m) == Symbol[]
        p = parameters(m)
        @test p.A == A
        @test p.c == c
    end

    @testset "steady_state" begin
        ss = steady_state(m)
        @test ss.y  ≈ 4.5 atol = 1e-10
        @test ss.π  ≈ 4.0 atol = 1e-10
        # 固定点の確認: c + A * y* ≈ y*
        y_ss = [ss.y, ss.π]
        @test c + A * y_ss ≈ y_ss atol = 1e-10
    end

    @testset "simulate: 長さと構造" begin
        y0 = [1.0, 0.5]
        result = simulate(m, y0; T = 10)
        @test length(result.y) == 11  # T+1 (初期値込み)
        @test length(result.π) == 11
        # 初期値が先頭に入っている
        @test result.y[1] ≈ y0[1] atol = 1e-12
        @test result.π[1] ≈ y0[2] atol = 1e-12
    end

    @testset "simulate: 遷移方程式の確認" begin
        y0 = [2.0, 1.0]
        result = simulate(m, y0; T = 5)
        for t in 1:5
            y_t   = result.y[t]
            π_t   = result.π[t]
            y_t1  = c[1] + A[1, 1] * y_t + A[1, 2] * π_t
            π_t1  = c[2] + A[2, 1] * y_t + A[2, 2] * π_t
            @test result.y[t + 1] ≈ y_t1 atol = 1e-12
            @test result.π[t + 1] ≈ π_t1 atol = 1e-12
        end
    end

    @testset "simulate: 定常状態からは動かない" begin
        ss = steady_state(m)
        y0 = [ss.y, ss.π]
        result = simulate(m, y0; T = 20)
        for t in 1:21
            @test result.y[t] ≈ ss.y atol = 1e-10
            @test result.π[t] ≈ ss.π atol = 1e-10
        end
    end

    @testset "simulate: 定常状態への収束" begin
        ss = steady_state(m)
        y0 = [0.0, 0.0]
        result = simulate(m, y0; T = 150)
        @test abs(result.y[end] - ss.y) < abs(result.y[1] - ss.y)
        # dominant eigenvalue ≈ 0.9 → 0.9^150 ≈ 1.3e-7 → diff << 1e-5
        @test result.y[end] ≈ ss.y atol = 1e-5
        @test result.π[end] ≈ ss.π atol = 1e-5
    end

    @testset "simulate: 引数バリデーション" begin
        @test_throws ArgumentError simulate(m, [1.0]; T = 10)
        @test_throws ArgumentError simulate(m, [1.0, 0.0, 0.5]; T = 10)
    end

    @testset "impulse_response: 長さと構造" begin
        shock = [1.0, 0.0]
        irf = impulse_response(m, shock; T = 20)
        @test length(irf.y) == 20
        @test length(irf.π) == 20
    end

    @testset "impulse_response: t=1 の応答がショックと一致" begin
        shock = [1.0, 0.0]
        irf = impulse_response(m, shock; T = 10)
        @test irf.y[1] ≈ shock[1] atol = 1e-12
        @test irf.π[1] ≈ shock[2] atol = 1e-12
    end

    @testset "impulse_response: t=2 の応答が A*shock と一致" begin
        shock = [1.0, 0.0]
        irf = impulse_response(m, shock; T = 10)
        expected_t2 = A * shock
        @test irf.y[2] ≈ expected_t2[1] atol = 1e-12
        @test irf.π[2] ≈ expected_t2[2] atol = 1e-12
    end

    @testset "impulse_response: shock_size によるスケーリング" begin
        irf1 = impulse_response(m, [1.0, 0.0]; T = 10)
        irf2 = impulse_response(m, [2.0, 0.0]; T = 10)
        @test irf2.y ≈ 2.0 .* irf1.y atol = 1e-12
        @test irf2.π ≈ 2.0 .* irf1.π atol = 1e-12
    end

    @testset "impulse_response: 定常 VAR では 0 に収束" begin
        # dominant eigenvalue ≈ 0.9 → 0.9^149 ≈ 1.3e-7 << 1e-5
        irf = impulse_response(m, [1.0, 0.0]; T = 150)
        @test abs(irf.y[150]) < 1e-5
        @test abs(irf.π[150]) < 1e-5
    end

    @testset "impulse_response: y ショックで π にも波及" begin
        irf = impulse_response(m, [1.0, 0.0]; T = 10)
        # y ショックが A[2,1] > 0 を通じて π に正の影響
        @test irf.π[2] > 0
    end

    @testset "impulse_response: 引数バリデーション" begin
        @test_throws ArgumentError impulse_response(m, [1.0]; T = 10)
        @test_throws ArgumentError impulse_response(m, [1.0, 0.0, 0.5]; T = 10)
    end

    @testset "to_simulation_result: simulate" begin
        y0 = [1.0, 0.5]
        sim = simulate(m, y0; T = 10)
        sr = to_simulation_result(m, sim, "simulate")
        @test sr.model_name == "VAR Model"
        @test sr.scenario_name == "simulate"
        @test haskey(sr, "y")
        @test haskey(sr, "π")
        @test nperiods(sr) == 11
        @test "parameters" in keys(sr.metadata)
    end

    @testset "to_simulation_result: impulse_response" begin
        irf = impulse_response(m, [1.0, 0.0]; T = 20)
        sr = to_simulation_result(m, irf, "irf_y_shock")
        @test sr.model_name == "VAR Model"
        @test sr.scenario_name == "irf_y_shock"
        @test haskey(sr, "y")
        @test haskey(sr, "π")
        @test nperiods(sr) == 20
    end

    @testset "plot_result（smoke test）" begin
        y0 = [1.0, 0.5]
        sim = simulate(m, y0; T = 10)
        sr = to_simulation_result(m, sim, "simulate")
        p = plot_result(sr)
        @test p isa Plots.Plot
        p2 = plot_result(sr; vars = "y")
        @test p2 isa Plots.Plot
    end

    @testset "plot_irf（smoke test）" begin
        irf = impulse_response(m, [1.0, 0.0]; T = 20)
        sr = to_simulation_result(m, irf, "irf_y_shock")
        p = plot_irf(sr)
        @test p isa Plots.Plot
        p2 = plot_irf(sr; vars = ["y", "π"])
        @test p2 isa Plots.Plot
    end

    @testset "1変数 VAR（scalar 相当）" begin
        m1 = VARModel([:x], reshape([0.8], 1, 1), [0.2])
        ss = steady_state(m1)
        @test ss.x ≈ 1.0 atol = 1e-10  # 0.2 / (1 - 0.8) = 1.0
        irf = impulse_response(m1, [1.0]; T = 5)
        @test irf.x[1] ≈ 1.0 atol = 1e-12
        @test irf.x[2] ≈ 0.8 atol = 1e-12
        @test irf.x[3] ≈ 0.64 atol = 1e-12
    end
end
