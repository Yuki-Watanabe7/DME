# `scenario_provenance.jl`/`scenario_serialization.jl`（Issue #203 / `E-7`）のテスト。
#
# 統合設計 §10.5（シリアライズ・replay、12項目）を中心に検証する。§10.4 の 11–13
# （`event_set_hash` の決定性・volatile field 除外・1ulp 感度）は既に
# `test_scenario_runner.jl` の「event_set_hash / scenario_content_hash: 決定性」testset が
# 対象とするため、本ファイルでは重複させない。
#
# ヘルパ（`_tsr_*`）は `test_scenario_runner.jl` のものを再利用する（`runtests.jl` が
# 逐次 `include` するため、同一 Main 名前空間で定義済み）。

using Dates: Date, DateTime
const JSON3 = DME.JSON3

# ------------------------------------------------------------
# テスト用ヘルパ（fictional。型写像の全パターンを網羅する assumption 群）
# ------------------------------------------------------------

function _tss_calendar_assumption(; id = "credit-cal")
    return scenario_assumption(;
        assumption_id = id,
        event_type = :CreditSpreadShock,
        sector = :unknown,
        direction = :up,
        magnitude = 40.0,
        unit = "bp",
        magnitude_source = :observed,
        application_mode = :additive,
        timing = EventTiming(;
            basis = :calendar,
            rule = :same_quarter,
            effective_from = Date(2026, 5, 15),
        ),
        persistence = PersistenceSpec(; shape = :ar1_decay, params = (half_life = 4,)),
        target_concepts = [:credit_spread],
        provenance = EventProvenance(;
            layer = :assumption,
            rule_id = "test-serialization-rule",
            rule_version = "1.0.0",
            generator = "test_scenario_serialization.jl",
            derived_from = ["fictional-source-cal"],
            generated_at = DateTime(2026, 3, 1, 12, 0, 0),
        ),
        confidence = 0.7,
        uncertainty = (0.5, 0.9),
        notes = "信用スプレッドの拡大（fictional・テスト用架空データ）",
        caveats = "実在企業・実在イベントを参照しない",
    )
end

function _tss_path_assumption(; id = "capex-path")
    return scenario_assumption(;
        assumption_id = id,
        event_type = :CapexGuidanceRevision,
        sector = :s1,
        direction = :up,
        magnitude = 3.0,
        unit = "%",
        magnitude_source = :derived,
        application_mode = :multiplicative,
        timing = EventTiming(; basis = :period, rule = :explicit_period, t_apply = 1),
        persistence = PersistenceSpec(;
            shape = :path,
            params = (values = [1.0, 2.0, 3.0],),
        ),
        target_concepts = [:capex_plan],
        provenance = EventProvenance(;
            layer = :assumption,
            rule_id = "test-serialization-rule",
            rule_version = "1.0.0",
            generator = "test_scenario_serialization.jl",
            derived_from = ["fictional-source-path"],
        ),
    )
end

function _tss_step_then_ramp_assumption(; id = "emp-str")
    return scenario_assumption(;
        assumption_id = id,
        event_type = :EmploymentPlanRevision,
        sector = :s1,
        direction = :down,
        magnitude = -4.0,
        unit = "%",
        magnitude_source = :assumed_default,
        application_mode = :multiplicative,
        timing = EventTiming(; basis = :period, rule = :explicit_period, t_apply = 2),
        persistence = PersistenceSpec(;
            shape = :step_then_ramp,
            params = (hold = 3, ramp_down = 2),
        ),
        target_concepts = [:employment_plan],
        provenance = EventProvenance(;
            layer = :assumption,
            rule_id = "test-serialization-rule",
            rule_version = "1.0.0",
            generator = "test_scenario_serialization.jl",
            derived_from = ["fictional-source-str"],
        ),
    )
end

function _tss_scenario(; id::Symbol = :test_serialization)
    return Scenario(;
        id = id,
        model = :capex_credit_cycle,
        period_zero = CalendarQuarter(2026, 1),
        assumptions = [
            _tsr_demand_assumption(; id = "demand-period"),
            _tss_calendar_assumption(),
            _tss_path_assumption(),
            _tss_step_then_ramp_assumption(),
        ],
        defaults_set_id = "test-defaults",
        defaults_set_version = "1.0.0",
        notes = "シリアライズ回帰テスト用の fictional シナリオ",
    )
end

@testset "scenario_provenance.jl / scenario_serialization.jl（Issue #203 / E-7）" begin
    targets = capex_credit_cycle_default_targets()
    m = capex_credit_cycle_model(targets)

    @testset "項目1: encode → decode → encode が正準に一致する" begin
        sc = _tss_scenario()
        d1 = scenario_to_dict(sc)
        sc2 = scenario_from_dict(d1)
        d2 = scenario_to_dict(sc2)
        @test canonical_json_bytes(d1) == canonical_json_bytes(d2)
    end

    @testset "項目2: ASCII キー・日本語の値が round-trip する" begin
        sc = _tss_scenario()
        d = scenario_to_dict(sc)
        # 全キーが ASCII であることは canonical_json_bytes 自体が強制する
        # （非ASCIIキーがあれば ArgumentError、json_canonical.jl `_jcs_check_key_ascii`）
        bytes = canonical_json_bytes(d)
        sc2 = scenario_from_dict(d)
        cal = only(a for a in sc2.assumptions if a.assumption_id == "credit-cal")
        @test cal.notes == "信用スプレッドの拡大（fictional・テスト用架空データ）"
        @test occursin("信用スプレッドの拡大", String(bytes))
    end

    @testset "項目3: Symbol/Date/DateTime/missing/nothing/Tuple の型写像が可逆" begin
        sc = _tss_scenario()
        sc2 = scenario_from_dict(scenario_to_dict(sc))

        demand = only(a for a in sc2.assumptions if a.assumption_id == "demand-period")
        @test demand.event_type === :DemandOutlookRevision  # Symbol
        @test demand.confidence === nothing                 # nothing

        cal = only(a for a in sc2.assumptions if a.assumption_id == "credit-cal")
        @test cal.timing.effective_from == Date(2026, 5, 15)              # Date
        @test cal.provenance.generated_at == DateTime(2026, 3, 1, 12, 0, 0) # DateTime
        @test cal.uncertainty == (0.5, 0.9)                                # Tuple

        path_a = only(a for a in sc2.assumptions if a.assumption_id == "capex-path")
        @test path_a.persistence.params.values == [1.0, 2.0, 3.0]

        str_a = only(a for a in sc2.assumptions if a.assumption_id == "emp-str")
        @test str_a.persistence.params.hold == 3
        @test str_a.persistence.params.ramp_down == 2
    end

    @testset "項目4: 未知 schema_version が ArgumentError" begin
        sc = _tss_scenario()
        d = scenario_to_dict(sc)
        d2 = copy(d)
        d2["schema_version"] = "dme.scenario/9.9.9"
        @test_throws ArgumentError scenario_from_dict(d2)
    end

    @testset "項目5: 必須フィールド欠損が ArgumentError（欠損キー名を列挙）" begin
        sc = _tss_scenario()
        d = scenario_to_dict(sc)
        d2 = copy(d)
        delete!(d2, "horizon_eval")
        err = try
            scenario_from_dict(d2)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("horizon_eval", err.msg)
    end

    @testset "項目6: hash 改竄（値を1文字変更）が ArgumentError" begin
        sc = _tss_scenario()
        d = scenario_to_dict(sc)
        d2 = copy(d)
        tampered = collect(d2["event_set_hash"])
        tampered[end] = tampered[end] == '0' ? '1' : '0'
        d2["event_set_hash"] = String(tampered)
        @test_throws ArgumentError scenario_from_dict(d2)
    end

    @testset "項目7: 未知キーの混入が ArgumentError（schema drift 検出）" begin
        sc = _tss_scenario()
        d = scenario_to_dict(sc)
        d2 = copy(d)
        d2["unknown_extra_field"] = "x"
        @test_throws ArgumentError scenario_from_dict(d2)

        a1 = copy(d["assumptions"][1])
        a1["unknown_extra_field"] = "x"
        @test_throws ArgumentError DME._scenario_assumption_from_dict(a1)
    end

    @testset "項目8・9: save_scenario_artifact → replay_scenario" begin
        mktempdir() do dir
            sc = _tsr_scenario(;
                id = :replay_test,
                assumptions = [
                    _tsr_demand_assumption(; id = "r1", magnitude = 4.0),
                    _tsr_credit_assumption(; id = "r2", magnitude = 30.0, t_apply = 2),
                ],
            )
            run1 = run_scenario(m, sc)
            @test run1.status === :completed

            paths = save_scenario_artifact(dir, run1)
            @test length(paths) == 6  # comparison.json は省略（baseline未指定）
            for fname in (
                "scenario.json",
                "observed_events.json",
                "event_log.json",
                "manifest.json",
                "result_summary.json",
                "report.md",
            )
                @test isfile(joinpath(dir, fname))
            end
            @test !isfile(joinpath(dir, "comparison.json"))

            replayed = replay_scenario(m, joinpath(dir, "scenario.json"))
            @test replayed.status === :completed
            @test replayed.exog == run1.exog
            @test replayed.result.variables == run1.result.variables
            @test [w.code for w in replayed.warnings] == [w.code for w in run1.warnings]
        end
    end

    @testset "項目9: params_hash 不一致の replay が ArgumentError" begin
        mktempdir() do dir
            sc = _tsr_scenario(; id = :replay_mismatch)
            run1 = run_scenario(m, sc)
            save_scenario_artifact(dir, run1)

            manifest_path = joinpath(dir, "manifest.json")
            manifest_text = read(manifest_path, String)
            tampered =
                replace(manifest_text, run1.provenance.params_hash => "sha256:" * "0"^64)
            write(manifest_path, tampered)

            @test_throws ArgumentError replay_scenario(m, joinpath(dir, "scenario.json"))
        end
    end

    @testset "項目10: 成果物に秘密情報・ローカル絶対パスが含まれない" begin
        mktempdir() do dir
            sc = _tsr_scenario(;
                id = :leak_check,
                assumptions = [_tsr_demand_assumption(; id = "leak-1")],
            )
            run1 = run_scenario(m, sc)
            paths = save_scenario_artifact(dir, run1)
            local_marker = homedir()
            for p in paths
                content = read(p, String)
                @test !occursin(local_marker, content)
                @test !occursin(r"sk-[A-Za-z0-9]{16,}"i, content)
                @test !occursin(r"api[_-]?key"i, content)
                @test !occursin(r"bearer\s+[A-Za-z0-9._-]{8,}"i, content)
            end
        end
    end

    @testset "項目11: 成果物に Digital Twin / Digital Shadow / デジタルツイン が含まれない" begin
        mktempdir() do dir
            sc = _tsr_scenario(;
                id = :dt_check,
                assumptions = [_tsr_demand_assumption(; id = "dt-1")],
            )
            run1 = run_scenario(m, sc)
            paths = save_scenario_artifact(dir, run1)
            for p in paths
                content = read(p, String)
                @test !occursin("Digital Twin", content)
                @test !occursin("Digital Shadow", content)
                @test !occursin("デジタルツイン", content)
            end
        end
    end

    @testset "項目12: golden fixture（source.kind == \"golden\"）" begin
        fixture_path =
            joinpath(@__DIR__, "fixtures", "scenarios", "event_driven_capex_golden.json")
        @test isfile(fixture_path)
        fixture = DME._scenario_json_to_plain(JSON3.read(read(fixture_path, String)))
        @test fixture["source"]["kind"] == "golden"
        @test fixture["source"]["kind"] != "illustrative"
        sc = scenario_from_dict(fixture["scenario"])
        @test sc.id === :event_driven_capex_golden
        @test !isempty(sc.assumptions)
        # 再エンコードが fixture の scenario 部分と正準一致する（golden 値からの回帰検出）
        @test canonical_json_bytes(scenario_to_dict(sc)) ==
              canonical_json_bytes(fixture["scenario"])
    end

    @testset "manifest.json の内容（統合設計 §9.5）" begin
        mktempdir() do dir
            sc = _tsr_scenario(;
                id = :manifest_check,
                assumptions = [_tsr_demand_assumption(; id = "man-1")],
            )
            run1 = run_scenario(m, sc)
            save_scenario_artifact(dir, run1)
            manifest = DME._scenario_json_to_plain(
                JSON3.read(read(joinpath(dir, "manifest.json"), String)),
            )
            @test manifest["schema_version"] == SCENARIO_ARTIFACT_SCHEMA_VERSION
            @test manifest["status"] == "completed"
            @test manifest["params_hash"] == run1.provenance.params_hash
            @test manifest["initial_state_id"] == run1.provenance.initial_state_id
            @test manifest["solver_settings_hash"] == run1.provenance.solver_settings_hash
            @test manifest["event_set_hash"] == run1.provenance.event_set_hash
            @test manifest["warnings_count"] == length(run1.warnings)
            @test manifest["rejections_count"] == length(run1.rejections)
        end
    end

    @testset "save_scenario_artifact: rejected run（schedule===nothing）で event_log が空" begin
        mktempdir() do dir
            sc = _tsr_scenario(;
                id = :rejected_check,
                assumptions = [_tsr_employment_assumption()],
            )
            run1 = run_scenario(m, sc)
            @test run1.status === :rejected_mapping
            @test run1.schedule === nothing
            paths = save_scenario_artifact(dir, run1)
            event_log = DME._scenario_json_to_plain(
                JSON3.read(read(joinpath(dir, "event_log.json"), String)),
            )
            @test isempty(event_log["event_log"])
            result_summary = DME._scenario_json_to_plain(
                JSON3.read(read(joinpath(dir, "result_summary.json"), String)),
            )
            @test result_summary["metadata"] === nothing
            @test result_summary["variables"] === nothing
        end
    end

    @testset "scenario_event_log: order_key 昇順・shuffle 不変" begin
        sc = _tsr_scenario(;
            assumptions = [
                _tsr_demand_assumption(; id = "s1", magnitude = 2.0, t_apply = 3),
                _tsr_credit_assumption(; id = "s2", magnitude = 15.0, t_apply = 1),
                _tsr_demand_assumption(; id = "s3", magnitude = -1.0, t_apply = 1),
            ],
        )
        run1 = run_scenario(m, sc)
        @test run1.status === :completed
        log = scenario_event_log(run1.schedule)
        expected_order =
            [e.input_id for e in sort(run1.schedule.log; by = e -> e.order_key)]
        @test [e["input_id"] for e in log] == expected_order

        sc_reordered = _tsr_scenario(;
            assumptions = [
                _tsr_demand_assumption(; id = "s3", magnitude = -1.0, t_apply = 1),
                _tsr_credit_assumption(; id = "s2", magnitude = 15.0, t_apply = 1),
                _tsr_demand_assumption(; id = "s1", magnitude = 2.0, t_apply = 3),
            ],
        )
        run2 = run_scenario(m, sc_reordered)
        @test scenario_event_log(run1.schedule) == scenario_event_log(run2.schedule)
    end
end
