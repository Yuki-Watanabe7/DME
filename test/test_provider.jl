@testset "LLM Provider" begin

    @testset "LLMProviderError: 型・メッセージ確認" begin
        err = LLMProviderError("test error message")
        @test err isa Exception
        @test err.message == "test error message"
        io = IOBuffer()
        Base.showerror(io, err)
        @test occursin("test error message", String(take!(io)))
    end

    @testset "LLMRequest: デフォルトコンストラクタ" begin
        req = LLMRequest("system", "user")
        @test req.system_prompt == "system"
        @test req.user_prompt == "user"
        @test req.max_tokens == 2000
        @test req.temperature == 0.3
    end

    @testset "LLMRequest: キーワード引数でオプション指定" begin
        req = LLMRequest("sys", "usr"; max_tokens = 500, temperature = 0.7)
        @test req.max_tokens == 500
        @test req.temperature == 0.7
    end

    @testset "LLMResponse: フィールド保持" begin
        res = LLMResponse("生成テキスト", "gpt-4o-mini", "stop", 10, 20)
        @test res.content == "生成テキスト"
        @test res.model == "gpt-4o-mini"
        @test res.finish_reason == "stop"
        @test res.input_tokens == 10
        @test res.output_tokens == 20
    end

    @testset "LLMResponse: usage が nothing でも動作" begin
        res = LLMResponse("text", "mock", "mock", nothing, nothing)
        @test isnothing(res.input_tokens)
        @test isnothing(res.output_tokens)
    end

    # === MockLLMProvider ===

    @testset "MockLLMProvider: AbstractLLMProvider のサブタイプ" begin
        provider = MockLLMProvider()
        @test provider isa AbstractLLMProvider
        @test provider isa MockLLMProvider
    end

    @testset "MockLLMProvider: complete が LLMResponse を返す" begin
        provider = MockLLMProvider()
        req = LLMRequest("システム指示", "ユーザー質問")
        res = complete(provider, req)
        @test res isa LLMResponse
        @test !isempty(res.content)
        @test res.model == "mock"
        @test res.finish_reason == "mock"
    end

    @testset "MockLLMProvider: デフォルト応答に免責文言が含まれる" begin
        provider = MockLLMProvider()
        req = LLMRequest("", "test")
        res = complete(provider, req)
        @test occursin("投資判断", res.content)
        @test occursin("意図していません", res.content)
    end

    @testset "MockLLMProvider: usage フィールドは nothing" begin
        provider = MockLLMProvider()
        req = LLMRequest("", "test")
        res = complete(provider, req)
        @test isnothing(res.input_tokens)
        @test isnothing(res.output_tokens)
    end

    @testset "MockLLMProvider: カスタムテンプレートが応答に反映される" begin
        provider = MockLLMProvider("カスタム応答テンプレート")
        req = LLMRequest("", "test")
        res = complete(provider, req)
        @test occursin("カスタム応答テンプレート", res.content)
    end

    @testset "MockLLMProvider: 応答はプロンプト長を含む" begin
        provider = MockLLMProvider()
        req = LLMRequest("syspart", "userpart")
        res = complete(provider, req)
        @test occursin("7", res.content)  # "syspart" = 7 文字
    end

    @testset "MockLLMProvider: LLM API を呼ばずに完全動作する" begin
        provider = MockLLMProvider()
        for _ in 1:3
            req = LLMRequest("s", "u")
            res = complete(provider, req)
            @test res isa LLMResponse
        end
    end

    # === OpenAIProvider ===

    @testset "OpenAIProvider: OPENAI_API_KEY 未設定で LLMProviderError" begin
        orig = get(ENV, "OPENAI_API_KEY", nothing)
        delete!(ENV, "OPENAI_API_KEY")
        try
            @test_throws LLMProviderError OpenAIProvider()
        finally
            isnothing(orig) || (ENV["OPENAI_API_KEY"] = orig)
        end
    end

    @testset "OpenAIProvider: 空文字列の api_key で LLMProviderError" begin
        @test_throws LLMProviderError OpenAIProvider("")
    end

    @testset "OpenAIProvider: api_key 直接指定で構築可能" begin
        provider = OpenAIProvider("sk-test-dummy-key")
        @test provider isa AbstractLLMProvider
        @test provider isa OpenAIProvider
        @test provider.api_key == "sk-test-dummy-key"
        @test provider.model == "gpt-4o-mini"
        @test provider.timeout_seconds == 30
        @test provider.max_retries == 3
        @test provider.retry_delay_seconds == 1.0
    end

    @testset "OpenAIProvider: キーワード引数でオプション指定" begin
        provider = OpenAIProvider("sk-key"; model = "gpt-4o", timeout_seconds = 60, max_retries = 5)
        @test provider.model == "gpt-4o"
        @test provider.timeout_seconds == 60
        @test provider.max_retries == 5
    end

    @testset "OpenAIProvider: OPENAI_API_KEY 設定済みのキーワード引数コンストラクタ" begin
        orig = get(ENV, "OPENAI_API_KEY", nothing)
        ENV["OPENAI_API_KEY"] = "sk-test-from-env"
        try
            provider = OpenAIProvider()
            @test provider isa OpenAIProvider
            @test provider.api_key == "sk-test-from-env"
        finally
            isnothing(orig) ? delete!(ENV, "OPENAI_API_KEY") : (ENV["OPENAI_API_KEY"] = orig)
        end
    end

    # === create_provider ===

    @testset "create_provider: use_mock=true で MockLLMProvider" begin
        p = create_provider(use_mock = true)
        @test p isa MockLLMProvider
    end

    @testset "create_provider: OPENAI_API_KEY 未設定時は MockLLMProvider にフォールバック" begin
        orig = get(ENV, "OPENAI_API_KEY", nothing)
        delete!(ENV, "OPENAI_API_KEY")
        try
            p = create_provider()
            @test p isa MockLLMProvider
        finally
            isnothing(orig) || (ENV["OPENAI_API_KEY"] = orig)
        end
    end

    @testset "create_provider: OPENAI_API_KEY 設定時は OpenAIProvider" begin
        orig = get(ENV, "OPENAI_API_KEY", nothing)
        ENV["OPENAI_API_KEY"] = "sk-test-key"
        try
            p = create_provider()
            @test p isa OpenAIProvider
            @test p.api_key == "sk-test-key"
        finally
            isnothing(orig) ? delete!(ENV, "OPENAI_API_KEY") : (ENV["OPENAI_API_KEY"] = orig)
        end
    end

    @testset "create_provider: model オプションが OpenAIProvider に渡される" begin
        orig = get(ENV, "OPENAI_API_KEY", nothing)
        ENV["OPENAI_API_KEY"] = "sk-key"
        try
            p = create_provider(model = "gpt-4o")
            @test p isa OpenAIProvider
            @test p.model == "gpt-4o"
        finally
            isnothing(orig) ? delete!(ENV, "OPENAI_API_KEY") : (ENV["OPENAI_API_KEY"] = orig)
        end
    end

    # === complete_from_prompt ===

    @testset "complete_from_prompt: 区切りなし文字列を受け取れる" begin
        provider = MockLLMProvider()
        res = complete_from_prompt(provider, "単一プロンプト文字列")
        @test res isa LLMResponse
        @test !isempty(res.content)
    end

    @testset "complete_from_prompt: \\n---\\n で system/user に分割される" begin
        provider = MockLLMProvider("分割確認テンプレート")
        res = complete_from_prompt(provider, "システム部分\n---\nユーザー部分")
        @test res isa LLMResponse
        @test !isempty(res.content)
    end

    @testset "complete_from_prompt: build_explain_prompt の出力を処理できる" begin
        rbc = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)
        irf_raw = impulse_response(rbc, 0.01)
        sr = to_simulation_result(rbc, irf_raw, "technology_shock")
        ctx = AnalysisContext(rbc, sr; shock_description = "1% tech shock")

        prompt = build_explain_prompt(ctx)
        provider = MockLLMProvider()
        res = complete_from_prompt(provider, prompt)
        @test res isa LLMResponse
        @test !isempty(res.content)
    end

    @testset "complete_from_prompt: build_data_comparison_prompt の出力を処理できる" begin
        rbc = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)
        irf_raw = impulse_response(rbc, 0.01)
        sr = to_simulation_result(rbc, irf_raw, "tech_shock")
        dcs = DataComparisonSummary(
            "FRED/GDPC1",
            (1, 40),
            Dict{String, Any}("overall_rmse" => 0.03),
            String[],
        )
        ctx = AnalysisContext(rbc, sr; data_comparison_summary = dcs)

        prompt = build_data_comparison_prompt(ctx)
        provider = MockLLMProvider()
        res = complete_from_prompt(provider, prompt)
        @test res isa LLMResponse
        @test !isempty(res.content)
    end

    @testset "complete_from_prompt: max_tokens/temperature オプションが渡せる" begin
        provider = MockLLMProvider()
        res = complete_from_prompt(provider, "prompt"; max_tokens = 100, temperature = 0.0)
        @test res isa LLMResponse
    end

    # === AbstractLLMProvider 未実装時のエラー ===

    @testset "AbstractLLMProvider: complete 未実装で LLMProviderError" begin
        struct _TestUnimplementedProvider <: AbstractLLMProvider end
        p = _TestUnimplementedProvider()
        req = LLMRequest("", "test")
        @test_throws LLMProviderError complete(p, req)
    end

end
