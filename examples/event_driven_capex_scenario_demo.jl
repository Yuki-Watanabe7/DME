# examples/event_driven_capex_scenario_demo.jl
#
# 日付付き複数イベントScenarioの統合デモ（Issue #205 / `E-9`）
#
# 部門別CAPEX・信用循環モデル（`CapexCreditCycleModel`）に対し、暦日付きイベント
# （`ObservedEvent`/`InterpretedSignal`/`ScenarioAssumption`）から `run_scenario` を通じて
# 決定的に `SimulationResult` を得るまでの経路を、外部API・ネットワークなしで実演する。
#
# 統合シナリオ（8ケース。Issue #205「統合シナリオ」節・
# docs/architecture/macro_event_runtime_integration.md §11 `E-9` 行）:
#   1. baseline（eventなし）
#   2. AI需要見通し下方修正（:DemandOutlookRevision）
#   3. 2 + CAPEXガイダンス削減・受注キャンセル（:CapexGuidanceRevision・:OrderCancellation）
#   4. 3 + credit spread拡大・lending standard引締め
#      （:CreditSpreadShock・:LendingStandardChange、on_unmapped=:warn）
#   5. 4 + policy rate緩和・価格/利益率ショック・格付イベント
#      （:PolicyRateChange・:PriceOrMarginShock・:RefinancingOrRatingEvent）
#   6. 同一四半期の複数イベントの決定論的合成（offsetting・within-class合成）
#   7. unmapped event を含み fail closed となる negative fixture（on_unmapped=:reject既定）
#   8. 構造的に invalid な negative fixture（`duplicate_event_id`）
# に加えて、5の保存済み artifact から replay して同一結果を再現する検証、`Sc0`–`Sc4`
# との数値互換性確認（統合設計 §8.4）、2回実行の決定性確認を行う。
#
# 9イベント型（`MACRO_EVENT_TYPES`）はすべて、mapping可能（E2E経路を通る）または
# mapping不能理由が固定される（`unmapped_target`、`D1`–`D4`）のいずれかで一度は登場する
# （統合設計 §10.6 項目2）。実在企業名・実数値を用いず、`entity`/`source.publisher` に
# "fictional" を含める（Issue #205 の規律）。
#
# 実行方法:
#   julia --project=. examples/event_driven_capex_scenario_demo.jl
#
# 成果物の出力先（既定はリポジトリ内 artifacts/、環境変数で上書き可）:
#   EDCS_DEMO_OUTDIR=/path/to/dir
#
# 保存する成果物（統合設計 §9.5。ケースごとに `<outdir>/<case_id>/` へ7種）:
#   scenario.json / observed_events.json / event_log.json / manifest.json /
#   result_summary.json / comparison.json（baselineがある完走ケースのみ） / report.md
# 加えてデモ全体の成果物:
#   sc0_sc4_parity.json … 統合設計 §8.4 の数値互換性確認（許容誤差0）
#   event_type_coverage.json … 9イベント型それぞれの mapping可否と登場ケース
#   demo_manifest.json … 全体provenance・決定性確認・replay確認・注意事項8件
#   report.md            … 人が読むサマリー
#
# 注意（結果の限界・禁止される解釈。統合設計 §12.3・llm_safety.md）: EDCS_NOTES を参照。
#
# 関連: docs/examples/event_driven_capex_scenario_demo.md /
#       docs/architecture/macro_event_runtime_integration.md（本デモの正本） /
#       docs/adr/0010-macro-event-scenario-contract.md /
#       docs/adr/0014-digital-twin-naming-conditions.md /
#       docs/adr/0015-macro-event-runtime-contract.md

# ヘッドレス環境（CI・無表示）でも問題なく完走する（可視化を持たないデモのため不要だが、
# 将来の拡張に備えて既存デモと同じ規約を踏襲する）。
get!(ENV, "GKSwstype", "nul")

using DME
using Dates: Date, now
const JSON3 = DME.JSON3

# ─────────────────────────────────────────────────────────────────
# 定数
# ─────────────────────────────────────────────────────────────────

const EDCS_CASE_IDS = (
    :baseline,
    :demand_outlook_down,
    :capex_cut_order_cancel,
    :credit_tightening,
    :policy_easing,
    :simultaneous_composition,
    :negative_unmapped,
    :negative_invalid,
)

const EDCS_PERIOD_ZERO = CalendarQuarter(2026, 1)

# LLM説明層への必須記載8件（統合設計 §12.3）。llm_safety.md の必須記載と併せて適用する。
const EDCS_NOTES = String[
    "どのイベントが観測に基づき、どのイベントが仮定かを magnitude_source に基づいて区別する" *
    "（:observed/:disclosed/:derived と :assumed_default/:external_belief を混同しない）。",
    ":assumed_default の仮定を含む場合、magnitude ±50%の感応度（scenario_magnitude_sensitivity）" *
    "の結果を併記する。",
    "unmapped_target/unsupported_model は「影響が無い」ことを意味しない。モデルが構造上その" *
    "事象を表現しないことを示す（近い変数への代理適用は行わない）。",
    "offsetting_events により相殺が生じた場合、net値だけでなく両側の粗値を確認できるようにする。",
    "timing_sensitive が記録された場合、±1期ずらしの結果（scenario_timing_sensitivity）を" *
    "併記する。",
    "timing_basis_period（理論シナリオ、Sc0–Sc4）の結果を、暦日付きの主張として提示しない。",
    ":as_of を実装していないため、「その時点で判断できた」「当時のデータで予測できた」とは" *
    "述べない。known_at は監査属性であり as-of 判定には用いない。",
    "status = :terminated の結果を完走した結果として提示しない。有効区間と打ち切り理由を" *
    "明示する。",
]

const EDCS_ADDITIONAL_NOTES = String[
    "パラメータ・イベントmagnitudeは fictional な例示値であり、実在企業・実在イベントを参照" *
    "しない。実データによる較正を経ていない。",
    "propagation_order はモデル内の系列順序であり、統計的因果効果ではない（causal/contribution" *
    "と呼ばない）。",
    "本出力は投資判断・政策立案の根拠として使用することを意図していない。",
]

# ─────────────────────────────────────────────────────────────────
# JSON安全化・provenance ヘルパー（`examples/capex_credit_cycle_demo.jl` と同じ規約）
# ─────────────────────────────────────────────────────────────────

function _edcs_git_revision()
    try
        rev = readchomp(`git -C $(@__DIR__) rev-parse --short HEAD`)
        isempty(rev) ? "unknown" : rev
    catch
        "unknown"
    end
end

_edcs_json_safe(x::AbstractFloat) =
    isfinite(x) ? x : (isnan(x) ? "NaN" : (x > 0 ? "Inf" : "-Inf"))
_edcs_json_safe(x::AbstractVector) = Any[_edcs_json_safe(v) for v in x]
_edcs_json_safe(x::Missing) = nothing
_edcs_json_safe(x::Nothing) = nothing
_edcs_json_safe(x) = x

function _edcs_write_json(path::AbstractString, value)
    mkpath(dirname(path))
    write(path, canonical_json_bytes(value))
    return path
end

# ─────────────────────────────────────────────────────────────────
# イベント構築ヘルパー（fictional）
# ─────────────────────────────────────────────────────────────────

_edcs_provenance(rule_id::AbstractString; derived_from::Vector{String} = String[]) =
    EventProvenance(;
        layer = :assumption,
        rule_id = rule_id,
        rule_version = "1.0.0",
        generator = "event_driven_capex_scenario_demo.jl",
        derived_from = derived_from,
    )

_edcs_timing(; rule::Symbol, effective_from::Date, effective_until::Union{Date, Nothing} = nothing) =
    EventTiming(;
        basis = :calendar,
        rule = rule,
        effective_from = effective_from,
        effective_until = effective_until,
    )

_edcs_persistence(; shape::Symbol = :step, duration::Union{Int, Nothing} = 4, params::NamedTuple = NamedTuple()) =
    PersistenceSpec(; shape = shape, duration = duration, params = params)

function _edcs_demand_outlook_assumption(;
    id::AbstractString,
    magnitude::Float64 = -6.0,
    effective_from::Date = Date(2026, 1, 20),
    rule::Symbol = :cutoff,
)
    return scenario_assumption(;
        assumption_id = id,
        event_type = :DemandOutlookRevision,
        sector = :s1,
        direction = magnitude >= 0 ? :up : :down,
        magnitude = magnitude,
        unit = "%",
        magnitude_source = :assumed_default,
        application_mode = :multiplicative,
        timing = _edcs_timing(; rule = rule, effective_from = effective_from),
        persistence = _edcs_persistence(; shape = :ar1_decay, duration = nothing, params = (half_life = 4.0,)),
        target_concepts = [:demand_expectation],
        provenance = _edcs_provenance(
            "edcs-demand-outlook";
            derived_from = ["fictional-source:semiconductor-outlook-note"],
        ),
        notes = "AI半導体向け需要見通しの下方修正（fictional、数値は分析者仮定）",
    )
end

function _edcs_capex_guidance_assumption(;
    id::AbstractString,
    magnitude::Float64 = -8.0,
    effective_from::Date = Date(2026, 4, 5),
)
    return scenario_assumption(;
        assumption_id = id,
        event_type = :CapexGuidanceRevision,
        sector = :s1,
        direction = :down,
        magnitude = magnitude,
        unit = "%",
        magnitude_source = :assumed_default,
        application_mode = :multiplicative,
        timing = _edcs_timing(; rule = :cutoff, effective_from = effective_from),
        persistence = _edcs_persistence(; shape = :step_then_ramp, duration = nothing, params = (hold = 4.0, ramp_down = 3.0)),
        target_concepts = [:capex_plan],
        provenance = _edcs_provenance(
            "edcs-capex-guidance";
            derived_from = ["fictional-source:capex-guidance-update"],
        ),
        notes = "CAPEXガイダンスの引下げ（fictional）",
    )
end

function _edcs_order_cancellation_assumption(;
    id::AbstractString,
    sector::Symbol,
    magnitude::Float64,
    effective_from::Date = Date(2026, 4, 8),
)
    return scenario_assumption(;
        assumption_id = id,
        event_type = :OrderCancellation,
        sector = sector,
        direction = :down,
        magnitude = magnitude,
        unit = "bn USD (2017 chained)",
        magnitude_source = :assumed_default,
        application_mode = :additive,
        timing = _edcs_timing(; rule = :same_quarter, effective_from = effective_from),
        persistence = _edcs_persistence(; shape = :step, duration = 4),
        target_concepts = [:order_flow],
        provenance = _edcs_provenance(
            "edcs-order-cancellation";
            derived_from = ["fictional-source:order-cancellation-notice"],
        ),
        notes = "受注キャンセル（fictional、部門 $(sector)）",
    )
end

function _edcs_credit_spread_assumption(;
    id::AbstractString,
    magnitude::Float64 = 45.0,
    effective_from::Date = Date(2026, 4, 20),
)
    return scenario_assumption(;
        assumption_id = id,
        event_type = :CreditSpreadShock,
        sector = :unknown,
        direction = magnitude >= 0 ? :up : :down,
        magnitude = magnitude,
        unit = "bp",
        magnitude_source = :assumed_default,
        application_mode = :additive,
        timing = _edcs_timing(; rule = :same_quarter, effective_from = effective_from),
        persistence = _edcs_persistence(; shape = :ar1_decay, duration = nothing, params = (half_life = 3.0,)),
        target_concepts = [:credit_spread],
        provenance = _edcs_provenance(
            "edcs-credit-spread";
            derived_from = ["fictional-source:credit-market-note"],
        ),
        notes = "信用スプレッドの拡大（fictional）",
    )
end

function _edcs_lending_standard_assumption(;
    id::AbstractString,
    magnitude::Float64 = 8.0,
    effective_from::Date = Date(2026, 4, 25),
)
    return scenario_assumption(;
        assumption_id = id,
        event_type = :LendingStandardChange,
        sector = :s4,
        direction = :up,
        magnitude = magnitude,
        unit = "%",
        magnitude_source = :assumed_default,
        application_mode = :multiplicative,
        timing = _edcs_timing(; rule = :same_quarter, effective_from = effective_from),
        persistence = _edcs_persistence(; shape = :step, duration = 6),
        target_concepts = [:lending_standard],
        provenance = _edcs_provenance(
            "edcs-lending-standard";
            derived_from = ["fictional-source:bank-lending-survey"],
        ),
        notes = "貸出態度の引締め（fictional）。モデルは構造上この事象の適用先を持たない" *
                "（unmapped_target、D2）",
    )
end

function _edcs_policy_rate_assumption(;
    id::AbstractString,
    magnitude::Float64 = -0.5,
    effective_from::Date = Date(2026, 7, 15),
)
    return scenario_assumption(;
        assumption_id = id,
        event_type = :PolicyRateChange,
        sector = :out_of_model,
        direction = magnitude >= 0 ? :up : :down,
        magnitude = magnitude,
        unit = "%pt",
        magnitude_source = :assumed_default,
        application_mode = :additive,
        timing = _edcs_timing(; rule = :same_quarter, effective_from = effective_from),
        persistence = _edcs_persistence(; shape = :step, duration = nothing),
        target_concepts = [:policy_rate],
        provenance = _edcs_provenance(
            "edcs-policy-rate";
            derived_from = ["fictional-source:central-bank-statement"],
        ),
        notes = "政策金利の緩和（fictional）",
    )
end

function _edcs_price_margin_assumption(;
    id::AbstractString,
    sector::Symbol = :s1,
    magnitude::Float64 = -2.0,
    effective_from::Date = Date(2026, 7, 1),
)
    return scenario_assumption(;
        assumption_id = id,
        event_type = :PriceOrMarginShock,
        sector = sector,
        direction = :down,
        magnitude = magnitude,
        unit = "%",
        magnitude_source = :assumed_default,
        application_mode = :multiplicative,
        timing = _edcs_timing(; rule = :cutoff, effective_from = effective_from),
        persistence = _edcs_persistence(; shape = :ar1_decay, duration = nothing, params = (half_life = 4.0,)),
        target_concepts = [:output_price_margin],
        provenance = _edcs_provenance(
            "edcs-price-margin";
            derived_from = ["fictional-source:pricing-note"],
        ),
        notes = "出荷価格/利益率の圧縮（fictional、部門 $(sector)）",
    )
end

function _edcs_refinancing_assumption(;
    id::AbstractString,
    sector::Symbol = :s2,
    magnitude::Float64 = 15.0,
    effective_from::Date = Date(2026, 7, 10),
    reason_note::AbstractString = "格付見通しの引下げ（rating_downgrade、fictional）。" *
                                   "市場スプレッドへ反映される分のみモデルへ適用する",
)
    return scenario_assumption(;
        assumption_id = id,
        event_type = :RefinancingOrRatingEvent,
        sector = sector,
        direction = magnitude >= 0 ? :up : :down,
        magnitude = magnitude,
        unit = "bp",
        magnitude_source = :assumed_default,
        application_mode = :additive,
        timing = _edcs_timing(; rule = :same_quarter, effective_from = effective_from),
        persistence = _edcs_persistence(; shape = :step, duration = 6),
        target_concepts = [:refinancing_condition],
        provenance = _edcs_provenance(
            "edcs-refinancing";
            derived_from = ["fictional-source:credit-rating-note"],
        ),
        notes = reason_note,
    )
end

function _edcs_employment_plan_assumption(;
    id::AbstractString,
    magnitude::Float64 = -3.0,
    effective_from::Date = Date(2026, 4, 8),
)
    return scenario_assumption(;
        assumption_id = id,
        event_type = :EmploymentPlanRevision,
        sector = :s1,
        direction = :down,
        magnitude = magnitude,
        unit = "%",
        magnitude_source = :assumed_default,
        application_mode = :multiplicative,
        timing = _edcs_timing(; rule = :same_quarter, effective_from = effective_from),
        persistence = _edcs_persistence(; shape = :step, duration = 4),
        target_concepts = [:employment_plan],
        provenance = _edcs_provenance(
            "edcs-employment-plan";
            derived_from = ["fictional-source:workforce-plan-update"],
        ),
        notes = "雇用計画の下方修正（fictional）。モデルは構造上この事象の適用先を持たない" *
                "（unmapped_target、D4）",
    )
end

# ─────────────────────────────────────────────────────────────────
# L1/L2 原本（`demand_outlook_down` ケースのみ、観測→仮定への遡及を実演する）
# ─────────────────────────────────────────────────────────────────

function _edcs_demand_observed_events()
    src = EventSource(;
        publisher = "fictional-industry-wire",
        document_id = "FICTIONAL-DOC-0001",
        url = "",
        retrieved_at = nothing,
    )
    l1 = observed_event(;
        event_id = "obs-demand-1",
        event_type = :DemandOutlookRevision,
        announced_at = Date(2026, 1, 18),
        observed_at = Date(2026, 1, 18),
        known_at = Date(2026, 1, 19),
        source = src,
        provenance = EventProvenance(;
            layer = :observed,
            rule_id = "manual-entry",
            rule_version = "1.0.0",
            generator = "human",
            derived_from = String[],
        ),
        entity = "fictional-semiconductor-co-A",
        sector = :s1,
        direction = :down,
        magnitude = missing,
        unit = nothing,
        notes = "AI半導体向け需要見通しを引き下げ（fictional）。数値は当該文書に開示されていない。",
    )
    l2 = interpreted_signal(;
        event_id = "sig-demand-1",
        event_type = :DemandOutlookRevision,
        announced_at = Date(2026, 1, 18),
        observed_at = Date(2026, 1, 18),
        known_at = Date(2026, 1, 19),
        source = src,
        provenance = EventProvenance(;
            layer = :interpreted,
            rule_id = "analyst-interpretation",
            rule_version = "1.0.0",
            generator = "human",
            derived_from = ["obs-demand-1"],
        ),
        entity = "fictional-semiconductor-co-A",
        sector = :s1,
        direction = :down,
        magnitude_source = :assumed_default,
        confidence = 0.6,
        magnitude = -6.0,
        unit = "%",
        target_concepts = [:demand_expectation],
        notes = "数値非開示のため -6% を分析者仮定として使用（fictional、magnitude_source=" *
                ":assumed_default）",
    )
    return AbstractMacroEvent[l1, l2]
end

# ─────────────────────────────────────────────────────────────────
# 8ケースの assumptions 構築（統合設計 §11 `E-9` 行）
# ─────────────────────────────────────────────────────────────────

"""
    _edcs_case_assumptions() -> Dict{Symbol,Vector{ScenarioAssumption}}

8ケース（統合設計 §11 `E-9` 行）それぞれの `ScenarioAssumption` 集合を構築する。
`demand_outlook_down` → `capex_cut_order_cancel` → `credit_tightening` → `policy_easing` は
累積的（前段の仮定を含む）。`simultaneous_composition`・`negative_unmapped`・
`negative_invalid` は独立したケースである。
"""
function _edcs_case_assumptions()
    demand = _edcs_demand_outlook_assumption(; id = "case2-demand")

    capex_guidance = _edcs_capex_guidance_assumption(; id = "case3-capex-guidance")
    order_s2 = _edcs_order_cancellation_assumption(; id = "case3-order-s2", sector = :s2, magnitude = -4.0)
    order_s3 = _edcs_order_cancellation_assumption(; id = "case3-order-s3", sector = :s3, magnitude = -2.5)

    credit_spread = _edcs_credit_spread_assumption(; id = "case4-credit-spread")
    lending_standard = _edcs_lending_standard_assumption(; id = "case4-lending-standard")

    policy_rate = _edcs_policy_rate_assumption(; id = "case5-policy-rate")
    price_margin = _edcs_price_margin_assumption(; id = "case5-price-margin", sector = :s1)
    refinancing = _edcs_refinancing_assumption(; id = "case5-refinancing")

    case2 = [demand]
    case3 = vcat(case2, [capex_guidance, order_s2, order_s3])
    case4 = vcat(case3, [credit_spread, lending_standard])
    case5 = vcat(case4, [policy_rate, price_margin, refinancing])

    # 全4件を同一日付・:same_quarter 規則で揃え、同一四半期への決定論的合成
    # （offsetting・within-class合成）を実演する。
    simultaneous = [
        _edcs_credit_spread_assumption(;
            id = "case6-credit-pos",
            magnitude = 40.0,
            effective_from = Date(2026, 4, 15),
        ),
        _edcs_credit_spread_assumption(;
            id = "case6-credit-neg",
            magnitude = -15.0,
            effective_from = Date(2026, 4, 15),
        ),
        _edcs_demand_outlook_assumption(;
            id = "case6-demand-pos",
            magnitude = 5.0,
            effective_from = Date(2026, 4, 15),
            rule = :same_quarter,
        ),
        _edcs_demand_outlook_assumption(;
            id = "case6-demand-neg",
            magnitude = -2.5,
            effective_from = Date(2026, 4, 15),
            rule = :same_quarter,
        ),
    ]

    negative_unmapped = [
        _edcs_price_margin_assumption(;
            id = "case7-price-margin-s2",
            sector = :s2,
            magnitude = -1.0,
        ),                                                   # D1: sector_ne_s1
        _edcs_refinancing_assumption(;
            id = "case7-refinancing-maturity-wall",
            sector = :s3,
            magnitude = 35.0,
            reason_note = "満期集中による借換リスク（maturity_wall、fictional）",
        ),                                                    # D3: 借換条件そのものの変更
        _edcs_employment_plan_assumption(; id = "case7-employment-plan"),  # D4
    ]

    dup_a = _edcs_demand_outlook_assumption(; id = "case8-dup", magnitude = 4.0)
    dup_b = _edcs_credit_spread_assumption(; id = "case8-dup", magnitude = 20.0)
    negative_invalid = [dup_a, dup_b]

    return Dict{Symbol, Vector{ScenarioAssumption}}(
        :baseline => ScenarioAssumption[],
        :demand_outlook_down => case2,
        :capex_cut_order_cancel => case3,
        :credit_tightening => case4,
        :policy_easing => case5,
        :simultaneous_composition => simultaneous,
        :negative_unmapped => negative_unmapped,
        :negative_invalid => negative_invalid,
    )
end

const EDCS_CASE_NAMES = Dict{Symbol, String}(
    :baseline => "baseline（eventなし）",
    :demand_outlook_down => "AI需要見通し下方修正",
    :capex_cut_order_cancel => "CAPEXガイダンス削減 + 受注キャンセル",
    :credit_tightening => "上記 + credit spread拡大 + lending standard引締め",
    :policy_easing => "上記 + policy rate緩和 + 価格/利益率ショック + 格付イベント",
    :simultaneous_composition => "同一四半期の複数イベントの決定論的合成（offsetting含む）",
    :negative_unmapped => "unmapped eventを含む negative fixture（fail closed）",
    :negative_invalid => "構造的に invalid な negative fixture（duplicate_event_id）",
)

const EDCS_EXPECTED_STATUS = Dict{Symbol, Symbol}(
    :baseline => :completed,
    :demand_outlook_down => :completed,
    :capex_cut_order_cancel => :completed,
    :credit_tightening => :completed,
    :policy_easing => :completed,
    :simultaneous_composition => :completed,
    :negative_unmapped => :rejected_mapping,
    :negative_invalid => :rejected_validation,
)

# on_unmapped=:warn が必要なケース（LendingStandardChange、D2）。他は既定 :reject。
const EDCS_ON_UNMAPPED_WARN_CASES = (:credit_tightening, :policy_easing)

# ─────────────────────────────────────────────────────────────────
# ScenarioComparisonDiagnostics → Dict（成果物 comparison.json 用）
# ─────────────────────────────────────────────────────────────────

function _edcs_comparison_to_dict(c::ScenarioComparisonDiagnostics)::Dict{String, Any}
    peak_dict(p) = Dict{String, Any}(
        "value" => _edcs_json_safe(p.value),
        "period" => p.period,
        "sign" => p.sign,
    )
    return Dict{String, Any}(
        "variables" => String.(c.variables),
        "abs_diff" => Dict{String, Any}(String(k) => _edcs_json_safe(v) for (k, v) in c.abs_diff),
        "rel_diff" => Dict{String, Any}(
            String(k) => Any[x === missing ? nothing : _edcs_json_safe(x) for x in v] for
            (k, v) in c.rel_diff
        ),
        "peak" => Dict{String, Any}(String(k) => peak_dict(v) for (k, v) in c.peak),
        "trough" => Dict{String, Any}(String(k) => peak_dict(v) for (k, v) in c.trough),
        "onset_period" => Dict{String, Any}(String(k) => v for (k, v) in c.onset_period),
        "duration_above" => Dict{String, Any}(String(k) => v for (k, v) in c.duration_above),
        "recovery_period" => Dict{String, Any}(String(k) => v for (k, v) in c.recovery_period),
        "cumulative" => Dict{String, Any}(
            String(k) => (v === nothing ? nothing : _edcs_json_safe(v)) for (k, v) in c.cumulative
        ),
        "propagation_order" => [
            Dict{String, Any}(
                "variable" => String(p.variable),
                "sector" => String(p.sector),
                "onset_period" => p.onset_period,
            ) for p in c.propagation_order
        ],
        "event_application_periods" => c.event_application_periods,
        "valid_range" => Any[first(c.valid_range), last(c.valid_range)],
        "invalid_reason" => c.invalid_reason === nothing ? nothing : String(c.invalid_reason),
        "thresholds" => Dict{String, Any}(
            "id" => c.thresholds.id,
            "version" => c.thresholds.version,
            "onset_abs" => c.thresholds.onset_abs,
            "onset_rel" => c.thresholds.onset_rel,
            "onset_persistence" => c.thresholds.onset_persistence,
            "rel_denominator_floor" => c.thresholds.rel_denominator_floor,
        ),
    )
end

# ─────────────────────────────────────────────────────────────────
# ケース実行
# ─────────────────────────────────────────────────────────────────

"""
    _edcs_run_case(m, id, assumptions, baseline_run; outdir) -> NamedTuple

1ケースを `run_scenario` で実行し、成果物7種を `outdir/<id>/` へ保存する。`baseline_run`
が渡され、かつ実行が `:completed` の場合のみ `scenario_comparison` を計算し
`comparison.json` を書く。
"""
function _edcs_run_case(
    m::CapexCreditCycleModel,
    id::Symbol,
    assumptions::Vector{ScenarioAssumption},
    baseline_run::Union{ScenarioRun, Nothing};
    outdir::AbstractString,
)
    sc = Scenario(;
        id = id,
        name = EDCS_CASE_NAMES[id],
        model = :capex_credit_cycle,
        period_zero = EDCS_PERIOD_ZERO,
        assumptions = assumptions,
        defaults_set_id = "event-driven-capex-scenario-demo",
        defaults_set_version = "1.0.0",
        notes = "fictional。実在企業・実在イベントを参照しない（Issue #205 統合デモ）。",
    )
    options = ScenarioRunOptions(;
        on_unmapped = id in EDCS_ON_UNMAPPED_WARN_CASES ? :warn : :reject,
    )
    run = run_scenario(m, sc; options = options)

    comparison = nothing
    comparison_dict = nothing
    if run.status === :completed && baseline_run !== nothing && baseline_run !== run
        comparison = scenario_comparison(baseline_run, run; model_diagnostics = run.diagnostics)
        comparison_dict = _edcs_comparison_to_dict(comparison)
    end

    observed_events = id === :demand_outlook_down ? _edcs_demand_observed_events() : AbstractMacroEvent[]

    dir = joinpath(outdir, String(id))
    paths = save_scenario_artifact(
        dir,
        run;
        observed_events = observed_events,
        comparison = comparison_dict,
    )

    return (
        id = id,
        scenario = sc,
        run = run,
        comparison = comparison,
        dir = dir,
        paths = paths,
        status_ok = run.status === EDCS_EXPECTED_STATUS[id],
    )
end

# ─────────────────────────────────────────────────────────────────
# Sc0–Sc4 数値互換性確認（統合設計 §8.4・§10.4 項目6–8）
# ─────────────────────────────────────────────────────────────────

"""
    _edcs_sc0_sc4_parity(m) -> NamedTuple

`capex_scenario_assumptions(id)` 経由の `run_scenario` の `exog` が
`capex_exogenous_paths(m, capex_scenario(id))` と**完全一致**（許容誤差0）することを
`Sc0`–`Sc4` 全件で確認する（統合設計 §8.4 項目1–3）。
"""
function _edcs_sc0_sc4_parity(m::CapexCreditCycleModel)
    per_scenario = Dict{String, Any}()
    all_pass = true
    for id in CAPEX_CC_SCENARIO_IDS
        legacy_exog = capex_exogenous_paths(m, capex_scenario(id))
        legacy_series = simulate(m; scenario = id, exog = legacy_exog)

        assumptions = capex_scenario_assumptions(id)
        sc = Scenario(; id = id, model = :capex_credit_cycle, assumptions = assumptions)
        run = run_scenario(m, sc)

        exog_match = run.status === :completed &&
                     all(run.exog[v] == legacy_exog[v] for v in exogenous_variables(m))
        series_match = run.status === :completed && all(
            isequal(v, getproperty(legacy_series, Symbol(k))) for
            (k, v) in pairs(run.result.variables)
        )
        ok = exog_match && series_match
        all_pass &= ok
        per_scenario[String(id)] = Dict{String, Any}(
            "status" => String(run.status),
            "exog_exact_match" => exog_match,
            "simulation_result_exact_match" => series_match,
            "pass" => ok,
        )
    end
    return (all_pass = all_pass, per_scenario = per_scenario)
end

# ─────────────────────────────────────────────────────────────────
# イベント型カバレッジ（統合設計 §10.6 項目2）
# ─────────────────────────────────────────────────────────────────

"""
    _edcs_event_type_coverage(case_runs) -> Dict{String,Any}

9イベント型（`MACRO_EVENT_TYPES`）それぞれについて、mapping可能（`AppliedModelInput` を
生成した）ケース、または mapping不能理由が固定されている（`unmapped_target` として
拒否/警告された）ケースを記録する。
"""
function _edcs_event_type_coverage(case_runs)
    coverage = Dict{Symbol, Dict{String, Any}}()
    for cr in case_runs
        run = cr.run
        for input in run.applied_inputs
            et = _edcs_assumption_event_type(run.scenario, input.assumption_id)
            et === nothing && continue
            coverage[et] = Dict{String, Any}(
                "status" => "mapped",
                "case" => String(cr.id),
                "target_variable" => String(input.target_variable),
            )
        end
        for r in run.rejections
            r.code === :unmapped_target || continue
            haskey(coverage, r.event_type) && continue
            coverage[r.event_type] = Dict{String, Any}(
                "status" => "unmapped_target",
                "case" => String(cr.id),
                "upstream_issue" => r.upstream_issue,
                "detail" => r.detail,
            )
        end
        # on_unmapped=:warn では unmapped_target は EventRejection ではなく
        # :unmapped_target_accepted 警告として記録される（run.rejections に現れない）。
        for w in run.warnings
            w.code === :unmapped_target_accepted || continue
            isempty(w.subject_ids) && continue
            et = _edcs_assumption_event_type(run.scenario, w.subject_ids[1])
            et === nothing && continue
            haskey(coverage, et) && continue
            coverage[et] = Dict{String, Any}(
                "status" => "unmapped_target",
                "case" => String(cr.id),
                "upstream_issue" => "",
                "detail" => w.detail,
            )
        end
    end
    return Dict{String, Any}(
        "types" => Dict{String, Any}(String(t) => get(coverage, t, nothing) for t in MACRO_EVENT_TYPES),
        "all_covered" => all(haskey(coverage, t) for t in MACRO_EVENT_TYPES),
    )
end

function _edcs_assumption_event_type(sc::Scenario, assumption_id::AbstractString)
    idx = findfirst(a -> a.assumption_id == assumption_id, sc.assumptions)
    return idx === nothing ? nothing : sc.assumptions[idx].event_type
end

# ─────────────────────────────────────────────────────────────────
# Markdown レポート
# ─────────────────────────────────────────────────────────────────

function _edcs_write_markdown_report(
    path,
    case_runs,
    parity,
    coverage,
    determinism_ok::Bool,
    replay_ok::Bool,
    manifest::Dict{String, Any},
)
    io = IOBuffer()
    println(io, "# 日付付き複数イベントScenario 統合デモ — 実行レポート\n")
    println(io, "> 本レポートは自動生成物です。全ケースは fictional であり、実在企業・実在イベント・")
    println(io, "> 実数値を参照しません。\n")

    println(io, "## 1. 実行メタデータ（provenance）\n")
    println(io, "- 実行日時: `$(manifest["run_timestamp"])`")
    println(io, "- code revision: `$(manifest["code_revision"])`")
    println(io, "- event_runtime_version: `$(MACRO_EVENT_RUNTIME_VERSION)`")

    println(io, "\n## 2. ケース別 実行結果\n")
    println(io, "| ケース | 内容 | status | 期待どおり | assumptions数 |")
    println(io, "|---|---|---|---|---|")
    for cr in case_runs
        println(
            io,
            "| $(cr.id) | $(EDCS_CASE_NAMES[cr.id]) | $(cr.run.status) | $(cr.status_ok) | " *
            "$(length(cr.scenario.assumptions)) |",
        )
    end

    println(io, "\n## 3. Sc0–Sc4 数値互換性確認（統合設計 §8.4）\n")
    println(io, "- 全件一致（許容誤差0）: `$(parity.all_pass)`")
    println(io, "\n| シナリオ | exog完全一致 | SimulationResult完全一致 |")
    println(io, "|---|---|---|")
    for id in CAPEX_CC_SCENARIO_IDS
        p = parity.per_scenario[String(id)]
        println(io, "| $(id) | $(p["exog_exact_match"]) | $(p["simulation_result_exact_match"]) |")
    end

    println(io, "\n## 4. イベント型カバレッジ（9型）\n")
    println(io, "- 全9型がmapping可能またはmapping不能理由固定で登場: `$(coverage["all_covered"])`")
    println(io, "\n| event_type | status | ケース |")
    println(io, "|---|---|---|")
    for t in MACRO_EVENT_TYPES
        entry = coverage["types"][String(t)]
        status = entry === nothing ? "MISSING" : entry["status"]
        case = entry === nothing ? "-" : entry["case"]
        println(io, "| $(t) | $(status) | $(case) |")
    end

    println(io, "\n## 5. 決定性・replay確認\n")
    println(io, "- 2回実行で全成果物ファイルが完全一致: `$(determinism_ok)`")
    println(io, "- 保存済み artifact からの replay が同一結果を再現: `$(replay_ok)`")

    println(io, "\n## 6. 保存した成果物\n")
    println(io, "各ケースは `<outdir>/<case_id>/` に scenario.json・observed_events.json・")
    println(io, "event_log.json・manifest.json・result_summary.json・comparison.json（該当時）・")
    println(io, "report.md を保存します。加えて `sc0_sc4_parity.json`・`event_type_coverage.json`・")
    println(io, "`demo_manifest.json` をデモ直下に保存します。")

    println(io, "\n## 7. 注意事項（LLM説明層への必須記載、統合設計 §12.3）\n")
    for (i, note) in enumerate(EDCS_NOTES)
        println(io, "$(i). $(note)")
    end
    println(io, "\n### 追加の注意事項\n")
    for (i, note) in enumerate(EDCS_ADDITIONAL_NOTES)
        println(io, "$(i). $(note)")
    end

    write(path, String(take!(io)))
    return path
end

# ─────────────────────────────────────────────────────────────────
# 本体
# ─────────────────────────────────────────────────────────────────

"""
    run_event_driven_capex_scenario_demo(; outdir, verbose=true) -> NamedTuple

日付付き複数イベントScenarioの統合デモ（統合設計 §11 `E-9`）を実行し、成果物パスと
主要結果を返す。API キー不要・ネットワークアクセスなし・完全に決定的に完走する。
"""
function run_event_driven_capex_scenario_demo(; outdir::AbstractString, verbose::Bool = true)
    isdir(outdir) || mkpath(outdir)
    say(args...) = verbose && println(args...)

    say("=" ^ 64)
    say("Step 1  モデル構築")
    say("=" ^ 64)
    m = capex_credit_cycle_model(capex_credit_cycle_default_targets())

    say("\n" * "=" ^ 64)
    say("Step 2  8ケースの実行・成果物保存")
    say("=" ^ 64)
    all_assumptions = _edcs_case_assumptions()
    case_runs = []
    baseline_run = nothing
    for id in EDCS_CASE_IDS
        cr = _edcs_run_case(m, id, all_assumptions[id], baseline_run; outdir = outdir)
        push!(case_runs, cr)
        id === :baseline && (baseline_run = cr.run)
        say(
            "  $(id): status=$(cr.run.status)  期待どおり=$(cr.status_ok)  " *
            "warnings=$(length(cr.run.warnings))  rejections=$(length(cr.run.rejections))",
        )
    end
    all_status_ok = all(cr.status_ok for cr in case_runs)
    say("  全ケースが期待どおりの status: ", all_status_ok)

    say("\n" * "=" ^ 64)
    say("Step 3  Sc0–Sc4 数値互換性確認（統合設計 §8.4）")
    say("=" ^ 64)
    parity = _edcs_sc0_sc4_parity(m)
    say("  全件一致（許容誤差0）: ", parity.all_pass)

    say("\n" * "=" ^ 64)
    say("Step 4  イベント型カバレッジ（9型）確認")
    say("=" ^ 64)
    coverage = _edcs_event_type_coverage(case_runs)
    say("  全9型が登場: ", coverage["all_covered"])

    say("\n" * "=" ^ 64)
    say("Step 5  決定性確認（2回実行で全成果物ファイルが完全一致）")
    say("=" ^ 64)
    determinism_dir = mktempdir()
    case_runs_2 = []
    baseline_run_2 = nothing
    for id in EDCS_CASE_IDS
        cr2 = _edcs_run_case(m, id, all_assumptions[id], baseline_run_2; outdir = determinism_dir)
        push!(case_runs_2, cr2)
        id === :baseline && (baseline_run_2 = cr2.run)
    end
    determinism_ok = true
    for (cr1, cr2) in zip(case_runs, case_runs_2)
        for fname in readdir(cr1.dir)
            f1 = read(joinpath(cr1.dir, fname), String)
            f2 = read(joinpath(cr2.dir, fname), String)
            f1 == f2 || (determinism_ok = false)
        end
    end
    say("  2回実行で全成果物ファイルが完全一致: ", determinism_ok)

    say("\n" * "=" ^ 64)
    say("Step 6  replay確認（policy_easing の保存済み artifact から再実行）")
    say("=" ^ 64)
    flagship = only(filter(cr -> cr.id === :policy_easing, case_runs))
    replay_options = ScenarioRunOptions(;
        on_unmapped = flagship.id in EDCS_ON_UNMAPPED_WARN_CASES ? :warn : :reject,
    )
    replayed = replay_scenario(m, joinpath(flagship.dir, "scenario.json"); options = replay_options)
    replay_ok =
        replayed.status === flagship.run.status &&
        replayed.exog == flagship.run.exog &&
        (
            flagship.run.result === nothing ? replayed.result === nothing :
            replayed.result.variables == flagship.run.result.variables
        ) &&
        [w.code for w in replayed.warnings] == [w.code for w in flagship.run.warnings]
    say("  replayが同一結果を再現: ", replay_ok)

    say("\n" * "=" ^ 64)
    say("Step 7  デモ全体成果物の保存")
    say("=" ^ 64)
    parity_dict = Dict{String, Any}(
        "all_pass" => parity.all_pass,
        "per_scenario" => parity.per_scenario,
    )
    parity_path = _edcs_write_json(joinpath(outdir, "sc0_sc4_parity.json"), parity_dict)
    coverage_path = _edcs_write_json(joinpath(outdir, "event_type_coverage.json"), coverage)

    manifest = Dict{String, Any}(
        "demo" => "event_driven_capex_scenario",
        "run_timestamp" => string(now()),
        "code_revision" => _edcs_git_revision(),
        "event_runtime_version" => MACRO_EVENT_RUNTIME_VERSION,
        "event_contract_version" => MACRO_EVENT_CONTRACT_VERSION,
        "time_semantics_version" => SCENARIO_TIME_SEMANTICS_VERSION,
        "event_mapping_version" => CAPEX_CC_EVENT_MAPPING_VERSION,
        "cases" => Dict{String, Any}(
            String(cr.id) => Dict{String, Any}(
                "status" => String(cr.run.status),
                "status_ok" => cr.status_ok,
                "warnings" => [String(w.code) for w in cr.run.warnings],
                "rejections" => [String(r.code) for r in cr.run.rejections],
                "event_set_hash" => cr.run.provenance.event_set_hash,
            ) for cr in case_runs
        ),
        "all_cases_status_ok" => all_status_ok,
        "sc0_sc4_parity_all_pass" => parity.all_pass,
        "event_type_coverage_all_covered" => coverage["all_covered"],
        "determinism_check_pass" => determinism_ok,
        "replay_check_pass" => replay_ok,
        "notes" => EDCS_NOTES,
        "additional_notes" => EDCS_ADDITIONAL_NOTES,
    )
    manifest_path = _edcs_write_json(joinpath(outdir, "demo_manifest.json"), manifest)

    report_path = joinpath(outdir, "report.md")
    _edcs_write_markdown_report(
        report_path,
        case_runs,
        parity,
        coverage,
        determinism_ok,
        replay_ok,
        manifest,
    )

    for p in (parity_path, coverage_path, manifest_path, report_path)
        say("  saved: $(basename(p))")
    end

    return (
        outdir = outdir,
        model = m,
        case_runs = case_runs,
        all_status_ok = all_status_ok,
        sc0_sc4_parity = parity,
        event_type_coverage = coverage,
        determinism_ok = determinism_ok,
        replay_ok = replay_ok,
        manifest = manifest,
        artifact_paths = vcat(
            [p for cr in case_runs for p in cr.paths],
            [parity_path, coverage_path, manifest_path, report_path],
        ),
    )
end

# ─────────────────────────────────────────────────────────────────
# スクリプトとして直接実行された場合のみ走らせる（include では実行しない）
# ─────────────────────────────────────────────────────────────────
if abspath(PROGRAM_FILE) == @__FILE__
    outdir = get(
        ENV,
        "EDCS_DEMO_OUTDIR",
        joinpath(@__DIR__, "..", "artifacts", "event_driven_capex_scenario_demo"),
    )

    println(
        """
╔═══════════════════════════════════════════════════════════════════╗
║  日付付き複数イベントScenario 統合デモ                               ║
║  8ケース → Sc0–Sc4互換性 → 9型カバレッジ → 決定性 → replay → 保存    ║
╚═══════════════════════════════════════════════════════════════════╝

  出力先: $(outdir)

注意: 全ケースは fictional であり、実在企業・実在イベント・実数値を参照しない。
      unmapped_target は「影響が無い」ことを意味せず、モデルが構造上その事象を
      表現しないことを示す。本デモは投資判断・政策立案の根拠として使用することを
      意図していない。
""",
    )

    out = run_event_driven_capex_scenario_demo(; outdir = outdir)

    println(
        """

完了。出力ディレクトリ: $(out.outdir)

全ケースが期待どおりの status: $(out.all_status_ok)
Sc0–Sc4 数値互換性（許容誤差0）: $(out.sc0_sc4_parity.all_pass)
9イベント型カバレッジ: $(out.event_type_coverage["all_covered"])
決定性（2回実行の完全一致）: $(out.determinism_ok)
replay（保存済みartifactからの再現）: $(out.replay_ok)

詳細: docs/examples/event_driven_capex_scenario_demo.md
""",
    )
end
