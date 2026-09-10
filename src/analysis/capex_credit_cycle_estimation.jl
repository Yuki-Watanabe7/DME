# CCC 実証層: 識別可能な推定ブロックの限定推定と parameter artifact（Issue #246 / P-6）。
#
# #245 で `:estimable` / `:weakly_identified` と判定された推定ブロックを **1 ブロックずつ**
# 受け取り、方程式別残差 objective（#170 §7.4-3・§8.5・`Z-15`）を限定的に最小化する。
# 全構造パラメータの一括推定は行わない（ADR 0012 決定 12）。推定不能ブロックの点推定値を
# 捏造せず、`W1`–`W4` 契約どおり固定へ降格・範囲報告・複数仕様・感応度扱いを構造化して返す。
#
# 読み取り専用の後処理層（会計層・診断層・較正層・識別層と同じ配置規律）。provider / HTTP を
# 呼ばない。モデル方程式に実証固有の分岐を加えない（`src/models/capex_credit_cycle.jl` へ
# 単一方程式の公開 API を追加しない。ADR 0018 決定 8）。残差関数は #169 の式 ID と 1:1 で
# 対応させ、モデル 1 期実行の中間値との一致をテストで統制する（`Z-15`・§12.5-48）。
#
# 正本:
#   docs/architecture/capex_credit_cycle_empirical_integration.md §5.6・§6・§8.4–§8.6・§11
#   docs/models/capex_credit_cycle_empirical_strategy.md §7–§8・§10・§15
#   docs/adr/0012-capex-credit-cycle-empirical-contract.md 決定 12–24
#   docs/adr/0018-capex-credit-cycle-empirical-runtime-contract.md 決定 8・9・16

const CAPEX_CC_ESTIMATION_VERSION = "capex-credit-cycle-estimation/1.0.0"

# 推定ステータス語彙（実証統合設計 §5.6・§6.2）。6 値目を追加しない。
const CAPEX_CC_ESTIMATION_STATUSES =
    (:converged, :boundary_solution, :not_converged, :invalid_objective, :demoted)

# parameter set の由来（実証統合設計 §5.6 契約 7）。literature/default と estimated/calibrated
# を同一 artifact 内で別フィールドに保持し、由来不明の混在を作らない。
const CAPEX_CC_PARAMETER_SET_KINDS = (:literature_default, :calibrated, :estimated)

# ---------------------------------------------------------------------------
# EST パラメータの bounds / 符号制約（モデル層の契約と共有。[動学方程式] §13.3・§13.4）
# ---------------------------------------------------------------------------

"""
    CAPEX_CC_EST_PARAM_BOUNDS :: Dict{Symbol, Tuple{Float64, Float64}}

35 個の `EST` パラメータの推定範囲（下限・上限）。[動学方程式](../models/capex_credit_cycle_equations.md)
§13.3 の範囲欄に対応する。**符号制約**は下限で表現する（`≥ 0` は下限 `0.0`、`> 0` は
下限 `1e-6`）。推定中はこの範囲外へ出さず、収束解が端に張り付いた場合は post-hoc クリップ
せず `:boundary_solution` として保持する（§12.5-47・ADR 0018 決定 8）。

上限は識別のための走査範囲であり普遍的な制約ではない（`SENS` 走査と直交。#170 §15.1）。
"""
const CAPEX_CC_EST_PARAM_BOUNDS = Dict{Symbol, Tuple{Float64, Float64}}(
    # --- EB-1 金融条件 ---
    :bh_fc_pol => (0.0, 5.0),          # 標準化単位/%pt, ≥ 0
    :bh_spread_cov => (0.0, 500.0),    # bp/倍^pow, ≥ 0
    :bh_spread_fc => (0.0, 300.0),     # bp/標準化単位, ≥ 0
    :bh_lend_spread => (0.0, 1.0),     # 標準化単位/bp, ≥ 0
    # --- EB-3 生産・在庫・受注残 ---
    :bh_inv_adj_s2 => (0.0, 1.0),      # 比率/四半期, [0, 1]
    :bh_inv_adj_s3 => (0.0, 1.0),
    :bh_prod_cut_s2 => (0.0, 10.0),    # 比率/比率, ≥ 0
    :bh_prod_cut_s3 => (0.0, 10.0),
    # --- EB-4 価格 ---
    :bh_price_adj_s2 => (1e-6, 1.0),   # 比率/四半期, (0, 1]
    :bh_price_adj_s3 => (1e-6, 1.0),
    :bh_price_sens_s2 => (0.0, 5.0),   # 指数, ≥ 0
    :bh_price_sens_s3 => (0.0, 5.0),
    # --- EB-6 雇用・賃金 ---
    :bh_emp_up_s1 => (1e-6, 1.0),      # 比率/四半期, (0, 1]
    :bh_emp_up_s2 => (1e-6, 1.0),
    :bh_emp_up_s3 => (1e-6, 1.0),
    :bh_emp_up_s5 => (1e-6, 1.0),
    :bh_emp_down_s1 => (1e-6, 1.0),    # (0, bh_emp_up]（許容条件 9 で強制）
    :bh_emp_down_s2 => (1e-6, 1.0),
    :bh_emp_down_s3 => (1e-6, 1.0),
    :bh_emp_down_s5 => (1e-6, 1.0),
    :bh_wage_slope => (0.0, 10.0),     # 指数単位/比率, ≥ 0
    # --- EB-7 消費 ---
    :bh_mpc => (1e-6, 1.0 - 1e-6),     # 比率, (0, 1)（許容条件 10）
    :bh_cons_adj => (1e-6, 1.0),       # 比率/四半期, (0, 1]
    # --- EB-5 CAPEX・投資 ---
    :bh_alpha_capex_s1 => (1e-6, 1.0), # 比率/四半期, (0, 1]
    :bh_cc_elas_s1 => (0.0, 20.0),     # 1/%pt, ≥ 0
    :bh_alpha_inv_s2 => (1e-6, 1.0),
    :bh_alpha_inv_s3 => (1e-6, 1.0),
    :bh_cc_elas_inv_s2 => (0.0, 20.0),
    :bh_cc_elas_inv_s3 => (0.0, 20.0),
    :bh_lend_elas_inv_s2 => (0.0, 20.0),
    :bh_lend_elas_inv_s3 => (0.0, 20.0),
    :bh_defer_roll => (0.0, 20.0),     # 比率/指数単位, ≥ 0
    # --- EB-2 資本コスト・評価・担保 ---
    :bh_ev_elas => (0.0, 20.0),        # 指数単位/比率, ≥ 0
    :bh_coll_elas => (0.0, 10.0),      # —, ≥ 0
    :bh_roll_slope => (0.0, 20.0),     # 指数単位/比率, ≥ 0
)

"""
    capex_est_param_bounds(name::Symbol) -> Tuple{Float64, Float64}

`name`（`EST` パラメータ）の推定範囲を返す。`EST` でないパラメータは `ArgumentError`。
"""
function capex_est_param_bounds(name::Symbol)
    haskey(CAPEX_CC_EST_PARAM_BOUNDS, name) ||
        throw(ArgumentError("$(name) は EST パラメータではありません（bounds 未定義）"))
    return CAPEX_CC_EST_PARAM_BOUNDS[name]
end

# ---------------------------------------------------------------------------
# 決定的な擬似乱数（multi-start の初期値摂動。RNG 依存を増やさない自前 LCG）
# ---------------------------------------------------------------------------

mutable struct _CCCEstLCG
    state::UInt64
end

_ccc_est_lcg(seed::Integer) = _CCCEstLCG(UInt64(seed) ⊻ 0x9e3779b97f4a7c15 | 0x1)

function _ccc_est_rand(g::_CCCEstLCG)
    g.state = g.state * 0x5deece66d + 0xb
    return Float64(g.state >> 11) / 9007199254740992.0
end

# ---------------------------------------------------------------------------
# 推定設定（estimation config version。`W2` / `W3` の閾値・objective・seed を持つ。
# ADR 0018 §7・§8.6 の契約）
# ---------------------------------------------------------------------------

"""
    CapexEstimationConfig

ブロック別限定推定の再現可能な設定。`W2` / `W3` の**発火しきい値**はここに固定し、推定結果を
見て変えない（§8.6・ADR 0018 決定 9）。閾値を変更する場合は `version` を上げ、変更前後の
結果を両方保存する。

- `optimizer` / `weight_mode`: 本 version は `:nelder_mead` / (`:std_normalize` または `:none`)。
- `max_iterations` / `tol` / `n_starts` / `seed` / `start_perturbation`: multi-start optimizer。
- `boundary_atol`: bounds への張り付き判定（`:boundary_solution`）。
- `curvature_step`: objective 曲率の前進差分幅（分散推定ではない。#170 §8.3-1）。
- `weak_curvature_tol`: 曲率がこれ未満なら弱識別（`W2` 発火の一条件）。
- `range_grid` / `range_rel_tol`: `W2` 範囲報告のグリッド点数と等値域の相対許容差。
- `holdout_frac`: 標本末尾のこの割合を objective から除外し out-of-sample 区間として確保する
  （#170 §10.1。既定 0 で全期 in-sample）。
- `standard_errors_supported`: 常に `false`（objective 曲率は分散推定ではない）。
"""
struct CapexEstimationConfig
    version::String
    optimizer::Symbol
    weight_mode::Symbol
    max_iterations::Int
    tol::Float64
    n_starts::Int
    seed::Int
    start_perturbation::Float64
    boundary_atol::Float64
    curvature_step::Float64
    weak_curvature_tol::Float64
    range_grid::Int
    range_rel_tol::Float64
    holdout_frac::Float64
    initial_overrides::Dict{Symbol, Float64}
    standard_errors_supported::Bool
end

function CapexEstimationConfig(;
    optimizer::Symbol = :nelder_mead,
    weight_mode::Symbol = :std_normalize,
    max_iterations::Int = 2000,
    tol::Float64 = 1e-12,
    n_starts::Int = 5,
    seed::Int = 20260901,
    start_perturbation::Float64 = 0.5,
    boundary_atol::Float64 = 1e-6,
    curvature_step::Float64 = 1e-3,
    weak_curvature_tol::Float64 = 1e-8,
    range_grid::Int = 41,
    range_rel_tol::Float64 = 0.10,
    holdout_frac::Float64 = 0.0,
    initial_overrides::Dict{Symbol, Float64} = Dict{Symbol, Float64}(),
    standard_errors_supported::Bool = false,
    version::String = CAPEX_CC_ESTIMATION_VERSION,
)
    optimizer === :nelder_mead ||
        throw(ArgumentError("本 version の optimizer は :nelder_mead のみです"))
    weight_mode in (:std_normalize, :none) ||
        throw(ArgumentError("weight_mode は :std_normalize / :none のいずれかです"))
    max_iterations >= 1 ||
        throw(ArgumentError("max_iterations は 1 以上でなければなりません"))
    n_starts >= 1 || throw(ArgumentError("n_starts は 1 以上でなければなりません"))
    (0 < tol < 1) || throw(ArgumentError("tol は (0, 1) の範囲でなければなりません"))
    (0 < curvature_step < 1) ||
        throw(ArgumentError("curvature_step は (0, 1) の範囲でなければなりません"))
    weak_curvature_tol >= 0 ||
        throw(ArgumentError("weak_curvature_tol は 0 以上でなければなりません"))
    range_grid >= 3 || throw(ArgumentError("range_grid は 3 以上でなければなりません"))
    (0 < range_rel_tol < 1) ||
        throw(ArgumentError("range_rel_tol は (0, 1) の範囲でなければなりません"))
    (0 <= holdout_frac < 1) ||
        throw(ArgumentError("holdout_frac は [0, 1) の範囲でなければなりません"))
    standard_errors_supported &&
        throw(ArgumentError("standard_errors_supported は本 version では常に false です"))
    # initial_overrides は EST で bounds 内でなければならない（invalid initial value を拒否）
    for (p, v) in initial_overrides
        haskey(CAPEX_CC_EST_PARAM_BOUNDS, p) || throw(
            ArgumentError(
                "initial_overrides のキー $(p) は EST パラメータではありません（§12.5-46）",
            ),
        )
        lo, hi = CAPEX_CC_EST_PARAM_BOUNDS[p]
        isfinite(v) || throw(ArgumentError("initial_overrides[$(p)] が非有限です"))
        (lo <= v <= hi) || throw(
            ArgumentError(
                "initial_overrides[$(p)]=$(v) が bounds [$(lo), $(hi)] の外です（不正な初期値）",
            ),
        )
    end
    return CapexEstimationConfig(
        version,
        optimizer,
        weight_mode,
        max_iterations,
        tol,
        n_starts,
        seed,
        start_perturbation,
        boundary_atol,
        curvature_step,
        weak_curvature_tol,
        range_grid,
        range_rel_tol,
        holdout_frac,
        copy(initial_overrides),
        standard_errors_supported,
    )
end

# ---------------------------------------------------------------------------
# 方程式別残差関数（#169 の式 ID と 1:1。`Z-15`）
#
# すべて「右辺を観測値で評価して予測した左辺の値」を返す純関数。`cur` / `lag` / `lag3` は
# モデル変数名 => 値の Dict、`p` は 6 区分をマージしたパラメータ Dict/NamedTuple。
# モデル 1 期実行の中間値との一致は test/test_capex_credit_cycle_estimation.jl で統制する
# （§12.5-48）。**モデル層の内部関数を呼ばない**（二重実装をテストで縛る。ADR 0018 決定 8）。
# ---------------------------------------------------------------------------

_ccc_getp(p, k::Symbol) = p isa AbstractDict ? p[k] : getproperty(p, k)

# E5-01: fin_cond = (1−bh_fc_adj)·fin_cond[t−1] + bh_fc_adj·bh_fc_pol·(policy_rate − st_pol_ref)
function _ccc_resid_E5_01(cur, lag, p)
    fadj = _ccc_getp(p, :bh_fc_adj)
    return (1 - fadj) * lag[:fin_cond] +
           fadj * _ccc_getp(p, :bh_fc_pol) * (cur[:policy_rate] - _ccc_getp(p, :st_pol_ref))
end

# E5-02: equity_val = max(st_ev_min, (1−bh_ev_adj)·equity_val[t−1]
#                     + bh_ev_adj·(1 + bh_ev_elas·(Σ profit_s[t−1] / st_profit_ref − 1)))
function _ccc_resid_E5_02(cur, lag, p)
    eadj = _ccc_getp(p, :bh_ev_adj)
    prof = lag[:profit_s1] + lag[:profit_s2] + lag[:profit_s3]
    raw =
        (1 - eadj) * lag[:equity_val] +
        eadj * (1 + _ccc_getp(p, :bh_ev_elas) * (prof / _ccc_getp(p, :st_profit_ref) - 1))
    return max(raw, _ccc_getp(p, :st_ev_min))
end

# E5-03: collateral = st_coll_ltv · (Σ_{SF}(cap_s[t−1]+capex_pipe_s[t−1]) + Σ_{SP} invval_s[t−1])
#                    · equity_val^{bh_coll_elas}
# invval_s[t−1] = price_s[t−1]·inv_s[t−1]（E12-05 の再構成）。
function _ccc_resid_E5_03(cur, lag, p)
    physical =
        (lag[:cap_s1] + lag[:capex_pipe_s1]) +
        (lag[:cap_s2] + lag[:capex_pipe_s2]) +
        (lag[:cap_s3] + lag[:capex_pipe_s3])
    invval = lag[:price_s2] * lag[:inv_s2] + lag[:price_s3] * lag[:inv_s3]
    return _ccc_getp(p, :st_coll_ltv) *
           (physical + invval) *
           cur[:equity_val]^_ccc_getp(p, :bh_coll_elas)
end

# E5-04: spread_endo = st_spread0
#      + bh_spread_cov·max(0, bh_cov_threshold − coverage_agg[t−1])^{bh_spread_pow}
#      + bh_spread_fc·fin_cond[t−1]
# coverage_agg[t−1] が NaN のとき閾値項を 0 として評価する（§5.5・§15.4 の契約）。
function _ccc_resid_E5_04(cur, lag, p)
    cov = lag[:coverage_agg]
    thr =
        (ismissing(cov) || isnan(cov)) ? 0.0 :
        _ccc_getp(p, :bh_spread_cov) *
        max(0.0, _ccc_getp(p, :bh_cov_threshold) - cov)^_ccc_getp(p, :bh_spread_pow)
    return _ccc_getp(p, :st_spread0) + thr + _ccc_getp(p, :bh_spread_fc) * lag[:fin_cond]
end

# E5-06: lend_stance = − bh_lend_spread · (spread[t−1] − st_spread0)
_ccc_resid_E5_06(cur, lag, p) =
    -_ccc_getp(p, :bh_lend_spread) * (lag[:spread] - _ccc_getp(p, :st_spread0))

# E5-07: rollover = clamp(1 − bh_roll_slope·max(0, Σ_{SF} debt_s[t−1]/collateral − pl_ltv), 0, 1)
# collateral は当期値（E5-03 の出力）。
function _ccc_resid_E5_07(cur, lag, p)
    debt = lag[:debt_s1] + lag[:debt_s2] + lag[:debt_s3]
    coll = cur[:collateral]
    (ismissing(coll) || isnan(coll) || coll <= 0) && return NaN
    raw = 1 - _ccc_getp(p, :bh_roll_slope) * max(0.0, debt / coll - _ccc_getp(p, :pl_ltv))
    return clamp(raw, 0.0, 1.0)
end

# E9-15/E9-16 合成: price_s = max(st_price_min_s,
#   price_s[t−1] + bh_price_adj_s·(price_tgt_s − price_s[t−1]))
# price_tgt_s = 1 + bh_price_sens_s·tanh((util_s[t−1] − bh_util_tgt_s)/bh_price_scale_s)
function _ccc_resid_E9_16(cur, lag, p, s::AbstractString)
    util_tgt = _ccc_getp(p, Symbol("bh_util_tgt_$s"))
    scale = _ccc_getp(p, Symbol("bh_price_scale_$s"))
    sens = _ccc_getp(p, Symbol("bh_price_sens_$s"))
    ptgt = 1 + sens * tanh((lag[Symbol("util_$s")] - util_tgt) / scale)
    plag = lag[Symbol("price_$s")]
    raw = plag + _ccc_getp(p, Symbol("bh_price_adj_$s")) * (ptgt - plag)
    return max(raw, _ccc_getp(p, Symbol("st_price_min_$s")))
end

# E9-06/E9-07 合成（制約非拘束時）: y_s = max(0, y_norm_s − y_cut_s)
#   y_norm_s = ship_desired_s + bh_inv_adj_s·(bh_inv_target_s·ship_desired_s − inv_s[t−1])
#   y_cut_s  = bh_prod_cut_s·max(0, inv_ratio_s[t−1] − bh_inv_thresh_s)·ship_desired_s
# 観測駆動では ship_desired_s ≈ ship_s（供給制約非拘束時）、
# inv_ratio_s[t−1] = inv_s[t−1]/y_s[t−1]。
function _ccc_resid_E9_06_07(ship_des, inv_lag1, inv_ratio_lag1, p, s::AbstractString)
    inv_adj = _ccc_getp(p, Symbol("bh_inv_adj_$s"))
    inv_tgt = _ccc_getp(p, Symbol("bh_inv_target_$s"))
    prod_cut = _ccc_getp(p, Symbol("bh_prod_cut_$s"))
    inv_thresh = _ccc_getp(p, Symbol("bh_inv_thresh_$s"))
    y_norm = ship_des + inv_adj * (inv_tgt * ship_des - inv_lag1)
    y_cut =
        (ismissing(inv_ratio_lag1) || isnan(inv_ratio_lag1)) ? 0.0 :
        prod_cut * max(0.0, inv_ratio_lag1 - inv_thresh) * ship_des
    return max(0.0, y_norm - y_cut)
end

# E10-09: wage = max(st_wage_min, wage[t−1] + bh_wage_slope·(emp_tot[t−3]/st_emp_ref − 1))
function _ccc_resid_E10_09(cur, lag, lag3, p)
    raw =
        lag[:wage] +
        _ccc_getp(p, :bh_wage_slope) * (lag3[:emp_tot] / _ccc_getp(p, :st_emp_ref) - 1)
    return max(raw, _ccc_getp(p, :st_wage_min))
end

# E10-06: emp_s = max(0, emp_s[t−1] + λ_s·gap_emp_s)
#   gap_emp_s = emp_req_s − emp_s[t−1]
#   λ_s = 0                if |gap| ≤ bh_emp_band_s·emp_s[t−1]
#         bh_emp_up_s      if gap > 0
#         bh_emp_down_s    if gap < 0
function _ccc_resid_E10_06(emp_lag1, emp_req, p, s::AbstractString)
    gap = emp_req - emp_lag1
    band = _ccc_getp(p, Symbol("bh_emp_band_$s"))
    lambda = if abs(gap) <= band * emp_lag1
        0.0
    elseif gap > 0
        _ccc_getp(p, Symbol("bh_emp_up_$s"))
    else
        _ccc_getp(p, Symbol("bh_emp_down_$s"))
    end
    return max(0.0, emp_lag1 + lambda * gap)
end

# E10-13: cons = max(0, cons[t−1] + bh_cons_adj·(bh_mpc·hh_income + st_cons_auto − cons[t−1]))
function _ccc_resid_E10_13(cur, lag, p)
    raw =
        lag[:cons] +
        _ccc_getp(p, :bh_cons_adj) *
        (_ccc_getp(p, :bh_mpc) * cur[:hh_income] + _ccc_getp(p, :st_cons_auto) - lag[:cons])
    return max(raw, 0.0)
end

"""
    capex_equation_residual(id::AbstractString, cur, lag, p; lag3 = nothing, sector = nothing)
        -> Float64

式 ID（`"E5-01"` 等）の**右辺を観測値で評価した左辺の予測値**を返す。`cur` / `lag` / `lag3`
はモデル変数名 => 値の Dict、`p` はパラメータ。二重実装統制テスト（§12.5-48）が、この関数の
出力とモデル 1 期実行の中間値の一致を検査する。
"""
function capex_equation_residual(
    id::AbstractString,
    cur,
    lag,
    p;
    lag3 = nothing,
    sector::Union{AbstractString, Nothing} = nothing,
)
    id == "E5-01" && return _ccc_resid_E5_01(cur, lag, p)
    id == "E5-02" && return _ccc_resid_E5_02(cur, lag, p)
    id == "E5-03" && return _ccc_resid_E5_03(cur, lag, p)
    id == "E5-04" && return _ccc_resid_E5_04(cur, lag, p)
    id == "E5-06" && return _ccc_resid_E5_06(cur, lag, p)
    id == "E5-07" && return _ccc_resid_E5_07(cur, lag, p)
    if id == "E9-16"
        sector === nothing && throw(ArgumentError("E9-16 は sector 引数が必要です"))
        return _ccc_resid_E9_16(cur, lag, p, sector)
    end
    if id == "E10-09"
        lag3 === nothing && throw(ArgumentError("E10-09 は lag3 引数が必要です"))
        return _ccc_resid_E10_09(cur, lag, lag3, p)
    end
    id == "E10-13" && return _ccc_resid_E10_13(cur, lag, p)
    throw(ArgumentError("式 ID $(id) の残差関数は未実装です（EB の point 推定対象外）"))
end

# ---------------------------------------------------------------------------
# 観測フレームの構築（モデル変数を dataset から解決し、時系列の隣接ペア/三つ組を作る）
# ---------------------------------------------------------------------------

# 数値ヘルパ（Statistics に依存しない）
_ccc_est_mean(xs) = isempty(xs) ? 0.0 : sum(xs) / length(xs)
function _ccc_est_std(xs)
    length(xs) < 2 && return 0.0
    m = _ccc_est_mean(xs)
    return sqrt(sum((x - m)^2 for x in xs) / length(xs))
end

# dataset からモデル変数群を解決する。返り値: Dict{Symbol, Vector{Union{Float64, Missing}}}
function _ccc_est_resolve_vars(ds::CapexEmpiricalDataset, mvars)
    out = Dict{Symbol, Vector{Union{Float64, Missing}}}()
    for mv in mvars
        out[mv] = _ccc_id_resolve(ds, mv).series
    end
    return out
end

_ccc_finite(v) = !ismissing(v) && isfinite(v)

# in-sample / holdout 分割（末尾 holdout_frac を objective から除外）
function _ccc_est_sample_split(n::Int, cfg::CapexEstimationConfig)
    n_hold = floor(Int, n * cfg.holdout_frac)
    n_in = n - n_hold
    return (1:n_in, (n_in + 1):n)
end

# ---------------------------------------------------------------------------
# 一般化された objective（方程式別残差の重み付き二乗和）
# ---------------------------------------------------------------------------

# 1 つの方程式の残差ベクトル生成器を保持する。
#   frames: (θ::Dict) -> Vector{Float64}（各期の (obs − pred)）。θ 非依存部分は事前計算する。
struct _CCCEqSpec
    id::String
    params::Vector{Symbol}                 # この式が識別する EST パラメータ
    obs_std::Float64                       # 観測 LHS の標準偏差（:std_normalize 用）
    n_pairs::Int
    residual::Function                     # (θ::Dict{Symbol,Float64}) -> Vector{Float64}
end

function _ccc_weight(spec::_CCCEqSpec, cfg::CapexEstimationConfig)
    cfg.weight_mode === :none && return 1.0
    return spec.obs_std > 0 ? 1.0 / spec.obs_std : 1.0
end

# objective 総値: Σ_eq w_eq^2 · Σ_t r_t^2（θ は EST パラメータ Dict、pfix は固定パラメータ Dict）
function _ccc_block_objective(
    specs::Vector{_CCCEqSpec},
    θ::Dict{Symbol, Float64},
    pfix::Dict{Symbol, Float64},
    cfg::CapexEstimationConfig,
)
    merged = merge(pfix, θ)
    total = 0.0
    contrib = Dict{String, Float64}()
    for spec in specs
        w = _ccc_weight(spec, cfg)
        rs = spec.residual(merged)
        s = 0.0
        for r in rs
            (isfinite(r)) || return (total = Inf, contributions = contrib)
            s += (r * w)^2
        end
        contrib[spec.id] = s
        total += s
    end
    return (total = total, contributions = contrib)
end

# ---------------------------------------------------------------------------
# ブロック別の式仕様の構築
# ---------------------------------------------------------------------------

# 与えられた式仕様の一覧を、point 推定対象パラメータ集合とともに返す。
# 観測系列が揃わず式を構成できない場合はその式を落とし、理由を excluded に積む。
struct _CCCBlockPlan
    specs::Vector{_CCCEqSpec}
    point_params::Vector{Symbol}            # 実際に点推定する EST パラメータ
    armed::Dict{Symbol, Symbol}            # 事前固定された W2/W3（識別診断由来）
    pre_applied::Dict{Symbol, Symbol}      # 事前適用された W1/W4（識別診断由来）
    demote_extra::Dict{Symbol, Symbol}    # 観測不足で追加降格した EST（param => :W4）
    excluded::Vector{String}
    pfix::Dict{Symbol, Float64}
end

# 較正モデルのパラメータ + literature default をマージした固定パラメータ Dict。
function _ccc_est_fixed_params(cal::CapexEmpiricalCalibration)
    pfix = Dict{Symbol, Float64}()
    for (k, v) in pairs(parameters(cal.model))
        pfix[k] = Float64(v)
    end
    # literature default（`Z-17`: 出所は default_unattributed）で欠けを補う
    for (k, v) in pairs(_ccc_default_behavioral())
        haskey(pfix, k) || (pfix[k] = Float64(v))
    end
    return pfix
end

# EB-1: E5-01（bh_fc_pol）・E5-06（bh_lend_spread）・E5-04（bh_spread_fc / bh_spread_cov[W2]）
function _ccc_plan_EB1(
    ds::CapexEmpiricalDataset,
    diag::CapexIdentificationDiagnostic,
    cfg::CapexEstimationConfig,
    pfix::Dict{Symbol, Float64},
)
    n = length(ds.dates)
    in_idx, _ = _ccc_est_sample_split(n, cfg)
    V = _ccc_est_resolve_vars(
        ds,
        (:fin_cond, :policy_rate, :spread, :lend_stance, :coverage_agg),
    )
    specs = _CCCEqSpec[]
    excluded = String[]
    point = Symbol[]

    # E5-01
    idx501 = [
        k for k in in_idx if k >= 2 &&
            _ccc_finite(V[:fin_cond][k]) &&
            _ccc_finite(V[:fin_cond][k - 1]) &&
            _ccc_finite(V[:policy_rate][k])
    ]
    if length(idx501) >= 4
        obs = Float64[V[:fin_cond][k] for k in idx501]
        push!(
            specs,
            _CCCEqSpec(
                "E5-01",
                [:bh_fc_pol],
                _ccc_est_std(obs),
                length(idx501),
                θ -> Float64[
                    V[:fin_cond][k] - _ccc_resid_E5_01(
                        Dict(:policy_rate => Float64(V[:policy_rate][k])),
                        Dict(:fin_cond => Float64(V[:fin_cond][k - 1])),
                        θ,
                    ) for k in idx501
                ],
            ),
        )
        push!(point, :bh_fc_pol)
    else
        push!(excluded, "E5-01: 有効ペア $(length(idx501)) < 4（bh_fc_pol は W4 へ）")
    end

    # E5-06
    idx506 = [
        k for k in in_idx if
        k >= 2 && _ccc_finite(V[:lend_stance][k]) && _ccc_finite(V[:spread][k - 1])
    ]
    if length(idx506) >= 4
        obs = Float64[V[:lend_stance][k] for k in idx506]
        push!(
            specs,
            _CCCEqSpec(
                "E5-06",
                [:bh_lend_spread],
                _ccc_est_std(obs),
                length(idx506),
                θ -> Float64[
                    V[:lend_stance][k] - _ccc_resid_E5_06(
                        Dict{Symbol, Float64}(),
                        Dict(:spread => Float64(V[:spread][k - 1])),
                        θ,
                    ) for k in idx506
                ],
            ),
        )
        push!(point, :bh_lend_spread)
    else
        push!(excluded, "E5-06: 有効ペア $(length(idx506)) < 4（bh_lend_spread は W4 へ）")
    end

    # E5-04（observed LHS は spread を spread_endo の proxy として用いる）
    idx504 = [
        k for k in in_idx if
        k >= 2 && _ccc_finite(V[:spread][k]) && _ccc_finite(V[:fin_cond][k - 1])
    ]
    if length(idx504) >= 4
        obs = Float64[V[:spread][k] for k in idx504]
        push!(
            specs,
            _CCCEqSpec(
                "E5-04",
                [:bh_spread_fc, :bh_spread_cov],
                _ccc_est_std(obs),
                length(idx504),
                θ -> Float64[
                    V[:spread][k] - _ccc_resid_E5_04(
                        Dict{Symbol, Float64}(),
                        Dict(
                            :coverage_agg =>
                                _ccc_finite(V[:coverage_agg][k - 1]) ?
                                Float64(V[:coverage_agg][k - 1]) : NaN,
                            :fin_cond => Float64(V[:fin_cond][k - 1]),
                        ),
                        θ,
                    ) for k in idx504
                ],
            ),
        )
        push!(point, :bh_spread_fc)
    else
        push!(excluded, "E5-04: 有効ペア $(length(idx504)) < 4（bh_spread_fc は W4 へ）")
    end

    return specs, point, excluded
end

# EB-3: E9-06/E9-07 合成（部門 s2・s3。y_s は在庫恒等式 y_s = inv_s − inv_s[t−1] + ship_s で再構成）
function _ccc_plan_EB3(
    ds::CapexEmpiricalDataset,
    diag::CapexIdentificationDiagnostic,
    cfg::CapexEstimationConfig,
    pfix::Dict{Symbol, Float64},
)
    n = length(ds.dates)
    in_idx, _ = _ccc_est_sample_split(n, cfg)
    V = _ccc_est_resolve_vars(ds, (:inv_s2, :inv_s3, :ship_s2, :ship_s3))
    specs = _CCCEqSpec[]
    excluded = String[]
    point = Symbol[]
    eps = 1e-8

    for s in ("s2", "s3")
        inv = V[Symbol("inv_$s")]
        ship = V[Symbol("ship_$s")]
        idxs = [
            k for k in in_idx if k >= 3 &&
                _ccc_finite(inv[k]) &&
                _ccc_finite(inv[k - 1]) &&
                _ccc_finite(inv[k - 2]) &&
                _ccc_finite(ship[k]) &&
                _ccc_finite(ship[k - 1])
        ]
        # y[t] と y[t−1] を再構成し、y[t−1] > eps の期のみ有効
        usable = Int[]
        y_obs = Dict{Int, Float64}()
        yr_lag = Dict{Int, Float64}()
        for k in idxs
            yk = Float64(inv[k]) - Float64(inv[k - 1]) + Float64(ship[k])
            ykm1 = Float64(inv[k - 1]) - Float64(inv[k - 2]) + Float64(ship[k - 1])
            (isfinite(yk) && isfinite(ykm1) && ykm1 > eps) || continue
            push!(usable, k)
            y_obs[k] = yk
            yr_lag[k] = Float64(inv[k - 1]) / ykm1
        end
        if length(usable) >= 4
            obs = Float64[y_obs[k] for k in usable]
            ps = [Symbol("bh_inv_adj_$s"), Symbol("bh_prod_cut_$s")]
            push!(
                specs,
                _CCCEqSpec(
                    "E9-06/07:$s",
                    ps,
                    _ccc_est_std(obs),
                    length(usable),
                    θ -> Float64[
                        y_obs[k] - _ccc_resid_E9_06_07(
                            Float64(ship[k]),
                            Float64(inv[k - 1]),
                            yr_lag[k],
                            θ,
                            s,
                        ) for k in usable
                    ],
                ),
            )
            append!(point, ps)
        else
            push!(
                excluded,
                "E9-06/07:$(s): 有効ペア $(length(usable)) < 4（bh_inv_adj_$(s)・bh_prod_cut_$(s) は W4 へ）",
            )
        end
    end
    return specs, point, excluded
end

# EB-6: E10-09（bh_wage_slope）のみ点推定。E10-06 の emp_req_s は部門産出・（S3 は）CAPEX 活動
# 系列を要し EB-6 の required 集合の外であるため、8 個の emp パラメータは W4（事前適用・感応度のみ）
# へ降格する（§7.4-1・§8.6）。
function _ccc_plan_EB6(
    ds::CapexEmpiricalDataset,
    diag::CapexIdentificationDiagnostic,
    cfg::CapexEstimationConfig,
    pfix::Dict{Symbol, Float64},
)
    n = length(ds.dates)
    in_idx, _ = _ccc_est_sample_split(n, cfg)
    V = _ccc_est_resolve_vars(ds, (:wage, :emp_tot))
    specs = _CCCEqSpec[]
    excluded = String[]
    point = Symbol[]

    idxs = [
        k for k in in_idx if k >= 4 &&
            _ccc_finite(V[:wage][k]) &&
            _ccc_finite(V[:wage][k - 1]) &&
            _ccc_finite(V[:emp_tot][k - 3])
    ]
    if length(idxs) >= 4
        obs = Float64[V[:wage][k] for k in idxs]
        push!(
            specs,
            _CCCEqSpec(
                "E10-09",
                [:bh_wage_slope],
                _ccc_est_std(obs),
                length(idxs),
                θ -> Float64[
                    V[:wage][k] - _ccc_resid_E10_09(
                        Dict{Symbol, Float64}(),
                        Dict(:wage => Float64(V[:wage][k - 1])),
                        Dict(:emp_tot => Float64(V[:emp_tot][k - 3])),
                        θ,
                    ) for k in idxs
                ],
            ),
        )
        push!(point, :bh_wage_slope)
    else
        push!(excluded, "E10-09: 有効三つ組 $(length(idxs)) < 4（bh_wage_slope は W4 へ）")
    end
    return specs, point, excluded
end

# EB-4: E9-15/E9-16 合成（部門 s2・s3）。util_s は proxy 観測だが、範囲報告のための objective は
# 構成できる。診断が全候補を W2 armed するため点推定は返さず、W2 範囲報告に用いる。
function _ccc_plan_EB4(
    ds::CapexEmpiricalDataset,
    diag::CapexIdentificationDiagnostic,
    cfg::CapexEstimationConfig,
    pfix::Dict{Symbol, Float64},
)
    n = length(ds.dates)
    in_idx, _ = _ccc_est_sample_split(n, cfg)
    V = _ccc_est_resolve_vars(ds, (:price_s2, :price_s3, :util_s2, :util_s3))
    specs = _CCCEqSpec[]
    excluded = String[]
    for s in ("s2", "s3")
        price = V[Symbol("price_$s")]
        util = V[Symbol("util_$s")]
        idxs = [
            k for k in in_idx if k >= 2 &&
                _ccc_finite(price[k]) &&
                _ccc_finite(price[k - 1]) &&
                _ccc_finite(util[k - 1])
        ]
        if length(idxs) >= 4
            obs = Float64[price[k] for k in idxs]
            ps = [Symbol("bh_price_adj_$s"), Symbol("bh_price_sens_$s")]
            push!(
                specs,
                _CCCEqSpec(
                    "E9-15/16:$s",
                    ps,
                    _ccc_est_std(obs),
                    length(idxs),
                    θ -> Float64[
                        price[k] - _ccc_resid_E9_16(
                            Dict{Symbol, Float64}(),
                            Dict(
                                Symbol("price_$s") => Float64(price[k - 1]),
                                Symbol("util_$s") => Float64(util[k - 1]),
                            ),
                            θ,
                            s,
                        ) for k in idxs
                    ],
                ),
            )
        else
            push!(excluded, "E9-15/16:$s: 有効ペア $(length(idxs)) < 4")
        end
    end
    return specs, Symbol[], excluded
end

# EB-7: E10-13（cons・hh_income は proxy）。診断が全候補を W2 armed するため範囲報告に用いる。
function _ccc_plan_EB7(
    ds::CapexEmpiricalDataset,
    diag::CapexIdentificationDiagnostic,
    cfg::CapexEstimationConfig,
    pfix::Dict{Symbol, Float64},
)
    n = length(ds.dates)
    in_idx, _ = _ccc_est_sample_split(n, cfg)
    V = _ccc_est_resolve_vars(ds, (:cons, :hh_income))
    specs = _CCCEqSpec[]
    excluded = String[]
    idxs = [
        k for k in in_idx if k >= 2 &&
            _ccc_finite(V[:cons][k]) &&
            _ccc_finite(V[:cons][k - 1]) &&
            _ccc_finite(V[:hh_income][k])
    ]
    if length(idxs) >= 4
        obs = Float64[V[:cons][k] for k in idxs]
        push!(
            specs,
            _CCCEqSpec(
                "E10-13",
                [:bh_mpc, :bh_cons_adj],
                _ccc_est_std(obs),
                length(idxs),
                θ -> Float64[
                    V[:cons][k] - _ccc_resid_E10_13(
                        Dict(:hh_income => Float64(V[:hh_income][k])),
                        Dict(:cons => Float64(V[:cons][k - 1])),
                        θ,
                    ) for k in idxs
                ],
            ),
        )
    else
        push!(excluded, "E10-13: 有効ペア $(length(idxs)) < 4")
    end
    return specs, Symbol[], excluded
end

# EB-2・EB-5: 観測 LHS が潜在（collateral・cost_capital_s・target_cap_s1・cancel_s1）であるため
# objective を構成できない。全候補を W2/W3 で降格し、範囲は bounds を報告する（§8.3 W2）。
function _ccc_plan_latent_only(
    ds::CapexEmpiricalDataset,
    diag::CapexIdentificationDiagnostic,
    cfg::CapexEstimationConfig,
    pfix::Dict{Symbol, Float64},
)
    return _CCCEqSpec[],
    Symbol[],
    String["観測 LHS が潜在（E 分類）であるため方程式別 objective を構成できない（§8.2 ID-1・ID-2）"]
end

function _ccc_block_plan(
    block::CapexEstimationBlockSpec,
    ds::CapexEmpiricalDataset,
    cal::CapexEmpiricalCalibration,
    diag::CapexIdentificationDiagnostic,
    cfg::CapexEstimationConfig,
)::_CCCBlockPlan
    pfix = _ccc_est_fixed_params(cal)

    builder = if block.id === :EB1
        _ccc_plan_EB1
    elseif block.id === :EB3
        _ccc_plan_EB3
    elseif block.id === :EB6
        _ccc_plan_EB6
    elseif block.id === :EB4
        _ccc_plan_EB4
    elseif block.id === :EB7
        _ccc_plan_EB7
    else # :EB2 / :EB5
        _ccc_plan_latent_only
    end
    specs, point, excluded = builder(ds, cal_diag_bridge(ds, diag), cfg, pfix)

    # 識別診断由来の割当（事前適用 W1/W4・事前固定 W2/W3）
    pre_applied = copy(diag.applied_actions)
    armed = copy(diag.armed_actions)

    # armed パラメータは点推定しない（範囲報告へ回す。§5.6 契約 2）
    point = [p for p in point if !haskey(armed, p) && !haskey(pre_applied, p)]

    # 観測不足で式を構成できなかった EST を W4 へ追加降格
    demote_extra = Dict{Symbol, Symbol}()
    for p in diag.effective_est_params
        if !(p in point) && !haskey(armed, p) && !haskey(pre_applied, p)
            demote_extra[p] = :W4
        end
    end

    return _CCCBlockPlan(specs, point, armed, pre_applied, demote_extra, excluded, pfix)
end

# builder は識別診断だけを引数に取るシグネチャに合わせるためのブリッジ（将来 dataset 依存の
# 追加判定を入れる余地を残す）。現状は diag をそのまま返す。
cal_diag_bridge(::CapexEmpiricalDataset, diag::CapexIdentificationDiagnostic) = diag

# ---------------------------------------------------------------------------
# 結果型
# ---------------------------------------------------------------------------

"""
    CapexBlockEstimateStart

multi-start 1 試行の記録。
"""
struct CapexBlockEstimateStart
    index::Int
    initial::Dict{Symbol, Float64}
    estimated::Dict{Symbol, Float64}
    objective_value::Float64
    converged::Bool
    iterations::Int
end

"""
    CapexBlockEstimate

推定ブロック 1 個の限定推定結果（実証統合設計 §5.6）。

- `status ∈ CAPEX_CC_ESTIMATION_STATUSES`。
  - `:converged` / `:not_converged`: 点推定が（少なくとも 1 個）収束したか。
  - `:boundary_solution`: 収束解が bounds に張り付いた（post-hoc クリップしない）。
  - `:invalid_objective`: objective が非有限（NaN/Inf）。
  - `:demoted`: 点推定を 1 個も返さず、`W1`–`W4` へ全面降格した。
- `estimated`: 点推定値（`W` へ降格していない EST）。
- `ranges`: `W2` 範囲報告（`param => (lo, hi)`。objective の等値域。無ければ bounds）。
- `alternate_specs`: `W3` 複数仕様（`param => Dict(spec => value)`）。
- `demoted`: `param => :W1/:W2/:W3/:W4`（事前適用・事前固定・観測不足による追加降格の合算）。
- `objective_value` / `objective_contributions`: 採用解の総値と式別寄与。
- `literature_objective`: literature default での objective（比較用。§10 の分離報告）。
- `boundary_hits`: bounds に到達した点推定パラメータ。
- `admissibility_failures`: 許容条件 9・10 の違反（推定後検証。クリップしない）。
- `curvature`: 各点推定パラメータの objective 曲率（前進差分。**分散推定ではない**）。
- `standard_errors_supported`: 常に `false`（#170 §8.3-1）。
"""
struct CapexBlockEstimate
    block::Symbol
    order::Int
    status::Symbol
    equation_ids::Vector{String}
    estimated::Dict{Symbol, Float64}
    ranges::Dict{Symbol, Tuple{Float64, Float64}}
    alternate_specs::Dict{Symbol, Dict{String, Float64}}
    demoted::Dict{Symbol, Symbol}
    bounds::Dict{Symbol, Tuple{Float64, Float64}}
    initial_values::Dict{Symbol, Float64}
    objective_value::Float64
    objective_contributions::Dict{String, Float64}
    literature_objective::Float64
    boundary_hits::Vector{Symbol}
    admissibility_failures::Vector{String}
    curvature::Dict{Symbol, Float64}
    n_obs_used::Int
    n_obs_excluded::Int
    excluded_reasons::Vector{String}
    weights::Dict{String, Float64}
    converged::Bool
    iterations::Int
    adopted_start::Int
    starts::Vector{CapexBlockEstimateStart}
    standard_errors_supported::Bool
    identification_status::Symbol
    reasons::Vector{String}
    warnings::Vector{String}
    config::CapexEstimationConfig
    block_spec_hash::String
    metadata::Dict{String, Any}
end

# ---------------------------------------------------------------------------
# W2 範囲報告（objective の等値域をグリッドで走査。#170 §8.3 W2）
# ---------------------------------------------------------------------------

# 1 パラメータを bounds 内でグリッド走査し、objective ≤ min·(1 + range_rel_tol) の帯を返す。
# objective を構成できない（specs が空）場合は bounds をそのまま返す。
function _ccc_w2_range(
    param::Symbol,
    specs::Vector{_CCCEqSpec},
    base_θ::Dict{Symbol, Float64},
    pfix::Dict{Symbol, Float64},
    cfg::CapexEstimationConfig,
)
    lo, hi = CAPEX_CC_EST_PARAM_BOUNDS[param]
    relevant = [s for s in specs if param in s.params]
    isempty(relevant) && return (lo, hi)

    grid = range(lo, hi; length = cfg.range_grid)
    objs = Float64[]
    for g in grid
        θ = copy(base_θ)
        θ[param] = g
        o = _ccc_block_objective(relevant, θ, pfix, cfg)
        push!(objs, o.total)
    end
    finite = [o for o in objs if isfinite(o)]
    isempty(finite) && return (lo, hi)
    omin = minimum(finite)
    thresh = omin * (1 + cfg.range_rel_tol) + cfg.range_rel_tol * eps()
    in_band = [grid[i] for i in eachindex(grid) if isfinite(objs[i]) && objs[i] <= thresh]
    isempty(in_band) && return (lo, hi)
    return (Float64(minimum(in_band)), Float64(maximum(in_band)))
end

# W3: ai_exp の 3 仕様（定数 / compute_dem 逆算 / セクター株価）。観測が揃わない現段階では
# 各仕様の推定値を作れないため、literature default を 3 通り並置し、範囲を bounds で示す
# （#170 §8.2 ID-1・§8.3 W3。単一値を採らない）。
const _CCC_W3_AI_EXP_SPECS = ("ai_exp_constant", "ai_exp_compute_dem", "ai_exp_equity")

function _ccc_w3_alternate_specs(param::Symbol, pfix::Dict{Symbol, Float64})
    default = get(pfix, param, get(CAPEX_CC_EST_PARAM_BOUNDS, param, (0.0, 1.0))[1])
    return Dict{String, Float64}(spec => Float64(default) for spec in _CCC_W3_AI_EXP_SPECS)
end

# ---------------------------------------------------------------------------
# 推定本体（1 ブロック）
# ---------------------------------------------------------------------------

"""
    estimate_capex_block(block::Symbol, ds::CapexEmpiricalDataset,
                         cal::CapexEmpiricalCalibration,
                         diag::CapexIdentificationDiagnostic;
                         config::CapexEstimationConfig = CapexEstimationConfig())
        -> CapexBlockEstimate

`block`（`:EB1` … `:EB7`）の `EST` パラメータを、方程式別残差 objective で**限定的に**推定する。
**1 回につき 1 ブロック**（ブロック横断の同時最適化を公開 API として提供しない。ADR 0012 決定 12）。

契約（実証統合設計 §5.6・§8.5・§8.6）:

1. `diag.block === block` かつ `diag ∈ #245 の診断結果`。不一致は `ArgumentError`。
2. `diag.status ∈ (:not_identified, :insufficient_data)` の推定を**拒否**する（`ArgumentError`）。
3. `diag.status === :weakly_identified` は `armed_actions` の `W2`/`W3` へ降格し、その
   パラメータの点推定を返さない。armed でない候補は点推定しうる。
4. `FIX`/`CAL-SS`/`CAL-OBS`/`SCN`/`SENS` が `est_params` に混入していれば拒否（§12.5-46）。
5. bounds・符号制約・許容条件 9・10 を推定中／結果検証で強制し、**post-hoc クリップしない**
   （端に張り付いた場合は `:boundary_solution`）。
6. multi-start は決定的擬似乱数（`config.seed`）。同一 `ds`・`cal`・`config` で決定的。
7. `standard_errors_supported = false`。objective の曲率を分散推定と呼ばない。
"""
function estimate_capex_block(
    block::Symbol,
    ds::CapexEmpiricalDataset,
    cal::CapexEmpiricalCalibration,
    diag::CapexIdentificationDiagnostic;
    config::CapexEstimationConfig = CapexEstimationConfig(),
)::CapexBlockEstimate
    spec = capex_estimation_block(block)   # 未知 id は ArgumentError
    validate_capex_estimation_blocks([spec]; full = false)   # 区分・重複の二重防御（§12.5-46）

    diag.block === block || throw(
        ArgumentError(
            "diag.block（$(diag.block)）が要求ブロック（$(block)）と一致しません。#245 の診断結果を渡してください",
        ),
    )

    # 6 区分の三重防御（identification validator・block validator に加えて推定入口でも）
    for p in spec.est_params
        cls = get(cal.parameter_provenance, p, capex_parameter_class(p))
        cls === :EST || throw(
            ArgumentError(
                "$(block): est_param $(p) は $(cls) に分類されています。推定対象にできません（§12.5-46）",
            ),
        )
    end

    if diag.status in (:not_identified, :insufficient_data)
        throw(
            ArgumentError(
                "$(block) は識別診断で :$(diag.status) です。推定を拒否します（§12.5-43）。" *
                "理由: " *
                join(diag.reasons, "; "),
            ),
        )
    end

    plan = _ccc_block_plan(spec, ds, cal, diag, config)
    pfix = plan.pfix
    block_spec_hash = "sha256:" * sha256_hex_of_canonical(_ccc_block_spec_payload(spec))

    reasons = String[]
    warnings = String[]
    append!(reasons, plan.excluded)

    # 降格の合算（事前適用 W1/W4 + 事前固定 W2/W3 + 観測不足の W4）。
    # `est_params` に含まれるものだけを対象にする（`fixed_params` 上の W1 事前適用は
    # 情報として reasons に残す。§8.6）。
    est_set = Set(spec.est_params)
    demoted = Dict{Symbol, Symbol}()
    for (p, a) in plan.pre_applied
        p in est_set ? (demoted[p] = a) :
        push!(
            reasons,
            "fixed_params の $(p) に $(a) が事前適用されている（est_params ではない）",
        )
    end
    for (p, a) in plan.armed
        p in est_set && (demoted[p] = a)
    end
    for (p, a) in plan.demote_extra
        p in est_set && (demoted[p] = a)
    end

    n_obs_used = isempty(plan.specs) ? 0 : maximum(s.n_pairs for s in plan.specs)
    weights = Dict{String, Float64}(s.id => _ccc_weight(s, config) for s in plan.specs)

    # ---- point 推定 ----
    point = plan.point_params
    ranges = Dict{Symbol, Tuple{Float64, Float64}}()
    alternate_specs = Dict{Symbol, Dict{String, Float64}}()
    estimated = Dict{Symbol, Float64}()
    curvature = Dict{Symbol, Float64}()
    boundary_hits = Symbol[]
    admissibility_failures = String[]
    starts = CapexBlockEstimateStart[]
    initial_values = Dict{Symbol, Float64}()
    obj_value = NaN
    obj_contrib = Dict{String, Float64}()
    converged = false
    iterations = 0
    adopted_start = 0
    point_final = copy(plan.point_params)

    lit_θ = Dict{Symbol, Float64}(
        p => Float64(get(_ccc_default_behavioral(), p, get(pfix, p, 0.0))) for
        p in spec.est_params
    )
    lit_obj =
        isempty(plan.specs) ? NaN :
        _ccc_block_objective(plan.specs, lit_θ, pfix, config).total

    if !isempty(point) && !isempty(plan.specs)
        lo = [CAPEX_CC_EST_PARAM_BOUNDS[p][1] for p in point]
        hi = [CAPEX_CC_EST_PARAM_BOUNDS[p][2] for p in point]
        x0 = Float64[
            clamp(
                get(
                    config.initial_overrides,
                    p,
                    Float64(get(_ccc_default_behavioral(), p, get(pfix, p, 0.0))),
                ),
                CAPEX_CC_EST_PARAM_BOUNDS[p][1],
                CAPEX_CC_EST_PARAM_BOUNDS[p][2],
            ) for p in point
        ]
        for (k, p) in enumerate(point)
            initial_values[p] = x0[k]
        end

        # armed パラメータは point 推定中は literature default で固定
        θfix_armed = Dict{Symbol, Float64}(
            p => Float64(get(_ccc_default_behavioral(), p, get(pfix, p, 0.0))) for
            p in keys(plan.armed)
        )
        pfix_run = merge(pfix, θfix_armed)

        objfun = function (x)
            θ = Dict{Symbol, Float64}(point[k] => x[k] for k in eachindex(point))
            _ccc_block_objective(plan.specs, θ, pfix_run, config).total
        end

        # multi-start（1 個目 configured、以降 決定的摂動）
        starts_x0 = Vector{Vector{Float64}}(undef, config.n_starts)
        starts_x0[1] = copy(x0)
        if config.n_starts > 1
            g = _ccc_est_lcg(config.seed)
            for si in 2:(config.n_starts)
                xs = similar(x0)
                for k in eachindex(point)
                    u = _ccc_est_rand(g)
                    span = hi[k] - lo[k]
                    base = x0[k]
                    δ = config.start_perturbation * (2u - 1) * max(abs(base), 0.1 * span)
                    xs[k] = clamp(base + δ, lo[k], hi[k])
                end
                starts_x0[si] = xs
            end
        end

        for si in 1:(config.n_starts)
            xb, fb, iters, conv = _nelder_mead(
                objfun,
                starts_x0[si],
                lo,
                hi;
                max_iter = config.max_iterations,
                tol = config.tol,
            )
            push!(
                starts,
                CapexBlockEstimateStart(
                    si,
                    Dict(point[k] => starts_x0[si][k] for k in eachindex(point)),
                    Dict(point[k] => xb[k] for k in eachindex(point)),
                    fb,
                    conv,
                    iters,
                ),
            )
        end

        adopted_start = argmin([st.objective_value for st in starts])
        best = starts[adopted_start]
        converged = best.converged
        iterations = best.iterations
        for (k, p) in enumerate(point)
            estimated[p] = best.estimated[p]
        end
        xbest = [estimated[p] for p in point]
        θbest = Dict{Symbol, Float64}(point[k] => xbest[k] for k in eachindex(point))
        obj = _ccc_block_objective(plan.specs, θbest, pfix_run, config)
        obj_value = obj.total
        obj_contrib = obj.contributions

        # 境界張り付き（クリップしない）
        for (k, p) in enumerate(point)
            if isapprox(xbest[k], lo[k]; atol = config.boundary_atol) ||
               isapprox(xbest[k], hi[k]; atol = config.boundary_atol)
                push!(boundary_hits, p)
            end
        end

        # objective 曲率（前進差分。分散推定ではない）
        for (k, p) in enumerate(point)
            h = config.curvature_step * max(abs(xbest[k]), 1e-6)
            xp = copy(xbest)
            xm = copy(xbest)
            xp[k] = clamp(xbest[k] + h, lo[k], hi[k])
            xm[k] = clamp(xbest[k] - h, lo[k], hi[k])
            fp = objfun(xp)
            fm = objfun(xm)
            curvature[p] = (fp - 2 * obj_value + fm) / (h^2)
        end

        # 平坦な objective（曲率 ≈ 0）の点推定パラメータは事前固定の閾値
        # （config.weak_curvature_tol）で W2 範囲へ**事後発火**降格する（§8.6）。
        # 閾値を結果で変えない。曲率のみを見て他の推定を増やさない（#170 §8.3-3）。
        flat = Symbol[]
        for p in point
            c = get(curvature, p, NaN)
            (!isfinite(c) || abs(c) < config.weak_curvature_tol) && push!(flat, p)
        end
        if !isempty(flat)
            for p in flat
                delete!(estimated, p)
                demoted[p] = :W2
                push!(
                    reasons,
                    "objective 曲率 ≈ 0（$(round(get(curvature, p, NaN); sigdigits = 3))）→ W2 範囲へ事後発火降格（§8.6）",
                )
            end
            filter!(p -> !(p in flat), boundary_hits)
            point_final = Symbol[p for p in point if !(p in flat)]
            if isempty(point_final)
                obj_value = NaN
                obj_contrib = Dict{String, Float64}()
            else
                θr = Dict{Symbol, Float64}(p => estimated[p] for p in point_final)
                objr = _ccc_block_objective(plan.specs, θr, pfix_run, config)
                obj_value = objr.total
                obj_contrib = objr.contributions
            end
        end
    end

    # ---- 範囲報告（W2）と複数仕様（W3） ----
    base_θ = merge(
        Dict{Symbol, Float64}(
            p => Float64(get(_ccc_default_behavioral(), p, get(pfix, p, 0.0))) for
            p in spec.est_params
        ),
        estimated,
    )
    for (p, action) in sort(collect(demoted); by = x -> String(x[1]))
        if action === :W3
            alternate_specs[p] = _ccc_w3_alternate_specs(p, pfix)
            push!(
                reasons,
                "$(p): W3。ai_exp の 3 仕様（$(join(_CCC_W3_AI_EXP_SPECS, " / "))）を並置。" *
                "ai_exp 系列が揃わない段階では各仕様の推定値を作れず、既定値を 3 通り並置する（単一値を採らない。#170 §8.2 ID-1）",
            )
        elseif action in (:W2, :W1, :W4)
            ranges[p] = _ccc_w2_range(p, plan.specs, base_θ, pfix, config)
        end
    end

    # ---- 許容条件 9・10（推定後検証。クリップしない） ----
    for s in _CCC_S15
        up_k = Symbol("bh_emp_up_$s")
        dn_k = Symbol("bh_emp_down_$s")
        up_v = get(estimated, up_k, get(base_θ, up_k, get(pfix, up_k, NaN)))
        dn_v = get(estimated, dn_k, get(base_θ, dn_k, get(pfix, dn_k, NaN)))
        if isfinite(up_v) &&
           isfinite(dn_v) &&
           (haskey(estimated, up_k) || haskey(estimated, dn_k))
            dn_v <= up_v || push!(
                admissibility_failures,
                "条件9: bh_emp_down_$(s)（$(dn_v)）> bh_emp_up_$(s)（$(up_v)）",
            )
        end
    end
    if haskey(estimated, :bh_mpc)
        (0 < estimated[:bh_mpc] < 1) || push!(
            admissibility_failures,
            "条件10: 0 < bh_mpc（$(estimated[:bh_mpc])）< 1 が破れています",
        )
    end

    # ---- ステータス判定 ----
    status = if isempty(point_final)
        push!(reasons, "点推定対象が 0（すべて W1/W2/W3/W4 へ降格）")
        :demoted
    elseif !isfinite(obj_value)
        :invalid_objective
    elseif !isempty(admissibility_failures)
        push!(reasons, "許容条件違反（クリップしない）: " * join(admissibility_failures, "; "))
        :invalid_objective
    elseif !isempty(boundary_hits)
        push!(reasons, "境界張り付き: " * join(String.(boundary_hits), ", "))
        :boundary_solution
    elseif !converged
        push!(reasons, "採用 start が収束せず（max_iterations=$(config.max_iterations)）")
        :not_converged
    else
        :converged
    end

    if diag.status === :weakly_identified
        push!(
            warnings,
            "識別診断: :weakly_identified。armed パラメータは点推定せず範囲報告（§5.6 契約2）",
        )
    end
    isempty(plan.armed) || push!(
        warnings,
        "W2/W3 armed: " * join(
            ["$(p)=>:$(a)" for (p, a) in sort(collect(plan.armed); by = x -> String(x[1]))],
            ", ",
        ),
    )

    n_obs_excluded = length(plan.excluded)

    metadata = Dict{String, Any}(
        "estimation_version" => CAPEX_CC_ESTIMATION_VERSION,
        "dataset_hash" => get(ds.metadata, "dataset_hash", ""),
        "targets_hash" => cal.targets_hash,
        "identification_version" => CAPEX_CC_IDENTIFICATION_VERSION,
        "objective" => "per-equation residual (std-normalized); trajectory matching は採らない（§8.5）",
        "standard_errors_note" => "curvature は objective の曲率近似であり分散推定ではない（#170 §8.3-1）",
        "caveat" => "fit の良さは因果妥当性・景気後退確率・予測精度ではない（ADR 0018 決定22）",
        "holdout_frac" => config.holdout_frac,
    )

    return CapexBlockEstimate(
        block,
        spec.order,
        status,
        copy(spec.equation_ids),
        estimated,
        ranges,
        alternate_specs,
        demoted,
        Dict{Symbol, Tuple{Float64, Float64}}(
            p => CAPEX_CC_EST_PARAM_BOUNDS[p] for p in spec.est_params
        ),
        initial_values,
        obj_value,
        obj_contrib,
        lit_obj,
        sort(boundary_hits; by = String),
        admissibility_failures,
        curvature,
        n_obs_used,
        n_obs_excluded,
        plan.excluded,
        weights,
        converged,
        iterations,
        adopted_start,
        starts,
        false,
        diag.status,
        reasons,
        warnings,
        config,
        block_spec_hash,
        metadata,
    )
end

# ブロック仕様の canonical payload（block_spec_hash・parameter_set_hash の一部）
function _ccc_block_spec_payload(b::CapexEstimationBlockSpec)
    return Dict{String, Any}(
        "id" => String(b.id),
        "order" => b.order,
        "est_params" => sort(String.(b.est_params)),
        "fixed_params" => sort(String.(b.fixed_params)),
        "required_keys" => sort(String.(b.required_keys)),
        "supporting_keys" => sort(String.(b.supporting_keys)),
        "equation_ids" => sort(b.equation_ids),
        "identification_risks" => sort(String.(b.identification_risks)),
        "preassigned_actions" =>
            Dict{String, Any}(String(k) => String(v) for (k, v) in b.preassigned_actions),
    )
end

# ---------------------------------------------------------------------------
# parameter set（literature/default・calibrated・estimated を別フィールドに保持）
# ---------------------------------------------------------------------------

"""
    CapexParameterSet

`EB-1`–`EB-7` の限定推定結果を、由来別に分けて保持する再現可能な parameter artifact
（実証統合設計 §5.6 契約 7・§11.2）。

- `kind ∈ CAPEX_CC_PARAMETER_SET_KINDS`。
- `literature_default`: `bh_` の実装既定値（`Z-17`: 出所は `default_unattributed`）。
- `calibrated`: 逆較正で決まった `CAL-SS`/`CAL-OBS` パラメータ（`cal.model` 由来）。
- `estimated`: ブロック別推定の点推定値。
- `ranges` / `alternate_specs`: `W2` 範囲報告・`W3` 複数仕様。
- `parameter_source`: 全 142 パラメータの由来（`:fixed`/`:calibrated`/`:estimated`/
  `:literature_default`/`:demoted_W1`–`:demoted_W4`）。
- `parameter_set_hash`: `targets_hash` + block spec + config + 推定値 + `kind` の canonical hash
  （反復回数・所要時間は除外。§11.3）。
"""
struct CapexParameterSet
    version::String
    kind::Symbol
    dataset_hash::String
    targets_hash::String
    identification_hash::String
    literature_default::Dict{Symbol, Float64}
    calibrated::Dict{Symbol, Float64}
    estimated::Dict{Symbol, Float64}
    ranges::Dict{Symbol, Tuple{Float64, Float64}}
    alternate_specs::Dict{Symbol, Dict{String, Float64}}
    demoted::Dict{Symbol, Symbol}
    parameter_source::Dict{Symbol, Symbol}
    block_estimates::Vector{CapexBlockEstimate}
    config::CapexEstimationConfig
    parameter_set_hash::String
    warnings::Vector{String}
    metadata::Dict{String, Any}
end

"""
    capex_parameter_set(cal, diags, estimates; kind, config, identification_hash = "")
        -> CapexParameterSet

`kind` に応じた parameter artifact を作る。

- `:literature_default`: `estimates` は空でよい。`bh_` は実装既定値。
- `:calibrated`: `estimates` は空でよい。`bh_` は `cal.model` の較正値。
- `:estimated`: `estimates::Vector{CapexBlockEstimate}` を必須とし、点推定値で `bh_` を上書きする。
  推定不能パラメータは較正値／既定値のまま残し、`parameter_source` で由来を区別する。

`diags` は #245 の識別診断（`parameter_source` の `:demoted_*` 判定に用いる）。
"""
function capex_parameter_set(
    cal::CapexEmpiricalCalibration,
    diags::AbstractVector{CapexIdentificationDiagnostic},
    estimates::AbstractVector{CapexBlockEstimate} = CapexBlockEstimate[];
    kind::Symbol,
    config::CapexEstimationConfig = CapexEstimationConfig(),
    identification_hash::AbstractString = "",
)
    kind in CAPEX_CC_PARAMETER_SET_KINDS ||
        throw(ArgumentError("kind は $(CAPEX_CC_PARAMETER_SET_KINDS) のいずれかです"))
    if kind === :estimated && isempty(estimates)
        throw(
            ArgumentError(
                "kind = :estimated には estimates（CapexBlockEstimate の一覧）が必要です",
            ),
        )
    end
    for e in estimates
        e.block in (:EB1, :EB2, :EB3, :EB4, :EB5, :EB6, :EB7) ||
            throw(ArgumentError("未知の block $(e.block)"))
    end
    length(unique(e.block for e in estimates)) == length(estimates) ||
        throw(ArgumentError("estimates に同一 block が重複しています（1 ブロック 1 推定）"))

    lit = Dict{Symbol, Float64}(
        k => Float64(v) for (k, v) in pairs(_ccc_default_behavioral())
    )
    calp = Dict{Symbol, Float64}(k => Float64(v) for (k, v) in pairs(parameters(cal.model)))
    prov = cal.parameter_provenance

    estimated = Dict{Symbol, Float64}()
    ranges = Dict{Symbol, Tuple{Float64, Float64}}()
    alternate_specs = Dict{Symbol, Dict{String, Float64}}()
    demoted = Dict{Symbol, Symbol}()
    warnings = String[]

    if kind === :estimated
        for e in estimates
            for (p, v) in e.estimated
                estimated[p] = v
            end
            for (p, r) in e.ranges
                ranges[p] = r
            end
            for (p, sp) in e.alternate_specs
                alternate_specs[p] = copy(sp)
            end
            for (p, a) in e.demoted
                demoted[p] = a
            end
            append!(warnings, e.warnings)
        end
    end

    # parameter_source: 142 パラメータの由来
    parameter_source = Dict{Symbol, Symbol}()
    for (p, cls) in prov
        cls === :dict_placeholder && continue
        src = if cls === :FIX
            :fixed
        elseif cls in (:CAL_SS, :CAL_OBS)
            :calibrated
        elseif cls === :EST
            # `EST` は逆較正で決まらない。推定しなければ実装既定値のまま
            # （`Z-17`: 出所は default_unattributed）。
            if haskey(estimated, p)
                :estimated
            elseif haskey(demoted, p)
                Symbol("demoted_", String(demoted[p]))
            else
                :literature_default
            end
        else
            :literature_default
        end
        parameter_source[p] = src
    end

    cfg_payload = _ccc_estimation_config_payload(config)
    hash_payload = Dict{String, Any}(
        "parameter_set_version" => CAPEX_CC_ESTIMATION_VERSION,
        "kind" => String(kind),
        "targets_hash" => cal.targets_hash,
        "identification_hash" => String(identification_hash),
        "config" => cfg_payload,
        "block_specs" => Dict{String, Any}(
            String(b.id) => _ccc_block_spec_payload(b) for b in CAPEX_CC_ESTIMATION_BLOCKS
        ),
        "estimated" => Dict{String, Any}(String(k) => v for (k, v) in estimated),
        "ranges" => Dict{String, Any}(String(k) => [r[1], r[2]] for (k, r) in ranges),
        "alternate_specs" => Dict{String, Any}(
            String(k) => Dict{String, Any}(s => v for (s, v) in sp) for
            (k, sp) in alternate_specs
        ),
        "demoted" => Dict{String, Any}(String(k) => String(v) for (k, v) in demoted),
    )
    parameter_set_hash = "sha256:" * sha256_hex_of_canonical(hash_payload)

    metadata = Dict{String, Any}(
        "estimation_version" => CAPEX_CC_ESTIMATION_VERSION,
        "dataset_hash" => cal.dataset_hash,
        "targets_hash" => cal.targets_hash,
        "n_estimated" => length(estimated),
        "n_demoted" => length(demoted),
        "n_ranges" => length(ranges),
        "n_alternate_specs" => length(alternate_specs),
        "blocks_estimated" => sort(String.(e.block for e in estimates)),
        "caveat" => "literature/default と estimated/calibrated を別フィールドに保持する（由来不明の混在を作らない。§5.6 契約7）。fit を因果/予測精度へ読み替えない（ADR 0018 決定22）。",
    )

    return CapexParameterSet(
        CAPEX_CC_ESTIMATION_VERSION,
        kind,
        cal.dataset_hash,
        cal.targets_hash,
        String(identification_hash),
        lit,
        calp,
        estimated,
        ranges,
        alternate_specs,
        demoted,
        parameter_source,
        collect(estimates),
        config,
        parameter_set_hash,
        unique(warnings),
        metadata,
    )
end

# ---------------------------------------------------------------------------
# シリアライズ（決定的順序・artifact identity）
# ---------------------------------------------------------------------------

function _ccc_estimation_config_payload(c::CapexEstimationConfig)
    return Dict{String, Any}(
        "version" => c.version,
        "optimizer" => String(c.optimizer),
        "weight_mode" => String(c.weight_mode),
        "max_iterations" => c.max_iterations,
        "tol" => c.tol,
        "n_starts" => c.n_starts,
        "seed" => c.seed,
        "start_perturbation" => c.start_perturbation,
        "boundary_atol" => c.boundary_atol,
        "curvature_step" => c.curvature_step,
        "weak_curvature_tol" => c.weak_curvature_tol,
        "range_grid" => c.range_grid,
        "range_rel_tol" => c.range_rel_tol,
        "holdout_frac" => c.holdout_frac,
        "initial_overrides" =>
            Dict{String, Any}(String(k) => v for (k, v) in c.initial_overrides),
        "standard_errors_supported" => c.standard_errors_supported,
    )
end

"""
    capex_estimation_config_to_dict(config) -> Dict{String, Any}
"""
capex_estimation_config_to_dict(config::CapexEstimationConfig) =
    _ccc_estimation_config_payload(config)

"""
    capex_estimation_config_from_dict(d) -> CapexEstimationConfig
"""
function capex_estimation_config_from_dict(d)
    getv(k) = d[k]
    ov = Dict{Symbol, Float64}()
    if haskey(d, "initial_overrides")
        for (k, v) in pairs(d["initial_overrides"])
            ov[Symbol(String(k))] = Float64(v)
        end
    end
    return CapexEstimationConfig(;
        optimizer = Symbol(String(getv("optimizer"))),
        weight_mode = Symbol(String(getv("weight_mode"))),
        max_iterations = Int(getv("max_iterations")),
        tol = Float64(getv("tol")),
        n_starts = Int(getv("n_starts")),
        seed = Int(getv("seed")),
        start_perturbation = Float64(getv("start_perturbation")),
        boundary_atol = Float64(getv("boundary_atol")),
        curvature_step = Float64(getv("curvature_step")),
        weak_curvature_tol = Float64(getv("weak_curvature_tol")),
        range_grid = Int(getv("range_grid")),
        range_rel_tol = Float64(getv("range_rel_tol")),
        holdout_frac = Float64(getv("holdout_frac")),
        initial_overrides = ov,
        standard_errors_supported = Bool(getv("standard_errors_supported")),
        version = String(getv("version")),
    )
end

function _ccc_block_estimate_dict(e::CapexBlockEstimate)
    return Dict{String, Any}(
        "block" => String(e.block),
        "order" => e.order,
        "status" => String(e.status),
        "equation_ids" => sort(e.equation_ids),
        "estimated" => Dict{String, Any}(String(k) => v for (k, v) in e.estimated),
        "ranges" => Dict{String, Any}(String(k) => [r[1], r[2]] for (k, r) in e.ranges),
        "alternate_specs" => Dict{String, Any}(
            String(k) => Dict{String, Any}(s => v for (s, v) in sp) for
            (k, sp) in e.alternate_specs
        ),
        "demoted" => Dict{String, Any}(String(k) => String(v) for (k, v) in e.demoted),
        "bounds" => Dict{String, Any}(String(k) => [b[1], b[2]] for (k, b) in e.bounds),
        "initial_values" =>
            Dict{String, Any}(String(k) => v for (k, v) in e.initial_values),
        "objective_value" => isfinite(e.objective_value) ? e.objective_value : nothing,
        "objective_contributions" => e.objective_contributions,
        "literature_objective" =>
            isfinite(e.literature_objective) ? e.literature_objective : nothing,
        "boundary_hits" => sort(String.(e.boundary_hits)),
        "admissibility_failures" => e.admissibility_failures,
        "curvature" => Dict{String, Any}(
            String(k) => (isfinite(v) ? v : nothing) for (k, v) in e.curvature
        ),
        "n_obs_used" => e.n_obs_used,
        "n_obs_excluded" => e.n_obs_excluded,
        "excluded_reasons" => e.excluded_reasons,
        "weights" => e.weights,
        "converged" => e.converged,
        "iterations" => e.iterations,
        "adopted_start" => e.adopted_start,
        "starts" => [
            Dict{String, Any}(
                "index" => st.index,
                "initial" => Dict{String, Any}(String(k) => v for (k, v) in st.initial),
                "estimated" =>
                    Dict{String, Any}(String(k) => v for (k, v) in st.estimated),
                "objective_value" =>
                    isfinite(st.objective_value) ? st.objective_value : nothing,
                "converged" => st.converged,
                "iterations" => st.iterations,
            ) for st in e.starts
        ],
        "standard_errors_supported" => e.standard_errors_supported,
        "identification_status" => String(e.identification_status),
        "reasons" => e.reasons,
        "warnings" => e.warnings,
        "block_spec_hash" => e.block_spec_hash,
        "config" => _ccc_estimation_config_payload(e.config),
        "metadata" => e.metadata,
    )
end

"""
    capex_block_estimate_to_dict(e::CapexBlockEstimate) -> Dict{String, Any}
"""
capex_block_estimate_to_dict(e::CapexBlockEstimate) = _ccc_block_estimate_dict(e)

"""
    capex_parameter_set_to_dict(ps::CapexParameterSet) -> Dict{String, Any}

再現に必要な公開情報を辞書化する。API キー・URL・ローカルパスは含めない。
"""
function capex_parameter_set_to_dict(ps::CapexParameterSet)
    return Dict{String, Any}(
        "estimation_version" => ps.version,
        "kind" => String(ps.kind),
        "dataset_hash" => ps.dataset_hash,
        "targets_hash" => ps.targets_hash,
        "identification_hash" => ps.identification_hash,
        "parameter_set_hash" => ps.parameter_set_hash,
        "literature_default" =>
            Dict{String, Any}(String(k) => v for (k, v) in ps.literature_default),
        "calibrated" => Dict{String, Any}(String(k) => v for (k, v) in ps.calibrated),
        "estimated" => Dict{String, Any}(String(k) => v for (k, v) in ps.estimated),
        "ranges" => Dict{String, Any}(String(k) => [r[1], r[2]] for (k, r) in ps.ranges),
        "alternate_specs" => Dict{String, Any}(
            String(k) => Dict{String, Any}(s => v for (s, v) in sp) for
            (k, sp) in ps.alternate_specs
        ),
        "demoted" => Dict{String, Any}(String(k) => String(v) for (k, v) in ps.demoted),
        "parameter_source" =>
            Dict{String, Any}(String(k) => String(v) for (k, v) in ps.parameter_source),
        "block_estimates" => [_ccc_block_estimate_dict(e) for e in ps.block_estimates],
        "config" => _ccc_estimation_config_payload(ps.config),
        "warnings" => ps.warnings,
        "metadata" => ps.metadata,
    )
end

"""
    save_capex_parameter_set(path, ps) -> path

`CapexParameterSet` を JSON として保存する（`capex_parameter_set_to_dict`）。
"""
function save_capex_parameter_set(path::AbstractString, ps::CapexParameterSet)
    open(path, "w") do io
        JSON3.pretty(io, capex_parameter_set_to_dict(ps))
    end
    return path
end

"""
    save_capex_block_estimate(path, e) -> path
"""
function save_capex_block_estimate(path::AbstractString, e::CapexBlockEstimate)
    open(path, "w") do io
        JSON3.pretty(io, capex_block_estimate_to_dict(e))
    end
    return path
end
