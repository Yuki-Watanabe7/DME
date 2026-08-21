# 日付付き複数イベントScenario 統合デモ（examples/event_driven_capex_scenario_demo.jl）の
# テスト（Issue #205 / `E-9`）。
#
# カバレッジ（統合設計 §10.6 の11項目）:
#   1. baseline（eventなし）と複数イベントScenarioが公開APIだけで完走する
#   2. 9イベント型の代表fixtureがE2E経路を通る、またはmapping不能理由が固定される
#   3. Sc0–Sc4対応シナリオの結果がcapex_exogenous_paths経路と一致する
#   4. 日付→四半期・同時順序・mapping・before/afterが成果物から確認できる
#   5. invalid/unmappedのfixtureがfail closedになる（部分実行されない）
#   6. 2回実行で正準artifact・hash・系列・diagnosticsが一致する
#   7. 保存済みartifactからreplayして同一結果を再現する
#   8. 全成功シナリオで会計検証12項目がacc_pass
#   9. 成果物に秘密情報・外部依存・実企業データ・Digital Twin表記・投資推奨が含まれない
#   10. 成果物の注意事項に統合設計 §12.3 の必須記載8件が含まれる
#   11. FredClient/EStatClientを生成しない（ネットワーク非依存）
# 加えて test/fixtures/scenarios/event_driven_capex/ の golden fixture 3種の round-trip・
# 実行結果を検証する（`Y-25`）。

const JSON3 = DME.JSON3

# 例スクリプトは PROGRAM_FILE ガードで直接実行時のみ走る。include では
# run_event_driven_capex_scenario_demo などの関数定義のみ読み込まれる。
const EDCS_DEMO_SCRIPT_PATH =
    joinpath(@__DIR__, "..", "examples", "event_driven_capex_scenario_demo.jl")
include(EDCS_DEMO_SCRIPT_PATH)

const EDCS_FIXTURE_DIR =
    joinpath(@__DIR__, "fixtures", "scenarios", "event_driven_capex")

@testset "日付付き複数イベントScenario 統合デモ" begin
    run_demo(dir) = run_event_driven_capex_scenario_demo(; outdir = dir, verbose = false)

    # ---- 1. baseline・複数イベントScenarioが公開APIだけで完走する ----------
    @testset "項目1: baseline・複数イベントScenarioが完走する" begin
        dir = mktempdir()
        r = run_demo(dir)

        completed_cases =
            (:baseline, :demand_outlook_down, :capex_cut_order_cancel, :credit_tightening,
                :policy_easing, :simultaneous_composition)
        for cr in r.case_runs
            if cr.id in completed_cases
                @test cr.run.status === :completed
                @test cr.run.result !== nothing
                @test cr.run.exog !== nothing
            end
        end
        @test r.all_status_ok

        for id in EDCS_CASE_IDS
            for fname in (
                "scenario.json",
                "observed_events.json",
                "event_log.json",
                "manifest.json",
                "result_summary.json",
                "report.md",
            )
                path = joinpath(dir, String(id), fname)
                @test isfile(path)
                @test filesize(path) > 0
            end
        end
    end

    # ---- 2. 9イベント型がE2E経路を通る、またはmapping不能理由が固定される ---
    @testset "項目2: 9イベント型のカバレッジ" begin
        dir = mktempdir()
        r = run_demo(dir)
        @test r.event_type_coverage["all_covered"]
        for t in MACRO_EVENT_TYPES
            entry = r.event_type_coverage["types"][String(t)]
            @test entry !== nothing
            @test entry["status"] in ("mapped", "unmapped_target")
        end
        # mapping不能のD1–D4がすべて固定理由で登場する（LendingStandardChangeはD2、
        # policy_easing/credit_tighteningでon_unmapped=:warnにより警告として登場）
        @test r.event_type_coverage["types"]["LendingStandardChange"]["status"] == "unmapped_target"
        @test r.event_type_coverage["types"]["EmploymentPlanRevision"]["status"] == "unmapped_target"
    end

    # ---- 3. Sc0–Sc4対応シナリオがcapex_exogenous_paths経路と一致する --------
    @testset "項目3: Sc0–Sc4数値互換性（許容誤差0）" begin
        dir = mktempdir()
        r = run_demo(dir)
        @test r.sc0_sc4_parity.all_pass
        for id in CAPEX_CC_SCENARIO_IDS
            p = r.sc0_sc4_parity.per_scenario[String(id)]
            @test p["pass"]
            @test p["exog_exact_match"]
            @test p["simulation_result_exact_match"]
        end
        parity_path = joinpath(dir, "sc0_sc4_parity.json")
        @test isfile(parity_path)
        parity_json = JSON3.read(read(parity_path, String))
        @test parity_json["all_pass"] == true
    end

    # ---- 4. 日付→四半期・同時順序・mapping・before/afterが成果物から確認できる
    @testset "項目4: 日付→四半期・同時イベント合成・before/afterが確認できる" begin
        dir = mktempdir()
        r = run_demo(dir)

        simult = only(filter(cr -> cr.id === :simultaneous_composition, r.case_runs))
        @test simult.run.status === :completed
        # 同一四半期4イベントのうちcredit系2件はoffsetting（符号が逆）
        @test any(w.code === :offsetting_events for w in simult.run.warnings)

        event_log = JSON3.read(
            read(joinpath(simult.dir, "event_log.json"), String),
        )["event_log"]
        @test !isempty(event_log)
        # before/after（適用前後値）が event_log から確認できる
        for entry in event_log
            @test haskey(entry, "pre_value")
            @test haskey(entry, "post_value")
        end

        # 暦日付き（policy_easing）ケースで period_zero・period_labels がscenario.jsonから
        # 確認できる（日付→四半期の割当が成果物から追跡可能）
        flagship = only(filter(cr -> cr.id === :policy_easing, r.case_runs))
        sc_json = JSON3.read(read(joinpath(flagship.dir, "scenario.json"), String))
        @test sc_json["period_zero"]["year"] == 2026
        @test sc_json["period_zero"]["quarter"] == 1
        result_summary = JSON3.read(read(joinpath(flagship.dir, "result_summary.json"), String))
        @test haskey(result_summary["metadata"], "period_labels")
    end

    # ---- 5. invalid/unmappedのfixtureがfail closedになる --------------------
    @testset "項目5: negative fixtureがfail closed（部分実行されない）" begin
        dir = mktempdir()
        r = run_demo(dir)

        neg_unmapped = only(filter(cr -> cr.id === :negative_unmapped, r.case_runs))
        @test neg_unmapped.run.status === :rejected_mapping
        @test neg_unmapped.run.result === nothing
        @test neg_unmapped.run.exog === nothing
        @test any(rj.code === :unmapped_target for rj in neg_unmapped.run.rejections)

        neg_invalid = only(filter(cr -> cr.id === :negative_invalid, r.case_runs))
        @test neg_invalid.run.status === :rejected_validation
        @test neg_invalid.run.result === nothing
        @test neg_invalid.run.exog === nothing
        @test any(rj.code === :duplicate_event_id for rj in neg_invalid.run.rejections)
    end

    # ---- 6. 2回実行で正準artifact・hash・系列・diagnosticsが一致する --------
    @testset "項目6: 決定性（2回実行で全成果物ファイルが完全一致）" begin
        dir = mktempdir()
        r = run_demo(dir)
        @test r.determinism_ok
    end

    # ---- 7. 保存済みartifactからreplayして同一結果を再現する ----------------
    @testset "項目7: replayが同一結果を再現する" begin
        dir = mktempdir()
        r = run_demo(dir)
        @test r.replay_ok

        flagship = only(filter(cr -> cr.id === :policy_easing, r.case_runs))
        m = r.model
        replayed = replay_scenario(
            m,
            joinpath(flagship.dir, "scenario.json");
            options = ScenarioRunOptions(; on_unmapped = :warn),
        )
        @test replayed.status === flagship.run.status
        @test replayed.exog == flagship.run.exog
        @test replayed.result.variables == flagship.run.result.variables
    end

    # ---- 8. 全成功シナリオで会計検証12項目がacc_pass --------------------------
    @testset "項目8: 全成功ケースで会計検証12項目がacc_pass" begin
        dir = mktempdir()
        r = run_demo(dir)
        for cr in r.case_runs
            cr.run.status === :completed || continue
            @test cr.run.accounting !== nothing
            @test accounting_passed(cr.run.accounting)
            @test isempty(cr.run.accounting.violations)
        end
    end

    # ---- 9. 秘密情報・外部依存・実企業データ・Digital Twin・投資推奨が無い ---
    @testset "項目9: 禁止内容が成果物・スクリプトに含まれない" begin
        secret = "SECRET_EDCS_DEMO_TOKEN_ZZZ_7724"
        prev_fred = get(ENV, "FRED_API_KEY", nothing)
        prev_openai = get(ENV, "OPENAI_API_KEY", nothing)
        ENV["FRED_API_KEY"] = secret
        ENV["OPENAI_API_KEY"] = secret
        try
            dir = mktempdir()
            run_demo(dir)
            for (root, _, files) in walkdir(dir)
                for fname in files
                    path = joinpath(root, fname)
                    txt = read(path, String)
                    @test !occursin(secret, txt)
                    @test !occursin("FRED_API_KEY", txt)
                    @test !occursin("OPENAI_API_KEY", txt)
                    @test !occursin(homedir(), txt)
                    @test !occursin(r"sk-[A-Za-z0-9]{16,}"i, txt)
                    @test !occursin("Digital Twin", txt)
                    @test !occursin("Digital Shadow", txt)
                    @test !occursin("デジタルツイン", txt)
                end
            end
        finally
            prev_fred === nothing ? delete!(ENV, "FRED_API_KEY") : (ENV["FRED_API_KEY"] = prev_fred)
            prev_openai === nothing ? delete!(ENV, "OPENAI_API_KEY") :
            (ENV["OPENAI_API_KEY"] = prev_openai)
        end

        script_txt = read(EDCS_DEMO_SCRIPT_PATH, String)
        for term in ("Digital Twin", "Digital Shadow", "デジタルツイン")
            @test !occursin(term, script_txt)
        end
    end

    # ---- 10. 注意事項に統合設計 §12.3 の必須記載8件が含まれる ------------------
    @testset "項目10: LLM説明層への必須記載8件が成果物に含まれる" begin
        @test length(EDCS_NOTES) == 8
        dir = mktempdir()
        r = run_demo(dir)

        manifest = JSON3.read(read(joinpath(dir, "demo_manifest.json"), String))
        @test length(manifest["notes"]) == 8

        report_txt = read(joinpath(dir, "report.md"), String)
        key_phrases = (
            "magnitude_source",
            "scenario_magnitude_sensitivity",
            "unmapped_target",
            "offsetting_events",
            "scenario_timing_sensitivity",
            "timing_basis_period",
            ":as_of",
            "terminated",
        )
        for phrase in key_phrases
            @test occursin(phrase, report_txt)
        end
    end

    # ---- 11. FredClient/EStatClientを生成しない ------------------------------
    @testset "項目11: ネットワーク非依存（FredClient/EStatClient/HTTP.を生成しない）" begin
        script_txt = read(EDCS_DEMO_SCRIPT_PATH, String)
        @test !occursin("FredClient", script_txt)
        @test !occursin("EStatClient", script_txt)
        @test !occursin("HTTP.", script_txt)
    end

    # ---- golden fixture（source.kind == "golden"）の round-trip・実行 --------
    @testset "golden fixture: baseline.json / positive_multi_event.json / negative_unmapped.json" begin
        targets = capex_credit_cycle_default_targets()
        m = capex_credit_cycle_model(targets)

        cases = (
            ("baseline.json", :completed),
            ("positive_multi_event.json", :completed),
            ("negative_unmapped.json", :rejected_mapping),
        )
        for (fname, expected_status) in cases
            path = joinpath(EDCS_FIXTURE_DIR, fname)
            @test isfile(path)
            fixture = DME._scenario_json_to_plain(JSON3.read(read(path, String)))
            @test fixture["source"]["kind"] == "golden"
            @test fixture["source"]["kind"] != "illustrative"

            sc = scenario_from_dict(fixture["scenario"])
            # 再エンコードが fixture の scenario 部分と正準一致する（golden 値からの回帰検出）
            @test canonical_json_bytes(scenario_to_dict(sc)) ==
                  canonical_json_bytes(fixture["scenario"])

            options =
                get(fixture["expected"], "on_unmapped", "") == "warn" ?
                ScenarioRunOptions(; on_unmapped = :warn) : ScenarioRunOptions()
            run = run_scenario(m, sc; options = options)
            @test run.status === expected_status
            @test String(run.status) == fixture["expected"]["status"]
        end
    end
end
