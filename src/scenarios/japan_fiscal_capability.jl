# japan_fiscal_capability.jl: Japan Fiscal Scenario Lab の scenario family × model
# capability / mapping contract（Issue #274 / Phase 3）。
#
# 5 つの scenario family（low growth + high rates / fiscal consolidation /
# financial repression / high growth・productivity shock / JGB funding-cost shock）を
# 既存 DME モデルでどこまで表現できるかを、**実装前に固定した機械可読な契約**として保持する。
#
# 設計方針（Issue #274 受け入れ条件）:
#   - 表現不能な概念を近いショックへ黙って代理 mapping しない。禁止代理は
#     `forbidden_proxies` として family ごとに明示列挙する。
#   - `representable` / `partial` / `not_representable` を必ず判定し、`partial` /
#     `not_representable` の理由を具体的に書く。
#   - FRE（fiscal-regime-engine）の affinity / share / confidence / dimension score を
#     shock magnitude へ変換しない。FRE snapshot の役割を `:observed_context_only` に固定する。
#   - financial repression を単一の政策金利ショックへ縮約しない（`decomposition_rule`）。
#   - 日本較正済みモデルは存在しないため、`claim_level = :magnitude` を名乗れる mapping は
#     1 つも無い（コンストラクタと registry 健全性検査で強制する）。
#
# 本ファイルは**宣言のみ**であり、scenario catalog（#275）・adapter / runner（#276）・
# E2E / artifact（#277）は実装しない。モデル方程式も変更しない。
#
# 依存: scenarios/macro_events.jl（`MACRO_EVENT_MAGNITUDE_SOURCES`・
# `MACRO_EVENT_TARGET_CONCEPTS`）と core/model_capabilities.jl（`MODEL_CAPABILITY_REGISTRY`）。
# モデル型そのものには依存しない（Symbol のみを扱う）。
#
# 設計契約:
#   docs/architecture/japan_fiscal_scenario_capability.md
#   docs/adr/0020-japan-fiscal-scenario-capability-contract.md

# ===========================================================================
# 契約 version と固定語彙
# ===========================================================================

"Japan fiscal scenario capability 契約の version（#275 の provenance が参照する決定 version）。"
const JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION = "japan-fiscal-scenario-capability/1.0.0"

"Phase 3 で扱う scenario family の安定 ID（#273 の initial scenario families）。"
const JAPAN_FISCAL_SCENARIO_FAMILIES = (
    :low_growth_high_rates,
    :fiscal_consolidation,
    :financial_repression,
    :high_growth_productivity,
    :jgb_funding_cost,
)

"""
明示的 Scenario Assumption の概念語彙（#275 §3 の区分に対応）。

`:policy_rate` と `:long_rate_funding_condition` は、イベント層の
`MACRO_EVENT_TARGET_CONCEPTS` の同名 target concept と**同一の概念・同一の単位**を指す
（意図的な同名）。他の 7 概念はイベント層に対応物を持たない。
"""
const JAPAN_FISCAL_ASSUMPTION_CONCEPTS = (
    :growth_path,                  # 実質 GDP 成長率パスの assumption
    :productivity_growth,          # 労働生産性・TFP の成長率/水準の assumption
    :policy_rate,                  # 名目政策金利（短期）
    :long_rate_funding_condition,  # 長期金利・funding 条件（JGB 利回り等）
    :government_spending,          # 政府支出
    :tax,                          # 税（税率または税額）
    :primary_balance,              # プライマリーバランス
    :inflation,                    # 一般物価上昇率
    :cb_jgb_absorption,            # 中央銀行の JGB 吸収（保有・買入）
)

"モデル出力側の概念語彙（`required_outputs` / `endogenous_outputs` / `unsupported_outputs`）。"
const JAPAN_FISCAL_OUTPUT_CONCEPTS = (
    :output,
    :output_gap,
    :inflation,
    :price_level,
    :nominal_rate,
    :real_rate,
    :private_borrowing_cost,
    :private_debt,
    :employment,
    :consumption,
    :investment,
    :capital_stock,
    :government_balance,
    :government_debt_stock,
    :money_stock,
    :exchange_rate,
    :net_exports,
)

"""
representability の 3 値。判定は family の `required_concepts` と `required_outputs` に対して行い、
3 値は相互排他かつ網羅的である（コンストラクタが強制する）。

- `:representable` … `required_concepts` を**すべて**別々の入力として受け取り、
  かつ `required_outputs` を**すべて**内生的に返す。
- `:partial` … `required_concepts` の**一部**を別々の入力として受け取るが、上の条件を
  満たさない（受け取れない概念があるか、必要な出力を返さない）。受け取れない概念は
  代理へ寄せず unsupported として返す。
- `:not_representable` … `required_concepts` を 1 つも受け取れない、または既存入力の
  意味を読み替えないと表現できない。
"""
const JAPAN_FISCAL_REPRESENTABILITY = (:representable, :partial, :not_representable)

"Phase 3（#276）での採否。`:primary` は実装必須、`:supporting` は任意、`:not_adopted` は実装しない。"
const JAPAN_FISCAL_ADOPTIONS = (:primary, :supporting, :not_adopted)

"assumption 概念がモデル側で受け取られる形式。"
const JAPAN_FISCAL_INPUT_KINDS = (
    :exogenous_path,                 # 期別の外生パス
    :model_parameter,                # モデル構築時のパラメータ（期別に変えられない）
    :structural_parameter,           # 構造パラメータの上書き（CCC の `structural` 等）
    :shock_process,                  # ショック過程（AR(1) 等）への注入
    :initial_state,                  # 初期状態
    :requires_structural_conversion, # 構造ドライバーへの変換を経てのみ受け取れる（変換は非一意）
    :not_accepted,                   # 受け取れない（代理へ寄せない）
)

"モデル入力の時間軸。"
const JAPAN_FISCAL_HORIZONS = (:static, :period, :quarterly, :annual, :continuous_year)

"""
較正の基準。日本較正済み（`:japan_calibrated`）のモデルは現時点で 1 つも存在しない。

- `:japan_calibrated` … 日本データで較正・推定済み
- `:non_japan_calibrated` … 他国（米国）データで較正・推定済み
- `:structural_illustrative` … 較正・推定を持たない（教科書パラメータまたは手入力係数）
- `:not_applicable` … `:not_representable` で較正の問題が生じない
"""
const JAPAN_FISCAL_CALIBRATION_BASES =
    (:japan_calibrated, :non_japan_calibrated, :structural_illustrative, :not_applicable)

"""
model-implied result として主張してよい水準。

- `:none` … 実行しない
- `:direction_only` … 符号（方向）のみ
- `:direction_and_relative_timing` … 符号・相対的な時間形状（peak / onset / duration の順序）
- `:magnitude` … 日本の量として提示してよい

`:magnitude` は `calibration_basis = :japan_calibrated` のときのみ許される。
"""
const JAPAN_FISCAL_CLAIM_LEVELS =
    (:none, :direction_only, :direction_and_relative_timing, :magnitude)

"gap register の解決先。"
const JAPAN_FISCAL_GAP_RESOLUTIONS = (:hold_as_limitation, :followup_issue, :out_of_scope)

"監査対象の候補モデル（`MODEL_CAPABILITY_REGISTRY` の全 11 モデル）。"
const JAPAN_FISCAL_CANDIDATE_MODELS = (
    :ramsey,
    :rbc,
    :solow,
    :islm,
    :adas,
    :new_keynesian,
    :var,
    :mundell_fleming,
    :keen,
    :sim,
    :capex_credit_cycle,
)

# ---------------------------------------------------------------------------
# FRE context contract（#273 core rules / #274 受け入れ条件 3）
# ---------------------------------------------------------------------------

"""
FRE snapshot の役割。`:observed_context_only` に固定する。

FRE snapshot は「現在どの調整レジームに近いか」という**観測コンテキスト**であり、
shock magnitude の生成入力ではない。本 registry のどの mapping も FRE のフィールドを
magnitude 導出に用いない。
"""
const JAPAN_FISCAL_FRE_CONTEXT_ROLE = :observed_context_only

"""
Japan fiscal scenario assumption で許さない `magnitude_source`
（`MACRO_EVENT_MAGNITUDE_SOURCES` の部分集合）。

`:external_belief` は外部システムの belief に付随した数量であり、FRE の
affinity / share / confidence をこの経路から magnitude へ持ち込ませないために禁止する。
"""
const JAPAN_FISCAL_FORBIDDEN_MAGNITUDE_SOURCES = (:external_belief,)

"""
magnitude の導出入力に用いてはならない FRE snapshot のフィールド名。

いずれも「どのレジームに近いか」の度合いであって、経済量ではない
（FRE 設計原則 `Regime affinity ≠ probability`・`DME shock magnitude ≠ regime confidence`）。
"""
const JAPAN_FISCAL_FORBIDDEN_MAGNITUDE_INPUT_FIELDS = (
    "regime_affinity",
    "regime_share",
    "regime_confidence",
    "dimension_score",
    "constraint_pressure",
    "data_quality_score",
)

# ===========================================================================
# 検証ヘルパ
# ===========================================================================

_jf_check(val, vocab, field) =
    val in vocab || throw(ArgumentError("未知の $field: $(repr(val))（有効: $(vocab)）"))

function _jf_check_subset(vals, vocab, field)
    for v in vals
        v in vocab ||
            throw(ArgumentError("未知の $field 要素: $(repr(v))（有効: $(vocab)）"))
    end
    return vals
end

_jf_sym(x::Symbol) = String(x)
_jf_syms(xs) = String[String(x) for x in xs]

# ===========================================================================
# JapanFiscalAssumptionConcept
# ===========================================================================

"""
    JapanFiscalAssumptionConcept

明示的 Scenario Assumption の 1 概念の定義（単位・時点基準・イベント層 target concept との対応）。

## フィールド
- `concept::Symbol` : `JAPAN_FISCAL_ASSUMPTION_CONCEPTS` のいずれか
- `display_name::String` : 表示名
- `definition::String` : 定義（何を主張する assumption か）
- `unit::String` : 単位（`"%pt (annualized)"`・`"bp"`・`"ratio to GDP"` …）
- `basis::Symbol` : `:level` / `:growth_rate` / `:rate` / `:ratio_to_gdp` / `:stock`
- `event_target_concept::Union{Symbol,Nothing}` : 同一概念を指すイベント層 target concept
  （`MACRO_EVENT_TARGET_CONCEPTS`）。対応物が無ければ `nothing`
- `zero_vs_missing::String` : 0 と未指定の区別の意味
- `doc_ref::String` : 根拠 docs
"""
struct JapanFiscalAssumptionConcept
    concept::Symbol
    display_name::String
    definition::String
    unit::String
    basis::Symbol
    event_target_concept::Union{Symbol, Nothing}
    zero_vs_missing::String
    doc_ref::String
end

function JapanFiscalAssumptionConcept(;
    concept::Symbol,
    display_name::String,
    definition::String,
    unit::String,
    basis::Symbol,
    event_target_concept::Union{Symbol, Nothing} = nothing,
    zero_vs_missing::String = "0 は『変化なし』の主張。未指定は『assumption を置いていない』であり 0 へ丸めない。",
    doc_ref::String = "docs/architecture/japan_fiscal_scenario_capability.md",
)
    _jf_check(concept, JAPAN_FISCAL_ASSUMPTION_CONCEPTS, "assumption concept")
    _jf_check(basis, (:level, :growth_rate, :rate, :ratio_to_gdp, :stock), "basis")
    if event_target_concept !== nothing
        _jf_check(event_target_concept, MACRO_EVENT_TARGET_CONCEPTS, "event_target_concept")
    end
    return JapanFiscalAssumptionConcept(
        concept,
        display_name,
        definition,
        unit,
        basis,
        event_target_concept,
        zero_vs_missing,
        doc_ref,
    )
end

"assumption 概念 registry（`JAPAN_FISCAL_ASSUMPTION_CONCEPTS` の全 9 概念）。"
const JAPAN_FISCAL_ASSUMPTION_CONCEPT_REGISTRY = Dict{Symbol, JapanFiscalAssumptionConcept}(
    :growth_path => JapanFiscalAssumptionConcept(;
        concept = :growth_path,
        display_name = "実質GDP成長率パス",
        definition = "実質 GDP の成長率について置く assumption。構造ドライバー（生産性・人口・外部需要・国内需要）を特定しない集計レベルの主張。",
        unit = "%pt (annualized growth rate)",
        basis = :growth_rate,
        zero_vs_missing = "0 は『成長率ゼロ』。未指定は『成長について assumption を置いていない』であり、モデルの内生成長をそのまま使う。",
    ),
    :productivity_growth => JapanFiscalAssumptionConcept(;
        concept = :productivity_growth,
        display_name = "生産性成長率・潜在産出水準",
        definition = "労働生産性または TFP の成長率（`:growth_rate`）もしくは潜在産出の水準シフト。`:growth_path` とは別概念であり、相互に自動変換しない。",
        unit = "%pt (annualized growth rate) または level index",
        basis = :growth_rate,
    ),
    :policy_rate => JapanFiscalAssumptionConcept(;
        concept = :policy_rate,
        display_name = "名目政策金利（短期）",
        definition = "中央銀行が設定する短期名目政策金利の水準または変化幅。長期金利・funding 条件とは別概念。",
        unit = "%pt (annualized)",
        basis = :rate,
        event_target_concept = :policy_rate,
    ),
    :long_rate_funding_condition => JapanFiscalAssumptionConcept(;
        concept = :long_rate_funding_condition,
        display_name = "長期金利・funding条件",
        definition = "長期名目金利（10年 JGB 等）・長期実質金利・inflation compensation・secured funding スプレッドの変化。ADR 0019 の `FundingShockComponents` と同一の観測分解を用いる。",
        unit = "bp",
        basis = :rate,
        event_target_concept = :long_rate_funding_condition,
    ),
    :government_spending => JapanFiscalAssumptionConcept(;
        concept = :government_spending,
        display_name = "政府支出",
        definition = "政府支出の水準または変化幅。モデルによって単位（水準・対 GDP 比）が異なるため、adapter で換算式を記録する。",
        unit = "level または ratio to GDP",
        basis = :level,
    ),
    :tax => JapanFiscalAssumptionConcept(;
        concept = :tax,
        display_name = "税（税率または税額）",
        definition = "税率（比例税率 θ）または定額税額 T の変化。モデルによって税の定式化が異なり、税率と税額は自動変換しない。",
        unit = "ratio（税率）または level（定額税）",
        basis = :rate,
    ),
    :primary_balance => JapanFiscalAssumptionConcept(;
        concept = :primary_balance,
        display_name = "プライマリーバランス",
        definition = "利払費を除く財政収支。**どのモデルでも直接の入力ではない**結果量であり、`(:government_spending, :tax)` へ変換して初めて入力できる。変換は一意でない。",
        unit = "ratio to GDP",
        basis = :ratio_to_gdp,
    ),
    :inflation => JapanFiscalAssumptionConcept(;
        concept = :inflation,
        display_name = "インフレ率（一般物価）",
        definition = "一般物価上昇率について置く assumption。部門別の産出価格（例: CCC の `price_s1`）とは別概念。",
        unit = "%pt (annualized)",
        basis = :rate,
    ),
    :cb_jgb_absorption => JapanFiscalAssumptionConcept(;
        concept = :cb_jgb_absorption,
        display_name = "中央銀行のJGB吸収",
        definition = "中央銀行による国債買入・保有残高の変化（イールドカーブ・コントロールを含む）。DME のどのモデルも中央銀行のバランスシートを持たない。",
        unit = "level（残高）または ratio to outstanding JGB",
        basis = :stock,
    ),
)

"""
    japan_fiscal_assumption_concept(concept::Symbol) -> JapanFiscalAssumptionConcept

assumption 概念の定義を返す。未登録の概念は `ArgumentError`。
"""
function japan_fiscal_assumption_concept(concept::Symbol)
    haskey(JAPAN_FISCAL_ASSUMPTION_CONCEPT_REGISTRY, concept) || throw(
        ArgumentError(
            "未登録の assumption concept: $(repr(concept))（登録済み: $(sort(collect(keys(JAPAN_FISCAL_ASSUMPTION_CONCEPT_REGISTRY))))）",
        ),
    )
    return JAPAN_FISCAL_ASSUMPTION_CONCEPT_REGISTRY[concept]
end

"""
    japan_fiscal_magnitude_source_allowed(source::Symbol) -> Bool

`magnitude_source`（`MACRO_EVENT_MAGNITUDE_SOURCES`）が Japan fiscal scenario assumption で
許されるか。`JAPAN_FISCAL_FORBIDDEN_MAGNITUDE_SOURCES` に含まれるものは `false`。
"""
function japan_fiscal_magnitude_source_allowed(source::Symbol)
    _jf_check(source, MACRO_EVENT_MAGNITUDE_SOURCES, "magnitude_source")
    return !(source in JAPAN_FISCAL_FORBIDDEN_MAGNITUDE_SOURCES)
end

# ===========================================================================
# JapanFiscalInputMapping
# ===========================================================================

"""
    JapanFiscalInputMapping

1 つの assumption 概念が、あるモデルでどう受け取られるか（または受け取られないか）。

`input_kind = :not_accepted` の行は「受け取れない」ことを**明示的に記録する**ための行であり、
近い変数へ寄せないことの根拠になる。

## フィールド
- `concept::Symbol` : `JAPAN_FISCAL_ASSUMPTION_CONCEPTS` のいずれか
- `variable::Symbol` : モデル側の変数・パラメータ名（受け取れない場合は `:none`）
- `input_kind::Symbol` : `JAPAN_FISCAL_INPUT_KINDS`
- `unit::String` : モデル側の単位（受け取れない場合は `""`）
- `horizon::Symbol` : `JAPAN_FISCAL_HORIZONS`
- `conversion::String` : assumption 単位 → モデル単位の換算・変換の説明（非一意なら明記）
- `notes::String` : 注意事項（受け取れない理由を含む）
"""
struct JapanFiscalInputMapping
    concept::Symbol
    variable::Symbol
    input_kind::Symbol
    unit::String
    horizon::Symbol
    conversion::String
    notes::String
end

function JapanFiscalInputMapping(;
    concept::Symbol,
    input_kind::Symbol,
    variable::Symbol = :none,
    unit::String = "",
    horizon::Symbol = :period,
    conversion::String = "",
    notes::String = "",
)
    _jf_check(concept, JAPAN_FISCAL_ASSUMPTION_CONCEPTS, "assumption concept")
    _jf_check(input_kind, JAPAN_FISCAL_INPUT_KINDS, "input_kind")
    _jf_check(horizon, JAPAN_FISCAL_HORIZONS, "horizon")
    if input_kind === :not_accepted
        variable === :none || throw(
            ArgumentError(
                "input_kind=:not_accepted の行は variable=:none でなければなりません（実値: $(repr(variable))）。受け取れない概念を変数名へ結び付けない。",
            ),
        )
        isempty(notes) && throw(
            ArgumentError(
                "input_kind=:not_accepted の行は notes（受け取れない理由）が必須です（concept=$(repr(concept))）。",
            ),
        )
    else
        variable === :none && throw(
            ArgumentError(
                "input_kind=$(repr(input_kind)) の行は variable が必須です（concept=$(repr(concept))）。",
            ),
        )
    end
    return JapanFiscalInputMapping(
        concept,
        variable,
        input_kind,
        unit,
        horizon,
        conversion,
        notes,
    )
end

# ===========================================================================
# JapanFiscalModelMapping
# ===========================================================================

"""
    JapanFiscalModelMapping

1 つの (scenario family, model) セルの capability / mapping 判定。

`accepted_concepts` は `inputs` から導出する（[`japan_fiscal_accepted_concepts`](@ref)）ため
フィールドとして重複保持しない。

## フィールド
- `family::Symbol` / `model::Symbol` : セルの座標
- `representability::Symbol` : `JAPAN_FISCAL_REPRESENTABILITY`
- `adoption::Symbol` : `JAPAN_FISCAL_ADOPTIONS`（Phase 3 / #276 での採否）
- `inputs::Vector{JapanFiscalInputMapping}` : 概念ごとの受け取り方（`:not_accepted` を含む）
- `calibration_basis::Symbol` : `JAPAN_FISCAL_CALIBRATION_BASES`
- `claim_level::Symbol` : `JAPAN_FISCAL_CLAIM_LEVELS`
- `baseline_requirements::Vector{String}` : baseline / 現状起点に必要なもの
- `endogenous_outputs::Vector{Symbol}` : 内生的に返す `JAPAN_FISCAL_OUTPUT_CONCEPTS`
- `missing_channels::Vector{String}` : 欠けている構造チャネル
- `parameterization_requirements::Vector{String}` : 必要なパラメータ化・感応度の要件
- `japan_caveats::Vector{String}` : 日本適用上の注意
- `can_state::Vector{String}` : model-implied result として言えること
- `cannot_state::Vector{String}` : 言えないこと
- `gap_ids::Vector{String}` : 関連する gap register の ID
- `reason::String` : representability 判定の理由
- `doc_ref::String` : 根拠 docs
"""
struct JapanFiscalModelMapping
    family::Symbol
    model::Symbol
    representability::Symbol
    adoption::Symbol
    inputs::Vector{JapanFiscalInputMapping}
    calibration_basis::Symbol
    claim_level::Symbol
    baseline_requirements::Vector{String}
    endogenous_outputs::Vector{Symbol}
    missing_channels::Vector{String}
    parameterization_requirements::Vector{String}
    japan_caveats::Vector{String}
    can_state::Vector{String}
    cannot_state::Vector{String}
    gap_ids::Vector{String}
    reason::String
    doc_ref::String
end

function JapanFiscalModelMapping(;
    family::Symbol,
    model::Symbol,
    representability::Symbol,
    reason::String,
    adoption::Symbol = :not_adopted,
    inputs::Vector{JapanFiscalInputMapping} = JapanFiscalInputMapping[],
    calibration_basis::Symbol = :not_applicable,
    claim_level::Symbol = :none,
    baseline_requirements::Vector{String} = String[],
    endogenous_outputs::Vector{Symbol} = Symbol[],
    missing_channels::Vector{String} = String[],
    parameterization_requirements::Vector{String} = String[],
    japan_caveats::Vector{String} = String[],
    can_state::Vector{String} = String[],
    cannot_state::Vector{String} = String[],
    gap_ids::Vector{String} = String[],
    doc_ref::String = "docs/architecture/japan_fiscal_scenario_capability.md",
)
    _jf_check(family, JAPAN_FISCAL_SCENARIO_FAMILIES, "scenario family")
    _jf_check(model, JAPAN_FISCAL_CANDIDATE_MODELS, "model")
    _jf_check(representability, JAPAN_FISCAL_REPRESENTABILITY, "representability")
    _jf_check(adoption, JAPAN_FISCAL_ADOPTIONS, "adoption")
    _jf_check(calibration_basis, JAPAN_FISCAL_CALIBRATION_BASES, "calibration_basis")
    _jf_check(claim_level, JAPAN_FISCAL_CLAIM_LEVELS, "claim_level")
    _jf_check_subset(endogenous_outputs, JAPAN_FISCAL_OUTPUT_CONCEPTS, "output concept")

    isempty(reason) && throw(
        ArgumentError(
            "JapanFiscalModelMapping.reason は必須です（family=$family, model=$model）。representability の理由を具体的に書く。",
        ),
    )

    seen = Set{Symbol}()
    for i in inputs
        i.concept in seen && throw(
            ArgumentError(
                "JapanFiscalModelMapping.inputs に重複した concept があります: $(repr(i.concept))（family=$family, model=$model）",
            ),
        )
        push!(seen, i.concept)
    end

    accepted = Symbol[i.concept for i in inputs if i.input_kind !== :not_accepted]

    # representability は family の required_concepts / required_outputs に対して機械的に決まる。
    # 3 値は相互排他かつ網羅的であり、宣言値との不一致は登録時に落とす。
    spec = japan_fiscal_family_spec(family)
    covers_concepts = issubset(Set(spec.required_concepts), Set(accepted))
    covers_outputs = issubset(Set(spec.required_outputs), Set(endogenous_outputs))
    touches_required = !isempty(intersect(Set(spec.required_concepts), Set(accepted)))
    derived = if !touches_required
        :not_representable
    elseif covers_concepts && covers_outputs
        :representable
    else
        :partial
    end
    derived === representability || throw(
        ArgumentError(
            "representability の宣言値 $(repr(representability)) が family 仕様から導かれる値 $(repr(derived)) と一致しません" *
            "（family=$family, model=$model）。required_concepts=$(spec.required_concepts)・" *
            "accepted=$(accepted)・required_outputs=$(spec.required_outputs)・endogenous_outputs=$(endogenous_outputs)",
        ),
    )

    if representability === :not_representable
        adoption === :not_adopted || throw(
            ArgumentError(
                ":not_representable のセルは adoption=:not_adopted でなければなりません（family=$family, model=$model）",
            ),
        )
        claim_level === :none || throw(
            ArgumentError(
                ":not_representable のセルは claim_level=:none でなければなりません（family=$family, model=$model）",
            ),
        )
    end

    if adoption !== :not_adopted && claim_level === :none
        throw(
            ArgumentError(
                "採用するセル（adoption=$(repr(adoption))）は claim_level=:none であってはいけません（family=$family, model=$model）",
            ),
        )
    end

    # 日本較正済みでないモデルの結果を日本の量として提示しない（#274 受け入れ条件）。
    if claim_level === :magnitude && calibration_basis !== :japan_calibrated
        throw(
            ArgumentError(
                "claim_level=:magnitude は calibration_basis=:japan_calibrated のときのみ許されます" *
                "（family=$family, model=$model, calibration_basis=$(repr(calibration_basis))）。" *
                "日本較正済みモデルは現時点で存在しない（gap G-02）。",
            ),
        )
    end

    return JapanFiscalModelMapping(
        family,
        model,
        representability,
        adoption,
        inputs,
        calibration_basis,
        claim_level,
        baseline_requirements,
        endogenous_outputs,
        missing_channels,
        parameterization_requirements,
        japan_caveats,
        can_state,
        cannot_state,
        gap_ids,
        reason,
        doc_ref,
    )
end

"""
    japan_fiscal_accepted_concepts(m::JapanFiscalModelMapping) -> Vector{Symbol}

mapping が実際に受け取る assumption 概念（`inputs` のうち `:not_accepted` でないもの）。
"""
japan_fiscal_accepted_concepts(m::JapanFiscalModelMapping) =
    Symbol[i.concept for i in m.inputs if i.input_kind !== :not_accepted]

# ===========================================================================
# JapanFiscalScenarioFamilySpec
# ===========================================================================

"""
    JapanFiscalScenarioFamilySpec

1 つの scenario family の意味・必要概念・分解規則・禁止代理。

## フィールド
- `family::Symbol` : `JAPAN_FISCAL_SCENARIO_FAMILIES`
- `display_name::String` / `economic_meaning::String`
- `required_concepts::Vector{Symbol}` : 表現に必須の assumption 概念
- `optional_concepts::Vector{Symbol}` : 任意の assumption 概念
- `required_outputs::Vector{Symbol}` : 判定に必要なモデル出力概念
- `unsupported_outputs::Vector{Symbol}` : どのモデルでも得られない出力概念
- `decomposition_rule::String` : 概念を縮約してはならない規則
- `forbidden_proxies::Vector{String}` : 禁止する代理 mapping（具体的に列挙）
- `guardrails::Vector{String}` : その他の guardrail
- `gap_ids::Vector{String}` : 関連 gap
- `doc_ref::String`
"""
struct JapanFiscalScenarioFamilySpec
    family::Symbol
    display_name::String
    economic_meaning::String
    required_concepts::Vector{Symbol}
    optional_concepts::Vector{Symbol}
    required_outputs::Vector{Symbol}
    unsupported_outputs::Vector{Symbol}
    decomposition_rule::String
    forbidden_proxies::Vector{String}
    guardrails::Vector{String}
    gap_ids::Vector{String}
    doc_ref::String
end

function JapanFiscalScenarioFamilySpec(;
    family::Symbol,
    display_name::String,
    economic_meaning::String,
    required_concepts::Vector{Symbol},
    decomposition_rule::String,
    optional_concepts::Vector{Symbol} = Symbol[],
    required_outputs::Vector{Symbol} = Symbol[],
    unsupported_outputs::Vector{Symbol} = Symbol[],
    forbidden_proxies::Vector{String} = String[],
    guardrails::Vector{String} = String[],
    gap_ids::Vector{String} = String[],
    doc_ref::String = "docs/architecture/japan_fiscal_scenario_capability.md",
)
    _jf_check(family, JAPAN_FISCAL_SCENARIO_FAMILIES, "scenario family")
    _jf_check_subset(
        required_concepts,
        JAPAN_FISCAL_ASSUMPTION_CONCEPTS,
        "required concept",
    )
    _jf_check_subset(
        optional_concepts,
        JAPAN_FISCAL_ASSUMPTION_CONCEPTS,
        "optional concept",
    )
    _jf_check_subset(required_outputs, JAPAN_FISCAL_OUTPUT_CONCEPTS, "required output")
    _jf_check_subset(
        unsupported_outputs,
        JAPAN_FISCAL_OUTPUT_CONCEPTS,
        "unsupported output",
    )
    isempty(required_concepts) && throw(
        ArgumentError(
            "JapanFiscalScenarioFamilySpec.required_concepts は空にできません（family=$family）",
        ),
    )
    overlap = intersect(Set(required_concepts), Set(optional_concepts))
    isempty(overlap) || throw(
        ArgumentError(
            "required_concepts と optional_concepts が重複しています: $(sort(collect(overlap)))（family=$family）",
        ),
    )
    isempty(forbidden_proxies) && throw(
        ArgumentError(
            "JapanFiscalScenarioFamilySpec.forbidden_proxies は空にできません（family=$family）。" *
            "表現不能な概念を近いショックへ寄せないことを具体的に列挙する。",
        ),
    )
    return JapanFiscalScenarioFamilySpec(
        family,
        display_name,
        economic_meaning,
        required_concepts,
        optional_concepts,
        required_outputs,
        unsupported_outputs,
        decomposition_rule,
        forbidden_proxies,
        guardrails,
        gap_ids,
        doc_ref,
    )
end

# ===========================================================================
# JapanFiscalGap（unsupported / gap register）
# ===========================================================================

"""
    JapanFiscalGap

Phase 3 で解消せず限界として保持する構造的ギャップ 1 件。

## フィールド
- `gap_id::String` : `"G-01"` 形式の安定 ID
- `title::String` / `description::String`
- `affected_families::Vector{Symbol}` / `affected_models::Vector{Symbol}`
- `consequence::String` : このギャップにより言えなくなること
- `resolution::Symbol` : `JAPAN_FISCAL_GAP_RESOLUTIONS`
- `doc_ref::String`
"""
struct JapanFiscalGap
    gap_id::String
    title::String
    description::String
    affected_families::Vector{Symbol}
    affected_models::Vector{Symbol}
    consequence::String
    resolution::Symbol
    doc_ref::String
end

function JapanFiscalGap(;
    gap_id::String,
    title::String,
    description::String,
    consequence::String,
    resolution::Symbol,
    affected_families::Vector{Symbol} = collect(JAPAN_FISCAL_SCENARIO_FAMILIES),
    affected_models::Vector{Symbol} = collect(JAPAN_FISCAL_CANDIDATE_MODELS),
    doc_ref::String = "docs/architecture/japan_fiscal_scenario_capability.md",
)
    occursin(r"^G-\d{2}$", gap_id) ||
        throw(ArgumentError("gap_id は \"G-01\" 形式でなければなりません（実値: $gap_id）"))
    _jf_check_subset(affected_families, JAPAN_FISCAL_SCENARIO_FAMILIES, "affected family")
    _jf_check_subset(affected_models, JAPAN_FISCAL_CANDIDATE_MODELS, "affected model")
    _jf_check(resolution, JAPAN_FISCAL_GAP_RESOLUTIONS, "resolution")
    return JapanFiscalGap(
        gap_id,
        title,
        description,
        affected_families,
        affected_models,
        consequence,
        resolution,
        doc_ref,
    )
end

# ===========================================================================
# gap register（G-01 〜 G-15）
# ===========================================================================

"""
    JAPAN_FISCAL_GAP_REGISTER

Phase 3 で解消せず限界として保持する構造的ギャップ 15 件。`#276` の adapter 実装は
これらを「後から埋める前提」で設計してはならない（埋める場合は新規モデルの追加であり、
#273 の non-goal に当たる）。
"""
const JAPAN_FISCAL_GAP_REGISTER = JapanFiscalGap[
    JapanFiscalGap(;
        gap_id = "G-01",
        title = "利付き政府債務ストックを持つモデルが存在しない",
        description = "DME のどのモデルも、利子を生む政府債務ストックを状態変数として持たない。SIM の `H` は無利子の政府貨幣（high-powered money）であり国債ではない。Keen の `d`・CCC の部門別債務はいずれも民間債務である。",
        consequence = "債務残高/GDP・利払費・`r − g` 債務動学・債務持続可能性のいずれも、どの scenario family でも出力できない。財政シナリオの結果を『債務が持続可能か』へ読み替えてはならない。",
        resolution = :hold_as_limitation,
    ),
    JapanFiscalGap(;
        gap_id = "G-02",
        title = "日本較正済みのモデルが存在しない",
        description = "DME の実証較正・推定は Keen（米国）と CCC（米国 NIPA・AI/半導体 CAPEX）のみである。e-Stat クライアントはデータ層に存在するが、日本データでモデルを較正する経路は実装されていない。イベント層の `geography` 既定値も `\"US\"` である。",
        consequence = "Phase 3 のすべての結果は mechanism / illustrative であり、日本の量として提示できない（`claim_level = :magnitude` を名乗れる mapping は存在しない）。",
        resolution = :followup_issue,
    ),
    JapanFiscalGap(;
        gap_id = "G-03",
        title = "GDP 成長率パスを外生入力として受け取るモデルが存在しない",
        description = "産出はすべてのモデルで内生変数である。成長 assumption は必ず構造ドライバー（Solow の `g`・`n`、RBC の TFP、Keen の `α`、CCC のモデル外需要パス、需要ショック）へ変換しなければならず、その変換は一意でない。",
        consequence = "`:growth_path` を直接受け取れる mapping は 1 つも無い。低成長・高成長シナリオは構造ドライバーの選択に依存し、選択自体が assumption として記録される必要がある。",
        affected_families = [:low_growth_high_rates, :high_growth_productivity],
        resolution = :hold_as_limitation,
    ),
    JapanFiscalGap(;
        gap_id = "G-04",
        title = "中央銀行のバランスシート・JGB 吸収を持つモデルが存在しない",
        description = "IS-LM・AD-AS・Mundell-Fleming は名目マネーサプライ `M` を外生に持つが、これは中央銀行の資産構成（国債保有残高）ではない。New Keynesian は Taylor rule のみで balance sheet を持たない。",
        consequence = "`:cb_jgb_absorption` はすべてのモデルで受け取れない。金融抑圧シナリオはこの概念を unsupported として返さなければならず、政策金利の追加的引き下げへ振り替えてはならない。",
        affected_families = [:financial_repression, :jgb_funding_cost],
        resolution = :hold_as_limitation,
    ),
    JapanFiscalGap(;
        gap_id = "G-05",
        title = "インフレを政策金利と独立な assumption として受け取れるのは New Keynesian のみ",
        description = "AD-AS は物価水準 `P` を内生化するが、その変化はマネーサプライ `M` 等の単一入力の同時結果であり、インフレと名目金利を独立に置けない。New Keynesian はインフレ目標 `π_star` をパラメータとして持ち、金融政策ショックと分離できる。",
        consequence = "金融抑圧の 2 概念（低い名目金利・高いインフレ）を分離して受け取れるのは New Keynesian だけである。AD-AS で両者を同時に動かすと、契約が禁じる『単一 rate shock への縮約』と同じ誤りになる。",
        affected_families = [:financial_repression],
        affected_models = [:islm, :adas, :mundell_fleming, :sim, :capex_credit_cycle],
        resolution = :hold_as_limitation,
    ),
    JapanFiscalGap(;
        gap_id = "G-06",
        title = "期間構造（短期金利と長期金利の同時保持）を持つモデルが存在しない",
        description = "IS-LM・AD-AS・Mundell-Fleming・New Keynesian はいずれも金利を 1 本しか持たない。CCC は `policy_rate`（短期）と `spread_shock_ex`（加算的な上乗せ、bp）の 2 スロットを持つが、これは期間構造ではなく『短期金利＋加算スプレッド』である（ADR 0019）。",
        consequence = "長期金利と政策金利を別入力として保持できるのは CCC のみであり、かつ長期金利は期間構造ではなくスプレッドとして表現される。イールドカーブの形状変化そのものは表現できない。",
        affected_families = [:low_growth_high_rates, :jgb_funding_cost],
        resolution = :hold_as_limitation,
    ),
    JapanFiscalGap(;
        gap_id = "G-07",
        title = "プライマリーバランスを直接の入力として受け取るモデルが存在しない",
        description = "SIM では `T = θ·Y` と `G` から、IS-LM / AD-AS / Mundell-Fleming では `T` と `G` から、PB は結果として決まる。PB を目標値として与えるには `(G, T)` の組を逆算する必要があり、同じ PB を与える組は無数に存在する。",
        consequence = "`:primary_balance` assumption は `(:government_spending, :tax)` へ変換したうえで、変換規則と非一意性を artifact に記録しなければならない。PB だけを指定したシナリオは `:partial` 以下になる。",
        affected_families = [:fiscal_consolidation],
        resolution = :hold_as_limitation,
    ),
    JapanFiscalGap(;
        gap_id = "G-08",
        title = "開放経済かつ財政を持つモデルは Mundell-Fleming のみで、その構造が財政乗数をゼロにする",
        description = "Mundell-Fleming は変動相場・完全資本移動・小国（`r = r*`）を前提とし、この構造の帰結として政府支出の増加は為替増価と純輸出減少で完全に相殺される。`r_star` は世界利子率であって日本の長期金利ではない。",
        consequence = "『財政政策が無効』という結果はモデル構造の仮定であり、日本についての実証的発見ではない。日本の国債が国内で消化され中央銀行が大量保有する状況と、小国・完全資本移動の仮定は整合しない。",
        affected_families = [:fiscal_consolidation, :jgb_funding_cost],
        affected_models = [:mundell_fleming],
        resolution = :hold_as_limitation,
    ),
    JapanFiscalGap(;
        gap_id = "G-09",
        title = "Keen の貸出金利 `r` は時間変化しないスカラーパラメータ",
        description = "`KeenModel.r` は実質貸出金利を表す定数パラメータであり、期別の金利パスを与えられない。金利変更は `r` の異なる 2 つのモデルインスタンスを比較する形（永続的なステップ変化）でしか表現できない。",
        consequence = "Keen では金利の時間形状（ramp・AR(1) 減衰等）を表現できない。`:long_rate_funding_condition` の `PersistenceSpec` は Keen へ渡せない。",
        affected_families = [
            :low_growth_high_rates,
            :financial_repression,
            :jgb_funding_cost,
        ],
        affected_models = [:keen],
        resolution = :hold_as_limitation,
    ),
    JapanFiscalGap(;
        gap_id = "G-10",
        title = "VAR は係数手入力・ラグ 1 のみで、推定機能を持たない",
        description = "`VARModel` は係数行列 `A` と定数項 `c` を手入力する簡易 VAR(1) であり、実データからの推定は未対応。日本データから推定した係数を DME が生成する経路は無い。",
        consequence = "VAR はどの family についても『外部で推定した係数を与えれば原理的には表現できる』に留まり、係数の供給元が無いため Phase 3 では採用しない。",
        affected_models = [:var],
        resolution = :out_of_scope,
    ),
    JapanFiscalGap(;
        gap_id = "G-11",
        title = "CCC の `price_s1` は S1 部門の産出価格であり一般物価ではない",
        description = "`price_s1` は期内処理順序ステップ 5 で確定する S1 の先決価格であり、消費者物価・GDP デフレーターのような一般物価水準ではない。",
        consequence = "`:inflation` assumption を `price_s1` へ写像してはならない。CCC は金融抑圧の『インフレ』概念を受け取れない。",
        affected_families = [:financial_repression],
        affected_models = [:capex_credit_cycle],
        resolution = :hold_as_limitation,
    ),
    JapanFiscalGap(;
        gap_id = "G-12",
        title = "CCC の `ext_demand_s2` / `ext_demand_s3` はモデル外需要であり GDP 成長パスではない",
        description = "`ext_demand_s` は本モデルの外側にある半導体・装置需要（10億ドル/四半期）であり、S2・S3 の受注を生成する残差構成の外生系列である（実証化契約 §観測方程式）。海外需要に限定されず、集計 GDP の成長率でもない。CCC の baseline は成長率ゼロの定常状態と定義されている（ADR 0011）。",
        consequence = "`:growth_path` を `ext_demand_s` へ写像してはならない。CCC は成長regimeそのものを表現できない。",
        affected_families = [
            :low_growth_high_rates,
            :high_growth_productivity,
            :fiscal_consolidation,
        ],
        affected_models = [:capex_credit_cycle],
        resolution = :hold_as_limitation,
    ),
    JapanFiscalGap(;
        gap_id = "G-13",
        title = "Solow の貯蓄率 `s` は民間貯蓄率であり財政再建の代理ではない",
        description = "`s` は産出のうち投資へ回る割合を表す行動パラメータであり、政府部門を持たない Solow モデルに公的貯蓄・財政収支の概念は無い。",
        consequence = "財政緊縮を `s` の上昇として表現してはならない。Solow は財政シナリオを表現できない。",
        affected_families = [:fiscal_consolidation],
        affected_models = [:solow, :ramsey, :rbc],
        resolution = :hold_as_limitation,
    ),
    JapanFiscalGap(;
        gap_id = "G-14",
        title = "`:LongRateFundingShock` → `spread_shock_ex` は企業の実効借入コストへの写像であり、政府の調達コストではない",
        description = "ADR 0019 が定めた写像は CCC の企業借入コスト `r_new_s` へ加算されるものであり、政府の国債発行コストを表さない。イベント型と `FundingShockComponents`（生データ分解）自体はモデル非依存であり日本へ再利用できるが、この写像規則は再利用できない。",
        consequence = "JGB funding-cost シナリオは sovereign leg（政府の調達コスト・利払費）と private pass-through leg（民間の実効借入コスト）に分け、sovereign leg はどのモデルでも表現できないと明示しなければならない。",
        affected_families = [:jgb_funding_cost],
        resolution = :hold_as_limitation,
    ),
    JapanFiscalGap(;
        gap_id = "G-15",
        title = "financial-stress 観測系列（#260 Part B）は米国系列のみ",
        description = "`src/data/financial_stress_catalog.jl` が保持するのは CCC OAS・広範 HY OAS・SOFR・TGCR・IORB・10年米国債名目/実質/breakeven の 8 系列であり、いずれも米国系列である。日本の対応系列（10年 JGB 利回り・TONA / GC レポ・日銀政策金利・JGB breakeven）は未実装。",
        consequence = "JGB funding-cost シナリオの `FundingShockComponents` は、Phase 3 では観測から自動構成できず、明示的な Scenario Assumption として与えるしかない。",
        affected_families = [:jgb_funding_cost],
        resolution = :followup_issue,
    ),
]

"""
    japan_fiscal_gaps(; family=nothing, model=nothing) -> Vector{JapanFiscalGap}

gap register を返す。`family` / `model` を与えると該当するものだけに絞る。
"""
function japan_fiscal_gaps(;
    family::Union{Symbol, Nothing} = nothing,
    model::Union{Symbol, Nothing} = nothing,
)
    family === nothing ||
        _jf_check(family, JAPAN_FISCAL_SCENARIO_FAMILIES, "scenario family")
    model === nothing || _jf_check(model, JAPAN_FISCAL_CANDIDATE_MODELS, "model")
    out = JapanFiscalGap[]
    for g in JAPAN_FISCAL_GAP_REGISTER
        family === nothing || family in g.affected_families || continue
        model === nothing || model in g.affected_models || continue
        push!(out, g)
    end
    return out
end

"""
    japan_fiscal_gap(gap_id::AbstractString) -> JapanFiscalGap

ID で gap を引く。未登録の ID は `ArgumentError`。
"""
function japan_fiscal_gap(gap_id::AbstractString)
    idx = findfirst(g -> g.gap_id == gap_id, JAPAN_FISCAL_GAP_REGISTER)
    idx === nothing && throw(
        ArgumentError(
            "未登録の gap_id: $gap_id（登録済み: $([g.gap_id for g in JAPAN_FISCAL_GAP_REGISTER])）",
        ),
    )
    return JAPAN_FISCAL_GAP_REGISTER[idx]
end

# ===========================================================================
# scenario family registry（5 family）
# ===========================================================================

"""
    JAPAN_FISCAL_FAMILY_REGISTRY

5 つの scenario family の意味・必要概念・分解規則・禁止代理。
"""
const JAPAN_FISCAL_FAMILY_REGISTRY = Dict{Symbol, JapanFiscalScenarioFamilySpec}(
    :low_growth_high_rates => JapanFiscalScenarioFamilySpec(;
        family = :low_growth_high_rates,
        display_name = "低成長 + 高金利",
        economic_meaning = "実質成長率が低いまま、短期政策金利と長期金利の双方が上昇する局面。財政側では成長と金利の双方が債務動学を悪化させる方向へ働く。",
        required_concepts = [:growth_path, :policy_rate, :long_rate_funding_condition],
        optional_concepts = [:inflation, :productivity_growth],
        required_outputs = [:output, :private_borrowing_cost],
        unsupported_outputs = [:government_debt_stock, :government_balance],
        decomposition_rule = "政策金利・長期金利・成長を 1 つの入力へ縮約しない。3 概念は別々の Scenario Assumption として保持し、モデルが受け取れない概念は近い入力へ寄せずに unsupported として返す。",
        forbidden_proxies = [
            "IS-LM / AD-AS のマネーサプライ `M` の減少を『高金利 assumption』として用いない。金利と産出が同一入力の同時結果になり、政策金利と成長を独立に置くという family の要件を満たさない。",
            "CCC の `ext_demand_s2` / `ext_demand_s3`（モデル外需要）を GDP 成長率パスの代理に用いない（G-12）。",
            "Mundell-Fleming の `r_star`（世界利子率）を日本の長期金利の代理に用いない（G-08）。",
            "New Keynesian の産出ギャップ `x` の低下を『低成長』として提示しない。ギャップは潜在産出からの乖離であり成長率ではない。",
        ],
        guardrails = [
            "`:growth_path`（GDP 成長率）と `:productivity_growth`（生産性成長率）を同一視しない（G-03）。",
            "どのモデルも政府債務残高・利払費を出力しないため、結果を債務持続可能性の判断へ読み替えない（G-01）。",
        ],
        gap_ids = ["G-01", "G-02", "G-03", "G-06", "G-12"],
    ),
    :fiscal_consolidation => JapanFiscalScenarioFamilySpec(;
        family = :fiscal_consolidation,
        display_name = "財政再建（歳出削減・増税）",
        economic_meaning = "政府支出の削減または増税によりプライマリーバランスを改善させる局面。短期の需要収縮と、政府純資産・家計純資産の変化を同時に扱う必要がある。",
        required_concepts = [:government_spending, :tax],
        optional_concepts = [:primary_balance, :growth_path, :policy_rate, :inflation],
        required_outputs = [:output, :government_balance],
        unsupported_outputs = [:government_debt_stock],
        decomposition_rule = "プライマリーバランス assumption はどのモデルでも直接の入力ではない。`:primary_balance` は `(:government_spending, :tax)` へ変換したうえで、変換式と『同じ PB を与える組が無数にある』ことを記録する（G-07）。",
        forbidden_proxies = [
            "Solow の貯蓄率 `s` を財政再建の代理に用いない。`s` は民間貯蓄率であり公的貯蓄ではない（G-13）。",
            "New Keynesian の `:demand` ショックを財政緊縮の代理に用いない。需要ショックは税・支出・債務のいずれの意味も持たず、財政乗数として解釈できない。",
            "CCC のモデル外需要の低下を財政緊縮の代理に用いない（G-12）。",
            "Keen の投資関数パラメータ `κ0` の引き下げを財政緊縮の代理に用いない。民間投資行動の変化であり政府部門ではない。",
        ],
        guardrails = [
            "利払費の変化を通じた債務動学はどのモデルにも無い（G-01）。",
            "SIM の `H` は無利子の政府貨幣であり利付き国債ではない。SIM の『政府債務』を国債残高として提示しない（G-01）。",
            "税率（比例税 θ）と定額税額 `T` は異なる定式化であり、自動変換しない。",
        ],
        gap_ids = ["G-01", "G-02", "G-07", "G-08", "G-13"],
    ),
    :financial_repression => JapanFiscalScenarioFamilySpec(;
        family = :financial_repression,
        display_name = "金融抑圧",
        economic_meaning = "名目政策金利を低位に据え置いたままインフレを上昇させ、実質金利を負にすることで、中央銀行の国債吸収とあわせて政府債務の実質価値を圧縮する局面。",
        required_concepts = [:policy_rate, :inflation, :cb_jgb_absorption],
        optional_concepts = [:long_rate_funding_condition, :growth_path],
        required_outputs = [:nominal_rate, :inflation, :real_rate],
        unsupported_outputs = [:government_debt_stock, :government_balance, :money_stock],
        decomposition_rule = "金融抑圧を単一の政策金利ショックへ縮約しない。名目政策金利・インフレ・中央銀行の JGB 吸収を独立な 3 つの Scenario Assumption として保持し、受け取れない概念（`:cb_jgb_absorption` はすべてのモデルで受け取れない）を unsupported として返す。",
        forbidden_proxies = [
            "AD-AS のマネーサプライ `M` 増加を『政策金利低位維持 + インフレ上昇』の合成入力として用いない。2 概念が単一入力の同時結果になり、分解規則に反する（G-05）。",
            "CCC の `price_s1`（S1 部門の産出価格）を一般物価・インフレの代理に用いない（G-11）。",
            "中央銀行の JGB 吸収を政策金利の追加的な引き下げへ振り替えない（G-04）。",
            "Keen の実質貸出金利 `r` の低下を『政策金利の低位維持』として提示しない。`r` は民間の実質借入金利であり政策金利ではない。",
        ],
        guardrails = [
            "実質金利は `i − E[π]` としてモデル出力から導出できるが、政府債務への負担軽減額は算出できない（G-01）。",
            "`:cb_jgb_absorption` はどの mapping も受け取らない。未対応であることを結果に明示する（G-04）。",
        ],
        gap_ids = ["G-01", "G-02", "G-04", "G-05", "G-11"],
    ),
    :high_growth_productivity => JapanFiscalScenarioFamilySpec(;
        family = :high_growth_productivity,
        display_name = "高成長 / 生産性ショック",
        economic_meaning = "労働生産性・TFP の改善により潜在産出と成長率が高まる局面。財政側では分母（GDP）の拡大を通じて債務比率が改善する経路が想定される。",
        required_concepts = [:productivity_growth],
        optional_concepts = [:growth_path, :policy_rate, :inflation],
        required_outputs = [:output, :capital_stock],
        unsupported_outputs = [:government_debt_stock, :government_balance],
        decomposition_rule = "生産性ショックと GDP 成長パス assumption を区別する。`:growth_path` を直接受け取るモデルは存在しないため、成長仮定は必ず構造ドライバー（Solow の `g`・RBC の TFP・Keen の `α`）へ変換し、変換の非一意性を記録する（G-03）。",
        forbidden_proxies = [
            "New Keynesian の `:demand` ショックを生産性向上の代理に用いない。産出ギャップの一時的拡大であり潜在産出の上昇ではない。",
            "SIM の賃金率 `W` を労働生産性の代理に用いない。`W` は数値基準であり `N = Y/W` は会計上の恒等式にすぎない。",
            "CCC の `ai_exp` を日本の生産性成長の代理に用いない。米国 AI 設備投資期待を表す外生入力である（G-02・G-12）。",
            "Ramsey の資本分配率 `α` の変更を生産性ショックの代理に用いない。生産関数の形状パラメータであり技術水準ではない。",
        ],
        guardrails = [
            "Solow の `g`・Keen の `α` は成長『率』、AD-AS の `Y_n` は潜在産出『水準』であり相互に変換できない。",
            "RBC の TFP ショックは持続性 `ρ < 1` で平均回帰するため、持続的な成長regimeの変化を表現しない。",
        ],
        gap_ids = ["G-01", "G-02", "G-03", "G-12"],
    ),
    :jgb_funding_cost => JapanFiscalScenarioFamilySpec(;
        family = :jgb_funding_cost,
        display_name = "JGB funding-cost ショック",
        economic_meaning = "政策金利の変更を伴わない、または政策金利だけでは説明できない長期 JGB 利回りの上昇と、それが政府の調達コストおよび民間の実効借入コストへ及ぼす影響。",
        required_concepts = [:long_rate_funding_condition],
        optional_concepts = [:policy_rate, :inflation],
        required_outputs = [:private_borrowing_cost, :government_balance],
        unsupported_outputs = [:government_debt_stock],
        decomposition_rule = "JGB funding-cost ショックを sovereign leg（政府の調達コスト・利払費）と private pass-through leg（民間の実効借入コスト）に分け、sovereign leg はどのモデルでも表現できないことを結果に明示する（G-01・G-14）。",
        forbidden_proxies = [
            "`:LongRateFundingShock` → `spread_shock_ex` の写像を sovereign leg に用いない。企業の実効借入コストへの写像であり政府の調達コストではない（G-14）。",
            "Mundell-Fleming の `r_star` を JGB 利回りの代理に用いない。世界利子率であり日本の長期金利ではない（G-08）。",
            "New Keynesian の `:monetary` ショックを長期金利ショックの代理に用いない。期間構造を持たず、政策金利と長期金利を区別できない（G-06）。",
            "IS-LM / AD-AS の `r` を JGB 利回りとして解釈しない。単一の内生金利であり、政策金利とも長期金利とも同定されない。",
        ],
        guardrails = [
            "ADR 0019 の `FundingShockComponents`（生データ分解）と `FundingShockPassThrough`（pass-through 係数）はモデル非依存であり日本へ再利用できる。再利用できないのは CCC 側の写像規則・米国観測系列・米国較正である（G-14・G-15・G-02）。",
            "pass-through 係数の既定値 1.0 は米国についても較正されていない。日本へ適用する場合は感応度の併記を必須とする。",
            "`decomposition_residual_bps` を term premium と呼ばない（ADR 0019 決定 4）。",
        ],
        gap_ids = ["G-01", "G-02", "G-06", "G-08", "G-14", "G-15"],
    ),
)

"""
    japan_fiscal_scenario_families() -> Vector{Symbol}

Phase 3 の scenario family 一覧（宣言順）。
"""
japan_fiscal_scenario_families() = collect(JAPAN_FISCAL_SCENARIO_FAMILIES)

"""
    japan_fiscal_family_spec(family::Symbol) -> JapanFiscalScenarioFamilySpec

family の仕様を返す。未登録は `ArgumentError`。
"""
function japan_fiscal_family_spec(family::Symbol)
    haskey(JAPAN_FISCAL_FAMILY_REGISTRY, family) || throw(
        ArgumentError(
            "未登録の scenario family: $(repr(family))（登録済み: $(sort(collect(keys(JAPAN_FISCAL_FAMILY_REGISTRY))))）",
        ),
    )
    return JAPAN_FISCAL_FAMILY_REGISTRY[family]
end

# ===========================================================================
# capability matrix（5 family × 11 model = 55 セル）
# ===========================================================================

# VAR に共通の判定理由（全 family で同一）。
const _JF_VAR_REASON =
    "`VARModel` は係数手入力・ラグ 1 の簡易 VAR であり、どのショックがどの経済概念に対応するかを" *
    "与える構造識別の機構を持たない。任意の変数集合を置けるため形式的には何でも表現できるように" *
    "見えるが、係数の供給元も識別の根拠も DME に無い（G-10）。能力 metadata の原則（推測で" *
    "過大申告しない）に従い、全 family で `:not_representable` と判定する。"

"""
    JAPAN_FISCAL_MODEL_MAPPINGS

5 scenario family × 11 候補モデルの capability / mapping 判定（55 セル）。
`JAPAN_FISCAL_SCENARIO_FAMILIES` × `JAPAN_FISCAL_CANDIDATE_MODELS` の全組み合わせを
過不足なく含む（登録時の健全性検査で強制する）。
"""
const JAPAN_FISCAL_MODEL_MAPPINGS = JapanFiscalModelMapping[

    # -----------------------------------------------------------------
    # F1: 低成長 + 高金利
    # -----------------------------------------------------------------
    JapanFiscalModelMapping(;
        family = :low_growth_high_rates,
        model = :ramsey,
        representability = :not_representable,
        reason = "政策金利・長期金利・成長率のいずれも入力として持たない。定常状態の実質利子率は `r* = 1/β + δ − 1` として選好と技術から内生的に決まる政策外の量であり、`β` を動かして金利を作ることは選好パラメータを政策金利と読み替えることになる。",
        inputs = [
            JapanFiscalInputMapping(;
                concept = :policy_rate,
                input_kind = :not_accepted,
                notes = "`β`（割引因子）は家計の時間選好であり中央銀行の政策変数ではない。金利を動かす目的で `β` を変更しない。",
            ),
        ],
        missing_channels = ["名目変数・貨幣・中央銀行", "政府部門", "成長率の外生指定"],
        gap_ids = ["G-03", "G-06"],
    ),
    JapanFiscalModelMapping(;
        family = :low_growth_high_rates,
        model = :rbc,
        representability = :not_representable,
        reason = "名目変数・政策金利を持たない実物モデル。TFP ショックは `:productivity_growth`（高成長 family）の概念であり `:growth_path` ではない（G-03）。定常状態の実質利子率 `1/β + δ − 1` は TFP と独立であり、成長と金利を別入力として同時に動かせない。",
        missing_channels = ["名目変数・貨幣・中央銀行", "政府部門", "期間構造"],
        gap_ids = ["G-03", "G-06"],
    ),
    JapanFiscalModelMapping(;
        family = :low_growth_high_rates,
        model = :solow,
        representability = :not_representable,
        reason = "金利を持たない。`g`・`n` は技術進歩率・人口成長率であり、集計 GDP 成長率の assumption（`:growth_path`）と同一視しない（G-03）。",
        missing_channels = ["金利・金融市場", "政府部門"],
        gap_ids = ["G-03", "G-06"],
    ),
    JapanFiscalModelMapping(;
        family = :low_growth_high_rates,
        model = :islm,
        representability = :not_representable,
        reason = "政策金利を入力として持たない。`r` は `M/P` と財市場から内生的に決まり、目標金利を与えるには `M` を逆算する必要があるが、その `M` は同時に産出も動かす。したがって金利と成長を独立な assumption として置けない。静学モデルであり成長率の概念も持たない。",
        inputs = [
            JapanFiscalInputMapping(;
                concept = :policy_rate,
                input_kind = :not_accepted,
                notes = "`M` の変更を『高金利 assumption』として用いない。金利と産出が同一入力の同時結果になり、family の分解規則に反する。",
            ),
        ],
        missing_channels = ["期間構造", "動学（静学 1 点解）", "政府債務ストック"],
        gap_ids = ["G-03", "G-06"],
    ),
    JapanFiscalModelMapping(;
        family = :low_growth_high_rates,
        model = :adas,
        representability = :not_representable,
        reason = "IS-LM と同じ理由で政策金利を独立な入力として持たない（`r` は内生）。物価 `P` は内生化されるが、これも `M` 等の単一入力の同時結果である。静学モデルであり成長率を持たない。",
        inputs = [
            JapanFiscalInputMapping(;
                concept = :policy_rate,
                input_kind = :not_accepted,
                notes = "`M` の変更は金利・産出・物価を同時に動かす。単一入力を複数 assumption の代理にしない。",
            ),
        ],
        missing_channels = ["期間構造", "動学（静学 1 点解）", "政府債務ストック"],
        gap_ids = ["G-03", "G-06"],
    ),
    JapanFiscalModelMapping(;
        family = :low_growth_high_rates,
        model = :new_keynesian,
        representability = :partial,
        adoption = :supporting,
        calibration_basis = :structural_illustrative,
        claim_level = :direction_and_relative_timing,
        reason = "名目政策金利を `:monetary` ショック（Taylor rule への AR(1) ショック）として独立に受け取れるが、期間構造を持たないため長期金利を別入力にできず（G-06）、産出は潜在からの乖離（ギャップ）であって成長率ではない（G-03）。3 required concept のうち 1 つのみを受け取る。",
        inputs = [
            JapanFiscalInputMapping(;
                concept = :policy_rate,
                variable = :i,
                input_kind = :shock_process,
                unit = "%pt (deviation from steady state)",
                horizon = :quarterly,
                conversion = "政策金利の変化幅（%pt）を `impulse_response(m, shock_size; shock=:monetary)` の `shock_size` へ渡す。持続性は `ρ_m` で与え、`PersistenceSpec` の時間形状から `ρ_m` への変換規則を明示する。",
                notes = "出力はすべて定常状態からの乖離である。水準として提示しない。",
            ),
            JapanFiscalInputMapping(;
                concept = :inflation,
                variable = :π_star,
                input_kind = :model_parameter,
                unit = "%pt (annualized)",
                horizon = :quarterly,
                conversion = "インフレ目標の変更としてのみ受け取る。実現インフレ `π` は内生であり直接指定できない。",
            ),
            JapanFiscalInputMapping(;
                concept = :long_rate_funding_condition,
                input_kind = :not_accepted,
                notes = "期間構造を持たない。`:monetary` ショックを長期金利ショックの代理に用いない（G-06）。",
            ),
            JapanFiscalInputMapping(;
                concept = :growth_path,
                input_kind = :not_accepted,
                notes = "産出ギャップ `x` は潜在産出からの乖離であり成長率ではない。ギャップの低下を『低成長』として提示しない（G-03）。",
            ),
        ],
        baseline_requirements = [
            "baseline は全ショックゼロの定常状態（`x=0`・`π=π_star`・`i=r_n+π_star`）。日本の観測水準へ合わせる較正は行わない。",
            "baseline と scenario で `σ`・`β`・`κ`・`φ_π`・`φ_x`・`π_star`・ホライズンを一致させる。",
        ],
        endogenous_outputs = [:output_gap, :inflation, :nominal_rate, :real_rate],
        missing_channels = [
            "財政・政府債務",
            "期間構造・長期金利",
            "成長トレンド",
            "名目金利ゼロ下限・非伝統的政策",
        ],
        parameterization_requirements = [
            "`ρ_m` がショックの時間形状を決めるため、`PersistenceSpec` の shape から `ρ_m` への変換規則と、その値に対する感応度の併記が必要。",
            "`φ_π > 1`（Taylor principle）を満たさないパラメータでは MSV 解が発散しうるため、パラメータ許容域の検査が必要。",
        ],
        japan_caveats = [
            "パラメータは教科書値であり日本の推定値ではない（G-02）。",
            "日本の名目金利ゼロ下限・イールドカーブ・コントロールを表現しない。",
        ],
        can_state = [
            "予期せぬ利上げ（正の金融政策ショック）に対する産出ギャップ・インフレ・名目金利の方向と相対的な時間形状。",
            "`nk_expected_inflation_path` による事前的実質金利 `i − E[π]` の経路（real-rate model artifact と同じ機構）。",
        ],
        cannot_state = [
            "低成長そのもの。モデルは潜在産出からの乖離しか持たない（G-03）。",
            "長期金利・イールドカーブの動き（G-06）。",
            "財政・政府債務への影響（G-01）。",
            "日本の産出・インフレの変化幅（G-02）。",
        ],
        gap_ids = ["G-01", "G-02", "G-03", "G-06"],
    ),
    JapanFiscalModelMapping(;
        family = :low_growth_high_rates,
        model = :var,
        representability = :not_representable,
        reason = _JF_VAR_REASON,
        gap_ids = ["G-10"],
    ),
    JapanFiscalModelMapping(;
        family = :low_growth_high_rates,
        model = :mundell_fleming,
        representability = :not_representable,
        reason = "UIP 条件 `r = r*` により国内金利は世界利子率に固定され、政策金利・長期金利のいずれも独立な assumption として置けない。`r_star` を日本の政策金利・長期金利の代理にすることは禁止代理である（G-08）。成長率の概念も持たない。",
        inputs = [
            JapanFiscalInputMapping(;
                concept = :long_rate_funding_condition,
                input_kind = :not_accepted,
                notes = "`r_star` は世界利子率であり、日本の長期金利・JGB 利回りではない（G-08）。",
            ),
            JapanFiscalInputMapping(;
                concept = :policy_rate,
                input_kind = :not_accepted,
                notes = "完全資本移動の仮定により国内政策金利を世界利子率と独立に設定できない。",
            ),
        ],
        missing_channels = ["国内金利の独立性", "期間構造", "成長"],
        gap_ids = ["G-03", "G-06", "G-08"],
    ),
    JapanFiscalModelMapping(;
        family = :low_growth_high_rates,
        model = :keen,
        representability = :partial,
        adoption = :supporting,
        calibration_basis = :structural_illustrative,
        claim_level = :direction_only,
        reason = "実質貸出金利 `r` を通じて funding コストの恒久的な上昇を受け取れるが、中央銀行・政策金利を持たず（`r` は民間の貸出金利）、成長率の assumption も受け取らない。3 required concept のうち 1 つのみを受け取る。",
        inputs = [
            JapanFiscalInputMapping(;
                concept = :long_rate_funding_condition,
                variable = :r,
                input_kind = :model_parameter,
                unit = "annualized real rate (decimal)",
                horizon = :continuous_year,
                conversion = "bp を年率実質金利へ換算する（bp/10000）。`r` は実質金利であるため、名目長期金利の変化をそのまま渡すとインフレ分を二重に扱う。実質ベースへ変換した根拠（用いた期待インフレ）を記録する。",
                notes = "`r` はスカラー定数であり期別のパスを与えられない。恒久的なステップ変化として、`r` の異なる 2 つのモデルインスタンスの比較でのみ表現する（G-09）。",
            ),
            JapanFiscalInputMapping(;
                concept = :policy_rate,
                input_kind = :not_accepted,
                notes = "中央銀行・政策金利を持たない。`r` を政策金利として提示しない。",
            ),
            JapanFiscalInputMapping(;
                concept = :growth_path,
                input_kind = :not_accepted,
                notes = "`α` は労働生産性成長率であり集計 GDP 成長率の assumption ではない（G-03）。",
            ),
        ],
        baseline_requirements = [
            "baseline は良い均衡（`steady_state` が返す閉形式解）またはその近傍の初期値から開始する。",
            "baseline と scenario で `α`・`β`・`δ`・`ν`・Phillips/投資関数パラメータと積分区間を一致させる。",
        ],
        endogenous_outputs = [:private_debt, :employment],
        missing_channels = [
            "政府部門・財政",
            "名目変数・物価",
            "政策金利",
            "金利の時間形状（G-09）",
        ],
        parameterization_requirements = [
            "双安定性により結果が初期値と `r` に強く依存するため、`r` の ±50% 感応度と初期値の感応度を必ず併記する。",
            "崩壊経路（`d → ∞`）は数値的に発散するため、積分の打ち切り条件と打ち切り時刻の記録が必要。",
        ],
        japan_caveats = [
            "実証較正は米国基準のみ（ADR 0004）であり、日本の民間債務・雇用率に合わせた較正は存在しない（G-02）。",
            "既定パラメータは Grasselli & Costa Lima (2012) の数値例であり日本の推定値ではない。",
        ],
        can_state = [
            "実質借入金利の恒久的な上昇が、民間債務比率 `d` と雇用率 `λ` を良い均衡から崩壊経路へ向かわせるかどうかの方向。",
        ],
        cannot_state = [
            "政策金利と長期金利の区別（政策金利を持たない）。",
            "危機の発生時期・発生確率（双安定系の決定論的軌道であり確率ではない）。",
            "政府債務・財政（政府部門を持たない。G-01）。",
            "金利の時間形状に依存する結果（G-09）。",
        ],
        gap_ids = ["G-01", "G-02", "G-03", "G-06", "G-09"],
    ),
    JapanFiscalModelMapping(;
        family = :low_growth_high_rates,
        model = :sim,
        representability = :not_representable,
        reason = "金利を一切持たない（金融資産は無利子の政府貨幣 `H` のみ）。成長率の概念も持たず、定常状態は `Y* = G/θ` の水準として定義される。",
        missing_channels = ["金利・金融市場", "物価", "成長"],
        gap_ids = ["G-01", "G-03", "G-06"],
    ),
    JapanFiscalModelMapping(;
        family = :low_growth_high_rates,
        model = :capex_credit_cycle,
        representability = :partial,
        adoption = :primary,
        calibration_basis = :non_japan_calibrated,
        claim_level = :direction_and_relative_timing,
        reason = "政策金利（`policy_rate`、外生パス）と長期金利・funding 条件（`:LongRateFundingShock` 経由で `spread_shock_ex`、bp）を**別々の入力**として受け取れる唯一のモデルであり、family の中核要件（金利を 1 本へ縮約しない）を満たす。一方で GDP 成長率パスを受け取る入力は無く、baseline は成長率ゼロの定常状態と定義されている（G-12）。3 required concept のうち 2 つを受け取る。",
        inputs = [
            JapanFiscalInputMapping(;
                concept = :policy_rate,
                variable = :policy_rate,
                input_kind = :exogenous_path,
                unit = "% (annualized)",
                horizon = :quarterly,
                conversion = "`:PolicyRateChange` イベント（`:absolute` / `:additive`、%pt）から期別の外生パスを構成する。",
            ),
            JapanFiscalInputMapping(;
                concept = :long_rate_funding_condition,
                variable = :spread_shock_ex,
                input_kind = :exogenous_path,
                unit = "bp",
                horizon = :quarterly,
                conversion = "`FundingShockComponents` から `funding_shock_magnitude_bps` と `FundingShockPassThrough` を経て bp を算出し、`:LongRateFundingShock` として `spread_shock_ex` へ加算合成する（ADR 0019）。pass-through 係数は日本について較正されていない。",
                notes = "`spread_shock_ex` は企業の実効借入コストへの加算であり、政府の調達コストではない（G-14）。",
            ),
            JapanFiscalInputMapping(;
                concept = :growth_path,
                input_kind = :not_accepted,
                notes = "`ext_demand_s2` / `ext_demand_s3` は本モデル外の半導体・装置需要であり GDP 成長率パスではない。成長 assumption の代理に用いない（G-12）。",
            ),
        ],
        baseline_requirements = [
            "baseline は成長率ゼロの定常状態（ADR 0011）。`capex_credit_cycle_default_targets` からの逆較正で構築するが、48 の target キーは米国 NIPA 由来である（G-02）。",
            "baseline と scenario で model version・パラメータ・初期状態・ホライズンを一致させる。",
        ],
        endogenous_outputs = [
            :output,
            :private_borrowing_cost,
            :private_debt,
            :investment,
            :employment,
            :consumption,
        ],
        missing_channels = [
            "政府部門・財政・国債",
            "一般物価・インフレ",
            "成長regime",
            "イールドカーブの形状",
        ],
        parameterization_requirements = [
            "`FundingShockPassThrough` の既定係数 1.0 は較正されていない。日本へ適用する場合は ±50% の感応度併記を必須とする。",
            "`policy_rate` と `spread_shock_ex` は同じ実効借入コスト `r_new_s` へ入るため、両者を同時に動かす場合は反実仮想による寄与分解を併記する。",
            "`ai_exp` は baseline 値から動かさない（米国 AI 設備投資期待の外生入力であり日本シナリオの assumption ではない）。",
        ],
        japan_caveats = [
            "部門 S1–S5 は米国の AI・半導体 CAPEX 循環を対象に定義されており、日本の産業構造へ対応付けられていない（G-02）。",
            "診断ラベル（hedge / speculative / ponzi 相当の資金繰り区分）の閾値は較正されておらず、日本の企業財務へ適用する根拠が無い。",
        ],
        can_state = [
            "政策金利と長期金利・funding 条件を別入力として与えたときの、企業の実効借入コスト・CAPEX・部門別産出の方向と相対的な時間形状（peak / onset / duration の順序）。",
            "2 つの入力それぞれの寄与を反実仮想で分解した結果。",
        ],
        cannot_state = [
            "日本の量としての産出・投資の変化幅（G-02）。",
            "GDP 成長率 assumption に対する応答（G-12）。",
            "政府債務・利払費・債務持続可能性（G-01）。",
            "イールドカーブの形状変化（G-06）。",
        ],
        gap_ids = ["G-01", "G-02", "G-03", "G-06", "G-12", "G-14"],
    ),

    # -----------------------------------------------------------------
    # F2: 財政再建（歳出削減・増税）
    # -----------------------------------------------------------------
    JapanFiscalModelMapping(;
        family = :fiscal_consolidation,
        model = :ramsey,
        representability = :not_representable,
        reason = "政府部門を持たない。政府支出・税のいずれも入力として存在しない。",
        missing_channels = ["政府部門", "税", "政府債務"],
        gap_ids = ["G-01", "G-13"],
    ),
    JapanFiscalModelMapping(;
        family = :fiscal_consolidation,
        model = :rbc,
        representability = :not_representable,
        reason = "政府部門を持たない。政府支出・税のいずれも入力として存在しない。",
        missing_channels = ["政府部門", "税", "政府債務"],
        gap_ids = ["G-01", "G-13"],
    ),
    JapanFiscalModelMapping(;
        family = :fiscal_consolidation,
        model = :solow,
        representability = :not_representable,
        reason = "政府部門を持たない。貯蓄率 `s` は民間の行動パラメータであり公的貯蓄・財政収支ではないため、財政緊縮を `s` の上昇として表現しない（G-13）。",
        inputs = [
            JapanFiscalInputMapping(;
                concept = :government_spending,
                input_kind = :not_accepted,
                notes = "`s` を財政再建の代理に用いない。民間貯蓄率であり公的貯蓄ではない（G-13）。",
            ),
        ],
        missing_channels = ["政府部門", "税", "政府債務"],
        gap_ids = ["G-01", "G-13"],
    ),
    JapanFiscalModelMapping(;
        family = :fiscal_consolidation,
        model = :islm,
        representability = :partial,
        adoption = :supporting,
        calibration_basis = :structural_illustrative,
        claim_level = :direction_only,
        reason = "政府支出 `G` と定額税 `T` を直接のパラメータとして受け取るが、静学モデルであり期別の経路・政府債務ストック・財政収支の動学を持たない。財政収支は入力の差 `T − G` として自明に決まり、モデルが内生的に返す出力ではない。",
        inputs = [
            JapanFiscalInputMapping(;
                concept = :government_spending,
                variable = :G,
                input_kind = :model_parameter,
                unit = "level (model units)",
                horizon = :static,
                conversion = "対 GDP 比の assumption を与える場合、baseline の `Y*` を用いて水準へ換算し、換算式と baseline 依存性を記録する。",
            ),
            JapanFiscalInputMapping(;
                concept = :tax,
                variable = :T,
                input_kind = :model_parameter,
                unit = "level (model units)",
                horizon = :static,
                conversion = "IS-LM の `T` は定額税である。税率の assumption を与える場合は baseline の `Y*` を用いて税額へ換算し、比例税ではないことを記録する。",
            ),
            JapanFiscalInputMapping(;
                concept = :primary_balance,
                variable = :T,
                input_kind = :requires_structural_conversion,
                unit = "ratio to GDP",
                horizon = :static,
                conversion = "PB 目標を満たす `(G, T)` の組は無数にあるため、閉じ変数を 1 本（既定 `T`）に固定して逆算し、固定した事実と `G` を閉じ変数にした場合の感応度を記録する（G-07）。",
            ),
        ],
        baseline_requirements = [
            "baseline は同一パラメータでの `steady_state`（均衡 1 点）。scenario との差は `G`・`T` のみに限定する。",
        ],
        endogenous_outputs = [:output, :nominal_rate, :consumption, :investment],
        missing_channels = [
            "動学（静学 1 点解）",
            "政府債務ストック・利払費",
            "物価",
            "対外部門",
        ],
        parameterization_requirements = [
            "乗数は `c1`・`b`・`l1`・`l2` に強く依存するため、これらの ±50% 感応度の併記が必要。",
        ],
        japan_caveats = [
            "教科書パラメータであり日本の推定値ではない（G-02）。",
            "定額税のみで社会保障負担・消費税といった日本の税制を表現しない。",
        ],
        can_state = [
            "歳出削減・増税が産出と利子率へ及ぼす方向（乗数とクラウディングアウトの符号）。",
        ],
        cannot_state = [
            "時間経路・peak / onset / duration（静学モデルであり 1 点しか返さない）。",
            "政府債務残高・利払費（G-01）。",
            "日本の財政乗数の大きさ（G-02）。",
        ],
        gap_ids = ["G-01", "G-02", "G-07"],
    ),
    JapanFiscalModelMapping(;
        family = :fiscal_consolidation,
        model = :adas,
        representability = :partial,
        adoption = :supporting,
        calibration_basis = :structural_illustrative,
        claim_level = :direction_only,
        reason = "IS-LM と同じく `G`・`T` を直接受け取り、加えて物価水準 `P` を内生化するため財政緊縮のデフレ効果を符号として示せる。ただし静学であり、財政収支・政府債務の動学を返さない。",
        inputs = [
            JapanFiscalInputMapping(;
                concept = :government_spending,
                variable = :G,
                input_kind = :model_parameter,
                unit = "level (model units)",
                horizon = :static,
                conversion = "対 GDP 比を与える場合は baseline 均衡の `Y*` で水準へ換算し、換算式を記録する。",
            ),
            JapanFiscalInputMapping(;
                concept = :tax,
                variable = :T,
                input_kind = :model_parameter,
                unit = "level (model units)",
                horizon = :static,
                conversion = "定額税。税率 assumption からの換算式と、比例税ではないことを記録する。",
            ),
            JapanFiscalInputMapping(;
                concept = :primary_balance,
                variable = :T,
                input_kind = :requires_structural_conversion,
                unit = "ratio to GDP",
                horizon = :static,
                conversion = "閉じ変数を 1 本に固定して `(G, T)` を逆算する（G-07）。",
            ),
        ],
        baseline_requirements = [
            "baseline は同一パラメータでの `steady_state`（均衡 1 点）。",
        ],
        endogenous_outputs = [
            :output,
            :price_level,
            :nominal_rate,
            :consumption,
            :investment,
        ],
        missing_channels = ["動学（静学 1 点解）", "政府債務ストック・利払費", "対外部門"],
        parameterization_requirements = [
            "SRAS の傾き `v` と期待物価 `P_e` が物価反応を決めるため、両者の感応度併記が必要。",
        ],
        japan_caveats = [
            "教科書パラメータであり日本の推定値ではない（G-02）。",
            "期待物価 `P_e` は外生固定であり、期待形成の変化を表現しない。",
        ],
        can_state = ["歳出削減・増税が産出・物価水準・利子率へ及ぼす方向。"],
        cannot_state = [
            "時間経路・peak / onset / duration（静学モデル）。",
            "政府債務残高・利払費（G-01）。",
            "インフレ率（物価『水準』の 1 点であり率ではない）。",
        ],
        gap_ids = ["G-01", "G-02", "G-07"],
    ),
    JapanFiscalModelMapping(;
        family = :fiscal_consolidation,
        model = :new_keynesian,
        representability = :not_representable,
        reason = "3 方程式モデルに財政部門が無く、政府支出・税のいずれも入力として持たない。`:demand` ショックは税・支出・債務のいずれの意味も持たないため、財政緊縮の代理に用いない。",
        inputs = [
            JapanFiscalInputMapping(;
                concept = :government_spending,
                input_kind = :not_accepted,
                notes = "`:demand` ショックを財政緊縮の代理に用いない。財政乗数として解釈できる根拠が無い。",
            ),
        ],
        missing_channels = ["政府部門", "税", "政府債務"],
        gap_ids = ["G-01"],
    ),
    JapanFiscalModelMapping(;
        family = :fiscal_consolidation,
        model = :var,
        representability = :not_representable,
        reason = _JF_VAR_REASON,
        gap_ids = ["G-10"],
    ),
    JapanFiscalModelMapping(;
        family = :fiscal_consolidation,
        model = :mundell_fleming,
        representability = :partial,
        adoption = :supporting,
        calibration_basis = :structural_illustrative,
        claim_level = :direction_only,
        reason = "`G`・`T` を直接受け取るが、UIP と変動相場の構造により均衡産出 `Y = (M/P + l2·r*)/l1` が `G` を含まず、財政乗数が恒等的にゼロになる。財政収支・政府債務の出力も持たない。",
        inputs = [
            JapanFiscalInputMapping(;
                concept = :government_spending,
                variable = :G,
                input_kind = :model_parameter,
                unit = "level (model units)",
                horizon = :static,
                conversion = "対 GDP 比を与える場合は baseline 均衡の `Y*` で換算する。",
                notes = "`G` は産出に影響せず、純輸出 `NX` と為替 `e` のみを動かす。",
            ),
            JapanFiscalInputMapping(;
                concept = :tax,
                variable = :T,
                input_kind = :model_parameter,
                unit = "level (model units)",
                horizon = :static,
                conversion = "定額税。税率 assumption からの換算式を記録する。",
            ),
        ],
        baseline_requirements = [
            "baseline は同一パラメータでの `steady_state`（均衡 1 点）。`r_star` を baseline と scenario で一致させる。",
        ],
        endogenous_outputs = [
            :output,
            :exchange_rate,
            :net_exports,
            :consumption,
            :investment,
        ],
        missing_channels = [
            "動学（静学 1 点解）",
            "政府債務ストック・利払費",
            "物価",
            "国内金利の独立性",
        ],
        parameterization_requirements = [
            "純輸出の為替感応度 `nx1` が為替の反応幅を決めるため、感応度の併記が必要。",
        ],
        japan_caveats = [
            "小国・完全資本移動・変動相場の仮定は、国債が国内で消化され中央銀行が大量保有する日本の状況と整合しない（G-08）。",
            "『財政政策は無効』という結果はモデル構造の帰結であり、日本についての実証的発見ではない（G-08）。",
        ],
        can_state = [
            "変動相場・完全資本移動という仮定の下で、財政緊縮が為替と純輸出へ及ぼす方向（産出は不変）。",
        ],
        cannot_state = [
            "日本の財政乗数（構造仮定により恒等的にゼロ。実証結果ではない。G-08）。",
            "政府債務残高・利払費（G-01）。",
            "時間経路（静学モデル）。",
        ],
        gap_ids = ["G-01", "G-02", "G-07", "G-08"],
    ),
    JapanFiscalModelMapping(;
        family = :fiscal_consolidation,
        model = :keen,
        representability = :not_representable,
        reason = "政府部門を持たない閉鎖経済の民間債務モデルであり、政府支出・税のいずれも入力として存在しない。投資関数パラメータ `κ0` の引き下げを財政緊縮の代理に用いない（民間投資行動の変化であり政府部門ではない）。",
        inputs = [
            JapanFiscalInputMapping(;
                concept = :government_spending,
                input_kind = :not_accepted,
                notes = "`κ0`（投資関数の定数項）を財政緊縮の代理に用いない。",
            ),
        ],
        missing_channels = ["政府部門", "税", "政府債務"],
        gap_ids = ["G-01"],
    ),
    JapanFiscalModelMapping(;
        family = :fiscal_consolidation,
        model = :sim,
        representability = :representable,
        adoption = :primary,
        calibration_basis = :structural_illustrative,
        claim_level = :direction_and_relative_timing,
        reason = "政府支出 `G` と比例税率 `θ` を別々の入力として受け取り、税収 `T = θ·Y` が内生であるため財政収支 `T − G` を**モデルの出力**として返す。ストック・フロー整合であり、家計純資産 `H` の蓄積経路を会計恒等式つきで追える。required concept・required output をいずれも満たす唯一のモデル。",
        inputs = [
            JapanFiscalInputMapping(;
                concept = :government_spending,
                variable = :G,
                input_kind = :exogenous_path,
                unit = "level (model units)",
                horizon = :period,
                conversion = "`impulse_response(m, shock_size; shock=:G)` の加算ショック、または期別系列 `Gseq` として与える。対 GDP 比 assumption は定常状態 `Y* = G/θ` を用いて水準へ換算し、換算式を記録する。",
            ),
            JapanFiscalInputMapping(;
                concept = :tax,
                variable = :θ,
                input_kind = :exogenous_path,
                unit = "ratio (tax rate)",
                horizon = :period,
                conversion = "比例税率そのもの。`impulse_response(m, shock_size; shock=:θ)` または期別系列 `θseq` として与える。定額税額の assumption は受け取らない（θ は率であり額ではない）。",
                notes = "ショック後に `θ ∉ (0, 1)` となる指定は `ArgumentError` として拒否される。",
            ),
            JapanFiscalInputMapping(;
                concept = :primary_balance,
                variable = :θ,
                input_kind = :requires_structural_conversion,
                unit = "ratio to GDP",
                horizon = :period,
                conversion = "PB は `θ·Y − G` として内生に決まるため、PB 目標を与えるには閉じ変数を 1 本（既定 `θ`）に固定して数値的に逆算する。`Y` も同時に動くため逆算は反復を要し、組は一意でない（G-07）。",
            ),
        ],
        baseline_requirements = [
            "baseline は定常状態（`Y* = G/θ`・`H* = (1−α1)/α2 · YD*`）から開始する。日本の水準を再現する較正は行わない（G-02）。",
            "baseline と scenario で `α1`・`α2`・`W`・初期ストック `H0`・ホライズン `T` を一致させる。",
        ],
        endogenous_outputs = [
            :output,
            :government_balance,
            :consumption,
            :employment,
            :money_stock,
        ],
        missing_channels = [
            "利子率（`H` は無利子）",
            "物価・インフレ",
            "対外部門",
            "企業の投資決定",
            "中央銀行",
        ],
        parameterization_requirements = [
            "`α1`・`α2`・`θ` は教科書値。`θ` を日本の一般政府収入/GDP 比へ寄せる場合、その設定自体を assumption として記録する。",
            "`impulse_response` は `G` か `θ` の一方しか動かせないため、歳出削減と増税の同時実施には期別系列（`Gseq`・`θseq`）を与える薄い adapter が #276 で必要。",
        ],
        japan_caveats = [
            "閉鎖経済・3 部門（家計・生産・政府）の最小モデルであり、日本の財政制度（社会保障・地方財政・特別会計）を表現しない。",
            "`H` を国債残高として提示しない。無利子の政府貨幣であり利付き国債ではない（G-01）。",
        ],
        can_state = [
            "歳出削減・増税が産出・可処分所得・家計純資産・財政収支へ及ぼす方向と、定常状態へ収束する相対的な時間形状。",
            "全期で会計恒等式が成立すること（`sfc_result` + `validate_sfc_accounting`）。",
        ],
        cannot_state = [
            "利払費・債務残高/GDP・`r − g` 債務動学（G-01）。",
            "日本の財政乗数の大きさ（G-02）。",
            "金利・為替・インフレへの影響（モデルに存在しない）。",
        ],
        gap_ids = ["G-01", "G-02", "G-07"],
    ),
    JapanFiscalModelMapping(;
        family = :fiscal_consolidation,
        model = :capex_credit_cycle,
        representability = :not_representable,
        reason = "政府部門を持たない（部門は S1–S5 の企業・金融・家計であり政府は残差部門 `SX` にも分離されていない）。政府支出・税のいずれも入力として存在しない。モデル外需要 `ext_demand_s2` / `ext_demand_s3` の低下を財政緊縮の代理に用いない（G-12）。",
        inputs = [
            JapanFiscalInputMapping(;
                concept = :government_spending,
                input_kind = :not_accepted,
                notes = "モデル外需要のパスを財政緊縮の代理に用いない。`ext_demand_s` は本モデル外の半導体・装置需要であり政府支出ではない（G-12）。",
            ),
        ],
        missing_channels = ["政府部門", "税", "政府債務"],
        gap_ids = ["G-01", "G-12"],
    ),

    # -----------------------------------------------------------------
    # F3: 金融抑圧
    # -----------------------------------------------------------------
    JapanFiscalModelMapping(;
        family = :financial_repression,
        model = :ramsey,
        representability = :not_representable,
        reason = "名目変数・貨幣・中央銀行を持たない実物モデルであり、政策金利・インフレ・JGB 吸収のいずれも入力として存在しない。",
        missing_channels = ["名目変数・貨幣", "中央銀行", "政府債務"],
        gap_ids = ["G-04", "G-05"],
    ),
    JapanFiscalModelMapping(;
        family = :financial_repression,
        model = :rbc,
        representability = :not_representable,
        reason = "名目変数・貨幣・中央銀行を持たない実物モデルであり、政策金利・インフレ・JGB 吸収のいずれも入力として存在しない。",
        missing_channels = ["名目変数・貨幣", "中央銀行", "政府債務"],
        gap_ids = ["G-04", "G-05"],
    ),
    JapanFiscalModelMapping(;
        family = :financial_repression,
        model = :solow,
        representability = :not_representable,
        reason = "金利・物価・中央銀行のいずれも持たない実物成長モデルであり、金融抑圧の 3 概念を 1 つも受け取らない。",
        missing_channels = ["名目変数・貨幣", "中央銀行", "金利"],
        gap_ids = ["G-04", "G-05"],
    ),
    JapanFiscalModelMapping(;
        family = :financial_repression,
        model = :islm,
        representability = :not_representable,
        reason = "物価 `P` が外生固定でインフレの概念を持たない。政策金利も入力として持たない（`r` は `M/P` から内生的に決まる）。中央銀行の JGB 吸収も持たない（G-04）。",
        inputs = [
            JapanFiscalInputMapping(;
                concept = :cb_jgb_absorption,
                input_kind = :not_accepted,
                notes = "`M` は名目マネーサプライであり中央銀行の資産構成（国債保有残高）ではない。JGB 吸収の代理に用いない（G-04）。",
            ),
        ],
        missing_channels = ["インフレ", "政策金利の独立指定", "中央銀行バランスシート"],
        gap_ids = ["G-04", "G-05"],
    ),
    JapanFiscalModelMapping(;
        family = :financial_repression,
        model = :adas,
        representability = :not_representable,
        reason = "物価水準 `P` は内生だが、インフレと名目金利を**独立な** assumption として受け取れない。両者はマネーサプライ `M` 等の単一入力の同時結果であり、『金融抑圧を単一 rate shock へ縮約しない』という family の分解規則に反する（G-05）。中央銀行の JGB 吸収も持たない（G-04）。",
        inputs = [
            JapanFiscalInputMapping(;
                concept = :inflation,
                input_kind = :not_accepted,
                notes = "`P` は内生であり assumption として与えられない。期待物価 `P_e` は外生パラメータだが物価の『水準』であって上昇『率』ではなく、静学 1 点解のため期間を定めない限りインフレ率へ換算できない。`M` の増加で `P` と `r` を同時に動かすことを『インフレ assumption + 政策金利 assumption』として提示しない（G-05）。",
            ),
            JapanFiscalInputMapping(;
                concept = :policy_rate,
                input_kind = :not_accepted,
                notes = "`r` は内生。目標金利を与えるには `M` の逆算が要り、その `M` は物価も同時に動かす。",
            ),
            JapanFiscalInputMapping(;
                concept = :cb_jgb_absorption,
                input_kind = :not_accepted,
                notes = "中央銀行のバランスシートを持たない（G-04）。",
            ),
        ],
        missing_channels = [
            "インフレと名目金利の分離",
            "中央銀行バランスシート",
            "動学（静学 1 点解）",
        ],
        gap_ids = ["G-04", "G-05"],
    ),
    JapanFiscalModelMapping(;
        family = :financial_repression,
        model = :new_keynesian,
        representability = :partial,
        adoption = :primary,
        calibration_basis = :structural_illustrative,
        claim_level = :direction_and_relative_timing,
        reason = "名目政策金利（`:monetary` ショックと Taylor rule パラメータ）とインフレ（目標 `π_star`）を**別々の入力**として受け取れる唯一のモデルであり、family の分解規則（単一 rate shock へ縮約しない）を満たす。中央銀行の JGB 吸収は表現できない（G-04）。3 required concept のうち 2 つを受け取る。",
        inputs = [
            JapanFiscalInputMapping(;
                concept = :policy_rate,
                variable = :i,
                input_kind = :shock_process,
                unit = "%pt (deviation from steady state)",
                horizon = :quarterly,
                conversion = "『名目金利を低位に据え置く』は持続的な負の金融政策ショック（`shock=:monetary`、`shock_size < 0`、`ρ_m` を大きくとる）として表現する。`ρ_m` への変換規則を明示する。",
                notes = "Taylor rule 係数 `φ_π`・`φ_x` の引き下げも『政策反応の弱さ』として表現できるが、ショックとパラメータ変更は別の assumption として記録する。",
            ),
            JapanFiscalInputMapping(;
                concept = :inflation,
                variable = :π_star,
                input_kind = :model_parameter,
                unit = "%pt (annualized)",
                horizon = :quarterly,
                conversion = "インフレ目標の引き上げとして受け取る。定常状態の名目金利 `i* = r_n + π_star` も同時に上がるため、『名目金利を据え置いたままインフレだけ上げる』には `π_star` 変更と負の金融政策ショックの**組み合わせ**が要る。組み合わせ規則を assumption として明示する。",
            ),
            JapanFiscalInputMapping(;
                concept = :cb_jgb_absorption,
                input_kind = :not_accepted,
                notes = "中央銀行のバランスシート・国債保有を持たない。政策金利の追加的な引き下げへ振り替えない（G-04）。",
            ),
        ],
        baseline_requirements = [
            "baseline は全ショックゼロの定常状態（`x=0`・`π=π_star`・`i=r_n+π_star`）。",
            "`π_star` を変更する scenario では baseline も同じ `π_star` で再計算せず、baseline は変更前の `π_star` を保持し、差分が目標変更を含むことを記録する。",
        ],
        endogenous_outputs = [:output_gap, :inflation, :nominal_rate, :real_rate],
        missing_channels = [
            "中央銀行バランスシート・JGB 吸収（G-04）",
            "政府債務・利払費（G-01）",
            "名目金利ゼロ下限",
            "期間構造",
        ],
        parameterization_requirements = [
            "`ρ_m → 1` では MSV 解 `(A − ρB)` が特異に近づき不安定になるため、`ρ_m` の上限と感応度の記録が必要。",
            "実質金利は `i − E[π]` として導出する。`nk_expected_inflation_path` と `real_rate_model_artifact` の既存機構を再利用し、導出式を artifact に記録する。",
        ],
        japan_caveats = [
            "パラメータは教科書値であり日本の推定値ではない（G-02）。",
            "イールドカーブ・コントロール・量的緩和といった日本の非伝統的政策手段を表現しない（G-04）。",
        ],
        can_state = [
            "名目政策金利とインフレ目標を**別入力**として与えたときの、事前的実質金利 `i − E[π]` の経路の方向と相対的な時間形状。",
            "政策反応係数の低下（`φ_π` の引き下げ）が実質金利の負化にどう寄与するかの方向。",
        ],
        cannot_state = [
            "中央銀行の JGB 吸収の効果（G-04）。",
            "政府債務の実質価値がどれだけ圧縮されるか（G-01）。",
            "日本の実質金利の水準・家計から政府への移転額（G-02・G-01）。",
        ],
        gap_ids = ["G-01", "G-02", "G-04"],
    ),
    JapanFiscalModelMapping(;
        family = :financial_repression,
        model = :var,
        representability = :not_representable,
        reason = _JF_VAR_REASON,
        gap_ids = ["G-10"],
    ),
    JapanFiscalModelMapping(;
        family = :financial_repression,
        model = :mundell_fleming,
        representability = :not_representable,
        reason = "`r = r*` により国内名目金利を世界利子率と独立に低位へ据え置けない（G-08）。物価 `P` は短期固定でインフレを持たず、中央銀行のバランスシートも持たない。",
        missing_channels = ["国内金利の独立性", "インフレ", "中央銀行バランスシート"],
        gap_ids = ["G-04", "G-05", "G-08"],
    ),
    JapanFiscalModelMapping(;
        family = :financial_repression,
        model = :keen,
        representability = :not_representable,
        reason = "実質貸出金利 `r` は民間の借入金利であり政策金利ではない。物価・インフレを持たず（実質モデル）、中央銀行も政府も持たない。3 required concept を 1 つも受け取らない。`r` の低下を『政策金利の低位維持』として提示しない。",
        inputs = [
            JapanFiscalInputMapping(;
                concept = :policy_rate,
                input_kind = :not_accepted,
                notes = "`r` は民間の実質貸出金利であり政策金利ではない。代理に用いない。",
            ),
            JapanFiscalInputMapping(;
                concept = :inflation,
                input_kind = :not_accepted,
                notes = "名目変数を持たない実質モデルであり、インフレの概念が無い。",
            ),
        ],
        missing_channels = ["政策金利", "インフレ", "中央銀行", "政府部門"],
        gap_ids = ["G-01", "G-04", "G-05", "G-09"],
    ),
    JapanFiscalModelMapping(;
        family = :financial_repression,
        model = :sim,
        representability = :not_representable,
        reason = "金利・物価のいずれも持たない（金融資産は無利子の政府貨幣 `H` のみ）。中央銀行も存在しない。",
        missing_channels = ["金利", "物価・インフレ", "中央銀行"],
        gap_ids = ["G-01", "G-04", "G-05"],
    ),
    JapanFiscalModelMapping(;
        family = :financial_repression,
        model = :capex_credit_cycle,
        representability = :partial,
        adoption = :not_adopted,
        calibration_basis = :non_japan_calibrated,
        claim_level = :none,
        reason = "`policy_rate` を外生パスとして受け取れるが、一般物価・インフレを持たず（`price_s1` は S1 部門の産出価格であり代理にしない。G-11）、中央銀行の JGB 吸収も持たない（G-04）。実質金利の経路と政府債務の実質価値圧縮という family の中核を返さないため、Phase 3 では採用しない。",
        inputs = [
            JapanFiscalInputMapping(;
                concept = :policy_rate,
                variable = :policy_rate,
                input_kind = :exogenous_path,
                unit = "% (annualized)",
                horizon = :quarterly,
                conversion = "`:PolicyRateChange` イベントから期別の外生パスを構成する。",
                notes = "名目・実質の区別を持たないため、金融抑圧の『実質金利を負にする』という主張を支えない。",
            ),
            JapanFiscalInputMapping(;
                concept = :inflation,
                input_kind = :not_accepted,
                notes = "`price_s1` は S1 の先決産出価格であり一般物価水準ではない。インフレ assumption の代理に用いない（G-11）。",
            ),
            JapanFiscalInputMapping(;
                concept = :cb_jgb_absorption,
                input_kind = :not_accepted,
                notes = "中央銀行・国債を持たない（G-04）。",
            ),
        ],
        endogenous_outputs = [:private_borrowing_cost, :output, :private_debt, :investment],
        missing_channels = [
            "一般物価・インフレ（G-11）",
            "中央銀行バランスシート（G-04）",
            "政府債務（G-01）",
            "実質金利",
        ],
        japan_caveats = ["部門構成・逆較正はいずれも米国由来（G-02）。"],
        cannot_state = [
            "実質金利の経路（名目・実質の区別を持たない）。",
            "政府債務の実質価値の圧縮（G-01）。",
        ],
        gap_ids = ["G-01", "G-02", "G-04", "G-11"],
    ),

    # -----------------------------------------------------------------
    # F4: 高成長 / 生産性ショック
    # -----------------------------------------------------------------
    JapanFiscalModelMapping(;
        family = :high_growth_productivity,
        model = :ramsey,
        representability = :not_representable,
        reason = "生産関数 `K^α` に技術水準・TFP のパラメータが無く、生産性を動かす入力を持たない。`α`（資本分配率）は生産関数の形状パラメータであり技術水準ではないため、生産性ショックの代理に用いない。",
        inputs = [
            JapanFiscalInputMapping(;
                concept = :productivity_growth,
                input_kind = :not_accepted,
                notes = "`α` は資本分配率であり技術水準ではない。生産性ショックの代理に用いない。",
            ),
        ],
        missing_channels = ["技術水準・TFP", "労働供給", "成長率"],
        gap_ids = ["G-03"],
    ),
    JapanFiscalModelMapping(;
        family = :high_growth_productivity,
        model = :rbc,
        representability = :representable,
        adoption = :supporting,
        calibration_basis = :structural_illustrative,
        claim_level = :direction_and_relative_timing,
        reason = "TFP `A` の水準ショックを `impulse_response(m, shock_size)` として直接受け取り、資本ストック `K` と産出 `Y` の移行経路を返す。required concept・required output をいずれも満たす。ただしショックは持続性 `ρ < 1` で平均回帰するため、持続的な成長regimeの変化ではない。",
        inputs = [
            JapanFiscalInputMapping(;
                concept = :productivity_growth,
                variable = :A,
                input_kind = :shock_process,
                unit = "log level deviation",
                horizon = :period,
                conversion = "生産性の水準シフト（対数偏差）を `shock_size` として渡す。成長『率』の assumption を渡す場合は、対象期間長を明示して水準シフトへ換算し、換算が期間長に依存し一意でないことを記録する（G-03）。",
                notes = "`ρ` により `log A` は AR(1) で平均回帰する。恒久的な技術水準シフトは表現しない。",
            ),
        ],
        baseline_requirements = [
            "baseline は `calc_ep` が返す定常状態（`A* = 1` に正規化）。日本の水準へ合わせる較正は行わない（G-02）。",
            "baseline と scenario で `α`・`β`・`γ`・`δ`・`μ`・`ρ`・`maxT` を一致させる。",
        ],
        endogenous_outputs = [
            :output,
            :capital_stock,
            :consumption,
            :employment,
            :real_rate,
        ],
        missing_channels = [
            "政府部門・財政（G-01）",
            "名目変数・金利政策",
            "恒久的な成長率の変化",
        ],
        parameterization_requirements = [
            "`ρ`（TFP 持続性）がショックの時間形状を決めるため、`PersistenceSpec` からの変換規則と感応度の併記が必要。",
            "`A* = 1` への正規化のため、出力は水準ではなく定常状態比として解釈する。",
        ],
        japan_caveats = [
            "パラメータは教科書値であり日本の推定値ではない（G-02）。",
            "政府部門を持たないため、成長が財政へ及ぼす効果（分母効果）を返さない。",
        ],
        can_state = [
            "生産性の一時的な改善に対する産出・資本・消費・労働の方向と相対的な時間形状（peak / duration の順序）。",
        ],
        cannot_state = [
            "恒久的な成長率の変化（ショックは `ρ < 1` で平均回帰する）。",
            "債務残高/GDP の分母効果（政府部門を持たない。G-01）。",
            "日本の生産性上昇の量的効果（G-02）。",
        ],
        gap_ids = ["G-01", "G-02", "G-03"],
    ),
    JapanFiscalModelMapping(;
        family = :high_growth_productivity,
        model = :solow,
        representability = :representable,
        adoption = :primary,
        calibration_basis = :structural_illustrative,
        claim_level = :direction_and_relative_timing,
        reason = "技術進歩率 `g` と人口成長率 `n` を成長『率』のパラメータとして直接受け取り、効率労働単位あたり資本 `k` と産出 `y` の移行経路（`transition_path`）を返す。生産性成長率の概念を最も素直に受け取るモデルであり、required concept・required output をいずれも満たす。",
        inputs = [
            JapanFiscalInputMapping(;
                concept = :productivity_growth,
                variable = :g,
                input_kind = :model_parameter,
                unit = "growth rate per period (decimal)",
                horizon = :period,
                conversion = "技術進歩率そのもの。年率 %pt の assumption を小数へ換算する（%pt/100）。期の長さ（年・四半期）を明示する。",
                notes = "`g` の変更は均斉成長経路（BGP）そのものを変える。`k` は効率労働単位あたりであり、水準 `K` の経路とは別物である。",
            ),
        ],
        baseline_requirements = [
            "baseline は `solow_ep` の定常状態 `k* = (s/(δ+n+g+n·g))^{1/(1−α)}`。日本の資本係数へ合わせる較正は行わない（G-02）。",
            "baseline と scenario で `α`・`s`・`δ`・`n`・初期 `k0`・期間数を一致させる。",
        ],
        endogenous_outputs = [:output, :capital_stock, :consumption],
        missing_channels = [
            "政府部門・財政（G-01）",
            "金利・金融市場",
            "物価・名目変数",
            "最適化（`s` は外生の行動パラメータ）",
        ],
        parameterization_requirements = [
            "`g` の変更は定常状態と移行経路の双方を動かすため、`g` の ±50% 感応度の併記が必要。",
            "効率労働単位あたりの量と水準量の換算式（`Y = y · A · L`）を artifact に記録する。",
        ],
        japan_caveats = [
            "パラメータは教科書値であり日本の推定値ではない（G-02）。",
            "日本の人口減少（`n < 0`）は定常条件 `δ + n + g + n·g > 0` を満たす範囲でのみ設定でき、範囲外の指定は拒否する必要がある。",
            "政府部門を持たないため、成長が債務比率の分母へ及ぼす効果を返さない（G-01）。",
        ],
        can_state = [
            "技術進歩率・人口成長率の変更が、効率労働単位あたり資本・産出・消費の定常状態と移行経路へ及ぼす方向と相対的な時間形状。",
        ],
        cannot_state = [
            "債務残高/GDP の分母効果（政府部門を持たない。G-01）。",
            "日本の潜在成長率の水準（G-02）。",
            "金利・インフレへの影響（モデルに存在しない）。",
        ],
        gap_ids = ["G-01", "G-02", "G-03"],
    ),
    JapanFiscalModelMapping(;
        family = :high_growth_productivity,
        model = :islm,
        representability = :not_representable,
        reason = "供給側を持たず、潜在産出・生産性のいずれの入力も無い（産出は需要のみで決まる）。",
        missing_channels = ["供給側・潜在産出", "資本蓄積", "成長"],
        gap_ids = ["G-03"],
    ),
    JapanFiscalModelMapping(;
        family = :high_growth_productivity,
        model = :adas,
        representability = :partial,
        adoption = :supporting,
        calibration_basis = :structural_illustrative,
        claim_level = :direction_only,
        reason = "潜在産出 `Y_n` を**水準**として受け取れるため生産性向上の物価・産出への帰結を符号として示せるが、成長『率』ではなく水準であり、資本ストックの経路も返さない（静学 1 点解）。required output の `:capital_stock` を満たさない。",
        inputs = [
            JapanFiscalInputMapping(;
                concept = :productivity_growth,
                variable = :Y_n,
                input_kind = :requires_structural_conversion,
                unit = "level (model units)",
                horizon = :static,
                conversion = "生産性成長率の assumption を潜在産出の水準シフトへ換算する。換算は対象期間長に依存し一意でないため、期間長と換算式を assumption として記録する（G-03）。",
                notes = "`Y_n` は潜在産出の『水準』であり成長率ではない。Solow の `g`・Keen の `α` と相互に変換しない。",
            ),
        ],
        baseline_requirements = [
            "baseline は同一パラメータでの `steady_state`（均衡 1 点）。`P_e`（期待物価）を baseline と scenario で一致させる。",
        ],
        endogenous_outputs = [
            :output,
            :price_level,
            :nominal_rate,
            :consumption,
            :investment,
        ],
        missing_channels = [
            "資本蓄積・資本ストック",
            "動学（静学 1 点解）",
            "成長率",
            "政府債務",
        ],
        parameterization_requirements = [
            "SRAS の傾き `v` が潜在産出シフトの物価への波及を決めるため、感応度の併記が必要。",
        ],
        japan_caveats = [
            "教科書パラメータであり日本の推定値ではない（G-02）。",
            "期待物価 `P_e` が外生固定のため、潜在産出上昇に伴う期待の調整を表現しない。",
        ],
        can_state = [
            "潜在産出の上昇が均衡産出と物価水準へ及ぼす方向（デフレ圧力の符号）。",
        ],
        cannot_state = [
            "資本蓄積の経路（資本ストックを持たない）。",
            "成長率としての効果（水準シフトのみ。G-03）。",
            "債務比率の分母効果（G-01）。",
        ],
        gap_ids = ["G-01", "G-02", "G-03"],
    ),
    JapanFiscalModelMapping(;
        family = :high_growth_productivity,
        model = :new_keynesian,
        representability = :not_representable,
        reason = "産出は潜在からの乖離（ギャップ）で表現され、潜在産出そのものを動かす入力が無い。自然利子率 `r_n` は定常状態の名目金利 `i* = r_n + π_star` を動かすだけで、産出ギャップ `x` とインフレ `π` は定常状態のまま変わらず、生産性向上の効果を返さない。`:demand` ショックを生産性向上の代理に用いない。",
        inputs = [
            JapanFiscalInputMapping(;
                concept = :productivity_growth,
                input_kind = :not_accepted,
                notes = "`:demand` ショックは産出ギャップの一時的拡大であり潜在産出の上昇ではない。`r_n` の変更は定常状態の名目金利のみを動かす。",
            ),
        ],
        missing_channels = ["潜在産出の外生指定", "資本蓄積", "成長トレンド"],
        gap_ids = ["G-03"],
    ),
    JapanFiscalModelMapping(;
        family = :high_growth_productivity,
        model = :var,
        representability = :not_representable,
        reason = _JF_VAR_REASON,
        gap_ids = ["G-10"],
    ),
    JapanFiscalModelMapping(;
        family = :high_growth_productivity,
        model = :mundell_fleming,
        representability = :not_representable,
        reason = "供給側・潜在産出を持たず（`Y` は LM 方程式と `r*` のみで決まる）、生産性の入力が存在しない。",
        missing_channels = ["供給側・潜在産出", "資本蓄積", "成長"],
        gap_ids = ["G-03"],
    ),
    JapanFiscalModelMapping(;
        family = :high_growth_productivity,
        model = :keen,
        representability = :partial,
        adoption = :supporting,
        calibration_basis = :structural_illustrative,
        claim_level = :direction_only,
        reason = "労働生産性成長率 `α` をパラメータとして直接受け取る（成長『率』を受け取る数少ないモデル）。ただし状態変数は賃金シェア・雇用率・民間債務比率であり、産出水準・資本ストックを返さないため required output を満たさない。",
        inputs = [
            JapanFiscalInputMapping(;
                concept = :productivity_growth,
                variable = :α,
                input_kind = :model_parameter,
                unit = "growth rate per year (decimal)",
                horizon = :continuous_year,
                conversion = "労働生産性成長率そのもの（年率・小数）。年率 %pt の assumption を %pt/100 で換算する。",
                notes = "`α` は Phillips 曲線・投資関数を通じて賃金シェアと雇用率の動学に入る。産出水準は返らない。",
            ),
        ],
        baseline_requirements = [
            "baseline は良い均衡（`steady_state`）またはその近傍の初期値。",
            "baseline と scenario で `β`・`δ`・`ν`・`r`・Phillips/投資関数パラメータと積分区間を一致させる。",
        ],
        endogenous_outputs = [:private_debt, :employment],
        missing_channels = [
            "産出水準・資本ストック",
            "政府部門・財政（G-01）",
            "名目変数・物価",
        ],
        parameterization_requirements = [
            "双安定性のため `α` の ±50% 感応度と初期値の感応度を必ず併記する。",
        ],
        japan_caveats = [
            "実証較正は米国基準のみであり、日本の民間債務・雇用率へ合わせた較正は存在しない（G-02）。",
        ],
        can_state = [
            "労働生産性成長率の上昇が、民間債務比率と雇用率を良い均衡に留めるか崩壊経路へ向かわせるかの方向。",
        ],
        cannot_state = [
            "産出・資本ストックの経路（状態変数に含まれない）。",
            "債務比率の分母効果（政府部門を持たない。G-01）。",
            "危機の発生時期・発生確率。",
        ],
        gap_ids = ["G-01", "G-02", "G-03", "G-09"],
    ),
    JapanFiscalModelMapping(;
        family = :high_growth_productivity,
        model = :sim,
        representability = :not_representable,
        reason = "生産性の概念を持たない。賃金率 `W` は数値基準であり、`N = Y/W` は雇用の会計上の定義にすぎないため、`W` を労働生産性の代理に用いない。資本ストックも持たない。",
        inputs = [
            JapanFiscalInputMapping(;
                concept = :productivity_growth,
                input_kind = :not_accepted,
                notes = "`W` は名目賃金率（数値基準）であり労働生産性ではない。`N = Y/W` は会計上の恒等式である。",
            ),
        ],
        missing_channels = ["生産性・技術", "資本蓄積", "成長"],
        gap_ids = ["G-03"],
    ),
    JapanFiscalModelMapping(;
        family = :high_growth_productivity,
        model = :capex_credit_cycle,
        representability = :not_representable,
        reason = "baseline を成長率ゼロの定常状態と定義しており（ADR 0011）、成長regimeそのものを表現できない。`st_lprod_s` は部門別労働生産性の**水準**パラメータであり、その変更は定常水準の移動であって成長率の変更ではない。`ai_exp` は米国 AI 設備投資期待の外生入力であり日本の生産性 assumption ではない（G-02・G-12）。",
        inputs = [
            JapanFiscalInputMapping(;
                concept = :productivity_growth,
                input_kind = :not_accepted,
                notes = "`st_lprod_s` は水準パラメータであり成長率ではない。`ai_exp` を生産性成長の代理に用いない（G-12）。",
            ),
        ],
        missing_channels = [
            "成長regime（baseline が成長率ゼロ）",
            "政府部門（G-01）",
            "一般物価",
        ],
        gap_ids = ["G-01", "G-02", "G-03", "G-12"],
    ),

    # -----------------------------------------------------------------
    # F5: JGB funding-cost ショック
    # -----------------------------------------------------------------
    JapanFiscalModelMapping(;
        family = :jgb_funding_cost,
        model = :ramsey,
        representability = :not_representable,
        reason = "外生の金利入力を持たない（実質利子率は `1/β + δ − 1` として内生）。政府部門・国債も持たない。",
        missing_channels = ["外生金利", "政府部門・国債", "期間構造"],
        gap_ids = ["G-01", "G-06"],
    ),
    JapanFiscalModelMapping(;
        family = :jgb_funding_cost,
        model = :rbc,
        representability = :not_representable,
        reason = "外生の金利入力を持たない（実質利子率は内生）。名目長期金利・政府部門・国債も持たない。",
        missing_channels = ["外生金利", "政府部門・国債", "名目変数"],
        gap_ids = ["G-01", "G-06"],
    ),
    JapanFiscalModelMapping(;
        family = :jgb_funding_cost,
        model = :solow,
        representability = :not_representable,
        reason = "金利を一切持たない実物成長モデルであり、funding コストの入力が存在しない。",
        missing_channels = ["金利", "政府部門・国債"],
        gap_ids = ["G-01", "G-06"],
    ),
    JapanFiscalModelMapping(;
        family = :jgb_funding_cost,
        model = :islm,
        representability = :not_representable,
        reason = "金利 `r` は単一の内生変数であり、政策金利とも長期金利とも同定されない。外生の長期金利ショックを受け取る入力が無い。",
        inputs = [
            JapanFiscalInputMapping(;
                concept = :long_rate_funding_condition,
                input_kind = :not_accepted,
                notes = "`r` を JGB 利回りとして解釈しない。単一の内生金利であり、政策金利とも長期金利とも同定されない。",
            ),
        ],
        missing_channels = ["外生金利・期間構造", "政府債務ストック"],
        gap_ids = ["G-01", "G-06"],
    ),
    JapanFiscalModelMapping(;
        family = :jgb_funding_cost,
        model = :adas,
        representability = :not_representable,
        reason = "IS-LM と同じく金利 `r` は単一の内生変数であり、外生の長期金利ショックを受け取る入力が無い。",
        inputs = [
            JapanFiscalInputMapping(;
                concept = :long_rate_funding_condition,
                input_kind = :not_accepted,
                notes = "`r` を JGB 利回りとして解釈しない（G-06）。",
            ),
        ],
        missing_channels = ["外生金利・期間構造", "政府債務ストック"],
        gap_ids = ["G-01", "G-06"],
    ),
    JapanFiscalModelMapping(;
        family = :jgb_funding_cost,
        model = :new_keynesian,
        representability = :not_representable,
        reason = "期間構造を持たず、名目金利は Taylor rule で決まる 1 期物政策金利のみである。`:monetary` ショックを長期金利ショックの代理に用いると、#274 が分離を求めている政策金利と長期金利を同一視することになる（G-06）。",
        inputs = [
            JapanFiscalInputMapping(;
                concept = :long_rate_funding_condition,
                input_kind = :not_accepted,
                notes = "`:monetary` ショックは短期政策金利への innovation であり長期金利ではない（G-06）。",
            ),
        ],
        missing_channels = ["期間構造・長期金利", "政府債務ストック（G-01）"],
        gap_ids = ["G-01", "G-06"],
    ),
    JapanFiscalModelMapping(;
        family = :jgb_funding_cost,
        model = :var,
        representability = :not_representable,
        reason = _JF_VAR_REASON,
        gap_ids = ["G-10"],
    ),
    JapanFiscalModelMapping(;
        family = :jgb_funding_cost,
        model = :mundell_fleming,
        representability = :not_representable,
        reason = "`r_star` は世界利子率であり日本の長期 JGB 利回りではない。これを JGB 利回りの代理に用いることは禁止代理である（G-08）。国内長期金利を独立に動かす入力は存在しない。",
        inputs = [
            JapanFiscalInputMapping(;
                concept = :long_rate_funding_condition,
                input_kind = :not_accepted,
                notes = "`r_star` を JGB 利回りの代理に用いない（G-08）。小国・完全資本移動の仮定は日本の国債国内消化と整合しない。",
            ),
        ],
        missing_channels = ["国内長期金利", "政府債務ストック", "期間構造"],
        gap_ids = ["G-01", "G-06", "G-08"],
    ),
    JapanFiscalModelMapping(;
        family = :jgb_funding_cost,
        model = :keen,
        representability = :partial,
        adoption = :supporting,
        calibration_basis = :structural_illustrative,
        claim_level = :direction_only,
        reason = "実質貸出金利 `r` として private pass-through leg（民間の実効借入コスト上昇）を受け取れるが、政府部門を持たないため sovereign leg（政府の調達コスト・利払費）と財政収支を返さない（G-01）。金利の時間形状も与えられない（G-09）。",
        inputs = [
            JapanFiscalInputMapping(;
                concept = :long_rate_funding_condition,
                variable = :r,
                input_kind = :model_parameter,
                unit = "annualized real rate (decimal)",
                horizon = :continuous_year,
                conversion = "`FundingShockComponents` の bp を年率実質金利へ換算する（bp/10000）。`r` は実質金利であるため、名目長期金利の変化をそのまま渡さず、用いた期待インフレを記録する。pass-through 係数は Keen について較正されていない。",
                notes = "スカラー定数のため恒久的ステップ変化としてのみ表現する（G-09）。",
            ),
        ],
        baseline_requirements = [
            "baseline は良い均衡（`steady_state`）またはその近傍の初期値。`r` 以外のパラメータと積分区間を一致させる。",
        ],
        endogenous_outputs = [:private_debt, :employment],
        missing_channels = [
            "政府部門・国債・利払費（G-01）",
            "名目変数・期間構造",
            "金利の時間形状（G-09）",
        ],
        parameterization_requirements = [
            "双安定性のため `r` の ±50% 感応度と初期値の感応度を必ず併記する。",
            "名目 bp → 実質金利の換算に用いた期待インフレを assumption として記録する。",
        ],
        japan_caveats = [
            "実証較正は米国基準のみ（G-02）。日本の民間債務比率・雇用率へ合わせた較正は存在しない。",
        ],
        can_state = [
            "民間の実効実質借入コストの恒久的な上昇が、民間債務比率と雇用率を崩壊経路へ向かわせるかどうかの方向。",
        ],
        cannot_state = [
            "政府の調達コスト・利払費・財政収支（G-01・G-14）。",
            "金利の時間形状に依存する結果（G-09）。",
            "危機の発生時期・発生確率。",
        ],
        gap_ids = ["G-01", "G-02", "G-06", "G-09", "G-14"],
    ),
    JapanFiscalModelMapping(;
        family = :jgb_funding_cost,
        model = :sim,
        representability = :not_representable,
        reason = "金利を一切持たない（金融資産は無利子の政府貨幣 `H` のみ）。政府の調達コストという概念が存在しない。",
        missing_channels = ["金利", "国債・利払費"],
        gap_ids = ["G-01", "G-06"],
    ),
    JapanFiscalModelMapping(;
        family = :jgb_funding_cost,
        model = :capex_credit_cycle,
        representability = :partial,
        adoption = :primary,
        calibration_basis = :non_japan_calibrated,
        claim_level = :direction_and_relative_timing,
        reason = "`:LongRateFundingShock` → `spread_shock_ex`（bp、加算合成）として private pass-through leg を期別パスで受け取れる唯一のモデルであり、ADR 0019 の観測分解・pass-through 契約をそのまま再利用できる。一方 sovereign leg（政府の調達コスト・利払費・財政収支）は政府部門が無いため返さない（G-01・G-14）。",
        inputs = [
            JapanFiscalInputMapping(;
                concept = :long_rate_funding_condition,
                variable = :spread_shock_ex,
                input_kind = :exogenous_path,
                unit = "bp",
                horizon = :quarterly,
                conversion = "`FundingShockComponents`（`long_nominal_yield_shift_bps` 必須・`secured_funding_spread_shift_bps` 必須・実質/BEI は欠測可）から `funding_shock_magnitude_bps` と `FundingShockPassThrough` を経て bp を算出し、`:LongRateFundingShock` として `spread_shock_ex` へ加算合成する（ADR 0019）。",
                notes = "日本へ再利用できるのはイベント型・`FundingShockComponents`・`FundingShockPassThrough`（いずれもモデル非依存）まで。`spread_shock_ex` への写像規則・観測系列・逆較正は米国固有である（G-14・G-15・G-02）。",
            ),
            JapanFiscalInputMapping(;
                concept = :policy_rate,
                variable = :policy_rate,
                input_kind = :exogenous_path,
                unit = "% (annualized)",
                horizon = :quarterly,
                conversion = "`:PolicyRateChange` から期別の外生パスを構成する。長期金利ショックと独立に指定でき、`allowed_target_concepts` により型レベルで分離が保証される（ADR 0019 決定 6）。",
            ),
        ],
        baseline_requirements = [
            "baseline は成長率ゼロの定常状態（ADR 0011）。逆較正の 48 target キーは米国 NIPA 由来である（G-02）。",
            "baseline と scenario で model version・パラメータ・初期状態・ホライズンを一致させる。",
        ],
        endogenous_outputs = [
            :private_borrowing_cost,
            :output,
            :private_debt,
            :investment,
            :employment,
        ],
        missing_channels = [
            "政府部門・国債・利払費（G-01）",
            "sovereign leg 全体（G-14）",
            "イールドカーブの形状（G-06）",
            "一般物価",
        ],
        parameterization_requirements = [
            "`FundingShockPassThrough` の既定係数 1.0 は日本について較正されていない。±50% の感応度併記を必須とする。",
            "日本の観測系列（10年 JGB 利回り・TONA/GC レポ・日銀政策金利・JGB breakeven）は未実装のため、`FundingShockComponents` は観測からではなく明示的 Scenario Assumption として与える（G-15）。",
            "`decomposition_residual_bps` を term premium と呼ばない（ADR 0019 決定 4）。",
        ],
        japan_caveats = [
            "部門 S1–S5 は米国の AI・半導体 CAPEX 循環を対象としており、日本の産業構造へ対応付けられていない（G-02）。",
            "`spread_shock_ex` は企業の実効借入コストへの加算であり、政府の調達コストではない（G-14）。",
        ],
        can_state = [
            "長期金利・funding 条件の上昇が企業の実効借入コスト・CAPEX・部門別産出へ及ぼす方向と相対的な時間形状。",
            "政策金利を動かさずに長期金利だけを動かした場合と、両方を動かした場合の差（`allowed_target_concepts` による型レベルの分離が保証する）。",
        ],
        cannot_state = [
            "政府の調達コスト・利払費・債務残高への影響（G-01・G-14）。",
            "日本の量としての企業借入コスト・投資の変化幅（G-02）。",
            "イールドカーブの形状変化（G-06）。",
        ],
        gap_ids = ["G-01", "G-02", "G-06", "G-14", "G-15"],
    ),
]

# ---------------------------------------------------------------------------
# registry 健全性検査（load 時に落とす）
# ---------------------------------------------------------------------------

let
    seen = Set{Tuple{Symbol, Symbol}}()
    for m in JAPAN_FISCAL_MODEL_MAPPINGS
        key = (m.family, m.model)
        key in seen && error("JAPAN_FISCAL_MODEL_MAPPINGS に重複したセルがあります: $(key)")
        push!(seen, key)
    end
    expected = Set(
        (f, mo) for f in JAPAN_FISCAL_SCENARIO_FAMILIES for
        mo in JAPAN_FISCAL_CANDIDATE_MODELS
    )
    missing_cells = sort!(collect(setdiff(expected, seen)))
    isempty(missing_cells) || error(
        "JAPAN_FISCAL_MODEL_MAPPINGS に未登録のセルがあります（$(length(missing_cells)) 件）: $(missing_cells)。" *
        "5 scenario family × 11 候補モデルの全組み合わせに representability 判定が必要（Issue #274 受け入れ条件）。",
    )
end

let
    known = Set(g.gap_id for g in JAPAN_FISCAL_GAP_REGISTER)
    ids = [g.gap_id for g in JAPAN_FISCAL_GAP_REGISTER]
    length(unique(ids)) == length(ids) ||
        error("JAPAN_FISCAL_GAP_REGISTER に重複した gap_id があります: $(ids)")
    for m in JAPAN_FISCAL_MODEL_MAPPINGS
        bad = setdiff(Set(m.gap_ids), known)
        isempty(bad) || error(
            "未登録の gap_id を参照しています: $(sort(collect(bad)))（family=$(m.family), model=$(m.model)）",
        )
    end
    for (family, spec) in JAPAN_FISCAL_FAMILY_REGISTRY
        bad = setdiff(Set(spec.gap_ids), known)
        isempty(bad) || error(
            "未登録の gap_id を参照しています: $(sort(collect(bad)))（family=$family）",
        )
    end
end

let
    # 日本較正済みモデルが存在しないため、`:magnitude` を名乗るセルは 1 つも無い（G-02）。
    bad = [
        (m.family, m.model) for
        m in JAPAN_FISCAL_MODEL_MAPPINGS if m.claim_level === :magnitude
    ]
    isempty(bad) || error(
        "claim_level=:magnitude のセルが存在します: $(bad)。日本較正済みモデルは無い（G-02）。",
    )
    # family ごとに実装候補が 1 つ以上あるか、全セルが :not_representable であること。
    for family in JAPAN_FISCAL_SCENARIO_FAMILIES
        cells = [m for m in JAPAN_FISCAL_MODEL_MAPPINGS if m.family === family]
        adopted = [m for m in cells if m.adoption !== :not_adopted]
        all_nr = all(m -> m.representability === :not_representable, cells)
        (!isempty(adopted) || all_nr) || error(
            "family=$family に実装候補（adoption != :not_adopted）が無く、全セルが :not_representable でもありません。" *
            "Issue #274 受け入れ条件（family ごとに少なくとも 1 つの実装候補、または明示的 not_representable 結論）を満たしていません。",
        )
        count(m -> m.adoption === :primary, cells) <= 1 || error(
            "family=$family に :primary が複数あります。Phase 3 の主候補は 1 つに絞る。",
        )
    end
end

# ===========================================================================
# 照会 API
# ===========================================================================

"""
    japan_fiscal_model_mappings(; family=nothing, model=nothing,
                                representability=nothing, adoption=nothing)
        -> Vector{JapanFiscalModelMapping}

capability matrix を絞り込んで返す。すべて `nothing` なら 55 セル全件（宣言順）。
"""
function japan_fiscal_model_mappings(;
    family::Union{Symbol, Nothing} = nothing,
    model::Union{Symbol, Nothing} = nothing,
    representability::Union{Symbol, Nothing} = nothing,
    adoption::Union{Symbol, Nothing} = nothing,
)
    family === nothing ||
        _jf_check(family, JAPAN_FISCAL_SCENARIO_FAMILIES, "scenario family")
    model === nothing || _jf_check(model, JAPAN_FISCAL_CANDIDATE_MODELS, "model")
    representability === nothing ||
        _jf_check(representability, JAPAN_FISCAL_REPRESENTABILITY, "representability")
    adoption === nothing || _jf_check(adoption, JAPAN_FISCAL_ADOPTIONS, "adoption")
    out = JapanFiscalModelMapping[]
    for m in JAPAN_FISCAL_MODEL_MAPPINGS
        family === nothing || m.family === family || continue
        model === nothing || m.model === model || continue
        representability === nothing || m.representability === representability || continue
        adoption === nothing || m.adoption === adoption || continue
        push!(out, m)
    end
    return out
end

"""
    japan_fiscal_model_mapping(family::Symbol, model::Symbol) -> JapanFiscalModelMapping

1 セルの判定を返す。未登録の組み合わせは `ArgumentError`。
"""
function japan_fiscal_model_mapping(family::Symbol, model::Symbol)
    _jf_check(family, JAPAN_FISCAL_SCENARIO_FAMILIES, "scenario family")
    _jf_check(model, JAPAN_FISCAL_CANDIDATE_MODELS, "model")
    idx = findfirst(
        m -> m.family === family && m.model === model,
        JAPAN_FISCAL_MODEL_MAPPINGS,
    )
    idx === nothing && throw(ArgumentError("未登録のセル: family=$family, model=$model"))
    return JAPAN_FISCAL_MODEL_MAPPINGS[idx]
end

"""
    japan_fiscal_representability(family::Symbol, model::Symbol) -> Symbol

1 セルの representability（`JAPAN_FISCAL_REPRESENTABILITY`）を返す。
"""
japan_fiscal_representability(family::Symbol, model::Symbol) =
    japan_fiscal_model_mapping(family, model).representability

"""
    japan_fiscal_unsupported_concepts(family::Symbol, model::Symbol) -> Vector{Symbol}

family が必要とする assumption 概念のうち、そのモデルが受け取れないもの。
`#276` の adapter はこれを silent ignore せず unsupported として返さなければならない。
"""
function japan_fiscal_unsupported_concepts(family::Symbol, model::Symbol)
    m = japan_fiscal_model_mapping(family, model)
    required = japan_fiscal_family_spec(family).required_concepts
    accepted = Set(japan_fiscal_accepted_concepts(m))
    return Symbol[c for c in required if !(c in accepted)]
end

"""
    japan_fiscal_unsupported_outputs(family::Symbol, model::Symbol) -> Vector{Symbol}

family が判定に必要とする出力概念のうち、そのモデルが返さないもの。`:partial` のセルは
概念側・出力側のどちらか（または両方）が欠けている。

例: `(:jgb_funding_cost, :capex_credit_cycle)` は required concept をすべて受け取るが、
`:government_balance`（sovereign leg の利払費・財政収支）を返さないため `:partial` である。
"""
function japan_fiscal_unsupported_outputs(family::Symbol, model::Symbol)
    m = japan_fiscal_model_mapping(family, model)
    required = japan_fiscal_family_spec(family).required_outputs
    produced = Set(m.endogenous_outputs)
    return Symbol[o for o in required if !(o in produced)]
end

"""
    japan_fiscal_implementation_candidates(family::Symbol) -> Vector{Symbol}

Phase 3（#276）で実装するモデル（`adoption != :not_adopted`）を `:primary` を先頭にして返す。
空ベクトルは「この family に実装候補が無い（全セル `:not_representable`）」を意味する。
"""
function japan_fiscal_implementation_candidates(family::Symbol)
    cells = japan_fiscal_model_mappings(; family = family)
    primary = Symbol[m.model for m in cells if m.adoption === :primary]
    supporting = Symbol[m.model for m in cells if m.adoption === :supporting]
    return vcat(primary, supporting)
end

# ===========================================================================
# 機械可読 export（to_dict / to_json）
# ===========================================================================

to_dict(c::JapanFiscalAssumptionConcept) = Dict{String, Any}(
    "concept" => _jf_sym(c.concept),
    "display_name" => c.display_name,
    "definition" => c.definition,
    "unit" => c.unit,
    "basis" => _jf_sym(c.basis),
    "event_target_concept" =>
        c.event_target_concept === nothing ? nothing : _jf_sym(c.event_target_concept),
    "zero_vs_missing" => c.zero_vs_missing,
    "doc_ref" => c.doc_ref,
)

to_dict(i::JapanFiscalInputMapping) = Dict{String, Any}(
    "concept" => _jf_sym(i.concept),
    "variable" => _jf_sym(i.variable),
    "input_kind" => _jf_sym(i.input_kind),
    "unit" => i.unit,
    "horizon" => _jf_sym(i.horizon),
    "conversion" => i.conversion,
    "notes" => i.notes,
)

function to_dict(m::JapanFiscalModelMapping)
    return Dict{String, Any}(
        "family" => _jf_sym(m.family),
        "model" => _jf_sym(m.model),
        "representability" => _jf_sym(m.representability),
        "adoption" => _jf_sym(m.adoption),
        "accepted_concepts" => _jf_syms(japan_fiscal_accepted_concepts(m)),
        "unsupported_concepts" =>
            _jf_syms(japan_fiscal_unsupported_concepts(m.family, m.model)),
        "unsupported_outputs" =>
            _jf_syms(japan_fiscal_unsupported_outputs(m.family, m.model)),
        "inputs" => [to_dict(i) for i in m.inputs],
        "calibration_basis" => _jf_sym(m.calibration_basis),
        "claim_level" => _jf_sym(m.claim_level),
        "baseline_requirements" => copy(m.baseline_requirements),
        "endogenous_outputs" => _jf_syms(m.endogenous_outputs),
        "missing_channels" => copy(m.missing_channels),
        "parameterization_requirements" => copy(m.parameterization_requirements),
        "japan_caveats" => copy(m.japan_caveats),
        "can_state" => copy(m.can_state),
        "cannot_state" => copy(m.cannot_state),
        "gap_ids" => copy(m.gap_ids),
        "reason" => m.reason,
        "doc_ref" => m.doc_ref,
    )
end

to_dict(s::JapanFiscalScenarioFamilySpec) = Dict{String, Any}(
    "family" => _jf_sym(s.family),
    "display_name" => s.display_name,
    "economic_meaning" => s.economic_meaning,
    "required_concepts" => _jf_syms(s.required_concepts),
    "optional_concepts" => _jf_syms(s.optional_concepts),
    "required_outputs" => _jf_syms(s.required_outputs),
    "unsupported_outputs" => _jf_syms(s.unsupported_outputs),
    "decomposition_rule" => s.decomposition_rule,
    "forbidden_proxies" => copy(s.forbidden_proxies),
    "guardrails" => copy(s.guardrails),
    "gap_ids" => copy(s.gap_ids),
    "doc_ref" => s.doc_ref,
)

to_dict(g::JapanFiscalGap) = Dict{String, Any}(
    "gap_id" => g.gap_id,
    "title" => g.title,
    "description" => g.description,
    "affected_families" => _jf_syms(g.affected_families),
    "affected_models" => _jf_syms(g.affected_models),
    "consequence" => g.consequence,
    "resolution" => _jf_sym(g.resolution),
    "doc_ref" => g.doc_ref,
)

to_json(c::JapanFiscalAssumptionConcept) = JSON3.write(to_dict(c))
to_json(i::JapanFiscalInputMapping) = JSON3.write(to_dict(i))
to_json(m::JapanFiscalModelMapping) = JSON3.write(to_dict(m))
to_json(s::JapanFiscalScenarioFamilySpec) = JSON3.write(to_dict(s))
to_json(g::JapanFiscalGap) = JSON3.write(to_dict(g))

"""
    japan_fiscal_capability_matrix() -> Dict{String,Any}

capability / mapping contract 全体を 1 つの機械可読 Dict として返す。
`#275` の scenario artifact は `contract_version` を model capability decision version として
参照し、`#276` の adapter は `mappings` の `accepted_concepts` / `unsupported_concepts` /
`inputs` を実装の正本として参照する。

キー:
`contract_version` / `fre_context_role` / `forbidden_magnitude_sources` /
`forbidden_magnitude_input_fields` / `families` / `assumption_concepts` / `mappings` / `gaps` /
`vocabularies`。
"""
function japan_fiscal_capability_matrix()
    return Dict{String, Any}(
        "contract_version" => JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION,
        "fre_context_role" => _jf_sym(JAPAN_FISCAL_FRE_CONTEXT_ROLE),
        "forbidden_magnitude_sources" => _jf_syms(JAPAN_FISCAL_FORBIDDEN_MAGNITUDE_SOURCES),
        "forbidden_magnitude_input_fields" =>
            String[f for f in JAPAN_FISCAL_FORBIDDEN_MAGNITUDE_INPUT_FIELDS],
        "families" => [
            to_dict(JAPAN_FISCAL_FAMILY_REGISTRY[f]) for f in JAPAN_FISCAL_SCENARIO_FAMILIES
        ],
        "assumption_concepts" => [
            to_dict(JAPAN_FISCAL_ASSUMPTION_CONCEPT_REGISTRY[c]) for
            c in JAPAN_FISCAL_ASSUMPTION_CONCEPTS
        ],
        "mappings" => [to_dict(m) for m in JAPAN_FISCAL_MODEL_MAPPINGS],
        "gaps" => [to_dict(g) for g in JAPAN_FISCAL_GAP_REGISTER],
        "vocabularies" => Dict{String, Any}(
            "scenario_families" => _jf_syms(JAPAN_FISCAL_SCENARIO_FAMILIES),
            "candidate_models" => _jf_syms(JAPAN_FISCAL_CANDIDATE_MODELS),
            "assumption_concepts" => _jf_syms(JAPAN_FISCAL_ASSUMPTION_CONCEPTS),
            "output_concepts" => _jf_syms(JAPAN_FISCAL_OUTPUT_CONCEPTS),
            "representability" => _jf_syms(JAPAN_FISCAL_REPRESENTABILITY),
            "adoptions" => _jf_syms(JAPAN_FISCAL_ADOPTIONS),
            "input_kinds" => _jf_syms(JAPAN_FISCAL_INPUT_KINDS),
            "horizons" => _jf_syms(JAPAN_FISCAL_HORIZONS),
            "calibration_bases" => _jf_syms(JAPAN_FISCAL_CALIBRATION_BASES),
            "claim_levels" => _jf_syms(JAPAN_FISCAL_CLAIM_LEVELS),
            "gap_resolutions" => _jf_syms(JAPAN_FISCAL_GAP_RESOLUTIONS),
        ),
    )
end
