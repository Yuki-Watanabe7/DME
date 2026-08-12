# keen_calibration.jl: Keen モデルの限定キャリブレーション（ODE residual 方式）と
# 再現可能な推定結果を生成する層。
#
# 設計方針は docs/models/keen_empirical_strategy.md §5（決定記録は docs/adr/0004）。
#   - 固定パラメータと推定対象を明示的に分離し、全 10 パラメータ同時推定を既定にしない
#   - 観測状態の差分（forward difference, Δt=0.25）と keen_rhs の残差を方程式単位で最小化
#   - 欠損・非有限・発散・状態域逸脱・非連続の区間を objective から除外し内訳を保存
#   - スケール差を系列標準偏差で正規化（weight）して吸収する
#   - multi-start と境界到達・非一意解・弱識別・objective 感応度を診断として返す
#   - 標準誤差（Hessian ベース推論）は本 methodology version では未対応と明示する
#   - 設定・結果を機械可読形式（JSON）へ保存し、同じ fixture から再実行できる
#
# KeenModel の struct・parameters・ODE 動学（keen_rhs 等）はこのファイルの追加によって
# 一切変更されない（読み取り専用の後処理層）。

"""
    KEEN_CALIBRATION_METHODOLOGY_VERSION

本層（限定キャリブレーション・ODE residual）の methodology version。実証データ層の
methodology version（`KEEN_EMPIRICAL_METHODOLOGY_VERSION`、`keen-empirical/*`）とは独立に
管理する。推定対象/固定の分離方針・objective 定義・差分近似方式・診断規則を変更する場合に更新する。
"""
const KEEN_CALIBRATION_METHODOLOGY_VERSION = "keen-calibration/1.0.0"

"""
    KEEN_LITERATURE_PARAMS

Grasselli & Costa Lima (2012) 数値例に基づく Keen モデルの文献 default パラメータ
（[keen.md](https://github.com/Yuki-Watanabe7/DME/blob/main/docs/models/keen.md) §パラメータと同一）。固定値の供給源（`:literature`）や
literature vs calibrated 比較（[`calibrate_keen`](@ref) の `literature_objective`）に用いる。
"""
const KEEN_LITERATURE_PARAMS = (
    α = 0.025,
    β = 0.02,
    δ = 0.01,
    ν = 3.0,
    r = 0.03,
    φ0 = 0.0400641,
    φ1 = 6.41e-5,
    κ0 = -0.0065,
    κ1 = exp(-5),
    κ2 = 20.0,
)

# Keen モデルの全パラメータ名（固定/推定の網羅性検証に使う）
const _KEEN_ALL_PARAMS = (:α, :β, :δ, :ν, :r, :φ0, :φ1, :κ0, :κ1, :κ2)
# 常に固定（推定対象にしない）構造パラメータ
const _KEEN_ALWAYS_FIXED = (:α, :β, :δ, :ν, :r)
# 推定可能な行動パラメータ
const _KEEN_ESTIMABLE = (:φ0, :φ1, :κ0, :κ1, :κ2)
# 正値制約（符号制約）を要する行動パラメータ
const _KEEN_POSITIVE = (:φ1, :κ1, :κ2)

"""
    keen_literature_params() -> Dict{Symbol, Float64}

`KEEN_LITERATURE_PARAMS` を `Dict{Symbol,Float64}` で返す（推定/固定の既定値やコピー用途）。
"""
keen_literature_params() = Dict{Symbol, Float64}(pairs(KEEN_LITERATURE_PARAMS))

# ---------------------------------------------------------------------------
# 決定的な擬似乱数（multi-start の初期値摂動に使用。RNG 依存を増やさない自前 LCG）
# ---------------------------------------------------------------------------

mutable struct _KeenLCG
    state::UInt64
end

_keen_lcg(seed::Integer) = _KeenLCG(UInt64(seed) ⊻ 0x2545f4914f6cdd1d | 0x1)  # 0 除け・定数で分散

function _keen_rand(g::_KeenLCG)
    # 64bit 線形合同法（UInt64 演算は Julia では自然に wrap する）→ [0,1)
    g.state = g.state * 0x5deece66d + 0xb
    return Float64(g.state >> 11) / 9007199254740992.0  # 上位 53bit / 2^53
end

# ---------------------------------------------------------------------------
# 推定設定
# ---------------------------------------------------------------------------

"""
    KeenCalibrationConfig

Keen 限定キャリブレーションの再現可能な推定設定。全 10 パラメータ同時推定を既定にせず、
固定パラメータと推定対象を明示的に分離する（[keen_empirical_strategy.md](https://github.com/Yuki-Watanabe7/DME/blob/main/docs/models/keen_empirical_strategy.md) §3・§5）。

## 主なフィールド
- `estimated_params::Vector{Symbol}` : 推定対象パラメータ名（`_KEEN_ESTIMABLE` の部分集合）。既定 `[:φ0,:φ1,:κ0,:κ1]`
- `fixed_params::Dict{Symbol,Float64}` : 固定パラメータ値（`estimated_params` の補集合を必ず網羅）
- `fixed_basis::Dict{Symbol,Symbol}` : 固定値の根拠区分（`:data` / `:literature` / `:assumption`）
- `bounds::Dict{Symbol,Tuple{Float64,Float64}}` : 推定対象の下限・上限（正値制約は下限 `>0` で表現）
- `initial_guess::Dict{Symbol,Float64}` : 推定対象の初期値（bounds 内）
- `objective_method::Symbol` : `:ode_residual`（本 version 唯一の方式）
- `weight_mode::Symbol` : スケール差処理（`:std_normalize` / `:fixed` / `:none`）
- `weights::Dict{Symbol,Float64}` : `weight_mode == :fixed` のときの方程式別重み（`:ω`/`:λ`/`:d`）
- `use_calibration_split::Bool` : `true` で `dataset.calibration_indices` のみ使用（look-ahead 回避）
- `difference_scheme::Symbol` : 差分近似方式（`:forward`。端点処理は前進差分で最終点を残差に使わない）
- `optimizer::Symbol` : `:nelder_mead`
- `max_iterations::Int` / `tol::Float64` : optimizer の最大反復数・収束許容誤差
- `n_starts::Int` / `seed::Int` / `start_perturbation::Float64` : multi-start 数・種・初期値相対摂動幅
- `boundary_atol::Float64` : 境界到達判定の絶対許容差
- `nonunique_obj_rtol::Float64` / `nonunique_param_rtol::Float64` : 非一意解検出の objective/パラメータ相対閾値
- `weak_param_rtol::Float64` : 収束解のばらつきによる弱識別判定の相対閾値
- `sensitivity_step::Float64` : objective 感応度計算の相対摂動幅
- `invalid_penalty::Float64` : 良い均衡が定義できない候補への penalty
- `methodology_version::String`

弱識別・双安定性・fit の限界については [keen_empirical_strategy.md](https://github.com/Yuki-Watanabe7/DME/blob/main/docs/models/keen_empirical_strategy.md) §8 を参照。
推定値を因果パラメータや普遍定数として断定してはならない。
"""
struct KeenCalibrationConfig
    estimated_params::Vector{Symbol}
    fixed_params::Dict{Symbol, Float64}
    fixed_basis::Dict{Symbol, Symbol}
    bounds::Dict{Symbol, Tuple{Float64, Float64}}
    initial_guess::Dict{Symbol, Float64}
    objective_method::Symbol
    weight_mode::Symbol
    weights::Dict{Symbol, Float64}
    use_calibration_split::Bool
    difference_scheme::Symbol
    optimizer::Symbol
    max_iterations::Int
    tol::Float64
    n_starts::Int
    seed::Int
    start_perturbation::Float64
    boundary_atol::Float64
    nonunique_obj_rtol::Float64
    nonunique_param_rtol::Float64
    weak_param_rtol::Float64
    sensitivity_step::Float64
    invalid_penalty::Float64
    methodology_version::String
end

function KeenCalibrationConfig(;
    estimated_params::Vector{Symbol} = [:φ0, :φ1, :κ0, :κ1],
    fixed_params::Dict{Symbol, Float64},
    fixed_basis::Dict{Symbol, Symbol} = Dict{Symbol, Symbol}(),
    bounds::Dict{Symbol, Tuple{Float64, Float64}},
    initial_guess::Dict{Symbol, Float64},
    objective_method::Symbol = :ode_residual,
    weight_mode::Symbol = :std_normalize,
    weights::Dict{Symbol, Float64} = Dict(:ω => 1.0, :λ => 1.0, :d => 1.0),
    use_calibration_split::Bool = true,
    difference_scheme::Symbol = :forward,
    optimizer::Symbol = :nelder_mead,
    max_iterations::Int = 2000,
    tol::Float64 = 1e-12,
    n_starts::Int = 5,
    seed::Int = 20260718,
    start_perturbation::Float64 = 0.5,
    boundary_atol::Float64 = 1e-6,
    nonunique_obj_rtol::Float64 = 1e-3,
    nonunique_param_rtol::Float64 = 1e-2,
    weak_param_rtol::Float64 = 1e-2,
    sensitivity_step::Float64 = 1e-3,
    invalid_penalty::Float64 = 1e6,
    methodology_version::String = KEEN_CALIBRATION_METHODOLOGY_VERSION,
)
    isempty(estimated_params) &&
        throw(ArgumentError("estimated_params は 1 個以上必要です"))
    length(unique(estimated_params)) == length(estimated_params) ||
        throw(ArgumentError("estimated_params に重複があります"))
    for p in estimated_params
        p in _KEEN_ESTIMABLE || throw(
            ArgumentError(
                "$(repr(p)) は推定対象にできません（推定可能なのは $(_KEEN_ESTIMABLE)）",
            ),
        )
    end
    # 固定/推定の網羅性・排他性
    est = Set(estimated_params)
    for p in _KEEN_ALWAYS_FIXED
        haskey(fixed_params, p) ||
            throw(ArgumentError("固定パラメータ $(repr(p)) が fixed_params にありません"))
    end
    for p in _KEEN_ALL_PARAMS
        infixed = haskey(fixed_params, p)
        inest = p in est
        (infixed && inest) &&
            throw(ArgumentError("$(repr(p)) が固定と推定の両方に指定されています"))
        (infixed || inest) ||
            throw(ArgumentError("$(repr(p)) が固定にも推定にも指定されていません"))
    end
    objective_method === :ode_residual ||
        throw(ArgumentError("本 version の objective_method は :ode_residual のみです"))
    weight_mode in (:std_normalize, :fixed, :none) || throw(
        ArgumentError("weight_mode は :std_normalize / :fixed / :none のいずれかです"),
    )
    optimizer === :nelder_mead ||
        throw(ArgumentError("本 version の optimizer は :nelder_mead のみです"))
    difference_scheme === :forward ||
        throw(ArgumentError("本 version の difference_scheme は :forward のみです"))
    # bounds / initial guess / 符号制約
    for p in estimated_params
        haskey(bounds, p) || throw(ArgumentError("bounds に $(repr(p)) がありません"))
        haskey(initial_guess, p) ||
            throw(ArgumentError("initial_guess に $(repr(p)) がありません"))
        lo, hi = bounds[p]
        lo < hi ||
            throw(ArgumentError("$(repr(p)) の bounds は lo < hi でなければなりません"))
        g = initial_guess[p]
        lo <= g <= hi || throw(
            ArgumentError(
                "$(repr(p)) の initial_guess=$(g) が bounds [$(lo),$(hi)] 外です",
            ),
        )
        if p in _KEEN_POSITIVE
            lo > 0.0 || throw(
                ArgumentError(
                    "$(repr(p)) は正値制約があり bounds 下限は 0 より大きくなければなりません",
                ),
            )
        end
    end
    # 固定値の符号制約
    for p in _KEEN_POSITIVE
        if haskey(fixed_params, p)
            fixed_params[p] > 0.0 ||
                throw(ArgumentError("固定パラメータ $(repr(p)) は正でなければなりません"))
        end
    end
    haskey(fixed_params, :ν) &&
        fixed_params[:ν] <= 0.0 &&
        throw(ArgumentError("固定パラメータ :ν は正でなければなりません"))
    n_starts >= 1 || throw(ArgumentError("n_starts は 1 以上でなければなりません"))
    max_iterations >= 1 ||
        throw(ArgumentError("max_iterations は 1 以上でなければなりません"))
    for (p, b) in fixed_basis
        b in (:data, :literature, :assumption) || throw(
            ArgumentError(
                "$(repr(p)) の根拠区分 $(repr(b)) は :data/:literature/:assumption のいずれかです",
            ),
        )
    end
    KeenCalibrationConfig(
        copy(estimated_params),
        copy(fixed_params),
        copy(fixed_basis),
        copy(bounds),
        copy(initial_guess),
        objective_method,
        weight_mode,
        copy(weights),
        use_calibration_split,
        difference_scheme,
        optimizer,
        max_iterations,
        tol,
        n_starts,
        seed,
        start_perturbation,
        boundary_atol,
        nonunique_obj_rtol,
        nonunique_param_rtol,
        weak_param_rtol,
        sensitivity_step,
        invalid_penalty,
        methodology_version,
    )
end

"""
    keen_default_calibration_config(dataset::KeenEmpiricalDataset; kwargs...) -> KeenCalibrationConfig

米国既定に対応する Keen 限定キャリブレーション設定を、`dataset` から `r`（`dataset.r_param`）を
固定値として取り込んで構築する（[keen_empirical_strategy.md](https://github.com/Yuki-Watanabe7/DME/blob/main/docs/models/keen_empirical_strategy.md) §5.2）。

- **推定対象**: Phillips `φ0,φ1` と投資 `κ0,κ1`（曲率 `κ2` は文献値で固定）
- **固定**: `α,β,δ,ν,κ2`（文献値, `:literature`）・`r`（標本統計, `:data`）
- `kwargs` で `estimated_params`・`bounds`・`n_starts` 等を上書きできる。

推定値を因果パラメータや普遍定数として断定しないこと（fit ≠ 因果・危機確率、§8）。
"""
function keen_default_calibration_config(dataset::KeenEmpiricalDataset; kwargs...)
    lit = KEEN_LITERATURE_PARAMS
    fixed = Dict{Symbol, Float64}(
        :α => lit.α,
        :β => lit.β,
        :δ => lit.δ,
        :ν => lit.ν,
        :r => dataset.r_param,
        :κ2 => lit.κ2,
    )
    basis = Dict{Symbol, Symbol}(
        :α => :literature,
        :β => :literature,
        :δ => :literature,
        :ν => :literature,
        :r => :data,
        :κ2 => :literature,
    )
    bounds = Dict{Symbol, Tuple{Float64, Float64}}(
        :φ0 => (0.0, 0.5),
        :φ1 => (1e-8, 1e-2),
        :κ0 => (-0.5, 0.5),
        :κ1 => (1e-8, 0.5),
    )
    guess =
        Dict{Symbol, Float64}(:φ0 => lit.φ0, :φ1 => lit.φ1, :κ0 => lit.κ0, :κ1 => lit.κ1)
    KeenCalibrationConfig(;
        estimated_params = [:φ0, :φ1, :κ0, :κ1],
        fixed_params = fixed,
        fixed_basis = basis,
        bounds = bounds,
        initial_guess = guess,
        kwargs...,
    )
end

# ---------------------------------------------------------------------------
# 結果型
# ---------------------------------------------------------------------------

"""
    KeenCalibrationStart

multi-start の 1 試行の記録（初期値・推定値・objective・収束状態・反復数）。
"""
struct KeenCalibrationStart
    start_index::Int
    initial::Dict{Symbol, Float64}
    estimated::Dict{Symbol, Float64}
    objective_value::Float64
    converged::Bool
    iterations::Int
end

"""
    KeenCalibrationResult

Keen 限定キャリブレーションの構造化結果。元の `KeenEmpiricalDataset`・`KeenModel` を変更せず、
派生結果として保持する（[keen_empirical_strategy.md](https://github.com/Yuki-Watanabe7/DME/blob/main/docs/models/keen_empirical_strategy.md) §5.3）。

## 主なフィールド
- `config::KeenCalibrationConfig`
- `model::KeenModel` : calibrated モデル（採用解を反映）
- `estimated::Dict{Symbol,Float64}` / `fixed::Dict{Symbol,Float64}` : 推定値・固定値
- `objective_value::Float64` : objective 総値（採用解）
- `objective_contributions::Dict{Symbol,Float64}` : 方程式別寄与（`:ω`/`:λ`/`:d`）
- `converged::Bool` / `iterations::Int` : 採用解の収束状態・反復数
- `n_obs_used::Int` / `n_obs_excluded::Int` : 有効残差ペア数・除外ペア数
- `excluded_reasons::Dict{String,Int}` : 除外内訳（欠損/非有限・非連続・状態域逸脱）
- `weights_used::Dict{Symbol,Float64}` : 実際に用いた方程式別重み
- `adopted_start::Int` : 採用した multi-start のインデックス
- `starts::Vector{KeenCalibrationStart}` : 全 multi-start 結果
- `boundary_hits::Vector{Symbol}` : bounds へ張り付いた推定パラメータ
- `weak_identification::Bool` / `nonunique_solutions::Bool` : 弱識別・非一意解の warning
- `alternative_solutions::Vector{Dict{Symbol,Float64}}` : 採用解と objective が近いが異なる解
- `sensitivity::Dict{Symbol,Float64}` : 各推定パラメータへの objective 感応度（曲率近似。小さいほど弱識別）
- `standard_errors_supported::Bool` : 本 version は `false`（Hessian ベース推論は未対応）
- `literature_objective::Float64` / `literature_params::Dict{Symbol,Float64}` : 文献 default での objective・パラメータ
- `predicted::Dict{Symbol,Vector{Float64}}` / `observed::Dict{Symbol,Vector{Float64}}` : 有効ペアの予測/観測 state 差分
- `pair_times::Vector{Float64}` : 各有効ペアの開始観測時点（年単位）
- `dataset_metadata::Dict{String,Any}` : 系列 ID・期間・measurement version 等（再現用）
- `methodology_version::String`
- `metadata::Dict{String,Any}` : 差分近似方式・端点処理・注意事項等
"""
struct KeenCalibrationResult
    config::KeenCalibrationConfig
    model::KeenModel
    estimated::Dict{Symbol, Float64}
    fixed::Dict{Symbol, Float64}
    objective_value::Float64
    objective_contributions::Dict{Symbol, Float64}
    converged::Bool
    iterations::Int
    n_obs_used::Int
    n_obs_excluded::Int
    excluded_reasons::Dict{String, Int}
    weights_used::Dict{Symbol, Float64}
    adopted_start::Int
    starts::Vector{KeenCalibrationStart}
    boundary_hits::Vector{Symbol}
    weak_identification::Bool
    nonunique_solutions::Bool
    alternative_solutions::Vector{Dict{Symbol, Float64}}
    sensitivity::Dict{Symbol, Float64}
    standard_errors_supported::Bool
    literature_objective::Float64
    literature_params::Dict{Symbol, Float64}
    predicted::Dict{Symbol, Vector{Float64}}
    observed::Dict{Symbol, Vector{Float64}}
    pair_times::Vector{Float64}
    dataset_metadata::Dict{String, Any}
    methodology_version::String
    metadata::Dict{String, Any}
end

# ---------------------------------------------------------------------------
# 残差ペアの前計算（θ に依存しない部分）
# ---------------------------------------------------------------------------

# 1 つの forward-difference 残差ペア（開始点で keen_rhs を評価）
struct _KeenResidualPair
    start_time::Float64
    ω::Float64
    λ::Float64
    d::Float64
    π::Float64
    invλ2::Float64      # 1 / (1-λ)^2
    dω_obs::Float64     # (ω[j]-ω[i]) / Δt
    dλ_obs::Float64
    dd_obs::Float64
end

"""
    _keen_build_pairs(dataset, indices, r; dt_atol=1e-6)
        -> (pairs::Vector{_KeenResidualPair}, n_excluded, reasons)

`indices`（時間順・連続想定）の隣接観測から前進差分の残差ペアを構築する。
非連続（Δt≠0.25）・非有限・状態域逸脱（`λ≥1`・`ω≤0`・`d<0`）のペアは除外し内訳を数える。
`r` は固定金利パラメータ（`π = 1 - ω - r d` の構成に用いる）。
"""
function _keen_build_pairs(
    dataset::KeenEmpiricalDataset,
    indices::Vector{Int},
    r::Float64;
    dt_atol::Float64 = 1e-6,
)
    pairs = _KeenResidualPair[]
    reasons =
        Dict{String, Int}("non_contiguous" => 0, "non_finite" => 0, "out_of_domain" => 0)
    n_excluded = 0
    for k in 1:(length(indices) - 1)
        i = indices[k]
        j = indices[k + 1]
        # 連続位置でなければ（分割で飛んでいれば）非連続
        Δt = dataset.observation_times[j] - dataset.observation_times[i]
        if !isapprox(Δt, 0.25; atol = dt_atol)
            reasons["non_contiguous"] += 1
            n_excluded += 1
            continue
        end
        ωi, λi, di = dataset.ω[i], dataset.λ[i], dataset.d[i]
        ωj, λj, dj = dataset.ω[j], dataset.λ[j], dataset.d[j]
        if !(
            isfinite(ωi) &&
            isfinite(λi) &&
            isfinite(di) &&
            isfinite(ωj) &&
            isfinite(λj) &&
            isfinite(dj)
        )
            reasons["non_finite"] += 1
            n_excluded += 1
            continue
        end
        if λi >= 1.0 || λj >= 1.0 || ωi <= 0.0 || di < 0.0
            reasons["out_of_domain"] += 1
            n_excluded += 1
            continue
        end
        πi = 1.0 - ωi - r * di
        push!(
            pairs,
            _KeenResidualPair(
                dataset.observation_times[i],
                ωi,
                λi,
                di,
                πi,
                1.0 / (1.0 - λi)^2,
                (ωj - ωi) / Δt,
                (λj - λi) / Δt,
                (dj - di) / Δt,
            ),
        )
    end
    (pairs, n_excluded, reasons)
end

# 母標準偏差（Statistics 依存を避け自前計算）。n<2 または分散 0 のとき 0 を返す
function _keen_std(v::AbstractVector{<:Real})
    n = length(v)
    n < 2 && return 0.0
    μ = sum(v) / n
    s = 0.0
    for x in v
        s += (x - μ)^2
    end
    sqrt(s / n)
end

"""
    _keen_weights(config, pairs) -> Dict{Symbol,Float64}

`weight_mode` に従い方程式別重みを決める。`:std_normalize` は観測差分の母標準偏差の逆数
（0 のとき 1.0 へ退避）、`:fixed` は `config.weights`、`:none` は全て 1.0。
"""
function _keen_weights(config::KeenCalibrationConfig, pairs::Vector{_KeenResidualPair})
    if config.weight_mode === :none
        return Dict(:ω => 1.0, :λ => 1.0, :d => 1.0)
    elseif config.weight_mode === :fixed
        return Dict(
            :ω => get(config.weights, :ω, 1.0),
            :λ => get(config.weights, :λ, 1.0),
            :d => get(config.weights, :d, 1.0),
        )
    else # :std_normalize
        σω = _keen_std([p.dω_obs for p in pairs])
        σλ = _keen_std([p.dλ_obs for p in pairs])
        σd = _keen_std([p.dd_obs for p in pairs])
        inv(σ) = σ > 0.0 ? 1.0 / σ : 1.0
        return Dict(:ω => inv(σω), :λ => inv(σλ), :d => inv(σd))
    end
end

# 固定 + 推定（Dict）から KeenModel を構築
function _keen_model_from_params(config::KeenCalibrationConfig, θ::Dict{Symbol, Float64})
    getp(name) = haskey(θ, name) ? θ[name] : config.fixed_params[name]
    KeenModel(
        config.fixed_params[:α],
        config.fixed_params[:β],
        config.fixed_params[:δ],
        config.fixed_params[:ν],
        config.fixed_params[:r],
        getp(:φ0),
        getp(:φ1),
        getp(:κ0),
        getp(:κ1),
        getp(:κ2),
    )
end

# 良い均衡が定義できない候補への penalty（非現実的モデル領域の拒否）
function _keen_invalid_penalty(m::KeenModel, penalty::Float64)
    ok = try
        ss = steady_state(m)
        all(isfinite, (ss.ω, ss.λ, ss.d, ss.π, ss.g))
    catch
        false
    end
    ok ? 0.0 : penalty
end

"""
    _keen_objective(m, pairs, w, penalty) -> NamedTuple

calibrated モデル `m` の keen_rhs と前進差分観測の残差二乗和（方程式別重み `w`）を計算する。
返り値は `(total, ω, λ, d)`（`total` に良い均衡不定 penalty を含む）。
"""
function _keen_objective(
    m::KeenModel,
    pairs::Vector{_KeenResidualPair},
    w::Dict{Symbol, Float64},
    penalty::Float64,
)
    sω = 0.0
    sλ = 0.0
    sd = 0.0
    wω, wλ, wd = w[:ω], w[:λ], w[:d]
    for p in pairs
        Φ = m.φ1 * p.invλ2 - m.φ0
        κ = m.κ0 + m.κ1 * exp(m.κ2 * p.π)
        g = κ / m.ν - m.δ
        rω = p.dω_obs - p.ω * (Φ - m.α)
        rλ = p.dλ_obs - p.λ * (g - m.α - m.β)
        rd = p.dd_obs - (κ - p.π - p.d * g)
        sω += (rω * wω)^2
        sλ += (rλ * wλ)^2
        sd += (rd * wd)^2
    end
    pen = _keen_invalid_penalty(m, penalty)
    (total = sω + sλ + sd + pen, ω = sω, λ = sλ, d = sd)
end

# ---------------------------------------------------------------------------
# Nelder-Mead（bound は clamp + 二乗 penalty で内側へ押し戻す。自前実装・決定的）
# ---------------------------------------------------------------------------

"""
    _nelder_mead(f, x0, lo, hi; max_iter, tol) -> (x_best, f_best, iters, converged)

境界 `[lo,hi]` 付き Nelder-Mead。候補は評価前に clamp し、境界違反へ二乗 penalty を加えて
単体を内側へ戻す。`f` は clamp 済みベクトルに対して評価される（`x_best` は clamp 済み）。
初期単体は決定的に構築するため同一入力で同一結果になる。
"""
function _nelder_mead(
    f,
    x0::Vector{Float64},
    lo::Vector{Float64},
    hi::Vector{Float64};
    max_iter::Int = 2000,
    tol::Float64 = 1e-12,
)
    n = length(x0)
    bound_pen = 1e12
    function fp(x)
        viol = 0.0
        xc = similar(x)
        @inbounds for k in 1:n
            xc[k] = clamp(x[k], lo[k], hi[k])
            viol += (x[k] - xc[k])^2
        end
        f(xc) + bound_pen * viol
    end

    # 初期単体（各軸へ決定的なステップ）
    simplex = Vector{Vector{Float64}}(undef, n + 1)
    fvals = Vector{Float64}(undef, n + 1)
    simplex[1] = copy(x0)
    fvals[1] = fp(x0)
    for k in 1:n
        x = copy(x0)
        step = max(0.05 * abs(x0[k]), 0.01 * (hi[k] - lo[k]), 1e-4)
        x[k] = clamp(x0[k] + step, lo[k], hi[k])
        if x[k] == x0[k]  # 上限に張り付いていれば下側へ
            x[k] = clamp(x0[k] - step, lo[k], hi[k])
        end
        simplex[k + 1] = x
        fvals[k + 1] = fp(x)
    end

    α, γ, ρ, σ = 1.0, 2.0, 0.5, 0.5
    iters = 0
    converged = false
    for _ in 1:max_iter
        iters += 1
        order = sortperm(fvals)
        simplex = simplex[order]
        fvals = fvals[order]

        fbest, fworst = fvals[1], fvals[end]
        if abs(fworst - fbest) <= tol * (abs(fbest) + tol)
            converged = true
            break
        end

        # 重心（最悪点を除く）
        xc = zeros(n)
        for i in 1:n
            xc .+= simplex[i]
        end
        xc ./= n

        xw = simplex[end]
        xr = xc .+ α .* (xc .- xw)
        fr = fp(xr)

        if fr < fvals[1]
            xe = xc .+ γ .* (xr .- xc)
            fe = fp(xe)
            if fe < fr
                simplex[end] = xe
                fvals[end] = fe
            else
                simplex[end] = xr
                fvals[end] = fr
            end
        elseif fr < fvals[n]
            simplex[end] = xr
            fvals[end] = fr
        else
            # 収縮
            if fr < fvals[end]
                xk = xc .+ ρ .* (xr .- xc)  # 外側収縮
            else
                xk = xc .+ ρ .* (xw .- xc)  # 内側収縮
            end
            fk = fp(xk)
            if fk < min(fr, fvals[end])
                simplex[end] = xk
                fvals[end] = fk
            else
                # 全体縮小
                x1 = simplex[1]
                for i in 2:(n + 1)
                    simplex[i] = x1 .+ σ .* (simplex[i] .- x1)
                    fvals[i] = fp(simplex[i])
                end
            end
        end
    end

    order = sortperm(fvals)
    xbest = simplex[order[1]]
    # clamp 済みの最良点を返す
    xclamped = [clamp(xbest[k], lo[k], hi[k]) for k in 1:n]
    (xclamped, f(xclamped), iters, converged)
end

# ---------------------------------------------------------------------------
# 推定本体
# ---------------------------------------------------------------------------

"""
    calibrate_keen(dataset::KeenEmpiricalDataset, config::KeenCalibrationConfig)
        -> KeenCalibrationResult

`config` の推定対象パラメータを ODE residual 方式で限定的に推定する。固定パラメータは
推定中に変更されない。multi-start（決定的な初期値摂動）・境界到達・非一意解・弱識別・
objective 感応度・literature 比較を診断として返す。同一 `dataset`・`config` で決定的。

推定値を因果パラメータ・普遍定数・危機確率として断定してはならない
（[keen_empirical_strategy.md](https://github.com/Yuki-Watanabe7/DME/blob/main/docs/models/keen_empirical_strategy.md) §8）。
"""
function calibrate_keen(dataset::KeenEmpiricalDataset, config::KeenCalibrationConfig)
    r = config.fixed_params[:r]
    indices =
        config.use_calibration_split ? copy(dataset.calibration_indices) :
        collect(1:length(dataset))
    isempty(indices) &&
        throw(ArgumentError("推定に使う観測がありません（calibration_indices が空です）"))

    pairs, n_excluded, reasons = _keen_build_pairs(dataset, indices, r)
    isempty(pairs) && throw(
        ArgumentError(
            "有効な残差ペアが 0 です（欠損・非連続・状態域逸脱で全て除外されました）",
        ),
    )
    w = _keen_weights(config, pairs)

    est_names = config.estimated_params
    lo = [config.bounds[p][1] for p in est_names]
    hi = [config.bounds[p][2] for p in est_names]
    x0 = [config.initial_guess[p] for p in est_names]

    objfun(x) = _keen_objective(
        _keen_model_from_params(config, _keen_vec_to_dict(est_names, x)),
        pairs,
        w,
        config.invalid_penalty,
    ).total

    # ---- multi-start 初期値（1 個目は configured、以降は決定的摂動）----
    starts_x0 = Vector{Vector{Float64}}(undef, config.n_starts)
    starts_x0[1] = copy(x0)
    if config.n_starts > 1
        g = _keen_lcg(config.seed)
        for s in 2:(config.n_starts)
            xs = similar(x0)
            for k in 1:length(est_names)
                u = _keen_rand(g)               # [0,1)
                span = hi[k] - lo[k]
                base = x0[k]
                # base の周りを相対摂動、bounds でクリップ
                δ = config.start_perturbation * (2u - 1) * max(abs(base), 0.1 * span)
                xs[k] = clamp(base + δ, lo[k], hi[k])
            end
            starts_x0[s] = xs
        end
    end

    starts = KeenCalibrationStart[]
    for s in 1:(config.n_starts)
        xb, fb, iters, conv = _nelder_mead(
            objfun,
            starts_x0[s],
            lo,
            hi;
            max_iter = config.max_iterations,
            tol = config.tol,
        )
        push!(
            starts,
            KeenCalibrationStart(
                s,
                _keen_vec_to_dict(est_names, starts_x0[s]),
                _keen_vec_to_dict(est_names, xb),
                fb,
                conv,
                iters,
            ),
        )
    end

    # ---- 採用解（objective 最小）----
    adopted = argmin([st.objective_value for st in starts])
    best = starts[adopted]
    θ_best = best.estimated
    xbest = [θ_best[p] for p in est_names]
    m_best = _keen_model_from_params(config, θ_best)
    obj = _keen_objective(m_best, pairs, w, config.invalid_penalty)

    # ---- 境界到達 ----
    boundary_hits = Symbol[]
    for (k, p) in enumerate(est_names)
        if isapprox(xbest[k], lo[k]; atol = config.boundary_atol) ||
           isapprox(xbest[k], hi[k]; atol = config.boundary_atol)
            push!(boundary_hits, p)
        end
    end

    # ---- 非一意解の検出（objective が近いが解が異なる start）----
    alt = Dict{Symbol, Float64}[]
    obj_scale = max(best.objective_value, config.tol)
    for st in starts
        st.start_index == adopted && continue
        close_obj =
            abs(st.objective_value - best.objective_value) <=
            config.nonunique_obj_rtol * obj_scale
        if close_obj
            differs = false
            for p in est_names
                denom = max(abs(θ_best[p]), 1e-8)
                if abs(st.estimated[p] - θ_best[p]) / denom > config.nonunique_param_rtol
                    differs = true
                    break
                end
            end
            differs && push!(alt, st.estimated)
        end
    end
    nonunique = !isempty(alt)

    # ---- 弱識別: 収束解のばらつき or 非一意解 or 感応度の平坦さ ----
    conv_starts = [st for st in starts if st.converged]
    spread_weak = false
    if length(conv_starts) >= 2
        for p in est_names
            vals = [st.estimated[p] for st in conv_starts]
            denom = max(abs(θ_best[p]), 1e-8)
            if (maximum(vals) - minimum(vals)) / denom > config.weak_param_rtol
                spread_weak = true
                break
            end
        end
    end

    # ---- objective 感応度（曲率近似）----
    sensitivity = Dict{Symbol, Float64}()
    obj0 = obj.total
    for (k, p) in enumerate(est_names)
        h = config.sensitivity_step * max(abs(xbest[k]), 1e-6)
        xp = copy(xbest)
        xm = copy(xbest)
        xp[k] = clamp(xbest[k] + h, lo[k], hi[k])
        xm[k] = clamp(xbest[k] - h, lo[k], hi[k])
        fp = objfun(xp)
        fm = objfun(xm)
        curv = (fp - 2obj0 + fm) / (h^2)
        sensitivity[p] = curv
    end
    flat_weak = any(abs(v) < config.tol for v in values(sensitivity))
    weak = nonunique || spread_weak || flat_weak

    # ---- 予測/観測 state 差分（採用解での keen_rhs）----
    predicted = Dict(:ω => Float64[], :λ => Float64[], :d => Float64[])
    observed = Dict(:ω => Float64[], :λ => Float64[], :d => Float64[])
    pair_times = Float64[]
    for p in pairs
        Φ = m_best.φ1 * p.invλ2 - m_best.φ0
        κ = m_best.κ0 + m_best.κ1 * exp(m_best.κ2 * p.π)
        gm = κ / m_best.ν - m_best.δ
        push!(predicted[:ω], p.ω * (Φ - m_best.α))
        push!(predicted[:λ], p.λ * (gm - m_best.α - m_best.β))
        push!(predicted[:d], κ - p.π - p.d * gm)
        push!(observed[:ω], p.dω_obs)
        push!(observed[:λ], p.dλ_obs)
        push!(observed[:d], p.dd_obs)
        push!(pair_times, p.start_time)
    end

    # ---- literature default での objective（比較用）----
    lit_params = Dict{Symbol, Float64}()
    for p in est_names
        lit_params[p] = getproperty(KEEN_LITERATURE_PARAMS, p)
    end
    m_lit = _keen_model_from_params(config, lit_params)
    lit_obj = _keen_objective(m_lit, pairs, w, config.invalid_penalty).total

    fixed_used = copy(config.fixed_params)
    dataset_metadata = _keen_dataset_metadata(dataset)

    metadata = Dict{String, Any}(
        "objective_method" => string(config.objective_method),
        "difference_scheme" => string(config.difference_scheme),
        "endpoint_handling" => "forward-difference; 最終観測点は残差の開始点にならない",
        "weight_mode" => string(config.weight_mode),
        "use_calibration_split" => config.use_calibration_split,
        "n_starts" => config.n_starts,
        "seed" => config.seed,
        "standard_errors_note" => "標準誤差（Hessian ベースの統計推論）は本 methodology version では未対応。sensitivity は objective の曲率近似であり分散推定ではない",
        "caveat" => "推定値は近似対応する集計系列への当てはめであり、因果パラメータ・普遍定数・危機発生確率ではない",
    )

    KeenCalibrationResult(
        config,
        m_best,
        θ_best,
        fixed_used,
        obj.total,
        Dict(:ω => obj.ω, :λ => obj.λ, :d => obj.d),
        best.converged,
        best.iterations,
        length(pairs),
        n_excluded,
        reasons,
        w,
        adopted,
        starts,
        boundary_hits,
        weak,
        nonunique,
        alt,
        sensitivity,
        false,  # standard_errors_supported
        lit_obj,
        lit_params,
        predicted,
        observed,
        pair_times,
        dataset_metadata,
        config.methodology_version,
        metadata,
    )
end

_keen_vec_to_dict(names::Vector{Symbol}, x::Vector{Float64}) =
    Dict{Symbol, Float64}(names[k] => x[k] for k in 1:length(names))

function _keen_dataset_metadata(dataset::KeenEmpiricalDataset)
    prov = dataset.provenance
    Dict{String, Any}(
        "country" => dataset.config.country,
        "measurement_version" => dataset.config.methodology_version,
        "sample_start" => get(dataset.metadata, "sample_start", ""),
        "sample_end" => get(dataset.metadata, "sample_end", ""),
        "n_obs" => length(dataset),
        "mode" => string(get(dataset.metadata, "mode", "")),
        "vintage" => get(dataset.metadata, "vintage", ""),
        "series_ids" => Dict(
            string(v) => haskey(prov, v) ? prov[v].series_id : "" for v in (:ω, :λ, :d, :r)
        ),
        "source_ids" => Dict(
            string(v) => haskey(prov, v) ? prov[v].source_id : "" for v in (:ω, :λ, :d, :r)
        ),
        "r_param" => dataset.r_param,
        "r_mode" => string(dataset.config.r_mode),
    )
end

# ---------------------------------------------------------------------------
# 保存・読込（JSON、再現に必要な公開設定のみ）
# ---------------------------------------------------------------------------

"""
    keen_calibration_config_to_dict(config) -> Dict{String,Any}

`KeenCalibrationConfig` を JSON 化可能な `Dict`（Symbol/Tuple を string/array へ）に変換する。
"""
function keen_calibration_config_to_dict(config::KeenCalibrationConfig)
    Dict{String, Any}(
        "estimated_params" => string.(config.estimated_params),
        "fixed_params" => Dict(string(k) => v for (k, v) in config.fixed_params),
        "fixed_basis" => Dict(string(k) => string(v) for (k, v) in config.fixed_basis),
        "bounds" => Dict(string(k) => [v[1], v[2]] for (k, v) in config.bounds),
        "initial_guess" => Dict(string(k) => v for (k, v) in config.initial_guess),
        "objective_method" => string(config.objective_method),
        "weight_mode" => string(config.weight_mode),
        "weights" => Dict(string(k) => v for (k, v) in config.weights),
        "use_calibration_split" => config.use_calibration_split,
        "difference_scheme" => string(config.difference_scheme),
        "optimizer" => string(config.optimizer),
        "max_iterations" => config.max_iterations,
        "tol" => config.tol,
        "n_starts" => config.n_starts,
        "seed" => config.seed,
        "start_perturbation" => config.start_perturbation,
        "boundary_atol" => config.boundary_atol,
        "nonunique_obj_rtol" => config.nonunique_obj_rtol,
        "nonunique_param_rtol" => config.nonunique_param_rtol,
        "weak_param_rtol" => config.weak_param_rtol,
        "sensitivity_step" => config.sensitivity_step,
        "invalid_penalty" => config.invalid_penalty,
        "methodology_version" => config.methodology_version,
    )
end

# JSON3.Object / Dict の双方から取り出せる小ヘルパ
_kc_get(d, key) = d[key]
_kc_sym(x) = Symbol(String(x))
_kc_float(x) = Float64(x)
_kc_int(x) = Int(x)

"""
    keen_calibration_config_from_dict(d) -> KeenCalibrationConfig

[`keen_calibration_config_to_dict`](@ref) の逆変換。`Dict` または `JSON3.Object` を受け付ける。
"""
function keen_calibration_config_from_dict(d)
    est = [_kc_sym(x) for x in _kc_get(d, "estimated_params")]
    fixed = Dict{Symbol, Float64}(
        _kc_sym(k) => _kc_float(v) for (k, v) in pairs(_kc_get(d, "fixed_params"))
    )
    basis = Dict{Symbol, Symbol}(
        _kc_sym(k) => _kc_sym(v) for (k, v) in pairs(_kc_get(d, "fixed_basis"))
    )
    bounds = Dict{Symbol, Tuple{Float64, Float64}}()
    for (k, v) in pairs(_kc_get(d, "bounds"))
        bounds[_kc_sym(k)] = (_kc_float(v[1]), _kc_float(v[2]))
    end
    guess = Dict{Symbol, Float64}(
        _kc_sym(k) => _kc_float(v) for (k, v) in pairs(_kc_get(d, "initial_guess"))
    )
    weights = Dict{Symbol, Float64}(
        _kc_sym(k) => _kc_float(v) for (k, v) in pairs(_kc_get(d, "weights"))
    )
    KeenCalibrationConfig(;
        estimated_params = est,
        fixed_params = fixed,
        fixed_basis = basis,
        bounds = bounds,
        initial_guess = guess,
        objective_method = _kc_sym(_kc_get(d, "objective_method")),
        weight_mode = _kc_sym(_kc_get(d, "weight_mode")),
        weights = weights,
        use_calibration_split = Bool(_kc_get(d, "use_calibration_split")),
        difference_scheme = _kc_sym(_kc_get(d, "difference_scheme")),
        optimizer = _kc_sym(_kc_get(d, "optimizer")),
        max_iterations = _kc_int(_kc_get(d, "max_iterations")),
        tol = _kc_float(_kc_get(d, "tol")),
        n_starts = _kc_int(_kc_get(d, "n_starts")),
        seed = _kc_int(_kc_get(d, "seed")),
        start_perturbation = _kc_float(_kc_get(d, "start_perturbation")),
        boundary_atol = _kc_float(_kc_get(d, "boundary_atol")),
        nonunique_obj_rtol = _kc_float(_kc_get(d, "nonunique_obj_rtol")),
        nonunique_param_rtol = _kc_float(_kc_get(d, "nonunique_param_rtol")),
        weak_param_rtol = _kc_float(_kc_get(d, "weak_param_rtol")),
        sensitivity_step = _kc_float(_kc_get(d, "sensitivity_step")),
        invalid_penalty = _kc_float(_kc_get(d, "invalid_penalty")),
        methodology_version = String(_kc_get(d, "methodology_version")),
    )
end

"""
    keen_calibration_to_dict(result) -> Dict{String,Any}

`KeenCalibrationResult` を JSON 化可能な `Dict` へ変換する（再現に必要な公開設定・推定値・
診断・dataset provenance を含む。optimizer 内部状態は保存しない）。
"""
function keen_calibration_to_dict(result::KeenCalibrationResult)
    symdict(x) = Dict(string(k) => v for (k, v) in x)
    Dict{String, Any}(
        "config" => keen_calibration_config_to_dict(result.config),
        "estimated" => symdict(result.estimated),
        "fixed" => symdict(result.fixed),
        "objective_value" => result.objective_value,
        "objective_contributions" => symdict(result.objective_contributions),
        "converged" => result.converged,
        "iterations" => result.iterations,
        "n_obs_used" => result.n_obs_used,
        "n_obs_excluded" => result.n_obs_excluded,
        "excluded_reasons" => result.excluded_reasons,
        "weights_used" => symdict(result.weights_used),
        "adopted_start" => result.adopted_start,
        "starts" => [
            Dict{String, Any}(
                "start_index" => st.start_index,
                "initial" => symdict(st.initial),
                "estimated" => symdict(st.estimated),
                "objective_value" => st.objective_value,
                "converged" => st.converged,
                "iterations" => st.iterations,
            ) for st in result.starts
        ],
        "boundary_hits" => string.(result.boundary_hits),
        "weak_identification" => result.weak_identification,
        "nonunique_solutions" => result.nonunique_solutions,
        "alternative_solutions" => [symdict(a) for a in result.alternative_solutions],
        "sensitivity" => symdict(result.sensitivity),
        "standard_errors_supported" => result.standard_errors_supported,
        "literature_objective" => result.literature_objective,
        "literature_params" => symdict(result.literature_params),
        "dataset_metadata" => result.dataset_metadata,
        "methodology_version" => result.methodology_version,
        "metadata" => result.metadata,
    )
end

"""
    save_keen_calibration(path, result)

`KeenCalibrationResult` を JSON として `path` へ保存する（再現に必要な公開設定・推定値・診断）。
"""
function save_keen_calibration(path::AbstractString, result::KeenCalibrationResult)
    open(path, "w") do io
        JSON3.pretty(io, keen_calibration_to_dict(result))
    end
    path
end

"""
    save_keen_calibration_config(path, config)

`KeenCalibrationConfig` を JSON として `path` へ保存する。
"""
function save_keen_calibration_config(path::AbstractString, config::KeenCalibrationConfig)
    open(path, "w") do io
        JSON3.pretty(io, keen_calibration_config_to_dict(config))
    end
    path
end

"""
    load_keen_calibration_config(path) -> KeenCalibrationConfig

`save_keen_calibration_config` / `save_keen_calibration` が書いた JSON から設定を読み込む。
後者（結果ファイル）の場合は `"config"` キー配下を読む。読み込んだ設定は同じ fixture から
[`calibrate_keen`](@ref) を再実行するのに十分な公開設定を含む。
"""
function load_keen_calibration_config(path::AbstractString)
    obj = JSON3.read(read(path, String))
    d = haskey(obj, "config") ? obj["config"] : obj
    keen_calibration_config_from_dict(d)
end
