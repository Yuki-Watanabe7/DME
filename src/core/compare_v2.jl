# compare_v2.jl: 日付・単位・概念対応を明示するモデル比較 API v2（Issue #150 / Phase 5）
#
# v1（compare_with_data / ComparisonResult, src/core/compare.jl）は配列位置で短い系列へ
# 切り詰めて比較するため、日付・頻度・単位・stock/flow・観測範囲が異なる系列でも数値比較が
# できてしまう。v2 は比較前の契約検証を第一級にする:
#   - 日付 metadata があれば日付 intersection / 指定期間で整列し、配列位置は使わない。
#   - 日付が無い結果同士の period index 比較は、呼出側が明示許可した場合のみ行う。
#   - 頻度変換・季節調整・指数化・対数化・単位換算を暗黙に行わない。
#   - stock と flow、level と growth を自動同一視しない。
#   - equivalent/proxy/partial/incompatible を mapping に保持し、partial 以下では metric を制限・警告する。
#   - 比較不能でも例外だけで終了せず、理由と次に必要な変換・証拠を構造化して返す。
#
# 後方互換: v1（compare_with_data / ComparisonResult）は一切変更しない（ADR 0007 §9）。v2 は
# 加算的な新 API として導入する。
#
# 依存: core/simulation_result.jl（SimulationResult・_compute_variable_metrics・_var_summary）と
#       core/model_capabilities.jl（ModelConceptDefinition・concept_definitions_equivalent・
#       MODEL_CONCEPT_DEFINITION_REGISTRY・model_capabilities）。llm 層には依存しない。
# 参照: docs/adr/0007-sfc-integration-contract.md §9、docs/model_capabilities.md、Issue #150。

# ===========================================================================
# 契約 version と固定語彙
# ===========================================================================

const COMPARISON_V2_CONTRACT_VERSION = "comparison-v2/1.0.0"

# 比較モード
#   :trajectory     … 同一概念・単位・頻度・日付の水準（または明示変換後）系列の乖離
#   :shock_response … ショック応答の方向・peak・持続性
#   :empirical_fit  … 観測 proxy とモデル系列の対応根拠を保った fit
#   :mechanism      … 能力 metadata（#149）の構造化差分。数値 metric は返さない
const COMPARISON_MODES = (:trajectory, :shock_response, :empirical_fit, :mechanism)

# mapping type（cross_model_reasoning の CROSS_MODEL_MAPPING_TYPES と同語彙）
const COMPARISON_MAPPING_TYPES = (:equivalent, :proxy, :partial, :incompatible)

# 比較可能性レベル（重い方へ集約する。詳細は _COMPARABILITY_RANK）
#   :comparable   … そのまま数値比較可能
#   :partial      … 比較可能だが proxy/部分対応など注意付き（metric 計算＋警告）
#   :insufficient … 情報・重複・変換が不足（次に必要な変換・証拠を返す）
#   :incompatible … 構造的に数値比較不可（stock/flow 差・概念種別差など）
const COMPARABILITY_LEVELS = (:comparable, :partial, :insufficient, :incompatible)

const _COMPARABILITY_RANK = Dict{Symbol, Int}(
    :comparable => 1,
    :partial => 2,
    :insufficient => 3,
    :incompatible => 4,
)

# より重い（悪い）レベルを返す
_worse(a::Symbol, b::Symbol) = _COMPARABILITY_RANK[a] >= _COMPARABILITY_RANK[b] ? a : b

# ===========================================================================
# VariableComparisonMapping
# ===========================================================================

"""
    VariableComparisonMapping

比較する 1 変数ペアの対応と、その概念・単位・変換・対応種別を明示する契約。

## フィールド
- `model_variable::String` : モデル側（left）変数名
- `data_variable::String`  : データ側（right）変数名
- `mapping_type::Symbol`   : `COMPARISON_MAPPING_TYPES`（`:equivalent` / `:proxy` / `:partial` / `:incompatible`）
- `model_concept_id::Union{Symbol,Nothing}` : モデル側 concept id（`MODEL_CONCEPT_DEFINITION_REGISTRY` 参照）
- `data_concept_id::Union{Symbol,Nothing}`  : データ側 concept id（多くの実データは `nothing`）
- `unit::Union{String,Nothing}` : 期待する共通単位（情報用）
- `transform::Union{Nothing,Function}` : モデル系列へ明示的に適用する変換（対数化・指数化・単位換算等）。
  宣言された場合のみ適用し、暗黙変換は一切行わない。
- `transform_label::String` : `transform` の説明（provenance・履歴用）
- `caveats::Vector{String}` : この変数比較に関する注意事項

`transform` を宣言しない限り、単位差・頻度差は「自動同一視しない」契約に従い比較可能性を降格する。
"""
struct VariableComparisonMapping
    model_variable::String
    data_variable::String
    mapping_type::Symbol
    model_concept_id::Union{Symbol, Nothing}
    data_concept_id::Union{Symbol, Nothing}
    unit::Union{String, Nothing}
    transform::Union{Nothing, Function}
    transform_label::String
    caveats::Vector{String}
end

"""
    VariableComparisonMapping(; model_variable, data_variable, kwargs...)

キーワード引数コンストラクタ。`mapping_type` は `COMPARISON_MAPPING_TYPES` を検証する。
"""
function VariableComparisonMapping(;
    model_variable::String,
    data_variable::String,
    mapping_type::Symbol = :equivalent,
    model_concept_id::Union{Symbol, Nothing} = nothing,
    data_concept_id::Union{Symbol, Nothing} = nothing,
    unit::Union{String, Nothing} = nothing,
    transform::Union{Nothing, Function} = nothing,
    transform_label::String = "",
    caveats::Vector{String} = String[],
)
    mapping_type in COMPARISON_MAPPING_TYPES || throw(
        ArgumentError(
            "未知の mapping_type: $(repr(mapping_type))（有効: $(COMPARISON_MAPPING_TYPES)）",
        ),
    )
    return VariableComparisonMapping(
        model_variable,
        data_variable,
        mapping_type,
        model_concept_id,
        data_concept_id,
        unit,
        transform,
        transform_label,
        caveats,
    )
end

# ===========================================================================
# ComparisonSpec
# ===========================================================================

"""
    ComparisonSpec

比較 v2 の実行仕様。比較モード・変数 mapping・整列期間・period index 許可・（mechanism 用の）
モデル識別子を保持する。

## フィールド
- `mode::Symbol` : `COMPARISON_MODES`
- `mappings::Vector{VariableComparisonMapping}` : 変数対応（`:mechanism` 以外では 1 つ以上必須）
- `period::Union{Nothing,Tuple{String,String}}` : 整列に用いる日付ラベルの開始・終了（`nothing` なら日付 intersection 全体）
- `allow_period_index::Bool` : 日付 metadata が無い結果同士を配列位置で比較することを明示許可するか（既定 `false`）
- `left_model::Union{Symbol,Nothing}` / `right_model::Union{Symbol,Nothing}` : `:mechanism` モードで能力 metadata を引くモデル識別子
- `metadata::Dict{String,Any}` : 自由記述の付随情報
"""
struct ComparisonSpec
    mode::Symbol
    mappings::Vector{VariableComparisonMapping}
    period::Union{Nothing, Tuple{String, String}}
    allow_period_index::Bool
    left_model::Union{Symbol, Nothing}
    right_model::Union{Symbol, Nothing}
    metadata::Dict{String, Any}
end

"""
    ComparisonSpec(; mode, kwargs...)

キーワード引数コンストラクタ。`mode` を検証し、`:mechanism` 以外では `mappings` が空でないことを要求する。
"""
function ComparisonSpec(;
    mode::Symbol,
    mappings::Vector{VariableComparisonMapping} = VariableComparisonMapping[],
    period::Union{Nothing, Tuple{String, String}} = nothing,
    allow_period_index::Bool = false,
    left_model::Union{Symbol, Nothing} = nothing,
    right_model::Union{Symbol, Nothing} = nothing,
    metadata::Dict{String, Any} = Dict{String, Any}(),
)
    mode in COMPARISON_MODES ||
        throw(ArgumentError("未知の mode: $(repr(mode))（有効: $(COMPARISON_MODES)）"))
    if mode !== :mechanism && isempty(mappings)
        throw(ArgumentError("mode=$(mode) には少なくとも 1 つの mapping が必要です。"))
    end
    return ComparisonSpec(
        mode,
        mappings,
        period,
        allow_period_index,
        left_model,
        right_model,
        metadata,
    )
end

# ===========================================================================
# AlignmentResult / ComparabilityAssessment / ComparisonResultV2
# ===========================================================================

"""
    AlignmentResult

1 変数ペアの整列結果。共通日付・除外日付・使用位置・欠損数・period index 使用可否・変換履歴を保持する。

## フィールド
- `common_dates::Vector{String}` : 実際に比較へ用いた日付ラベル（`used_period_index` の場合は `"idx1"…`）
- `excluded_dates::Vector{String}` : どちらか一方のみに存在し比較から除外した日付
- `model_indices::Vector{Int}` / `data_indices::Vector{Int}` : 比較へ用いた各系列の位置
- `n_missing::Int` : 整列後に NaN/欠損で無効化されたペア数
- `used_period_index::Bool` : 日付が無く配列位置で整列したか（`allow_period_index` 明示許可時のみ true）
- `transform_history::Vector{String}` : 適用した明示変換の履歴
"""
struct AlignmentResult
    common_dates::Vector{String}
    excluded_dates::Vector{String}
    model_indices::Vector{Int}
    data_indices::Vector{Int}
    n_missing::Int
    used_period_index::Bool
    transform_history::Vector{String}
end

"""
    ComparabilityAssessment

比較可能性の総合評価。全体レベル・理由・次に必要な変換/証拠・変数別レベルを保持する。

## フィールド
- `level::Symbol` : 全体レベル（変数別レベルのうち最も重いもの。`COMPARABILITY_LEVELS`）
- `reasons::Vector{String}` : 降格・比較不能の理由
- `required_transforms::Vector{String}` : 比較可能にするために次に必要な変換・証拠
- `per_variable::Dict{String,Symbol}` : モデル変数名 → 変数別レベル
"""
struct ComparabilityAssessment
    level::Symbol
    reasons::Vector{String}
    required_transforms::Vector{String}
    per_variable::Dict{String, Symbol}
end

"""
    ComparisonResultV2

比較 API v2 の結果。評価（assessment）・整列（alignment）・指標（metrics）・警告・provenance を保持する。

## フィールド
- `mode::Symbol` : 実行した比較モード
- `model_name::String` / `data_source::String` : left / right の名称
- `assessment::ComparabilityAssessment` : 比較可能性の総合評価
- `alignment::Dict{String,AlignmentResult}` : モデル変数名 → 整列結果（変数ごとに独立整列）
- `metrics::Dict{String,NamedTuple}` : モデル変数名 → 変数別指標（レベルが `:comparable`/`:partial` の変数のみ）
- `mechanism_diff::Union{Nothing,Dict{String,Any}}` : `:mechanism` モードの構造化差分（他モードは `nothing`）
- `warnings::Vector{String}` : proxy/部分対応・period index 使用・変換適用などの注意
- `provenance::Dict{String,Any}` : 契約 version・mode・spec 要約
"""
struct ComparisonResultV2
    mode::Symbol
    model_name::String
    data_source::String
    assessment::ComparabilityAssessment
    alignment::Dict{String, AlignmentResult}
    metrics::Dict{String, NamedTuple}
    mechanism_diff::Union{Nothing, Dict{String, Any}}
    warnings::Vector{String}
    provenance::Dict{String, Any}
end

# ===========================================================================
# metadata アクセサ（日付・単位・頻度の復元。SimulationResult は metadata から復元）
# ===========================================================================

# 変数 var のメタデータ Dict を返す（MacroDataset 由来は series_metadata 配下、単一系列は top-level）
function _v2_series_meta(r::SimulationResult, var::String)
    if haskey(r.metadata, "series_metadata")
        sm = r.metadata["series_metadata"]
        if sm isa AbstractDict && haskey(sm, var)
            return sm[var]
        end
    end
    return r.metadata
end

# 変数 var の日付ラベル。無ければ nothing
function _v2_var_dates(r::SimulationResult, var::String)
    sm = _v2_series_meta(r, var)
    (sm isa AbstractDict && haskey(sm, "dates")) || return nothing
    return Vector{String}(sm["dates"])
end

# 変数 var の metadata field（"unit" / "frequency" 等）。無ければ nothing
function _v2_var_field(r::SimulationResult, var::String, field::String)
    sm = _v2_series_meta(r, var)
    (sm isa AbstractDict && haskey(sm, field)) || return nothing
    return sm[field]
end

# concept id → ModelConceptDefinition（無ければ nothing）
function _v2_concept_by_id(id::Union{Symbol, Nothing})
    id === nothing && return nothing
    idx = findfirst(d -> d.concept_id === id, MODEL_CONCEPT_DEFINITION_REGISTRY)
    return idx === nothing ? nothing : MODEL_CONCEPT_DEFINITION_REGISTRY[idx]
end

# 単位の解決: concept id の単位を優先し、無ければ metadata の "unit"
function _v2_resolve_unit(
    r::SimulationResult,
    var::String,
    concept_id::Union{Symbol, Nothing},
)
    c = _v2_concept_by_id(concept_id)
    c !== nothing && return c.unit
    u = _v2_var_field(r, var, "unit")
    return u === nothing ? nothing : String(u)
end

# 概念種別（stock/flow/rate/…）の解決: concept id からのみ
function _v2_resolve_kind(concept_id::Union{Symbol, Nothing})
    c = _v2_concept_by_id(concept_id)
    return c === nothing ? nothing : c.kind
end

# ===========================================================================
# 整列（日付 intersection / period index）
# ===========================================================================

# period 指定を left 日付上の位置範囲へ変換。ラベルが見つからない場合は空範囲 (1, 0)
function _v2_period_range(
    ldates::Vector{String},
    period::Union{Nothing, Tuple{String, String}},
)
    period === nothing && return (1, length(ldates))
    lo = findfirst(==(period[1]), ldates)
    hi = findfirst(==(period[2]), ldates)
    (lo === nothing || hi === nothing) && return (1, 0)
    return lo <= hi ? (lo, hi) : (hi, lo)
end

# left/right どちらかにしか無い日付（比較から除外した日付）
function _v2_excluded_dates(
    ldates::Vector{String},
    rdates::Vector{String},
    common::Vector{String},
)
    cs = Set(common)
    return String[d for d in unique(vcat(ldates, rdates)) if !(d in cs)]
end

# 変換適用後のモデル系列（transform が無ければコピー）
function _v2_model_values(left::SimulationResult, m::VariableComparisonMapping)
    v = copy(left[m.model_variable])
    m.transform === nothing && return v
    return Float64[Float64(m.transform(x)) for x in v]
end

# 1 変数ペアを整列する。戻り値 (AlignmentResult, amode) で amode ∈ (:dates, :index, :nodate)
function _v2_align(
    left::SimulationResult,
    right::SimulationResult,
    m::VariableComparisonMapping,
    spec::ComparisonSpec,
)
    hist = String[]
    if m.transform !== nothing
        label = isempty(m.transform_label) ? "(function)" : m.transform_label
        push!(hist, "model[$(m.model_variable)] に明示変換 $(label) を適用")
    end

    ldates = _v2_var_dates(left, m.model_variable)
    rdates = _v2_var_dates(right, m.data_variable)

    if ldates !== nothing && rdates !== nothing
        rpos = Dict{String, Int}()
        for (i, d) in enumerate(rdates)
            haskey(rpos, d) || (rpos[d] = i)
        end
        prange = _v2_period_range(ldates, spec.period)
        lidx = Int[]
        didx = Int[]
        common = String[]
        for (i, d) in enumerate(ldates)
            (prange[1] <= i <= prange[2]) || continue
            if haskey(rpos, d)
                push!(common, d)
                push!(lidx, i)
                push!(didx, rpos[d])
            end
        end
        excluded = _v2_excluded_dates(ldates, rdates, common)
        return AlignmentResult(common, excluded, lidx, didx, 0, false, hist), :dates
    end

    # 日付が片方でも欠ける場合
    if spec.allow_period_index
        nl = haskey(left, m.model_variable) ? length(left[m.model_variable]) : 0
        nr = haskey(right, m.data_variable) ? length(right[m.data_variable]) : 0
        n = min(nl, nr)
        labels = String["idx$(i)" for i in 1:n]
        return AlignmentResult(labels, String[], collect(1:n), collect(1:n), 0, true, hist),
        :index
    end

    return AlignmentResult(String[], String[], Int[], Int[], 0, false, hist), :nodate
end

_v2_with_missing(a::AlignmentResult, nm::Int) = AlignmentResult(
    a.common_dates,
    a.excluded_dates,
    a.model_indices,
    a.data_indices,
    nm,
    a.used_period_index,
    a.transform_history,
)

# ===========================================================================
# shock_response 用の指標
# ===========================================================================

# ショック応答の方向・peak・持続性を比較する指標（level/deviation 指標も併せて保持）
function _v2_compute_shock_metrics(
    mv::String,
    dv::String,
    m_vals::Vector{Float64},
    d_vals::Vector{Float64},
)
    ms = _var_summary(m_vals)
    ds = _var_summary(d_vals)
    same_dir = sign(ms.peak_response) == sign(ds.peak_response)
    peak_ratio = abs(ds.peak_response) < 1e-12 ? NaN : ms.peak_response / ds.peak_response
    base = _compute_variable_metrics(mv, dv, m_vals, d_vals)
    return (
        model_variable = mv,
        data_variable = dv,
        n_periods = length(m_vals),
        model_peak = ms.peak_response,
        data_peak = ds.peak_response,
        same_direction = same_dir,
        peak_ratio = peak_ratio,
        model_argmax = ms.argmax,
        data_argmax = ds.argmax,
        rmse = base.rmse,
        correlation = base.correlation,
    )
end

# ===========================================================================
# 変数別の比較可能性評価 + 整列 + 指標
# ===========================================================================

# 1 変数の評価。戻り値 (level, alignment, metric|nothing, reasons, required, warnings)
function _v2_assess_variable(
    left::SimulationResult,
    right::SimulationResult,
    m::VariableComparisonMapping,
    spec::ComparisonSpec,
)
    reasons = String[]
    required = String[]
    warns = String[]
    tag = "$(m.model_variable)⇔$(m.data_variable)"

    # 1) mapping_type を起点レベルへ
    level = if m.mapping_type === :incompatible
        push!(reasons, "変数 $(tag): mapping_type=incompatible のため数値比較不可。")
        :incompatible
    elseif m.mapping_type === :partial
        push!(warns, "変数 $(tag): 部分対応（partial）のため指標は参考値。")
        :partial
    elseif m.mapping_type === :proxy
        push!(warns, "変数 $(tag): 観測 proxy 対応のため指標は proxy 前提で解釈する。")
        :comparable
    else
        :comparable
    end

    # 2) 概念種別（stock/flow 等）の差 → 自動同一視しない
    mk = _v2_resolve_kind(m.model_concept_id)
    dk = _v2_resolve_kind(m.data_concept_id)
    if mk !== nothing && dk !== nothing && mk !== dk
        level = _worse(level, :incompatible)
        push!(reasons, "変数 $(tag): 概念種別が異なる（$(mk) vs $(dk)）ため数値比較不可。")
        push!(required, "$(mk) と $(dk)（stock/flow・level/growth 等）は自動同一視しない。")
    end

    # 3) 単位差 → 明示変換が無ければ降格
    mu = _v2_resolve_unit(left, m.model_variable, m.model_concept_id)
    du = _v2_resolve_unit(right, m.data_variable, m.data_concept_id)
    if mu !== nothing && du !== nothing && mu != du
        if m.transform !== nothing
            push!(warns, "変数 $(tag): 単位差（$(mu) vs $(du)）を宣言済み変換で調整。")
        else
            level = _worse(level, :insufficient)
            push!(reasons, "変数 $(tag): 単位差（$(mu) vs $(du)）。暗黙換算は行わない。")
            push!(required, "単位換算 $(mu) → $(du)（明示 transform）。")
        end
    end

    # 4) 頻度差 → 明示変換が無ければ降格
    mf = _v2_var_field(left, m.model_variable, "frequency")
    df = _v2_var_field(right, m.data_variable, "frequency")
    if mf !== nothing && df !== nothing && string(mf) != string(df)
        if m.transform !== nothing
            push!(warns, "変数 $(tag): 頻度差（$(mf) vs $(df)）を宣言済み変換で調整。")
        else
            level = _worse(level, :insufficient)
            push!(
                reasons,
                "変数 $(tag): 頻度差（$(mf) vs $(df)）。暗黙頻度変換は行わない。",
            )
            push!(required, "頻度変換 $(mf) → $(df)（明示 transform）。")
        end
    end

    # 5) concept 定義の非等価 → equivalent 宣言でも equivalent 扱いにしない
    mc = _v2_concept_by_id(m.model_concept_id)
    dc = _v2_concept_by_id(m.data_concept_id)
    if m.mapping_type === :equivalent &&
       mc !== nothing &&
       dc !== nothing &&
       !concept_definitions_equivalent(mc, dc)
        level = _worse(level, :partial)
        push!(
            warns,
            "変数 $(tag): concept 定義が一致しない（$(mc.concept_id) vs $(dc.concept_id)）ため equivalent ではなく partial として扱う。",
        )
    end

    # 6) 整列
    align, amode = _v2_align(left, right, m, spec)
    if amode === :nodate
        level = _worse(level, :insufficient)
        push!(reasons, "変数 $(tag): 日付 metadata が無く period index 比較も未許可。")
        push!(
            required,
            "日付 metadata の付与、または spec.allow_period_index=true の明示許可。",
        )
    elseif amode === :index
        push!(warns, "変数 $(tag): 日付が無いため配列位置（period index）で比較。")
    elseif amode === :dates && isempty(align.common_dates)
        level = _worse(level, :insufficient)
        push!(reasons, "変数 $(tag): 共通日付が 0 件（観測期間が重ならない）。")
        push!(required, "重複する観測期間、または spec.period 指定の見直し。")
    end

    # 7) 指標計算（比較可能/部分のみ・整列位置がある場合のみ）
    metric = nothing
    if (level === :comparable || level === :partial) && !isempty(align.model_indices)
        m_full = _v2_model_values(left, m)
        d_full = right[m.data_variable]
        m_vals = m_full[align.model_indices]
        d_vals = d_full[align.data_indices]
        n_missing = count(i -> isnan(m_vals[i]) || isnan(d_vals[i]), eachindex(m_vals))
        align = _v2_with_missing(align, n_missing)
        metric =
            spec.mode === :shock_response ?
            _v2_compute_shock_metrics(m.model_variable, m.data_variable, m_vals, d_vals) :
            _compute_variable_metrics(m.model_variable, m.data_variable, m_vals, d_vals)
    end

    return level, align, metric, reasons, required, warns
end

# ===========================================================================
# mechanism モード（能力 metadata の構造化差分）
# ===========================================================================

_v2_setdiff_dict(a, b) = Dict{String, Any}(
    "shared" => sort(String[String(x) for x in intersect(a, b)]),
    "left_only" => sort(String[String(x) for x in setdiff(a, b)]),
    "right_only" => sort(String[String(x) for x in setdiff(b, a)]),
)

_v2_scalar_diff(lv, rv) =
    Dict{String, Any}("left" => lv, "right" => rv, "differs" => lv != rv)

# 2 つの ModelCapabilityProfile の構造化差分（数値 metric ではない）
function _v2_mechanism_diff(lp::ModelCapabilityProfile, rp::ModelCapabilityProfile)
    treat_fields = (
        :production,
        :employment,
        :income_distribution,
        :prices,
        :monetary_policy,
        :fiscal_policy,
        :external_sector,
    )
    treatments = Dict{String, Any}()
    for f in treat_fields
        treatments[String(f)] =
            _v2_scalar_diff(String(getproperty(lp, f)), String(getproperty(rp, f)))
    end
    return Dict{String, Any}(
        "left_model" => String(lp.model),
        "right_model" => String(rp.model),
        "sectors" => _v2_setdiff_dict(lp.sectors, rp.sectors),
        "instruments" => _v2_setdiff_dict(lp.instruments, rp.instruments),
        "apis" => _v2_setdiff_dict(lp.apis, rp.apis),
        "treatments" => treatments,
        "endogenous_credit" => _v2_scalar_diff(lp.endogenous_credit, rp.endogenous_credit),
        "accounting_closure" =>
            _v2_scalar_diff(String(lp.accounting_closure), String(rp.accounting_closure)),
        "equilibrium_concept" =>
            _v2_scalar_diff(String(lp.equilibrium_concept), String(rp.equilibrium_concept)),
        "expectations" => _v2_scalar_diff(String(lp.expectations), String(rp.expectations)),
        "optimization" => _v2_scalar_diff(String(lp.optimization), String(rp.optimization)),
    )
end

function _v2_mechanism(
    left::SimulationResult,
    right::SimulationResult,
    spec::ComparisonSpec,
)
    if spec.left_model === nothing || spec.right_model === nothing
        assessment = ComparabilityAssessment(
            :insufficient,
            ["mechanism モードには spec.left_model / spec.right_model が必要。"],
            ["left_model・right_model にモデル識別子（:ramsey 等）を指定。"],
            Dict{String, Symbol}(),
        )
        return ComparisonResultV2(
            :mechanism,
            left.model_name,
            right.model_name,
            assessment,
            Dict{String, AlignmentResult}(),
            Dict{String, NamedTuple}(),
            nothing,
            String[],
            _v2_provenance(spec),
        )
    end
    lp = model_capabilities(spec.left_model)
    rp = model_capabilities(spec.right_model)
    diff = _v2_mechanism_diff(lp, rp)
    assessment = ComparabilityAssessment(
        :comparable,
        [
            "能力 metadata の構造化差分。数値 metric は返さない（mechanism/accounting モード）。",
        ],
        String[],
        Dict{String, Symbol}(),
    )
    return ComparisonResultV2(
        :mechanism,
        left.model_name,
        right.model_name,
        assessment,
        Dict{String, AlignmentResult}(),
        Dict{String, NamedTuple}(),
        diff,
        String[],
        _v2_provenance(spec),
    )
end

# ===========================================================================
# provenance
# ===========================================================================

function _v2_provenance(spec::ComparisonSpec)
    mappings = Dict{String, Any}[
        Dict{String, Any}(
            "model_variable" => m.model_variable,
            "data_variable" => m.data_variable,
            "mapping_type" => String(m.mapping_type),
            "model_concept_id" =>
                m.model_concept_id === nothing ? nothing : String(m.model_concept_id),
            "data_concept_id" =>
                m.data_concept_id === nothing ? nothing : String(m.data_concept_id),
            "transform" =>
                m.transform === nothing ? nothing :
                (isempty(m.transform_label) ? "function" : m.transform_label),
        ) for m in spec.mappings
    ]
    return Dict{String, Any}(
        "contract_version" => COMPARISON_V2_CONTRACT_VERSION,
        "mode" => String(spec.mode),
        "period" => spec.period === nothing ? nothing : [spec.period[1], spec.period[2]],
        "allow_period_index" => spec.allow_period_index,
        "mappings" => mappings,
    )
end

# ===========================================================================
# 公開 API: compare_results_v2
# ===========================================================================

"""
    compare_results_v2(left::SimulationResult, right::SimulationResult; spec::ComparisonSpec) -> ComparisonResultV2

日付・単位・頻度・概念定義・比較可能性を明示して 2 つの `SimulationResult` を比較する v2 API。

v1（[`compare_with_data`](@ref)）と異なり、配列位置での暗黙切り詰めや暗黙の単位/頻度変換を一切行わない:

- 日付 metadata があれば日付 intersection（`spec.period` 指定時はその範囲）で整列し、配列位置は使わない。
- 日付が無い結果同士の配列位置比較は `spec.allow_period_index=true` の明示許可時のみ行う。
- 単位差・頻度差は明示 `transform` が無ければ比較可能性を降格し、次に必要な変換を返す。
- stock/flow など概念種別が異なる場合は `:incompatible` とし数値比較しない。
- `mapping_type`（equivalent/proxy/partial/incompatible）を保持し、partial 以下では指標を制限・警告する。
- 比較不能でも例外で終了せず、理由（`assessment.reasons`）と次に必要な変換/証拠（`assessment.required_transforms`）を返す。

## 引数
- `left`  : モデル側の結果（`model_name` を left 名称とする）
- `right` : データ側の結果（`model_name` を right/data 名称とする）
- `spec`  : [`ComparisonSpec`](@ref)。比較モード・変数 mapping・整列期間・許可・モデル識別子

## 比較モード
- `:trajectory` / `:empirical_fit` : 水準乖離指標（rmse・mae・correlation 等）
- `:shock_response` : 方向・peak・持続性の指標
- `:mechanism` : 能力 metadata（#149）の構造化差分。数値 metric は返さない（`spec.left_model`/`right_model` が必要）

## エラー
- `spec.mappings` の変数名が `left`/`right` に存在しない場合は `ArgumentError`（呼び出し誤り）。
  比較可能性に関する問題は例外ではなく `assessment` に構造化して返す。

## 使用例
```julia
spec = ComparisonSpec(;
    mode = :trajectory,
    mappings = [VariableComparisonMapping(; model_variable="Y", data_variable="GDP")],
)
r = compare_results_v2(model_sr, data_sr; spec)
r.assessment.level               # :comparable / :partial / :insufficient / :incompatible
r.metrics["Y"].rmse              # レベルが comparable/partial の変数のみ
r.assessment.required_transforms # 比較可能にするために次に必要な変換
```
"""
function compare_results_v2(
    left::SimulationResult,
    right::SimulationResult;
    spec::ComparisonSpec,
)
    spec.mode === :mechanism && return _v2_mechanism(left, right, spec)

    # 変数の存在は呼び出し誤りとして例外（v1 と整合）
    for m in spec.mappings
        if !haskey(left, m.model_variable)
            throw(
                ArgumentError(
                    "変数 \"$(m.model_variable)\" がモデル結果（left）に存在しません。" *
                    "利用可能: $(sort(variable_names(left)))",
                ),
            )
        end
        if !haskey(right, m.data_variable)
            throw(
                ArgumentError(
                    "変数 \"$(m.data_variable)\" がデータ結果（right）に存在しません。" *
                    "利用可能: $(sort(variable_names(right)))",
                ),
            )
        end
    end

    alignment = Dict{String, AlignmentResult}()
    metrics = Dict{String, NamedTuple}()
    per_variable = Dict{String, Symbol}()
    reasons = String[]
    required = String[]
    warnings = String[]
    overall = :comparable

    for m in spec.mappings
        level, align, metric, rs, req, wr = _v2_assess_variable(left, right, m, spec)
        alignment[m.model_variable] = align
        per_variable[m.model_variable] = level
        metric !== nothing && (metrics[m.model_variable] = metric)
        append!(reasons, rs)
        append!(required, req)
        append!(warnings, wr)
        append!(warnings, m.caveats)
        overall = _worse(overall, level)
    end

    assessment =
        ComparabilityAssessment(overall, unique(reasons), unique(required), per_variable)
    return ComparisonResultV2(
        spec.mode,
        left.model_name,
        right.model_name,
        assessment,
        alignment,
        metrics,
        nothing,
        unique(warnings),
        _v2_provenance(spec),
    )
end

# ===========================================================================
# JSON 化（to_dict / to_json）
# ===========================================================================

# 非有限値を文字列タグへ符号化する（round-trip 用途ではなく表示・保存の安全化）。
# src/sfc/serialization.jl の `_sfc_encode_float` と同じ規約だが、compare_v2.jl は
# SFC 層に依存しないため独立に定義する。
_v2_json_safe(x::AbstractFloat) =
    isfinite(x) ? Float64(x) : (isnan(x) ? "NaN" : (x > 0 ? "Inf" : "-Inf"))
_v2_json_safe(x::AbstractVector) = Any[_v2_json_safe(v) for v in x]
_v2_json_safe(x) = x

"""
    to_dict(a::AlignmentResult) -> Dict{String, Any}
"""
to_dict(a::AlignmentResult) = Dict{String, Any}(
    "common_dates" => copy(a.common_dates),
    "excluded_dates" => copy(a.excluded_dates),
    "model_indices" => copy(a.model_indices),
    "data_indices" => copy(a.data_indices),
    "n_missing" => a.n_missing,
    "used_period_index" => a.used_period_index,
    "transform_history" => copy(a.transform_history),
)

"""
    to_dict(a::ComparabilityAssessment) -> Dict{String, Any}
"""
to_dict(a::ComparabilityAssessment) = Dict{String, Any}(
    "level" => String(a.level),
    "reasons" => copy(a.reasons),
    "required_transforms" => copy(a.required_transforms),
    "per_variable" => Dict{String, Any}(k => String(v) for (k, v) in a.per_variable),
)

"""
    to_dict(r::ComparisonResultV2) -> Dict{String, Any}

比較 API v2 の結果を JSON 安全な `Dict` へ変換する。非有限な指標値は文字列タグへ符号化する
（`_v2_json_safe`）。
"""
to_dict(r::ComparisonResultV2) = Dict{String, Any}(
    "mode" => String(r.mode),
    "model_name" => r.model_name,
    "data_source" => r.data_source,
    "assessment" => to_dict(r.assessment),
    "alignment" => Dict{String, Any}(k => to_dict(v) for (k, v) in r.alignment),
    "metrics" => Dict{String, Any}(
        var => Dict{String, Any}(String(k) => _v2_json_safe(v) for (k, v) in pairs(m))
        for (var, m) in r.metrics
    ),
    "mechanism_diff" => r.mechanism_diff,
    "warnings" => copy(r.warnings),
    "provenance" => r.provenance,
)

to_json(r::ComparisonResultV2) = JSON3.write(to_dict(r))
