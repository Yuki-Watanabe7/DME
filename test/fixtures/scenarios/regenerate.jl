# regenerate.jl: `event_driven_capex_golden.json`（scenario_to_dict の round-trip / decode
# 回帰テスト用 golden fixture、Issue #203 / `E-7`）を決定的に再生成する。
#
# 使い方（リポジトリルートから）:
#   julia --project=. test/fixtures/scenarios/regenerate.jl
#
# `test/fixtures/events/` 配下の `"source":{"kind":"illustrative"}` fixture（人間向け参考
# 資料であり、プログラム的には読み込まない）と異なり、本ファイルが生成する fixture は
# `"source":{"kind":"golden"}` を持ち、`test/test_scenario_serialization.jl` が実際に
# 読み込んで `scenario_from_dict` の decode・round-trip 回帰を検証する（`Y-25`）。
#
# 4種の `PersistenceSpec` 形状（`:step`・`:ar1_decay`・`:path`・`:step_then_ramp`）と
# `:calendar`/`:period` の両 timing basis を1つの `Scenario` に含め、型写像（Symbol・Date・
# DateTime・Tuple・NamedTuple）を一通り往復させる fictional シナリオを構築する。

using DME
const JSON3 = DME.JSON3
using Dates: Date, DateTime

const HERE = @__DIR__

function write_canonical_json(relpath::String, d)
    path = joinpath(HERE, relpath)
    mkpath(dirname(path))
    bytes = canonical_json_bytes(d)
    open(path, "w") do io
        write(io, bytes)
    end
    println("wrote ", relpath)
end

demand = scenario_assumption(;
    assumption_id = "demand-period",
    event_type = :DemandOutlookRevision,
    sector = :s1,
    direction = :up,
    magnitude = 5.0,
    unit = "%",
    magnitude_source = :assumed_default,
    application_mode = :multiplicative,
    timing = EventTiming(; basis = :period, rule = :explicit_period, t_apply = 0),
    persistence = PersistenceSpec(; shape = :step),
    target_concepts = [:demand_expectation],
    provenance = EventProvenance(;
        layer = :assumption,
        rule_id = "golden-fixture-rule",
        rule_version = "1.0.0",
        generator = "test/fixtures/scenarios/regenerate.jl",
        derived_from = ["fictional-source-demand"],
    ),
)

credit_cal = scenario_assumption(;
    assumption_id = "credit-cal",
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
        rule_id = "golden-fixture-rule",
        rule_version = "1.0.0",
        generator = "test/fixtures/scenarios/regenerate.jl",
        derived_from = ["fictional-source-credit"],
        generated_at = DateTime(2026, 3, 1, 12, 0, 0),
    ),
    confidence = 0.7,
    uncertainty = (0.5, 0.9),
    notes = "信用スプレッドの拡大（fictional・テスト用架空データ）",
    caveats = "実在企業・実在イベントを参照しない",
)

capex_path = scenario_assumption(;
    assumption_id = "capex-path",
    event_type = :CapexGuidanceRevision,
    sector = :s1,
    direction = :up,
    magnitude = 3.0,
    unit = "%",
    magnitude_source = :derived,
    application_mode = :multiplicative,
    timing = EventTiming(; basis = :period, rule = :explicit_period, t_apply = 1),
    persistence = PersistenceSpec(; shape = :path, params = (values = [1.0, 2.0, 3.0],)),
    target_concepts = [:capex_plan],
    provenance = EventProvenance(;
        layer = :assumption,
        rule_id = "golden-fixture-rule",
        rule_version = "1.0.0",
        generator = "test/fixtures/scenarios/regenerate.jl",
        derived_from = ["fictional-source-path"],
    ),
)

emp_str = scenario_assumption(;
    assumption_id = "emp-str",
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
        rule_id = "golden-fixture-rule",
        rule_version = "1.0.0",
        generator = "test/fixtures/scenarios/regenerate.jl",
        derived_from = ["fictional-source-emp"],
    ),
)

sc = Scenario(;
    id = :event_driven_capex_golden,
    model = :capex_credit_cycle,
    period_zero = CalendarQuarter(2026, 1),
    assumptions = [demand, credit_cal, capex_path, emp_str],
    defaults_set_id = "golden-fixture-defaults",
    defaults_set_version = "1.0.0",
    notes = "Issue #203 のシリアライズ/replayテスト用 golden fixture（fictional）",
)

fixture = Dict{String, Any}(
    "source" => Dict{String, Any}(
        "kind" => "golden",
        "description" =>
            "Issue #203 のシリアライズ/replayテストで実際にプログラム的に" *
            "読み込む fictional シナリオ。test/fixtures/events/ の illustrative " *
            "fixture（読み込まない参考資料）と区別する（Y-25）。",
    ),
    "scenario" => scenario_to_dict(sc),
)

write_canonical_json("event_driven_capex_golden.json", fixture)

# 生成直後に decode できることを自己確認する
sc2 = scenario_from_dict(fixture["scenario"])
@assert sc2.id === sc.id
@assert length(sc2.assumptions) == length(sc.assumptions)
println("self-check ok")
