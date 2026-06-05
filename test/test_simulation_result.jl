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
        ep = DME.calc_ep(rams)
        raw = DME.find_path(rams, ep[1] / 2)
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
        raw = DME.shock(rbc, 0.01)
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
