@testset "ramsey" begin
    rams = RamseyModel(0.3, 0.99, 0.25)
    @testset "calc_ep" begin
        rtn = DME.calc_ep(rams)
        @test rtn[1] ≈ 1.226144733 atol = 1e-8
        @test rtn[2] ≈ 0.756535429 atol = 1e-8
    end
    @testset "calc_ep が定常条件を満たす" begin
        α, β, δ = rams.α, rams.β, rams.δ
        K, C = DME.calc_ep(rams)
        # 修正黄金律（Euler 方程式の定常形）: β(αK*^(α-1) + 1 - δ) = 1
        @test β * (α * K^(α - 1) + 1 - δ) ≈ 1.0 atol = 1e-12
        # 資源制約: C* = K*^α - δK*
        @test C ≈ K^α - δ * K atol = 1e-12
    end
    @testset "find_path" begin
        ep = DME.calc_ep(rams)
        rtn = DME.find_path(rams, ep[1] / 2)
        @test rtn.K[1] == ep[1] / 2
        @test rtn.K[end] ≈ ep[1] atol = 1e-3
    end
    @testset "find_path が Euler 方程式と資源制約を満たす" begin
        α, β, δ = rams.α, rams.β, rams.δ
        ep = DME.calc_ep(rams)
        rtn = DME.find_path(rams, ep[1] / 2)
        for t in 1:(length(rtn.K) - 1)
            # Euler 方程式: C[t+1]/C[t] = β(αK[t+1]^(α-1) + 1 - δ)
            @test rtn.C[t + 1] / rtn.C[t] ≈ β * (α * rtn.K[t + 1]^(α - 1) + 1 - δ) atol =
                1e-6
            # 資源制約: K[t+1] = K[t]^α + (1-δ)K[t] - C[t]
            @test rtn.K[t + 1] ≈ rtn.K[t]^α + (1 - δ) * rtn.K[t] - rtn.C[t] atol = 1e-6
        end
    end
    @testset "find_path の鞍点経路は単調収束する" begin
        ep = DME.calc_ep(rams)
        # K0 < K*: 資本・消費とも単調増加で定常状態へ収束
        below = DME.find_path(rams, ep[1] / 2)
        @test all(diff(below.K) .> 0)
        @test all(diff(below.C) .> 0)
        # K0 > K*: 資本・消費とも単調減少で定常状態へ収束
        above = DME.find_path(rams, ep[1] * 1.5)
        @test all(diff(above.K) .< 0)
        @test all(diff(above.C) .< 0)
        @test above.K[end] ≈ ep[1] atol = 1e-3
    end
    @testset "find_path が閉形式解と一致する（Brock–Mirman: δ=1・対数効用）" begin
        # δ=1・対数効用では C = (1-αβ)K^α, K[t+1] = αβK[t]^α が厳密解
        α, β = 0.3, 0.99
        bm = RamseyModel(α, β, 1.0)
        Kstar = (α * β)^(1 / (1 - α))
        @test DME.calc_ep(bm)[1] ≈ Kstar atol = 1e-12
        rtn = DME.find_path(bm, Kstar / 2)
        for t in 1:(length(rtn.K) - 1)
            @test rtn.K[t + 1] ≈ α * β * rtn.K[t]^α atol = 1e-8
            @test rtn.C[t] ≈ (1 - α * β) * rtn.K[t]^α atol = 1e-8
        end
    end
    @testset "optimize_c" begin
        rams2 = RamseyModel(0.3, 1.0, 0.5)
        f = x -> -45 + sqrt(x)
        @test DME.optimize_c(rams2, 1.0, f, 0.001, 3.0, 0.001) ≈ sqrt(10) - 2 atol = 1e-7
    end
    @testset "V" begin
        @test DME.V(rams, 1.0, x -> x / 2) ≈ -28.974313466813 atol = 1e-8
    end
    @testset "update_value" begin
        node = DME.ChebNode(20, 0.5, 3.0)
        vf = DME.update_value(rams, node, x -> x / 2, DME.ITPCheb)
        # Chebyshev 補間値が直接計算した V と一致する（実測誤差 ~5e-9）
        @test vf(1.0) ≈ -28.974313466813 atol = 1e-6
    end
    @testset "simulate_by_nlvar" begin
        ep = DME.calc_ep(rams)
        K0 = ep[1] / 2
        rtn = DME.simulate_by_nlvar(rams, K0)
        @test rtn.K[end] ≈ ep[1] atol = 1e-2
        @test rtn.C[end] ≈ ep[2] atol = 1e-2
        # 定常状態への単調収束（K0 < K*）
        @test all(diff(rtn.K) .> 0)
        # クロス検証: 価値反復法の経路が NLsolve 完全予見経路と一致する（実測誤差 ~1e-3）
        ref = DME.find_path(rams, K0)
        n = length(rtn.K)
        @test maximum(abs.(rtn.K .- ref.K[1:n])) < 5e-3
        @test maximum(abs.(rtn.C .- ref.C[1:n])) < 5e-3
    end
end

@testset "カスタム設定でのシミュレーション（Ramsey）" begin
    rams = RamseyModel(0.3, 0.99, 0.25)

    @testset "find_path（Ramsey）カスタム maxT" begin
        ep = DME.calc_ep(rams)
        rtn = DME.find_path(rams, ep[1] / 2; maxT = 15)
        @test length(rtn.K) == 16   # maxT + 1
        @test length(rtn.C) == 16
    end

    @testset "solve_by_nlvar カスタム opts" begin
        ep = DME.calc_ep(rams)
        opts = ValueIterationOptions(n = 10, a = 0.5, b = 3.0, max_iter = 50)
        hc = DME.solve_by_nlvar(rams; opts = opts)
        @test hc(ep[1]) > 0
    end

    @testset "solve_by_nlvar デフォルトでログファイル未生成" begin
        log_files_before = filter(f -> endswith(f, ".log"), readdir("."))
        opts = ValueIterationOptions(n = 10, a = 0.5, b = 3.0, max_iter = 50)
        DME.solve_by_nlvar(rams; opts = opts)
        log_files_after = filter(f -> endswith(f, ".log"), readdir("."))
        @test log_files_before == log_files_after
    end

    @testset "solve_by_nlvar log_path 指定でファイル生成" begin
        opts = ValueIterationOptions(n = 10, a = 0.5, b = 3.0, max_iter = 50)
        log_file = tempname() * ".log"
        DME.solve_by_nlvar(rams; opts = opts, log_path = log_file)
        @test isfile(log_file)
        rm(log_file)
    end
end
