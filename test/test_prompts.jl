@testset "Prompts (explain_result)" begin
    # 共通テストデータ
    rbc = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)
    irf_raw = impulse_response(rbc, 0.01)
    sr_irf = to_simulation_result(rbc, irf_raw, "technology_shock")

    rams = RamseyModel(0.3, 0.99, 0.25)
    ep = DME.calc_ep(rams)
    path_raw = DME.find_path(rams, ep[1] / 2)
    sr_path = to_simulation_result(rams, path_raw, "find_path")

    ctx_rbc = AnalysisContext(
        rbc, sr_irf;
        shock_description = "1% positive technology shock",
        caveats = Caveats(
            ["Closed economy", "Representative agent"],
            String[],
            ["Variables are log deviations from steady state"],
        ),
    )
    ctx_rams = AnalysisContext(rams, sr_path)

    @testset "build_explain_prompt: 基本構造" begin
        prompt = build_explain_prompt(ctx_rbc)
        @test prompt isa String
        @test length(prompt) > 0
        # システム指示が含まれていること
        @test occursin("分析補助AI", prompt)
        @test occursin("必ず守るルール", prompt)
        # モデル情報が含まれていること
        @test occursin("RBC Model", prompt)
        # ショック設定が含まれていること
        @test occursin("1% positive technology shock", prompt)
        # シナリオ名が含まれていること
        @test occursin("technology_shock", prompt)
        # 期間数が含まれていること
        @test occursin(string(nperiods(sr_irf)), prompt)
    end

    @testset "build_explain_prompt: パラメータが含まれること" begin
        prompt = build_explain_prompt(ctx_rbc)
        @test occursin("α", prompt) || occursin("alpha", prompt) || occursin("0.3", prompt)
        @test occursin("β", prompt) || occursin("beta", prompt) || occursin("0.99", prompt)
    end

    @testset "build_explain_prompt: 安全指示が含まれること" begin
        prompt = build_explain_prompt(ctx_rbc)
        # 禁止事項の指示
        @test occursin("投資判断", prompt)
        @test occursin("将来予測", prompt) || occursin("断定的", prompt)
        # 免責文言の指示
        @test occursin("投資判断・政策立案の根拠として使用することを意図していません", prompt)
    end

    @testset "build_explain_prompt: caveats が含まれること" begin
        prompt = build_explain_prompt(ctx_rbc)
        @test occursin("Closed economy", prompt)
        @test occursin("Representative agent", prompt)
        @test occursin("log deviations", prompt)
    end

    @testset "build_explain_prompt: docs_excerpts が含まれること" begin
        de = DocsExcerpts(
            "RBC モデルは資本・労働・技術の3要素モデルです。",
            "ŷ は産出の対数偏差です。",
            "名目硬直性を含みません。",
        )
        ctx_with_docs = AnalysisContext(rbc, sr_irf; docs_excerpts = de)
        prompt = build_explain_prompt(ctx_with_docs)
        @test occursin("RBC モデルは資本", prompt)
        @test occursin("ŷ は産出", prompt)
        @test occursin("名目硬直性", prompt)
    end

    @testset "build_explain_prompt: docs_excerpts なしでもエラーなし" begin
        ctx_no_docs = AnalysisContext(rbc, sr_irf)
        prompt = build_explain_prompt(ctx_no_docs)
        @test prompt isa String
        @test length(prompt) > 0
    end

    @testset "build_explain_prompt: Ramseyモデルでも動作すること" begin
        prompt = build_explain_prompt(ctx_rams)
        @test prompt isa String
        @test occursin("Ramsey Model", prompt)
        @test occursin("find_path", prompt)
    end

    @testset "explain_result: 戻り値の型" begin
        out = explain_result(ctx_rbc)
        @test out isa ExplainResultOutput
    end

    @testset "explain_result: prompt フィールドが非空文字列" begin
        out = explain_result(ctx_rbc)
        @test out.prompt isa String
        @test length(out.prompt) > 0
        @test occursin("RBC Model", out.prompt)
    end

    @testset "explain_result: what_was_computed が非空" begin
        out = explain_result(ctx_rbc)
        @test !isempty(out.what_was_computed)
        @test occursin("RBC Model", out.what_was_computed)
        @test occursin("technology_shock", out.what_was_computed)
    end

    @testset "explain_result: variable_movements が非空" begin
        out = explain_result(ctx_rbc)
        @test !isempty(out.variable_movements)
    end

    @testset "explain_result: economic_interpretation が非空" begin
        out = explain_result(ctx_rbc)
        @test !isempty(out.economic_interpretation)
        # モデル名が含まれること
        @test occursin("RBC Model", out.economic_interpretation) ||
              occursin("モデル", out.economic_interpretation)
    end

    @testset "explain_result: model_limitations が非空" begin
        out = explain_result(ctx_rbc)
        @test !isempty(out.model_limitations)
    end

    @testset "explain_result: next_analyses が 1 件以上" begin
        out = explain_result(ctx_rbc)
        @test length(out.next_analyses) >= 1
        # 断定的推奨ではなく候補提示であること（「推奨」「検討」等の文言）
        @test any(occursin("検討", a) || occursin("候補", a) || occursin("分析", a) for a in out.next_analyses)
    end

    @testset "explain_result: caveats が 1 件以上" begin
        out = explain_result(ctx_rbc)
        @test length(out.caveats) >= 1
    end

    @testset "explain_result: disclaimer が必須文言を含む" begin
        out = explain_result(ctx_rbc)
        @test !isempty(out.disclaimer)
        @test occursin("投資判断", out.disclaimer)
        @test occursin("政策立案", out.disclaimer)
        @test occursin("意図していません", out.disclaimer)
    end

    @testset "explain_result: LLM API を呼ばずに完全動作すること" begin
        # LLM呼び出しなしで全フィールドが生成されることを確認
        out = explain_result(ctx_rams)
        @test out isa ExplainResultOutput
        @test !isempty(out.prompt)
        @test !isempty(out.what_was_computed)
        @test !isempty(out.variable_movements)
        @test !isempty(out.economic_interpretation)
        @test !isempty(out.model_limitations)
        @test !isempty(out.next_analyses)
        @test !isempty(out.caveats)
        @test !isempty(out.disclaimer)
    end

    @testset "explain_result: caveats がコンテキストの内容を反映すること" begin
        out = explain_result(ctx_rbc)
        @test any(occursin("Closed economy", c) for c in out.caveats)
        @test any(occursin("Representative agent", c) for c in out.caveats)
    end

    @testset "explain_result: caveats なし AnalysisContext でもデフォルト caveats が生成される" begin
        ctx_no_caveats = AnalysisContext(rbc, sr_irf)
        out = explain_result(ctx_no_caveats)
        @test length(out.caveats) >= 1
    end

    @testset "explain_result: docs_excerpts がプロンプトに反映される" begin
        de = DocsExcerpts("RBC model doc", "output guide text", "")
        ctx_with_docs = AnalysisContext(rbc, sr_irf; docs_excerpts = de)
        out = explain_result(ctx_with_docs)
        @test occursin("RBC model doc", out.prompt)
        @test occursin("output guide text", out.prompt)
    end
end
