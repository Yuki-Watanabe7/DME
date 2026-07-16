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
end
