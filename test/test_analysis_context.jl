@testset "AnalysisContext" begin
    # 共通テストデータ
    rbc = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)
    irf_raw = impulse_response(rbc, 0.01)
    sr_irf = to_simulation_result(rbc, irf_raw, "technology_shock")

    rams = RamseyModel(0.3, 0.99, 0.25)
    ep = DME.calc_ep(rams)
    path_raw = DME.find_path(rams, ep[1] / 2)
    sr_path = to_simulation_result(rams, path_raw, "find_path")

    @testset "ModelMetadata: RBCModel から生成" begin
        meta = ModelMetadata(rbc)
        @test meta.model_name == "RBC Model"
        @test :K in meta.state_variables
        @test :A in meta.state_variables
        @test :C in meta.control_variables
        @test haskey(meta.parameters, "α")
        @test haskey(meta.parameters, "β")
        @test meta.parameters["α"] ≈ 0.3
        @test meta.parameters["β"] ≈ 0.99
    end

    @testset "ModelMetadata: RamseyModel から生成" begin
        meta = ModelMetadata(rams)
        @test meta.model_name == "Ramsey Model"
        @test :K in meta.state_variables
        @test :C in meta.control_variables
        @test haskey(meta.parameters, "α")
        @test haskey(meta.parameters, "δ")
    end

    @testset "SimulationResultSummary: shock_description なし" begin
        srs = SimulationResultSummary(sr_irf)
        @test srs.scenario_name == "technology_shock"
        @test srs.n_periods == nperiods(sr_irf)
        @test haskey(srs.variable_summaries, "ŷ")
        @test isnothing(srs.shock_description)
    end

    @testset "SimulationResultSummary: shock_description あり" begin
        srs = SimulationResultSummary(sr_irf; shock_description = "1% tech shock")
        @test srs.shock_description == "1% tech shock"
    end

    @testset "Caveats: デフォルトコンストラクタ" begin
        c = Caveats()
        @test isempty(c.model_limitations)
        @test isempty(c.data_limitations)
        @test isempty(c.interpretation_warnings)
    end

    @testset "Caveats: フィールド指定" begin
        c = Caveats(
            ["Closed economy", "Representative agent"],
            ["FRED data may be revised"],
            ["Variables are log deviations"],
        )
        @test length(c.model_limitations) == 2
        @test c.model_limitations[1] == "Closed economy"
        @test length(c.interpretation_warnings) == 1
    end

    @testset "DocsExcerpts: デフォルトコンストラクタ" begin
        de = DocsExcerpts()
        @test de.model_doc == ""
        @test de.output_guide == ""
        @test de.caveats_doc == ""
    end

    @testset "DocsExcerpts: フィールド指定" begin
        de = DocsExcerpts("RBC model doc", "output guide", "caveats")
        @test de.model_doc == "RBC model doc"
    end

    @testset "AnalysisContext: モデル+SimulationResult から生成（最小）" begin
        ctx = AnalysisContext(rbc, sr_irf)
        @test ctx.model_metadata.model_name == "RBC Model"
        @test ctx.simulation_result_summary.scenario_name == "technology_shock"
        @test ctx.simulation_result_summary.n_periods == nperiods(sr_irf)
        @test isnothing(ctx.data_comparison_summary)
        @test isnothing(ctx.simulation_result_summary.shock_description)
        @test isnothing(ctx.docs_excerpts)
        @test isempty(ctx.caveats.model_limitations)
    end

    @testset "AnalysisContext: キーワード引数フルセット" begin
        dcs = DataComparisonSummary(
            "FRED/GDPC1",
            (1, 100),
            Dict{String, Any}("mean_deviation" => 0.05),
            ["Seasonal adjustment applied"],
        )
        de = DocsExcerpts("model doc", "output guide", "caveats doc")
        caveats = Caveats(["Closed economy"], String[], ["Log deviations"])

        ctx = AnalysisContext(
            rbc, sr_irf;
            shock_description = "1% positive technology shock",
            caveats = caveats,
            data_comparison_summary = dcs,
            docs_excerpts = de,
        )
        @test ctx.simulation_result_summary.shock_description == "1% positive technology shock"
        @test !isnothing(ctx.data_comparison_summary)
        @test ctx.data_comparison_summary.data_source == "FRED/GDPC1"
        @test ctx.data_comparison_summary.comparison_period == (1, 100)
        @test !isnothing(ctx.docs_excerpts)
        @test ctx.docs_excerpts.model_doc == "model doc"
        @test ctx.caveats.model_limitations[1] == "Closed economy"
    end

    @testset "AnalysisContext: Ramseyモデルでも生成できる" begin
        ctx = AnalysisContext(rams, sr_path)
        @test ctx.model_metadata.model_name == "Ramsey Model"
        @test ctx.simulation_result_summary.scenario_name == "find_path"
        @test ctx.simulation_result_summary.n_periods > 0
        @test haskey(ctx.simulation_result_summary.variable_summaries, "K")
    end

    @testset "to_dict: ModelMetadata" begin
        meta = ModelMetadata(rbc)
        d = to_dict(meta)
        @test d["model_name"] == "RBC Model"
        @test "K" in d["state_variables"]
        @test "C" in d["control_variables"]
        @test haskey(d["parameters"], "α")
        @test d isa Dict{String, Any}
    end

    @testset "to_dict: SimulationResultSummary — NamedTupleがDictに展開される" begin
        srs = SimulationResultSummary(sr_irf; shock_description = "1% shock")
        d = to_dict(srs)
        @test d["scenario_name"] == "technology_shock"
        @test d["n_periods"] == nperiods(sr_irf)
        @test d["shock_description"] == "1% shock"
        vs = d["variable_summaries"]
        @test vs isa Dict
        # ŷ のサマリーが Dict になっていること
        ys = vs["ŷ"]
        @test ys isa Dict
        @test haskey(ys, "initial")
        @test haskey(ys, "peak_response")
        @test haskey(ys, "sign_reversal")
    end

    @testset "to_dict: SimulationResultSummary — shock_description なしは含まれない" begin
        srs = SimulationResultSummary(sr_irf)
        d = to_dict(srs)
        @test !haskey(d, "shock_description")
    end

    @testset "to_dict: DataComparisonSummary" begin
        dcs = DataComparisonSummary(
            "FRED/GDPC1",
            (10, 50),
            Dict{String, Any}("max_dev" => 0.1),
            ["Revised data"],
        )
        d = to_dict(dcs)
        @test d["data_source"] == "FRED/GDPC1"
        @test d["comparison_period"] == [10, 50]
        @test d["deviation_statistics"]["max_dev"] ≈ 0.1
        @test d["data_caveats"] == ["Revised data"]
    end

    @testset "to_dict: Caveats" begin
        c = Caveats(["Limitation A"], ["Data caveat"], ["Warning X"])
        d = to_dict(c)
        @test d["model_limitations"] == ["Limitation A"]
        @test d["data_limitations"] == ["Data caveat"]
        @test d["interpretation_warnings"] == ["Warning X"]
    end

    @testset "to_dict: AnalysisContext — オプショナルフィールドなし" begin
        ctx = AnalysisContext(rbc, sr_irf)
        d = to_dict(ctx)
        @test haskey(d, "model_metadata")
        @test haskey(d, "simulation_result_summary")
        @test haskey(d, "caveats")
        @test !haskey(d, "data_comparison_summary")
        @test !haskey(d, "docs_excerpts")
    end

    @testset "to_dict: AnalysisContext — オプショナルフィールドあり" begin
        dcs = DataComparisonSummary("FRED/X", (1, 10), Dict{String, Any}(), String[])
        de = DocsExcerpts("doc", "guide", "caveat")
        ctx = AnalysisContext(rbc, sr_irf; data_comparison_summary = dcs, docs_excerpts = de)
        d = to_dict(ctx)
        @test haskey(d, "data_comparison_summary")
        @test haskey(d, "docs_excerpts")
    end

    @testset "to_json: JSON文字列が生成される" begin
        ctx = AnalysisContext(rbc, sr_irf)
        j = to_json(ctx)
        @test j isa String
        @test length(j) > 0
        @test occursin("model_metadata", j)
        @test occursin("simulation_result_summary", j)
    end

    @testset "to_compact_dict: 変数サマリーが4フィールドに絞られる" begin
        ctx = AnalysisContext(rbc, sr_irf)
        cd = to_compact_dict(ctx)
        vs = cd["simulation_result_summary"]["variable_summaries"]
        ys = vs["ŷ"]
        @test haskey(ys, "initial")
        @test haskey(ys, "final")
        @test haskey(ys, "peak_response")
        @test haskey(ys, "sign_reversal")
        # compact では range, argmax, argmin は省略される
        @test !haskey(ys, "range")
        @test !haskey(ys, "argmax")
        @test !haskey(ys, "argmin")
    end

    @testset "to_compact_dict: 空のDocsExcerptsは省略される" begin
        ctx = AnalysisContext(rbc, sr_irf; docs_excerpts = DocsExcerpts())
        cd = to_compact_dict(ctx)
        @test !haskey(cd, "docs_excerpts")
    end

    @testset "to_compact_dict: 内容のあるDocsExcerptsは保持される" begin
        de = DocsExcerpts("some doc", "", "")
        ctx = AnalysisContext(rbc, sr_irf; docs_excerpts = de)
        cd = to_compact_dict(ctx)
        @test haskey(cd, "docs_excerpts")
    end

    @testset "LLM API なしで完全動作すること（インポート・構築・変換）" begin
        # LLM接続層の実装に依存せず、AnalysisContext の構築・変換がすべて完結する
        ctx = AnalysisContext(
            rams, sr_path;
            caveats = Caveats(["Infinite horizon"], String[], ["Log deviation"]),
        )
        @test to_dict(ctx) isa Dict{String, Any}
        @test to_json(ctx) isa String
        @test to_compact_dict(ctx) isa Dict{String, Any}
    end
end
