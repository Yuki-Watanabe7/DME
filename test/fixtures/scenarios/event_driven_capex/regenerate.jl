# regenerate.jl: `test/fixtures/scenarios/event_driven_capex/` の golden fixture 3種
# （Issue #205 / `E-9`。統合設計 §10.7）を決定的に再生成する。
#
# 使い方（リポジトリルートから）:
#   julia --project=. test/fixtures/scenarios/event_driven_capex/regenerate.jl
#
# `examples/event_driven_capex_scenario_demo.jl` の `_edcs_case_assumptions()`（PROGRAM_FILE
# ガードにより `include` では実行されず関数定義のみ読み込まれる）を再利用し、デモ本体が
# 実際に構築する assumptions と golden fixture を同一の入力から生成する（デモの変更が
# fixture の陳腐化に気づかれずに残ることを防ぐ）。
#
# 本ディレクトリの fixture は `"source":{"kind":"golden"}` を持ち、
# `test/test_event_driven_scenario_demo.jl` が実際にプログラム的に読み込む
# （`test/fixtures/events/`・`test/fixtures/scenarios/regenerate.jl` と同じ `Y-25` の規約）。

using DME
const JSON3 = DME.JSON3

const HERE = @__DIR__
const DEMO_SCRIPT =
    joinpath(HERE, "..", "..", "..", "..", "examples", "event_driven_capex_scenario_demo.jl")
include(DEMO_SCRIPT)

function write_canonical_json(relpath::String, d)
    path = joinpath(HERE, relpath)
    mkpath(dirname(path))
    bytes = canonical_json_bytes(d)
    open(path, "w") do io
        write(io, bytes)
    end
    println("wrote ", relpath)
end

cases = _edcs_case_assumptions()

# ------------------------------------------------------------
# baseline.json（events無し。正当な baseline、統合設計 §5.4 契約）
# ------------------------------------------------------------

sc_baseline = Scenario(;
    id = :edcs_baseline_golden,
    name = EDCS_CASE_NAMES[:baseline],
    model = :capex_credit_cycle,
    period_zero = EDCS_PERIOD_ZERO,
    assumptions = cases[:baseline],
    defaults_set_id = "event-driven-capex-scenario-demo",
    defaults_set_version = "1.0.0",
    notes = "Issue #205 統合デモの golden fixture（fictional、baseline）。",
)
write_canonical_json(
    "baseline.json",
    Dict{String, Any}(
        "source" => Dict{String, Any}(
            "kind" => "golden",
            "description" => "Issue #205 統合デモの baseline（eventなし）ケースと同一の " *
                              "assumptions から生成した golden fixture。プログラム的に読み込む " *
                              "（Y-25）。実在企業・実在イベントを参照しない。",
        ),
        "expected" => Dict{String, Any}("status" => "completed"),
        "scenario" => scenario_to_dict(sc_baseline),
    ),
)

# ------------------------------------------------------------
# positive_multi_event.json（policy_easing ケースと同一。完走する E2E シナリオ）
# ------------------------------------------------------------

sc_positive = Scenario(;
    id = :edcs_positive_golden,
    name = EDCS_CASE_NAMES[:policy_easing],
    model = :capex_credit_cycle,
    period_zero = EDCS_PERIOD_ZERO,
    assumptions = cases[:policy_easing],
    defaults_set_id = "event-driven-capex-scenario-demo",
    defaults_set_version = "1.0.0",
    notes = "Issue #205 統合デモの golden fixture（fictional、複数イベント合成の完走ケース）。",
)
write_canonical_json(
    "positive_multi_event.json",
    Dict{String, Any}(
        "source" => Dict{String, Any}(
            "kind" => "golden",
            "description" => "Issue #205 統合デモの policy_easing（累積8→9イベント）ケースと " *
                              "同一の assumptions から生成した golden fixture。" *
                              "on_unmapped=:warn（LendingStandardChange、D2）での実行を要する。" *
                              "プログラム的に読み込む（Y-25）。実在企業・実在イベントを参照しない。",
        ),
        "expected" => Dict{String, Any}(
            "status" => "completed",
            "on_unmapped" => "warn",
            "note" => "LendingStandardChange は unmapped_target（D2）のため on_unmapped=:warn " *
                      "でのみ完走する。既定 :reject では :rejected_mapping になる。",
        ),
        "scenario" => scenario_to_dict(sc_positive),
    ),
)

# ------------------------------------------------------------
# negative_unmapped.json（negative_unmapped ケースと同一。既定 :reject で fail closed）
# ------------------------------------------------------------

sc_negative = Scenario(;
    id = :edcs_negative_golden,
    name = EDCS_CASE_NAMES[:negative_unmapped],
    model = :capex_credit_cycle,
    period_zero = EDCS_PERIOD_ZERO,
    assumptions = cases[:negative_unmapped],
    defaults_set_id = "event-driven-capex-scenario-demo",
    defaults_set_version = "1.0.0",
    notes = "Issue #205 統合デモの golden fixture（fictional、unmapped_targetによるfail closed）。",
)
write_canonical_json(
    "negative_unmapped.json",
    Dict{String, Any}(
        "source" => Dict{String, Any}(
            "kind" => "golden",
            "description" => "Issue #205 統合デモの negative_unmapped ケースと同一の " *
                              "assumptions から生成した golden fixture。" *
                              "PriceOrMarginShock(S2)/RefinancingOrRatingEvent(maturity_wall)/" *
                              "EmploymentPlanRevision がいずれも unmapped_target（D1/D3/D4）と " *
                              "なり、既定 on_unmapped=:reject で :rejected_mapping となる。" *
                              "プログラム的に読み込む（Y-25）。実在企業・実在イベントを参照しない。",
        ),
        "expected" => Dict{String, Any}(
            "status" => "rejected_mapping",
            "unmapped_reasons" => ["D1", "D3", "D4"],
        ),
        "scenario" => scenario_to_dict(sc_negative),
    ),
)

# 生成直後に decode / run_scenario できることを自己確認する
m = capex_credit_cycle_model(capex_credit_cycle_default_targets())

for (relpath, expected_status) in (
    ("baseline.json", :completed),
    ("positive_multi_event.json", :completed),
    ("negative_unmapped.json", :rejected_mapping),
)
    fixture =
        DME._scenario_json_to_plain(JSON3.read(read(joinpath(HERE, relpath), String)))
    sc = scenario_from_dict(fixture["scenario"])
    options =
        get(fixture["expected"], "on_unmapped", "") == "warn" ?
        ScenarioRunOptions(; on_unmapped = :warn) : ScenarioRunOptions()
    run = run_scenario(m, sc; options = options)
    @assert run.status === expected_status "$(relpath): expected $(expected_status), got $(run.status)"
end
println("self-check ok")
