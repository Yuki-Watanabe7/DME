# test_keen_sfc_comparison.jl: Keen–SFC 概念対応・非対応と比較レポート（Issue #151 / Phase 5）
#
# 検証観点（Issue #151 受け入れ条件・テスト項目）:
#   1. 概念対応 registry の契約（民間債務を equivalent と誤判定しない・不変条件の強制）
#   2. 政府負債（SIM の H）と企業債務（Keen の d）を同一視しない
#   3. SIM に存在しない金融不安定性指標を生成しない
#   4. comparable な synthetic 系列だけ比較 API v2 の metric を返す
#   5. LLM provider なしの決定的 fallback と、禁止解釈 fixture の検出
#
# すべて外部通信なしで決定的。

using Test
using DME

# ===========================================================================
# fixture provider（固定 JSON を返す。keen_llm_eval.jl の同種 helper とは独立）
# ===========================================================================

struct KSFCFixtureProvider <: DME.AbstractLLMProvider
    content::String
end

function DME.complete(p::KSFCFixtureProvider, ::DME.LLMRequest)::DME.LLMResponse
    DME.LLMResponse(p.content, "ksfc-fixture", "stop", nothing, nothing)
end

# ===========================================================================
# Keen–SFC 固有の安全性評価器（schema は通るが禁止解釈を含む応答を検出する）
# ===========================================================================

# 否定で閉じる文は禁止解釈ではない（「同一視しない」「生成しない」等）
const KSFC_NEGATION = r"(ない|ません|せず|不可|禁止|対象外|比較しない)"

# 肯定方向の禁止解釈（文単位で検査する）
const KSFC_FORBIDDEN_RULES = Tuple{Regex, Symbol}[
    # 政府負債（SIM の H）と民間・企業債務（Keen の d）の同一視
    (
        r"(政府貨幣|政府負債)[^。]{0,60}(民間債務|企業債務|Keen の d)[^。]{0,30}(同一|等価|equivalent|同じ|代理|合算)",
        :debt_concepts_conflated,
    ),
    (
        r"(民間債務|企業債務|債務比率)[^。]{0,60}(政府貨幣|政府負債)[^。]{0,30}(同一|等価|equivalent|同じ|代理|合算)",
        :debt_concepts_conflated,
    ),
    # SIM に存在しない金融不安定性指標の生成
    (
        r"SIM[^。]{0,60}(資金調達区分|Ponzi|Speculative|危機regime|金融不安定性指標|レバレッジ)[^。]{0,30}(を示す|を生成|を算出|を検出|が発生|に陥る|を持つ|できる)",
        :sim_financial_instability,
    ),
    # 比較不能概念の equivalent 化・統合
    (
        r"(比較不能|incompatible)[^。]{0,60}(equivalent|同値|同一指標|統合し|平均し|単一の指標)",
        :incompatible_as_equivalent,
    ),
    (
        r"(民間債務|企業債務|賃金シェア|利潤シェア|雇用率|資金調達区分|会計閉鎖)[^。]{0,40}(equivalent|同値|等価)",
        :incompatible_as_equivalent,
    ),
]

ksfc_sentences(text::AbstractString) = split(text, "。"; keepempty = false)

"""
    ksfc_safety_violations(out, ctx) -> Vector{NamedTuple}

`CrossModelReasoningOutput` を Issue #151 の安全性契約に照らして意味的に検査する。
production parser（`parse_cross_model_response`）が schema・source を検証するのに対し、
本評価器は「schema は通るが禁止解釈を含む」応答を回帰として検出する。
"""
function ksfc_safety_violations(
    out::CrossModelReasoningOutput,
    ctx::CrossModelComparisonContext,
)
    V = NamedTuple{(:rule, :section, :detail), Tuple{Symbol, String, String}}
    violations = V[]
    push_v!(rule, section, detail) =
        push!(violations, (rule = rule, section = section, detail = detail))

    for key in CROSS_MODEL_OUTPUT_SECTION_ORDER
        sec = DME._xm_section(out, key)
        for cl in sec.claims
            isempty(cl.source_ids) &&
                push_v!(:empty_source_ids, key, "claim $(cl.claim_id) に source_ids がない")
            for sid in cl.source_ids
                haskey(ctx.sources, sid) || push_v!(
                    :source_not_in_registry,
                    key,
                    "claim $(cl.claim_id) の source '$(sid)' が registry に無い",
                )
            end
            for s in ksfc_sentences(cl.text)
                occursin(KSFC_NEGATION, s) && continue
                for (rx, rule) in KSFC_FORBIDDEN_RULES
                    occursin(rx, s) &&
                        push_v!(rule, key, "claim $(cl.claim_id): 禁止解釈「$(s)」")
                end
            end
        end
    end

    isempty(out.source_references) &&
        push_v!(:missing_source_references, "-", "source_references が空")
    occursin("投資判断", out.disclaimer) ||
        push_v!(:missing_disclaimer, "-", "免責文言が欠落")
    return violations
end

const KSFC_FIXTURE_DIR = joinpath(@__DIR__, "fixtures", "llm", "keen_sfc")

# 数値比較用の synthetic 系列（日付 metadata を持たない決定的な系列）
function ksfc_synthetic_results(; n::Int = 12)
    keen = SimulationResult(
        "Keen Model",
        "synthetic",
        Dict(
            "Y" => Float64[100.0 + 0.5t for t in 1:n],
            "ω" => Float64[0.60 + 0.001t for t in 1:n],
            "λ" => Float64[0.90 + 0.001t for t in 1:n],
            "d" => Float64[0.50 + 0.010t for t in 1:n],
        ),
        Dict{String, Any}(),
    )
    sim = SimulationResult(
        "SIM Model",
        "synthetic",
        Dict(
            "Y" => Float64[100.0 + 0.6t for t in 1:n],
            "C" => Float64[80.0 + 0.4t for t in 1:n],
            "H" => Float64[10.0 + 0.2t for t in 1:n],
            "N" => Float64[100.0 + 0.6t for t in 1:n],
        ),
        Dict{String, Any}(),
    )
    return keen, sim
end

@testset "Keen–SFC 概念対応・比較レポート（#151）" begin

    # =======================================================================
    # 1. registry の契約
    # =======================================================================
    @testset "概念対応 registry の契約" begin
        @test length(KEEN_SFC_CONCEPT_CORRESPONDENCES) == length(KEEN_SFC_CONCEPTS)
        @test Set(c.concept for c in KEEN_SFC_CONCEPT_CORRESPONDENCES) ==
              Set(KEEN_SFC_CONCEPTS)
        # 語彙は Phase 4 / Phase 5 と共有する
        for c in KEEN_SFC_CONCEPT_CORRESPONDENCES
            @test c.mapping_type in CROSS_MODEL_MAPPING_TYPES
            @test c.comparability in DME.COMPARABILITY_LEVELS
            @test !isempty(c.rationale)
            # 比較不能な概念は必ず「次に必要な追加モデル・系列・変換」を返す
            if c.mapping_type === :incompatible
                @test c.comparability === :incompatible
                @test !isempty(c.required_evidence)
            end
            # 根拠 source を必ず持つ
            @test !isempty(c.source_ids)
        end
        # 絞り込み
        @test all(
            c -> c.mapping_type === :incompatible,
            keen_sfc_correspondences(; mapping_type = :incompatible),
        )
        @test length(keen_sfc_correspondences(; concept = :private_debt)) == 1
    end

    @testset "不変条件: incompatible に数値比較レベルを与えられない" begin
        @test_throws ArgumentError KeenSFCConceptCorrespondence(;
            concept = :private_debt,
            mapping_type = :incompatible,
            comparability = :comparable,
            rationale = "誤設定",
        )
        # equivalent は概念定義が真に等価な場合のみ許可される
        @test_throws ArgumentError KeenSFCConceptCorrespondence(;
            concept = :private_debt,
            mapping_type = :equivalent,
            comparability = :comparable,
            keen_concept_id = :keen_debt_ratio_d,
            sim_concept_id = :sim_money_stock_H,
            rationale = "民間債務と政府貨幣を等価とみなす誤設定",
        )
        # 未知の概念は受け付けない
        @test_throws ArgumentError KeenSFCConceptCorrespondence(;
            concept = :unknown_concept,
            mapping_type = :partial,
            comparability = :partial,
            rationale = "x",
        )
    end

    # =======================================================================
    # 2. 債務概念の非同一視
    # =======================================================================
    @testset "民間債務を equivalent と誤判定しない" begin
        pd = only(keen_sfc_correspondences(; concept = :private_debt))
        @test pd.mapping_type === :incompatible
        @test pd.comparability === :incompatible
        @test pd.keen_variable == "d"
        @test pd.sim_variable === nothing
        @test any(occursin("代理として用いない", c) for c in pd.caveats)
        # ModelConceptMapping（Phase 4 型）へ写しても incompatible のまま
        m = keen_sfc_concept_mapping(pd)
        @test m isa ModelConceptMapping
        @test m.source_model === :keen && m.target_model === :sim
        @test m.mapping_type === :incompatible
        # equivalent / proxy な mapping は 1 件も存在しない
        @test isempty(keen_sfc_correspondences(; mapping_type = :equivalent))
        @test isempty(keen_sfc_correspondences(; mapping_type = :proxy))
    end

    @testset "政府負債と企業債務を同一視しない" begin
        gl = only(keen_sfc_correspondences(; concept = :government_liability))
        hw = only(keen_sfc_correspondences(; concept = :household_financial_wealth))
        @test gl.mapping_type === :incompatible
        @test hw.mapping_type === :incompatible
        @test gl.sim_variable == "H" && gl.keen_variable === nothing
        @test hw.sim_variable == "H" && hw.keen_variable === nothing
        @test any(
            c -> occursin("民間債務", c) && occursin("同一", c) && occursin("しない", c),
            gl.caveats,
        )
        # 概念定義 registry 上も等価にならない
        h = only(filter(d -> d.concept_id === :sim_money_stock_H, concept_definitions(:sim)))
        d = only(filter(d -> d.concept_id === :keen_debt_ratio_d, concept_definitions(:keen)))
        @test !concept_definitions_equivalent(h, d)
    end

    # =======================================================================
    # 3. SIM に無い金融不安定性指標を生成しない
    # =======================================================================
    @testset "SIM に存在しない金融不安定性・分配指標を生成しない" begin
        unavailable = keen_sfc_sim_unavailable_indicators()
        for key in ("private_debt", "financing_regime", "wage_share", "profit_share",
            "employment_rate")
            @test key in unavailable
        end
        # SIM 固有概念（会計閉鎖・政府負債）は「SIM が持たない指標」ではない
        @test !("accounting_closure" in unavailable)
        @test !("government_liability" in unavailable)

        # SIM 側 synthetic 結果に d / ω / λ 相当の系列があっても metric を返さない
        keen, sim = ksfc_synthetic_results()
        sim_with_extra = SimulationResult(
            sim.model_name,
            sim.scenario_name,
            merge(sim.variables, Dict("d" => fill(0.5, 12), "ω" => fill(0.6, 12))),
            sim.metadata,
        )
        report = compare_keen_sfc(;
            keen_result = keen,
            sim_result = sim_with_extra,
            allow_period_index = true,
        )
        for key in unavailable
            @test !haskey(report.numeric_comparisons, key)
        end
        @test any(
            w -> occursin("金融不安定性指標", w) && occursin("生成しない", w),
            report.warnings,
        )
    end

    # =======================================================================
    # 4. comparable な系列だけ v2 metric を返す
    # =======================================================================
    @testset "comparable な synthetic 系列だけ v2 metric を返す" begin
        keen, sim = ksfc_synthetic_results()

        # 系列を渡さない場合は数値比較を一切行わない
        structural = compare_keen_sfc()
        @test isempty(structural.numeric_comparisons)
        @test length(structural.skipped_comparisons) ==
              length(KEEN_SFC_CONCEPT_CORRESPONDENCES)
        @test all(haskey(s, "reason") for s in structural.skipped_comparisons)

        # 日付 metadata が無い系列は明示許可が無い限り比較しない（#150 の契約）
        strict = compare_keen_sfc(; keen_result = keen, sim_result = sim)
        @test isempty(strict.numeric_comparisons)
        @test any(
            s -> s["concept"] == "aggregate_output" && occursin("降格", s["reason"]),
            strict.skipped_comparisons,
        )

        # 明示許可すると partial 対応の総産出のみ metric を返す
        report = compare_keen_sfc(;
            keen_result = keen,
            sim_result = sim,
            allow_period_index = true,
        )
        @test collect(keys(report.numeric_comparisons)) == ["aggregate_output"]
        r = report.numeric_comparisons["aggregate_output"]
        @test r.mode === :trajectory
        @test r.assessment.level === :partial
        @test haskey(r.metrics, "Y")
        @test isfinite(r.metrics["Y"].rmse)
        # Keen 側に系列が無い概念は不実施理由付きで残る
        skipped = Dict(s["concept"] => s for s in report.skipped_comparisons)
        @test haskey(skipped, "household_consumption")
        @test occursin("Keen 側に対応系列", skipped["household_consumption"]["reason"])
        @test occursin("比較不能", skipped["private_debt"]["reason"])
        @test !isempty(skipped["private_debt"]["required_evidence"])
    end

    # =======================================================================
    # 5. レポート構造・構造差分・出力項目
    # =======================================================================
    @testset "レポートの出力項目（Issue #151 の出力）" begin
        report = compare_keen_sfc()
        @test report.contract_version == KEEN_SFC_COMPARISON_CONTRACT_VERSION
        @test report.models == [:keen, :sim]
        # 共通概念（equivalent）は存在しない → 隠さず空で返し warning を出す
        @test isempty(report.shared_concepts)
        @test any(occursin("厳密に等価", w) for w in report.warnings)
        # 部分対応・比較不能
        @test Set(c.concept for c in report.partial_concepts) ==
              Set([:aggregate_output, :household_consumption])
        @test length(report.incomparable_concepts) == 9

        # 会計構造と動学機構の違い（#149 能力 metadata の構造化差分）
        diff = report.structural_differences
        @test diff["left_model"] == "keen" && diff["right_model"] == "sim"
        @test diff["accounting_closure"]["left"] == "none"
        @test diff["accounting_closure"]["right"] == "stock_flow_consistent"
        @test diff["accounting_closure"]["differs"]
        @test diff["endogenous_credit"]["left"] && !diff["endogenous_credit"]["right"]
        @test "government" in diff["sectors"]["right_only"]
        @test "bank" in diff["sectors"]["left_only"]
        @test diff["treatments"]["income_distribution"]["differs"]
        @test diff["treatments"]["fiscal_policy"]["differs"]

        # 各モデルが適する分析問い
        q = report.suitable_questions
        @test !isempty(q["keen"]) && !isempty(q["sim"])
        @test any(occursin("危機regime", s) for s in q["keen"])
        @test any(occursin("stock-flow consistency", s) for s in q["sim"])

        # 次期 Minsky-SFC で埋めるべきギャップ
        @test !isempty(report.minsky_sfc_gaps)
        @test any(occursin("銀行部門", g) for g in report.minsky_sfc_gaps)
        @test report.minsky_sfc_gaps == unique(report.minsky_sfc_gaps)
        # 比較を可能にするために必要な追加モデル・系列・変換
        @test !isempty(report.required_evidence)

        # JSON 化（round-trip はせず、必須キーの存在のみ検証）
        d = to_dict(report)
        for k in ("shared_concepts", "partial_concepts", "incomparable_concepts",
            "structural_differences", "numeric_comparisons", "skipped_comparisons",
            "suitable_questions", "minsky_sfc_gaps", "required_evidence", "context")
            @test haskey(d, k)
        end
        @test length(to_json(report)) > 0
    end

    # =======================================================================
    # 6. Phase 4 クロスモデル推論契約への接続
    # =======================================================================
    @testset "Phase 4 契約への接続（context・source registry）" begin
        ctx = build_keen_sfc_comparison_context()
        @test ctx.models == [:keen, :sim]
        @test ctx.contract_version == CROSS_MODEL_CONTEXT_CONTRACT_VERSION
        # 比較軸 mapping ＋ Keen–SFC 概念対応が加算されている
        @test length(ctx.mappings) ==
              length(CROSS_MODEL_CONCEPTS) + length(KEEN_SFC_CONCEPTS)
        @test any(m -> m.concept === :private_debt, ctx.mappings)
        # 根拠 source（モデル文書・能力 metadata・SFC 会計 check）が登録されている
        for sid in (
            KEEN_SFC_SOURCE_IDS.doc_keen,
            KEEN_SFC_SOURCE_IDS.doc_sim,
            KEEN_SFC_SOURCE_IDS.capability_keen,
            KEEN_SFC_SOURCE_IDS.capability_sim,
            KEEN_SFC_SOURCE_IDS.accounting_sim,
            KEEN_SFC_SOURCE_IDS.limitation,
            "mapping.keen.sim.private_debt",
        )
            @test haskey(ctx.sources, sid)
        end
        # 比較不能概念は insufficient_comparability として返る
        incomp = insufficient_comparability_concepts(ctx)
        for con in
            (:private_debt, :wage_share, :employment_rate, :accounting_closure, :fiscal_policy)
            @test con in incomp
        end
        @test !(:aggregate_output in incomp)
        # 安全性 warning
        codes = Set(w.code for w in ctx.warnings)
        @test "DEBT_CONCEPTS_NOT_INTERCHANGEABLE" in codes
        @test "SIM_NO_FINANCIAL_INSTABILITY" in codes
        @test "KEEN_SFC_INSUFFICIENT_COMPARABILITY" in codes
    end

    @testset "MODEL_CONCEPT_REGISTRY への :sim 登録（ADR 0007 §7）" begin
        cov = model_concept_coverage(; model = :sim)
        @test length(cov) == length(CROSS_MODEL_CONCEPTS)
        by = Dict(c.concept => c for c in cov)
        @test by[:private_debt_credit].treatment === :out_of_scope
        @test by[:income_distribution].treatment === :out_of_scope
        @test by[:demand_and_instability].treatment === :approximate
        @test by[:steady_state_stability].treatment === :endogenous
        @test by[:shock_response].treatment === :endogenous
        # Keen との比較軸 mapping は private_debt_credit / income_distribution で incompatible
        base = build_cross_model_comparison_context(; models = [:keen, :sim])
        bym = Dict(m.concept => m for m in base.mappings)
        @test bym[:private_debt_credit].mapping_type === :incompatible
        @test bym[:income_distribution].mapping_type === :incompatible
        # 概念定義 metadata（#149）への橋渡しが機能する
        defs = coverage_concept_definitions(by[:demand_and_instability])
        @test any(d -> d.concept_id === :sim_output_Y, defs)
    end

    # =======================================================================
    # 7. LLM 説明: 決定的生成・fallback・禁止解釈 fixture
    # =======================================================================
    @testset "provider 未接続の決定的生成" begin
        report = compare_keen_sfc()
        out = explain_keen_sfc_comparison(report)
        @test out isa CrossModelReasoningOutput
        @test out.generation_status === :deterministic
        @test out.contract_version == CROSS_MODEL_OUTPUT_CONTRACT_VERSION
        @test out.incomparable_or_insufficient.status === :insufficient_comparability
        @test !isempty(out.source_references)
        # 決定的出力は安全性評価器を通過する
        @test isempty(ksfc_safety_violations(out, report.context))
        # 比較不能概念が説明本文に現れる
        text = join([cl.text for cl in out.incomparable_or_insufficient.claims], " ")
        for label in ("民間（企業）債務", "賃金シェア", "雇用率", "会計閉鎖")
            @test occursin(label, text)
        end
    end

    @testset "provider 応答が壊れている場合は決定的 fallback" begin
        report = compare_keen_sfc()
        out = explain_keen_sfc_comparison(
            report;
            provider = KSFCFixtureProvider("これは JSON ではありません"),
        )
        @test out.generation_status === :fallback
        @test any(w -> w.code == "OUTPUT_SCHEMA_INVALID", out.warnings)
        @test isempty(ksfc_safety_violations(out, report.context))
    end

    @testset "forbidden fixture: schema は通るが禁止解釈を検出する" begin
        expected = Dict(
            "government_liability_as_private_debt.json" => :debt_concepts_conflated,
            "sim_financial_instability.json" => :sim_financial_instability,
            "incompatible_as_equivalent.json" => :incompatible_as_equivalent,
        )
        report = compare_keen_sfc()
        dir = joinpath(KSFC_FIXTURE_DIR, "forbidden")
        files = sort(filter(f -> endswith(f, ".json"), readdir(dir)))
        @test Set(files) == Set(keys(expected))
        for f in files
            content = read(joinpath(dir, f), String)
            # production parser は schema・source 検証を通す（禁止解釈は検出できない）
            parsed = parse_cross_model_response(content, report.context)
            @test parsed !== nothing
            out = explain_keen_sfc_comparison(
                report;
                provider = KSFCFixtureProvider(content),
            )
            @test out.generation_status === :parsed
            # 安全性評価器が禁止解釈を検出する
            vs = ksfc_safety_violations(out, report.context)
            @test !isempty(vs)
            @test expected[f] in Set(v.rule for v in vs)
        end
    end
end
