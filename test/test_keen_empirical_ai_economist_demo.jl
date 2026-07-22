# GR バックエンドをヘッドレスモードで動作させる（CI / 無表示環境対応）
ENV["GKSwstype"] = "nul"
using Plots
const JSON3 = DME.JSON3

# 例スクリプトは PROGRAM_FILE ガードで直接実行時のみ走る。include では
# run_keen_empirical_ai_economist などの関数定義のみ読み込まれる。
include(joinpath(@__DIR__, "..", "examples", "keen_empirical_ai_economist.jl"))

@testset "Keen 実証 AIエコノミスト統合デモ" begin
    fixture_dir = joinpath(@__DIR__, "fixtures", "keen")

    run_demo(dir; provider = nothing) = run_keen_empirical_ai_economist(;
        outdir = dir,
        mode = :fixture,
        fixture_dir = fixture_dir,
        provider = provider,
        verbose = false,
    )

    # ---- offline（provider なし）で外部接続せず完走する ------------------
    @testset "offline smoke: fixture + deterministic で完走" begin
        dir = mktempdir()
        r = run_demo(dir)
        # dataset 契約（固定 fixture の確定 shape）
        @test r.dataset.metadata["sample_start"] == "2000-Q1"
        @test r.dataset.metadata["sample_end"] == "2014-Q4"
        @test length(r.dataset) == 60
        # 説明成果物は provider なしなら常に deterministic
        @test r.keen_explanation.generation_status === :deterministic
        @test r.cross_explanation.generation_status === :deterministic
        @test r.provider_roundtrip_status == "not_invoked"
        # 期待する成果物がすべて生成され非空である
        for name in (
            "run_manifest.json",
            "keen_empirical_report.json",
            "keen_validation.json",
            "keen_calibration_config.json",
            "keen_ai_explanation.json",
            "cross_model_reasoning.json",
            "report.md",
            "keen_trajectories.png",
            "keen_regime_comparison.png",
            "keen_sensitivity_peak_debt.png",
            "keen_calibrated_diagnostics.png",
        )
            path = joinpath(dir, name)
            @test isfile(path)
            @test filesize(path) > 0
        end
    end

    # ---- 同一 fixture・seed で意味的に同一の数値・説明成果物が得られる ----
    @testset "決定性: 説明・クロスモデル・数値が一致" begin
        d1, d2 = mktempdir(), mktempdir()
        r1 = run_demo(d1)
        r2 = run_demo(d2)
        # 根拠付き説明・クロスモデル説明は section/claim/source まで一致
        @test to_dict(r1.keen_explanation) == to_dict(r2.keen_explanation)
        @test to_dict(r1.cross_explanation) == to_dict(r2.cross_explanation)
        # 推定結果の一致
        @test r1.result.calibration_result.estimated ==
              r2.result.calibration_result.estimated
        # manifest の数値・設定部分は一致（実行日時・code revision は provenance のため除外）
        volatile = ("run_timestamp", "code_revision")
        m1 = filter(kv -> !(kv.first in volatile), r1.manifest)
        m2 = filter(kv -> !(kv.first in volatile), r2.manifest)
        @test m1 == m2
    end

    # ---- provider（mock）経由の往復を実演しても保存物は deterministic ----
    @testset "provider 往復: 契約検証 fallback・保存物は deterministic" begin
        dir = mktempdir()
        r = run_demo(dir; provider = MockLLMProvider())
        # 汎用 mock 応答は keen 契約を満たさないため安全側 fallback になる
        @test r.provider_roundtrip_status == "fallback"
        # それでも保存する説明成果物は deterministic 生成を正とする
        @test r.keen_explanation.generation_status === :deterministic
        @test r.manifest["llm_provider"]["kind"] == "MockLLMProvider"
        @test r.manifest["llm_provider"]["uses_api"] == false
    end

    # ---- 機械可読成果物が parse 可能で必須メタデータを含む ---------------
    @testset "成果物 JSON の parse・必須メタデータ・NaN→null" begin
        dir = mktempdir()
        run_demo(dir)

        manifest = JSON3.read(read(joinpath(dir, "run_manifest.json"), String))
        for k in (
            "demo",
            "run_timestamp",
            "code_revision",
            "data_mode",
            "seed",
            "series",
            "methodology",
            "llm_provider",
            "explanation",
            "warnings",
        )
            @test haskey(manifest, k)
        end
        @test manifest["demo"] == "keen_empirical_ai_economist"
        @test manifest["data_mode"] == "fixture"
        @test Set(String.(keys(manifest["series"]))) == Set(["ω", "λ", "d", "r"])
        @test manifest["explanation"]["keen_generation_status"] == "deterministic"
        @test "private_debt_credit" in
              String.(manifest["explanation"]["insufficient_comparability"])

        # keen 説明 JSON: 契約・section・免責
        keen = JSON3.read(read(joinpath(dir, "keen_ai_explanation.json"), String))
        @test keen["contract_version"] == KEEN_AI_OUTPUT_CONTRACT_VERSION
        for sec in KEEN_OUTPUT_SECTION_ORDER
            @test haskey(keen, sec)
        end
        @test !isempty(keen["disclaimer"])

        # クロスモデル JSON: 契約・比較不能 section
        cross = JSON3.read(read(joinpath(dir, "cross_model_reasoning.json"), String))
        @test cross["contract_version"] == CROSS_MODEL_OUTPUT_CONTRACT_VERSION
        @test haskey(cross, "incomparable_or_insufficient")

        # 数値レポート: NaN は JSON では null（0 化しない）
        rep_txt = read(joinpath(dir, "keen_empirical_report.json"), String)
        @test !occursin("NaN", rep_txt)
    end

    # ---- secret 値が artifact に含まれない --------------------------------
    @testset "秘密値が artifact に含まれない" begin
        secret = "SECRET_AI_ECON_TOKEN_ZZZ_7788"
        prev_fred = get(ENV, "FRED_API_KEY", nothing)
        prev_openai = get(ENV, "OPENAI_API_KEY", nothing)
        ENV["FRED_API_KEY"] = secret
        ENV["OPENAI_API_KEY"] = secret
        try
            dir = mktempdir()
            run_demo(dir; provider = MockLLMProvider())
            for name in readdir(dir)
                txt = read(joinpath(dir, name), String)
                @test !occursin(secret, txt)
                @test !occursin("OPENAI_API_KEY", txt)
                @test !occursin("FRED_API_KEY", txt)
            end
        finally
            prev_fred === nothing ? delete!(ENV, "FRED_API_KEY") :
            (ENV["FRED_API_KEY"] = prev_fred)
            prev_openai === nothing ? delete!(ENV, "OPENAI_API_KEY") :
            (ENV["OPENAI_API_KEY"] = prev_openai)
        end
    end
end
