# keen_sfc_comparison.jl: Keen（Minsky 系）モデルと最小 SIM 型 SFC モデルの
# 概念対応・非対応・比較レポート層（Issue #151 / Phase 5）
#
# 目的（Issue #151）:
#   Keen と SIM の概念・機構・会計範囲を比較し、同値・proxy・部分対応・比較不能を
#   根拠付きで報告する。SIM が持たない企業債務・雇用率・賃金シェア・利潤シェア・
#   内生的金融不安定性、および Keen が持たない部門別 SFC 会計閉鎖・政府部門を、
#   欠陥として隠さず「モデルが答えられる問いの違い」として構造化する。
#
# 設計方針:
#   - 概念対応は #149 の `ModelCapabilityProfile` / `ModelConceptDefinition` を根拠にする。
#   - 数値比較の可否は #150 の `compare_results_v2` / `ComparabilityAssessment` に委ねる。
#     比較不能・情報不足の組合せは metric を計算せず、理由と必要な追加証拠を返す。
#   - 概念対応そのものは Phase 4（ADR 0006）の `ModelConceptMapping` を再利用し、
#     `CrossModelComparisonContext` / `CrossModelReasoningOutput` へ互換拡張として載せる。
#   - equivalent は概念定義（`concept_definitions_equivalent`）が真に一致する場合のみ許す。
#     民間債務・政府負債・金融不安定性指標を equivalent／proxy と誤判定しない。
#
# 依存: core/model_capabilities.jl（#149）、core/compare_v2.jl（#150）、
#       llm/cross_model_reasoning.jl（ADR 0006 の型・context・出力）。
# 参照: docs/analysis/keen_sfc_comparison.md、ADR 0006、ADR 0007 §7・§11。

# ===========================================================================
# 契約 version と概念語彙
# ===========================================================================

"""Keen–SFC 比較レポートの契約 version。"""
const KEEN_SFC_COMPARISON_CONTRACT_VERSION = "keen-sfc-comparison/1.0.0"

"""比較対象モデル（左＝Keen、右＝SIM）。"""
const KEEN_SFC_MODELS = (:keen, :sim)

"""
Keen–SIM 比較で扱う概念語彙。ADR 0006 の 5 つの比較軸（`CROSS_MODEL_CONCEPTS`）よりも
細かい変数・概念単位で、両モデルの対応・非対応を明示する。
"""
const KEEN_SFC_CONCEPTS = (
    :aggregate_output,             # 総産出・総所得
    :household_consumption,        # 家計消費
    :household_financial_wealth,   # 家計の金融資産ストック（SIM 固有）
    :government_liability,         # 政府負債（SIM 固有）
    :private_debt,                 # 民間（企業）債務・レバレッジ（Keen 固有）
    :financing_regime,             # 資金調達区分 Hedge/Speculative/Ponzi（Keen 固有）
    :wage_share,                   # 賃金シェア（Keen 固有）
    :profit_share,                 # 利潤シェア（Keen 固有）
    :employment_rate,              # 雇用率（Keen 固有）
    :accounting_closure,           # 会計閉鎖（stock-flow consistency。SIM 固有）
    :fiscal_policy,                # 財政政策（SIM 固有）
)

# 概念 → 表示名。クロスモデル推論層の表示辞書へ load 時に登録し、
# `_xm_concept_label` が Keen–SFC 概念にも日本語ラベルを返せるようにする。
const KEEN_SFC_CONCEPT_LABELS = Dict{Symbol, String}(
    :aggregate_output => "総産出・総所得",
    :household_consumption => "家計消費",
    :household_financial_wealth => "家計の金融資産ストック",
    :government_liability => "政府負債",
    :private_debt => "民間（企業）債務・レバレッジ",
    :financing_regime => "資金調達区分（Hedge/Speculative/Ponzi）",
    :wage_share => "賃金シェア",
    :profit_share => "利潤シェア",
    :employment_rate => "雇用率",
    :accounting_closure => "会計閉鎖（stock-flow consistency）",
    :fiscal_policy => "財政政策",
)

merge!(_XM_CONCEPT_LABELS, KEEN_SFC_CONCEPT_LABELS)

# 根拠 source ID（安定。^[a-z][a-z0-9_.-]*$）
const KEEN_SFC_SOURCE_IDS = (
    doc_keen = "doc.keen.model",
    doc_sim = "doc.sim.model",
    capability_keen = "capability.keen",
    capability_sim = "capability.sim",
    accounting_sim = "accounting.sim.check",
    limitation = "limitation.keen_sfc_contract",
)

# ===========================================================================
# KeenSFCConceptCorrespondence
# ===========================================================================

"""
    KeenSFCConceptCorrespondence

Keen と SIM の 1 概念の対応・非対応。Phase 4 の `ModelConceptMapping`（mapping_type）と
Phase 5 比較 API v2 の `COMPARABILITY_LEVELS`（数値比較の可否）を分けて保持する。

「概念として対応するか」（`mapping_type`）と「数値比較してよいか」（`comparability`）は
別問題であり、対応があっても単位・時間軸・出力系列が揃わなければ数値比較はしない。

## フィールド
- `concept::Symbol` : `KEEN_SFC_CONCEPTS` の 1 つ
- `label::String` : 表示名
- `mapping_type::Symbol` : `CROSS_MODEL_MAPPING_TYPES`（equivalent/proxy/partial/incompatible）
- `comparability::Symbol` : `COMPARABILITY_LEVELS`（comparable/partial/insufficient/incompatible）
- `keen_variable` / `sim_variable::Union{String,Nothing}` : 対応するモデル変数（無ければ `nothing`）
- `keen_concept_id` / `sim_concept_id::Union{Symbol,Nothing}` : `MODEL_CONCEPT_DEFINITION_REGISTRY` の id
- `unit_difference` / `frequency_difference::Union{String,Nothing}` : 差が無ければ `nothing`
- `rationale::String` : 対応・非対応の根拠
- `caveats::Vector{String}` : 誤用防止の注意（同一視の禁止など）
- `required_evidence::Vector{String}` : 比較可能にするために必要な追加モデル・系列・変換
- `source_ids::Vector{String}` : 根拠 source registry の ID
- `doc_refs::Vector{String}` : 根拠 docs のパス・節

## 不変条件
- `mapping_type === :incompatible` なら `comparability === :incompatible`（比較不能な概念で
  数値 metric を計算しない）。
- `mapping_type === :equivalent` は両側の `ModelConceptDefinition` が登録済みかつ
  [`concept_definitions_equivalent`](@ref) を満たす場合のみ許可する（同名・類似概念の誤等値化を防ぐ）。
"""
struct KeenSFCConceptCorrespondence
    concept::Symbol
    label::String
    mapping_type::Symbol
    comparability::Symbol
    keen_variable::Union{String, Nothing}
    sim_variable::Union{String, Nothing}
    keen_concept_id::Union{Symbol, Nothing}
    sim_concept_id::Union{Symbol, Nothing}
    unit_difference::Union{String, Nothing}
    frequency_difference::Union{String, Nothing}
    rationale::String
    caveats::Vector{String}
    required_evidence::Vector{String}
    source_ids::Vector{String}
    doc_refs::Vector{String}
end

function KeenSFCConceptCorrespondence(;
    concept::Symbol,
    mapping_type::Symbol,
    comparability::Symbol,
    rationale::String,
    label::String = get(KEEN_SFC_CONCEPT_LABELS, concept, String(concept)),
    keen_variable::Union{String, Nothing} = nothing,
    sim_variable::Union{String, Nothing} = nothing,
    keen_concept_id::Union{Symbol, Nothing} = nothing,
    sim_concept_id::Union{Symbol, Nothing} = nothing,
    unit_difference::Union{String, Nothing} = nothing,
    frequency_difference::Union{String, Nothing} = nothing,
    caveats::Vector{String} = String[],
    required_evidence::Vector{String} = String[],
    source_ids::Vector{String} = String[],
    doc_refs::Vector{String} = String[],
)
    concept in KEEN_SFC_CONCEPTS || throw(
        ArgumentError("未知の concept: $(repr(concept))（有効: $(KEEN_SFC_CONCEPTS)）"),
    )
    mapping_type in CROSS_MODEL_MAPPING_TYPES || throw(
        ArgumentError(
            "未知の mapping_type: $(repr(mapping_type))（有効: $(CROSS_MODEL_MAPPING_TYPES)）",
        ),
    )
    comparability in COMPARABILITY_LEVELS || throw(
        ArgumentError(
            "未知の comparability: $(repr(comparability))（有効: $(COMPARABILITY_LEVELS)）",
        ),
    )
    if mapping_type === :incompatible && comparability !== :incompatible
        throw(
            ArgumentError(
                "concept=$(concept): mapping_type=incompatible の概念に comparability=$(comparability) は許可しません（数値比較しない）。",
            ),
        )
    end
    if mapping_type === :equivalent
        a = _v2_concept_by_id(keen_concept_id)
        b = _v2_concept_by_id(sim_concept_id)
        (a !== nothing && b !== nothing && concept_definitions_equivalent(a, b)) || throw(
            ArgumentError(
                "concept=$(concept): equivalent は両モデルの概念定義が登録済みかつ真に等価な場合のみ許可します。",
            ),
        )
    end
    return KeenSFCConceptCorrespondence(
        concept,
        label,
        mapping_type,
        comparability,
        keen_variable,
        sim_variable,
        keen_concept_id,
        sim_concept_id,
        unit_difference,
        frequency_difference,
        rationale,
        caveats,
        required_evidence,
        source_ids,
        doc_refs,
    )
end

# 共通 source 束（docs・能力 metadata）
const _KSFC_BASE_SOURCES = String[
    KEEN_SFC_SOURCE_IDS.doc_keen,
    KEEN_SFC_SOURCE_IDS.doc_sim,
    KEEN_SFC_SOURCE_IDS.capability_keen,
    KEEN_SFC_SOURCE_IDS.capability_sim,
]

_ksfc_sources(extra::AbstractVector{String} = String[]) =
    unique(vcat(_KSFC_BASE_SOURCES, extra))

# ===========================================================================
# KEEN_SFC_CONCEPT_CORRESPONDENCES（registry）
# ===========================================================================

"""
    KEEN_SFC_CONCEPT_CORRESPONDENCES :: Vector{KeenSFCConceptCorrespondence}

Keen モデルと最小 SIM 型 SFC モデルの概念対応 registry（[`KEEN_SFC_CONCEPTS`](@ref) の各概念に
1件）。[`keen_sfc_correspondences`](@ref) で概念・`mapping_type`・`comparability` により
絞り込んで参照する。

根拠は docs（keen.md / sim_sfc.md / minsky_regime_diagnostics.md）と能力 metadata・概念定義
registry のみで、数値実証結果は含めない（ADR 0006 の「概念対応は repository metadata に限定する」）。
"""
const KEEN_SFC_CONCEPT_CORRESPONDENCES = KeenSFCConceptCorrespondence[
    KeenSFCConceptCorrespondence(;
        concept = :aggregate_output,
        mapping_type = :partial,
        comparability = :partial,
        keen_variable = "Y",
        sim_variable = "Y",
        sim_concept_id = :sim_output_Y,
        unit_difference = "real output level (Keen) vs wage units (SIM)",
        frequency_difference = "continuous (annual params) vs period (discrete)",
        rationale = "両モデルとも総産出・総所得のフローを持つが、Keen は生産関数 Y=K/ν に基づく実物産出（連続時間・年単位パラメータ）、" *
                    "SIM は需要決定 Y=C+G（離散期・賃金単位）であり定義・単位・時間軸が異なる。部分対応に留める。",
        caveats = [
            "Keen の既定 simulate 出力は状態変数 (ω, λ, d) のみで産出水準 Y の系列を含まない。",
            "賃金単位（W 数値基準）と実質水準を暗黙に換算しない。",
        ],
        required_evidence = [
            "Keen 側の産出水準 Y 系列（既定出力に含まれないため観測方程式経由で構成する）。",
            "賃金単位 → 実質水準の明示的な単位換算（compare_results_v2 の transform として宣言）。",
            "年単位連続時間 ↔ 離散期の時間軸そろえ（docs/models/keen_empirical_strategy.md の Δt 契約）。",
        ],
        source_ids = _ksfc_sources([
            "concept.keen.demand_and_instability",
            "concept.sim.demand_and_instability",
        ]),
        doc_refs = ["docs/models/keen.md §2", "docs/models/sim_sfc.md §方程式"],
    ),
    KeenSFCConceptCorrespondence(;
        concept = :household_consumption,
        mapping_type = :partial,
        comparability = :partial,
        keen_variable = "C",
        sim_variable = "C",
        unit_difference = "real consumption level (Keen) vs wage units (SIM)",
        frequency_difference = "continuous (annual params) vs period (discrete)",
        rationale = "SIM は消費関数 C=α1·YD+α2·H_{t−1} を明示的に持つ。Keen は消費を独立の行動方程式として持たず、" *
                    "賃金所得と投資関数を通じた集約需要の構造に組み込んでいる。概念は共通するが決定機構が異なるため部分対応。",
        caveats = [
            "Keen の既定出力に消費系列はない（集約需要・投資構造から別途導出が必要）。",
            "SIM の C は前期末の貨幣ストック H_{t−1} に依存し、時点規約が Keen の瞬時値と異なる。",
        ],
        required_evidence = [
            "Keen 側の消費系列（集約需要と投資関数からの導出）。",
            "単位・時間軸をそろえる明示変換（transform）。",
        ],
        source_ids = _ksfc_sources([
            "concept.keen.demand_and_instability",
            "concept.sim.demand_and_instability",
        ]),
        doc_refs = ["docs/models/keen.md §2", "docs/models/sim_sfc.md §方程式"],
    ),
    KeenSFCConceptCorrespondence(;
        concept = :household_financial_wealth,
        mapping_type = :incompatible,
        comparability = :incompatible,
        sim_variable = "H",
        sim_concept_id = :sim_money_stock_H,
        rationale = "SIM 固有。家計は政府貨幣 H を唯一の金融資産として蓄積する（H は家計の資産かつ政府の負債）。" *
                    "Keen は家計の金融資産ストックを持たず、追跡するのは企業の債務比率 d のみである。",
        caveats = [
            "H を Keen の民間債務 d の代理として用いない。保有主体・発行主体・返済制約が異なる。",
        ],
        required_evidence = [
            "家計金融資産を内生化する部門構成（銀行預金・企業債務を含む SFC 拡張）。",
        ],
        source_ids = _ksfc_sources([
            "concept.keen.private_debt_credit",
            "concept.sim.private_debt_credit",
            KEEN_SFC_SOURCE_IDS.accounting_sim,
        ]),
        doc_refs = ["docs/models/sim_sfc.md §会計表"],
    ),
    KeenSFCConceptCorrespondence(;
        concept = :government_liability,
        mapping_type = :incompatible,
        comparability = :incompatible,
        sim_variable = "H",
        sim_concept_id = :sim_money_stock_H,
        rationale = "SIM の H は政府の負債（貨幣発行）である。Keen には政府部門が存在せず（fiscal_policy=:none）、" *
                    "政府負債という概念自体を持たない。",
        caveats = [
            "政府負債（SIM の H）と企業の民間債務（Keen の d）は発行主体・利払い構造・返済制約が異なる。同一の「債務」として集計・比較しない。",
        ],
        required_evidence = [
            "政府部門・国債・利払い・財政ルールを持つ Minsky-SFC モデル。",
        ],
        source_ids = _ksfc_sources([
            "concept.keen.shock_response",
            "concept.sim.shock_response",
            KEEN_SFC_SOURCE_IDS.accounting_sim,
        ]),
        doc_refs = [
            "docs/models/sim_sfc.md §会計表",
            "docs/adr/0007-sfc-integration-contract.md §1",
        ],
    ),
    KeenSFCConceptCorrespondence(;
        concept = :private_debt,
        mapping_type = :incompatible,
        comparability = :incompatible,
        keen_variable = "d",
        keen_concept_id = :keen_debt_ratio_d,
        rationale = "Keen 固有。投資が内部資金（利潤 π）を超える分を銀行借入で賄い、債務比率 d=D/Y が内生的に動く。" *
                    "SIM は銀行部門・企業債務を持たず（金融資産は政府貨幣 H のみ）、対応概念が存在しない。",
        caveats = [
            "SIM の H（政府貨幣）を民間債務の代理として用いない。equivalent・proxy いずれとしても扱わない。",
            "SIM 出力から民間債務比率・レバレッジ指標を生成しない。",
        ],
        required_evidence = [
            "銀行部門と企業向け貸出 instrument（:loan / :deposit）を持つ SFC 拡張（ADR 0007 §11）。",
        ],
        source_ids = _ksfc_sources([
            "concept.keen.private_debt_credit",
            "concept.sim.private_debt_credit",
        ]),
        doc_refs = ["docs/models/keen.md §2,§5", "docs/models/sim_sfc.md §限界"],
    ),
    KeenSFCConceptCorrespondence(;
        concept = :financing_regime,
        mapping_type = :incompatible,
        comparability = :incompatible,
        keen_variable = "d",
        keen_concept_id = :keen_debt_ratio_d,
        rationale = "Keen 固有。Minsky 診断層が利払い・元本返済代理仮定に基づき Hedge/Speculative/Ponzi を分類する。" *
                    "SIM は債務・利払いを持たないため資金調達区分を定義できない。",
        caveats = [
            "SIM 出力から金融不安定性指標（資金調達区分・カバレッジ比率・発散時点）を生成しない。",
            "Keen の regime は集計比率からの proxy 分類であり、企業別の実測分類ではない。",
        ],
        required_evidence = [
            "利子付き債務と元本返済フローを部門別取引フロー行列に持つ SFC 拡張。",
        ],
        source_ids = _ksfc_sources([
            "concept.keen.demand_and_instability",
            "concept.sim.demand_and_instability",
        ]),
        doc_refs = [
            "docs/models/minsky_regime_diagnostics.md",
            "docs/models/sim_sfc.md §限界",
        ],
    ),
    KeenSFCConceptCorrespondence(;
        concept = :wage_share,
        mapping_type = :incompatible,
        comparability = :incompatible,
        keen_variable = "ω",
        keen_concept_id = :keen_wage_share_omega,
        rationale = "Keen 固有。ω=W·L/Y を非線形 Phillips 曲線で動学化する。SIM は企業利潤ゼロ・賃金率 W を数値基準とするため" *
                    "賃金シェアが定義上一定であり、分配の動学（income_distribution=:none）を持たない。",
        caveats = ["SIM の恒等的な賃金シェアを ω の観測値・比較対象として扱わない。"],
        required_evidence = ["企業利潤と賃金交渉を内生化する SFC 拡張。"],
        source_ids = _ksfc_sources([
            "concept.keen.income_distribution",
            "concept.sim.income_distribution",
        ]),
        doc_refs = ["docs/models/keen.md §2", "docs/models/sim_sfc.md §限界"],
    ),
    KeenSFCConceptCorrespondence(;
        concept = :profit_share,
        mapping_type = :incompatible,
        comparability = :incompatible,
        keen_variable = "π",
        rationale = "Keen 固有。利潤シェア π=1−ω−r·d（利払い後）が投資関数を通じて債務動学へ帰還する。" *
                    "SIM は企業利潤ゼロを仮定するため利潤シェアが存在しない。",
        caveats = ["SIM の利潤ゼロ仮定を「利潤シェア 0 の実測」として扱わない。"],
        required_evidence = ["企業部門の利潤・内部留保・投資を内生化する SFC 拡張。"],
        source_ids = _ksfc_sources([
            "concept.keen.income_distribution",
            "concept.sim.income_distribution",
        ]),
        doc_refs = ["docs/models/keen.md §2", "docs/models/sim_sfc.md §限界"],
    ),
    KeenSFCConceptCorrespondence(;
        concept = :employment_rate,
        mapping_type = :incompatible,
        comparability = :incompatible,
        keen_variable = "λ",
        keen_concept_id = :keen_employment_rate_lambda,
        rationale = "Keen 固有。λ=L/N（労働需要/労働人口）が Goodwin 循環の中核を成す。SIM は雇用水準 N=Y/W を持つが" *
                    "労働人口（労働供給）を持たないため雇用率を構成できない。",
        caveats = [
            "SIM の N は産出を賃金率で割った雇用「水準」であり、比率である λ とは概念種別（ratio vs level）が異なる。同一視しない。",
        ],
        required_evidence = [
            "SIM 側に労働人口（労働供給）系列を追加し雇用率を定義する拡張。",
        ],
        source_ids = _ksfc_sources([
            "concept.keen.income_distribution",
            "concept.sim.income_distribution",
        ]),
        doc_refs = ["docs/models/keen.md §2", "docs/models/sim_sfc.md §方程式"],
    ),
    KeenSFCConceptCorrespondence(;
        concept = :accounting_closure,
        mapping_type = :incompatible,
        comparability = :incompatible,
        rationale = "SIM 固有。部門別貸借対照表・取引フロー行列を構成し、行和・列和・ストックフロー整合を全期検証する" *
                    "（accounting_closure=:stock_flow_consistent）。Keen はモデル内の債務蓄積式を持つが部門別 SFC 表を構成せず、" *
                    "能力 metadata 上は accounting_closure=:none。会計整合性の水準が異なるため比較不能とする。",
        caveats = [
            "Keen の内部恒等式を「SFC 検証済み」と述べない。",
            "会計恒等式が保証するのは内的整合性であって現実妥当性ではない。",
        ],
        required_evidence = [
            "Keen 系機構（銀行・企業債務）を部門別貸借対照表・取引フロー行列として表現する Minsky-SFC モデル。",
        ],
        source_ids = _ksfc_sources([KEEN_SFC_SOURCE_IDS.accounting_sim]),
        doc_refs = [
            "docs/adr/0007-sfc-integration-contract.md §4",
            "docs/model_capabilities.md",
        ],
    ),
    KeenSFCConceptCorrespondence(;
        concept = :fiscal_policy,
        mapping_type = :incompatible,
        comparability = :incompatible,
        sim_variable = "G",
        rationale = "SIM 固有。政府支出 G・税率 θ を政策変数として持ち財政ショックの移行経路を計算できる" *
                    "（fiscal_policy=:endogenous）。Keen には政府部門が無く（fiscal_policy=:none）、同一の財政ショック比較を行わない。",
        caveats = [
            "Keen 側に財政ショックを外挿して比較しない（政府部門が存在しないため定義できない）。",
        ],
        required_evidence = ["政府部門・財政ルールを持つ Minsky-SFC モデル。"],
        source_ids = _ksfc_sources([
            "concept.keen.shock_response",
            "concept.sim.shock_response",
        ]),
        doc_refs = ["docs/models/sim_sfc.md §財政ショック", "docs/models/keen.md §9"],
    ),
]

"""
    keen_sfc_correspondences(; concept=nothing, mapping_type=nothing, comparability=nothing)
        -> Vector{KeenSFCConceptCorrespondence}

[`KEEN_SFC_CONCEPT_CORRESPONDENCES`](@ref) を概念・mapping 種別・比較可能性で絞り込む。
すべて `nothing` なら全件を返す。
"""
function keen_sfc_correspondences(;
    concept::Union{Symbol, Nothing} = nothing,
    mapping_type::Union{Symbol, Nothing} = nothing,
    comparability::Union{Symbol, Nothing} = nothing,
)
    return filter(KEEN_SFC_CONCEPT_CORRESPONDENCES) do c
        (concept === nothing || c.concept === concept) &&
            (mapping_type === nothing || c.mapping_type === mapping_type) &&
            (comparability === nothing || c.comparability === comparability)
    end
end

"""
    keen_sfc_concept_mapping(c::KeenSFCConceptCorrespondence) -> ModelConceptMapping

対応を Phase 4（ADR 0006）の [`ModelConceptMapping`](@ref) へ写す。`source_model=:keen`,
`target_model=:sim`。`caveats` には根拠（rationale）と誤用防止の注意を併せて格納する。
"""
function keen_sfc_concept_mapping(c::KeenSFCConceptCorrespondence)
    return ModelConceptMapping(
        :keen,
        :sim,
        c.concept,
        c.mapping_type,
        c.keen_variable,
        c.sim_variable,
        c.unit_difference,
        c.frequency_difference,
        nothing,
        unique(vcat([c.rationale], c.caveats)),
        copy(c.source_ids),
    )
end

"""
    keen_sfc_concept_mappings(; kwargs...) -> Vector{ModelConceptMapping}

[`keen_sfc_correspondences`](@ref) の結果を `ModelConceptMapping` のベクトルへ写す。
"""
keen_sfc_concept_mappings(; kwargs...) = ModelConceptMapping[
    keen_sfc_concept_mapping(c) for c in keen_sfc_correspondences(; kwargs...)
]

"""
    keen_sfc_sim_unavailable_indicators() -> Vector{String}

SIM が構造上持たないため、SIM 出力から生成してはならない指標（Keen 固有の金融不安定性・
分配指標）の一覧。Keen 側に変数があり SIM 側に対応変数が無い比較不能概念から決定的に導出する。
レポート生成と回帰テストの共通契約として用いる。
"""
function keen_sfc_sim_unavailable_indicators()
    return String[
        String(c.concept) for
        c in KEEN_SFC_CONCEPT_CORRESPONDENCES if c.mapping_type === :incompatible &&
            c.keen_variable !== nothing &&
            c.sim_variable === nothing
    ]
end

# ===========================================================================
# 比較コンテキスト（ADR 0006 の CrossModelComparisonContext を互換拡張）
# ===========================================================================

function _ksfc_extra_sources(accounting_report)
    srcs = Dict{String, EvidenceSource}()
    srcs[KEEN_SFC_SOURCE_IDS.doc_keen] = EvidenceSource(;
        id = KEEN_SFC_SOURCE_IDS.doc_keen,
        category = :model_concept,
        context_path = "/docs/keen",
        label = "Keen モデル解説（docs/models/keen.md）",
        method_id = "docs/models/keen.md",
    )
    srcs[KEEN_SFC_SOURCE_IDS.doc_sim] = EvidenceSource(;
        id = KEEN_SFC_SOURCE_IDS.doc_sim,
        category = :model_concept,
        context_path = "/docs/sim",
        label = "最小 SIM 型 SFC モデル解説（docs/models/sim_sfc.md）",
        method_id = "docs/models/sim_sfc.md",
    )
    for (key, model) in (
        (KEEN_SFC_SOURCE_IDS.capability_keen, :keen),
        (KEEN_SFC_SOURCE_IDS.capability_sim, :sim),
    )
        p = model_capabilities(model)
        srcs[key] = EvidenceSource(;
            id = key,
            category = :model_concept,
            context_path = "/capabilities/$(model)",
            label = "$(p.display_name) の能力プロファイル metadata",
            method_id = MODEL_CAPABILITY_CONTRACT_VERSION,
        )
    end
    srcs[KEEN_SFC_SOURCE_IDS.accounting_sim] = EvidenceSource(;
        id = KEEN_SFC_SOURCE_IDS.accounting_sim,
        category = :model_output,
        context_path = "/accounting/sim",
        label = accounting_report === nothing ?
                "SIM の SFC 会計恒等式検証（validate_sfc_accounting。未実行）" :
                "SIM の SFC 会計恒等式検証（status=$(accounting_status_label(accounting_report.status)), " *
                "passed=$(accounting_report.checks_passed)/$(accounting_report.checks_performed)）",
        method_id = SFC_ACCOUNTING_METHODOLOGY_VERSION,
    )
    srcs[KEEN_SFC_SOURCE_IDS.limitation] = EvidenceSource(;
        id = KEEN_SFC_SOURCE_IDS.limitation,
        category = :limitations,
        context_path = "/warnings",
        label = "Keen–SFC 比較の安全性・限界（Issue #151 / ADR 0006・0007）",
        method_id = KEEN_SFC_COMPARISON_CONTRACT_VERSION,
    )
    return srcs
end

function _ksfc_extra_warnings(
    correspondences::Vector{KeenSFCConceptCorrespondence},
    accounting_report,
)
    warns = ExplanationWarning[]
    incompat = [c for c in correspondences if c.mapping_type === :incompatible]
    if !isempty(incompat)
        push!(
            warns,
            ExplanationWarning(;
                code = "KEEN_SFC_INSUFFICIENT_COMPARABILITY",
                severity = :warning,
                message = "Keen–SIM で比較不能な概念: " *
                          join([c.label for c in incompat], ", ") *
                          "。統合・平均・単一ランキングへ潰さず、必要な追加モデル・系列・変換を提示する。",
                affected_sections = [
                    "concept_mappings",
                    "incomparable_or_insufficient",
                    "next_evidence",
                ],
            ),
        )
    end
    push!(
        warns,
        ExplanationWarning(;
            code = "DEBT_CONCEPTS_NOT_INTERCHANGEABLE",
            severity = :warning,
            message = "SIM の政府貨幣 H（政府負債＝家計資産）と Keen の民間債務比率 d は発行主体・返済制約が異なる。" *
                      "同一の「債務」として同一視・集計・代理しない。",
            affected_sections = ["concept_mappings", "mechanisms_by_model"],
        ),
    )
    push!(
        warns,
        ExplanationWarning(;
            code = "SIM_NO_FINANCIAL_INSTABILITY",
            severity = :warning,
            message = "SIM は民間債務・利払い・資金調達区分・危機regime を持たない。" *
                      "SIM 出力から金融不安定性指標（" *
                      join(keen_sfc_sim_unavailable_indicators(), ", ") *
                      "）を生成しない。",
            affected_sections = ["mechanisms_by_model", "incomparable_or_insufficient"],
        ),
    )
    push!(
        warns,
        ExplanationWarning(;
            code = "KEEN_NO_SFC_CLOSURE",
            severity = :info,
            message = "Keen は部門別 SFC 表を構成しない（accounting_closure=:none）。会計整合性を SIM と同水準に述べない。" *
                      "また SIM の会計恒等式が保証するのは内的整合性であって現実妥当性ではない。",
            affected_sections = ["mechanisms_by_model", "limitations"],
        ),
    )
    if accounting_report !== nothing && !accounting_passed(accounting_report)
        push!(
            warns,
            ExplanationWarning(;
                code = "SFC_ACCOUNTING_VIOLATION",
                severity = :error,
                message = "SIM の会計恒等式検証に違反がある（status=$(accounting_status_label(accounting_report.status))）。" *
                          "会計的信頼性が損なわれているため、SIM 側の数値解釈を限定する。",
                affected_source_ids = [KEEN_SFC_SOURCE_IDS.accounting_sim],
                affected_sections = ["mechanisms_by_model", "limitations"],
            ),
        )
    end
    return warns
end

"""
    build_keen_sfc_comparison_context(; empirical=nothing, accounting_report=nothing,
        model_metadata=Dict{Symbol,ModelMetadata}(),
        correspondences=KEEN_SFC_CONCEPT_CORRESPONDENCES) -> CrossModelComparisonContext

Keen–SIM のクロスモデル比較コンテキストを構築する。ADR 0006 の
[`build_cross_model_comparison_context`](@ref)（5 つの比較軸）に、Issue #151 の Keen–SFC
概念対応（`KEEN_SFC_CONCEPTS`）を **加算的に** 重ねた互換拡張コンテキストを返す。

- `mappings` : 比較軸の mapping ＋ Keen–SFC 概念対応（`ModelConceptMapping`）
- `sources`  : 比較軸 coverage ＋ モデル文書・能力 metadata・SFC 会計 check・Keen 実証 metadata
- `warnings` : 比較不能概念・債務概念の非同一視・SIM の金融不安定性非対応・会計違反

`empirical` に `KeenEmpiricalContext` を渡すと Keen 実証結果 source が登録され、
`accounting_report` に [`validate_sfc_accounting`](@ref) の結果を渡すと会計 check source の
ラベルへ検証結果が反映される（違反があれば `SFC_ACCOUNTING_VIOLATION` warning を付す）。
"""
function build_keen_sfc_comparison_context(;
    empirical::Union{KeenEmpiricalContext, Nothing} = nothing,
    accounting_report::Union{AccountingCheckReport, Nothing} = nothing,
    model_metadata::Dict{Symbol, ModelMetadata} = Dict{Symbol, ModelMetadata}(),
    correspondences::Vector{KeenSFCConceptCorrespondence} = KEEN_SFC_CONCEPT_CORRESPONDENCES,
)
    base = build_cross_model_comparison_context(;
        models = [:keen, :sim],
        empirical = empirical,
        model_metadata = model_metadata,
    )

    mappings = vcat(
        base.mappings,
        ModelConceptMapping[keen_sfc_concept_mapping(c) for c in correspondences],
    )

    sources = merge(base.sources, _ksfc_extra_sources(accounting_report))
    for c in correspondences
        m = keen_sfc_concept_mapping(c)
        s = _xm_mapping_source(m)
        sources[s.id] = s
    end

    warnings = vcat(base.warnings, _ksfc_extra_warnings(correspondences, accounting_report))
    concepts = vcat(base.concepts, Symbol[c.concept for c in correspondences])

    return CrossModelComparisonContext(
        base.contract_version,
        concepts,
        base.models,
        base.coverage,
        mappings,
        base.empirical,
        base.model_metadata,
        sources,
        warnings,
        base.prompt_version,
    )
end

# ===========================================================================
# 構造差分・分析に適した問い・次期モデルのギャップ
# ===========================================================================

"""
    keen_sfc_mechanism_diff() -> Dict{String,Any}

Keen と SIM の能力 metadata（#149）の構造化差分。比較 API v2 の `:mechanism` モードと
同一の差分関数を用いる（部門・金融商品・対応 API・各メカニズムの扱い・会計閉鎖・均衡概念）。
数値 metric は含まない。
"""
keen_sfc_mechanism_diff() =
    _v2_mechanism_diff(model_capabilities(:keen), model_capabilities(:sim))

# 各モデルが適する分析問い（docs・能力 metadata の記述範囲に限定）
const _KSFC_SUITABLE_QUESTIONS = Dict{String, Vector{String}}(
    "keen" => [
        "民間債務の累積が賃金シェア・雇用率の循環（Goodwin 循環）にどう作用するか。",
        "外生ショックなしにモデル内部の非線形性だけで債務崩壊（危機regime）が生じる条件は何か。",
        "利子率・投資関数パラメータの変化が良い均衡への収束/発散をどう変えるか。",
        "資金調達区分（Hedge/Speculative/Ponzi）の滞在比率と推移がどう変化するか（集計比率からの proxy 分類）。",
        "実データへの限定キャリブレーションと感応度・regime 比較による検証（Keen 実証層）。",
    ],
    "sim" => [
        "財政赤字が家計の金融資産ストック H としてどう積み上がるか。",
        "政府支出 G・税率 θ のショックが産出・可処分所得・貨幣ストックの移行経路をどう変えるか。",
        "貸借対照表・取引フローが全期で閉じているか（stock-flow consistency の検証）。",
        "需要決定産出と前期末ストックからの消費が定常状態 Y*=G/θ へどう収束するか。",
        "部門別の源泉・使途がどの取引で釣り合っているか（部門予算制約の可視化）。",
    ],
)

"""
    keen_sfc_suitable_questions() -> Dict{String,Vector{String}}

各モデルが答えられる分析問いの一覧（`"keen"` / `"sim"`）。docs と能力 metadata の
記述範囲に限定し、モデルが扱わない領域の問いは含めない。
"""
keen_sfc_suitable_questions() =
    Dict{String, Vector{String}}(k => copy(v) for (k, v) in _KSFC_SUITABLE_QUESTIONS)

# ADR 0007 §11 の将来拡張（責務境界のみ残した非対象範囲）
const _KSFC_ROADMAP_GAPS = String[
    "銀行部門・企業債務・利子付き資産を含む部門別 SFC 行列（instrument に :loan/:deposit/:bond、sector に :bank/:firm を追加。ADR 0007 §11）。",
    "資金調達区分診断を集計比率の proxy ではなく SFC 表の負債・利払いフローから直接構成すること。",
    "賃金シェア・利潤シェアの動学を会計恒等式と両立させること（企業部門の利潤・内部留保・投資）。",
    "危機regime の内生化を会計整合性を保ったまま表現すること（ADR 0007 §1 の非対象範囲）。",
]

"""
    keen_sfc_minsky_gaps(; correspondences=KEEN_SFC_CONCEPT_CORRESPONDENCES) -> Vector{String}

次期 Minsky-SFC モデルで埋めるべきギャップ。比較不能概念の `required_evidence` と
ADR 0007 §11 の将来拡張から決定的に導出する（重複排除）。
"""
function keen_sfc_minsky_gaps(;
    correspondences::Vector{KeenSFCConceptCorrespondence} = KEEN_SFC_CONCEPT_CORRESPONDENCES,
)
    gaps = String[]
    for c in correspondences
        c.mapping_type === :incompatible || continue
        append!(gaps, c.required_evidence)
    end
    append!(gaps, _KSFC_ROADMAP_GAPS)
    return unique(gaps)
end

# ===========================================================================
# KeenSFCComparisonReport
# ===========================================================================

"""
    KeenSFCComparisonReport

Keen–SIM 比較の構造化レポート（Issue #151）。共通概念・部分対応・比較不能・会計構造と
動学機構の差・実施した数値比較と不実施理由・各モデルが適する問い・次期 Minsky-SFC の
ギャップを、根拠 source とともに保持する。

## フィールド
- `contract_version::String` / `models::Vector{Symbol}`
- `shared_concepts::Vector{KeenSFCConceptCorrespondence}` : `equivalent`（真に等価な概念）
- `partial_concepts::Vector{KeenSFCConceptCorrespondence}` : `proxy` / `partial`
- `incomparable_concepts::Vector{KeenSFCConceptCorrespondence}` : `incompatible`
- `structural_differences::Dict{String,Any}` : 能力 metadata の構造化差分（会計閉鎖・部門・機構）
- `numeric_comparisons::Dict{String,ComparisonResultV2}` : 実際に metric を計算した概念
- `skipped_comparisons::Vector{Dict{String,Any}}` : 数値比較を行わなかった概念と理由・必要な追加証拠
- `suitable_questions::Dict{String,Vector{String}}` : 各モデルが適する分析問い
- `minsky_sfc_gaps::Vector{String}` : 次期 Minsky-SFC モデルで埋めるべきギャップ
- `required_evidence::Vector{String}` : 比較を可能にするために必要な追加モデル・系列・変換
- `context::CrossModelComparisonContext` : ADR 0006 互換の比較コンテキスト
- `warnings::Vector{String}` : 安全性・限界の注意
- `provenance::Dict{String,Any}` : 契約 version・入力有無の要約
"""
struct KeenSFCComparisonReport
    contract_version::String
    models::Vector{Symbol}
    shared_concepts::Vector{KeenSFCConceptCorrespondence}
    partial_concepts::Vector{KeenSFCConceptCorrespondence}
    incomparable_concepts::Vector{KeenSFCConceptCorrespondence}
    structural_differences::Dict{String, Any}
    numeric_comparisons::Dict{String, ComparisonResultV2}
    skipped_comparisons::Vector{Dict{String, Any}}
    suitable_questions::Dict{String, Vector{String}}
    minsky_sfc_gaps::Vector{String}
    required_evidence::Vector{String}
    context::CrossModelComparisonContext
    warnings::Vector{String}
    provenance::Dict{String, Any}
end

_ksfc_skip(c::KeenSFCConceptCorrespondence, reason::String) = Dict{String, Any}(
    "concept" => String(c.concept),
    "label" => c.label,
    "mapping_type" => String(c.mapping_type),
    "comparability" => String(c.comparability),
    "reason" => reason,
    "required_evidence" => copy(c.required_evidence),
    "source_ids" => copy(c.source_ids),
)

# 1 概念の数値比較を試みる。戻り値 (result|nothing, skip|nothing)
function _ksfc_try_compare(
    c::KeenSFCConceptCorrespondence,
    keen_result::Union{SimulationResult, Nothing},
    sim_result::Union{SimulationResult, Nothing},
    period,
    allow_period_index::Bool,
)
    if c.comparability === :incompatible
        return nothing,
        _ksfc_skip(c, "比較不能（mapping_type=$(c.mapping_type)）: " * c.rationale)
    end
    if c.comparability === :insufficient
        return nothing, _ksfc_skip(c, "情報・変換が不足しているため数値比較しない。")
    end
    if keen_result === nothing || sim_result === nothing
        return nothing,
        _ksfc_skip(
            c,
            "数値比較に必要な SimulationResult が渡されていない（keen_result / sim_result）。",
        )
    end
    if c.keen_variable === nothing || !haskey(keen_result, c.keen_variable)
        return nothing,
        _ksfc_skip(
            c,
            "Keen 側に対応系列 $(repr(c.keen_variable)) が無い（既定出力は ω, λ, d）。",
        )
    end
    if c.sim_variable === nothing || !haskey(sim_result, c.sim_variable)
        return nothing, _ksfc_skip(c, "SIM 側に対応系列 $(repr(c.sim_variable)) が無い。")
    end

    spec = ComparisonSpec(;
        mode = :trajectory,
        mappings = [
            VariableComparisonMapping(;
                model_variable = c.keen_variable,
                data_variable = c.sim_variable,
                mapping_type = c.mapping_type,
                model_concept_id = c.keen_concept_id,
                data_concept_id = c.sim_concept_id,
                caveats = copy(c.caveats),
            ),
        ],
        period = period,
        allow_period_index = allow_period_index,
        left_model = :keen,
        right_model = :sim,
    )
    result = compare_results_v2(keen_result, sim_result; spec = spec)
    if isempty(result.metrics)
        return nothing,
        _ksfc_skip(
            c,
            "比較可能性の検証で降格（level=$(result.assessment.level)）: " *
            join(result.assessment.reasons, " "),
        )
    end
    return result, nothing
end

"""
    compare_keen_sfc(; keen_result=nothing, sim_result=nothing, empirical=nothing,
        accounting_report=nothing, period=nothing, allow_period_index=false,
        model_metadata=Dict{Symbol,ModelMetadata}(),
        correspondences=KEEN_SFC_CONCEPT_CORRESPONDENCES) -> KeenSFCComparisonReport

Keen モデルと最小 SIM 型 SFC モデルの概念対応・非対応・構造差・数値比較可否をまとめた
[`KeenSFCComparisonReport`](@ref) を構築する（LLM は呼ばない。決定的）。

## 動作
1. `KEEN_SFC_CONCEPT_CORRESPONDENCES` を mapping 種別で共通概念 / 部分対応 / 比較不能に分ける。
2. 能力 metadata（#149）の構造化差分で会計構造・動学機構の違いを出す。
3. `comparability` が `:comparable` / `:partial` の概念のみ、比較 API v2（#150）で数値比較を試みる。
   比較不能・系列欠落・v2 の比較可能性検証で降格した概念は `skipped_comparisons` に理由付きで残す。
4. 比較を可能にするために必要な追加モデル・系列・変換（`required_evidence`）と、
   次期 Minsky-SFC モデルで埋めるべきギャップを導出する。

## 引数
- `keen_result` / `sim_result` : 数値比較を行う場合の `SimulationResult`（省略時は構造比較のみ）
- `empirical` : `KeenEmpiricalContext`（渡すと Keen 実証 source が context に登録される）
- `accounting_report` : [`validate_sfc_accounting`](@ref) の結果（会計 check を根拠 source に反映）
- `period` / `allow_period_index` : 比較 API v2 の整列設定（日付が無い結果同士の位置比較は明示許可が必要）

## 使用例
```julia
report = compare_keen_sfc()
report.incomparable_concepts            # 民間債務・雇用率・賃金シェア・会計閉鎖 …
report.numeric_comparisons              # 数値比較を実施した概念のみ
report.skipped_comparisons              # 不実施の理由と必要な追加証拠
out = explain_keen_sfc_comparison(report)   # 根拠付き構造化説明（provider 未接続で決定的）
```
"""
function compare_keen_sfc(;
    keen_result::Union{SimulationResult, Nothing} = nothing,
    sim_result::Union{SimulationResult, Nothing} = nothing,
    empirical::Union{KeenEmpiricalContext, Nothing} = nothing,
    accounting_report::Union{AccountingCheckReport, Nothing} = nothing,
    period::Union{Nothing, Tuple{String, String}} = nothing,
    allow_period_index::Bool = false,
    model_metadata::Dict{Symbol, ModelMetadata} = Dict{Symbol, ModelMetadata}(),
    correspondences::Vector{KeenSFCConceptCorrespondence} = KEEN_SFC_CONCEPT_CORRESPONDENCES,
)
    shared = [c for c in correspondences if c.mapping_type === :equivalent]
    partial = [c for c in correspondences if c.mapping_type in (:proxy, :partial)]
    incomparable = [c for c in correspondences if c.mapping_type === :incompatible]

    numeric = Dict{String, ComparisonResultV2}()
    skipped = Dict{String, Any}[]
    for c in correspondences
        res, skip =
            _ksfc_try_compare(c, keen_result, sim_result, period, allow_period_index)
        res === nothing || (numeric[String(c.concept)] = res)
        skip === nothing || push!(skipped, skip)
    end

    required = String[]
    for c in correspondences
        c.comparability === :comparable && continue
        append!(required, c.required_evidence)
    end

    warnings = String[]
    isempty(shared) && push!(
        warnings,
        "Keen と SIM に厳密に等価（equivalent）な概念は無い。共通に見える概念も単位・時間軸・決定機構が異なるため部分対応に留める。",
    )
    push!(
        warnings,
        "SIM の政府貨幣 H（政府負債＝家計資産）と Keen の民間債務比率 d を同一の債務として同一視・集計しない。",
    )
    push!(
        warnings,
        "SIM は民間債務・利払い・資金調達区分・危機regime を持たない。SIM 出力から金融不安定性指標（" *
        join(keen_sfc_sim_unavailable_indicators(), ", ") *
        "）を生成しない。",
    )
    push!(
        warnings,
        "Keen は部門別 SFC 表を構成しない（accounting_closure=:none）。会計整合性を SIM と同水準に述べない。",
    )
    push!(warnings, "SIM の会計恒等式が保証するのは内的整合性であって現実妥当性ではない。")
    for r in values(numeric)
        append!(warnings, r.warnings)
    end
    if accounting_report !== nothing && !accounting_passed(accounting_report)
        push!(
            warnings,
            "SIM の会計恒等式検証に違反がある（status=$(accounting_status_label(accounting_report.status))）。SIM 側の数値解釈を限定する。",
        )
    end

    ctx = build_keen_sfc_comparison_context(;
        empirical = empirical,
        accounting_report = accounting_report,
        model_metadata = model_metadata,
        correspondences = correspondences,
    )

    provenance = Dict{String, Any}(
        "contract_version" => KEEN_SFC_COMPARISON_CONTRACT_VERSION,
        "capability_contract_version" => MODEL_CAPABILITY_CONTRACT_VERSION,
        "comparison_v2_contract_version" => COMPARISON_V2_CONTRACT_VERSION,
        "cross_model_context_contract_version" => ctx.contract_version,
        "models" => String[String(m) for m in KEEN_SFC_MODELS],
        "n_correspondences" => length(correspondences),
        "n_numeric_comparisons" => length(numeric),
        "n_skipped" => length(skipped),
        "has_keen_result" => keen_result !== nothing,
        "has_sim_result" => sim_result !== nothing,
        "has_empirical" => empirical !== nothing,
        "has_accounting_report" => accounting_report !== nothing,
        "allow_period_index" => allow_period_index,
    )

    return KeenSFCComparisonReport(
        KEEN_SFC_COMPARISON_CONTRACT_VERSION,
        collect(KEEN_SFC_MODELS),
        shared,
        partial,
        incomparable,
        keen_sfc_mechanism_diff(),
        numeric,
        skipped,
        keen_sfc_suitable_questions(),
        keen_sfc_minsky_gaps(; correspondences = correspondences),
        unique(required),
        ctx,
        unique(warnings),
        provenance,
    )
end

"""
    explain_keen_sfc_comparison(report::KeenSFCComparisonReport; audience=:analyst,
        detail=:standard, provider=nothing, max_tokens=3500, temperature=0.2)
        -> CrossModelReasoningOutput

レポートの比較コンテキストから、ADR 0006 の根拠付き構造化出力
[`CrossModelReasoningOutput`](@ref) を生成する。

`provider === nothing`（既定）では LLM を呼ばず、検証済み context だけから決定的に生成する
（`generation_status=:deterministic`）。provider 指定時は応答を schema・source・安全性の
観点で検証し、通過で `:parsed`、失敗で決定的 fallback（`:fallback`）へ落とす。
"""
function explain_keen_sfc_comparison(
    report::KeenSFCComparisonReport;
    audience::Symbol = :analyst,
    detail::Symbol = :standard,
    provider::Union{AbstractLLMProvider, Nothing} = nothing,
    max_tokens::Int = 3500,
    temperature::Float64 = 0.2,
)
    return explain_cross_model_comparison(
        report.context;
        audience = audience,
        detail = detail,
        provider = provider,
        max_tokens = max_tokens,
        temperature = temperature,
    )
end

# ===========================================================================
# JSON 化（to_dict / to_json）
# ===========================================================================

to_dict(c::KeenSFCConceptCorrespondence) = Dict{String, Any}(
    "concept" => String(c.concept),
    "label" => c.label,
    "mapping_type" => String(c.mapping_type),
    "comparability" => String(c.comparability),
    "keen_variable" => c.keen_variable,
    "sim_variable" => c.sim_variable,
    "keen_concept_id" =>
        c.keen_concept_id === nothing ? nothing : String(c.keen_concept_id),
    "sim_concept_id" =>
        c.sim_concept_id === nothing ? nothing : String(c.sim_concept_id),
    "unit_difference" => c.unit_difference,
    "frequency_difference" => c.frequency_difference,
    "rationale" => c.rationale,
    "caveats" => copy(c.caveats),
    "required_evidence" => copy(c.required_evidence),
    "source_ids" => copy(c.source_ids),
    "doc_refs" => copy(c.doc_refs),
)

to_json(c::KeenSFCConceptCorrespondence) = JSON3.write(to_dict(c))

# 数値比較結果の要約（metric の NamedTuple は JSON 安全な Dict へ）
function _ksfc_comparison_summary(r::ComparisonResultV2)
    metrics = Dict{String, Any}()
    for (var, m) in r.metrics
        metrics[var] = Dict{String, Any}(String(k) => getfield(m, k) for k in keys(m))
    end
    return Dict{String, Any}(
        "mode" => String(r.mode),
        "left" => r.model_name,
        "right" => r.data_source,
        "level" => String(r.assessment.level),
        "reasons" => copy(r.assessment.reasons),
        "required_transforms" => copy(r.assessment.required_transforms),
        "metrics" => metrics,
        "warnings" => copy(r.warnings),
    )
end

"""
    to_dict(report::KeenSFCComparisonReport) -> Dict{String, Any}

レポートを JSON 安全な `Dict` へ変換する（Issue #151 の出力項目に対応）。
"""
function to_dict(report::KeenSFCComparisonReport)
    return Dict{String, Any}(
        "contract_version" => report.contract_version,
        "models" => String[String(m) for m in report.models],
        "shared_concepts" => Any[to_dict(c) for c in report.shared_concepts],
        "partial_concepts" => Any[to_dict(c) for c in report.partial_concepts],
        "incomparable_concepts" => Any[to_dict(c) for c in report.incomparable_concepts],
        "structural_differences" => report.structural_differences,
        "numeric_comparisons" => Dict{String, Any}(
            k => _ksfc_comparison_summary(v) for (k, v) in report.numeric_comparisons
        ),
        "skipped_comparisons" => Any[copy(s) for s in report.skipped_comparisons],
        "suitable_questions" =>
            Dict{String, Any}(k => copy(v) for (k, v) in report.suitable_questions),
        "minsky_sfc_gaps" => copy(report.minsky_sfc_gaps),
        "required_evidence" => copy(report.required_evidence),
        "warnings" => copy(report.warnings),
        "provenance" => report.provenance,
        "context" => to_dict(report.context),
    )
end

to_json(report::KeenSFCComparisonReport) = JSON3.write(to_dict(report))
