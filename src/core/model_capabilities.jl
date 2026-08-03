# model_capabilities.jl: モデル能力プロファイル・概念定義 metadata 層（Issue #149 / Phase 5）
#
# 各モデルが内生化する部門・金融機構・期待形成・政策変数・対応 API・実証能力を、
# LLM やクロスモデル推論が根拠にできる機械可読な repository metadata として提供する。
#
# 設計方針（Issue #149 受け入れ条件）:
#   - 能力を推測で過大申告しない。未対応は明示的に false / :none / 空とする。
#   - 同名変数でも定義が異なれば同一概念として扱わない（`definition_key` で判定）。
#   - 既存モデル API（model_name / state_variables / parameters …）は変更しない。
#   - docs（モデル節・限界節・model_selection_guide・variable_mapping・simulation_outputs）
#     のみを根拠とする。数値実証結果は含めない。
#
# 依存: core/model_interface.jl（AbstractMacroModel）と各モデル型。llm 層には依存しない。
# 参照: docs/model_capabilities.md（比較表・追加手順）、ADR 0006（クロスモデル推論）。

# ===========================================================================
# 契約 version と固定語彙
# ===========================================================================

const MODEL_CAPABILITY_CONTRACT_VERSION = "model-capability/1.0.0"

# 時間表現
const CAPABILITY_TIME_REPRESENTATIONS = (:static, :discrete, :continuous)

# 対応 API（統一計算 API + 実証パイプライン）
const CAPABILITY_APIS = (
    :steady_state,
    :transition_path,
    :simulate,
    :impulse_response,
    :calibration,
    :validation,
)

# 部門
const CAPABILITY_SECTORS = (:household, :firm, :government, :bank, :central_bank, :external)

# 金融商品
const CAPABILITY_INSTRUMENTS = (:money, :debt, :bond, :loan, :deposit)

# 会計閉鎖の程度
const CAPABILITY_ACCOUNTING_CLOSURES = (:none, :partial, :stock_flow_consistent)

# 経済メカニズムの扱い（保守的。未対応は :none）
#   :endogenous  … モデル内部で内生的に決定
#   :approximate … 近似・代理・部分的に扱う（例: 需要決定 Y、静的要素分配）
#   :exogenous   … 外生パラメータ/系列として与える
#   :none        … 扱わない
const CAPABILITY_TREATMENTS = (:endogenous, :approximate, :exogenous, :none)

# 期待形成
const CAPABILITY_EXPECTATIONS = (:none, :static, :adaptive, :rational, :perfect_foresight)

# 最適化の主体
const CAPABILITY_OPTIMIZATION = (:none, :household, :firm, :both)

# 均衡概念（開いた語彙。machine-readable のため Symbol で保持）
const CAPABILITY_EQUILIBRIUM_CONCEPTS = (
    :none,
    :static_equilibrium,       # IS-LM / AD-AS / Mundell-Fleming の静学均衡
    :saddle_path,              # Ramsey / RBC の鞍点安定
    :balanced_growth,          # Solow の均斉成長（効率労働単位）
    :zero_gap,                 # New Keynesian のゼロギャップ偏差均衡
    :linear_fixed_point,       # VAR の線形固定点
    :bistable_with_crisis,     # Keen の双安定（危機regime を含む）
    :stock_flow_steady_state,  # SIM の会計整合定常状態
)

# 概念定義（ModelConceptDefinition）用の語彙
const CONCEPT_KINDS = (:stock, :flow, :rate, :ratio, :index)  # stock/flow/rate が中核、比率・指数を追加
const CONCEPT_TIMINGS = (:end_of_period, :current_flow, :instantaneous, :static)
const CONCEPT_ENDOGENEITY = (:endogenous, :exogenous, :parameter)
const CONCEPT_OBSERVABILITY = (:observable, :partially_observable, :latent, :model_only)

# ===========================================================================
# ModelCapabilityProfile
# ===========================================================================

"""
    ModelCapabilityProfile

あるモデルが内生化する部門・金融機構・期待形成・政策変数・対応 API・実証能力を表す
機械可読な repository metadata。保守的に符号化し、未対応は `false` / `:none` / 空とする。

## フィールド
- `model::Symbol` : モデル識別子（`:ramsey`, `:keen`, `:sim` …）
- `model_type::Symbol` : Julia 型名（`:RamseyModel` …）
- `display_name::String` : 表示名
- `time_representation::Symbol` : `CAPABILITY_TIME_REPRESENTATIONS`
- `time_unit::Union{String,Nothing}` : 期間単位（`"quarterly"`, `"year"`, `"period"`, static は `nothing`）
- `apis::Vector{Symbol}` : 実装する `CAPABILITY_APIS` の部分集合
- `sectors::Vector{Symbol}` : 内生化する `CAPABILITY_SECTORS` の部分集合
- `instruments::Vector{Symbol}` : 扱う `CAPABILITY_INSTRUMENTS` の部分集合
- `endogenous_credit::Bool` : 内生信用創造の有無
- `accounting_closure::Symbol` : `CAPABILITY_ACCOUNTING_CLOSURES`
- `production` / `employment` / `income_distribution` / `prices` /
  `monetary_policy` / `fiscal_policy` / `external_sector` : 各 `CAPABILITY_TREATMENTS`
- `expectations::Symbol` : `CAPABILITY_EXPECTATIONS`
- `optimization::Symbol` : `CAPABILITY_OPTIMIZATION`
- `behavioral_equations::Bool` : アドホックな行動方程式を持つか
- `equilibrium_concept::Symbol` : `CAPABILITY_EQUILIBRIUM_CONCEPTS`
- `data_connection::Bool` / `estimation::Bool` / `out_of_sample_validation::Bool` : 実証能力
- `doc_ref::String` : 根拠 docs パス・節
- `caveats::Vector{String}` : 限界・注意
- `metadata::Dict{String,Any}` : 自由記述の付随情報
"""
struct ModelCapabilityProfile
    model::Symbol
    model_type::Symbol
    display_name::String
    time_representation::Symbol
    time_unit::Union{String, Nothing}
    apis::Vector{Symbol}
    sectors::Vector{Symbol}
    instruments::Vector{Symbol}
    endogenous_credit::Bool
    accounting_closure::Symbol
    production::Symbol
    employment::Symbol
    income_distribution::Symbol
    prices::Symbol
    monetary_policy::Symbol
    fiscal_policy::Symbol
    external_sector::Symbol
    expectations::Symbol
    optimization::Symbol
    behavioral_equations::Bool
    equilibrium_concept::Symbol
    data_connection::Bool
    estimation::Bool
    out_of_sample_validation::Bool
    doc_ref::String
    caveats::Vector{String}
    metadata::Dict{String, Any}
end

_cap_check(val, vocab, field) =
    val in vocab || throw(ArgumentError("未知の $field: $(repr(val))（有効: $(vocab)）"))

function _cap_check_subset(vals, vocab, field)
    for v in vals
        v in vocab ||
            throw(ArgumentError("未知の $field 要素: $(repr(v))（有効: $(vocab)）"))
    end
    return vals
end

function ModelCapabilityProfile(;
    model::Symbol,
    model_type::Symbol,
    display_name::String,
    time_representation::Symbol,
    time_unit::Union{String, Nothing} = nothing,
    apis::Vector{Symbol} = Symbol[],
    sectors::Vector{Symbol} = Symbol[],
    instruments::Vector{Symbol} = Symbol[],
    endogenous_credit::Bool = false,
    accounting_closure::Symbol = :none,
    production::Symbol = :none,
    employment::Symbol = :none,
    income_distribution::Symbol = :none,
    prices::Symbol = :none,
    monetary_policy::Symbol = :none,
    fiscal_policy::Symbol = :none,
    external_sector::Symbol = :none,
    expectations::Symbol = :none,
    optimization::Symbol = :none,
    behavioral_equations::Bool = false,
    equilibrium_concept::Symbol = :none,
    data_connection::Bool = false,
    estimation::Bool = false,
    out_of_sample_validation::Bool = false,
    doc_ref::String = "",
    caveats::Vector{String} = String[],
    metadata::Dict{String, Any} = Dict{String, Any}(),
)
    _cap_check(time_representation, CAPABILITY_TIME_REPRESENTATIONS, "time_representation")
    _cap_check_subset(apis, CAPABILITY_APIS, "api")
    _cap_check_subset(sectors, CAPABILITY_SECTORS, "sector")
    _cap_check_subset(instruments, CAPABILITY_INSTRUMENTS, "instrument")
    _cap_check(accounting_closure, CAPABILITY_ACCOUNTING_CLOSURES, "accounting_closure")
    for (val, field) in (
        (production, "production"),
        (employment, "employment"),
        (income_distribution, "income_distribution"),
        (prices, "prices"),
        (monetary_policy, "monetary_policy"),
        (fiscal_policy, "fiscal_policy"),
        (external_sector, "external_sector"),
    )
        _cap_check(val, CAPABILITY_TREATMENTS, field)
    end
    _cap_check(expectations, CAPABILITY_EXPECTATIONS, "expectations")
    _cap_check(optimization, CAPABILITY_OPTIMIZATION, "optimization")
    _cap_check(equilibrium_concept, CAPABILITY_EQUILIBRIUM_CONCEPTS, "equilibrium_concept")
    return ModelCapabilityProfile(
        model,
        model_type,
        display_name,
        time_representation,
        time_unit,
        apis,
        sectors,
        instruments,
        endogenous_credit,
        accounting_closure,
        production,
        employment,
        income_distribution,
        prices,
        monetary_policy,
        fiscal_policy,
        external_sector,
        expectations,
        optimization,
        behavioral_equations,
        equilibrium_concept,
        data_connection,
        estimation,
        out_of_sample_validation,
        doc_ref,
        caveats,
        metadata,
    )
end

"""
    supports_api(p::ModelCapabilityProfile, api::Symbol) -> Bool

プロファイルが `api`（`CAPABILITY_APIS` の 1 つ）を実装するか。
"""
supports_api(p::ModelCapabilityProfile, api::Symbol) = api in p.apis

"""
    has_sector(p::ModelCapabilityProfile, sector::Symbol) -> Bool

プロファイルが `sector` を内生化するか。
"""
has_sector(p::ModelCapabilityProfile, sector::Symbol) = sector in p.sectors

"""
    has_instrument(p::ModelCapabilityProfile, instrument::Symbol) -> Bool

プロファイルが `instrument` を扱うか。
"""
has_instrument(p::ModelCapabilityProfile, instrument::Symbol) = instrument in p.instruments

# ===========================================================================
# ModelConceptDefinition
# ===========================================================================

"""
    ModelConceptDefinition

あるモデルの 1 変数・概念の定義。安定した `concept_id` を持ち、モデル内変数名・定義・単位・
stock/flow/rate・時点・集計範囲・内生/外生・観測可能性・proxy 注意事項を保持する。

同じ `Y` や `debt` という名前でも定義が異なる場合は同一概念として扱わない。等価性は
`definition_key`（および単位・kind・時点）の一致で判定する（[`concept_definitions_equivalent`](@ref)）。

## フィールド
- `concept_id::Symbol` : グローバルに安定・一意な概念 id（例 `:ramsey_capital_K`）
- `model::Symbol` : モデル識別子
- `variable::Symbol` : モデル内の変数名（`state_variables` / `control_variables` と対応）
- `definition::String` : docs 由来の短い定義
- `unit::Union{String,Nothing}` : 単位（`"ratio"`, `"level (real)"` …）
- `kind::Symbol` : `CONCEPT_KINDS`
- `timing::Symbol` : `CONCEPT_TIMINGS`
- `aggregation::String` : 集計範囲（`"aggregate economy"`, `"household sector"` …）
- `endogeneity::Symbol` : `CONCEPT_ENDOGENEITY`
- `observability::Symbol` : `CONCEPT_OBSERVABILITY`
- `definition_key::Symbol` : 等価判定用の正準キー（定義が真に一致する場合のみ同一値）
- `proxy_caveats::Vector{String}` : proxy・観測上の注意
- `doc_ref::String` : 根拠 docs パス・節
"""
struct ModelConceptDefinition
    concept_id::Symbol
    model::Symbol
    variable::Symbol
    definition::String
    unit::Union{String, Nothing}
    kind::Symbol
    timing::Symbol
    aggregation::String
    endogeneity::Symbol
    observability::Symbol
    definition_key::Symbol
    proxy_caveats::Vector{String}
    doc_ref::String
end

function ModelConceptDefinition(;
    concept_id::Symbol,
    model::Symbol,
    variable::Symbol,
    definition::String,
    definition_key::Symbol,
    kind::Symbol,
    timing::Symbol,
    endogeneity::Symbol,
    observability::Symbol,
    unit::Union{String, Nothing} = nothing,
    aggregation::String = "aggregate economy",
    proxy_caveats::Vector{String} = String[],
    doc_ref::String = "",
)
    _cap_check(kind, CONCEPT_KINDS, "kind")
    _cap_check(timing, CONCEPT_TIMINGS, "timing")
    _cap_check(endogeneity, CONCEPT_ENDOGENEITY, "endogeneity")
    _cap_check(observability, CONCEPT_OBSERVABILITY, "observability")
    return ModelConceptDefinition(
        concept_id,
        model,
        variable,
        definition,
        unit,
        kind,
        timing,
        aggregation,
        endogeneity,
        observability,
        definition_key,
        proxy_caveats,
        doc_ref,
    )
end

"""
    concept_definitions_equivalent(a::ModelConceptDefinition, b::ModelConceptDefinition) -> Bool

2 つの概念定義が真に等価か。`definition_key`・`kind`・`unit`・`timing` がすべて一致する
場合のみ `true`。同名変数（例 両者 `:Y` や `:r`）でも `definition_key` が異なれば `false` を返し、
別定義の同一視を防ぐ（Issue #149・ADR 0006 §7）。
"""
function concept_definitions_equivalent(
    a::ModelConceptDefinition,
    b::ModelConceptDefinition,
)
    return a.definition_key === b.definition_key &&
           a.kind === b.kind &&
           a.unit == b.unit &&
           a.timing === b.timing
end

# ===========================================================================
# モデル識別子 ↔ 型
# ===========================================================================

const _CAPABILITY_MODEL_SYMBOLS = Dict{DataType, Symbol}(
    RamseyModel => :ramsey,
    RBCModel => :rbc,
    SolowModel => :solow,
    ISLMModel => :islm,
    ADASModel => :adas,
    NewKeynesianModel => :new_keynesian,
    VARModel => :var,
    MundellFlemingModel => :mundell_fleming,
    KeenModel => :keen,
    SIMModel => :sim,
    CapexCreditCycleModel => :capex_credit_cycle,
)

"""
    model_symbol(m::AbstractMacroModel) -> Symbol

モデルインスタンスから registry キー（`:ramsey` …）を返す。
"""
function model_symbol(m::AbstractMacroModel)
    haskey(_CAPABILITY_MODEL_SYMBOLS, typeof(m)) ||
        throw(ArgumentError("能力プロファイル未登録のモデル型: $(typeof(m))"))
    return _CAPABILITY_MODEL_SYMBOLS[typeof(m)]
end

# ===========================================================================
# MODEL_CAPABILITY_REGISTRY（docs のみを根拠。保守的に符号化）
# ===========================================================================

# 共通 caveat 断片
const _CAP_GENERIC_DATA_CAVEAT = "実データ接続は汎用の compare_with_data による出力比較を指す（推定・out-of-sample 検証は非対応）。"

const MODEL_CAPABILITY_REGISTRY = Dict{Symbol, ModelCapabilityProfile}(
    :ramsey => ModelCapabilityProfile(;
        model = :ramsey,
        model_type = :RamseyModel,
        display_name = "Ramsey 最適成長モデル",
        time_representation = :discrete,
        time_unit = "period",
        apis = [:steady_state, :transition_path, :simulate],
        sectors = [:household, :firm],
        production = :endogenous,
        income_distribution = :none,
        expectations = :perfect_foresight,
        optimization = :household,
        behavioral_equations = false,
        equilibrium_concept = :saddle_path,
        data_connection = true,
        doc_ref = "docs/models/ramsey.md",
        caveats = [
            "代表的家計の異時点間効用最大化。労働供給・貨幣・政府・対外部門を持たない実物モデル。",
            _CAP_GENERIC_DATA_CAVEAT,
        ],
    ),
    :rbc => ModelCapabilityProfile(;
        model = :rbc,
        model_type = :RBCModel,
        display_name = "RBC（実物的景気循環）モデル",
        time_representation = :discrete,
        time_unit = "quarterly",
        apis = [:steady_state, :transition_path, :impulse_response],
        sectors = [:household, :firm],
        production = :endogenous,
        employment = :endogenous,
        income_distribution = :approximate,
        expectations = :rational,
        optimization = :both,
        behavioral_equations = false,
        equilibrium_concept = :saddle_path,
        data_connection = true,
        doc_ref = "docs/models/rbc.md",
        caveats = [
            "要素分配 w,r は限界生産力による静的分配で分配動学は主眼ではない。金融摩擦・需要ショックは対象外。",
            _CAP_GENERIC_DATA_CAVEAT,
        ],
    ),
    :solow => ModelCapabilityProfile(;
        model = :solow,
        model_type = :SolowModel,
        display_name = "Solow 成長モデル",
        time_representation = :discrete,
        time_unit = "period",
        apis = [:steady_state, :transition_path, :simulate],
        sectors = [:household, :firm],
        production = :endogenous,
        employment = :exogenous,
        income_distribution = :approximate,
        expectations = :none,
        optimization = :none,
        behavioral_equations = true,
        equilibrium_concept = :balanced_growth,
        data_connection = true,
        doc_ref = "docs/models/solow.md",
        caveats = [
            "貯蓄率 s は固定の行動則で最適化しない。労働は率 n で外生成長、α は静的資本分配。",
            _CAP_GENERIC_DATA_CAVEAT,
        ],
    ),
    :islm => ModelCapabilityProfile(;
        model = :islm,
        model_type = :ISLMModel,
        display_name = "IS-LM モデル",
        time_representation = :static,
        time_unit = nothing,
        apis = [:steady_state, :simulate],
        sectors = [:household, :firm, :government, :central_bank],
        instruments = [:money],
        production = :approximate,
        prices = :none,
        monetary_policy = :endogenous,
        fiscal_policy = :endogenous,
        expectations = :none,
        optimization = :none,
        behavioral_equations = true,
        equilibrium_concept = :static_equilibrium,
        data_connection = true,
        doc_ref = "docs/models/islm.md",
        caveats = [
            "産出は需要決定（生産関数なし）、物価は固定。消費・投資・貨幣需要はアドホックな行動方程式。",
            _CAP_GENERIC_DATA_CAVEAT,
        ],
    ),
    :adas => ModelCapabilityProfile(;
        model = :adas,
        model_type = :ADASModel,
        display_name = "AD-AS モデル",
        time_representation = :static,
        time_unit = nothing,
        apis = [:steady_state, :simulate],
        sectors = [:household, :firm, :government, :central_bank],
        instruments = [:money],
        production = :approximate,
        employment = :approximate,
        prices = :endogenous,
        monetary_policy = :endogenous,
        fiscal_policy = :endogenous,
        expectations = :static,
        optimization = :none,
        behavioral_equations = true,
        equilibrium_concept = :static_equilibrium,
        data_connection = true,
        doc_ref = "docs/models/adas.md",
        caveats = [
            "期待物価 P_e は外生パラメータとして与える（内生更新しない）。AS 側の雇用は近似的。",
            _CAP_GENERIC_DATA_CAVEAT,
        ],
    ),
    :new_keynesian => ModelCapabilityProfile(;
        model = :new_keynesian,
        model_type = :NewKeynesianModel,
        display_name = "New Keynesian 3方程式モデル",
        time_representation = :discrete,
        time_unit = "quarterly",
        apis = [:steady_state, :simulate, :impulse_response],
        sectors = [:household, :firm, :central_bank],
        production = :approximate,
        prices = :endogenous,
        monetary_policy = :endogenous,
        fiscal_policy = :none,
        expectations = :rational,
        optimization = :both,
        behavioral_equations = false,
        equilibrium_concept = :zero_gap,
        data_connection = true,
        doc_ref = "docs/models/new_keynesian.md",
        caveats = [
            "IS・Phillips・Taylor 則の線形 3 方程式（前向き）。財政政策・貨幣ストックは持たないキャッシュレス設定。",
            _CAP_GENERIC_DATA_CAVEAT,
        ],
    ),
    :var => ModelCapabilityProfile(;
        model = :var,
        model_type = :VARModel,
        display_name = "簡易 VAR モデル",
        time_representation = :discrete,
        time_unit = "quarterly",
        apis = [:steady_state, :simulate, :impulse_response],
        sectors = Symbol[],
        production = :none,
        expectations = :none,
        optimization = :none,
        behavioral_equations = false,
        equilibrium_concept = :linear_fixed_point,
        data_connection = true,
        doc_ref = "docs/models/var.md",
        caveats = [
            "非構造（atheoretical）な線形時系列モデル。経済メカニズム・部門を構造的に内生化しない。係数 A,c はユーザ指定でモデル内推定機能は持たない。",
            _CAP_GENERIC_DATA_CAVEAT,
        ],
    ),
    :mundell_fleming => ModelCapabilityProfile(;
        model = :mundell_fleming,
        model_type = :MundellFlemingModel,
        display_name = "Mundell-Fleming モデル",
        time_representation = :static,
        time_unit = nothing,
        apis = [:steady_state, :simulate],
        sectors = [:household, :firm, :government, :central_bank, :external],
        instruments = [:money],
        production = :approximate,
        prices = :none,
        monetary_policy = :endogenous,
        fiscal_policy = :endogenous,
        external_sector = :endogenous,
        expectations = :none,
        optimization = :none,
        behavioral_equations = true,
        equilibrium_concept = :static_equilibrium,
        data_connection = true,
        doc_ref = "docs/models/mundell_fleming.md",
        caveats = [
            "小国開放経済の短期・固定物価。純輸出 NX・為替 e・資本移動を内生化するが物価・供給側は扱わない。",
            _CAP_GENERIC_DATA_CAVEAT,
        ],
    ),
    :keen => ModelCapabilityProfile(;
        model = :keen,
        model_type = :KeenModel,
        display_name = "Keen（Minsky 系）モデル",
        time_representation = :continuous,
        time_unit = "year",
        apis = [:steady_state, :simulate, :impulse_response, :calibration, :validation],
        sectors = [:household, :firm, :bank],
        instruments = [:debt, :loan],
        endogenous_credit = true,
        accounting_closure = :none,
        production = :endogenous,
        employment = :endogenous,
        income_distribution = :endogenous,
        prices = :none,
        monetary_policy = :none,
        fiscal_policy = :none,
        expectations = :none,
        optimization = :none,
        behavioral_equations = true,
        equilibrium_concept = :bistable_with_crisis,
        data_connection = true,
        estimation = true,
        out_of_sample_validation = true,
        doc_ref = "docs/models/keen.md",
        caveats = [
            "銀行は受動的に貸すと仮定し内生信用を持つが、SFC 会計行列は構成しない（債務比率 d のみ追跡）。",
            "政府・金融政策なし（金利 r は一定パラメータ）、物価は扱わない実物モデル。",
            "実証は Keen 専用の calibrate_keen（ODE residual 推定）・validate_keen（感応度・regime 比較）による。",
        ],
    ),
    :sim => ModelCapabilityProfile(;
        model = :sim,
        model_type = :SIMModel,
        display_name = "最小 SIM 型 SFC モデル",
        time_representation = :discrete,
        time_unit = "period",
        apis = [:steady_state, :simulate, :impulse_response],
        sectors = [:household, :firm, :government],
        instruments = [:money],
        endogenous_credit = false,
        accounting_closure = :stock_flow_consistent,
        production = :approximate,
        employment = :endogenous,
        income_distribution = :none,
        prices = :none,
        monetary_policy = :none,
        fiscal_policy = :endogenous,
        expectations = :none,
        optimization = :none,
        behavioral_equations = true,
        equilibrium_concept = :stock_flow_steady_state,
        data_connection = true,
        doc_ref = "docs/models/sim_sfc.md",
        caveats = [
            "会計恒等式（貸借対照表・取引フロー・ストック更新）を全期検証する SFC モデル。金融資産は政府貨幣 H のみ。",
            "産出は需要決定（Y=C+G、生産関数なし）、企業利潤ゼロで所得分配は扱わない。銀行貸出・危機regime なし。",
            _CAP_GENERIC_DATA_CAVEAT,
        ],
    ),
    :capex_credit_cycle => ModelCapabilityProfile(;
        model = :capex_credit_cycle,
        model_type = :CapexCreditCycleModel,
        display_name = "部門別CAPEX・信用循環モデル",
        time_representation = :discrete,
        time_unit = "quarterly",
        apis = [:steady_state, :simulate, :impulse_response],
        sectors = [:household, :firm, :bank],
        instruments = [:loan, :deposit],
        endogenous_credit = true,
        accounting_closure = :partial,
        production = :endogenous,
        employment = :endogenous,
        income_distribution = :approximate,
        prices = :approximate,
        monetary_policy = :exogenous,
        fiscal_policy = :none,
        external_sector = :none,
        expectations = :static,
        optimization = :none,
        behavioral_equations = true,
        equilibrium_concept = :none,
        data_connection = true,
        estimation = false,
        out_of_sample_validation = false,
        doc_ref = "docs/models/capex_credit_cycle_model_boundaries.md",
        caveats = [
            "残差部門 SX を持つため会計は経済全体で閉じていない（#166 §9.2 が要求）。",
            "デフォルト・信用損失を内生化していない。資金繰り診断は倒産・信用イベントの予測ではない（#166 §7）。",
            "信用の内生性は借り手側のみ。銀行の自己資本・調達コスト・貸出数量制約を持たない（#166 §12-1）。",
            "一般物価・インフレ・金融政策の内生反応を持たない。policy_rate は外生パスである。",
            "出力はすべて baseline 比の乖離であり、水準の絶対値は較正済みの実額を意味しない（契約 §2.4）。",
        ],
    ),
)

# ===========================================================================
# MODEL_CONCEPT_DEFINITION_REGISTRY（各モデルの主要変数の概念定義）
# ===========================================================================
#
# concept_id はグローバルに一意。同名変数（Y, r, K …）でも model 別に別 id・別 definition_key を
# 割り当て、別定義の同一視を防ぐ。docs のモデル節・variable_mapping・simulation_outputs を根拠とする。

const MODEL_CONCEPT_DEFINITION_REGISTRY = ModelConceptDefinition[
    # ---- Ramsey ----
    ModelConceptDefinition(;
        concept_id = :ramsey_capital_K,
        model = :ramsey,
        variable = :K,
        definition = "1 人当たり資本ストック（最適成長経路上）。",
        definition_key = :capital_stock_real_level,
        unit = "level (real)",
        kind = :stock,
        timing = :end_of_period,
        endogeneity = :endogenous,
        observability = :observable,
        doc_ref = "docs/models/ramsey.md",
    ),
    ModelConceptDefinition(;
        concept_id = :ramsey_consumption_C,
        model = :ramsey,
        variable = :C,
        definition = "家計消費（異時点間効用最大化で決定）。",
        definition_key = :consumption_real_flow,
        unit = "level (real)",
        kind = :flow,
        timing = :current_flow,
        endogeneity = :endogenous,
        observability = :observable,
        doc_ref = "docs/models/ramsey.md",
    ),
    # ---- RBC ----
    ModelConceptDefinition(;
        concept_id = :rbc_capital_K,
        model = :rbc,
        variable = :K,
        definition = "資本ストック（確率的成長経路上）。",
        definition_key = :capital_stock_real_level,
        unit = "level (real)",
        kind = :stock,
        timing = :end_of_period,
        endogeneity = :endogenous,
        observability = :observable,
        doc_ref = "docs/models/rbc.md",
    ),
    ModelConceptDefinition(;
        concept_id = :rbc_output_Y,
        model = :rbc,
        variable = :Y,
        definition = "産出（Cobb-Douglas 生産関数による供給側決定）。",
        definition_key = :output_production_function_real,
        unit = "level (real)",
        kind = :flow,
        timing = :current_flow,
        endogeneity = :endogenous,
        observability = :observable,
        doc_ref = "docs/models/rbc.md",
    ),
    ModelConceptDefinition(;
        concept_id = :rbc_interest_rate_r,
        model = :rbc,
        variable = :r,
        definition = "実質利子率＝資本の限界生産物。",
        definition_key = :real_marginal_product_capital,
        unit = "rate (real)",
        kind = :rate,
        timing = :current_flow,
        endogeneity = :endogenous,
        observability = :partially_observable,
        proxy_caveats = [
            "名目金利ではなく実質資本収益率であり、市場金利と直接同一視しない。",
        ],
        doc_ref = "docs/models/rbc.md",
    ),
    ModelConceptDefinition(;
        concept_id = :rbc_technology_A,
        model = :rbc,
        variable = :A,
        definition = "全要素生産性（AR(1) 技術ショック）。",
        definition_key = :total_factor_productivity,
        unit = "index",
        kind = :index,
        timing = :current_flow,
        endogeneity = :exogenous,
        observability = :latent,
        proxy_caveats = ["Solow 残差など間接推定に依存する潜在変数。"],
        doc_ref = "docs/models/rbc.md",
    ),
    # ---- Solow ----
    ModelConceptDefinition(;
        concept_id = :solow_capital_per_effective_k,
        model = :solow,
        variable = :k,
        definition = "効率労働単位当たり資本 k=K/(AL)。",
        definition_key = :capital_per_effective_labor,
        unit = "ratio",
        kind = :ratio,
        timing = :end_of_period,
        endogeneity = :endogenous,
        observability = :partially_observable,
        proxy_caveats = ["効率労働単位への基準化のため観測系列と直接比較しない。"],
        doc_ref = "docs/models/solow.md",
    ),
    # ---- IS-LM ----
    ModelConceptDefinition(;
        concept_id = :islm_output_Y,
        model = :islm,
        variable = :Y,
        definition = "均衡産出（財市場と貨幣市場の同時均衡で需要決定）。",
        definition_key = :output_demand_determined_static,
        unit = "level",
        kind = :flow,
        timing = :static,
        endogeneity = :endogenous,
        observability = :observable,
        doc_ref = "docs/models/islm.md",
    ),
    ModelConceptDefinition(;
        concept_id = :islm_interest_rate_r,
        model = :islm,
        variable = :r,
        definition = "名目利子率（LM 曲線・貨幣市場均衡で決定）。",
        definition_key = :nominal_interest_rate_money_market,
        unit = "rate (nominal)",
        kind = :rate,
        timing = :static,
        endogeneity = :endogenous,
        observability = :observable,
        proxy_caveats = ["名目金利であり RBC の実質資本収益率とは別概念。"],
        doc_ref = "docs/models/islm.md",
    ),
    # ---- AD-AS ----
    ModelConceptDefinition(;
        concept_id = :adas_output_Y,
        model = :adas,
        variable = :Y,
        definition = "均衡産出（総需要 AD と総供給 AS の交点）。",
        definition_key = :output_ad_as_equilibrium,
        unit = "level",
        kind = :flow,
        timing = :static,
        endogeneity = :endogenous,
        observability = :observable,
        doc_ref = "docs/models/adas.md",
    ),
    ModelConceptDefinition(;
        concept_id = :adas_price_level_P,
        model = :adas,
        variable = :P,
        definition = "物価水準（AD-AS 均衡で内生決定）。",
        definition_key = :price_level_ad_as,
        unit = "index",
        kind = :index,
        timing = :static,
        endogeneity = :endogenous,
        observability = :observable,
        doc_ref = "docs/models/adas.md",
    ),
    # ---- New Keynesian ----
    ModelConceptDefinition(;
        concept_id = :nk_output_gap_x,
        model = :new_keynesian,
        variable = :x,
        definition = "産出ギャップ（実際産出とポテンシャルの偏差）。",
        definition_key = :output_gap_deviation,
        unit = "log-deviation",
        kind = :ratio,
        timing = :current_flow,
        endogeneity = :endogenous,
        observability = :latent,
        proxy_caveats = ["ポテンシャル産出は潜在変数であり推定に依存する。"],
        doc_ref = "docs/models/new_keynesian.md",
    ),
    ModelConceptDefinition(;
        concept_id = :nk_inflation_pi,
        model = :new_keynesian,
        variable = :π,
        definition = "インフレ率（New Keynesian Phillips 曲線で決定）。",
        definition_key = :inflation_rate_nkpc,
        unit = "rate",
        kind = :rate,
        timing = :current_flow,
        endogeneity = :endogenous,
        observability = :observable,
        doc_ref = "docs/models/new_keynesian.md",
    ),
    ModelConceptDefinition(;
        concept_id = :nk_policy_rate_i,
        model = :new_keynesian,
        variable = :i,
        definition = "名目政策金利（Taylor 則で決定）。",
        definition_key = :nominal_policy_rate_taylor,
        unit = "rate (nominal)",
        kind = :rate,
        timing = :current_flow,
        endogeneity = :endogenous,
        observability = :observable,
        proxy_caveats = ["政策金利であり IS-LM の貨幣市場利子率とは決定機構が異なる。"],
        doc_ref = "docs/models/new_keynesian.md",
    ),
    ModelConceptDefinition(;
        concept_id = :nk_inflation_target_pi_star,
        model = :new_keynesian,
        variable = :π_star,
        definition = "インフレ目標（Taylor rule のアンカー）。current inflation・expected inflation とは別概念。",
        definition_key = :inflation_target_taylor,
        unit = "rate",
        kind = :rate,
        timing = :static,
        endogeneity = :parameter,
        observability = :model_only,
        doc_ref = "docs/models/new_keynesian.md",
    ),
    ModelConceptDefinition(;
        concept_id = :nk_natural_real_rate_r_n,
        model = :new_keynesian,
        variable = :r_n,
        definition = "自然実質利子率（産出ギャップ 0・インフレ目標達成時の実質金利水準）。model-implied ex-ante 実質政策金利とは別概念。",
        definition_key = :natural_real_rate_parameter,
        unit = "rate (real)",
        kind = :rate,
        timing = :static,
        endogeneity = :parameter,
        observability = :latent,
        proxy_caveats = [
            "定常状態では model-implied 実質政策金利と数値的に一致しうるが、意味は統合しない。",
        ],
        doc_ref = "docs/models/new_keynesian.md",
    ),
    ModelConceptDefinition(;
        concept_id = :nk_expected_inflation_e_pi,
        model = :new_keynesian,
        variable = :Eπ,
        definition = "t 期時点で形成される将来インフレ率の期待値 E_t[π_{t+h}]（MSV 解の閉形式）。current inflation・inflation target のコピーではない。",
        definition_key = :expected_inflation_msv,
        unit = "rate",
        kind = :rate,
        timing = :current_flow,
        endogeneity = :endogenous,
        observability = :model_only,
        doc_ref = "docs/models/new_keynesian.md",
    ),
    ModelConceptDefinition(;
        concept_id = :nk_model_implied_real_policy_rate,
        model = :new_keynesian,
        variable = :r_policy,
        definition = "model-implied ex-ante 実質政策金利 = 名目政策金利 − 期待インフレ率。natural real rate の代用ではない。",
        definition_key = :model_implied_real_policy_rate,
        unit = "rate (real)",
        kind = :rate,
        timing = :current_flow,
        endogeneity = :endogenous,
        observability = :model_only,
        proxy_caveats = [
            "自然実質利子率 r_n とは別概念であり、定常値の一致を同一視しない。",
        ],
        doc_ref = "docs/models/new_keynesian.md",
    ),
    # ---- VAR ----
    ModelConceptDefinition(;
        concept_id = :var_endogenous_vector_y,
        model = :var,
        variable = :y,
        definition = "内生変数ベクトル（ユーザ指定の系列。線形 VAR の被説明変数）。",
        definition_key = :var_reduced_form_series,
        unit = nothing,
        kind = :index,
        timing = :current_flow,
        endogeneity = :endogenous,
        observability = :observable,
        proxy_caveats = ["非構造の統計系列であり経済概念への解釈はユーザに委ねられる。"],
        doc_ref = "docs/models/var.md",
    ),
    # ---- Mundell-Fleming ----
    ModelConceptDefinition(;
        concept_id = :mf_output_Y,
        model = :mundell_fleming,
        variable = :Y,
        definition = "均衡産出（IS-LM-BP の同時均衡で需要決定）。",
        definition_key = :output_demand_determined_open_static,
        unit = "level",
        kind = :flow,
        timing = :static,
        endogeneity = :endogenous,
        observability = :observable,
        doc_ref = "docs/models/mundell_fleming.md",
    ),
    ModelConceptDefinition(;
        concept_id = :mf_exchange_rate_e,
        model = :mundell_fleming,
        variable = :e,
        definition = "名目為替レート（対外均衡・資本移動で決定）。",
        definition_key = :nominal_exchange_rate,
        unit = "level",
        kind = :rate,
        timing = :static,
        endogeneity = :endogenous,
        observability = :observable,
        doc_ref = "docs/models/mundell_fleming.md",
    ),
    ModelConceptDefinition(;
        concept_id = :mf_net_exports_NX,
        model = :mundell_fleming,
        variable = :NX,
        definition = "純輸出（為替・所得に依存）。",
        definition_key = :net_exports_flow,
        unit = "level",
        kind = :flow,
        timing = :static,
        endogeneity = :endogenous,
        observability = :observable,
        doc_ref = "docs/models/mundell_fleming.md",
    ),
    # ---- Keen ----
    ModelConceptDefinition(;
        concept_id = :keen_wage_share_omega,
        model = :keen,
        variable = :ω,
        definition = "賃金シェア ω=W·L/Y（非線形 Phillips 曲線で動学化）。",
        definition_key = :keen_wage_profit_share,
        unit = "ratio",
        kind = :ratio,
        timing = :instantaneous,
        endogeneity = :endogenous,
        observability = :observable,
        doc_ref = "docs/models/keen.md",
    ),
    ModelConceptDefinition(;
        concept_id = :keen_employment_rate_lambda,
        model = :keen,
        variable = :λ,
        definition = "雇用率 λ=L/N（労働需要と労働人口の比）。",
        definition_key = :keen_employment_rate,
        unit = "ratio",
        kind = :ratio,
        timing = :instantaneous,
        endogeneity = :endogenous,
        observability = :observable,
        doc_ref = "docs/models/keen.md",
    ),
    ModelConceptDefinition(;
        concept_id = :keen_debt_ratio_d,
        model = :keen,
        variable = :d,
        definition = "民間債務比率 d=D/Y（投資が利潤を超える分を借入で賄い上昇）。",
        definition_key = :keen_debt_ratio,
        unit = "ratio",
        kind = :ratio,
        timing = :instantaneous,
        endogeneity = :endogenous,
        observability = :observable,
        proxy_caveats = ["民間非金融部門債務/GDP を代理とするが銀行自己資本制約は非対象。"],
        doc_ref = "docs/models/keen.md",
    ),
    # ---- SIM (SFC) ----
    ModelConceptDefinition(;
        concept_id = :sim_money_stock_H,
        model = :sim,
        variable = :H,
        definition = "政府貨幣ストック H（家計保有＝政府負債。家計の富）。",
        definition_key = :sim_government_money_stock,
        unit = "wage units",
        kind = :stock,
        timing = :end_of_period,
        endogeneity = :endogenous,
        observability = :observable,
        proxy_caveats = ["賃金単位（W 基準）で表現され、名目/実質の区別は行わない。"],
        doc_ref = "docs/models/sim_sfc.md",
    ),
    ModelConceptDefinition(;
        concept_id = :sim_output_Y,
        model = :sim,
        variable = :Y,
        definition = "産出＝総需要 C+G（需要決定、生産関数なし）。",
        definition_key = :output_demand_determined_sfc,
        unit = "wage units",
        kind = :flow,
        timing = :current_flow,
        endogeneity = :endogenous,
        observability = :observable,
        doc_ref = "docs/models/sim_sfc.md",
    ),
    ModelConceptDefinition(;
        concept_id = :sim_disposable_income_YD,
        model = :sim,
        variable = :YD,
        definition = "可処分所得 YD=Y−T。",
        definition_key = :disposable_income_sfc,
        unit = "wage units",
        kind = :flow,
        timing = :current_flow,
        endogeneity = :endogenous,
        observability = :observable,
        doc_ref = "docs/models/sim_sfc.md",
    ),
    # ---- 部門別CAPEX・信用循環モデル（CCC） ----
    ModelConceptDefinition(;
        concept_id = :ccc_total_output_y_tot,
        model = :capex_credit_cycle,
        variable = :y_tot,
        definition = "総産出 y_tot = Σ va_s + y_s5（部門別付加価値の和）。GDP 全体ではなく本モデルが内生化する5部門の集計。",
        definition_key = :ccc_sectoral_value_added_output,
        unit = "level (bn USD, 2017 chained)",
        kind = :flow,
        timing = :current_flow,
        aggregation = "5部門集計（S1-S3 付加価値 + S5 産出）",
        endogeneity = :endogenous,
        observability = :observable,
        doc_ref = "docs/models/capex_credit_cycle_sectors_variables.md §5.5",
    ),
    ModelConceptDefinition(;
        concept_id = :ccc_sector_debt_debt_s,
        model = :capex_credit_cycle,
        variable = :debt_s1,
        definition = "部門別債務残高（借り手企業側のみ内生化、銀行の自己資本・貸出数量制約は持たない）。S1–S3 を個別に保持し集計比率は持たない。",
        definition_key = :ccc_sector_debt_stock,
        unit = "level (bn USD, 2017 chained)",
        kind = :stock,
        timing = :end_of_period,
        aggregation = "sector (S1–S3 個別)",
        endogeneity = :endogenous,
        observability = :partially_observable,
        proxy_caveats = [
            "Keen の集計債務比率 d=D/Y（比率・経済全体）とは単位・集計範囲が異なる。同一視しない。",
            "FRB Z.1 に産業別内訳が無いため部門配分（allocation）に依存する。",
        ],
        doc_ref = "docs/models/capex_credit_cycle_sectors_variables.md §5.4",
    ),
    ModelConceptDefinition(;
        concept_id = :ccc_credit_spread,
        model = :capex_credit_cycle,
        variable = :spread,
        definition = "社債スプレッド（集約カバレッジ・金融環境の関数として内生決定）。",
        definition_key = :ccc_corporate_credit_spread,
        unit = "bp",
        kind = :rate,
        timing = :current_flow,
        endogeneity = :endogenous,
        observability = :observable,
        doc_ref = "docs/models/capex_credit_cycle_sectors_variables.md §5.4",
    ),
    ModelConceptDefinition(;
        concept_id = :ccc_capex_exec_s1,
        model = :capex_credit_cycle,
        variable = :capex_exec_s1,
        definition = "S1（AI・クラウド需要部門）の実行 CAPEX。資金制約下で計画 CAPEX から執行される額。",
        definition_key = :ccc_ai_cloud_capex_execution,
        unit = "level (bn USD, 2017 chained)",
        kind = :flow,
        timing = :current_flow,
        aggregation = "sector (S1)",
        endogeneity = :endogenous,
        observability = :partially_observable,
        doc_ref = "docs/models/capex_credit_cycle_sectors_variables.md §5.2",
    ),
]

# ===========================================================================
# 公開 API: model_capabilities / concept_definitions
# ===========================================================================

"""
    model_capabilities(model) -> ModelCapabilityProfile

モデルの能力プロファイルを返す。`model` はモデルインスタンス（`AbstractMacroModel`）でも
識別子 `Symbol`（`:ramsey` …）でもよい。

```julia
p = model_capabilities(SolowModel(; α=0.3, s=0.2, δ=0.1, n=0.01, g=0.02))
supports_api(p, :steady_state)      # true
p.equilibrium_concept               # :balanced_growth
```
"""
function model_capabilities(model::Symbol)
    haskey(MODEL_CAPABILITY_REGISTRY, model) || throw(
        ArgumentError(
            "能力プロファイル未登録のモデル: $(repr(model))" *
            "（有効: $(sort(collect(keys(MODEL_CAPABILITY_REGISTRY)))))",
        ),
    )
    return MODEL_CAPABILITY_REGISTRY[model]
end
model_capabilities(m::AbstractMacroModel) = model_capabilities(model_symbol(m))

"""
    concept_definitions(model) -> Vector{ModelConceptDefinition}

モデルの主要変数・概念の定義一覧を返す。`model` はインスタンスでも識別子 `Symbol` でもよい。
`MODEL_CONCEPT_DEFINITION_REGISTRY` を model で絞り込む。
"""
concept_definitions(model::Symbol) =
    filter(d -> d.model === model, MODEL_CONCEPT_DEFINITION_REGISTRY)
concept_definitions(m::AbstractMacroModel) = concept_definitions(model_symbol(m))

# ===========================================================================
# JSON シリアライズ / デシリアライズ（round-trip）
# ===========================================================================
# 規約は src/sfc/serialization.jl に準拠: to_dict → Dict{String,Any}、to_json = JSON3.write∘to_dict、
# 復元は *_from_dict / *_from_json。Symbol は String へ、nothing は保持する。

_cap_sym(x::Symbol) = String(x)
_cap_syms(xs) = String[String(x) for x in xs]

# Dict / JSON3.Object 双方に対応するアクセサ
_cap_get(d::AbstractDict, k::AbstractString) = haskey(d, k) ? d[k] : d[Symbol(k)]
_cap_get(d, k::AbstractString) = getproperty(d, Symbol(k))
_cap_has(d::AbstractDict, k::AbstractString) = haskey(d, k) || haskey(d, Symbol(k))
_cap_has(d, k::AbstractString) = haskey(d, Symbol(k))

_cap_str_or_nothing(x) = x === nothing ? nothing : String(x)
_cap_to_string_vec(xs) = String[String(x) for x in xs]
_cap_to_symbol_vec(xs) = Symbol[Symbol(x) for x in xs]
_cap_plain_metadata(d::AbstractDict) = Dict{String, Any}(string(k) => v for (k, v) in d)

function to_dict(p::ModelCapabilityProfile)
    return Dict{String, Any}(
        "contract_version" => MODEL_CAPABILITY_CONTRACT_VERSION,
        "model" => _cap_sym(p.model),
        "model_type" => _cap_sym(p.model_type),
        "display_name" => p.display_name,
        "time_representation" => _cap_sym(p.time_representation),
        "time_unit" => p.time_unit,
        "apis" => _cap_syms(p.apis),
        "sectors" => _cap_syms(p.sectors),
        "instruments" => _cap_syms(p.instruments),
        "endogenous_credit" => p.endogenous_credit,
        "accounting_closure" => _cap_sym(p.accounting_closure),
        "production" => _cap_sym(p.production),
        "employment" => _cap_sym(p.employment),
        "income_distribution" => _cap_sym(p.income_distribution),
        "prices" => _cap_sym(p.prices),
        "monetary_policy" => _cap_sym(p.monetary_policy),
        "fiscal_policy" => _cap_sym(p.fiscal_policy),
        "external_sector" => _cap_sym(p.external_sector),
        "expectations" => _cap_sym(p.expectations),
        "optimization" => _cap_sym(p.optimization),
        "behavioral_equations" => p.behavioral_equations,
        "equilibrium_concept" => _cap_sym(p.equilibrium_concept),
        "data_connection" => p.data_connection,
        "estimation" => p.estimation,
        "out_of_sample_validation" => p.out_of_sample_validation,
        "doc_ref" => p.doc_ref,
        "caveats" => copy(p.caveats),
        "metadata" => _cap_plain_metadata(p.metadata),
    )
end

to_json(p::ModelCapabilityProfile) = JSON3.write(to_dict(p))

"""
    model_capability_profile_from_dict(d) -> ModelCapabilityProfile

`to_dict(::ModelCapabilityProfile)` の出力（または JSON3.Object）から復元する。
"""
function model_capability_profile_from_dict(d)
    return ModelCapabilityProfile(;
        model = Symbol(_cap_get(d, "model")),
        model_type = Symbol(_cap_get(d, "model_type")),
        display_name = String(_cap_get(d, "display_name")),
        time_representation = Symbol(_cap_get(d, "time_representation")),
        time_unit = _cap_str_or_nothing(_cap_get(d, "time_unit")),
        apis = _cap_to_symbol_vec(_cap_get(d, "apis")),
        sectors = _cap_to_symbol_vec(_cap_get(d, "sectors")),
        instruments = _cap_to_symbol_vec(_cap_get(d, "instruments")),
        endogenous_credit = Bool(_cap_get(d, "endogenous_credit")),
        accounting_closure = Symbol(_cap_get(d, "accounting_closure")),
        production = Symbol(_cap_get(d, "production")),
        employment = Symbol(_cap_get(d, "employment")),
        income_distribution = Symbol(_cap_get(d, "income_distribution")),
        prices = Symbol(_cap_get(d, "prices")),
        monetary_policy = Symbol(_cap_get(d, "monetary_policy")),
        fiscal_policy = Symbol(_cap_get(d, "fiscal_policy")),
        external_sector = Symbol(_cap_get(d, "external_sector")),
        expectations = Symbol(_cap_get(d, "expectations")),
        optimization = Symbol(_cap_get(d, "optimization")),
        behavioral_equations = Bool(_cap_get(d, "behavioral_equations")),
        equilibrium_concept = Symbol(_cap_get(d, "equilibrium_concept")),
        data_connection = Bool(_cap_get(d, "data_connection")),
        estimation = Bool(_cap_get(d, "estimation")),
        out_of_sample_validation = Bool(_cap_get(d, "out_of_sample_validation")),
        doc_ref = String(_cap_get(d, "doc_ref")),
        caveats = _cap_to_string_vec(_cap_get(d, "caveats")),
        metadata = _cap_has(d, "metadata") ? _cap_plain_metadata(_cap_get(d, "metadata")) :
                   Dict{String, Any}(),
    )
end

model_capability_profile_from_json(s::AbstractString) =
    model_capability_profile_from_dict(JSON3.read(s, Dict{String, Any}))

function to_dict(c::ModelConceptDefinition)
    return Dict{String, Any}(
        "concept_id" => _cap_sym(c.concept_id),
        "model" => _cap_sym(c.model),
        "variable" => _cap_sym(c.variable),
        "definition" => c.definition,
        "unit" => c.unit,
        "kind" => _cap_sym(c.kind),
        "timing" => _cap_sym(c.timing),
        "aggregation" => c.aggregation,
        "endogeneity" => _cap_sym(c.endogeneity),
        "observability" => _cap_sym(c.observability),
        "definition_key" => _cap_sym(c.definition_key),
        "proxy_caveats" => copy(c.proxy_caveats),
        "doc_ref" => c.doc_ref,
    )
end

to_json(c::ModelConceptDefinition) = JSON3.write(to_dict(c))

"""
    model_concept_definition_from_dict(d) -> ModelConceptDefinition

`to_dict(::ModelConceptDefinition)` の出力（または JSON3.Object）から復元する。
"""
function model_concept_definition_from_dict(d)
    return ModelConceptDefinition(;
        concept_id = Symbol(_cap_get(d, "concept_id")),
        model = Symbol(_cap_get(d, "model")),
        variable = Symbol(_cap_get(d, "variable")),
        definition = String(_cap_get(d, "definition")),
        unit = _cap_str_or_nothing(_cap_get(d, "unit")),
        kind = Symbol(_cap_get(d, "kind")),
        timing = Symbol(_cap_get(d, "timing")),
        aggregation = String(_cap_get(d, "aggregation")),
        endogeneity = Symbol(_cap_get(d, "endogeneity")),
        observability = Symbol(_cap_get(d, "observability")),
        definition_key = Symbol(_cap_get(d, "definition_key")),
        proxy_caveats = _cap_to_string_vec(_cap_get(d, "proxy_caveats")),
        doc_ref = String(_cap_get(d, "doc_ref")),
    )
end

model_concept_definition_from_json(s::AbstractString) =
    model_concept_definition_from_dict(JSON3.read(s, Dict{String, Any}))
