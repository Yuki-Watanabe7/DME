# examples/japan_fiscal_scenario_lab_demo.jl
#
# Japan Fiscal Scenario Lab の実行例（Issue #277）。FRE snapshot（observed context）と
# explicit Scenario Assumption を別々に置き、5 scenario family を各 family の primary モデルで
# baseline と比較実行し、表現不能・assumption 未指定のケースが「実行されない」ことを確かめたうえで、
# Market Analyzer 向けの versioned handoff bundle を書き出して fail closed に読み戻し、replay する。
# 乱数・ネットワーク・API キーを使わない（完全に決定的）。
#
# 実行方法:
#   julia --project=. examples/japan_fiscal_scenario_lab_demo.jl
#
# 成果物の出力先（既定はリポジトリ内 artifacts/japan_fiscal_scenario_lab_demo/、環境変数で上書き可）:
#   JAPAN_FISCAL_DEMO_OUTDIR=/path/to/dir
#   <outdir>/handoff/          : handoff bundle（index.json・scenarios/・artifacts/・contracts/）
#   既に存在する場合は上書きしない（別の outdir を指定する）。
#
# 注意（結果の限界・禁止される解釈）:
#   - FRE snapshot・assumption の数値はすべて架空の例示値であり、実際の FRE 出力・政策見通しではない。
#   - FRE の affinity / share / confidence / score は shock magnitude に使わない（observed context のみ）。
#   - model-implied result は forecast でも probability でもない。日本較正済みのモデルは無く（G-02）、
#     数値を日本の量として読まない（claim_level は direction_only または
#     direction_and_relative_timing）。
#   - 政府債務残高・利払費を持つモデルは無く（G-01）、債務持続可能性の判断に使わない。
#   - 投資判断・政策判断の根拠として使用することを意図していない。
#
# 関連: docs/architecture/japan_fiscal_scenario_handoff.md /
#       docs/adr/0025-japan-fiscal-scenario-handoff-contract.md

using DME
using Dates

"デモ用の FRE snapshot（架空。observed context としてのみ使う）。"
function jf_demo_fre_context()
    return JapanFiscalFREContext(;
        snapshot_id = "demo-fre-jp-2026-09-30",
        as_of = Date(2026, 9, 30),
        vintage_basis = "demo:as-released",
        regime_determination = :primary,
        primary_regime = "FINANCIAL_REPRESSION",
        regime_affinity = Dict(
            "GROWTH_NORMALIZATION" => 0.31,
            "FISCAL_CONSOLIDATION" => 0.44,
            "FINANCIAL_REPRESSION" => 0.68,
            "FISCAL_STRESS" => 0.39,
        ),
        regime_confidence = 0.58,
        constraint_pressure = 0.47,
        methodology_version = "demo-fre-methodology/1.0.0",
        policy_version = "demo-fre-policy/1.0.0",
        notes = "架空のデモ snapshot。",
    )
end

_jf_demo_a(id, concept, magnitude) = JapanFiscalScenarioAssumption(;
    assumption_id = id,
    concept = concept,
    magnitude = magnitude,
    magnitude_source = :assumed_default,
    notes = "デモの既定値（観測値ではない）。",
)

"family ごとの explicit assumption（FRE context とは独立に magnitude を明示する）。"
const JF_DEMO_ASSUMPTIONS = Dict(
    :low_growth_high_rates => [
        _jf_demo_a("growth", :growth_path, -0.5),
        _jf_demo_a("policy-rate", :policy_rate, 0.5),
        _jf_demo_a("long-rate", :long_rate_funding_condition, 30.0),
    ],
    :fiscal_consolidation =>
        [_jf_demo_a("spending", :government_spending, -2.0), _jf_demo_a("tax", :tax, 0.01)],
    :financial_repression => [
        _jf_demo_a("policy-rate", :policy_rate, -0.25),
        _jf_demo_a("inflation", :inflation, 1.0),
        _jf_demo_a("cb-absorption", :cb_jgb_absorption, 2.0),
    ],
    :high_growth_productivity => [_jf_demo_a("productivity", :productivity_growth, 0.5)],
    :jgb_funding_cost => [_jf_demo_a("long-rate", :long_rate_funding_condition, 50.0)],
)

function _jf_demo_scenario(family::Symbol, assumptions; suffix = "")
    return JapanFiscalScenario(;
        scenario_id = "demo-$(replace(String(family), '_' => '-'))$(suffix)",
        family = family,
        name = japan_fiscal_family_spec(family).display_name,
        fre_context = jf_demo_fre_context(),
        assumptions = assumptions,
        provenance = JapanFiscalScenarioProvenance(; assumption_source = :preset),
    )
end

"デモで実行する case（各 family の primary セル + 表現不能セル + assumption 未指定）。"
function jf_demo_cases()
    cases = JapanFiscalHandoffCase[]
    for f in JAPAN_FISCAL_SCENARIO_FAMILIES
        sc = _jf_demo_scenario(f, JF_DEMO_ASSUMPTIONS[f])
        primary = first(japan_fiscal_implementation_candidates(f))
        cell = japan_fiscal_model_mapping(f, primary)
        push!(
            cases,
            JapanFiscalHandoffCase(;
                case_id = "$(sc.scenario_id)-$(primary)",
                purpose = "$(japan_fiscal_family_spec(f).display_name) の primary セル",
                tags = [cell.representability],
                scenario = sc,
                model = primary,
            ),
        )
    end
    # 表現不能セル: 財政再建を New Keynesian で（需要ショックを財政緊縮の代理にしない）
    sc_f2 = _jf_demo_scenario(:fiscal_consolidation, JF_DEMO_ASSUMPTIONS[:fiscal_consolidation])
    push!(
        cases,
        JapanFiscalHandoffCase(;
            case_id = "demo-fiscal-consolidation-new-keynesian",
            purpose = "not_representable セル（実行しない）",
            tags = [:not_representable],
            scenario = sc_f2,
            model = :new_keynesian,
        ),
    )
    # 必須概念（税）の未指定: 0 とみなして実行しない
    sc_missing = _jf_demo_scenario(
        :fiscal_consolidation,
        [_jf_demo_a("spending", :government_spending, -2.0)];
        suffix = "-missing-tax",
    )
    push!(
        cases,
        JapanFiscalHandoffCase(;
            case_id = "demo-fiscal-consolidation-missing-tax-sim",
            purpose = "必須概念（税）の assumption 未指定（実行しない）",
            tags = [:missing_required_assumption],
            scenario = sc_missing,
            model = :sim,
        ),
    )
    return cases
end

function _jf_demo_describe(io::IO, case::JapanFiscalHandoffCase, a)
    println(io, "── ", case.case_id, "（", case.purpose, "）")
    if a isa JapanFiscalScenarioRejection
        println(io, "   実行しない: rejection_code=", a.rejection_code, " representability=", a.representability)
        println(io, "   理由: ", a.reason)
        return
    end
    cov = a.coverage
    println(
        io,
        "   representability=",
        cov.representability,
        " claim_level=",
        cov.claim_level,
        " numeric_semantics=",
        cov.numeric_semantics,
        " family_complete=",
        cov.family_complete,
    )
    for x in a.assumption_disposition
        println(io, "   assumption ", x.concept, ": ", x.assumption_state, " / ", x.model_input)
    end
    for v in a.diagnostics.variables
        line = "   $(v): 方向=$(a.diagnostics.direction[v])"
        if a.diagnostics.peak !== nothing
            line *= "  onset=ショック後 $(something(a.diagnostics.onset_period[v], "—")) 期" *
                    "  peak=ショック後 $(something(a.diagnostics.peak[v].period, "—")) 期"
        end
        println(io, line)
    end
    isempty(cov.unsupported_concepts) ||
        println(io, "   モデルが受け取れない概念: ", cov.unsupported_concepts)
    isempty(cov.unsupported_outputs) || println(io, "   モデルが返さない出力: ", cov.unsupported_outputs)
    println(io, "   覆われていない因果チャネル: ", cov.uncovered_channels)
    for c in cov.major_caveats
        println(io, "   注意: ", c)
    end
    return
end

"""
    run_japan_fiscal_scenario_lab_demo(; outdir, verbose=true, generated_at=now(UTC))

デモ全体を実行する。`<outdir>/handoff/` に handoff bundle を書き、読み戻した bundle と各 case の
replay 結果を返す。
"""
function run_japan_fiscal_scenario_lab_demo(;
    outdir::AbstractString,
    verbose::Bool = true,
    generated_at::DateTime = now(UTC),
)
    io = verbose ? stdout : devnull
    cases = jf_demo_cases()

    # 1. public API で 1 case ずつ実行する（result か rejection かを型で分岐する）
    for c in cases
        a = japan_fiscal_run(c.model, c.scenario; horizon = c.horizon, generated_at = generated_at)
        _jf_demo_describe(io, c, a)
    end

    # 2. handoff bundle を書き、fail closed で読み戻し、replay する
    bundle_dir = joinpath(outdir, "handoff")
    write_japan_fiscal_handoff(bundle_dir, cases; generated_at = generated_at)
    bundle = load_japan_fiscal_handoff(bundle_dir)
    replays = [replay_japan_fiscal_handoff_case(bundle, c.case_id) for c in cases]
    println(io)
    println(io, "handoff bundle: ", bundle_dir)
    println(io, "  schema_version: ", bundle.index["schema_version"])
    println(io, "  bundle_content_hash: ", bundle.index["bundle_content_hash"])
    println(io, "  replay（hash 完全一致）: ", all(r -> r.exact_match, replays))
    return (bundle_dir = bundle_dir, bundle = bundle, replays = replays, cases = cases)
end

if abspath(PROGRAM_FILE) == @__FILE__
    outdir = get(
        ENV,
        "JAPAN_FISCAL_DEMO_OUTDIR",
        joinpath(@__DIR__, "..", "artifacts", "japan_fiscal_scenario_lab_demo"),
    )
    println(
        """
Japan Fiscal Scenario Lab デモ
  出力先: $(outdir)

注意: FRE snapshot・assumption はすべて架空の例示値。FRE の score は shock magnitude に使わない。
      model-implied result は forecast / probability ではなく、日本の量でもない。
""",
    )
    run_japan_fiscal_scenario_lab_demo(; outdir = outdir)
end
