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

    @testset "summarize_result: 基本統計量" begin
        vars = Dict{String, Vector{Float64}}(
            "X" => [1.0, 3.0, 2.0, -1.0, 0.0],
        )
        r = SimulationResult("TestModel", "test", vars)
        s = summarize_result(r)

        @test s["model_name"] == "TestModel"
        @test s["scenario_name"] == "test"
        @test s["nperiods"] == 5

        xs = s["variables"]["X"]
        @test xs.initial == 1.0
        @test xs.final == 0.0
        @test xs.max == 3.0
        @test xs.min == -1.0
        @test xs.range ≈ 4.0
        @test xs.argmax == 2
        @test xs.argmin == 4
        # 正と負の両方が存在するので sign_reversal = true
        @test xs.sign_reversal == true
        # 絶対値最大は 3.0（正）
        @test xs.peak_response == 3.0
    end

    @testset "summarize_result: 符号反転なし" begin
        vars = Dict{String, Vector{Float64}}("K" => [1.0, 2.0, 3.0])
        r = SimulationResult("M", "s", vars)
        s = summarize_result(r)
        ks = s["variables"]["K"]
        @test ks.sign_reversal == false
        @test ks.initial == 1.0
        @test ks.final == 3.0
        @test ks.max == 3.0
        @test ks.min == 1.0
        @test ks.peak_response == 3.0
    end

    @testset "summarize_result: 負の peak_response" begin
        # 絶対値最大が負値のケース
        vars = Dict{String, Vector{Float64}}("Y" => [0.0, -5.0, 2.0])
        r = SimulationResult("M", "s", vars)
        s = summarize_result(r)
        ys = s["variables"]["Y"]
        @test ys.peak_response == -5.0
        @test ys.sign_reversal == true
    end

    @testset "summarize_result: Ramseyモデル結果" begin
        rams = RamseyModel(0.3, 0.99, 0.25)
        ep = DME.calc_ep(rams)
        raw = DME.find_path(rams, ep[1] / 2)
        r = to_simulation_result(rams, raw, "find_path")
        s = summarize_result(r)

        @test s["model_name"] == "Ramsey Model"
        @test s["scenario_name"] == "find_path"
        @test s["nperiods"] == nperiods(r)
        @test haskey(s["variables"], "K")
        @test haskey(s["variables"], "C")
        ks = s["variables"]["K"]
        @test ks.initial ≈ raw.K[1]
        @test ks.final ≈ raw.K[end]
        # 定常状態へ収束するため K は単調増加（K0 < K_star）
        @test ks.min ≈ ks.initial
        @test ks.max ≈ ks.final
    end

    @testset "summarize_result: RBC IRF結果" begin
        rbc = RBCModel(0.3, 0.99, 1, 0.025, 1, 0.9)
        raw = DME.shock(rbc, 0.01)
        r = to_simulation_result(rbc, raw, "shock")
        s = summarize_result(r)

        @test s["model_name"] == "RBC Model"
        @test s["scenario_name"] == "shock"
        # 全変数のサマリーが存在する
        for key in keys(raw)
            @test haskey(s["variables"], key)
            vs = s["variables"][key]
            @test vs.initial isa Float64
            @test vs.argmax isa Int
            @test vs.sign_reversal isa Bool
        end
        # ŷ はショック後に正の応答を示し、第1期にピーク
        @test s["variables"]["ŷ"].max > 0.0
        @test s["variables"]["ŷ"].argmax == 1
    end
end
