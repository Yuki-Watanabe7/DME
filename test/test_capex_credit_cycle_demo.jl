# 部門別CAPEX・信用循環モデル 統合デモ（examples/capex_credit_cycle_demo.jl）のテスト
# （Issue #186 / `I-8`）
#
# カバレッジ（統合設計 §8.5 の8項目）:
#   1. 例外なく完走し、5シナリオ（Sc0–Sc4）すべての結果を生成する
#   2. 2回実行して成果物JSONが完全一致する（決定性）
#   3. 成果物にmetadata予約キー20個が存在する
#   4. 成果物にAPIキー・トークンらしき文字列が含まれない
#   5. 成果物にDigital Twin/Digital Shadow/デジタルツインが含まれない（ADR 0014）
#   6. 成果物に統合設計 §8.4 の注意事項7件が含まれる
#   7. 全シナリオで会計検証12項目がacc_pass
#   8. ネットワークアクセスを行わない（FredClient/EStatClientを生成しない）

# GR バックエンドをヘッドレスモードで動作させる（CI / 無表示環境対応）
ENV["GKSwstype"] = "nul"
using Plots
const JSON3 = DME.JSON3

# 例スクリプトは PROGRAM_FILE ガードで直接実行時のみ走る。include では
# run_capex_credit_cycle_demo などの関数定義のみ読み込まれる。
const CAPEX_DEMO_SCRIPT_PATH =
    joinpath(@__DIR__, "..", "examples", "capex_credit_cycle_demo.jl")
include(CAPEX_DEMO_SCRIPT_PATH)

@testset "部門別CAPEX・信用循環モデル 統合デモ" begin
    run_demo(dir; make_plots = true) =
        run_capex_credit_cycle_demo(; outdir = dir, verbose = false, make_plots = make_plots)

    # ---- 1. 例外なく完走し、5シナリオすべての結果を生成する ----------------
    @testset "完走: 5シナリオすべての結果を生成し成果物が非空" begin
        dir = mktempdir()
        r = run_demo(dir)

        @test Set(keys(r.runs)) == Set(CAPEX_DEMO_SCENARIOS)
        @test Set(keys(r.diagnostics)) == Set(CAPEX_DEMO_SCENARIOS)
        @test Set(keys(r.accounting)) == Set(CAPEX_DEMO_SCENARIOS)
        for id in CAPEX_DEMO_SCENARIOS
            @test r.runs[id].termination_reason === :completed
        end

        for name in (
            "capex_scenario_Sc0.json",
            "capex_scenario_Sc1.json",
            "capex_scenario_Sc2.json",
            "capex_scenario_Sc3.json",
            "capex_scenario_Sc4.json",
            "capex_judgment_questions.json",
            "capex_comparison_v2.json",
            "capex_run_manifest.json",
            "report.md",
            "capex_sector_series_Sc3.png",
            "capex_scenario_comparison.png",
            "capex_diagnostic_label_Sc3.png",
            "capex_funding_pressure_Sc3.png",
        )
            path = joinpath(dir, name)
            @test isfile(path)
            @test filesize(path) > 0
        end
    end

    # ---- 2. 決定性: 2回実行して成果物JSONが完全一致する --------------------
    @testset "決定性: シナリオ・判定問題・比較API v2の成果物が完全一致" begin
        d1, d2 = mktempdir(), mktempdir()
        r1 = run_demo(d1; make_plots = false)
        r2 = run_demo(d2; make_plots = false)

        for name in (
            "capex_scenario_Sc0.json",
            "capex_scenario_Sc1.json",
            "capex_scenario_Sc2.json",
            "capex_scenario_Sc3.json",
            "capex_scenario_Sc4.json",
            "capex_judgment_questions.json",
            "capex_comparison_v2.json",
        )
            @test read(joinpath(d1, name), String) == read(joinpath(d2, name), String)
        end

        volatile = ("run_timestamp", "code_revision")
        m1 = filter(kv -> !(kv.first in volatile), r1.manifest)
        m2 = filter(kv -> !(kv.first in volatile), r2.manifest)
        @test m1 == m2
    end

    # ---- 3. metadata予約キー20個が成果物に存在する --------------------------
    @testset "metadata予約キー20個が全シナリオの reserved_metadata に存在する" begin
        dir = mktempdir()
        r = run_demo(dir; make_plots = false)

        reserved_keys = (
            "parameters",
            "variable_roles",
            "variable_sectors",
            "variable_units",
            "variable_timing",
            "variable_observability",
            "contract_version",
            "graph_version",
            "vars_version",
            "accounting_version",
            "boundaries_version",
            "equations_version",
            "empirical_version",
            "model_version",
            "scenario",
            "diagnostic_threshold_set",
            "termination_reason",
            "termination_period",
            "divergence_time",
            "warnings",
        )
        @test length(reserved_keys) == 20

        for id in CAPEX_DEMO_SCENARIOS
            meta = r.simulation_results[id].metadata
            for k in reserved_keys
                @test haskey(meta, k)
            end
        end

        manifest = JSON3.read(read(joinpath(dir, "capex_run_manifest.json"), String))
        for k in reserved_keys
            @test haskey(manifest["reserved_metadata"], k)
        end
    end

    # ---- 4. APIキー・トークンらしき文字列が成果物に含まれない --------------
    @testset "秘密値が成果物に含まれない" begin
        secret = "SECRET_CAPEX_DEMO_TOKEN_ZZZ_8831"
        prev_fred = get(ENV, "FRED_API_KEY", nothing)
        prev_openai = get(ENV, "OPENAI_API_KEY", nothing)
        ENV["FRED_API_KEY"] = secret
        ENV["OPENAI_API_KEY"] = secret
        try
            dir = mktempdir()
            run_demo(dir; make_plots = false)
            for name in readdir(dir)
                txt = read(joinpath(dir, name), String)
                @test !occursin(secret, txt)
                @test !occursin("FRED_API_KEY", txt)
                @test !occursin("OPENAI_API_KEY", txt)
            end
        finally
            prev_fred === nothing ? delete!(ENV, "FRED_API_KEY") :
            (ENV["FRED_API_KEY"] = prev_fred)
            prev_openai === nothing ? delete!(ENV, "OPENAI_API_KEY") :
            (ENV["OPENAI_API_KEY"] = prev_openai)
        end
    end

    # ---- 5. Digital Twin / Digital Shadow / デジタルツインが含まれない -----
    @testset "禁止表現（ADR 0014）が成果物に含まれない" begin
        dir = mktempdir()
        run_demo(dir; make_plots = false)
        forbidden = ("Digital Twin", "Digital Shadow", "デジタルツイン")
        for name in readdir(dir)
            endswith(name, ".png") && continue
            txt = read(joinpath(dir, name), String)
            for term in forbidden
                @test !occursin(term, txt)
            end
        end
        # スクリプト本体・テスト本体にも現れないことを確認する
        script_txt = read(CAPEX_DEMO_SCRIPT_PATH, String)
        for term in forbidden
            @test !occursin(term, script_txt)
        end
    end

    # ---- 6. 統合設計 §8.4 の注意事項7件が成果物に含まれる -------------------
    @testset "注意事項7件が manifest・report.md に含まれる" begin
        dir = mktempdir()
        r = run_demo(dir; make_plots = false)
        @test length(CAPEX_DEMO_NOTES) == 7

        manifest_notes = Set(String.(JSON3.read(
            read(joinpath(dir, "capex_run_manifest.json"), String),
        )["notes"]))
        @test manifest_notes == Set(CAPEX_DEMO_NOTES)

        report_txt = read(joinpath(dir, "report.md"), String)
        key_phrases = (
            "実データによる較正を経ていない",
            "broad_downturn",
            "反実仮想寄与",
            "倒産・信用イベントの予測ではない",
            "accounting_closure = :partial",
            "潜在変数であり",
            "投資判断・政策立案の根拠として使用することを意図していない",
        )
        for phrase in key_phrases
            @test occursin(phrase, report_txt)
        end
    end

    # ---- 7. 全シナリオで会計検証12項目がacc_pass ----------------------------
    @testset "全シナリオで会計検証12項目が acc_pass" begin
        dir = mktempdir()
        r = run_demo(dir; make_plots = false)
        @test r.all_accounting_pass
        for id in CAPEX_DEMO_SCENARIOS
            acc = r.accounting[id]
            @test accounting_passed(acc)
            @test acc.checks_performed > 0
            @test isempty(acc.violations)
        end
    end

    # ---- 8. ネットワークアクセスを行わない ----------------------------------
    @testset "FredClient・EStatClientを生成しない（ネットワーク非依存）" begin
        script_txt = read(CAPEX_DEMO_SCRIPT_PATH, String)
        @test !occursin("FredClient", script_txt)
        @test !occursin("EStatClient", script_txt)
        @test !occursin("HTTP.", script_txt)
    end

    # ---- 追加: Q2/Q3/Q4 の判定問題の回答が構造化されている ------------------
    @testset "判定問題の回答（Q2・Q3・Q4）が構造化されて出力される" begin
        dir = mktempdir()
        r = run_demo(dir; make_plots = false)
        j = r.judgment_questions
        @test haskey(j, "Q2_amplification")
        @test haskey(j, "Q3_share_C")
        @test haskey(j["Q3_share_C"], "Sc2")
        @test haskey(j["Q3_share_C"], "Sc3")
        @test haskey(j, "Q4_easing_containment")

        diag3 = r.diagnostics[:Sc3]
        if diag3.amplification !== nothing
            @test j["Q2_amplification"]["A"] ≈ diag3.amplification
        end
    end

    # ---- 追加: 比較API v2（mechanismモード）が同一モデル内シナリオ比較を返す -
    @testset "比較API v2（mechanismモード、Sc0 vs Sc3）" begin
        dir = mktempdir()
        r = run_demo(dir; make_plots = false)
        @test r.comparison_v2.mode === :mechanism
        @test r.comparison_v2.mechanism_diff !== nothing

        v2 = JSON3.read(read(joinpath(dir, "capex_comparison_v2.json"), String))
        @test v2["mode"] == "mechanism"
    end
end
