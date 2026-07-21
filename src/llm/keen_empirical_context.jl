# keen_empirical_context.jl: Keen 実証分析（キャリブレーション・検証・regime 診断・
# 感応度・方法論）を LLM へ構造化して渡すための AnalysisContext 拡張型。
#
# 設計契約は docs/adr/0005-keen-ai-explanation-contract.md（§2 source reference・§3 型）。
#   - 値の認識論的性質を 7 つの固定カテゴリへ分離する（observed_data / measurement /
#     calibration / model_output / diagnostic_proxy / sensitivity / limitations）。
#   - すべての主要主張を安定 source ID へ結び付ける（EvidenceSource registry）。
#   - 欠損・発散由来の非有限値は 0 化せず JSON null（`nothing`）とする。
#   - 実証層成果物（KeenEmpiricalDataset / KeenValidationResult）を再計算せず写像する。
#
# 本ファイルは LLM API を呼ばない。数値の生成・再計算も行わない。実証層（keen_calibration.jl /
# keen_validation.jl / minsky_diagnostics.jl）・データ層は本ファイルの追加で一切変更されない。

"""
    KEEN_AI_CONTEXT_CONTRACT_VERSION

Keen 実証コンテキスト契約（`KeenEmpiricalContext`）の version。カテゴリ・必須 field・
source 参照契約を変更する場合に更新する（ADR 0005 §8.2）。
"""
const KEEN_AI_CONTEXT_CONTRACT_VERSION = "keen-ai-context/1.0.0"

"""
    KEEN_AI_PROMPT_VERSION

本コンテキスト作成時に想定する説明 prompt の version（後続 #131 が使用）。
"""
const KEEN_AI_PROMPT_VERSION = "keen-ai-explanation-prompt/1.0.0"

# 固定根拠カテゴリ（ADR 0005 §1.1）
const KEEN_EVIDENCE_CATEGORIES = (
    :observed_data,
    :measurement,
    :calibration,
    :model_output,
    :diagnostic_proxy,
    :sensitivity,
    :limitations,
)

# warning severity（ADR 0005 §5）
const KEEN_WARNING_SEVERITIES = (:info, :warning, :error, :blocking)

# 状態変数 Symbol（:ω 等）→ ASCII の安定 source ID 断片
const _KEEN_VAR_SLUG =
    Dict{Symbol, String}(:ω => "omega", :λ => "lambda", :d => "debt", :r => "rate")

# 非有限 Float を JSON null（nothing）へ。0 化はしない（欠損・発散は null）。
_kctx_num(x::Real) = isfinite(x) ? Float64(x) : nothing
_kctx_num(::Nothing) = nothing

# source ID の正規化（^[a-z][a-z0-9_.-]*$ を満たすように小文字化・不正文字を '-' へ）
function _kctx_slug(s::AbstractString)
    out = IOBuffer()
    for c in lowercase(String(s))
        if ('a' <= c <= 'z') || ('0' <= c <= '9') || c in ('_', '.', '-')
            print(out, c)
        else
            print(out, '-')
        end
    end
    r = String(take!(out))
    isempty(r) && return "x"
    (('a' <= r[1] <= 'z')) ? r : "x-" * r
end

# ===========================================================================
# source reference（ADR 0005 §2）
# ===========================================================================

"""
    EvidenceSource

主張の出所を追跡可能にする source registry 要素（ADR 0005 §2.1）。context 内で一意な
安定 ID を持ち、claim はこの `id` を参照する（配列 index に依存しないため）。

## フィールド
- `id::String` : `^[a-z][a-z0-9_.-]*\$` を満たす一意 ID
- `category::Symbol` : `KEEN_EVIDENCE_CATEGORIES` の 1 つ
- `context_path::String` : 実証層 report root からの JSON Pointer（情報用）
- `label::String` : 人間向け短名
- `provider` / `series_id` / `period_start` / `period_end` / `unit` / `method_id` /
  `artifact_path::Union{String,Nothing}` : 主張内容に応じた修飾情報（無ければ `nothing`）
"""
struct EvidenceSource
    id::String
    category::Symbol
    context_path::String
    label::String
    provider::Union{String, Nothing}
    series_id::Union{String, Nothing}
    period_start::Union{String, Nothing}
    period_end::Union{String, Nothing}
    unit::Union{String, Nothing}
    method_id::Union{String, Nothing}
    artifact_path::Union{String, Nothing}
end

function EvidenceSource(;
    id::String,
    category::Symbol,
    context_path::String,
    label::String,
    provider::Union{String, Nothing} = nothing,
    series_id::Union{String, Nothing} = nothing,
    period_start::Union{String, Nothing} = nothing,
    period_end::Union{String, Nothing} = nothing,
    unit::Union{String, Nothing} = nothing,
    method_id::Union{String, Nothing} = nothing,
    artifact_path::Union{String, Nothing} = nothing,
)
    occursin(r"^[a-z][a-z0-9_.-]*$", id) || throw(
        ArgumentError("EvidenceSource.id が不正です: $(repr(id))（^[a-z][a-z0-9_.-]*\$）"),
    )
    category in KEEN_EVIDENCE_CATEGORIES || throw(
        ArgumentError(
            "未知の category: $(repr(category))（有効: $(KEEN_EVIDENCE_CATEGORIES)）",
        ),
    )
    EvidenceSource(
        id,
        category,
        context_path,
        label,
        provider,
        series_id,
        period_start,
        period_end,
        unit,
        method_id,
        artifact_path,
    )
end

"""
    ExplanationWarning

説明の制御フローへ反映する warning（ADR 0005 §5）。severity が section status・許可される
主張・provider 呼び出し可否を規定する。

## フィールド
- `code::String` : 標準化 code（例 `"CALIBRATION_NOT_CONVERGED"`）
- `severity::Symbol` : `:info` / `:warning` / `:error` / `:blocking`
- `message::String`
- `affected_source_ids::Vector{String}` / `affected_sections::Vector{String}`
"""
struct ExplanationWarning
    code::String
    severity::Symbol
    message::String
    affected_source_ids::Vector{String}
    affected_sections::Vector{String}
end

function ExplanationWarning(;
    code::String,
    severity::Symbol,
    message::String,
    affected_source_ids::Vector{String} = String[],
    affected_sections::Vector{String} = String[],
)
    severity in KEEN_WARNING_SEVERITIES || throw(
        ArgumentError(
            "未知の severity: $(repr(severity))（有効: $(KEEN_WARNING_SEVERITIES)）",
        ),
    )
    ExplanationWarning(code, severity, message, affected_source_ids, affected_sections)
end

# ===========================================================================
# 個別サマリー型（ADR 0005 §3.2）
# ===========================================================================

"""
    AnalysisScope

分析対象の識別情報（国・期間・取得モード・比較モデル・split 境界）。
"""
struct AnalysisScope
    country::String
    mode::String
    sample_start::String
    sample_end::String
    n_obs::Int
    comparison_models::Vector{Symbol}
    calibration_period::Tuple{String, String}
    validation_period::Union{Tuple{String, String}, Nothing}
end

"""
    ObservedSeriesSummary

1 系列の観測値と provenance（ADR 0005 category=`observed_data`）。欠損・非有限は `nothing`
とし 0 化しない。変換後 unit は `measurement` と併記する前提で保持する。
"""
struct ObservedSeriesSummary
    variable::Symbol
    dates::Vector{String}
    values::Vector{Union{Float64, Nothing}}
    provider::String
    series_id::String
    source_id::String
    mode::Symbol
    period_start::String
    period_end::String
    unit::String
    original_unit::String
    conversion_formula::String
    n_used::Int
    n_source_missing::Int
    n_invalid::Int
    source_ids::Vector{String}
end

"""
    MethodologySummary

測定・変換・再現に必要な方法論情報（ADR 0005 category=`measurement`）。系列対応・単位・
変換式・頻度集約・欠損処理・各層の methodology version・seed を保持する。
"""
struct MethodologySummary
    series_mapping::Dict{Symbol, String}
    original_units::Dict{Symbol, String}
    output_units::Dict{Symbol, String}
    conversion_formulas::Dict{Symbol, String}
    aggregations::Dict{Symbol, String}
    dropped_dates::Vector{String}
    quality_flags::Dict{String, Any}
    r_mode::String
    r_param::Float64
    measurement_version::String
    calibration_version::String
    validation_version::String
    diagnostic_version::String
    seed::Int
    source_ids::Vector{String}
end

"""
    CalibrationSummary

限定キャリブレーションの設定・推定値・識別診断（ADR 0005 category=`calibration`）。推定値は
特定の標本・proxy・bounds・objective に依存する限定推定値であり、真値ではない。
"""
struct CalibrationSummary
    estimated_params::Vector{Symbol}
    estimated_values::Dict{Symbol, Float64}
    fixed_params::Dict{Symbol, Float64}
    fixed_basis::Dict{Symbol, Symbol}
    bounds::Dict{Symbol, Tuple{Float64, Float64}}
    initial_guess::Dict{Symbol, Float64}
    objective_method::Symbol
    objective_value::Float64
    objective_contributions::Dict{Symbol, Float64}
    weight_mode::Symbol
    weights_used::Dict{Symbol, Float64}
    converged::Bool
    iterations::Int
    n_obs_used::Int
    n_obs_excluded::Int
    excluded_reasons::Dict{String, Int}
    boundary_hits::Vector{Symbol}
    weak_identification::Bool
    nonunique_solutions::Bool
    alternative_solutions::Vector{Dict{Symbol, Float64}}
    sensitivity::Dict{Symbol, Float64}
    standard_errors_supported::Bool
    literature_objective::Float64
    methodology_version::String
    source_ids::Vector{String}
end

"""
    ModelOutputSummary

1 モデル（literature / calibrated）の full-sample 予測 trajectory の存在・発散情報
（ADR 0005 category=`model_output`）。fit metric は `ValidationSummary` が保持する。
"""
struct ModelOutputSummary
    model_label::Symbol
    initial_state_mode::Symbol
    n_points::Int
    variables::Vector{Symbol}
    diverged::Bool
    divergence_offset::Union{Int, Nothing}
    period_start::String
    period_end::String
    source_ids::Vector{String}
end

"""
    ValidationVariableFit

1 変数の fit metric。非有限は `nothing`（発散・欠損由来）。
"""
struct ValidationVariableFit
    variable::Symbol
    n_pairs::Int
    rmse::Union{Float64, Nothing}
    mae::Union{Float64, Nothing}
    correlation::Union{Float64, Nothing}
    mean_error::Union{Float64, Nothing}
    direction_accuracy::Union{Float64, Nothing}
    turning_point_timing_error::Union{Float64, Nothing}
    rmse_standardized::Union{Float64, Nothing}
end

"""
    ValidationEvaluationSummary

1 つの（モデル × 期間 × 初期値方式）の評価。in-sample と out-of-sample、初期値方式は別 metric。
"""
struct ValidationEvaluationSummary
    model_label::Symbol
    period::Symbol
    initial_state_mode::Symbol
    n_obs::Int
    diverged::Bool
    divergence_offset::Union{Int, Nothing}
    fits::Vector{ValidationVariableFit}
    source_id::String
end

"""
    ValidationSummary

in-sample / out-of-sample 検証結果（ADR 0005 category=`model_output` の fit 側）。literature と
calibrated の悪化も隠さず保持する。
"""
struct ValidationSummary
    evaluations::Vector{ValidationEvaluationSummary}
    calibrated_worse_than_literature::Bool
    aggregate_rmse_literature::Union{Float64, Nothing}
    aggregate_rmse_calibrated::Union{Float64, Nothing}
    aggregate_rmse_period::String
    split_info::Dict{String, Any}
    methodology_version::String
    source_ids::Vector{String}
end

"""
    RegimeDiagnosticSummary

1 subject（observed proxy / literature model / calibrated model）の金融不安定性診断
（ADR 0005 category=`diagnostic_proxy`）。observed proxy は集計系列への操作的診断であり、
モデル内生 regime や企業別実測分類ではない。
"""
struct RegimeDiagnosticSummary
    subject::Symbol
    methodology_version::String
    amortization_rate::Float64
    regime_share::Dict{Symbol, Float64}
    first_speculative_time::Union{Int, Nothing}
    first_ponzi_time::Union{Int, Nothing}
    recovery_to_hedge_time::Union{Int, Nothing}
    peak_debt_ratio::Union{Float64, Nothing}
    min_interest_coverage_ratio::Union{Float64, Nothing}
    min_debt_service_coverage_ratio::Union{Float64, Nothing}
    min_ponzi_margin::Union{Float64, Nothing}
    min_hedge_margin::Union{Float64, Nothing}
    diverged::Bool
    divergence_time::Union{Int, Nothing}
    proxy_limitation::String
    source_ids::Vector{String}
end

"""
    SensitivitySummary

1 感応度シナリオの結果と base との差（ADR 0005 category=`sensitivity`）。頑健性は実際に変更した
仮定と範囲内でのみ主張できる。
"""
struct SensitivitySummary
    scenario_name::String
    kind::Symbol
    note::String
    reused_base_calibration::Bool
    estimated::Dict{Symbol, Float64}
    estimated_delta_vs_base::Dict{Symbol, Float64}
    objective_value::Float64
    objective_delta_vs_base::Union{Float64, Nothing}
    fit_period::Symbol
    fit_rmse::Dict{Symbol, Union{Float64, Nothing}}
    fit_rmse_delta_vs_base::Dict{Symbol, Union{Float64, Nothing}}
    regime_share::Dict{Symbol, Float64}
    first_speculative_time::Union{Int, Nothing}
    first_ponzi_time::Union{Int, Nothing}
    peak_debt_ratio::Union{Float64, Nothing}
    n_transitions::Int
    diverged::Bool
    sign_reversal::Bool
    robustness_status::Symbol
    source_ids::Vector{String}
end

"""
    LimitationSummary

安定 code 付きの限界・注意事項（ADR 0005 category=`limitations`）。自由文だけに潰さず code と
根拠 category、affected source IDs を保持する。
"""
struct LimitationSummary
    code::String
    text::String
    category::Symbol
    source_ids::Vector{String}
end

"""
    KeenEmpiricalContext

Keen 実証分析を LLM へ渡すための構造化コンテキスト（ADR 0005 §3.2）。認識論的性質の異なる
情報を category 別 field へ分離し、全主張を source registry へ結び付ける。分析が未実施・欠損の
section は空コレクション / `nothing` で表し、simulation-only や一部欠損の状態も表現できる。

`AnalysisContext` の optional field `keen_empirical` として保持し、`to_dict` / `to_json` /
`to_compact_dict` は本 field が存在するときだけ `keen_empirical` key を追加する。

## 生成
- 主 adapter: [`KeenEmpiricalContext(dataset::KeenEmpiricalDataset, result::KeenValidationResult)`](@ref)
  実証層成果物の dates / 系列 / trajectory / summary を**再計算せず**写像する。

## フィールド
`contract_version` / `analysis_scope` / `observed_data` / `measurement` / `calibration` /
`model_outputs` / `validation` / `regime_diagnostics` / `sensitivity` / `limitations` /
`warnings` / `sources` / `prompt_version`。
"""
struct KeenEmpiricalContext
    contract_version::String
    analysis_scope::AnalysisScope
    observed_data::Vector{ObservedSeriesSummary}
    measurement::Union{MethodologySummary, Nothing}
    calibration::Union{CalibrationSummary, Nothing}
    model_outputs::Vector{ModelOutputSummary}
    validation::Union{ValidationSummary, Nothing}
    regime_diagnostics::Vector{RegimeDiagnosticSummary}
    sensitivity::Vector{SensitivitySummary}
    limitations::Vector{LimitationSummary}
    warnings::Vector{ExplanationWarning}
    sources::Dict{String, EvidenceSource}
    prompt_version::String
end

# ===========================================================================
# 実証層成果物からの adapter（ADR 0005 §3.2 / §3.3）
# ===========================================================================

# regime enum Dict → Symbol キー Dict（"ponzi" 等）
_kctx_regime_share(d) = Dict{Symbol, Float64}(Symbol(string(k)) => v for (k, v) in d)

# observed 系列値を Union{Float64,Nothing}（非有限は nothing）へ
_kctx_obs_values(v::AbstractVector) = Union{Float64, Nothing}[_kctx_num(x) for x in v]

# MinskyDiagnosticsSummary → RegimeDiagnosticSummary
function _kctx_regime_summary(
    subject::Symbol,
    s::MinskyDiagnosticsSummary,
    proxy_limitation::String,
    source_id::String,
)
    RegimeDiagnosticSummary(
        subject,
        s.methodology_version,
        s.config.amortization_rate,
        _kctx_regime_share(s.regime_share_of_valid),
        s.first_speculative_time,
        s.first_ponzi_time,
        s.recovery_to_hedge_time,
        s.peak_debt_ratio,
        s.min_interest_coverage_ratio,
        s.min_debt_service_coverage_ratio,
        s.min_ponzi_margin,
        s.min_hedge_margin,
        s.diverged,
        s.divergence_time,
        proxy_limitation,
        [source_id],
    )
end

# KeenVariableMetrics → ValidationVariableFit（非有限 → nothing）
function _kctx_variable_fit(mt::KeenVariableMetrics)
    ValidationVariableFit(
        mt.variable,
        mt.n_pairs,
        _kctx_num(mt.rmse),
        _kctx_num(mt.mae),
        _kctx_num(mt.correlation),
        _kctx_num(mt.mean_error),
        _kctx_num(mt.direction_accuracy),
        mt.turning_point_timing_error,
        _kctx_num(mt.rmse_standardized),
    )
end

# eval → 安定 source ID
function _kctx_eval_source_id(e::KeenPeriodEvaluation)
    p = e.period === :in_sample ? "is" : "oos"
    m = replace(string(e.initial_state_mode), "_" => "-")
    "validation.$(e.model_label).$(p).$(m)"
end

# base の推定値・fit を取り出す（感応度 delta の基準）
function _kctx_base_sensitivity(result::KeenValidationResult)
    for r in result.sensitivity
        r.scenario.name == "base" && return r
    end
    isempty(result.sensitivity) ? nothing : result.sensitivity[1]
end

function _kctx_sensitivity_summary(
    r::KeenSensitivityResult,
    base::Union{KeenSensitivityResult, Nothing},
    source_id::String,
)
    is_base = base !== nothing && r.scenario.name == base.scenario.name
    est_delta = Dict{Symbol, Float64}()
    if base !== nothing
        for (k, v) in r.estimated
            haskey(base.estimated, k) && (est_delta[k] = v - base.estimated[k])
        end
    end
    obj_delta =
        base === nothing ? nothing : _kctx_num(r.objective_value - base.objective_value)
    fit = Dict{Symbol, Union{Float64, Nothing}}(k => _kctx_num(v) for (k, v) in r.fit_rmse)
    fit_delta = Dict{Symbol, Union{Float64, Nothing}}()
    if base !== nothing
        for (k, v) in r.fit_rmse
            if haskey(base.fit_rmse, k) && isfinite(v) && isfinite(base.fit_rmse[k])
                fit_delta[k] = v - base.fit_rmse[k]
            else
                fit_delta[k] = nothing
            end
        end
    end
    # 符号反転: 推定値のいずれかが base と符号反転
    sign_reversal = false
    if base !== nothing
        for (k, v) in r.estimated
            if haskey(base.estimated, k) &&
               sign(v) != sign(base.estimated[k]) &&
               v != 0.0 &&
               base.estimated[k] != 0.0
                sign_reversal = true
            end
        end
    end
    # 頑健性: base 自身は :base。発散差・符号反転があれば :unstable、それ以外は :stable
    robustness = if is_base
        :base
    elseif sign_reversal || (base !== nothing && r.diverged != base.diverged)
        :unstable
    else
        :stable
    end
    SensitivitySummary(
        r.scenario.name,
        r.scenario.kind,
        r.scenario.note,
        r.reused_base_calibration,
        copy(r.estimated),
        est_delta,
        r.objective_value,
        obj_delta,
        r.fit_period,
        fit,
        fit_delta,
        _kctx_regime_share(r.regime_share),
        r.first_speculative_time,
        r.first_ponzi_time,
        r.peak_debt_ratio,
        r.n_transitions,
        r.diverged,
        sign_reversal,
        robustness,
        [source_id],
    )
end

# 診断 subject が発散を除いて ponzi / speculative に到達したかの集合（regime mismatch 判定用）
function _kctx_reached_regimes(s::MinskyDiagnosticsSummary)
    reached = Set{Symbol}()
    s.first_speculative_time !== nothing && push!(reached, :speculative)
    s.first_ponzi_time !== nothing && push!(reached, :ponzi)
    reached
end

"""
    KeenEmpiricalContext(dataset::KeenEmpiricalDataset, result::KeenValidationResult;
                         mode=nothing, prompt_version=KEEN_AI_PROMPT_VERSION) -> KeenEmpiricalContext

実証層成果物から Keen 実証コンテキストを構築する主 adapter（ADR 0005 §3.2）。dataset の
dates / observed series と result の trajectory / summary を**再計算せず**写像し、source registry・
warning を組み立てる。非有限値は 0 化せず `nothing`（JSON null）とする。

`dataset` に validation split が無い等で一部の分析が欠けている場合も、該当 section を空 /
`nothing` として simulation-only に近い context を表現できる。
"""
function KeenEmpiricalContext(
    dataset::KeenEmpiricalDataset,
    result::KeenValidationResult;
    mode::Union{Symbol, Nothing} = nothing,
    prompt_version::String = KEEN_AI_PROMPT_VERSION,
)
    sources = Dict{String, EvidenceSource}()
    add_src!(s::EvidenceSource) = (sources[s.id] = s; s.id)

    resolved_mode =
        mode === nothing ? string(get(dataset.metadata, "mode", "")) : string(mode)
    country = string(get(dataset.metadata, "country", ""))
    n = length(dataset)
    sample_start = isempty(dataset.dates) ? "" : dataset.dates[1]
    sample_end = isempty(dataset.dates) ? "" : dataset.dates[end]

    cal_start = get(result.split_info, "calibration_start", "")
    cal_end = get(result.split_info, "calibration_end", "")
    val_start = get(result.split_info, "validation_start", "")
    val_end = get(result.split_info, "validation_end", "")
    scope = AnalysisScope(
        country,
        resolved_mode,
        sample_start,
        sample_end,
        n,
        copy(result.config.comparison_models),
        (String(cal_start), String(cal_end)),
        isempty(String(val_start)) ? nothing : (String(val_start), String(val_end)),
    )

    # ---- observed_data ----
    observed = ObservedSeriesSummary[]
    obs_series_vals =
        Dict(:ω => dataset.ω, :λ => dataset.λ, :d => dataset.d, :r => dataset.r)
    for v in (:ω, :λ, :d, :r)
        haskey(dataset.provenance, v) || continue
        p = dataset.provenance[v]
        slug = get(_KEEN_VAR_SLUG, v, _kctx_slug(string(v)))
        sid = add_src!(
            EvidenceSource(;
                id = "obs.$(slug)",
                category = :observed_data,
                context_path = "/dataset/series/$(v)",
                label = "観測系列 $(v)（$(p.series_id)）",
                provider = p.source,
                series_id = p.series_id,
                period_start = p.adopted_start,
                period_end = p.adopted_end,
                unit = "model-unit (ratio)",
                method_id = string(get(dataset.metadata, "methodology_version", "")),
            ),
        )
        push!(
            observed,
            ObservedSeriesSummary(
                v,
                copy(dataset.dates),
                _kctx_obs_values(obs_series_vals[v]),
                p.source,
                p.series_id,
                p.source_id,
                p.mode,
                p.adopted_start,
                p.adopted_end,
                "model-unit (ratio)",
                p.original_unit,
                p.conversion_formula,
                p.n_used,
                p.n_source_missing,
                p.n_invalid,
                [sid],
            ),
        )
    end

    # ---- measurement ----
    meas_sid = add_src!(
        EvidenceSource(;
            id = "measurement.methodology",
            category = :measurement,
            context_path = "/methodology",
            label = "観測方程式・単位変換・頻度集約",
            method_id = string(get(dataset.metadata, "methodology_version", "")),
        ),
    )
    series_mapping = Dict{Symbol, String}()
    original_units = Dict{Symbol, String}()
    output_units = Dict{Symbol, String}()
    conversion_formulas = Dict{Symbol, String}()
    aggregations = Dict{Symbol, String}()
    for (v, p) in dataset.provenance
        series_mapping[v] = p.series_id
        original_units[v] = p.original_unit
        output_units[v] = "model-unit (ratio)"
        conversion_formulas[v] = p.conversion_formula
        aggregations[v] = string(p.aggregation)
    end
    measurement = MethodologySummary(
        series_mapping,
        original_units,
        output_units,
        conversion_formulas,
        aggregations,
        copy(dataset.dropped_dates),
        copy(dataset.quality_flags),
        string(dataset.config.r_mode),
        dataset.r_param,
        string(get(dataset.metadata, "methodology_version", "")),
        result.calibration_result.methodology_version,
        result.methodology_version,
        result.regime_comparison.observed_summary.methodology_version,
        result.config.calibration_config.seed,
        [meas_sid],
    )

    # ---- calibration ----
    cal = result.calibration_result
    cal_sid = add_src!(
        EvidenceSource(;
            id = "calibration.base",
            category = :calibration,
            context_path = "/validation/calibration",
            label = "限定キャリブレーション（採用解）",
            period_start = String(cal_start),
            period_end = String(cal_end),
            method_id = cal.methodology_version,
        ),
    )
    calibration = CalibrationSummary(
        copy(cal.config.estimated_params),
        copy(cal.estimated),
        copy(cal.fixed),
        copy(cal.config.fixed_basis),
        copy(cal.config.bounds),
        copy(cal.config.initial_guess),
        cal.config.objective_method,
        cal.objective_value,
        copy(cal.objective_contributions),
        cal.config.weight_mode,
        copy(cal.weights_used),
        cal.converged,
        cal.iterations,
        cal.n_obs_used,
        cal.n_obs_excluded,
        copy(cal.excluded_reasons),
        copy(cal.boundary_hits),
        cal.weak_identification,
        cal.nonunique_solutions,
        [copy(a) for a in cal.alternative_solutions],
        copy(cal.sensitivity),
        cal.standard_errors_supported,
        cal.literature_objective,
        cal.methodology_version,
        [cal_sid],
    )

    # ---- model_outputs（full-sample trajectory バンドルから）----
    model_outputs = ModelOutputSummary[]
    tb = result.trajectories
    for label in (:literature, :calibrated)
        label in result.config.comparison_models || continue
        traj = label === :literature ? tb.literature : tb.calibrated
        # 発散オフセット（最初に非有限になった位置）
        off = nothing
        npts = length(tb.times)
        for k in 1:npts
            if !(
                isfinite(get(traj[:ω], k, NaN)) &&
                isfinite(get(traj[:λ], k, NaN)) &&
                isfinite(get(traj[:d], k, NaN))
            )
                off = k
                break
            end
        end
        msid = add_src!(
            EvidenceSource(;
                id = "model.$(label)",
                category = :model_output,
                context_path = "/validation/trajectories/$(label)",
                label = "$(label) モデルの full-sample 予測 trajectory",
                period_start = sample_start,
                period_end = sample_end,
                method_id = result.methodology_version,
            ),
        )
        push!(
            model_outputs,
            ModelOutputSummary(
                label,
                :observed_start,
                npts,
                collect(keys(traj)),
                off !== nothing,
                off,
                sample_start,
                sample_end,
                [msid],
            ),
        )
    end

    # ---- validation（評価別 metric）----
    eval_summaries = ValidationEvaluationSummary[]
    val_source_ids = String[]
    for (i, e) in enumerate(result.evaluations)
        eid = _kctx_eval_source_id(e)
        add_src!(
            EvidenceSource(;
                id = eid,
                category = :model_output,
                context_path = "/validation/evaluations/$(i - 1)",
                label = "$(e.model_label) / $(e.period) / $(e.initial_state_mode) の検証",
                method_id = result.methodology_version,
            ),
        )
        push!(val_source_ids, eid)
        fits = ValidationVariableFit[
            _kctx_variable_fit(e.metrics[v]) for
            v in result.config.eval_variables if haskey(e.metrics, v)
        ]
        push!(
            eval_summaries,
            ValidationEvaluationSummary(
                e.model_label,
                e.period,
                e.initial_state_mode,
                e.n_obs,
                e.diverged,
                e.divergence_offset,
                fits,
                eid,
            ),
        )
    end
    validation = ValidationSummary(
        eval_summaries,
        result.calibrated_worse_than_literature,
        _kctx_num(get(result.metadata, "aggregate_rmse_literature", NaN)),
        _kctx_num(get(result.metadata, "aggregate_rmse_calibrated", NaN)),
        string(get(result.metadata, "aggregate_rmse_period", "")),
        copy(result.split_info),
        result.methodology_version,
        val_source_ids,
    )

    # ---- regime_diagnostics ----
    rc = result.regime_comparison
    reg_note = rc.note
    regime_diagnostics = RegimeDiagnosticSummary[]
    reg_specs = (
        (:observed_proxy, "regime.observed-proxy", rc.observed_summary),
        (:literature_model, "regime.literature-model", rc.literature_summary),
        (:calibrated_model, "regime.calibrated-model", rc.calibrated_summary),
    )
    for (subject, rid, summ) in reg_specs
        add_src!(
            EvidenceSource(;
                id = rid,
                category = :diagnostic_proxy,
                context_path = "/validation/regime_comparison/$(_kctx_slug(string(subject)))",
                label = "金融不安定性診断: $(subject)",
                method_id = summ.methodology_version,
            ),
        )
        push!(regime_diagnostics, _kctx_regime_summary(subject, summ, reg_note, rid))
    end

    # ---- sensitivity ----
    base_sens = _kctx_base_sensitivity(result)
    sensitivity = SensitivitySummary[]
    for (i, r) in enumerate(result.sensitivity)
        sid = "sensitivity.$(_kctx_slug(r.scenario.name))"
        add_src!(
            EvidenceSource(;
                id = sid,
                category = :sensitivity,
                context_path = "/validation/sensitivity/$(i - 1)",
                label = "感応度シナリオ: $(r.scenario.name)",
                method_id = result.methodology_version,
            ),
        )
        push!(sensitivity, _kctx_sensitivity_summary(r, base_sens, sid))
    end

    # ---- limitations（caveats を安定 code 付きへ）----
    lim_sid = add_src!(
        EvidenceSource(;
            id = "limitation.caveats",
            category = :limitations,
            context_path = "/validation/caveats",
            label = "実証層の固定 caveats",
            method_id = result.methodology_version,
        ),
    )
    limitations = LimitationSummary[]
    for (i, c) in enumerate(result.caveats)
        push!(
            limitations,
            LimitationSummary("KEEN_CAVEAT_$(i)", c, :limitations, [lim_sid]),
        )
    end

    # ---- warnings（構造化フラグと自由文 warning を標準 code へ）----
    warnings = _kctx_build_warnings(result, cal_sid, val_source_ids, rc)

    KeenEmpiricalContext(
        KEEN_AI_CONTEXT_CONTRACT_VERSION,
        scope,
        observed,
        measurement,
        calibration,
        model_outputs,
        validation,
        regime_diagnostics,
        sensitivity,
        limitations,
        warnings,
        sources,
        prompt_version,
    )
end

# 構造化フラグ・自由文 warning を ADR 0005 §5 の標準 code / severity へ写像する。
function _kctx_build_warnings(
    result::KeenValidationResult,
    cal_sid::String,
    val_source_ids::Vector{String},
    rc::KeenRegimeComparison,
)
    warnings = ExplanationWarning[]
    cal = result.calibration_result

    if !cal.converged
        push!(
            warnings,
            ExplanationWarning(;
                code = "CALIBRATION_NOT_CONVERGED",
                severity = :error,
                message = "採用した推定解が収束していません。推定値を真値として解釈しないでください。",
                affected_source_ids = [cal_sid],
                affected_sections = ["calibration_interpretation"],
            ),
        )
    end
    if cal.weak_identification
        push!(
            warnings,
            ExplanationWarning(;
                code = "WEAK_IDENTIFICATION",
                severity = :warning,
                message = "推定は弱識別の兆候があります（平坦な objective・複数局所解）。推定値の一意性・精度を主張しないでください。",
                affected_source_ids = [cal_sid],
                affected_sections = ["calibration_interpretation"],
            ),
        )
    end
    if cal.nonunique_solutions
        push!(
            warnings,
            ExplanationWarning(;
                code = "NONUNIQUE_SOLUTION",
                severity = :warning,
                message = "採用解と objective が近い異なる解が存在します（非一意）。",
                affected_source_ids = [cal_sid],
                affected_sections = ["calibration_interpretation"],
            ),
        )
    end
    if !isempty(cal.boundary_hits)
        push!(
            warnings,
            ExplanationWarning(;
                code = "PARAMETER_AT_BOUND",
                severity = :warning,
                message = "推定値が bounds に張り付いています: $(cal.boundary_hits)。",
                affected_source_ids = [cal_sid],
                affected_sections = ["calibration_interpretation"],
            ),
        )
    end
    if result.calibrated_worse_than_literature
        push!(
            warnings,
            ExplanationWarning(;
                code = "OOS_WORSE_THAN_LITERATURE",
                severity = :warning,
                message = "calibrated の集計 RMSE が literature default より大きく、当てはまりが改善していません。妥当性・予測力を主張しないでください。",
                affected_source_ids = copy(val_source_ids),
                affected_sections = ["validation_assessment"],
            ),
        )
    end
    for (i, e) in enumerate(result.evaluations)
        if e.diverged
            push!(
                warnings,
                ExplanationWarning(;
                    code = "MODEL_DIVERGED",
                    severity = :error,
                    message = "$(e.model_label) の $(e.period)（$(e.initial_state_mode)）予測が発散しました（offset=$(e.divergence_offset)）。発散後を補間しないでください。",
                    affected_source_ids = [_kctx_eval_source_id(e)],
                    affected_sections = ["validation_assessment", "regime_assessment"],
                ),
            )
        end
    end
    # regime mismatch: observed proxy と calibrated model の到達 regime 集合が不一致
    obs_reached = _kctx_reached_regimes(rc.observed_summary)
    cal_reached = _kctx_reached_regimes(rc.calibrated_summary)
    if obs_reached != cal_reached
        push!(
            warnings,
            ExplanationWarning(;
                code = "REGIME_MISMATCH",
                severity = :warning,
                message = "observed proxy と calibrated model の到達 regime が一致しません。両者を別表示し、一致を主張しないでください。",
                affected_source_ids = ["regime.observed-proxy", "regime.calibrated-model"],
                affected_sections = ["regime_assessment"],
            ),
        )
    end
    # sensitivity 不安定: base 以外に unstable シナリオがある
    base_sens = _kctx_base_sensitivity(result)
    unstable = false
    for r in result.sensitivity
        r.scenario.name == "base" && continue
        summ = _kctx_sensitivity_summary(
            r,
            base_sens,
            "sensitivity.$(_kctx_slug(r.scenario.name))",
        )
        summ.robustness_status === :unstable && (unstable = true)
    end
    if unstable
        push!(
            warnings,
            ExplanationWarning(;
                code = "SENSITIVITY_UNSTABLE",
                severity = :warning,
                message = "感応度シナリオ間で符号反転または発散差があります。頑健性を主張せず、検証済み範囲のみ記述してください。",
                affected_source_ids = String[],
                affected_sections = ["sensitivity_and_robustness"],
            ),
        )
    end
    warnings
end

# ===========================================================================
# JSON 化（to_dict）。非有限は _kctx_num で null 化済み or ここで sanitize する
# ===========================================================================

function to_dict(s::EvidenceSource)
    d = Dict{String, Any}(
        "id" => s.id,
        "category" => string(s.category),
        "context_path" => s.context_path,
        "label" => s.label,
    )
    for (k, v) in (
        ("provider", s.provider),
        ("series_id", s.series_id),
        ("period_start", s.period_start),
        ("period_end", s.period_end),
        ("unit", s.unit),
        ("method_id", s.method_id),
        ("artifact_path", s.artifact_path),
    )
        v !== nothing && (d[k] = v)
    end
    d
end

to_dict(w::ExplanationWarning) = Dict{String, Any}(
    "code" => w.code,
    "severity" => string(w.severity),
    "message" => w.message,
    "affected_source_ids" => copy(w.affected_source_ids),
    "affected_sections" => copy(w.affected_sections),
)

to_dict(sc::AnalysisScope) = Dict{String, Any}(
    "country" => sc.country,
    "mode" => sc.mode,
    "sample_start" => sc.sample_start,
    "sample_end" => sc.sample_end,
    "n_obs" => sc.n_obs,
    "comparison_models" => String.(sc.comparison_models),
    "calibration_period" => [sc.calibration_period[1], sc.calibration_period[2]],
    "validation_period" =>
        sc.validation_period === nothing ? nothing :
        [sc.validation_period[1], sc.validation_period[2]],
)

to_dict(o::ObservedSeriesSummary) = Dict{String, Any}(
    "variable" => string(o.variable),
    "dates" => copy(o.dates),
    "values" => Any[v for v in o.values],
    "provider" => o.provider,
    "series_id" => o.series_id,
    "source_id" => o.source_id,
    "mode" => string(o.mode),
    "period_start" => o.period_start,
    "period_end" => o.period_end,
    "unit" => o.unit,
    "original_unit" => o.original_unit,
    "conversion_formula" => o.conversion_formula,
    "n_used" => o.n_used,
    "n_source_missing" => o.n_source_missing,
    "n_invalid" => o.n_invalid,
    "source_ids" => copy(o.source_ids),
)

_kctx_sym_dict(d) = Dict{String, Any}(string(k) => v for (k, v) in d)
_kctx_sym_num_dict(d) = Dict{String, Any}(string(k) => _kctx_num(v) for (k, v) in d)
_kctx_bounds_dict(d) = Dict{String, Any}(string(k) => [v[1], v[2]] for (k, v) in d)

to_dict(m::MethodologySummary) = Dict{String, Any}(
    "series_mapping" => _kctx_sym_dict(m.series_mapping),
    "original_units" => _kctx_sym_dict(m.original_units),
    "output_units" => _kctx_sym_dict(m.output_units),
    "conversion_formulas" => _kctx_sym_dict(m.conversion_formulas),
    "aggregations" => _kctx_sym_dict(m.aggregations),
    "dropped_dates" => copy(m.dropped_dates),
    "quality_flags" => m.quality_flags,
    "r_mode" => m.r_mode,
    "r_param" => _kctx_num(m.r_param),
    "measurement_version" => m.measurement_version,
    "calibration_version" => m.calibration_version,
    "validation_version" => m.validation_version,
    "diagnostic_version" => m.diagnostic_version,
    "seed" => m.seed,
    "source_ids" => copy(m.source_ids),
)

to_dict(c::CalibrationSummary) = Dict{String, Any}(
    "estimated_params" => String.(c.estimated_params),
    "estimated_values" => _kctx_sym_num_dict(c.estimated_values),
    "fixed_params" => _kctx_sym_num_dict(c.fixed_params),
    "fixed_basis" =>
        Dict{String, Any}(string(k) => string(v) for (k, v) in c.fixed_basis),
    "bounds" => _kctx_bounds_dict(c.bounds),
    "initial_guess" => _kctx_sym_num_dict(c.initial_guess),
    "objective_method" => string(c.objective_method),
    "objective_value" => _kctx_num(c.objective_value),
    "objective_contributions" => _kctx_sym_num_dict(c.objective_contributions),
    "weight_mode" => string(c.weight_mode),
    "weights_used" => _kctx_sym_num_dict(c.weights_used),
    "converged" => c.converged,
    "iterations" => c.iterations,
    "n_obs_used" => c.n_obs_used,
    "n_obs_excluded" => c.n_obs_excluded,
    "excluded_reasons" => _kctx_sym_dict(c.excluded_reasons),
    "boundary_hits" => String.(c.boundary_hits),
    "weak_identification" => c.weak_identification,
    "nonunique_solutions" => c.nonunique_solutions,
    "alternative_solutions" =>
        Any[_kctx_sym_num_dict(a) for a in c.alternative_solutions],
    "sensitivity" => _kctx_sym_num_dict(c.sensitivity),
    "standard_errors_supported" => c.standard_errors_supported,
    "literature_objective" => _kctx_num(c.literature_objective),
    "methodology_version" => c.methodology_version,
    "source_ids" => copy(c.source_ids),
)

to_dict(mo::ModelOutputSummary) = Dict{String, Any}(
    "model_label" => string(mo.model_label),
    "initial_state_mode" => string(mo.initial_state_mode),
    "n_points" => mo.n_points,
    "variables" => String.(mo.variables),
    "diverged" => mo.diverged,
    "divergence_offset" => mo.divergence_offset,
    "period_start" => mo.period_start,
    "period_end" => mo.period_end,
    "source_ids" => copy(mo.source_ids),
)

to_dict(f::ValidationVariableFit) = Dict{String, Any}(
    "variable" => string(f.variable),
    "n_pairs" => f.n_pairs,
    "rmse" => f.rmse,
    "mae" => f.mae,
    "correlation" => f.correlation,
    "mean_error" => f.mean_error,
    "direction_accuracy" => f.direction_accuracy,
    "turning_point_timing_error" => f.turning_point_timing_error,
    "rmse_standardized" => f.rmse_standardized,
)

to_dict(e::ValidationEvaluationSummary) = Dict{String, Any}(
    "model_label" => string(e.model_label),
    "period" => string(e.period),
    "initial_state_mode" => string(e.initial_state_mode),
    "n_obs" => e.n_obs,
    "diverged" => e.diverged,
    "divergence_offset" => e.divergence_offset,
    "fits" => Any[to_dict(f) for f in e.fits],
    "source_id" => e.source_id,
)

to_dict(v::ValidationSummary) = Dict{String, Any}(
    "evaluations" => Any[to_dict(e) for e in v.evaluations],
    "calibrated_worse_than_literature" => v.calibrated_worse_than_literature,
    "aggregate_rmse_literature" => v.aggregate_rmse_literature,
    "aggregate_rmse_calibrated" => v.aggregate_rmse_calibrated,
    "aggregate_rmse_period" => v.aggregate_rmse_period,
    "split_info" => v.split_info,
    "methodology_version" => v.methodology_version,
    "source_ids" => copy(v.source_ids),
)

to_dict(r::RegimeDiagnosticSummary) = Dict{String, Any}(
    "subject" => string(r.subject),
    "methodology_version" => r.methodology_version,
    "amortization_rate" => _kctx_num(r.amortization_rate),
    "regime_share" => _kctx_sym_num_dict(r.regime_share),
    "first_speculative_time" => r.first_speculative_time,
    "first_ponzi_time" => r.first_ponzi_time,
    "recovery_to_hedge_time" => r.recovery_to_hedge_time,
    "peak_debt_ratio" => r.peak_debt_ratio,
    "min_interest_coverage_ratio" => r.min_interest_coverage_ratio,
    "min_debt_service_coverage_ratio" => r.min_debt_service_coverage_ratio,
    "min_ponzi_margin" => r.min_ponzi_margin,
    "min_hedge_margin" => r.min_hedge_margin,
    "diverged" => r.diverged,
    "divergence_time" => r.divergence_time,
    "proxy_limitation" => r.proxy_limitation,
    "source_ids" => copy(r.source_ids),
)

to_dict(s::SensitivitySummary) = Dict{String, Any}(
    "scenario_name" => s.scenario_name,
    "kind" => string(s.kind),
    "note" => s.note,
    "reused_base_calibration" => s.reused_base_calibration,
    "estimated" => _kctx_sym_num_dict(s.estimated),
    "estimated_delta_vs_base" => _kctx_sym_num_dict(s.estimated_delta_vs_base),
    "objective_value" => _kctx_num(s.objective_value),
    "objective_delta_vs_base" => s.objective_delta_vs_base,
    "fit_period" => string(s.fit_period),
    "fit_rmse" => Dict{String, Any}(string(k) => v for (k, v) in s.fit_rmse),
    "fit_rmse_delta_vs_base" =>
        Dict{String, Any}(string(k) => v for (k, v) in s.fit_rmse_delta_vs_base),
    "regime_share" => _kctx_sym_num_dict(s.regime_share),
    "first_speculative_time" => s.first_speculative_time,
    "first_ponzi_time" => s.first_ponzi_time,
    "peak_debt_ratio" => s.peak_debt_ratio,
    "n_transitions" => s.n_transitions,
    "diverged" => s.diverged,
    "sign_reversal" => s.sign_reversal,
    "robustness_status" => string(s.robustness_status),
    "source_ids" => copy(s.source_ids),
)

to_dict(l::LimitationSummary) = Dict{String, Any}(
    "code" => l.code,
    "text" => l.text,
    "category" => string(l.category),
    "source_ids" => copy(l.source_ids),
)

"""
    to_dict(ctx::KeenEmpiricalContext) -> Dict{String, Any}

`KeenEmpiricalContext` を JSON 化可能な `Dict` へ変換する。未実施の section は空コレクション /
`nothing`、非有限値は `null`（`nothing`）として保持する。
"""
function to_dict(ctx::KeenEmpiricalContext)
    Dict{String, Any}(
        "contract_version" => ctx.contract_version,
        "analysis_scope" => to_dict(ctx.analysis_scope),
        "observed_data" => Any[to_dict(o) for o in ctx.observed_data],
        "measurement" => ctx.measurement === nothing ? nothing : to_dict(ctx.measurement),
        "calibration" => ctx.calibration === nothing ? nothing : to_dict(ctx.calibration),
        "model_outputs" => Any[to_dict(m) for m in ctx.model_outputs],
        "validation" => ctx.validation === nothing ? nothing : to_dict(ctx.validation),
        "regime_diagnostics" => Any[to_dict(r) for r in ctx.regime_diagnostics],
        "sensitivity" => Any[to_dict(s) for s in ctx.sensitivity],
        "limitations" => Any[to_dict(l) for l in ctx.limitations],
        "warnings" => Any[to_dict(w) for w in ctx.warnings],
        "sources" => Dict{String, Any}(k => to_dict(v) for (k, v) in ctx.sources),
        "prompt_version" => ctx.prompt_version,
    )
end

"""
    to_compact_dict(ctx::KeenEmpiricalContext) -> Dict{String, Any}

トークン量を抑えた `KeenEmpiricalContext` の `Dict`。`observed_data` の系列値配列は
統計サマリー（`n_used` 等）だけに畳み込み、date/value の生配列を省く。他の section は
`to_dict` と同一。
"""
function to_compact_dict(ctx::KeenEmpiricalContext)
    d = to_dict(ctx)
    compact_obs = Any[]
    for o in d["observed_data"]
        oc = copy(o)
        delete!(oc, "dates")
        delete!(oc, "values")
        push!(compact_obs, oc)
    end
    d["observed_data"] = compact_obs
    d
end
