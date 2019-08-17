using DME
using Test

@testset "util" begin
    @testset "ChebNode" begin
        @test DME.ChebNode(2, -1, 1).node ≈ [-1/sqrt(2), 1/sqrt(2)]
        @test DME.ChebNode(2, -1.5, 2.5).node ≈ [-1/sqrt(2), 1/sqrt(2)] .* 2 .+ 0.5
    end
    @testset "is_updated" begin
        @test DME.is_updated([1.0, 2.0, 3.0], [1.09, 2.09, 3.09], 0.1) == false
        @test DME.is_updated([1.0, 2.0, 3.0], [1.09, 2.1, 3.09], 0.1) == true
    end
    @testset "interpo" begin
        func = x -> x^3 - x
        c_node = DME.ChebNode(20, -1.5, 2.5)
        che = DME.Cheb(c_node, [func(x) for x in c_node.node])
        for s in -1.5:0.1:2.5
            @test DME.interpo(s, che) ≈ func(s) atol=1e-10
        end
        l_node = DME.Node([1.0, 2.5, 4.0])
        V = [3.5, 0.5, 2.0]
        l_param = DME.LinInterpo(l_node, V)
        @test DME.interpo(0.5, l_param) == 3.5
        @test DME.interpo(5.0, l_param) == 2.0
        @test DME.interpo(2.5, l_param) == 0.5
        @test DME.interpo(1.5, l_param) ≈ 2.5
        @test DME.interpo(3.5, l_param) ≈ 1.5
    end
end

@testset "ramsey" begin
    rams = RamseyModel(0.3, 0.99, 0.25)
    @testset "calc_ep" begin
        rtn = calc_ep(rams)
        @test rtn[1] ≈ 1.226144733 atol=1e-8
        @test rtn[2] ≈ 0.756535429 atol=1e-8
    end
    @testset "find_path" begin
        ep = calc_ep(rams)
        rtn = find_path(rams, ep[1]/2)
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
        ep = calc_ep(rams)
        rtn = simulate_by_nlvar(rams, ep[1]/2)
        @test rtn.K[end] ≈ ep[1] atol=1e-1
        @test rtn.C[end] ≈ ep[2] atol=1e-1
    end
end

@testset "RBC" begin
    rbc = RBCModel(0.3, 0.99, 1, 0.025, 1, 0.9)
    @testset "calc_ep" begin
        rtn = calc_ep(rbc)
        @test rtn[1] ≈ 1.0 atol=1e-3
        @test rtn[2] ≈ 0.0351 atol=1e-3
        @test rtn[3] ≈ 1.7557 atol=1e-3
        @test rtn[4] ≈ 0.6672 atol=1e-3
        @test rtn[5] ≈ 14.301 atol=1e-3
        @test rtn[6] ≈ 1.6733 atol=1e-3
        @test rtn[7] ≈ 1.3158 atol=1e-3
    end
end
