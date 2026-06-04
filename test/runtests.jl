using DME
using Test

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
        @test rtn.K[end] ≈ ep[1] atol=1e-2
        @test rtn.C[end] ≈ ep[2] atol=1e-2
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

@testset "SimulationResult" begin
    @testset "コンストラクタ（フルフィールド）" begin
        vars = Dict{String, Vector{Float64}}("K" => [1.0, 1.1], "C" => [0.5, 0.6])
        meta = Dict{String, Any}("note" => "test")
        r = SimulationResult("TestModel", "test_scenario", vars, meta)
        @test r.model_name == "TestModel"
        @test r.scenario_name == "test_scenario"
        @test r["K"] == [1.0, 1.1]
        @test r["C"] == [0.5, 0.6]
        @test r.metadata["note"] == "test"
    end

    @testset "コンストラクタ（metadata省略）" begin
        vars = Dict{String, Vector{Float64}}("K" => [1.0, 2.0])
        r = SimulationResult("M", "s", vars)
        @test r.metadata == Dict{String, Any}()
        @test nperiods(r) == 2
    end

    @testset "haskey / variable_names" begin
        vars = Dict{String, Vector{Float64}}("A" => [1.0], "B" => [2.0])
        r = SimulationResult("M", "s", vars)
        @test haskey(r, "A")
        @test !haskey(r, "Z")
        @test sort(variable_names(r)) == ["A", "B"]
    end

    @testset "nperiods（空変数）" begin
        r = SimulationResult("M", "s", Dict{String, Vector{Float64}}())
        @test nperiods(r) == 0
    end

    @testset "to_simulation_result（Ramseyモデル）" begin
        rams = RamseyModel(0.3, 0.99, 0.25)
        ep = calc_ep(rams)
        raw = find_path(rams, ep[1] / 2)
        r = to_simulation_result(rams, raw, "find_path")
        @test r.model_name == "Ramsey Model"
        @test r.scenario_name == "find_path"
        @test haskey(r, "K")
        @test haskey(r, "C")
        @test r["K"] ≈ raw.K
        @test r["C"] ≈ raw.C
        @test nperiods(r) == length(raw.K)
        @test haskey(r.metadata, "parameters")
    end

    @testset "to_simulation_result（RBCモデル）" begin
        rbc = RBCModel(0.3, 0.99, 1, 0.025, 1, 0.9)
        raw = shock(rbc, 0.01)
        r = to_simulation_result(rbc, raw, "shock")
        @test r.model_name == "RBC Model"
        @test r.scenario_name == "shock"
        # shock の全キーが SimulationResult に含まれることを確認
        for key in keys(raw)
            @test haskey(r, key)
        end
        first_key = first(keys(raw))
        @test nperiods(r) == length(raw[first_key])
        @test haskey(r.metadata, "parameters")
        # raw Dict へのキー追加が SimulationResult に影響しないことを確認（shallow copy）
        raw["__test_extra__"] = [0.0]
        @test !haskey(r, "__test_extra__")
    end
end
