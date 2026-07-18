# keen_validation.jl: Keen モデルの実証バリデーションと診断仮定感応度分析を行う
# 読み取り専用の後処理層。
#
# 設計方針は docs/models/keen_empirical_strategy.md §6（識別戦略は §5、決定記録は docs/adr/0004）。
#   - in-sample（calibration）と out-of-sample（validation）を明確に分離し look-ahead を作らない
#   - validation 初期値の扱い（実観測から開始 / calibration 終点予測から連続）を別 metric として区別
#   - 水準誤差（RMSE/MAE）に加え、方向性・転換点・regime 遷移・発散を分けて評価する
#   - literature default と calibrated モデルを同一データ・同一 metric で比較する（悪化も隠さない）
#   - 金融不安定性診断（Phase 2 の minsky_diagnostics_summary）を observed proxy・model 双方へ適用
#   - amortization_rate・金利方式・系列 proxy・標本期間・initial guess・weight への感応度を返す
#   - 単一 pass/fail 閾値を必須にせず、成功・失敗・限界を構造化して返す
#   - 欠損・発散後 NaN を 0 として metric 計算しない（有効ペアのみで計算）
#   - 同一 dataset・config で決定的
#
# KeenModel の struct・parameters・ODE 動学（keen_rhs 等）・KeenEmpiricalDataset・
# KeenCalibrationResult はこのファイルの追加によって一切変更されない。

"""
    KEEN_VALIDATION_METHODOLOGY_VERSION

本層（実証バリデーション・感応度分析）の methodology version。推定層
（`KEEN_CALIBRATION_METHODOLOGY_VERSION`）・データ層（`KEEN_EMPIRICAL_METHODOLOGY_VERSION`）・
診断層（`minsky-regime/*`・`minsky-diagnostics/*`）とは独立に管理する。metric 定義・
初期値方式・regime 比較契約・感応度シナリオ規約を変更する場合に更新する。
"""
const KEEN_VALIDATION_METHODOLOGY_VERSION = "keen-validation/1.0.0"

"""
    KEEN_VALIDATION_CAVEATS

バリデーション結果に常に添付する注意事項（fit を因果妥当性・危機確率・投資助言と
同一視しないための固定文言）。[keen_empirical_strategy.md](../../docs/models/keen_empirical_strategy.md) §8・
[LLM 安全性ルール](../../docs/llm_safety.md) と対応する。
"""
const KEEN_VALIDATION_CAVEATS = String[
    "実証 fit（当てはまり）は因果関係・危機発生確率・将来予測精度と同一ではない。",
    "モデル変数（ω・λ・d）と統計系列は近似対応であり厳密に同一ではない。",
    "observed proxy regime は集計系列に Phase 2 と同じ操作的定義を適用した代理であり、企業別実測分類ではない。",
    "amortization_rate 等の診断仮定は理論的アンカーではなく作業仮定であり、regime 判定はその仮定に依存する。",
    "発散しないことはモデルの妥当性を保証しない。転換点・方向性・regime 遷移も併せて評価する必要がある。",
]

# ===========================================================================
# 定量 metric
# ===========================================================================

"""
    KeenVariableMetrics

1 状態変数の予測系列と観測系列を比較した定量 metric。水準誤差（RMSE/MAE）と
方向性・転換点を分けて保持し、単位・スケール差を単一総合点へ集約しない。

## フィールド
- `variable::Symbol` : 対象状態変数（`:ω`・`:λ`・`:d`）
- `n_pairs::Int` : metric 計算に使った有効（両側とも有限）ペア数
- `rmse::Float64` / `mae::Float64` : 二乗平均平方根誤差・平均絶対誤差
- `correlation::Float64` : Pearson 相関（`n_pairs < 2` または分散 0 で `NaN`）
- `mean_error::Float64` : 平均誤差（bias、`predicted - observed`）
- `direction_accuracy::Float64` : 前期比符号一致率（有効な連続ペアのみ、`NaN` なら評価不能）
- `n_direction_pairs::Int` : 方向性評価に使った連続ペア数
- `turning_points_observed::Int` / `turning_points_predicted::Int` : 観測・予測の転換点数
- `turning_point_timing_error::Union{Float64,Nothing}` : 各観測転換点から最近傍の予測転換点までの
  平均距離（観測インデックス単位）。どちらかが 0 個なら `nothing`
- `rmse_standardized::Float64` / `mae_standardized::Float64` : 観測系列の母標準偏差で正規化した
  RMSE/MAE（スケール差を跨いだ比較用。観測分散 0 で `NaN`）

有効ペアが 0 のときは誤差系はすべて `NaN`・カウント系は `0`・timing error は `nothing`。
発散後 `NaN` や欠損は有効ペアから除外され、`0` として扱われることはない。
"""
struct KeenVariableMetrics
    variable::Symbol
    n_pairs::Int
    rmse::Float64
    mae::Float64
    correlation::Float64
    mean_error::Float64
    direction_accuracy::Float64
    n_direction_pairs::Int
    turning_points_observed::Int
    turning_points_predicted::Int
    turning_point_timing_error::Union{Float64, Nothing}
    rmse_standardized::Float64
    mae_standardized::Float64
end

# Pearson 相関（Statistics 依存を避け自前計算）。n<2 または分散 0 で NaN。
function _keen_corr(x::AbstractVector{<:Real}, y::AbstractVector{<:Real})
    n = length(x)
    n < 2 && return NaN
    mx = sum(x) / n
    my = sum(y) / n
    sxy = 0.0
    sxx = 0.0
    syy = 0.0
    for i in 1:n
        dx = x[i] - mx
        dy = y[i] - my
        sxy += dx * dy
        sxx += dx * dx
        syy += dy * dy
    end
    (sxx <= 0.0 || syy <= 0.0) && return NaN
    sxy / sqrt(sxx * syy)
end

# 有限な連続 3 点で前期差分の符号が反転する点（転換点）のインデックス列。
function _keen_turning_points(v::AbstractVector{<:Real})
    tps = Int[]
    n = length(v)
    for k in 2:(n - 1)
        a, b, c = v[k - 1], v[k], v[k + 1]
        (isfinite(a) && isfinite(b) && isfinite(c)) || continue
        d1 = b - a
        d2 = c - b
        if (d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)
            push!(tps, k)
        end
    end
    tps
end

function _keen_tp_timing_error(obs_tps::Vector{Int}, pred_tps::Vector{Int})
    (isempty(obs_tps) || isempty(pred_tps)) && return nothing
    total = 0.0
    for t in obs_tps
        total += minimum(abs(t - p) for p in pred_tps)
    end
    total / length(obs_tps)
end

"""
    _keen_variable_metrics(pred, obs, var; skip_first=false) -> KeenVariableMetrics

予測系列 `pred` と観測系列 `obs`（同じ長さ・時間順）から `var` の定量 metric を計算する。
非有限（`NaN`/`Inf`）を含むペアは除外し、`0` として扱わない。

`skip_first=true` のとき先頭点（初期化アンカー）を評価窓から除外する。実観測から積分を
開始する方式（`:observed_start`）では `pred[1] ≡ obs[1]` が構成上必ず成立し誤差が恒等的に 0 に
なるため、これを fit として数えると発散直後（有効ペアが初期点のみ）のモデルが RMSE=0 と
なって「発散を隠す」。アンカーを除いて予測ホライズン上でのみ評価することで、発散・欠損を
0 化せず正しく反映する。
"""
function _keen_variable_metrics(
    pred::Vector{Float64},
    obs::Vector{Float64},
    var::Symbol;
    skip_first::Bool = false,
)
    if skip_first && length(pred) >= 1
        return _keen_variable_metrics(pred[2:end], obs[2:end], var)
    end
    n = length(pred)
    idx = [k for k in 1:n if isfinite(pred[k]) && isfinite(obs[k])]
    np = length(idx)
    if np == 0
        return KeenVariableMetrics(
            var,
            0,
            NaN,
            NaN,
            NaN,
            NaN,
            NaN,
            0,
            0,
            0,
            nothing,
            NaN,
            NaN,
        )
    end
    p = pred[idx]
    o = obs[idx]
    sse = 0.0
    sae = 0.0
    se = 0.0
    for i in 1:np
        e = p[i] - o[i]
        sse += e * e
        sae += abs(e)
        se += e
    end
    rmse = sqrt(sse / np)
    mae = sae / np
    me = se / np
    corr = _keen_corr(p, o)

    # 方向性: 連続する有効ペア（k, k+1 の両系列が有限）で前期比符号一致
    n_dir = 0
    n_dir_hit = 0
    for k in 1:(n - 1)
        (
            isfinite(pred[k]) &&
            isfinite(pred[k + 1]) &&
            isfinite(obs[k]) &&
            isfinite(obs[k + 1])
        ) || continue
        n_dir += 1
        if sign(pred[k + 1] - pred[k]) == sign(obs[k + 1] - obs[k])
            n_dir_hit += 1
        end
    end
    dir_acc = n_dir == 0 ? NaN : n_dir_hit / n_dir

    obs_tps = _keen_turning_points(obs)
    pred_tps = _keen_turning_points(pred)
    tp_err = _keen_tp_timing_error(obs_tps, pred_tps)

    σo = _keen_std(o)
    rmse_std = σo > 0.0 ? rmse / σo : NaN
    mae_std = σo > 0.0 ? mae / σo : NaN

    KeenVariableMetrics(
        var,
        np,
        rmse,
        mae,
        corr,
        me,
        dir_acc,
        n_dir,
        length(obs_tps),
        length(pred_tps),
        tp_err,
        rmse_std,
        mae_std,
    )
end

# ===========================================================================
# 感応度シナリオ
# ===========================================================================

"""
    KeenSensitivityScenario

感応度分析の 1 シナリオ。base に対する上書き（dataset / calibration_config /
regime_config のいずれか）で表す。上書きが `nothing` の要素は base を用いる。

## フィールド
- `name::String` : シナリオ名（結果と対応づける識別子）
- `kind::Symbol` : シナリオ種別（`:amortization_rate`・`:rate_method`・`:wage_share_proxy`・
  `:calibration_sample`・`:initial_guess`・`:variable_weight`・`:custom`）
- `dataset::Union{KeenEmpiricalDataset,Nothing}` : dataset 上書き（`nothing` で base）
- `calibration_config::Union{KeenCalibrationConfig,Nothing}` : 推定設定上書き（`nothing` で base）
- `regime_config::Union{FinancingRegimeConfig,Nothing}` : 診断設定上書き（`nothing` で base）
- `note::String` : シナリオの意図・出所メモ

`dataset` と `calibration_config` の両方が `nothing`（＝ `regime_config` のみ上書き、または全 base）の
シナリオは**再推定を行わず base の calibrated モデルを再利用**する。これにより
`amortization_rate` の変更は ODE・推定結果を変えず診断だけを変える、という契約が保証される。
"""
struct KeenSensitivityScenario
    name::String
    kind::Symbol
    dataset::Union{KeenEmpiricalDataset, Nothing}
    calibration_config::Union{KeenCalibrationConfig, Nothing}
    regime_config::Union{FinancingRegimeConfig, Nothing}
    note::String
end

function KeenSensitivityScenario(;
    name::String,
    kind::Symbol,
    dataset::Union{KeenEmpiricalDataset, Nothing} = nothing,
    calibration_config::Union{KeenCalibrationConfig, Nothing} = nothing,
    regime_config::Union{FinancingRegimeConfig, Nothing} = nothing,
    note::String = "",
)
    valid = (
        :amortization_rate,
        :rate_method,
        :wage_share_proxy,
        :calibration_sample,
        :initial_guess,
        :variable_weight,
        :custom,
    )
    kind in valid ||
        throw(ArgumentError("未知の感応度シナリオ種別: $(repr(kind))（有効: $(valid)）"))
    KeenSensitivityScenario(name, kind, dataset, calibration_config, regime_config, note)
end

# base scenario だけ再利用する（dataset・calibration_config が両方 base）か判定
_reuses_base_calibration(sc::KeenSensitivityScenario) =
    sc.dataset === nothing && sc.calibration_config === nothing

# calibration_config を一部フィールドだけ差し替えて再構築する（感応度シナリオ生成用）。
function _keen_calibration_config_with(
    base::KeenCalibrationConfig;
    fixed_params::Union{Dict{Symbol, Float64}, Nothing} = nothing,
    initial_guess::Union{Dict{Symbol, Float64}, Nothing} = nothing,
    weight_mode::Union{Symbol, Nothing} = nothing,
    weights::Union{Dict{Symbol, Float64}, Nothing} = nothing,
)
    KeenCalibrationConfig(;
        estimated_params = copy(base.estimated_params),
        fixed_params = fixed_params === nothing ? copy(base.fixed_params) : fixed_params,
        fixed_basis = copy(base.fixed_basis),
        bounds = copy(base.bounds),
        initial_guess = initial_guess === nothing ? copy(base.initial_guess) :
                        initial_guess,
        objective_method = base.objective_method,
        weight_mode = weight_mode === nothing ? base.weight_mode : weight_mode,
        weights = weights === nothing ? copy(base.weights) : weights,
        use_calibration_split = base.use_calibration_split,
        difference_scheme = base.difference_scheme,
        optimizer = base.optimizer,
        max_iterations = base.max_iterations,
        tol = base.tol,
        n_starts = base.n_starts,
        seed = base.seed,
        start_perturbation = base.start_perturbation,
        boundary_atol = base.boundary_atol,
        nonunique_obj_rtol = base.nonunique_obj_rtol,
        nonunique_param_rtol = base.nonunique_param_rtol,
        weak_param_rtol = base.weak_param_rtol,
        sensitivity_step = base.sensitivity_step,
        invalid_penalty = base.invalid_penalty,
        methodology_version = base.methodology_version,
    )
end

# ===========================================================================
# バリデーション設定
# ===========================================================================

const _KEEN_VALID_METRICS =
    (:rmse, :mae, :correlation, :mean_error, :direction_accuracy, :turning_point)

"""
    KeenValidationConfig

Keen 実証バリデーションの再現可能な設定。

## 主なフィールド
- `calibration_config::KeenCalibrationConfig` : calibrated モデルを得る推定設定（`calibrate_keen`）
- `regime_config::FinancingRegimeConfig` : 金融不安定性診断の基準設定（Phase 2）
- `comparison_models::Vector{Symbol}` : 比較対象（`:literature`・`:calibrated` の部分集合）
- `initial_state_modes::Vector{Symbol}` : validation 初期値方式（`:observed_start`・
  `:calibration_continued` の部分集合。別 metric として区別される）
- `eval_variables::Vector{Symbol}` : 評価対象状態変数（`:ω`・`:λ`・`:d` の部分集合）
- `metrics::Vector{Symbol}` : 報告する metric 一覧（`_KEEN_VALID_METRICS` の部分集合）
- `sensitivity_scenarios::Vector{KeenSensitivityScenario}` : 感応度シナリオ
- `substeps_per_year::Int` : 予測 trajectory の 1 年あたり RK4 ステップ数（既定 4 = 四半期刻み）
- `guard_max::Float64` : 発散ガード閾値
- `methodology_version::String`

`in-sample`（calibration 期間）は `:observed_start`（calibration 開始観測から積分）で評価する。
`out-of-sample`（validation 期間）は `initial_state_modes` の各方式で別々に評価する。
"""
struct KeenValidationConfig
    calibration_config::KeenCalibrationConfig
    regime_config::FinancingRegimeConfig
    comparison_models::Vector{Symbol}
    initial_state_modes::Vector{Symbol}
    eval_variables::Vector{Symbol}
    metrics::Vector{Symbol}
    sensitivity_scenarios::Vector{KeenSensitivityScenario}
    substeps_per_year::Int
    guard_max::Float64
    methodology_version::String
end

function KeenValidationConfig(;
    calibration_config::KeenCalibrationConfig,
    regime_config::FinancingRegimeConfig = FinancingRegimeConfig(),
    comparison_models::Vector{Symbol} = [:literature, :calibrated],
    initial_state_modes::Vector{Symbol} = [:observed_start, :calibration_continued],
    eval_variables::Vector{Symbol} = [:ω, :λ, :d],
    metrics::Vector{Symbol} = collect(_KEEN_VALID_METRICS),
    sensitivity_scenarios::Vector{KeenSensitivityScenario} = KeenSensitivityScenario[],
    substeps_per_year::Int = 4,
    guard_max::Float64 = 1e6,
    methodology_version::String = KEEN_VALIDATION_METHODOLOGY_VERSION,
)
    isempty(comparison_models) &&
        throw(ArgumentError("comparison_models は 1 個以上必要です"))
    for c in comparison_models
        c in (:literature, :calibrated) || throw(
            ArgumentError(
                "comparison_models は :literature/:calibrated のみ（指定: $(repr(c))）",
            ),
        )
    end
    isempty(initial_state_modes) &&
        throw(ArgumentError("initial_state_modes は 1 個以上必要です"))
    for mo in initial_state_modes
        mo in (:observed_start, :calibration_continued) || throw(
            ArgumentError(
                "initial_state_modes は :observed_start/:calibration_continued のみ（指定: $(repr(mo))）",
            ),
        )
    end
    isempty(eval_variables) && throw(ArgumentError("eval_variables は 1 個以上必要です"))
    for v in eval_variables
        v in (:ω, :λ, :d) ||
            throw(ArgumentError("eval_variables は :ω/:λ/:d のみ（指定: $(repr(v))）"))
    end
    for mt in metrics
        mt in _KEEN_VALID_METRICS || throw(
            ArgumentError("未知の metric: $(repr(mt))（有効: $(_KEEN_VALID_METRICS)）"),
        )
    end
    substeps_per_year >= 1 ||
        throw(ArgumentError("substeps_per_year は 1 以上でなければなりません"))
    isfinite(guard_max) && guard_max > 0 ||
        throw(ArgumentError("guard_max は正の有限値でなければなりません"))
    KeenValidationConfig(
        calibration_config,
        regime_config,
        copy(comparison_models),
        copy(initial_state_modes),
        copy(eval_variables),
        copy(metrics),
        copy(sensitivity_scenarios),
        substeps_per_year,
        guard_max,
        methodology_version,
    )
end

"""
    keen_default_validation_config(dataset::KeenEmpiricalDataset; kwargs...) -> KeenValidationConfig

米国既定に対応するバリデーション設定を構築する。`calibration_config` は
[`keen_default_calibration_config`](@ref) から、感応度シナリオは base 設定から派生した
決定論的な既定集合（`amortization_rate` 3 値・名目/実質金利方式・initial guess 変更・weight 変更）を用いる。

`wage_share_proxy` / `calibration_sample` の感応度は代替 dataset を要するため既定には含めず、
`sensitivity_scenarios` へ `KeenSensitivityScenario` を追加して指定する
（[keen_empirical_strategy.md](../../docs/models/keen_empirical_strategy.md) §6）。
"""
function keen_default_validation_config(
    dataset::KeenEmpiricalDataset;
    calibration_config::KeenCalibrationConfig = keen_default_calibration_config(dataset),
    regime_config::FinancingRegimeConfig = FinancingRegimeConfig(),
    real_rate_spread::Float64 = 0.02,
    kwargs...,
)
    base_cal = calibration_config

    # amortization_rate 感応度（診断のみ変更 → base calibration を再利用）
    amort_values = [0.03, 0.05, 0.10]
    scenarios = KeenSensitivityScenario[]
    for a in amort_values
        push!(
            scenarios,
            KeenSensitivityScenario(;
                name = "amortization_rate=$(a)",
                kind = :amortization_rate,
                regime_config = FinancingRegimeConfig(;
                    amortization_rate = a,
                    debt_tolerance = regime_config.debt_tolerance,
                    classification_tolerance = regime_config.classification_tolerance,
                    methodology_version = regime_config.methodology_version,
                ),
                note = "元本返済代理率のみ変更。ODE・推定結果は不変で診断のみ変わる。",
            ),
        )
    end

    # 金利方式（名目 → 実質代理: r を real_rate_spread だけ引き下げた固定値で再推定）
    r_real = max(base_cal.fixed_params[:r] - real_rate_spread, 1e-6)
    real_fixed = copy(base_cal.fixed_params)
    real_fixed[:r] = r_real
    push!(
        scenarios,
        KeenSensitivityScenario(;
            name = "rate_method=real_proxy",
            kind = :rate_method,
            calibration_config = _keen_calibration_config_with(
                base_cal;
                fixed_params = real_fixed,
            ),
            note = "名目金利から real_rate_spread=$(real_rate_spread) を引いた実質代理で r を固定し再推定。",
        ),
    )

    # initial guess 変更（bounds 中点へ寄せた別スタート）
    alt_guess = Dict{Symbol, Float64}()
    for p in base_cal.estimated_params
        lo, hi = base_cal.bounds[p]
        g = base_cal.initial_guess[p]
        alt_guess[p] = clamp(0.5 * g + 0.5 * (lo + hi) / 2, lo, hi)
    end
    push!(
        scenarios,
        KeenSensitivityScenario(;
            name = "initial_guess=midpoint_blend",
            kind = :initial_guess,
            calibration_config = _keen_calibration_config_with(
                base_cal;
                initial_guess = alt_guess,
            ),
            note = "初期値を bounds 中点へ寄せて再推定（多局所解・弱識別の確認）。",
        ),
    )

    # variable weight 変更（正規化なし）
    push!(
        scenarios,
        KeenSensitivityScenario(;
            name = "variable_weight=none",
            kind = :variable_weight,
            calibration_config = _keen_calibration_config_with(
                base_cal;
                weight_mode = :none,
            ),
            note = "方程式別重みを外して（:none）再推定し、weight 依存性を確認。",
        ),
    )

    KeenValidationConfig(;
        calibration_config = base_cal,
        regime_config = regime_config,
        sensitivity_scenarios = scenarios,
        kwargs...,
    )
end

# ===========================================================================
# 結果型
# ===========================================================================

"""
    KeenPeriodEvaluation

1 つの（モデル × 期間 × 初期値方式）に対する予測・観測系列と変数別 metric。

## フィールド
- `model_label::Symbol` : `:literature` または `:calibrated`
- `period::Symbol` : `:in_sample`（calibration 期間）または `:out_of_sample`（validation 期間）
- `initial_state_mode::Symbol` : `:observed_start` または `:calibration_continued`
- `n_obs::Int` : 期間内観測数
- `times::Vector{Float64}` : 期間内観測時点（年単位、dataset の観測時間軸）
- `observed::Dict{Symbol,Vector{Float64}}` / `predicted::Dict{Symbol,Vector{Float64}}` : 変数別系列
- `metrics::Dict{Symbol,KeenVariableMetrics}` : 変数別 metric
- `diverged::Bool` : 予測 trajectory が発散ガードに抵触したか
- `divergence_offset::Union{Int,Nothing}` : 期間内で発散した最初の相対インデックス（1始まり）。なければ `nothing`
"""
struct KeenPeriodEvaluation
    model_label::Symbol
    period::Symbol
    initial_state_mode::Symbol
    n_obs::Int
    times::Vector{Float64}
    observed::Dict{Symbol, Vector{Float64}}
    predicted::Dict{Symbol, Vector{Float64}}
    metrics::Dict{Symbol, KeenVariableMetrics}
    diverged::Bool
    divergence_offset::Union{Int, Nothing}
end

"""
    KeenRegimeComparison

observed proxy・literature モデル・calibrated モデルの金融不安定性診断を同一契約
（Phase 2 の `MinskyDiagnosticsResult` / `MinskyDiagnosticsSummary`）で並べた比較結果。

model 側の regime 系列は「観測開始状態から full-sample を積分した予測 trajectory」に対する診断。
observed 側は観測系列 `ω`・`d` へ直接適用した集計 proxy（`g` は観測不能のため `NaN`、
成長依存の指標のみ未定義になる）。

## フィールド
- `observed` / `literature` / `calibrated` :: `MinskyDiagnosticsResult`
- `observed_summary` / `literature_summary` / `calibrated_summary` :: `MinskyDiagnosticsSummary`
- `note::String` : 集計 proxy であることの明示
"""
struct KeenRegimeComparison
    observed::MinskyDiagnosticsResult
    literature::MinskyDiagnosticsResult
    calibrated::MinskyDiagnosticsResult
    observed_summary::MinskyDiagnosticsSummary
    literature_summary::MinskyDiagnosticsSummary
    calibrated_summary::MinskyDiagnosticsSummary
    note::String
end

"""
    KeenSensitivityResult

1 感応度シナリオの結果。base（`name = "base"`）を含めて同一契約で並べ、呼び出し側が
差分を取れるようにする。

## フィールド
- `scenario::KeenSensitivityScenario`
- `reused_base_calibration::Bool` : base の推定結果を再利用したか（`true` なら推定値・objective は base と同一）
- `estimated::Dict{Symbol,Float64}` : 推定値
- `objective_value::Float64` : 推定 objective 総値
- `fit_period::Symbol` : fit metric を計算した期間（`:out_of_sample` を優先、validation が無ければ `:in_sample`）
- `fit_rmse::Dict{Symbol,Float64}` : 変数別 RMSE（calibrated モデル・`:observed_start`）
- `regime_share::Dict{FinancingRegime,Float64}` : calibrated モデルの regime 滞在比率
- `first_speculative_time` / `first_ponzi_time` / `recovery_to_hedge_time::Union{Int,Nothing}`
- `peak_debt_ratio::Union{Float64,Nothing}`
- `diverged::Bool` : calibrated モデル trajectory が発散したか
- `n_transitions::Int` : calibrated モデルの regime 遷移数
"""
struct KeenSensitivityResult
    scenario::KeenSensitivityScenario
    reused_base_calibration::Bool
    estimated::Dict{Symbol, Float64}
    objective_value::Float64
    fit_period::Symbol
    fit_rmse::Dict{Symbol, Float64}
    regime_share::Dict{FinancingRegime, Float64}
    first_speculative_time::Union{Int, Nothing}
    first_ponzi_time::Union{Int, Nothing}
    recovery_to_hedge_time::Union{Int, Nothing}
    peak_debt_ratio::Union{Float64, Nothing}
    diverged::Bool
    n_transitions::Int
end

"""
    KeenTrajectoryBundle

observed（観測 proxy）・literature・calibrated の full-sample 系列を**同一時間軸**で束ねた
可視化用バンドル。model 側は観測開始状態（`:observed_start`）からの予測 trajectory。
発散後は `NaN`（0 化・補間しない）。可視化層はこれを読むだけで再計算しない。

## フィールド
- `times::Vector{Float64}` : 年単位の観測時間軸（`dataset.observation_times`）
- `dates::Vector{String}` : 四半期ラベル（`dataset.dates`）
- `calibration_end_time` / `validation_start_time::Union{Float64,Nothing}` : 期間境界（描画用）
- `observed` / `literature` / `calibrated::Dict{Symbol,Vector{Float64}}` : `:ω`・`:λ`・`:d` の系列
  （すべて `length(times)` と同じ長さ・同じ時間軸）
"""
struct KeenTrajectoryBundle
    times::Vector{Float64}
    dates::Vector{String}
    calibration_end_time::Union{Float64, Nothing}
    validation_start_time::Union{Float64, Nothing}
    observed::Dict{Symbol, Vector{Float64}}
    literature::Dict{Symbol, Vector{Float64}}
    calibrated::Dict{Symbol, Vector{Float64}}
end

"""
    KeenValidationResult

Keen 実証バリデーションの構造化結果。元の `KeenEmpiricalDataset`・`KeenModel`・
`KeenCalibrationResult` を変更せず派生結果として保持する。

## 主なフィールド
- `config::KeenValidationConfig`
- `calibration_result::KeenCalibrationResult` : base の calibrated モデル（採用解）
- `evaluations::Vector{KeenPeriodEvaluation}` : （モデル × 期間 × 初期値方式）の評価
- `regime_comparison::KeenRegimeComparison` : observed / literature / calibrated の診断比較
- `sensitivity::Vector{KeenSensitivityResult}` : base を含む感応度結果
- `trajectories::KeenTrajectoryBundle` : observed / literature / calibrated の full-sample 系列（可視化用）
- `split_info::Dict{String,Any}` : split 境界・観測数・欠損除外の記録（look-ahead が無いことの根拠）
- `calibrated_worse_than_literature::Bool` : out-of-sample（無ければ in-sample）集計 RMSE で
  calibrated が literature より悪いか（悪化を隠さない）
- `warnings::Vector{String}` / `caveats::Vector{String}`
- `dataset_metadata::Dict{String,Any}` : 系列 ID・期間・measurement version（再現用）
- `methodology_version::String`
- `metadata::Dict{String,Any}`
"""
struct KeenValidationResult
    config::KeenValidationConfig
    calibration_result::KeenCalibrationResult
    evaluations::Vector{KeenPeriodEvaluation}
    regime_comparison::KeenRegimeComparison
    sensitivity::Vector{KeenSensitivityResult}
    trajectories::KeenTrajectoryBundle
    split_info::Dict{String, Any}
    calibrated_worse_than_literature::Bool
    warnings::Vector{String}
    caveats::Vector{String}
    dataset_metadata::Dict{String, Any}
    methodology_version::String
    metadata::Dict{String, Any}
end

# ===========================================================================
# trajectory / regime ヘルパー
# ===========================================================================

"""
    _keen_predict_over(m, ω0, λ0, d0, times; substeps_per_year, guard_max) -> NamedTuple

初期状態 `(ω0, λ0, d0)` から `times`（年単位・昇順）の各時点での予測状態を RK4 で積分して返す。
`times[1]` は初期状態に対応する。隣接時点間は `Δt` を `substeps_per_year` に基づき細分して積分し、
発散ガードに抵触した時点以降は `NaN` で埋める（`simulate` と同じガード規約）。
"""
function _keen_predict_over(
    m::KeenModel,
    ω0::Float64,
    λ0::Float64,
    d0::Float64,
    times::Vector{Float64};
    substeps_per_year::Int,
    guard_max::Float64,
)
    n = length(times)
    ω = fill(NaN, n)
    λ = fill(NaN, n)
    d = fill(NaN, n)
    π = fill(NaN, n)
    g = fill(NaN, n)
    n == 0 && return (ω = ω, λ = λ, d = d, π = π, g = g)

    diverged = keen_diverged(ω0, λ0, d0, guard_max)
    ωc, λc, dc = ω0, λ0, d0
    if !diverged
        ω[1], λ[1], d[1] = ω0, λ0, d0
        π1 = 1 - ω0 - m.r * d0
        π[1] = π1
        g[1] = (m.κ0 + m.κ1 * exp(m.κ2 * π1)) / m.ν - m.δ
    end

    for k in 1:(n - 1)
        diverged && continue
        Δ = times[k + 1] - times[k]
        nsteps = max(1, round(Int, Δ * substeps_per_year))
        h = Δ / nsteps
        for _ in 1:nsteps
            ωc, λc, dc = keen_rk4_step(m, ωc, λc, dc, h)
            if keen_diverged(ωc, λc, dc, guard_max)
                diverged = true
                break
            end
        end
        diverged && continue
        ω[k + 1], λ[k + 1], d[k + 1] = ωc, λc, dc
        πk = 1 - ωc - m.r * dc
        π[k + 1] = πk
        g[k + 1] = (m.κ0 + m.κ1 * exp(m.κ2 * πk)) / m.ν - m.δ
    end
    (ω = ω, λ = λ, d = d, π = π, g = g)
end

# 予測 trajectory の発散オフセット（最初に NaN になった相対インデックス、1始まり）。なければ nothing。
function _keen_divergence_offset(traj)
    for k in 1:length(traj.ω)
        (isfinite(traj.ω[k]) && isfinite(traj.λ[k]) && isfinite(traj.d[k])) || return k
    end
    nothing
end

# dataset から state・時間軸のスライスを取り出す（indices は時間順を想定）
function _keen_slice(dataset::KeenEmpiricalDataset, indices::Vector{Int})
    (
        times = dataset.observation_times[indices],
        ω = dataset.ω[indices],
        λ = dataset.λ[indices],
        d = dataset.d[indices],
    )
end

# 1 期間の予測を組み立て KeenPeriodEvaluation を返す。
# init_state で開始し、times に沿って積分。predicted を obs_slice と突き合わせる。
function _keen_period_evaluation(
    m::KeenModel,
    model_label::Symbol,
    period::Symbol,
    init_mode::Symbol,
    init_state::NTuple{3, Float64},
    times::Vector{Float64},
    obs_slice,
    eval_vars::Vector{Symbol};
    substeps_per_year::Int,
    guard_max::Float64,
    skip_first::Bool = false,
)
    ω0, λ0, d0 = init_state
    traj = _keen_predict_over(
        m,
        ω0,
        λ0,
        d0,
        times;
        substeps_per_year = substeps_per_year,
        guard_max = guard_max,
    )
    observed = Dict(:ω => obs_slice.ω, :λ => obs_slice.λ, :d => obs_slice.d)
    predicted = Dict(:ω => traj.ω, :λ => traj.λ, :d => traj.d)
    metrics = Dict{Symbol, KeenVariableMetrics}()
    for v in eval_vars
        metrics[v] =
            _keen_variable_metrics(predicted[v], observed[v], v; skip_first = skip_first)
    end
    off = _keen_divergence_offset(traj)
    KeenPeriodEvaluation(
        model_label,
        period,
        init_mode,
        length(times),
        copy(times),
        observed,
        predicted,
        metrics,
        off !== nothing,
        off,
    )
end

# 1 モデルについて in-sample / out-of-sample の全評価を返す。
function _keen_evaluate_model(
    m::KeenModel,
    model_label::Symbol,
    dataset::KeenEmpiricalDataset,
    config::KeenValidationConfig,
)
    evals = KeenPeriodEvaluation[]
    calib = dataset.calibration_indices
    valid = dataset.validation_indices

    # ---- in-sample（calibration 期間、observed_start）----
    if !isempty(calib)
        cs = _keen_slice(dataset, calib)
        push!(
            evals,
            _keen_period_evaluation(
                m,
                model_label,
                :in_sample,
                :observed_start,
                (cs.ω[1], cs.λ[1], cs.d[1]),
                cs.times,
                cs,
                config.eval_variables;
                substeps_per_year = config.substeps_per_year,
                guard_max = config.guard_max,
                skip_first = true,  # 初期化アンカー（pred≡obs）を fit から除外
            ),
        )
    end

    # ---- out-of-sample（validation 期間、各初期値方式）----
    if !isempty(valid)
        vs = _keen_slice(dataset, valid)
        for mode in config.initial_state_modes
            if mode === :observed_start
                init = (vs.ω[1], vs.λ[1], vs.d[1])
                push!(
                    evals,
                    _keen_period_evaluation(
                        m,
                        model_label,
                        :out_of_sample,
                        mode,
                        init,
                        vs.times,
                        vs,
                        config.eval_variables;
                        substeps_per_year = config.substeps_per_year,
                        guard_max = config.guard_max,
                        skip_first = true,  # 初期化アンカー（pred≡obs）を fit から除外
                    ),
                )
            else # :calibration_continued
                # calibration 開始観測から full [calib; valid] を連続積分し validation 部分をスライス
                if isempty(calib)
                    continue
                end
                full_idx = vcat(calib, valid)
                fs = _keen_slice(dataset, full_idx)
                traj = _keen_predict_over(
                    m,
                    fs.ω[1],
                    fs.λ[1],
                    fs.d[1],
                    fs.times;
                    substeps_per_year = config.substeps_per_year,
                    guard_max = config.guard_max,
                )
                nvalid = length(valid)
                sl = (length(full_idx) - nvalid + 1):length(full_idx)
                predicted = Dict(:ω => traj.ω[sl], :λ => traj.λ[sl], :d => traj.d[sl])
                observed = Dict(:ω => vs.ω, :λ => vs.λ, :d => vs.d)
                metrics = Dict{Symbol, KeenVariableMetrics}()
                for v in config.eval_variables
                    metrics[v] = _keen_variable_metrics(predicted[v], observed[v], v)
                end
                # 発散オフセット（validation スライス内の相対位置）
                off = nothing
                for (rel, k) in enumerate(sl)
                    if !(isfinite(traj.ω[k]) && isfinite(traj.λ[k]) && isfinite(traj.d[k]))
                        off = rel
                        break
                    end
                end
                push!(
                    evals,
                    KeenPeriodEvaluation(
                        model_label,
                        :out_of_sample,
                        mode,
                        nvalid,
                        copy(vs.times),
                        observed,
                        predicted,
                        metrics,
                        off !== nothing,
                        off,
                    ),
                )
            end
        end
    end
    evals
end

# model の full-sample 予測 trajectory（観測開始状態から。ω・λ・d を返す）
function _keen_full_trajectory(
    m::KeenModel,
    dataset::KeenEmpiricalDataset,
    config::KeenValidationConfig,
)
    fs = _keen_slice(dataset, collect(1:length(dataset)))
    traj = _keen_predict_over(
        m,
        fs.ω[1],
        fs.λ[1],
        fs.d[1],
        fs.times;
        substeps_per_year = config.substeps_per_year,
        guard_max = config.guard_max,
    )
    Dict(:ω => traj.ω, :λ => traj.λ, :d => traj.d)
end

# observed proxy の診断（ω・d・r から。g は観測不能のため NaN）
function _keen_observed_diagnostics(
    dataset::KeenEmpiricalDataset,
    regime_config::FinancingRegimeConfig,
)
    n = length(dataset)
    g = fill(NaN, n)
    _minsky_diagnostics_from_series(
        "observed-proxy",
        "validation",
        copy(dataset.ω),
        copy(dataset.d),
        dataset.r_param,
        g;
        config = regime_config,
        metadata = Dict{String, Any}("source" => "observed proxy series"),
    )
end

# model（literature/calibrated）の full-sample 予測 trajectory への診断
function _keen_model_diagnostics(
    m::KeenModel,
    label::String,
    dataset::KeenEmpiricalDataset,
    config::KeenValidationConfig,
)
    fs = _keen_slice(dataset, collect(1:length(dataset)))
    traj = _keen_predict_over(
        m,
        fs.ω[1],
        fs.λ[1],
        fs.d[1],
        fs.times;
        substeps_per_year = config.substeps_per_year,
        guard_max = config.guard_max,
    )
    _minsky_diagnostics_from_series(
        "keen-$(label)",
        "validation",
        traj.ω,
        traj.d,
        m.r,
        traj.g;
        config = config.regime_config,
        metadata = Dict{String, Any}("parameters" => parameters(m)),
    )
end

# ===========================================================================
# 感応度実行
# ===========================================================================

# scenario から KeenSensitivityResult を計算する。
function _keen_run_sensitivity(
    scenario::KeenSensitivityScenario,
    base_dataset::KeenEmpiricalDataset,
    base_calibration::KeenCalibrationResult,
    config::KeenValidationConfig,
)
    ds = scenario.dataset === nothing ? base_dataset : scenario.dataset
    reuse = _reuses_base_calibration(scenario)
    calres = if reuse
        base_calibration
    else
        cc =
            scenario.calibration_config === nothing ? config.calibration_config :
            scenario.calibration_config
        calibrate_keen(ds, cc)
    end
    m = calres.model
    rc = scenario.regime_config === nothing ? config.regime_config : scenario.regime_config

    # fit metric（calibrated モデル・observed_start）: validation 優先、無ければ calibration
    fit_period = isempty(ds.validation_indices) ? :in_sample : :out_of_sample
    idx = fit_period === :out_of_sample ? ds.validation_indices : ds.calibration_indices
    sl = _keen_slice(ds, idx)
    traj = _keen_predict_over(
        m,
        sl.ω[1],
        sl.λ[1],
        sl.d[1],
        sl.times;
        substeps_per_year = config.substeps_per_year,
        guard_max = config.guard_max,
    )
    pred = Dict(:ω => traj.ω, :λ => traj.λ, :d => traj.d)
    obs = Dict(:ω => sl.ω, :λ => sl.λ, :d => sl.d)
    fit_rmse = Dict{Symbol, Float64}()
    for v in config.eval_variables
        fit_rmse[v] = _keen_variable_metrics(pred[v], obs[v], v; skip_first = true).rmse
    end

    # regime 診断（full-sample、scenario の regime_config）
    diag = _keen_model_diagnostics(m, scenario.name, ds, _with_regime(config, rc))
    summ = minsky_diagnostics_summary(diag)

    KeenSensitivityResult(
        scenario,
        reuse,
        copy(calres.estimated),
        calres.objective_value,
        fit_period,
        fit_rmse,
        copy(summ.regime_share_of_valid),
        summ.first_speculative_time,
        summ.first_ponzi_time,
        summ.recovery_to_hedge_time,
        summ.peak_debt_ratio,
        summ.diverged,
        length(diag.regime_diagnostics.transitions),
    )
end

# config の regime_config だけ差し替えた軽量コピー（診断計算のみに使う）
function _with_regime(config::KeenValidationConfig, rc::FinancingRegimeConfig)
    KeenValidationConfig(
        config.calibration_config,
        rc,
        config.comparison_models,
        config.initial_state_modes,
        config.eval_variables,
        config.metrics,
        config.sensitivity_scenarios,
        config.substeps_per_year,
        config.guard_max,
        config.methodology_version,
    )
end

# ===========================================================================
# バリデーション本体
# ===========================================================================

# 集計 out-of-sample（無ければ in-sample）RMSE を eval_vars 合計で返す（モデル比較用）。
function _keen_aggregate_rmse(evals::Vector{KeenPeriodEvaluation}, model_label::Symbol)
    # out_of_sample / observed_start を優先、無ければ in_sample / observed_start
    for (period, mode) in ((:out_of_sample, :observed_start), (:in_sample, :observed_start))
        for e in evals
            if e.model_label == model_label &&
               e.period == period &&
               e.initial_state_mode == mode
                total = 0.0
                cnt = 0
                for (_, mt) in e.metrics
                    if isfinite(mt.rmse)
                        total += mt.rmse
                        cnt += 1
                    end
                end
                return cnt == 0 ? NaN : total, period
            end
        end
    end
    NaN, :none
end

"""
    validate_keen(dataset::KeenEmpiricalDataset, config::KeenValidationConfig) -> KeenValidationResult

`dataset` に対し Keen モデルの実証バリデーションと診断仮定感応度分析を実行する。

1. `config.calibration_config` で `calibrate_keen` を実行し calibrated モデルを得る
2. literature / calibrated モデルを in-sample（calibration 期間）と out-of-sample（validation 期間）へ
   分けて予測・観測を突き合わせ、変数別 metric を計算する（validation は初期値方式ごとに別 metric）
3. observed proxy / literature / calibrated の金融不安定性診断を同一契約で比較する
4. `config.sensitivity_scenarios` を決定論的に実行し、推定値・fit・regime・遷移・発散の感応度を返す

同一 `dataset`・`config` で決定的。推定値・fit を因果妥当性・危機確率・投資助言と同一視してはならない
（[keen_empirical_strategy.md](../../docs/models/keen_empirical_strategy.md) §8、`KEEN_VALIDATION_CAVEATS`）。
"""
function validate_keen(dataset::KeenEmpiricalDataset, config::KeenValidationConfig)
    isempty(dataset.calibration_indices) &&
        throw(ArgumentError("calibration_indices が空です（推定に使う観測がありません）"))

    # ---- base 推定 ----
    calibration_result = calibrate_keen(dataset, config.calibration_config)
    m_calibrated = calibration_result.model
    lit = KEEN_LITERATURE_PARAMS
    # literature モデルは固定パラメータを共有し、推定対象を文献値へ置換して構築
    lit_params = Dict{Symbol, Float64}()
    for p in config.calibration_config.estimated_params
        lit_params[p] = getproperty(lit, p)
    end
    m_literature = _keen_model_from_params(config.calibration_config, lit_params)

    models =
        Dict{Symbol, KeenModel}(:literature => m_literature, :calibrated => m_calibrated)

    # ---- 期間別評価 ----
    evaluations = KeenPeriodEvaluation[]
    for label in config.comparison_models
        append!(evaluations, _keen_evaluate_model(models[label], label, dataset, config))
    end

    # ---- regime 比較 ----
    obs_diag = _keen_observed_diagnostics(dataset, config.regime_config)
    lit_diag = _keen_model_diagnostics(m_literature, "literature", dataset, config)
    cal_diag = _keen_model_diagnostics(m_calibrated, "calibrated", dataset, config)
    regime_comparison = KeenRegimeComparison(
        obs_diag,
        lit_diag,
        cal_diag,
        minsky_diagnostics_summary(obs_diag),
        minsky_diagnostics_summary(lit_diag),
        minsky_diagnostics_summary(cal_diag),
        "observed proxy は集計系列への Phase 2 診断の代理であり企業別実測分類ではない。model 側は観測開始状態からの full-sample 予測 trajectory への診断。",
    )

    # ---- full-sample 系列バンドル（可視化用、再計算しないよう保持）----
    trajectories = KeenTrajectoryBundle(
        copy(dataset.observation_times),
        copy(dataset.dates),
        isempty(dataset.calibration_indices) ? nothing :
        dataset.observation_times[dataset.calibration_indices[end]],
        isempty(dataset.validation_indices) ? nothing :
        dataset.observation_times[dataset.validation_indices[1]],
        Dict(:ω => copy(dataset.ω), :λ => copy(dataset.λ), :d => copy(dataset.d)),
        _keen_full_trajectory(m_literature, dataset, config),
        _keen_full_trajectory(m_calibrated, dataset, config),
    )

    # ---- 感応度 ----
    sensitivity = KeenSensitivityResult[]
    base_scenario = KeenSensitivityScenario(;
        name = "base",
        kind = :custom,
        note = "base 設定（比較の基準）。",
    )
    push!(
        sensitivity,
        _keen_run_sensitivity(base_scenario, dataset, calibration_result, config),
    )
    for sc in config.sensitivity_scenarios
        push!(sensitivity, _keen_run_sensitivity(sc, dataset, calibration_result, config))
    end

    # ---- calibrated vs literature（悪化を隠さない）----
    lit_rmse, lit_period = _keen_aggregate_rmse(evaluations, :literature)
    cal_rmse, cal_period = _keen_aggregate_rmse(evaluations, :calibrated)
    calibrated_worse = isfinite(lit_rmse) && isfinite(cal_rmse) && cal_rmse > lit_rmse

    # ---- warnings ----
    warnings = String[]
    if isempty(dataset.validation_indices)
        push!(
            warnings,
            "validation_indices が空です。out-of-sample 評価は行われず in-sample のみです。",
        )
    end
    if calibrated_worse
        push!(
            warnings,
            "calibrated モデルの集計 RMSE（$(cal_period)）が literature default より大きく、当てはまりが改善していません。",
        )
    end
    if calibration_result.weak_identification
        push!(warnings, "推定は弱識別の兆候があります（複数局所解・平坦な objective）。")
    end
    if !isempty(calibration_result.boundary_hits)
        push!(
            warnings,
            "推定値が bounds に張り付いています: $(calibration_result.boundary_hits)。",
        )
    end
    for e in evaluations
        if e.diverged
            push!(
                warnings,
                "$(e.model_label) の $(e.period)（$(e.initial_state_mode)）予測が発散しました（offset=$(e.divergence_offset)）。",
            )
        end
    end
    if regime_comparison.calibrated_summary.diverged
        push!(warnings, "calibrated モデルの full-sample 予測が発散しました。")
    end

    split_info = Dict{String, Any}(
        "n_obs_total" => length(dataset),
        "n_calibration" => length(dataset.calibration_indices),
        "n_validation" => length(dataset.validation_indices),
        "calibration_indices" => copy(dataset.calibration_indices),
        "validation_indices" => copy(dataset.validation_indices),
        "calibration_start" =>
            isempty(dataset.calibration_indices) ? "" :
            dataset.dates[dataset.calibration_indices[1]],
        "calibration_end" =>
            isempty(dataset.calibration_indices) ? "" :
            dataset.dates[dataset.calibration_indices[end]],
        "validation_start" =>
            isempty(dataset.validation_indices) ? "" :
            dataset.dates[dataset.validation_indices[1]],
        "validation_end" =>
            isempty(dataset.validation_indices) ? "" :
            dataset.dates[dataset.validation_indices[end]],
        "no_overlap" => isempty(
            intersect(Set(dataset.calibration_indices), Set(dataset.validation_indices)),
        ),
        "n_obs_excluded_calibration" => calibration_result.n_obs_excluded,
        "excluded_reasons" => calibration_result.excluded_reasons,
    )

    metadata = Dict{String, Any}(
        "aggregate_rmse_literature" => lit_rmse,
        "aggregate_rmse_calibrated" => cal_rmse,
        "aggregate_rmse_period" => string(cal_period),
        "prediction_scheme" => "RK4, substeps_per_year=$(config.substeps_per_year)",
        "initial_state_modes" => string.(config.initial_state_modes),
        "pass_fail_note" => "Phase 3 では単一 pass/fail 閾値を課さない。成功・失敗・限界を metric・warnings として構造化して返す。",
    )

    KeenValidationResult(
        config,
        calibration_result,
        evaluations,
        regime_comparison,
        sensitivity,
        trajectories,
        split_info,
        calibrated_worse,
        warnings,
        copy(KEEN_VALIDATION_CAVEATS),
        _keen_dataset_metadata(dataset),
        config.methodology_version,
        metadata,
    )
end

# ===========================================================================
# 保存（JSON、再現・報告用の要約）
# ===========================================================================

_keen_variable_metrics_to_dict(mt::KeenVariableMetrics) = Dict{String, Any}(
    "variable" => string(mt.variable),
    "n_pairs" => mt.n_pairs,
    "rmse" => mt.rmse,
    "mae" => mt.mae,
    "correlation" => mt.correlation,
    "mean_error" => mt.mean_error,
    "direction_accuracy" => mt.direction_accuracy,
    "n_direction_pairs" => mt.n_direction_pairs,
    "turning_points_observed" => mt.turning_points_observed,
    "turning_points_predicted" => mt.turning_points_predicted,
    "turning_point_timing_error" => mt.turning_point_timing_error,
    "rmse_standardized" => mt.rmse_standardized,
    "mae_standardized" => mt.mae_standardized,
)

_keen_period_eval_to_dict(e::KeenPeriodEvaluation) = Dict{String, Any}(
    "model_label" => string(e.model_label),
    "period" => string(e.period),
    "initial_state_mode" => string(e.initial_state_mode),
    "n_obs" => e.n_obs,
    "diverged" => e.diverged,
    "divergence_offset" => e.divergence_offset,
    "metrics" =>
        Dict(string(v) => _keen_variable_metrics_to_dict(mt) for (v, mt) in e.metrics),
)

function _keen_regime_summary_to_dict(s::MinskyDiagnosticsSummary)
    Dict{String, Any}(
        "regime_share" => Dict(string(k) => v for (k, v) in s.regime_share_of_valid),
        "first_speculative_time" => s.first_speculative_time,
        "first_ponzi_time" => s.first_ponzi_time,
        "recovery_to_hedge_time" => s.recovery_to_hedge_time,
        "peak_debt_ratio" => s.peak_debt_ratio,
        "min_interest_coverage_ratio" => s.min_interest_coverage_ratio,
        "min_debt_service_coverage_ratio" => s.min_debt_service_coverage_ratio,
        "min_ponzi_margin" => s.min_ponzi_margin,
        "min_hedge_margin" => s.min_hedge_margin,
        "diverged" => s.diverged,
        "divergence_time" => s.divergence_time,
        "amortization_rate" => s.config.amortization_rate,
    )
end

_keen_sensitivity_to_dict(r::KeenSensitivityResult) = Dict{String, Any}(
    "name" => r.scenario.name,
    "kind" => string(r.scenario.kind),
    "note" => r.scenario.note,
    "reused_base_calibration" => r.reused_base_calibration,
    "estimated" => Dict(string(k) => v for (k, v) in r.estimated),
    "objective_value" => r.objective_value,
    "fit_period" => string(r.fit_period),
    "fit_rmse" => Dict(string(k) => v for (k, v) in r.fit_rmse),
    "regime_share" => Dict(string(k) => v for (k, v) in r.regime_share),
    "first_speculative_time" => r.first_speculative_time,
    "first_ponzi_time" => r.first_ponzi_time,
    "recovery_to_hedge_time" => r.recovery_to_hedge_time,
    "peak_debt_ratio" => r.peak_debt_ratio,
    "diverged" => r.diverged,
    "n_transitions" => r.n_transitions,
)

"""
    keen_validation_to_dict(result) -> Dict{String,Any}

`KeenValidationResult` を JSON 化可能な `Dict` へ変換する（metric・regime 比較サマリー・
感応度・split 情報・warnings/caveats・provenance を含む。生の系列や dataset オブジェクトは含めない）。
"""
function keen_validation_to_dict(result::KeenValidationResult)
    Dict{String, Any}(
        "calibration" => keen_calibration_to_dict(result.calibration_result),
        "evaluations" => [_keen_period_eval_to_dict(e) for e in result.evaluations],
        "regime_comparison" => Dict{String, Any}(
            "observed" =>
                _keen_regime_summary_to_dict(result.regime_comparison.observed_summary),
            "literature" => _keen_regime_summary_to_dict(
                result.regime_comparison.literature_summary,
            ),
            "calibrated" => _keen_regime_summary_to_dict(
                result.regime_comparison.calibrated_summary,
            ),
            "note" => result.regime_comparison.note,
        ),
        "sensitivity" => [_keen_sensitivity_to_dict(r) for r in result.sensitivity],
        "split_info" => result.split_info,
        "calibrated_worse_than_literature" => result.calibrated_worse_than_literature,
        "warnings" => result.warnings,
        "caveats" => result.caveats,
        "dataset_metadata" => result.dataset_metadata,
        "methodology_version" => result.methodology_version,
        "metadata" => result.metadata,
    )
end

# JSON 化前の非有限値サニタイズ。JSON 仕様は NaN/Inf を許さないため、metric 等に現れる
# 非有限 Float を `nothing`（JSON null）へ再帰的に置換する（0 化はしない。欠損・発散は null）。
_keen_json_safe(x::AbstractFloat) = isfinite(x) ? x : nothing
_keen_json_safe(x::AbstractDict) =
    Dict{String, Any}(string(k) => _keen_json_safe(v) for (k, v) in x)
_keen_json_safe(x::AbstractVector) = Any[_keen_json_safe(v) for v in x]
_keen_json_safe(x::Tuple) = Any[_keen_json_safe(v) for v in x]
_keen_json_safe(x) = x

"""
    save_keen_validation(path, result)

`KeenValidationResult` を JSON として `path` へ保存する（報告・再現用の要約）。
metric 等の非有限値（`NaN`/`Inf`、発散・欠損由来）は JSON `null` として保存する（0 化しない）。
"""
function save_keen_validation(path::AbstractString, result::KeenValidationResult)
    open(path, "w") do io
        JSON3.pretty(io, _keen_json_safe(keen_validation_to_dict(result)))
    end
    path
end

# dataset provenance を系列別 Dict へ（採用系列・単位変換・共通期間・quality を機械可読化）
function _keen_series_report(dataset::KeenEmpiricalDataset)
    out = Dict{String, Any}()
    for v in (:ω, :λ, :d, :r)
        haskey(dataset.provenance, v) || continue
        p = dataset.provenance[v]
        out[string(v)] = Dict{String, Any}(
            "source_id" => p.source_id,
            "series_id" => p.series_id,
            "source" => p.source,
            "mode" => string(p.mode),
            "original_unit" => p.original_unit,
            "conversion_formula" => p.conversion_formula,
            "aggregation" => string(p.aggregation),
            "adopted_start" => p.adopted_start,
            "adopted_end" => p.adopted_end,
            "n_used" => p.n_used,
            "n_source_missing" => p.n_source_missing,
            "n_invalid" => p.n_invalid,
        )
    end
    out
end

"""
    keen_empirical_report(dataset, result; mode=nothing, artifact_paths=String[]) -> Dict{String,Any}

fixture/live/rest_api いずれの経路でも同一契約の**機械可読な統合レポート**を組み立てる。
dataset 系列 provenance（採用系列・source・mode・単位変換・共通期間・quality）と
`KeenValidationResult` の全要約（推定設定・結果・warnings・validation metric・regime 遷移比較・
感応度・caveats）に加え、生成した artifact（図・JSON）パスを束ねる。

**API key・環境変数値・秘密情報は保存しない**（系列 ID・変換式・推定値・パスのみ）。
`mode` は取得モード（`:fixture`/`:live`/`:rest_api`）の記録用。
"""
function keen_empirical_report(
    dataset::KeenEmpiricalDataset,
    result::KeenValidationResult;
    mode::Union{Symbol, Nothing} = nothing,
    artifact_paths::AbstractVector{<:AbstractString} = String[],
)
    resolved_mode =
        mode === nothing ? string(get(dataset.metadata, "mode", "")) : string(mode)
    Dict{String, Any}(
        "report_kind" => "keen-empirical-phase3",
        "methodology" => Dict{String, Any}(
            "measurement" => get(dataset.metadata, "methodology_version", ""),
            "calibration" => result.calibration_result.methodology_version,
            "validation" => result.methodology_version,
        ),
        "dataset" => Dict{String, Any}(
            "country" => get(dataset.metadata, "country", ""),
            "mode" => resolved_mode,
            "sample_start" => get(dataset.metadata, "sample_start", ""),
            "sample_end" => get(dataset.metadata, "sample_end", ""),
            "n_obs" => length(dataset),
            "r_param" => dataset.r_param,
            "r_mode" => string(dataset.config.r_mode),
            "series" => _keen_series_report(dataset),
            "quality_flags" => dataset.quality_flags,
            "dropped_dates" => dataset.dropped_dates,
        ),
        "validation" => keen_validation_to_dict(result),
        "artifact_paths" => collect(String, artifact_paths),
        "caveats" => result.caveats,
    )
end

"""
    save_keen_empirical_report(path, dataset, result; mode=nothing, artifact_paths=String[]) -> path

[`keen_empirical_report`](@ref) を JSON として `path` へ保存する。秘密情報は含めない。
"""
function save_keen_empirical_report(
    path::AbstractString,
    dataset::KeenEmpiricalDataset,
    result::KeenValidationResult;
    mode::Union{Symbol, Nothing} = nothing,
    artifact_paths::AbstractVector{<:AbstractString} = String[],
)
    report =
        keen_empirical_report(dataset, result; mode = mode, artifact_paths = artifact_paths)
    open(path, "w") do io
        JSON3.pretty(io, _keen_json_safe(report))
    end
    path
end
