@testset "ramsey" begin
    rams = RamseyModel(0.3, 0.99, 0.25)
    @testset "calc_ep" begin
        rtn = DME.calc_ep(rams)
        @test rtn[1] ≈ 1.226144733 atol=1e-8
        @test rtn[2] ≈ 0.756535429 atol=1e-8
    end
    @testset "find_path" begin
        ep = DME.calc_ep(rams)
        rtn = DME.find_path(rams, ep[1]/2)
        @test rtn.K[end] ≈ ep[1] atol=1e-3
        @test rtn.C[end] ≈ ep[2] atol=1e-3
    end
    @testset "optimize_c" begin
        rams2 = RamseyModel(0.3, 1.0, 0.5)
        f = x -> -45 + sqrt(x)
        @test DME.optimize_c(rams2, 1.0, f, 0.001, 3.0, 0.001) ≈ sqrt(10)-2 atol=1e-7
    end
    @testset "V" begin
        @test DME.V(rams, 1.0, x -> x / 2) ≈ -28.97431347 atol=7
    end
    @testset "update_value" begin
        node = DME.ChebNode(20, 0.5, 3.0)
        @test DME.update_value(rams, node, x -> x / 2, DME.ITPCheb)(1.0) ≈ -28.97431347 atol=7
    end
    @testset "simulate_by_nlvar" begin
        ep = DME.calc_ep(rams)
        rtn = DME.simulate_by_nlvar(rams, ep[1]/2)
        @test rtn.K[end] ≈ ep[1] atol=1e-2
        @test rtn.C[end] ≈ ep[2] atol=1e-2
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
end
