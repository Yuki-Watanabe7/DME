using Plots

@testset "KeenModel" begin
    # Grasselli & Costa Lima (2012) の数値例
    m = KeenModel(0.025, 0.02, 0.01, 3.0, 0.03, 0.0400641, 6.41e-5, -0.0065, exp(-5), 20.0)

    @testset "モデルメタ情報" begin
        @test model_name(m) == "Keen Model"
        @test state_variables(m) == [:ω, :λ, :d]
        @test control_variables(m) == Symbol[]
        p = parameters(m)
        @test p.α == 0.025
        @test p.β == 0.02
        @test p.δ == 0.01
        @test p.ν == 3.0
        @test p.r == 0.03
        @test p.φ0 == 0.0400641
        @test p.φ1 == 6.41e-5
        @test p.κ0 == -0.0065
        @test p.κ1 == exp(-5)
        @test p.κ2 == 20.0
    end

    @testset "steady_state: 文献値一致" begin
        ss = steady_state(m)
        @test ss.ω ≈ 0.8361 atol = 1e-3
        @test ss.λ ≈ 0.9686 atol = 1e-3
        @test ss.d ≈ 0.0702 atol = 1e-3
        @test ss.π ≈ 0.1618 atol = 1e-3
        @test ss.g ≈ 0.045 atol = 1e-10
    end

    @testset "keen_rhs: 定常状態での残差 ≈ 0" begin
        ss = steady_state(m)
        dω, dλ, dd = DME.keen_rhs(m, ss.ω, ss.λ, ss.d)
        @test dω ≈ 0.0 atol = 1e-10
        @test dλ ≈ 0.0 atol = 1e-10
        @test dd ≈ 0.0 atol = 1e-10
    end

    @testset "keen_rhs: 非定常状態では残差が非ゼロ" begin
        ss = steady_state(m)
        dω, dλ, dd = DME.keen_rhs(m, ss.ω - 0.1, ss.λ - 0.1, ss.d + 0.5)
        @test abs(dω) > 1e-6
        @test abs(dλ) > 1e-6
        @test abs(dd) > 1e-6
    end

    @testset "simulate: 均衡での微小攪乱は均衡へ回帰" begin
        ss = steady_state(m)
        result = simulate(m, ss.ω, ss.λ, ss.d + 0.01; T = 300)
        @test length(result.ω) == 300
        @test length(result.λ) == 300
        @test length(result.d) == 300
        @test length(result.π) == 300
        @test length(result.g) == 300
        # 初期値が先頭に入っている
        @test result.ω[1] ≈ ss.ω atol = 1e-12
        @test result.λ[1] ≈ ss.λ atol = 1e-12
        @test result.d[1] ≈ ss.d + 0.01 atol = 1e-12
        # 終端値が均衡に回帰
        @test result.ω[end] ≈ ss.ω atol = 1e-3
        @test result.λ[end] ≈ ss.λ atol = 1e-3
        @test result.d[end] ≈ ss.d atol = 1e-3
        @test !any(isnan, result.ω)
        @test !any(isnan, result.d)
    end

    @testset "simulate: 高債務初期値からの崩壊経路" begin
        ss = steady_state(m)
        result = simulate(m, ss.ω, ss.λ, 5.0; T = 300)
        # 発散ガードが作動し NaN 埋めされる（例外を送出せず完走する）
        @test any(isnan, result.ω)
        @test any(isnan, result.λ)
        @test any(isnan, result.d)
        # 一度発散すると以降はすべて NaN のまま
        first_nan = findfirst(isnan, result.d)
        @test first_nan !== nothing
        @test all(isnan, result.ω[first_nan:end])
        @test all(isnan, result.λ[first_nan:end])
        @test all(isnan, result.d[first_nan:end])
        # 発散前は非有限値を含まない
        @test !any(isnan, result.d[1:(first_nan - 1)])
    end

    @testset "keen_rk4_step: 定常状態は不動点" begin
        ss = steady_state(m)
        dt = 1.0 / 20
        ω_next, λ_next, d_next = DME.keen_rk4_step(m, ss.ω, ss.λ, ss.d, dt)
        # 定常状態では右辺が 0 なので1ステップ後も定常状態に留まる
        @test ω_next ≈ ss.ω atol = 1e-10
        @test λ_next ≈ ss.λ atol = 1e-10
        @test d_next ≈ ss.d atol = 1e-10
    end

    @testset "simulate: RK4 刻み収束（substeps=10 と 20 の差）" begin
        ss = steady_state(m)
        r10 = simulate(m, ss.ω, ss.λ, ss.d + 0.01; T = 300, options = ODESolverOptions(substeps = 10))
        r20 = simulate(m, ss.ω, ss.λ, ss.d + 0.01; T = 300, options = ODESolverOptions(substeps = 20))
        @test maximum(abs.(r10.ω .- r20.ω)) < 1e-5
        @test maximum(abs.(r10.λ .- r20.λ)) < 1e-5
        @test maximum(abs.(r10.d .- r20.d)) < 1e-5
    end

    @testset "to_simulation_result / plot_result（smoke test）" begin
        ss = steady_state(m)
        result = simulate(m, ss.ω, ss.λ, ss.d + 0.01; T = 300)
        sr = to_simulation_result(m, result, "simulate")
        @test sr.model_name == "Keen Model"
        @test sr.scenario_name == "simulate"
        @test haskey(sr, "ω")
        @test haskey(sr, "λ")
        @test haskey(sr, "d")
        @test haskey(sr, "π")
        @test haskey(sr, "g")
        @test nperiods(sr) == 300
        @test "parameters" in keys(sr.metadata)

        p = plot_result(sr)
        @test p isa Plots.Plot

        # 崩壊経路（NaN 混入）でも plot_result が例外なく動作する
        collapse = simulate(m, ss.ω, ss.λ, 5.0; T = 300)
        sr_collapse = to_simulation_result(m, collapse, "simulate")
        p_collapse = plot_result(sr_collapse)
        @test p_collapse isa Plots.Plot
    end
end
