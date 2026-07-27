# SFC対応 AIエコノミスト統合デモ（examples/sfc_ai_economist_demo.jl）のテスト（Issue #152）
#
# カバレッジ（Issue #152 受け入れ条件）:
#   - offline 完走と成果物存在（乱数を使わず API キー不要）
#   - 同一 config で決定的な JSON・説明を生成
#   - 全期会計 check pass
#   - 意図的な不整合 fixture ではデモが依拠する検証層が正常扱いしない（警告/fail を返す）
#   - 比較不能概念へ数値 metric を生成しない
#   - secret 非混入・NaN の JSON 安全表現・manifest の必須 metadata

# GR バックエンドをヘッドレスモードで動作させる（CI / 無表示環境対応）
ENV["GKSwstype"] = "nul"
using Plots
const JSON3 = DME.JSON3

# 例スクリプトは PROGRAM_FILE ガードで直接実行時のみ走る。include では
# run_sfc_ai_economist などの関数定義のみ読み込まれる。
include(joinpath(@__DIR__, "..", "examples", "sfc_ai_economist_demo.jl"))

@testset "SFC対応 AIエコノミスト統合デモ" begin
    run_demo(dir; provider = nothing) =
        run_sfc_ai_economist(; outdir = dir, provider = provider, verbose = false)

    # ---- offline（provider なし）で外部接続・乱数なしに完走する -----------
    @testset "offline smoke: 決定的に完走し全成果物が非空" begin
        dir = mktempdir()
        r = run_demo(dir)

        @test r.ksfc_explanation.generation_status === :deterministic
        @test r.provider_roundtrip_status == "not_invoked"

        for name in (
            "sfc_result_baseline.json",
            "sfc_result_fiscal_shock.json",
            "accounting_checks.json",
            "model_capabilities.json",
            "comparison_v2.json",
            "keen_sfc_comparison.json",
            "keen_sfc_explanation.json",
            "run_manifest.json",
            "report.md",
            "sfc_baseline_trajectories.png",
            "sfc_fiscal_shock_trajectories.png",
            "sfc_household_wealth_comparison.png",
        )
            path = joinpath(dir, name)
            @test isfile(path)
            @test filesize(path) > 0
        end
    end

    # ---- 全期会計 check pass（#147 の検証がデモのシナリオで実際に通ること）
    @testset "全期会計 check pass" begin
        dir = mktempdir()
        r = run_demo(dir)
        @test accounting_passed(r.acc_baseline)
        @test accounting_passed(r.acc_shock)
        @test r.acc_baseline.checks_performed > 0
        @test r.acc_shock.checks_performed > 0
    end

    # ---- 同一 config で意味的に同一の数値・説明成果物が得られる（決定性）--
    @testset "決定性: 説明・比較レポート・manifest が一致" begin
        d1, d2 = mktempdir(), mktempdir()
        r1 = run_demo(d1)
        r2 = run_demo(d2)
        @test to_dict(r1.ksfc_explanation) == to_dict(r2.ksfc_explanation)
        @test to_dict(r1.ksfc_report) == to_dict(r2.ksfc_report)
        @test to_dict(r1.comparison_v2) == to_dict(r2.comparison_v2)
        @test to_dict(r1.acc_baseline) == to_dict(r2.acc_baseline)

        volatile = ("run_timestamp", "code_revision")
        m1 = filter(kv -> !(kv.first in volatile), r1.manifest)
        m2 = filter(kv -> !(kv.first in volatile), r2.manifest)
        @test m1 == m2
    end

    # ---- provider（mock）往復: 契約検証 fallback・保存物は deterministic --
    @testset "provider 往復: 契約検証 fallback・保存物は deterministic" begin
        dir = mktempdir()
        r = run_demo(dir; provider = MockLLMProvider())
        # 汎用 mock 応答はクロスモデル推論の契約を満たさないため安全側 fallback になる
        @test r.provider_roundtrip_status == "fallback"
        @test r.ksfc_explanation.generation_status === :deterministic
        @test r.manifest["llm_provider"]["kind"] == "MockLLMProvider"
        @test r.manifest["llm_provider"]["uses_api"] == false
    end

    # ---- 比較不能概念へ数値 metric を生成しない -----------------------------
    @testset "比較不能概念へ数値 metric を生成しない" begin
        dir = mktempdir()
        r = run_demo(dir)
        report = r.ksfc_report
        numeric_keys = Set(String.(keys(report.numeric_comparisons)))
        for c in report.incomparable_concepts
            @test !(String(c.concept) in numeric_keys)
        end
        for indicator in keen_sfc_sim_unavailable_indicators()
            @test !(indicator in numeric_keys)
        end
    end

    # ---- 機械可読成果物が parse 可能で必須メタデータを含む -----------------
    @testset "成果物 JSON の parse・必須メタデータ・契約 version" begin
        dir = mktempdir()
        run_demo(dir)

        manifest = JSON3.read(read(joinpath(dir, "run_manifest.json"), String))
        for k in (
            "demo",
            "run_timestamp",
            "code_revision",
            "scenario",
            "accounting",
            "methodology",
            "llm_provider",
            "explanation",
            "warnings",
        )
            @test haskey(manifest, k)
        end
        @test manifest["demo"] == "sfc_ai_economist"
        @test manifest["accounting"]["baseline_passed"] == true
        @test manifest["accounting"]["fiscal_shock_passed"] == true
        @test manifest["methodology"]["sfc_contract"] == SFC_CONTRACT_VERSION
        @test manifest["methodology"]["keen_sfc_comparison_contract"] ==
              KEEN_SFC_COMPARISON_CONTRACT_VERSION
        @test manifest["explanation"]["generation_status"] == "deterministic"
        @test "private_debt" in String.(manifest["explanation"]["incomparable_concepts"])

        acc = JSON3.read(read(joinpath(dir, "accounting_checks.json"), String))
        @test acc["baseline"]["status"] == "pass"
        @test acc["fiscal_shock"]["status"] == "pass"

        cap = JSON3.read(read(joinpath(dir, "model_capabilities.json"), String))
        @test haskey(cap, "sim")
        @test haskey(cap, "keen")

        v2 = JSON3.read(read(joinpath(dir, "comparison_v2.json"), String))
        @test v2["mode"] == "trajectory"

        ksfc = JSON3.read(read(joinpath(dir, "keen_sfc_comparison.json"), String))
        @test ksfc["contract_version"] == KEEN_SFC_COMPARISON_CONTRACT_VERSION

        expl = JSON3.read(read(joinpath(dir, "keen_sfc_explanation.json"), String))
        @test expl["contract_version"] == DME.CROSS_MODEL_OUTPUT_CONTRACT_VERSION
        for sec in DME.CROSS_MODEL_OUTPUT_SECTION_ORDER
            @test haskey(expl, sec)
        end
        @test !isempty(expl["disclaimer"])
    end

    # ---- 意図的な不整合 fixture: デモが依拠する検証層は正常扱いしない -----
    @testset "意図的な不整合 fixture では警告・fail を返す" begin
        dir = mktempdir()
        r = run_demo(dir)

        # baseline の SFCResult を壊す（会計恒等式が破れるよう貸借対照表の一部を改変）
        d = to_dict(r.baseline_sfc)
        snap1 = d["snapshots"][1]
        bs = snap1["balance_sheet"]
        bs["holdings"][1][1] = bs["holdings"][1][1] + 999.0  # 行和が 0 でなくなる
        broken = sfc_result_from_dict(d)

        broken_report = validate_sfc_accounting(broken)
        @test !accounting_passed(broken_report)
        @test broken_report.status in (acc_fail, acc_invalid)

        ksfc_broken = compare_keen_sfc(;
            sim_result = broken.simulation_result,
            accounting_report = broken_report,
        )
        @test any(occursin("会計恒等式検証に違反", w) for w in ksfc_broken.warnings)
    end

    # ---- secret 値が artifact に含まれない --------------------------------
    @testset "秘密値が artifact に含まれない" begin
        secret = "SECRET_SFC_AI_ECON_TOKEN_ZZZ_9911"
        prev_openai = get(ENV, "OPENAI_API_KEY", nothing)
        ENV["OPENAI_API_KEY"] = secret
        try
            dir = mktempdir()
            run_demo(dir; provider = MockLLMProvider())
            for name in readdir(dir)
                txt = read(joinpath(dir, name), String)
                @test !occursin(secret, txt)
                @test !occursin("OPENAI_API_KEY", txt)
            end
        finally
            prev_openai === nothing ? delete!(ENV, "OPENAI_API_KEY") :
            (ENV["OPENAI_API_KEY"] = prev_openai)
        end
    end
end
