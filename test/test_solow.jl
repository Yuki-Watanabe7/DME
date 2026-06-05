@testset "SolowModel" begin
    # 標準的なパラメータ: α=0.3, s=0.2, δ=0.1, n=0.01, g=0.02
    m = SolowModel(0.3, 0.2, 0.1, 0.01, 0.02)

    @testset "model_name" begin
        @test model_name(m) == "Solow Model"
    end

    @testset "state_variables / control_variables / parameters" begin
        @test state_variables(m) == [:k]
        @test control_variables(m) == [:c]
        p = parameters(m)
        @test p.α == 0.3
        @test p.s == 0.2
        @test p.δ == 0.1
        @test p.n == 0.01
        @test p.g == 0.02
    end

    @testset "solow_ep（解析的定常状態）" begin
        k_star, y_star, c_star = DME.solow_ep(m)
        # k* = (s / (δ+n+g+n·g))^(1/(1-α))
        denom = 0.1 + 0.01 + 0.02 + 0.01 * 0.02
        expected_k = (0.2 / denom)^(1 / 0.7)
        @test k_star ≈ expected_k atol = 1e-10
        @test y_star ≈ expected_k^0.3 atol = 1e-10
        @test c_star ≈ (1 - 0.2) * expected_k^0.3 atol = 1e-10
        # 定常状態での資本蓄積方程式の確認
        # k* = (s*y* + (1-δ)*k*) / ((1+n)(1+g)) を満たすか
        k_next = DME.solow_next_k(m, k_star)
        @test k_next ≈ k_star atol = 1e-10
    end

    @testset "steady_state" begin
        ss = steady_state(m)
        @test haskey(NamedTuple(ss), :k)
        @test haskey(NamedTuple(ss), :y)
        @test haskey(NamedTuple(ss), :c)
        @test ss.k > 0
        @test ss.y > 0
        @test ss.c > 0
        # c = (1-s)*y
        @test ss.c ≈ (1 - m.s) * ss.y atol = 1e-10
    end

    @testset "transition_path（収束確認）" begin
        ss = steady_state(m)
        k0 = ss.k / 2  # 定常状態の半分から開始
        result = transition_path(m, k0; T = 200)
        @test length(result.k) == 200
        @test length(result.y) == 200
        @test length(result.c) == 200
        @test length(result.inv) == 200
        # 初期値
        @test result.k[1] ≈ k0 atol = 1e-12
        # 200期後には定常状態に収束していること
        @test result.k[end] ≈ ss.k atol = 1e-4
        @test result.y[end] ≈ ss.y atol = 1e-4
        @test result.c[end] ≈ ss.c atol = 1e-4
        # 単調増加（初期値 < 定常状態の場合）
        @test all(diff(result.k) .>= 0)
    end

    @testset "simulate（transition_pathと同一）" begin
        k0 = 1.0
        r1 = transition_path(m, k0; T = 50)
        r2 = simulate(m, k0; T = 50)
        @test r1.k == r2.k
        @test r1.y == r2.y
        @test r1.c == r2.c
    end

    @testset "to_simulation_result" begin
        ss = steady_state(m)
        k0 = ss.k / 2
        path = transition_path(m, k0; T = 50)
        sr = to_simulation_result(m, path, "transition_path")
        @test sr.model_name == "Solow Model"
        @test sr.scenario_name == "transition_path"
        @test haskey(sr, "k")
        @test haskey(sr, "y")
        @test haskey(sr, "c")
        @test nperiods(sr) == 50
        @test "parameters" in keys(sr.metadata)
    end
end
