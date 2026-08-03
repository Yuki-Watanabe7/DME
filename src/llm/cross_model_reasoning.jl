# cross_model_reasoning.jl: Keen 実証結果と既存マクロモデルのクロスモデル推論層（ADR 0006）
#
# ADR 0005 の source registry / EvidenceClaim / ExplanationSection / ExplanationWarning を
# 再利用し、モデル間の概念対応（ModelConceptMapping）を明示したうえで、共通点・相違点・
# 適用範囲・実証的支持/反証・比較不能項目・次に必要な証拠を根拠付きで説明する。
#
# 依存: keen_empirical_context.jl（EvidenceSource / ExplanationWarning / KeenEmpiricalContext）、
#       keen_empirical_prompts.jl（EvidenceClaim / ExplanationSection / _DISCLAIMER_JA 等）、
#       analysis_context.jl（ModelMetadata）、provider.jl（AbstractLLMProvider）。

# ===========================================================================
# 契約 version と固定語彙（ADR 0006 §1・§9）
# ===========================================================================

const CROSS_MODEL_CONTEXT_CONTRACT_VERSION = "cross-model-context/1.0.0"
const CROSS_MODEL_PROMPT_VERSION = "cross-model-reasoning-prompt/1.0.0"
const CROSS_MODEL_OUTPUT_CONTRACT_VERSION = "cross-model-output/1.0.0"

# 比較軸（Issue #132 / ADR 0006 §1.1）
const CROSS_MODEL_CONCEPTS = (
    :private_debt_credit,     # 民間債務・信用拡張の役割
    :income_distribution,     # 所得分配・賃金シェア・利潤率
    :demand_and_instability,  # 需要不足と金融不安定性の伝播経路
    :steady_state_stability,  # 定常状態・局所安定性・危機regime
    :shock_response,          # 政策ショック・外生ショックへの反応
)

# treatment（ADR 0006 §1.2）
const CROSS_MODEL_TREATMENTS = (:endogenous, :approximate, :out_of_scope)

# mapping type（Issue #132 / ADR 0006 §3）
const CROSS_MODEL_MAPPING_TYPES = (:equivalent, :proxy, :partial, :incompatible)

# section status（ADR 0006 §6）
const CROSS_MODEL_SECTION_STATUSES =
    (:available, :not_available, :insufficient_comparability)

# claim の epistemic_status（ADR 0006 §6）
const CROSS_MODEL_STATUSES = (:metadata, :mapping, :empirical, :comparative, :limitation)

# category → epistemic_status（atomic な status のみ厳密対応。合成 status は複数 category を引用可）
const _XM_CATEGORY_STATUS = Dict{Symbol, Symbol}(
    :model_concept => :metadata,
    :concept_mapping => :mapping,
    :empirical_evidence => :empirical,
    :comparison => :comparative,
    :limitations => :limitation,
)

# 必須 section キーと表示順（ADR 0006 §6）
const CROSS_MODEL_OUTPUT_SECTION_ORDER = (
    "executive_summary",
    "comparison_scope",
    "concept_mappings",
    "mechanisms_by_model",
    "consistent_observations",
    "divergent_conclusions",
    "empirical_support",
    "incomparable_or_insufficient",
    "next_evidence",
    "limitations",
)

# モデル識別子 → 表示名
const _XM_MODEL_LABELS = Dict{Symbol, String}(
    :solow => "Solow 成長モデル",
    :ramsey => "Ramsey 最適成長モデル",
    :rbc => "RBC モデル",
    :islm => "IS-LM モデル",
    :adas => "AD-AS モデル",
    :new_keynesian => "New Keynesian 3方程式モデル",
    :mundell_fleming => "Mundell-Fleming モデル",
    :var => "簡易 VAR モデル",
    :keen => "Keen モデル",
    :sim => "SIM（SFC）モデル",
    :capex_credit_cycle => "部門別CAPEX・信用循環モデル",
)

# 比較軸 → 表示名
const _XM_CONCEPT_LABELS = Dict{Symbol, String}(
    :private_debt_credit => "民間債務・信用拡張",
    :income_distribution => "所得分配・賃金シェア・利潤率",
    :demand_and_instability => "需要不足と金融不安定性の伝播",
    :steady_state_stability => "定常状態・局所安定性・危機regime",
    :shock_response => "政策・外生ショック反応",
)

_xm_model_label(m::Symbol) = get(_XM_MODEL_LABELS, m, String(m))
_xm_concept_label(c::Symbol) = get(_XM_CONCEPT_LABELS, c, String(c))

# ===========================================================================
# ModelConceptCoverage（ADR 0006 §2）
# ===========================================================================

"""
    ModelConceptCoverage

あるモデルが 1 つの比較軸をどう扱うかの repository metadata。docs のモデル節・限界節・
`docs/model_selection_guide.md` の横断表・`docs/data/variable_mapping.md` のみを根拠とし、
数値実証結果は含めない。

## フィールド
- `model::Symbol` : モデル識別子
- `concept::Symbol` : `CROSS_MODEL_CONCEPTS` の 1 つ
- `treatment::Symbol` : `CROSS_MODEL_TREATMENTS` の 1 つ
- `variables::Vector{String}` : その概念を表す変数記号
- `definition::String` : docs 由来の短い定義
- `definition_key::Symbol` : 等価判定用の正準キー（定義が真に一致する場合のみ同一値）
- `unit::Union{String,Nothing}` / `frequency::Union{String,Nothing}` / `measure::Union{String,Nothing}`
- `doc_ref::String` : 根拠 docs パス・節
- `caveats::Vector{String}` : 定義差・限界の注意
"""
struct ModelConceptCoverage
    model::Symbol
    concept::Symbol
    treatment::Symbol
    variables::Vector{String}
    definition::String
    definition_key::Symbol
    unit::Union{String, Nothing}
    frequency::Union{String, Nothing}
    measure::Union{String, Nothing}
    doc_ref::String
    caveats::Vector{String}
end

function ModelConceptCoverage(;
    model::Symbol,
    concept::Symbol,
    treatment::Symbol,
    definition::String,
    definition_key::Symbol,
    variables::Vector{String} = String[],
    unit::Union{String, Nothing} = nothing,
    frequency::Union{String, Nothing} = nothing,
    measure::Union{String, Nothing} = nothing,
    doc_ref::String = "",
    caveats::Vector{String} = String[],
)
    concept in CROSS_MODEL_CONCEPTS || throw(
        ArgumentError("未知の concept: $(repr(concept))（有効: $(CROSS_MODEL_CONCEPTS)）"),
    )
    treatment in CROSS_MODEL_TREATMENTS || throw(
        ArgumentError(
            "未知の treatment: $(repr(treatment))（有効: $(CROSS_MODEL_TREATMENTS)）",
        ),
    )
    ModelConceptCoverage(
        model,
        concept,
        treatment,
        variables,
        definition,
        definition_key,
        unit,
        frequency,
        measure,
        doc_ref,
        caveats,
    )
end

# coverage の安定 source ID（^[a-z][a-z0-9_.-]*$）
_xm_coverage_source_id(c::ModelConceptCoverage) = "concept.$(c.model).$(c.concept)"

# ===========================================================================
# ModelConceptMapping（ADR 0006 §3）
# ===========================================================================

"""
    ModelConceptMapping

2 モデル間・1 概念の対応。同名変数でも定義が異なれば `equivalent` にしない（ADR 0006 §3・§7）。

## フィールド
- `source_model::Symbol` / `target_model::Symbol`
- `concept::Symbol`
- `mapping_type::Symbol` : `CROSS_MODEL_MAPPING_TYPES` の 1 つ
- `source_variable::Union{String,Nothing}` / `target_variable::Union{String,Nothing}`
- `unit_difference::Union{String,Nothing}` / `frequency_difference::Union{String,Nothing}` /
  `aggregation_difference::Union{String,Nothing}` : 差が無ければ `nothing`
- `caveats::Vector{String}` : 比較上の注意事項
- `source_ids::Vector{String}` : 参照する coverage source ID
"""
struct ModelConceptMapping
    source_model::Symbol
    target_model::Symbol
    concept::Symbol
    mapping_type::Symbol
    source_variable::Union{String, Nothing}
    target_variable::Union{String, Nothing}
    unit_difference::Union{String, Nothing}
    frequency_difference::Union{String, Nothing}
    aggregation_difference::Union{String, Nothing}
    caveats::Vector{String}
    source_ids::Vector{String}
end

_xm_mapping_source_id(
    m::ModelConceptMapping,
) = "mapping.$(m.source_model).$(m.target_model).$(m.concept)"

_xm_first_var(c::ModelConceptCoverage) = isempty(c.variables) ? nothing : first(c.variables)

# 2 coverage から mapping_type を決める（ADR 0006 §3.2、保守的）
function _xm_mapping_type(a::ModelConceptCoverage, b::ModelConceptCoverage)
    (a.treatment === :out_of_scope || b.treatment === :out_of_scope) && return :incompatible
    if a.definition_key === b.definition_key && a.measure == b.measure && a.unit == b.unit
        return :equivalent
    end
    (a.treatment === :approximate || b.treatment === :approximate) && return :partial
    :proxy
end

_xm_diff(x, y) = x == y ? nothing : "$(x) vs $(y)"

"""
    derive_concept_mapping(a::ModelConceptCoverage, b::ModelConceptCoverage) -> ModelConceptMapping

同一 concept の 2 coverage から `ModelConceptMapping` を導出する（ADR 0006 §3.2）。
`a.concept === b.concept` を要求する。unit / frequency / measure の差を各差分 field へ転記し、
同名変数で定義が異なる場合は比較上の注意事項へ明示する。
"""
function derive_concept_mapping(a::ModelConceptCoverage, b::ModelConceptCoverage)
    a.concept === b.concept ||
        throw(ArgumentError("concept が一致しません: $(a.concept) vs $(b.concept)"))
    mtype = _xm_mapping_type(a, b)
    caveats = String[]
    append!(caveats, a.caveats)
    append!(caveats, b.caveats)
    if mtype === :incompatible
        oos = a.treatment === :out_of_scope ? a.model : b.model
        push!(
            caveats,
            "$(_xm_model_label(oos)) は $(_xm_concept_label(a.concept)) を対象外とするため比較不能。",
        )
    end
    # 同名変数の定義差（安全性: 同名でも定義が異なれば同一視しない）
    va, vb = _xm_first_var(a), _xm_first_var(b)
    if va !== nothing &&
       vb !== nothing &&
       va == vb &&
       (a.definition_key !== b.definition_key || a.measure != b.measure)
        push!(
            caveats,
            "変数「$(va)」は両モデルで名称が同じだが定義が異なる（$(a.model): $(a.definition) / $(b.model): $(b.definition)）。同一視しない。",
        )
    end
    ModelConceptMapping(
        a.model,
        b.model,
        a.concept,
        mtype,
        va,
        vb,
        _xm_diff(a.unit, b.unit),
        _xm_diff(a.frequency, b.frequency),
        _xm_diff(a.measure, b.measure),
        unique(caveats),
        [_xm_coverage_source_id(a), _xm_coverage_source_id(b)],
    )
end

# ===========================================================================
# MODEL_CONCEPT_REGISTRY（repository metadata。docs のみを根拠。ADR 0006 §2）
# ===========================================================================

# 共通 caveat 断片
const _XM_PARAM_SHARE_CAVEAT = "Cobb-Douglas 資本弾力性 α を固定パラメータとして扱う静的分配であり、賃金シェアの動学ではない。"

# CCC の caveats 5件（責務境界 §2.6・§5.8 要件2。5軸すべての coverage 行へ含める）
const _CCC_XM_CAVEATS = [
    "残差部門 SX を持つため会計は経済全体で閉じていない（#166 §9.2 が要求）。",
    "デフォルト・信用損失を内生化していない。資金繰り診断は倒産・信用イベントの予測ではない（#166 §7）。",
    "信用の内生性は借り手側のみ。銀行の自己資本・調達コスト・貸出数量制約を持たない（#166 §12-1）。",
    "一般物価・インフレ・金融政策の内生反応を持たない。policy_rate は外生パスである。",
    "出力はすべて baseline 比の乖離であり、水準の絶対値は較正済みの実額を意味しない（契約 §2.4）。",
]

const MODEL_CONCEPT_REGISTRY = ModelConceptCoverage[
    # ---- Keen（Minsky 系。信用・分配・不安定性・危機regime を内生化）------------
    ModelConceptCoverage(;
        model = :keen,
        concept = :private_debt_credit,
        treatment = :endogenous,
        variables = ["d"],
        definition_key = :keen_debt_ratio,
        unit = "ratio",
        frequency = "continuous (annual params)",
        measure = "ratio",
        definition = "民間債務比率 d=D/Y を内生化。投資が内部資金(利潤π)を超える分を借入で賄い d が上昇。",
        doc_ref = "docs/models/keen.md §2,§5",
        caveats = ["銀行は受動的に貸すと仮定し、信用供給制約・銀行自己資本制約は非対象。"],
    ),
    ModelConceptCoverage(;
        model = :keen,
        concept = :income_distribution,
        treatment = :endogenous,
        variables = ["ω", "π", "λ"],
        definition_key = :keen_wage_profit_share,
        unit = "ratio",
        frequency = "continuous (annual params)",
        measure = "ratio",
        definition = "賃金シェア ω を非線形 Phillips 曲線で、利潤シェア π=1−ω−r·d を利払い後で動学化(Goodwin 循環)。",
        doc_ref = "docs/models/keen.md §2,§5",
    ),
    ModelConceptCoverage(;
        model = :keen,
        concept = :demand_and_instability,
        treatment = :endogenous,
        variables = ["λ", "d"],
        definition_key = :keen_endogenous_instability,
        unit = "ratio",
        frequency = "continuous (annual params)",
        measure = "ratio",
        definition = "外生ショックなしにモデル内部の非線形性だけで好況循環と債務崩壊の双安定性が生じる。",
        doc_ref = "docs/models/keen.md §1,§2",
        caveats = [
            "需要は雇用率 λ 経由の Goodwin 機構であり、明示的な財市場・在庫調整はない。",
        ],
    ),
    ModelConceptCoverage(;
        model = :keen,
        concept = :steady_state_stability,
        treatment = :endogenous,
        variables = ["ω", "λ", "d"],
        definition_key = :keen_bistable_crisis,
        unit = "ratio",
        frequency = "continuous (annual params)",
        measure = "ratio",
        definition = "良い均衡(局所安定・振動的減衰)と悪い均衡(ω,λ→0, d→∞ の債務崩壊=危機regime)の双安定性。",
        doc_ref = "docs/models/keen.md §1,§6,§8",
        caveats = ["崩壊経路は予測ではなく、危機regime を明示的に持つ唯一のモデル。"],
    ),
    ModelConceptCoverage(;
        model = :keen,
        concept = :shock_response,
        treatment = :approximate,
        variables = ["ω", "λ", "d"],
        definition_key = :equilibrium_perturbation_irf,
        unit = "ratio (additive shift)",
        frequency = "continuous (annual params)",
        measure = "level",
        definition = "良い均衡から状態を加法的にずらした初期値からの simulate(均衡攪乱型 IRF)。",
        doc_ref = "docs/models/keen.md §7,§9",
        caveats = [
            "政府部門なし=財政政策なし、金利 r は一定パラメータ=金融政策チャンネルなし、確率ショックなし。",
        ],
    ),

    # ---- SIM（最小 SFC。会計恒等式を検証するが金融資産は政府貨幣 H のみ）--------
    ModelConceptCoverage(;
        model = :sim,
        concept = :private_debt_credit,
        treatment = :out_of_scope,
        definition_key = :none,
        definition = "金融資産は政府貨幣 H のみ。銀行貸出・企業債務・信用創造を持たない。",
        doc_ref = "docs/models/sim_sfc.md §限界; docs/adr/0007-sfc-integration-contract.md §1",
        caveats = [
            "H は家計の資産かつ政府の負債であり、企業の民間債務ではない。Keen の債務比率 d と同一視しない。",
        ],
    ),
    ModelConceptCoverage(;
        model = :sim,
        concept = :income_distribution,
        treatment = :out_of_scope,
        definition_key = :none,
        definition = "企業利潤ゼロ（賃金＝産出）を仮定し、賃金シェア・利潤シェアの動学を持たない。",
        doc_ref = "docs/models/sim_sfc.md §限界",
        caveats = [
            "賃金率 W を数値基準とするため賃金シェアは定義上一定であり、分配の動学ではない。",
        ],
    ),
    ModelConceptCoverage(;
        model = :sim,
        concept = :demand_and_instability,
        treatment = :approximate,
        variables = ["Y", "C"],
        definition_key = :sim_demand_determined_output,
        unit = "wage units",
        frequency = "period (discrete)",
        measure = "level",
        definition = "産出は総需要 Y=C+G で決定され、家計の貨幣ストック H が消費関数を通じて需要へ波及する。",
        doc_ref = "docs/models/sim_sfc.md §方程式",
        caveats = [
            "生産関数を持たない需要決定モデルであり、金融不安定性の伝播経路は存在しない（0<α1<1 で大域安定）。",
        ],
    ),
    ModelConceptCoverage(;
        model = :sim,
        concept = :steady_state_stability,
        treatment = :endogenous,
        variables = ["H", "Y"],
        definition_key = :sim_stock_flow_steady_state,
        unit = "wage units",
        frequency = "period (discrete)",
        measure = "level",
        definition = "貯蓄ゼロ・政府予算均衡 T=G の会計整合定常状態（Y*=G/θ, H*=(1−α1)/α2·YD*）へ大域収束。",
        doc_ref = "docs/models/sim_sfc.md §定常状態",
        caveats = [
            "危機regime・双安定性を持たない。会計恒等式は全期 validate_sfc_accounting で検証される。",
        ],
    ),
    ModelConceptCoverage(;
        model = :sim,
        concept = :shock_response,
        treatment = :endogenous,
        variables = ["G", "θ"],
        definition_key = :sim_fiscal_shock_path,
        unit = "wage units",
        frequency = "period (discrete)",
        measure = "level",
        definition = "政府支出 G・税率 θ への恒久/一時ショックから新しい定常状態への移行経路を水準で返す。",
        doc_ref = "docs/models/sim_sfc.md §財政ショック",
        caveats = ["金融政策・確率ショックは持たない（財政ショックのみ）。"],
    ),

    # ---- CCC（部門別CAPEX・信用循環モデル。部門別 CAPEX・受注残・在庫・稼働率・信用条件を持つ）----
    ModelConceptCoverage(;
        model = :capex_credit_cycle,
        concept = :private_debt_credit,
        treatment = :endogenous,
        variables = ["debt_s", "leverage_s", "spread", "rollover", "lend_stance"],
        definition_key = :ccc_sector_debt_credit_conditions,
        unit = "level (bn USD, 2017 chained); bp",
        frequency = "quarterly",
        measure = "level",
        definition = "部門別債務残高・レバレッジ・社債スプレッド・借換条件・貸出態度を内生化する（借り手側のみ内生、銀行の自己資本・貸出数量制約は持たない）。",
        doc_ref = "docs/models/capex_credit_cycle_model_boundaries.md §2.6,§5.2",
        caveats = _CCC_XM_CAVEATS,
    ),
    ModelConceptCoverage(;
        model = :capex_credit_cycle,
        concept = :income_distribution,
        treatment = :approximate,
        variables = ["wagebill_s", "profit_s", "va_s"],
        definition_key = :ccc_accounting_factor_shares,
        unit = "level (bn USD, 2017 chained)",
        frequency = "quarterly",
        measure = "level",
        definition = "賃金支払額・利益・付加価値はいずれも会計残差として決まり、集計賃金シェアを状態変数として持たない。",
        doc_ref = "docs/models/capex_credit_cycle_model_boundaries.md §2.6,§5.2",
        caveats = _CCC_XM_CAVEATS,
    ),
    ModelConceptCoverage(;
        model = :capex_credit_cycle,
        concept = :demand_and_instability,
        treatment = :endogenous,
        variables = ["capex_exec_s1", "order_s", "y_s", "cons", "y_tot"],
        definition_key = :ccc_sectoral_capex_credit_propagation,
        unit = "level (bn USD, 2017 chained)",
        frequency = "quarterly",
        measure = "level",
        definition = "部門別 CAPEX ショックが受注・在庫・信用条件・雇用・消費を通じて他部門・家計へ波及する経路を内生化する。",
        doc_ref = "docs/models/capex_credit_cycle_model_boundaries.md §2.6,§5.2",
        caveats = _CCC_XM_CAVEATS,
    ),
    ModelConceptCoverage(;
        model = :capex_credit_cycle,
        concept = :steady_state_stability,
        treatment = :approximate,
        definition_key = :ccc_baseline_path,
        unit = "level (bn USD, 2017 chained)",
        frequency = "quarterly",
        measure = "level",
        definition = "baseline（`t = -8 … -1`）を成長率ゼロの定常状態として逆較正で与える。均衡の解析解・局所安定性の判定は持たない（`equilibrium_concept = :none`）。",
        doc_ref = "docs/models/capex_credit_cycle_model_boundaries.md §2.6,§5.2",
        caveats = _CCC_XM_CAVEATS,
    ),
    ModelConceptCoverage(;
        model = :capex_credit_cycle,
        concept = :shock_response,
        treatment = :endogenous,
        variables = ["dY_t", "dI_t", "dC_t"],
        definition_key = :ccc_baseline_relative_deviation,
        unit = "relative deviation; %pt; bp",
        frequency = "quarterly",
        measure = "deviation",
        definition = "CAPEX・信用ショックへの反応は baseline 比の乖離としてのみ判定・比較する（水準の絶対値は較正済みの実額を意味しない）。",
        doc_ref = "docs/models/capex_credit_cycle_model_boundaries.md §2.6,§5.2",
        caveats = _CCC_XM_CAVEATS,
    ),

    # ---- RBC ----------------------------------------------------------------
    ModelConceptCoverage(;
        model = :rbc,
        concept = :private_debt_credit,
        treatment = :out_of_scope,
        definition_key = :none,
        definition = "金融摩擦・借入制約・担保制約・レバレッジサイクルは考慮しない。",
        doc_ref = "docs/models/rbc.md §9",
    ),
    ModelConceptCoverage(;
        model = :rbc,
        concept = :income_distribution,
        treatment = :approximate,
        variables = ["w", "r"],
        definition_key = :marginal_product_shares,
        unit = "level (real)",
        frequency = "quarterly",
        measure = "level",
        definition = "実質賃金 w と実質利子率 r を限界生産力として内生決定(要素分配)。分配動学は主眼ではない。",
        doc_ref = "docs/models/rbc.md §6",
    ),
    ModelConceptCoverage(;
        model = :rbc,
        concept = :demand_and_instability,
        treatment = :out_of_scope,
        definition_key = :none,
        definition = "需要ショック・需要不足・流動性トラップは扱わない。伝播は実物的(技術ショック)のみ。",
        doc_ref = "docs/models/rbc.md §9",
    ),
    ModelConceptCoverage(;
        model = :rbc,
        concept = :steady_state_stability,
        treatment = :endogenous,
        variables = ["K", "C"],
        definition_key = :modified_golden_rule_ss,
        unit = "level (real)",
        frequency = "quarterly",
        measure = "level",
        definition = "解析的定常状態(r*=1/β+δ−1 等)を導出し、Blanchard-Kahn 条件で一意な鞍点安定。",
        doc_ref = "docs/models/rbc.md §5,§6",
        caveats = ["決定的定常状態の周りに確率的・労働供給層を加える。危機regime はない。"],
    ),
    ModelConceptCoverage(;
        model = :rbc,
        concept = :shock_response,
        treatment = :endogenous,
        variables = ["A"],
        definition_key = :stochastic_tech_shock_irf,
        unit = "log-deviation",
        frequency = "quarterly",
        measure = "deviation",
        definition = "AR(1)技術ショックへの IRF(対数偏差)。正の技術ショックで産出・消費・投資・労働が同時増加。",
        doc_ref = "docs/models/rbc.md §7,§8",
        caveats = [
            "金融政策・財政政策・需要ショックは扱わない。IRF は定常状態からの対数偏差。",
        ],
    ),

    # ---- Ramsey -------------------------------------------------------------
    ModelConceptCoverage(;
        model = :ramsey,
        concept = :private_debt_credit,
        treatment = :out_of_scope,
        definition_key = :none,
        definition = "金融市場なし(借入・貸出・資産価格・金融政策チャンネルが存在しない)。",
        doc_ref = "docs/models/ramsey.md §10",
    ),
    ModelConceptCoverage(;
        model = :ramsey,
        concept = :income_distribution,
        treatment = :approximate,
        variables = ["α"],
        definition_key = :capital_share_param,
        unit = "share (dimensionless)",
        frequency = "quarterly",
        measure = "parameter",
        definition = "資本分配率 α をパラメータとして持つ(労働分配率=1−α)。賃金・利潤率の内生化はない。",
        doc_ref = "docs/models/ramsey.md §5",
        caveats = [
            _XM_PARAM_SHARE_CAVEAT,
            "代表的家計・労働=1固定で異質性・格差は扱えない。",
        ],
    ),
    ModelConceptCoverage(;
        model = :ramsey,
        concept = :demand_and_instability,
        treatment = :out_of_scope,
        definition_key = :none,
        definition = "閉鎖経済・確実性等価で需要不足やトラップは扱わない。景気循環自体が対象外。",
        doc_ref = "docs/models/ramsey.md §9,§10",
    ),
    ModelConceptCoverage(;
        model = :ramsey,
        concept = :steady_state_stability,
        treatment = :endogenous,
        variables = ["K", "C"],
        definition_key = :modified_golden_rule_ss,
        unit = "level (real)",
        frequency = "quarterly",
        measure = "level",
        definition = "修正黄金律 K*=(α/(1/β+δ−1))^{1/(1−α)} を持ち、初期資本から定常状態へ単調収束。",
        doc_ref = "docs/models/ramsey.md §6,§7",
        caveats = ["完全予見・確率ショックなし。危機regime はない。"],
    ),
    ModelConceptCoverage(;
        model = :ramsey,
        concept = :shock_response,
        treatment = :approximate,
        variables = ["K"],
        definition_key = :initial_value_perturbation,
        unit = "level (real)",
        frequency = "quarterly",
        measure = "level",
        definition = "確率ショックなし。初期資本 K0 を定常値からずらして移行動態を分析(資本課税等の比較静学)。",
        doc_ref = "docs/models/ramsey.md §7,§9",
        caveats = ["金融政策・名目硬直性は扱わない。"],
    ),

    # ---- Solow --------------------------------------------------------------
    ModelConceptCoverage(;
        model = :solow,
        concept = :private_debt_credit,
        treatment = :out_of_scope,
        definition_key = :none,
        definition = "物価・金融政策・信用/債務を扱えない長期成長モデル。",
        doc_ref = "docs/models/solow.md 限界",
    ),
    ModelConceptCoverage(;
        model = :solow,
        concept = :income_distribution,
        treatment = :approximate,
        variables = ["α"],
        definition_key = :capital_share_param,
        unit = "share (dimensionless)",
        frequency = "unspecified",
        measure = "parameter",
        definition = "資本分配率 α をパラメータとして持つ。賃金シェア・利潤率の内生動学はない。",
        doc_ref = "docs/models/solow.md 変数表",
        caveats = [_XM_PARAM_SHARE_CAVEAT],
    ),
    ModelConceptCoverage(;
        model = :solow,
        concept = :demand_and_instability,
        treatment = :out_of_scope,
        definition_key = :none,
        definition = "供給側(貯蓄→資本蓄積)の成長モデルで需要不足の概念なし。",
        doc_ref = "docs/models/solow.md 限界",
    ),
    ModelConceptCoverage(;
        model = :solow,
        concept = :steady_state_stability,
        treatment = :endogenous,
        variables = ["k"],
        definition_key = :efficiency_unit_fixed_point,
        unit = "efficiency-unit ratio",
        frequency = "unspecified",
        measure = "ratio",
        definition = "効率労働単位あたり定常状態 k*=(s/(δ+n+g+ng))^{1/(1−α)} へ任意初期資本から大域的単調収束。",
        doc_ref = "docs/models/solow.md 定常状態",
        caveats = ["危機regime 概念なし。効率労働単位あたりの比率で表現。"],
    ),
    ModelConceptCoverage(;
        model = :solow,
        concept = :shock_response,
        treatment = :approximate,
        variables = ["s", "n", "g"],
        definition_key = :comparative_statics_param,
        unit = "efficiency-unit ratio",
        frequency = "unspecified",
        measure = "ratio",
        definition = "貯蓄率・人口成長率・技術進歩率の変化が定常値に与える影響を比較静学的に扱う。",
        doc_ref = "docs/models/solow.md; docs/model_selection_guide.md §4.1",
        caveats = ["確率的ショックは考慮しない。"],
    ),

    # ---- IS-LM --------------------------------------------------------------
    ModelConceptCoverage(;
        model = :islm,
        concept = :private_debt_credit,
        treatment = :out_of_scope,
        definition_key = :none,
        definition = "貨幣 M は扱うが民間債務・信用拡張の概念はなく、外生的貨幣供給のみ。",
        doc_ref = "docs/models/islm.md 限界",
    ),
    ModelConceptCoverage(;
        model = :islm,
        concept = :income_distribution,
        treatment = :out_of_scope,
        definition_key = :none,
        definition = "分配・賃金シェア・利潤率の記述なし(需要側の集計モデル)。",
        doc_ref = "docs/models/islm.md",
    ),
    ModelConceptCoverage(;
        model = :islm,
        concept = :demand_and_instability,
        treatment = :approximate,
        variables = ["Y", "r"],
        definition_key = :islm_demand,
        unit = "level",
        frequency = "static",
        measure = "level",
        definition = "財市場・貨幣市場の同時均衡で短期需要と政策効果を扱う。金融不安定性の伝播経路はない。",
        doc_ref = "docs/models/islm.md §1; docs/model_selection_guide.md §4.4",
        caveats = [
            "需要サイドのみ、総供給との統合は非対象。r は名目利子率(インフレ期待未考慮)。",
        ],
    ),
    ModelConceptCoverage(;
        model = :islm,
        concept = :steady_state_stability,
        treatment = :approximate,
        variables = ["Y", "r"],
        definition_key = :islm_static_equilibrium,
        unit = "level",
        frequency = "static",
        measure = "level",
        definition = "静学均衡(特定期の均衡値)のみ。動学的調整・局所安定性・危機regime は扱わない。",
        doc_ref = "docs/models/islm.md 限界",
        caveats = ["静学モデル。定常状態はスカラー、simulate は長さ1ベクトル。"],
    ),
    ModelConceptCoverage(;
        model = :islm,
        concept = :shock_response,
        treatment = :endogenous,
        variables = ["G", "T", "M"],
        definition_key = :comparative_statics_policy,
        unit = "level",
        frequency = "static",
        measure = "level",
        definition = "財政政策(G,T)・金融政策(M)の産出・利子率への短期効果を比較静学で扱う(クラウディングアウト)。",
        doc_ref = "docs/models/islm.md §政策; docs/model_selection_guide.md §4.4",
        caveats = ["前向き期待なし。将来政策の効果は分析できない。"],
    ),

    # ---- AD-AS --------------------------------------------------------------
    ModelConceptCoverage(;
        model = :adas,
        concept = :private_debt_credit,
        treatment = :out_of_scope,
        definition_key = :none,
        definition = "貨幣市場は含むが信用・債務の概念なし。",
        doc_ref = "docs/models/adas.md",
    ),
    ModelConceptCoverage(;
        model = :adas,
        concept = :income_distribution,
        treatment = :out_of_scope,
        definition_key = :none,
        definition = "分配・賃金シェア・利潤率の記述なし。",
        doc_ref = "docs/models/adas.md",
    ),
    ModelConceptCoverage(;
        model = :adas,
        concept = :demand_and_instability,
        treatment = :approximate,
        variables = ["Y", "P"],
        definition_key = :adas_demand_supply,
        unit = "level",
        frequency = "static",
        measure = "level",
        definition = "需要ショック(AD シフト)と供給ショック(SRAS シフト)で Y・P を同時決定。金融不安定性経路なし。",
        doc_ref = "docs/models/adas.md §ショック比較",
        caveats = ["スタグフレーション(P_e↑)は扱えるが動学的伝播ではない。"],
    ),
    ModelConceptCoverage(;
        model = :adas,
        concept = :steady_state_stability,
        treatment = :approximate,
        variables = ["Y", "P"],
        definition_key = :adas_static_equilibrium,
        unit = "level",
        frequency = "static",
        measure = "level",
        definition = "短期均衡(AD·SRAS 交点)が主計算対象、LRAS(Y=Y_n)は参照概念。動学的安定性・危機regime は扱わない。",
        doc_ref = "docs/models/adas.md 限界",
        caveats = ["静学モデル。長期均衡への調整経路は扱わない。"],
    ),
    ModelConceptCoverage(;
        model = :adas,
        concept = :shock_response,
        treatment = :endogenous,
        variables = ["G", "M", "Y_n", "P_e"],
        definition_key = :comparative_statics_shock,
        unit = "level",
        frequency = "static",
        measure = "level",
        definition = "需要ショック(G↑,M↑)・供給ショック(Y_n↑,P_e↑)を比較静学で扱う。",
        doc_ref = "docs/models/adas.md §ショック分析",
        caveats = ["期待は外生(P_e 所与)。名目利子率(実質金利・フィッシャー式非対象)。"],
    ),

    # ---- New Keynesian ------------------------------------------------------
    ModelConceptCoverage(;
        model = :new_keynesian,
        concept = :private_debt_credit,
        treatment = :out_of_scope,
        definition_key = :none,
        definition = "金融摩擦・信用制約を扱えない(HANK 等の異質主体は非対象)。",
        doc_ref = "docs/models/new_keynesian.md 非対象; docs/model_selection_guide.md §4.6",
    ),
    ModelConceptCoverage(;
        model = :new_keynesian,
        concept = :income_distribution,
        treatment = :out_of_scope,
        definition_key = :none,
        definition = "代表的主体モデルで分配・賃金シェアの概念なし。",
        doc_ref = "docs/models/new_keynesian.md 非対象",
    ),
    ModelConceptCoverage(;
        model = :new_keynesian,
        concept = :demand_and_instability,
        treatment = :approximate,
        variables = ["x", "π"],
        definition_key = :nk_demand_costpush,
        unit = "deviation",
        frequency = "quarterly",
        measure = "deviation",
        definition = "動学的 IS 曲線で需要ショック、NKPC でコストプッシュショックが産出ギャップ・インフレへ伝播。金融不安定性経路はない。",
        doc_ref = "docs/models/new_keynesian.md §ショック分析",
        caveats = ["前向き合理的期待。信用の伝播経路はない。"],
    ),
    ModelConceptCoverage(;
        model = :new_keynesian,
        concept = :steady_state_stability,
        treatment = :endogenous,
        variables = ["x", "π", "i"],
        definition_key = :zero_gap_ss,
        unit = "deviation",
        frequency = "quarterly",
        measure = "deviation",
        definition = "定常状態 x*=0, π*=π_star, i*=r_n+π_star。Taylor 原理(φ_π>1)で一意安定、φ_π<1 で均衡不定。",
        doc_ref = "docs/models/new_keynesian.md §定常状態,§MSV",
        caveats = ["危機regime 概念なし(ZLB 非対象)。IRF は定常状態からの乖離。"],
    ),
    ModelConceptCoverage(;
        model = :new_keynesian,
        concept = :shock_response,
        treatment = :endogenous,
        variables = ["x", "π", "i"],
        definition_key = :three_shock_irf,
        unit = "deviation",
        frequency = "quarterly",
        measure = "deviation",
        definition = "需要・コストプッシュ・金融政策の3ショック IRF と Taylor rule(タカ派/ハト派)比較。",
        doc_ref = "docs/models/new_keynesian.md §ショック分析",
        caveats = [
            "金融政策=Taylor rule のみ、財政政策動学は非対象。線形化のため大ショックで精度低下。",
        ],
    ),

    # ---- Mundell-Fleming ----------------------------------------------------
    ModelConceptCoverage(;
        model = :mundell_fleming,
        concept = :private_debt_credit,
        treatment = :out_of_scope,
        definition_key = :none,
        definition = "貨幣市場(M/P)はあるが信用・民間債務の概念なし。",
        doc_ref = "docs/models/mundell_fleming.md",
    ),
    ModelConceptCoverage(;
        model = :mundell_fleming,
        concept = :income_distribution,
        treatment = :out_of_scope,
        definition_key = :none,
        definition = "分配の記述なし。",
        doc_ref = "docs/models/mundell_fleming.md",
    ),
    ModelConceptCoverage(;
        model = :mundell_fleming,
        concept = :demand_and_instability,
        treatment = :approximate,
        variables = ["Y", "e", "NX"],
        definition_key = :mf_open_demand,
        unit = "level",
        frequency = "static",
        measure = "level",
        definition = "財政/金融政策が UIP・為替・純輸出経路で産出へ伝播する開放経済の需要側。金融不安定性経路はない。",
        doc_ref = "docs/models/mundell_fleming.md §5",
        caveats = [
            "e は高いほど自国通貨安(実データと符号規約が異なりうる)。物価固定・完全資本移動。",
        ],
    ),
    ModelConceptCoverage(;
        model = :mundell_fleming,
        concept = :steady_state_stability,
        treatment = :approximate,
        variables = ["Y", "r", "e"],
        definition_key = :mf_static_equilibrium,
        unit = "level",
        frequency = "static",
        measure = "level",
        definition = "静学均衡のみ。動学的調整・局所安定性・危機regime は扱わない。",
        doc_ref = "docs/models/mundell_fleming.md §8.3",
        caveats = ["静学モデル。固定相場制は対象外(変動相場のみ)。"],
    ),
    ModelConceptCoverage(;
        model = :mundell_fleming,
        concept = :shock_response,
        treatment = :endogenous,
        variables = ["G", "M", "r_star"],
        definition_key = :policy_theorem,
        unit = "level",
        frequency = "static",
        measure = "level",
        definition = "Mundell-Fleming 定理(変動相場: 財政政策無効・金融政策有効)、海外金利/外需ショックの比較静学。",
        doc_ref = "docs/models/mundell_fleming.md §5,§6",
        caveats = ["期待形成なし。物価固定。"],
    ),

    # ---- VAR ----------------------------------------------------------------
    ModelConceptCoverage(;
        model = :var,
        concept = :private_debt_credit,
        treatment = :out_of_scope,
        definition_key = :none,
        definition = "理論的変数定義を持たない。任意系列を格納できるが構造的な信用/債務の定義はない。",
        doc_ref = "docs/data/variable_mapping.md §2.8; docs/model_selection_guide.md §3",
        caveats = ["変数定義はユーザーが選ぶ(理論的解釈なし)。"],
    ),
    ModelConceptCoverage(;
        model = :var,
        concept = :income_distribution,
        treatment = :out_of_scope,
        definition_key = :none,
        definition = "理論的変数定義を持たない(分配の構造的定義なし)。",
        doc_ref = "docs/data/variable_mapping.md §2.8",
        caveats = ["変数定義はユーザーが選ぶ(理論的解釈なし)。"],
    ),
    ModelConceptCoverage(;
        model = :var,
        concept = :demand_and_instability,
        treatment = :approximate,
        variables = ["y"],
        definition_key = :var_data_driven,
        unit = "arbitrary",
        frequency = "arbitrary",
        measure = "level-deviation",
        definition = "変数間の波及経路・スピルオーバー(非対角係数)を線形動学で確認できるが構造識別なし。",
        doc_ref = "docs/models/var.md §係数行列の解釈; docs/model_selection_guide.md §4.8",
        caveats = ["構造ショック識別(SVAR)なし、理論的解釈が乏しい。係数は手入力。"],
    ),
    ModelConceptCoverage(;
        model = :var,
        concept = :steady_state_stability,
        treatment = :endogenous,
        variables = ["y"],
        definition_key = :linear_fixed_point,
        unit = "arbitrary",
        frequency = "arbitrary",
        measure = "level",
        definition = "定常状態 y*=(I−A)^{-1}c。A の spectral radius<1 で一意の定常状態が存在。",
        doc_ref = "docs/models/var.md §定常状態",
        caveats = ["危機regime 概念なし。係数 A は手入力(推定は対象外)。"],
    ),
    ModelConceptCoverage(;
        model = :var,
        concept = :shock_response,
        treatment = :approximate,
        variables = ["y"],
        definition_key = :hand_input_irf,
        unit = "arbitrary",
        frequency = "arbitrary",
        measure = "level-deviation",
        definition = "impulse_response は定常状態からの乖離 irf[t]=A^{t-1}·shock。構造ショック識別は対象外。",
        doc_ref = "docs/models/var.md §出力,§非対象",
        caveats = ["SVAR 識別・分散分解・信頼区間なし。係数は手入力。"],
    ),
]

"""
    model_concept_coverage(; model=nothing, concept=nothing,
                           registry=MODEL_CONCEPT_REGISTRY) -> Vector{ModelConceptCoverage}

`MODEL_CONCEPT_REGISTRY` を model / concept で絞り込む。両方 `nothing` なら全件。
"""
function model_concept_coverage(;
    model::Union{Symbol, Nothing} = nothing,
    concept::Union{Symbol, Nothing} = nothing,
    registry::Vector{ModelConceptCoverage} = MODEL_CONCEPT_REGISTRY,
)
    filter(registry) do c
        (model === nothing || c.model === model) &&
            (concept === nothing || c.concept === concept)
    end
end

"""
    coverage_concept_definitions(cov::ModelConceptCoverage;
        registry=MODEL_CONCEPT_DEFINITION_REGISTRY) -> Vector{ModelConceptDefinition}

`ModelConceptCoverage`（Phase 4 のクロスモデル比較軸 metadata）が参照する変数に対応する
Phase 5 の `ModelConceptDefinition` を返す。同一モデルかつ `cov.variables` に含まれる変数の
定義を突き合わせる。Phase 4 の `MODEL_CONCEPT_REGISTRY` を段階的に Phase 5 の概念定義
metadata から参照できるようにする橋渡し（Issue #149「既存層との接続」）。

`cov.variables` が空、または対応する概念定義が未登録の場合は空ベクトルを返す。
"""
function coverage_concept_definitions(
    cov::ModelConceptCoverage;
    registry::Vector{ModelConceptDefinition} = MODEL_CONCEPT_DEFINITION_REGISTRY,
)
    isempty(cov.variables) && return ModelConceptDefinition[]
    return filter(registry) do d
        d.model === cov.model && String(d.variable) in cov.variables
    end
end

# ===========================================================================
# CrossModelComparisonContext（ADR 0006 §4）
# ===========================================================================

"""
    CrossModelComparisonContext

クロスモデル比較の構造化コンテキスト（ADR 0006 §4）。LLM API は呼ばない。
`build_cross_model_comparison_context` で作成し、`to_dict` / `to_json` でプロンプトへ埋め込む。

## フィールド
- `contract_version::String`
- `concepts::Vector{Symbol}` / `models::Vector{Symbol}`
- `coverage::Vector{ModelConceptCoverage}` : 対象 (model, concept) の repository metadata
- `mappings::Vector{ModelConceptMapping}` : 概念対応
- `empirical::Union{KeenEmpiricalContext,Nothing}` : Keen 実証結果(あれば)
- `model_metadata::Dict{Symbol,ModelMetadata}` : 比較モデルの repository metadata(任意)
- `sources::Dict{String,EvidenceSource}` : source registry
- `warnings::Vector{ExplanationWarning}`
- `prompt_version::String`
"""
struct CrossModelComparisonContext
    contract_version::String
    concepts::Vector{Symbol}
    models::Vector{Symbol}
    coverage::Vector{ModelConceptCoverage}
    mappings::Vector{ModelConceptMapping}
    empirical::Union{KeenEmpiricalContext, Nothing}
    model_metadata::Dict{Symbol, ModelMetadata}
    sources::Dict{String, EvidenceSource}
    warnings::Vector{ExplanationWarning}
    prompt_version::String
end

# coverage → EvidenceSource（category=:model_concept）
function _xm_coverage_source(c::ModelConceptCoverage)
    EvidenceSource(;
        id = _xm_coverage_source_id(c),
        category = :model_concept,
        context_path = "/coverage/$(c.model)/$(c.concept)",
        label = "$(_xm_model_label(c.model)): $(_xm_concept_label(c.concept))",
        unit = c.unit,
        method_id = c.doc_ref,
    )
end

# mapping → EvidenceSource（category=:concept_mapping）
function _xm_mapping_source(m::ModelConceptMapping)
    EvidenceSource(;
        id = _xm_mapping_source_id(m),
        category = :concept_mapping,
        context_path = "/mappings/$(m.source_model)-$(m.target_model)/$(m.concept)",
        label = "$(_xm_model_label(m.source_model))↔$(_xm_model_label(m.target_model)): $(_xm_concept_label(m.concept)) [$(m.mapping_type)]",
    )
end

# ある concept が比較可能か（equivalent/proxy/partial の mapping が 1 件以上あるか）
function _xm_concept_comparable(mappings::Vector{ModelConceptMapping}, concept::Symbol)
    any(
        m -> m.concept === concept && m.mapping_type in (:equivalent, :proxy, :partial),
        mappings,
    )
end

# ある concept に mapping が存在するか
_xm_concept_has_mapping(mappings::Vector{ModelConceptMapping}, concept::Symbol) =
    any(m -> m.concept === concept, mappings)

# 同名変数が複数モデルで定義差を持つか検出（安全性: DEFINITION_MISMATCH）
function _xm_shared_variable_mismatches(coverage::Vector{ModelConceptCoverage})
    byvar = Dict{String, Vector{ModelConceptCoverage}}()
    for c in coverage
        for v in c.variables
            push!(get!(byvar, v, ModelConceptCoverage[]), c)
        end
    end
    shared = String[]
    for (v, cs) in byvar
        models = unique(c.model for c in cs)
        length(models) >= 2 || continue
        keys_ = unique((c.definition_key, c.measure, c.unit) for c in cs)
        length(keys_) >= 2 && push!(shared, v)
    end
    sort(shared)
end

"""
    build_cross_model_comparison_context(; models, concepts=collect(CROSS_MODEL_CONCEPTS),
        empirical=nothing, model_metadata=Dict{Symbol,ModelMetadata}(),
        registry=MODEL_CONCEPT_REGISTRY) -> CrossModelComparisonContext

`MODEL_CONCEPT_REGISTRY` を (models × concepts) で絞り込み、モデル対ごとの `ModelConceptMapping` を
導出して `CrossModelComparisonContext` を組み立てる（ADR 0006 §4）。source registry・warning を
生成し、比較不能な概念には `INSUFFICIENT_COMPARABILITY`、同名変数の定義差には `DEFINITION_MISMATCH`
を付す。`empirical` を渡すと Keen 実証結果サマリー source（category `:empirical_evidence`）を派生する。

`models` は 2 件以上を要求する（クロスモデル比較のため）。
"""
function build_cross_model_comparison_context(;
    models::Vector{Symbol},
    concepts::Vector{Symbol} = collect(CROSS_MODEL_CONCEPTS),
    empirical::Union{KeenEmpiricalContext, Nothing} = nothing,
    model_metadata::Dict{Symbol, ModelMetadata} = Dict{Symbol, ModelMetadata}(),
    registry::Vector{ModelConceptCoverage} = MODEL_CONCEPT_REGISTRY,
)
    length(models) >= 2 || throw(
        ArgumentError(
            "クロスモデル比較には 2 件以上の models が必要です（受領: $(models)）",
        ),
    )
    for c in concepts
        c in CROSS_MODEL_CONCEPTS || throw(
            ArgumentError("未知の concept: $(repr(c))（有効: $(CROSS_MODEL_CONCEPTS)）"),
        )
    end

    # 対象 coverage を registry から収集（存在するものだけ）
    coverage = ModelConceptCoverage[]
    for m in models, con in concepts
        found = model_concept_coverage(; model = m, concept = con, registry = registry)
        append!(coverage, found)
    end

    # mapping を導出（model 対 × concept、両モデルに coverage があるもの）
    covmap = Dict{Tuple{Symbol, Symbol}, ModelConceptCoverage}()
    for c in coverage
        covmap[(c.model, c.concept)] = c
    end
    mappings = ModelConceptMapping[]
    for i in 1:length(models), j in (i + 1):length(models)
        ma, mb = models[i], models[j]
        for con in concepts
            a = get(covmap, (ma, con), nothing)
            b = get(covmap, (mb, con), nothing)
            (a === nothing || b === nothing) && continue
            push!(mappings, derive_concept_mapping(a, b))
        end
    end

    # source registry
    sources = Dict{String, EvidenceSource}()
    for c in coverage
        s = _xm_coverage_source(c)
        sources[s.id] = s
    end
    for m in mappings
        s = _xm_mapping_source(m)
        sources[s.id] = s
    end
    # 安全性・契約の限界 source
    sources["limitation.cross_model_contract"] = EvidenceSource(;
        id = "limitation.cross_model_contract",
        category = :limitations,
        context_path = "/warnings",
        label = "クロスモデル比較の安全性・限界(ADR 0006)",
        method_id = CROSS_MODEL_OUTPUT_CONTRACT_VERSION,
    )

    warnings = ExplanationWarning[]
    # fit 比較の制限（既定 info）
    push!(
        warnings,
        ExplanationWarning(;
            code = "FIT_COMPARISON_RESTRICTED",
            severity = :info,
            message = "モデル別 fit の単純比較は、対象系列・期間・自由度・推定方法が一致する場合に限る。",
            affected_sections = ["empirical_support"],
        ),
    )
    # 比較不能な concept
    incomparable = Symbol[]
    for con in concepts
        _xm_concept_has_mapping(mappings, con) || continue
        _xm_concept_comparable(mappings, con) && continue
        push!(incomparable, con)
    end
    if !isempty(incomparable)
        push!(
            warnings,
            ExplanationWarning(;
                code = "INSUFFICIENT_COMPARABILITY",
                severity = :warning,
                message = "比較不能(全 mapping が incompatible)な概念: " *
                          join(String.(incomparable), ", ") *
                          "。これらは統合・平均せず insufficient_comparability として扱う。",
                affected_sections = ["concept_mappings", "incomparable_or_insufficient"],
            ),
        )
    end
    # 同名変数の定義差
    shared = _xm_shared_variable_mismatches(coverage)
    if !isempty(shared)
        push!(
            warnings,
            ExplanationWarning(;
                code = "DEFINITION_MISMATCH",
                severity = :warning,
                message = "複数モデルで名称は同じだが定義が異なる変数: " *
                          join(shared, ", ") *
                          "。equivalent とせず定義差を明示する。",
                affected_sections = ["concept_mappings", "mechanisms_by_model"],
            ),
        )
    end
    # 実証 fit は Keen 実証層のみ
    if empirical !== nothing
        push!(
            warnings,
            ExplanationWarning(;
                code = "EMPIRICAL_ONLY_FOR_KEEN",
                severity = :info,
                message = "本コンテキストで実証 fit を持つのは Keen 実証層のみ。非当てはめモデルの反証・肯定には使わない。",
                affected_sections = ["empirical_support"],
            ),
        )
        # 実証結果サマリー source（category=:empirical_evidence）
        for (sid, label) in (
            ("empirical.keen.calibration", "Keen 限定キャリブレーション要約"),
            ("empirical.keen.validation", "Keen 実証検証の集計 fit 要約"),
            ("empirical.keen.regime", "Keen regime 診断要約"),
        )
            sources[sid] = EvidenceSource(;
                id = sid,
                category = :empirical_evidence,
                context_path = "/empirical",
                label = label,
                method_id = empirical.contract_version,
            )
        end
    end

    CrossModelComparisonContext(
        CROSS_MODEL_CONTEXT_CONTRACT_VERSION,
        collect(concepts),
        collect(models),
        coverage,
        mappings,
        empirical,
        model_metadata,
        sources,
        warnings,
        CROSS_MODEL_PROMPT_VERSION,
    )
end

"""
    insufficient_comparability_concepts(ctx::CrossModelComparisonContext) -> Vector{Symbol}

すべての cross-model mapping が `incompatible` で比較不能な概念を返す（ADR 0006 §4・§7）。
"""
function insufficient_comparability_concepts(ctx::CrossModelComparisonContext)
    [
        con for con in ctx.concepts if _xm_concept_has_mapping(ctx.mappings, con) &&
            !_xm_concept_comparable(ctx.mappings, con)
    ]
end

# ===========================================================================
# 出力型 CrossModelReasoningOutput（ADR 0006 §6）
# ===========================================================================

"""
    CrossModelReasoningOutput

クロスモデル推論の根拠付き構造化出力（ADR 0006 §6）。ADR 0005 の `ExplanationSection` /
`EvidenceClaim` を再利用し、必須 section を表示順で常に持つ。`source_references` は claim から
実際に参照された registry entry のみを重複なく保持する。

## 生成モード（`generation_status`）
- `:deterministic` : provider 未接続。検証済み context だけから決定的に生成
- `:parsed` : provider 応答が schema・source・安全性検証を通過
- `:fallback` : provider 応答が検証に失敗し、決定的 fallback へ落ちた
"""
struct CrossModelReasoningOutput
    contract_version::String
    prompt_version::String
    generation_status::Symbol
    audience::Symbol
    detail::Symbol
    executive_summary::ExplanationSection
    comparison_scope::ExplanationSection
    concept_mappings::ExplanationSection
    mechanisms_by_model::ExplanationSection
    consistent_observations::ExplanationSection
    divergent_conclusions::ExplanationSection
    empirical_support::ExplanationSection
    incomparable_or_insufficient::ExplanationSection
    next_evidence::ExplanationSection
    limitations::ExplanationSection
    source_references::Vector{EvidenceSource}
    reproducibility::Dict{String, Any}
    warnings::Vector{ExplanationWarning}
    prompt::String
    disclaimer::String
end

function _xm_section(out::CrossModelReasoningOutput, key::String)
    key == "executive_summary" && return out.executive_summary
    key == "comparison_scope" && return out.comparison_scope
    key == "concept_mappings" && return out.concept_mappings
    key == "mechanisms_by_model" && return out.mechanisms_by_model
    key == "consistent_observations" && return out.consistent_observations
    key == "divergent_conclusions" && return out.divergent_conclusions
    key == "empirical_support" && return out.empirical_support
    key == "incomparable_or_insufficient" && return out.incomparable_or_insufficient
    key == "next_evidence" && return out.next_evidence
    key == "limitations" && return out.limitations
    throw(ArgumentError("未知の section key: $(key)"))
end

# ===========================================================================
# system prompt / schema instruction / build_cross_model_prompt（ADR 0006 §6・§7）
# ===========================================================================

const _XM_SYSTEM_PROMPT = """
あなたは DME のクロスモデル推論アシスタントです。Keen 実証結果と既存マクロモデルの比較を、
リポジトリの構造化コンテキスト（repository metadata と概念対応）だけを根拠に説明します。

厳守事項（ADR 0006）:
- 同名変数でも定義が異なれば同一視しない。mapping_type と unit/measure 差を明示する。
- モデルの性質は context の repository metadata のみを根拠とし、一般知識で補完しない。根拠が
  無ければ not_available / insufficient_comparability とする。
- 比較不能（incompatible のみ）な概念を統合・平均・単一ランキングへ潰さない。
- モデル別 fit の単純比較は、対象系列・期間・自由度・推定方法が一致する場合に限る。実証 fit を
  持つのは Keen 実証層のみである。
- あるモデルの失敗を別モデルの正しさの証明にしない。実証的支持/反証は比較可能範囲の条件付き記述に限る。
- 各 claim は 1 つの epistemic_status（metadata / mapping / empirical / comparative / limitation）を持ち、
  source_ids は context の source registry に存在する ID を 1 件以上参照する。
"""

function _xm_output_schema_instruction()
    secs = join(["  \"$(k)\": {section}" for k in CROSS_MODEL_OUTPUT_SECTION_ORDER], ",\n")
    """
出力は次の JSON スキーマに厳密に従ってください。Markdown code fence や前後の自由文を付けない。

{
  "contract_version": "$(CROSS_MODEL_OUTPUT_CONTRACT_VERSION)",
$(secs)
}

各 {section} は {"status": "available|not_available|insufficient_comparability",
"claims": [{"claim_id": str, "text": str,
"epistemic_status": "metadata|mapping|empirical|comparative|limitation",
"source_ids": [str, ...], "qualifiers": [str, ...]}], "missing_fields": [str, ...]}。

制約:
- source_ids はすべて context の source registry に存在する ID。
- epistemic_status=metadata の claim は category=model_concept の source のみ、
  mapping は concept_mapping のみ、empirical は empirical_evidence のみを参照する。
  comparative / limitation の合成 claim は複数 category の source を参照できる。
- 情報が無い section は status=not_available、比較不能は insufficient_comparability。
"""
end

"""
    build_cross_model_prompt(ctx::CrossModelComparisonContext; audience=:analyst,
                             detail=:standard) -> String

クロスモデル推論の完成済み prompt を生成する（provider 呼び出しから分離。ADR 0006 §6）。
system 指示・context JSON・出力スキーマ指示・免責を結合する。
"""
function build_cross_model_prompt(
    ctx::CrossModelComparisonContext;
    audience::Symbol = :analyst,
    detail::Symbol = :standard,
)
    ctx_json = JSON3.write(to_dict(ctx))
    """
$(_XM_SYSTEM_PROMPT)

対象読者: $(audience)、詳細度: $(detail)。

# 比較コンテキスト（JSON）
$(ctx_json)

# 出力形式
$(_xm_output_schema_instruction())

必ず次の免責を出力の disclaimer 相当として意識してください:
「$(replace(_DISCLAIMER_JA, "\n" => " "))」
"""
end

# ===========================================================================
# 決定的 section 生成（ADR 0006 §6・§7.2）
# ===========================================================================

# section に影響する warning severity / messages
function _xm_section_severity(warnings::Vector{ExplanationWarning}, section::String)
    sev = nothing
    for w in warnings
        section in w.affected_sections || continue
        if sev === nothing || _KEEN_SEVERITY_RANK[w.severity] > _KEEN_SEVERITY_RANK[sev]
            sev = w.severity
        end
    end
    sev
end

function _xm_section_warning_messages(warnings::Vector{ExplanationWarning}, section::String)
    ["[$(w.code)] $(w.message)" for w in warnings if section in w.affected_sections]
end

# 比較対象の全 coverage source id（scope 等の合成 claim 用）
_xm_all_coverage_ids(ctx) = sort!([_xm_coverage_source_id(c) for c in ctx.coverage])

function _xm_scope_section(ctx::CrossModelComparisonContext)
    counts = Dict{Symbol, Int}()
    for m in ctx.mappings
        counts[m.mapping_type] = get(counts, m.mapping_type, 0) + 1
    end
    cnt_str = join(["$(t)=$(get(counts, t, 0))" for t in CROSS_MODEL_MAPPING_TYPES], ", ")
    all_ids = _xm_all_coverage_ids(ctx)
    isempty(all_ids) &&
        return ExplanationSection(:not_available, EvidenceClaim[], ["coverage"])
    claims = EvidenceClaim[EvidenceClaim(;
        claim_id = "scope.extent",
        text = "比較対象モデル: $(join(_xm_model_label.(ctx.models), ", "))。" *
               "比較軸: $(join(_xm_concept_label.(ctx.concepts), ", "))。" *
               "概念対応 $(length(ctx.mappings)) 件（$(cnt_str)）。" *
               "実証結果: $(ctx.empirical === nothing ? "なし" : "Keen 実証層あり")。",
        epistemic_status = :comparative,
        source_ids = all_ids,
    ),]
    ExplanationSection(:available, claims, String[])
end

function _xm_mappings_section(ctx::CrossModelComparisonContext)
    isempty(ctx.mappings) &&
        return ExplanationSection(:not_available, EvidenceClaim[], ["mappings"])
    notes = _xm_section_warning_messages(ctx.warnings, "concept_mappings")
    claims = EvidenceClaim[]
    for m in ctx.mappings
        diffs = String[]
        m.unit_difference === nothing || push!(diffs, "unit: $(m.unit_difference)")
        m.frequency_difference === nothing ||
            push!(diffs, "freq: $(m.frequency_difference)")
        m.aggregation_difference === nothing ||
            push!(diffs, "measure: $(m.aggregation_difference)")
        diff_str = isempty(diffs) ? "差分なし" : join(diffs, "; ")
        push!(
            claims,
            EvidenceClaim(;
                claim_id = "mapping.$(m.source_model).$(m.target_model).$(m.concept)",
                text = "$(_xm_model_label(m.source_model))↔$(_xm_model_label(m.target_model)) / " *
                       "$(_xm_concept_label(m.concept)): [$(m.mapping_type)]（$(diff_str)）。",
                epistemic_status = :mapping,
                source_ids = [_xm_mapping_source_id(m)],
                qualifiers = m.caveats,
            ),
        )
    end
    ExplanationSection(:available, claims, notes)
end

function _xm_mechanisms_section(ctx::CrossModelComparisonContext)
    notes = _xm_section_warning_messages(ctx.warnings, "mechanisms_by_model")
    claims = EvidenceClaim[]
    for m in ctx.models
        cov = [c for c in ctx.coverage if c.model === m && c.treatment !== :out_of_scope]
        isempty(cov) && continue
        parts = [
            "$(_xm_concept_label(c.concept))（$(c.treatment)$(isempty(c.variables) ? "" : ", 変数=" * join(c.variables, "/"))）: $(c.definition)"
            for c in cov
        ]
        push!(
            claims,
            EvidenceClaim(;
                claim_id = "mechanism.$(m)",
                text = "$(_xm_model_label(m)) が扱うメカニズム — " * join(parts, " / "),
                epistemic_status = :metadata,
                source_ids = [_xm_coverage_source_id(c) for c in cov],
            ),
        )
    end
    isempty(claims) &&
        return ExplanationSection(:not_available, EvidenceClaim[], ["coverage"])
    ExplanationSection(:available, claims, notes)
end

function _xm_consistent_section(ctx::CrossModelComparisonContext)
    claims = EvidenceClaim[]
    # 概念ごとに 2 モデル以上が内生化していれば構造的一致として記述
    for con in ctx.concepts
        endog =
            [c for c in ctx.coverage if c.concept === con && c.treatment === :endogenous]
        length(endog) >= 2 || continue
        push!(
            claims,
            EvidenceClaim(;
                claim_id = "consistent.endogenous.$(con)",
                text = "$(_xm_concept_label(con)) を内生化するモデル: " *
                       join([_xm_model_label(c.model) for c in endog], ", ") *
                       "（docs 上の構造的一致であり、同一データへの実証的一致ではない）。",
                epistemic_status = :comparative,
                source_ids = [_xm_coverage_source_id(c) for c in endog],
            ),
        )
    end
    # equivalent mapping は概念対応上の一致
    for m in ctx.mappings
        m.mapping_type === :equivalent || continue
        push!(
            claims,
            EvidenceClaim(;
                claim_id = "consistent.equivalent.$(m.source_model).$(m.target_model).$(m.concept)",
                text = "$(_xm_model_label(m.source_model)) と $(_xm_model_label(m.target_model)) は " *
                       "$(_xm_concept_label(m.concept)) の扱いが equivalent。",
                epistemic_status = :comparative,
                source_ids = [_xm_mapping_source_id(m)],
                qualifiers = m.caveats,
            ),
        )
    end
    isempty(claims) && return ExplanationSection(
        :not_available,
        EvidenceClaim[],
        ["consistent_observations"],
    )
    ExplanationSection(:available, claims, String[])
end

# concept の分岐原因（docs 準拠の根拠となる仮定）
const _XM_DIVERGENCE_CAUSE = Dict{Symbol, String}(
    :private_debt_credit => "民間債務・信用を内生化するか（Keen）、金融市場・信用を対象外とするか（実物・需要モデル）という仮定の差。",
    :income_distribution => "分配を賃金シェアの動学として内生化するか（Keen）、資本分配率 α を固定パラメータ／限界生産力の静的分配とするかの差。",
    :demand_and_instability => "不安定性をモデル内生の非線形性で生むか（Keen）、市場清算・供給決定で需要不足を排除するか（RBC/Ramsey/Solow）、外生ショックで需要を動かすか（IS-LM/NK 等）という決定の差。",
    :steady_state_stability => "単一の収束的定常状態・静学均衡を持つか、危機regime を含む双安定性を持つか（Keen のみ）という力学の差。",
    :shock_response => "確率的外生ショック駆動の IRF か（RBC/NK）、比較静学か（IS-LM/AD-AS/MF/Solow）、均衡攪乱か（Keen/Ramsey）という反応の定式化の差。",
)

function _xm_divergent_section(ctx::CrossModelComparisonContext)
    claims = EvidenceClaim[]
    for con in ctx.concepts
        cov = [c for c in ctx.coverage if c.concept === con]
        length(cov) >= 2 || continue
        treatments = unique(c.treatment for c in cov)
        length(treatments) >= 2 || continue  # 全モデル同じ扱いなら相違なし
        groups = [
            "$(t): " *
            join([_xm_model_label(c.model) for c in cov if c.treatment === t], ", ") for
            t in CROSS_MODEL_TREATMENTS if any(c -> c.treatment === t, cov)
        ]
        push!(
            claims,
            EvidenceClaim(;
                claim_id = "divergent.$(con)",
                text = "$(_xm_concept_label(con)) の扱いが分岐 — " *
                       join(groups, " ／ ") *
                       "。原因となる仮定: " *
                       get(_XM_DIVERGENCE_CAUSE, con, ""),
                epistemic_status = :comparative,
                source_ids = [_xm_coverage_source_id(c) for c in cov],
            ),
        )
    end
    isempty(claims) && return ExplanationSection(
        :not_available,
        EvidenceClaim[],
        ["divergent_conclusions"],
    )
    ExplanationSection(:available, claims, String[])
end

function _xm_empirical_section(ctx::CrossModelComparisonContext)
    kctx = ctx.empirical
    kctx === nothing &&
        return ExplanationSection(:not_available, EvidenceClaim[], ["empirical"])
    notes = _xm_section_warning_messages(ctx.warnings, "empirical_support")
    base_qual = vcat(
        [
            "実証 fit を持つのは Keen 実証層のみ。系列・期間・自由度・方法が一致しない他モデルとの単純 fit 比較はしない。",
            "あるモデルの失敗を別モデルの正しさの証明にしない。",
        ],
        notes,
    )
    claims = EvidenceClaim[]
    sc = kctx.analysis_scope
    v = kctx.validation
    if v !== nothing
        worse = v.calibrated_worse_than_literature
        push!(
            claims,
            EvidenceClaim(;
                claim_id = "empirical.keen.fit",
                text = "Keen 実証検証（$(sc.country), $(sc.sample_start)〜$(sc.sample_end)）: " *
                       "集計 RMSE literature=$(_keen_fmt(v.aggregate_rmse_literature))、" *
                       "calibrated=$(_keen_fmt(v.aggregate_rmse_calibrated))、" *
                       "calibrated が literature より悪化=$(worse)。" *
                       "この条件付き fit の範囲でのみ Keen の債務駆動機構と整合を評価できる。",
                epistemic_status = :empirical,
                source_ids = ["empirical.keen.validation"],
                qualifiers = base_qual,
            ),
        )
    end
    if kctx.calibration !== nothing
        c = kctx.calibration
        push!(
            claims,
            EvidenceClaim(;
                claim_id = "empirical.keen.calibration",
                text = "限定キャリブレーション: converged=$(c.converged)、" *
                       "objective=$(_keen_fmt(c.objective_value))。" *
                       (
                           c.converged ? "" :
                           "未収束のため推定値を真値・構造値として解釈しない。"
                       ),
                epistemic_status = :empirical,
                source_ids = ["empirical.keen.calibration"],
                qualifiers = base_qual,
            ),
        )
    end
    # 相対的支持/反証の限定記述（合成）
    debt_models = [c.model for c in ctx.coverage if c.concept === :private_debt_credit]
    oos_models = [
        c.model for c in ctx.coverage if
        c.concept === :private_debt_credit && c.treatment === :out_of_scope
    ]
    if :keen in ctx.models && !isempty(oos_models)
        push!(
            claims,
            EvidenceClaim(;
                claim_id = "empirical.relative_support",
                text = "現在の実証結果は、Keen が内生化する民間債務・信用の役割を検証済み fit の範囲で条件付きに評価するに留まる。" *
                       "民間債務を対象外とするモデル（$(join(_xm_model_label.(oos_models), ", "))）は同一系列に当てはめていないため、" *
                       "この結果はそれらの反証にも肯定にもならない。",
                epistemic_status = :comparative,
                source_ids = vcat(
                    ["empirical.keen.validation"],
                    ["concept.$(m).private_debt_credit" for m in debt_models],
                ),
                qualifiers = base_qual,
            ),
        )
    end
    isempty(claims) &&
        return ExplanationSection(:insufficient_comparability, EvidenceClaim[], notes)
    ExplanationSection(:available, claims, notes)
end

function _xm_incomparable_section(ctx::CrossModelComparisonContext)
    notes = _xm_section_warning_messages(ctx.warnings, "incomparable_or_insufficient")
    incomp_concepts = insufficient_comparability_concepts(ctx)
    incompat_maps = [m for m in ctx.mappings if m.mapping_type === :incompatible]
    claims = EvidenceClaim[]
    for con in incomp_concepts
        push!(
            claims,
            EvidenceClaim(;
                claim_id = "insufficient.$(con)",
                text = "$(_xm_concept_label(con)) は比較可能な対応が無く（全 mapping が incompatible）、" *
                       "insufficient_comparability とする。統合・平均・単一ランキングへ潰さない。",
                epistemic_status = :comparative,
                source_ids = [
                    _xm_mapping_source_id(m) for m in ctx.mappings if m.concept === con
                ],
            ),
        )
    end
    for m in incompat_maps
        push!(
            claims,
            EvidenceClaim(;
                claim_id = "incompatible.$(m.source_model).$(m.target_model).$(m.concept)",
                text = "$(_xm_model_label(m.source_model))↔$(_xm_model_label(m.target_model)) の " *
                       "$(_xm_concept_label(m.concept)) は比較不能（incompatible）。",
                epistemic_status = :mapping,
                source_ids = [_xm_mapping_source_id(m)],
                qualifiers = m.caveats,
            ),
        )
    end
    if isempty(claims)
        return ExplanationSection(
            :not_available,
            EvidenceClaim[],
            ["incomparable_or_insufficient"],
        )
    end
    status = isempty(incomp_concepts) ? :available : :insufficient_comparability
    ExplanationSection(status, claims, notes)
end

function _xm_next_evidence_section(ctx::CrossModelComparisonContext)
    lim = "limitation.cross_model_contract"
    claims = EvidenceClaim[]
    incomp = insufficient_comparability_concepts(ctx)
    if !isempty(incomp)
        push!(
            claims,
            EvidenceClaim(;
                claim_id = "next.incomparable",
                text = "比較不能な概念（" *
                       join(_xm_concept_label.(incomp), ", ") *
                       "）については、対応する内生機構を持つ追加モデル（例: SFC / Ryoo 型）や、" *
                       "共通の観測系列を要する。",
                epistemic_status = :comparative,
                source_ids = [lim],
            ),
        )
    end
    if ctx.empirical === nothing
        push!(
            claims,
            EvidenceClaim(;
                claim_id = "next.empirical",
                text = "実証的支持/反証を述べるには Keen 実証層（キャリブレーション・検証）の実行結果が必要。",
                epistemic_status = :comparative,
                source_ids = [lim],
            ),
        )
    else
        v = ctx.empirical.validation
        if v !== nothing && v.calibrated_worse_than_literature
            push!(
                claims,
                EvidenceClaim(;
                    claim_id = "next.oos",
                    text = "calibrated が literature より悪化しているため、識別戦略の改善と out-of-sample 検証の追加が必要。",
                    epistemic_status = :comparative,
                    source_ids = ["empirical.keen.validation"],
                ),
            )
        end
    end
    push!(
        claims,
        EvidenceClaim(;
            claim_id = "next.common_series",
            text = "モデル別 fit を比較するには、対象系列・期間・自由度・推定方法をそろえた共通の検証設計が必要。",
            epistemic_status = :comparative,
            source_ids = [lim],
        ),
    )
    ExplanationSection(:available, claims, String[])
end

function _xm_limitations_section(ctx::CrossModelComparisonContext)
    lim = "limitation.cross_model_contract"
    safety = [
        "同名変数でも定義が異なる場合は一致とみなさない。",
        "fit 指標の単純比較は、対象系列・期間・自由度・推定方法が一致する場合に限定する。",
        "一つのモデルの失敗を別モデルの正しさの証明と解釈しない。",
        "モデルの性質は repository metadata のみを根拠とし、未登録モデルを一般知識で補完しない。",
    ]
    claims = EvidenceClaim[EvidenceClaim(;
        claim_id = "limitation.safety",
        text = "クロスモデル比較の安全性制約: " * join(safety, " "),
        epistemic_status = :limitation,
        source_ids = [lim],
    ),]
    for w in ctx.warnings
        w.severity === :info && continue
        push!(
            claims,
            EvidenceClaim(;
                claim_id = "limitation.warning.$(w.code)",
                text = "[$(w.severity)] $(w.code): $(w.message)",
                epistemic_status = :limitation,
                source_ids = [lim],
                qualifiers = isempty(w.affected_sections) ? String[] :
                             ["影響 section: $(join(w.affected_sections, ", "))"],
            ),
        )
    end
    ExplanationSection(:available, claims, String[])
end

function _xm_executive_summary(
    ctx::CrossModelComparisonContext,
    sections::Dict{String, ExplanationSection},
)
    lim = "limitation.cross_model_contract"
    flagged = [
        k for k in CROSS_MODEL_OUTPUT_SECTION_ORDER if
        k != "executive_summary" && sections[k].status === :insufficient_comparability
    ]
    all_ids = _xm_all_coverage_ids(ctx)
    src = isempty(all_ids) ? [lim] : all_ids
    claims = EvidenceClaim[EvidenceClaim(;
        claim_id = "exec.overview",
        text = "$(join(_xm_model_label.(ctx.models), ", ")) を $(length(ctx.concepts)) 軸で比較し、" *
               "概念対応・共通点・相違点・実証的支持/反証・比較不能項目・次に必要な証拠を、" *
               "根拠を分離して整理した。",
        epistemic_status = :comparative,
        source_ids = src,
    ),]
    high = [w for w in ctx.warnings if w.severity in (:warning, :error, :blocking)]
    if !isempty(flagged) || !isempty(high)
        push!(
            claims,
            EvidenceClaim(;
                claim_id = "exec.caution",
                text = "比較不能・要注意: section=$(isempty(flagged) ? "なし" : join(flagged, ", "))、" *
                       "警告=$(isempty(high) ? "なし" : join(unique(w.code for w in high), ", "))。" *
                       "これらは統合せず限定して扱う。",
                epistemic_status = :limitation,
                source_ids = [lim],
            ),
        )
    end
    ExplanationSection(:available, claims, String[])
end

# claim から参照された source を registry entry へ解決（重複排除・登録済のみ）
function _xm_collect_source_references(
    sections::Dict{String, ExplanationSection},
    sources::Dict{String, EvidenceSource},
)
    seen = String[]
    refs = EvidenceSource[]
    for key in CROSS_MODEL_OUTPUT_SECTION_ORDER
        for cl in sections[key].claims
            for id in cl.source_ids
                (id in seen) && continue
                haskey(sources, id) || continue
                push!(seen, id)
                push!(refs, sources[id])
            end
        end
    end
    refs
end

function _xm_reproducibility(
    ctx::CrossModelComparisonContext,
    audience::Symbol,
    detail::Symbol,
)
    d = Dict{String, Any}(
        "context_contract_version" => ctx.contract_version,
        "output_contract_version" => CROSS_MODEL_OUTPUT_CONTRACT_VERSION,
        "prompt_version" => ctx.prompt_version,
        "audience" => string(audience),
        "detail" => string(detail),
        "models" => String.(ctx.models),
        "concepts" => String.(ctx.concepts),
        "n_mappings" => length(ctx.mappings),
        "n_coverage" => length(ctx.coverage),
        "has_empirical" => ctx.empirical !== nothing,
    )
    if ctx.empirical !== nothing
        d["empirical_contract_version"] = ctx.empirical.contract_version
        d["empirical_country"] = ctx.empirical.analysis_scope.country
    end
    d
end

function _xm_build_deterministic(
    ctx::CrossModelComparisonContext,
    prompt::String,
    generation_status::Symbol,
    audience::Symbol,
    detail::Symbol,
    extra_warnings::Vector{ExplanationWarning},
)
    sections = Dict{String, ExplanationSection}(
        "comparison_scope" => _xm_scope_section(ctx),
        "concept_mappings" => _xm_mappings_section(ctx),
        "mechanisms_by_model" => _xm_mechanisms_section(ctx),
        "consistent_observations" => _xm_consistent_section(ctx),
        "divergent_conclusions" => _xm_divergent_section(ctx),
        "empirical_support" => _xm_empirical_section(ctx),
        "incomparable_or_insufficient" => _xm_incomparable_section(ctx),
        "next_evidence" => _xm_next_evidence_section(ctx),
        "limitations" => _xm_limitations_section(ctx),
    )
    sections["executive_summary"] = _xm_executive_summary(ctx, sections)

    all_warnings = vcat(copy(ctx.warnings), extra_warnings)
    refs = _xm_collect_source_references(sections, ctx.sources)

    CrossModelReasoningOutput(
        CROSS_MODEL_OUTPUT_CONTRACT_VERSION,
        ctx.prompt_version,
        generation_status,
        audience,
        detail,
        sections["executive_summary"],
        sections["comparison_scope"],
        sections["concept_mappings"],
        sections["mechanisms_by_model"],
        sections["consistent_observations"],
        sections["divergent_conclusions"],
        sections["empirical_support"],
        sections["incomparable_or_insufficient"],
        sections["next_evidence"],
        sections["limitations"],
        refs,
        _xm_reproducibility(ctx, audience, detail),
        all_warnings,
        prompt,
        _DISCLAIMER_JA,
    )
end

_xm_parser_failure_warning(reason::String) = ExplanationWarning(;
    code = "OUTPUT_SCHEMA_INVALID",
    severity = :blocking,
    message = "provider 応答の検証に失敗したため決定的 fallback を採用しました: $(reason)",
    affected_sections = collect(CROSS_MODEL_OUTPUT_SECTION_ORDER),
)

# ===========================================================================
# provider 応答の検証（ADR 0006 §7 / ADR 0005 §7.1 準拠）
# ===========================================================================

function _xm_parse_claim(raw, section::String, sources::Dict{String, EvidenceSource})
    (raw isa AbstractDict) || error("$(section): claim が object ではありません")
    for k in ("claim_id", "text", "epistemic_status", "source_ids")
        haskey(raw, k) || error("$(section): claim に必須 field '$(k)' がありません")
    end
    status = Symbol(String(raw["epistemic_status"]))
    status in CROSS_MODEL_STATUSES ||
        error("$(section): 不正な epistemic_status '$(status)'")
    sids = raw["source_ids"]
    (sids isa AbstractVector && !isempty(sids)) ||
        error("$(section): source_ids は 1 件以上必要です")
    source_ids = String[]
    for id in sids
        sid = String(id)
        haskey(sources, sid) || error("$(section): 未登録の source_id '$(sid)'")
        # atomic status は category との整合を要求。合成 status(comparative/limitation)は複数 category 可
        if status in (:metadata, :mapping, :empirical)
            expected = get(_XM_CATEGORY_STATUS, sources[sid].category, nothing)
            expected === status || error(
                "$(section): source '$(sid)'（$(sources[sid].category)）と status '$(status)' が不整合",
            )
        end
        push!(source_ids, sid)
    end
    quals = get(raw, "qualifiers", String[])
    qualifiers = quals isa AbstractVector ? String[String(q) for q in quals] : String[]
    EvidenceClaim(
        String(raw["claim_id"]),
        String(raw["text"]),
        status,
        source_ids,
        qualifiers,
    )
end

function _xm_parse_section(raw, section::String, sources::Dict{String, EvidenceSource})
    (raw isa AbstractDict) || error("section '$(section)' が object ではありません")
    haskey(raw, "status") || error("section '$(section)' に status がありません")
    status = Symbol(String(raw["status"]))
    status in CROSS_MODEL_SECTION_STATUSES ||
        error("section '$(section)' の status '$(status)' が不正です")
    claims_raw = get(raw, "claims", [])
    (claims_raw isa AbstractVector) ||
        error("section '$(section)' の claims が配列ではありません")
    claims = EvidenceClaim[_xm_parse_claim(c, section, sources) for c in claims_raw]
    mf_raw = get(raw, "missing_fields", String[])
    missing_fields =
        mf_raw isa AbstractVector ? String[String(x) for x in mf_raw] : String[]
    ExplanationSection(status, claims, missing_fields)
end

"""
    parse_cross_model_response(raw, ctx; audience=:analyst, detail=:standard, prompt="")
        -> Union{CrossModelReasoningOutput, Nothing}

provider の raw 応答（JSON 文字列）を検証し、成功時に `generation_status=:parsed` の
[`CrossModelReasoningOutput`](@ref) を返す。検証に失敗した場合は `nothing`（呼び出し側が
決定的 fallback を採用する。ADR 0006 §7）。
"""
function parse_cross_model_response(
    raw::AbstractString,
    ctx::CrossModelComparisonContext;
    audience::Symbol = :analyst,
    detail::Symbol = :standard,
    prompt::String = "",
)::Union{CrossModelReasoningOutput, Nothing}
    parsed = try
        JSON3.read(raw, Dict{String, Any})
    catch
        return nothing
    end
    try
        get(parsed, "contract_version", "") == CROSS_MODEL_OUTPUT_CONTRACT_VERSION ||
            error("contract_version 不一致")
        secs = Dict{String, ExplanationSection}()
        for key in CROSS_MODEL_OUTPUT_SECTION_ORDER
            haskey(parsed, key) || error("必須 section '$(key)' がありません")
            secs[key] = _xm_parse_section(parsed[key], key, ctx.sources)
        end
        refs = _xm_collect_source_references(secs, ctx.sources)
        return CrossModelReasoningOutput(
            CROSS_MODEL_OUTPUT_CONTRACT_VERSION,
            ctx.prompt_version,
            :parsed,
            audience,
            detail,
            secs["executive_summary"],
            secs["comparison_scope"],
            secs["concept_mappings"],
            secs["mechanisms_by_model"],
            secs["consistent_observations"],
            secs["divergent_conclusions"],
            secs["empirical_support"],
            secs["incomparable_or_insufficient"],
            secs["next_evidence"],
            secs["limitations"],
            refs,
            _xm_reproducibility(ctx, audience, detail),
            copy(ctx.warnings),
            prompt,
            _DISCLAIMER_JA,
        )
    catch
        return nothing
    end
end

# ===========================================================================
# 公開 API（ADR 0006 §6）
# ===========================================================================

_xm_has_blocking(ctx::CrossModelComparisonContext) =
    any(w -> w.severity === :blocking, ctx.warnings)

"""
    explain_cross_model_comparison(ctx::CrossModelComparisonContext; audience=:analyst,
        detail=:standard, provider=nothing, max_tokens=3500, temperature=0.2)
        -> CrossModelReasoningOutput

`CrossModelComparisonContext` から根拠付きのクロスモデル推論を生成する（ADR 0006 §6）。
概念対応・共通点・相違点・実証的支持/反証・比較不能項目・次に必要な証拠を、根拠 category と
`epistemic_status` を分離した必須 section・source 参照・警告・免責とともに常に含む。

## 動作モード
- `provider === nothing`（既定）: LLM を呼ばず、検証済み context だけから決定的に生成する
  （`generation_status=:deterministic`）。
- `provider` 指定: `build_cross_model_prompt` の prompt を送信し、応答を
  [`parse_cross_model_response`](@ref) で検証する。通過で `:parsed`、失敗で parser failure
  warning を付けて決定的 fallback（`:fallback`）へ落とす。context に `blocking` warning が
  ある場合は provider を呼ばず fallback にする。
"""
function explain_cross_model_comparison(
    ctx::CrossModelComparisonContext;
    audience::Symbol = :analyst,
    detail::Symbol = :standard,
    provider::Union{AbstractLLMProvider, Nothing} = nothing,
    max_tokens::Int = 3500,
    temperature::Float64 = 0.2,
)::CrossModelReasoningOutput
    prompt = build_cross_model_prompt(ctx; audience = audience, detail = detail)

    provider === nothing && return _xm_build_deterministic(
        ctx,
        prompt,
        :deterministic,
        audience,
        detail,
        ExplanationWarning[],
    )

    if _xm_has_blocking(ctx)
        return _xm_build_deterministic(
            ctx,
            prompt,
            :fallback,
            audience,
            detail,
            [_xm_parser_failure_warning("context に blocking warning があります")],
        )
    end

    response = try
        complete_from_prompt(
            provider,
            prompt;
            max_tokens = max_tokens,
            temperature = temperature,
        )
    catch e
        return _xm_build_deterministic(
            ctx,
            prompt,
            :fallback,
            audience,
            detail,
            [_xm_parser_failure_warning("provider 呼び出しに失敗しました: $(e)")],
        )
    end

    parsed = parse_cross_model_response(
        response.content,
        ctx;
        audience = audience,
        detail = detail,
        prompt = prompt,
    )
    parsed === nothing || return parsed

    _xm_build_deterministic(
        ctx,
        prompt,
        :fallback,
        audience,
        detail,
        [
            _xm_parser_failure_warning(
                "応答 JSON が schema / source / 安全性検証を通過しませんでした",
            ),
        ],
    )
end

# ===========================================================================
# JSON 化（to_dict / to_json）
# ===========================================================================

to_dict(c::ModelConceptCoverage) = Dict{String, Any}(
    "model" => string(c.model),
    "concept" => string(c.concept),
    "treatment" => string(c.treatment),
    "variables" => copy(c.variables),
    "definition" => c.definition,
    "definition_key" => string(c.definition_key),
    "unit" => c.unit,
    "frequency" => c.frequency,
    "measure" => c.measure,
    "doc_ref" => c.doc_ref,
    "caveats" => copy(c.caveats),
)

to_dict(m::ModelConceptMapping) = Dict{String, Any}(
    "source_model" => string(m.source_model),
    "target_model" => string(m.target_model),
    "concept" => string(m.concept),
    "mapping_type" => string(m.mapping_type),
    "source_variable" => m.source_variable,
    "target_variable" => m.target_variable,
    "unit_difference" => m.unit_difference,
    "frequency_difference" => m.frequency_difference,
    "aggregation_difference" => m.aggregation_difference,
    "caveats" => copy(m.caveats),
    "source_ids" => copy(m.source_ids),
)

"""
    to_dict(ctx::CrossModelComparisonContext) -> Dict{String, Any}
"""
function to_dict(ctx::CrossModelComparisonContext)
    d = Dict{String, Any}(
        "contract_version" => ctx.contract_version,
        "prompt_version" => ctx.prompt_version,
        "concepts" => String.(ctx.concepts),
        "models" => String.(ctx.models),
        "coverage" => Any[to_dict(c) for c in ctx.coverage],
        "mappings" => Any[to_dict(m) for m in ctx.mappings],
        "sources" => Dict{String, Any}(k => to_dict(v) for (k, v) in ctx.sources),
        "warnings" => Any[to_dict(w) for w in ctx.warnings],
    )
    if !isempty(ctx.model_metadata)
        d["model_metadata"] =
            Dict{String, Any}(string(k) => to_dict(v) for (k, v) in ctx.model_metadata)
    end
    if ctx.empirical !== nothing
        d["empirical"] = to_compact_dict(ctx.empirical)
    end
    d
end

to_json(ctx::CrossModelComparisonContext) = JSON3.write(to_dict(ctx))

"""
    to_dict(out::CrossModelReasoningOutput) -> Dict{String, Any}
"""
function to_dict(out::CrossModelReasoningOutput)
    d = Dict{String, Any}(
        "contract_version" => out.contract_version,
        "prompt_version" => out.prompt_version,
        "generation_status" => string(out.generation_status),
        "audience" => string(out.audience),
        "detail" => string(out.detail),
        "source_references" => Any[to_dict(s) for s in out.source_references],
        "reproducibility" => out.reproducibility,
        "warnings" => Any[to_dict(w) for w in out.warnings],
        "disclaimer" => out.disclaimer,
    )
    for key in CROSS_MODEL_OUTPUT_SECTION_ORDER
        d[key] = to_dict(_xm_section(out, key))
    end
    d
end

to_json(out::CrossModelReasoningOutput) = JSON3.write(to_dict(out))
