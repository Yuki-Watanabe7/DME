@testset "DocContext (軽量RAG)" begin
    # 共通テストデータ
    rbc  = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)
    irf_raw = impulse_response(rbc, 0.01)
    sr_irf  = to_simulation_result(rbc, irf_raw, "technology_shock")

    rams = RamseyModel(0.3, 0.99, 0.25)
    ep   = DME.calc_ep(rams)
    path_raw = DME.find_path(rams, ep[1] / 2)
    sr_path  = to_simulation_result(rams, path_raw, "find_path")

    # テスト用の docs_root（実パッケージの docs/ を使用）
    docs_root = joinpath(dirname(dirname(pathof(DME))), "docs")

    @testset "戻り値の型が DocsExcerpts であること" begin
        de = build_docs_excerpts("RBC Model"; docs_root = docs_root)
        @test de isa DocsExcerpts
    end

    @testset "既知モデル: model_doc が空でないこと" begin
        for mn in ["RBC Model", "Ramsey Model", "Solow Model",
                   "IS-LM Model", "AD-AS Model", "New Keynesian Model",
                   "VAR Model", "Mundell-Fleming Model"]
            de = build_docs_excerpts(mn; docs_root = docs_root)
            @test de isa DocsExcerpts
            @test !isempty(de.model_doc)
        end
    end

    @testset "未知モデル名: 安全に fallback して空文字列を返すこと" begin
        de = build_docs_excerpts("Unknown Model"; docs_root = docs_root)
        @test de isa DocsExcerpts
        @test de.model_doc == ""
        @test de.caveats_doc == ""
    end

    @testset "docs_root が存在しないパス: 安全に fallback すること" begin
        de = build_docs_excerpts("RBC Model"; docs_root = "/nonexistent/path/docs")
        @test de isa DocsExcerpts
        @test de.model_doc == ""
        @test de.output_guide == ""
        @test de.caveats_doc == ""
    end

    @testset "output_guide が空でないこと" begin
        de = build_docs_excerpts("RBC Model"; docs_root = docs_root)
        @test !isempty(de.output_guide)
    end

    @testset "caveats_doc が空でないこと (RBC / Ramsey)" begin
        for mn in ["RBC Model", "Ramsey Model"]
            de = build_docs_excerpts(mn; docs_root = docs_root)
            @test !isempty(de.caveats_doc)
        end
    end

    @testset "max_chars_per_doc: 各フィールドが上限以内であること" begin
        limit = 300
        de = build_docs_excerpts("RBC Model";
            docs_root = docs_root, max_chars_per_doc = limit,
        )
        # "…" が付加されても limit + 1 文字以内（末尾省略記号分）
        @test length(de.model_doc)    <= limit + 1
        @test length(de.output_guide) <= limit + 1
    end

    @testset "scenario_name='technology_shock': IRF セクションが選択されること" begin
        de = build_docs_excerpts("RBC Model";
            scenario_name = "technology_shock",
            docs_root = docs_root,
        )
        @test de isa DocsExcerpts
        # output_guide が空でないこと（IRF/ショック系の scenario_name で選択されること）
        @test !isempty(de.output_guide)
    end

    @testset "variable_names が渡されても正常動作すること" begin
        de = build_docs_excerpts("RBC Model";
            variable_names = [:K, :A, :C, :L],
            docs_root = docs_root,
        )
        @test de isa DocsExcerpts
        @test !isempty(de.model_doc)
    end

    @testset "keywords が渡されても正常動作すること" begin
        de = build_docs_excerpts("RBC Model";
            keywords  = ["IRF", "定常状態"],
            docs_root = docs_root,
        )
        @test de isa DocsExcerpts
    end

    @testset "build_docs_excerpts(ctx): AnalysisContext から生成できること" begin
        ctx = AnalysisContext(rbc, sr_irf)
        de  = build_docs_excerpts(ctx; docs_root = docs_root)
        @test de isa DocsExcerpts
        @test !isempty(de.model_doc)
        @test !isempty(de.output_guide)
    end

    @testset "build_docs_excerpts(ctx): Ramsey モデルでも動作すること" begin
        ctx = AnalysisContext(rams, sr_path)
        de  = build_docs_excerpts(ctx; docs_root = docs_root)
        @test de isa DocsExcerpts
        @test !isempty(de.model_doc)
    end

    @testset "生成した DocsExcerpts を AnalysisContext に設定できること" begin
        de  = build_docs_excerpts("RBC Model"; docs_root = docs_root)
        ctx = AnalysisContext(rbc, sr_irf; docs_excerpts = de)
        @test !isnothing(ctx.docs_excerpts)
        @test !isempty(ctx.docs_excerpts.model_doc)
    end

    @testset "to_dict で docs_excerpts が含まれること" begin
        de  = build_docs_excerpts("RBC Model"; docs_root = docs_root)
        ctx = AnalysisContext(rbc, sr_irf; docs_excerpts = de)
        d   = to_dict(ctx)
        @test haskey(d, "docs_excerpts")
        @test !isempty(d["docs_excerpts"]["model_doc"])
    end

    @testset "LLM API なしで完全動作すること" begin
        de  = build_docs_excerpts("RBC Model";
            variable_names = [:K, :A, :C, :L],
            scenario_name  = "technology_shock",
            keywords       = ["IRF"],
            docs_root      = docs_root,
        )
        ctx = AnalysisContext(rbc, sr_irf; docs_excerpts = de)
        @test to_dict(ctx) isa Dict{String, Any}
        @test to_json(ctx) isa String
        @test to_compact_dict(ctx) isa Dict{String, Any}
    end
end
