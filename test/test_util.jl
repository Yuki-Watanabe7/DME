@testset "util" begin
    @testset "Node" begin
        nd = DME.Node([3.1, 5.2, 9.3])
        @test DME.len(nd) == 3
        @test DME.lower_bound(nd) == 3.1
        @test DME.upper_bound(nd) == 9.3
        rtn = [x for x in DME.node(nd)]
        @test rtn[1] == 3.1
        @test rtn[2] == 5.2
        @test rtn[3] == 9.3
    end
    @testset "Node2D" begin
        nd1 = DME.Node([3.1, 5.2, 9.3])
        nd2 = DME.Node([1.8, 2.1])
        nd = DME.Node2D(nd1, nd2)
        @test DME.len(nd) == (3, 2)
        @test DME.lower_bound(nd) == (3.1, 1.8)
        @test DME.upper_bound(nd) == (9.3, 2.1)
        rtn_nd1, rtn_nd2 = DME.node(nd)
        rtn1 = [x for x in rtn_nd1]
        rtn2 = [x for x in rtn_nd2]
        @test rtn1[1] == 3.1
        @test rtn1[2] == 5.2
        @test rtn1[3] == 9.3
        @test rtn2[1] == 1.8
        @test rtn2[2] == 2.1
    end
    @testset "AbstractNodeWithParam" begin
        @test DME.len(DME.ChebNode(2, -1, 1)) == 2
        @test DME.lower_bound(DME.ChebNode(2, -1, 1)) == -1
        @test DME.upper_bound(DME.ChebNode(2, -1, 1)) == 1
    end
    @testset "ChebNode" begin
        @test DME.node(DME.ChebNode(2, -1, 1)) ≈ [-1/sqrt(2), 1/sqrt(2)]
        @test DME.node(DME.ChebNode(2, -1.5, 2.5)) ≈ [-1/sqrt(2), 1/sqrt(2)] .* 2 .+ 0.5
    end
    @testset "RangeNode" begin
        for (i, knot) in enumerate(DME.node(DME.RangeNode(4, 1.0, 3.0)))
            @test knot ≈ 2 / 3 * (i-1) + 1
        end
    end
    @testset "is_updated" begin
        @test DME.is_updated([1.0, 2.0, 3.0], [1.09, 2.09, 3.09], 0.1) == false
        @test DME.is_updated([1.0, 2.0, 3.0], [1.09, 2.1, 3.09], 0.1) == true
    end
    @testset "interpo" begin
        func = x -> x^3 - x
        c_node = DME.ChebNode(20, -1.5, 2.5)
        che = DME.Cheb(c_node, [func(x) for x in DME.node(c_node)])
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
        l2_node = DME.Node2D(DME.Node([1.0, 2.5, 4.0]), DME.Node([0.5, 3.5]))
        V = [3.5, 0.5, 2.0, 1.5, 1.0, 2.5]
        l2_param = DME.LinInterpo2D(l2_node, V)
        @test DME.interpo((0.5, 0.0), l2_param) == 3.5
        @test DME.interpo((5.0, 4.0), l2_param) == 2.5
        @test DME.interpo((2.5, 0.5), l2_param) == 2.0
        @test DME.interpo((1.5, 3.5), l2_param) ≈ 5/6
        @test DME.interpo((3.5, 2.0), l2_param) ≈ 1.75
    end
end

@testset "SolverOptions" begin
    @testset "SolverOptions デフォルト値" begin
        opts = SolverOptions()
        @test opts.horizon == 30
        @test opts.max_iter == 1000
        @test opts.tolerance == 1e-8
    end
    @testset "SolverOptions カスタム値" begin
        opts = SolverOptions(horizon = 15, max_iter = 500, tolerance = 1e-6)
        @test opts.horizon == 15
        @test opts.max_iter == 500
        @test opts.tolerance == 1e-6
    end
    @testset "ValueIterationOptions デフォルト値" begin
        opts = ValueIterationOptions()
        @test opts.n == 20
        @test opts.a == 0.5
        @test opts.b == 3.0
        @test opts.max_iter == 100
        @test opts.tolerance == 0.0001
        @test opts.itp_type == DME.ITPCubic
    end
    @testset "ValueIterationOptions カスタム値" begin
        opts = ValueIterationOptions(n = 10, a = 0.8, b = 2.5, max_iter = 50)
        @test opts.n == 10
        @test opts.a == 0.8
        @test opts.b == 2.5
        @test opts.max_iter == 50
    end
end
