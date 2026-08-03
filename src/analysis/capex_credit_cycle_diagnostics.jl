# capex_credit_cycle_diagnostics.jl: 部門別CAPEX・信用循環モデル（`CapexCreditCycleModel`）専用の
# 診断層（ラベル・資金繰り・ループ利得・非線形性・反実仮想、Issue #183 / `I-5`）。
#
# 会計層（`capex_credit_cycle_accounting.jl`、`I-3`）と同じ設計方針を踏襲する読み取り専用の
# 後処理層である。診断はモデル本体の動学に影響しない（ADR 0009・#169 §16.1）。`capex_run` の
# `run.diagnostics` へは接続しない（`I-5` の対象ファイルに `capex_credit_cycle.jl` を含まない。
# 統合設計 §9 `I-5`）。呼び出し側が `capex_diagnostics(m, run)` を明示的に呼ぶ。
#
# 設計契約:
#   docs/models/capex_credit_cycle_analysis_contract.md §3・§4（判定問題 Q1–Q5・診断ラベル）
#   docs/models/capex_credit_cycle_stock_flow.md §7.3・§7.4（資金繰り診断量・funding_pressure_s）
#   docs/models/capex_credit_cycle_equations.md §16（診断層の契約：ループ利得・非線形性・
#     credit-off・share_C・funding_pressure_s・ラベル整合確認）
#   docs/architecture/capex_credit_cycle_integration.md §6.4・§9 `I-5`
#   docs/adr/0013-capex-credit-cycle-integration-contract.md
#
# 反実仮想の実装方針（本ファイル冒頭で一度だけ説明する設計判断）:
#   `capex_run` は反実仮想実行のための内部フック（パラメータ差し替え・ラグ変数の固定）を持たない。
#   `R1a`/`R1b`/`R2` 短絡は「パラメータではなく変数を固定する」反実仮想（#169 §16.2 表）であり、
#   `CapexCreditCycleModel` の再構築（新パラメータでの逆較正）でも表現できない。そのため本ファイルは
#   `_ccc_financial!` 等の内部関数（8関数、期内処理順序に対応）をそのまま再利用する専用の実行ループ
#   （`_capex_cf_series`）を持つ。`capex_run` 本体との二重管理を避けるため、`_capex_cf_series` は
#   診断・反実仮想専用（警告・T2/T3 の構造化記録・`binding` の永続化を行わない最小実装）とし、
#   本番の期別系列生成は `capex_run` に一元化されたままである。
#
#   反実仮想の多くは定常状態を変えない（後述）。ゆえに `capex_diagnostics` は反実仮想を「同一の
#   `run.exog`（ショックあり）」と「baseline 外生パス（ショックなし）」の対で実行し、両者の差分を
#   `dz`（baseline比乖離）とする。この対実行方式は `loop_off_r4`（`st_gen_share_s = 0`）のように
#   定常状態そのものを変えてしまう反実仮想でも正しく機能する（差分がその反実仮想自身の無ショック
#   均衡からの乖離になるため）。他の反実仮想（`credit_off`・`cons_off`・R1a/R1b/R2/R2短絡/R3）は
#   `CapexCreditCycleModel` の許容条件（§13.4）が保証する構造的性質（`liq_s^ss = 1` により資本コスト
#   弾性項が定常状態でゼロになる、`bh_cov_threshold`・`pl_ltv`・`rollover^ss = 1` の各許容条件により
#   スプレッド閾値項・借換閾値項が定常状態でゼロになる、`lend_stance^ss = 0` により貸出態度弾性項が
#   ゼロになる）によって定常状態不変であることを確認済みであり、対実行方式はこれらに対しても
#   （無ショック側が定数系列になるだけで）同じ結果を与える。

# ------------------------------------------------------------
# CapexDiagnosticThresholds（統合設計 §6.4。全閾値は暫定既定値であり、分析契約 §4.4 に従い
# 方程式へハードコードせず外部化する）
# ------------------------------------------------------------

"""
    CapexDiagnosticThresholds

診断ラベル・非線形性近傍検出・Q1–Q3 判定に用いる全閾値。`id`・`version` を持ち、
`metadata["diagnostic_threshold_set"]`（`I-6` の責務）へそのまま出力できる。

## フィールド
分析契約 §4.2・§4.4（深さ・広がり・持続性）、§3 Q1–Q3（判定条件）、動学方程式 §16（残差・数値）
が正本。個別の意味は各節を参照。
"""
Base.@kwdef struct CapexDiagnosticThresholds
    id::String = "default"
    version::String = "capex-credit-cycle-thresholds/1.0.0"
    # 深さ（分析契約 §4.2 G1–G4）
    dy_total::Float64 = -0.010
    dy_sector::Float64 = -0.030
    di_sector::Float64 = -0.080
    dl::Float64 = -0.005
    dyd::Float64 = -0.008
    dc::Float64 = -0.008
    spread_bp::Float64 = 100.0
    # 広がり・持続性
    breadth::Float64 = 0.60
    persistence::Int = 2
    # Q1・Q2・Q3（分析契約 §3）
    q1_dy::Float64 = 0.005
    q1_spread_bp::Float64 = 50.0
    q1_recovery_window::Int = 8
    q1_recovery_ratio::Float64 = 0.5
    q2_amplification::Float64 = 1.2
    q3_share_c::Float64 = 0.30
    # 残差・数値（動学方程式 §16）
    s5_resid_tol::Float64 = 0.05
    prox_band::Float64 = 0.10
    jac_h::Float64 = 1e-6
end

# ------------------------------------------------------------
# CapexDiagnostics（統合設計 §6.4）
# ------------------------------------------------------------

"""
    CapexDiagnostics

`capex_diagnostics` の結果。フィールドの意味は統合設計 §6.4 の表・動学方程式 §16 を参照。
"""
struct CapexDiagnostics
    label::Symbol
    group_status::Dict{Symbol, NamedTuple}
    breadth::Float64
    breadth_excl_s1::Float64
    deteriorated_sectors::Vector{Symbol}
    peaks::Dict{String, NamedTuple}
    recovery_period::Union{Int, Nothing}
    funding_pressure::Dict{Symbol, Vector{Symbol}}
    loop_active::Dict{Symbol, Bool}
    loop_gain::Dict{Symbol, Union{Float64, Nothing}}
    spectral_radius::Vector{Float64}
    short_circuit_gain::Vector{Float64}
    threshold_proximity::Vector{NamedTuple}
    amplification::Union{Float64, Nothing}
    share_c::Union{Float64, Nothing}
    share_c_additive::Union{Float64, Nothing}
    delayed_containment::Union{Bool, Nothing}
    label_loop_mismatch::Bool
    accounting_status::AccountingCheckStatus
    thresholds::CapexDiagnosticThresholds
end

"""
    CAPEX_CC_FUNDING_PRESSURE_LABELS

`funding_pressure_s` の5値（precedenceの高い順。会計仕様 §7.4・動学方程式 §16.8）。
"""
const CAPEX_CC_FUNDING_PRESSURE_LABELS = (
    :fp_invalid,
    :fp_unlevered,
    :fp_interest_uncovered,
    :fp_rollover_dependent,
    :fp_covered,
)

"""
    CAPEX_CC_NL_IDS

非線形性の所在7箇所（動学方程式 §16.4）の識別子。
"""
const CAPEX_CC_NL_IDS = (
    Symbol("NL-1"),
    Symbol("NL-2"),
    Symbol("NL-3"),
    Symbol("NL-4"),
    Symbol("NL-5"),
    Symbol("NL-6"),
    Symbol("NL-7"),
)

"""
    CAPEX_CC_LOOP_IDS

ループ作動フラグ5本（動学方程式 §16.2 `E16-04`）。
"""
const CAPEX_CC_LOOP_IDS = (:R1a, :R1b, :R2, :R3, :R4)

"""
    CAPEX_CC_LOOP_GAIN_IDS

`gain(loop)`（反実仮想インパルス比、動学方程式 §16.2表(B)）の6行。`R2_short` は短絡ループの
反実仮想版であり、`short_circuit_gain`（`g_short`、閉形式 `E16-05`）とは別の量である。
"""
const CAPEX_CC_LOOP_GAIN_IDS = (:R1a, :R1b, :R2, :R2_short, :R3, :R4)

"""
    CAPEX_CC_COUNTERFACTUAL_KINDS

`capex_counterfactual` が受理する反実仮想種別。`:credit_off`・`:cons_off`・`loop_off` 6種
（統合設計 §9 `I-5`）。
"""
const CAPEX_CC_COUNTERFACTUAL_KINDS = (
    :credit_off,
    :cons_off,
    :loop_off_r1a,
    :loop_off_r1b,
    :loop_off_r2,
    :loop_off_r2_short,
    :loop_off_r3,
    :loop_off_r4,
)

const _CAPEX_LOOP_GAIN_TO_CF_KIND = Dict(
    :R1a => :loop_off_r1a,
    :R1b => :loop_off_r1b,
    :R2 => :loop_off_r2,
    :R2_short => :loop_off_r2_short,
    :R3 => :loop_off_r3,
    :R4 => :loop_off_r4,
)

const _CAPEX_LOOP_GAIN_REPRESENTATIVE = Dict(
    :R1a => [:capex_exec_s1],
    :R1b => [:y_s2, :y_s3],
    :R2 => [:capex_exec_s1, :invest_s2, :invest_s3],
    :R2_short => [:spread],
    :R3 => [:capex_exec_s1],
    :R4 => [:cons],
)

# ------------------------------------------------------------
# 反実仮想パラメータ・変数固定の仕様（動学方程式 §16.2・§16.5）
# ------------------------------------------------------------

"""
    _capex_counterfactual_spec(m, kind) -> (overrides::NamedTuple, fixed_state::Vector{Symbol})

`kind`（[`CAPEX_CC_COUNTERFACTUAL_KINDS`](@ref)）に対応する `params` の上書き集合と、
固定する状態キー（`_CCCState` の70キーのいずれか）を返す。

- `:credit_off`（動学方程式 §16.5）: 資本コスト・貸出態度・借換条件の各弾性を固定するパラメータ
  5系統9個。`cost_capital_s` 自体・`repay_s`・`bh_spread_cov`/`bh_roll_slope`/`bh_coll_elas` は
  固定しない（§16.5 の「固定しないパラメータ」表）。
- `:cons_off`（`E16-07` の定義）: `bh_mpc = 0` かつ `st_cons_auto = cons^{ss}`（`cons` を baseline
  系列に固定するのと同値）。
- `:loop_off_r1a`/`:loop_off_r1b`（§16.2表）: パラメータでは表現できない反実仮想であるため
  `ocf_s[t−1]` を定常値に固定する（変数の固定）。
- `:loop_off_r2`/`:loop_off_r3`: `bh_spread_cov = 0`／`bh_roll_slope = 0`。
- `:loop_off_r2_short`: `bh_spread_cov = 0` かつ `r_new_s` を定常値に固定する契約（§16.2表）を、
  `r_eff_s`（状態）を定常値に固定することで実装する。両者は定常状態から出発する限り同一の不動点を
  与える（`r_eff_s` の更新式 `E5-13` が `r_new_s` を定常値に固定すれば自明にその値へ留まるため）。
- `:loop_off_r4`: `st_gen_share_s2 = st_gen_share_s3 = 0`。
"""
function _capex_counterfactual_spec(m::CapexCreditCycleModel, kind::Symbol)
    kind in CAPEX_CC_COUNTERFACTUAL_KINDS || throw(
        ArgumentError(
            "未知の反実仮想種別: $(kind)。$(CAPEX_CC_COUNTERFACTUAL_KINDS) のいずれかを" *
            "指定してください",
        ),
    )
    if kind === :credit_off
        overrides = (
            bh_cc_elas_s1 = 0.0,
            bh_cc_elas_inv_s2 = 0.0,
            bh_cc_elas_inv_s3 = 0.0,
            bh_lend_elas_inv_s2 = 0.0,
            bh_lend_elas_inv_s3 = 0.0,
            bh_dcap_lend_s1 = 0.0,
            bh_dcap_lend_s2 = 0.0,
            bh_dcap_lend_s3 = 0.0,
            bh_defer_roll = 0.0,
        )
        return (overrides = overrides, fixed_state = Symbol[])
    elseif kind === :cons_off
        ss = steady_state(m)
        return (overrides = (bh_mpc = 0.0, st_cons_auto = ss.cons), fixed_state = Symbol[])
    elseif kind === :loop_off_r1a
        return (overrides = NamedTuple(), fixed_state = [:ocf_s1_lag1])
    elseif kind === :loop_off_r1b
        return (overrides = NamedTuple(), fixed_state = [:ocf_s2_lag1, :ocf_s3_lag1])
    elseif kind === :loop_off_r2
        return (overrides = (bh_spread_cov = 0.0,), fixed_state = Symbol[])
    elseif kind === :loop_off_r2_short
        return (
            overrides = (bh_spread_cov = 0.0,),
            fixed_state = [:r_eff_s1, :r_eff_s2, :r_eff_s3],
        )
    elseif kind === :loop_off_r3
        return (overrides = (bh_roll_slope = 0.0,), fixed_state = Symbol[])
    else # :loop_off_r4
        return (
            overrides = (st_gen_share_s2 = 0.0, st_gen_share_s3 = 0.0),
            fixed_state = Symbol[],
        )
    end
end

"""
    _capex_cf_series(m, p_cf, opts, exog, fixed_state) -> NamedTuple

診断・反実仮想専用の実行ループ。`capex_run` と同じ内部関数（8関数、期内処理順序に対応）を
`m.params` の代わりに `p_cf`（上書き済み `NamedTuple`）で呼び出し、`fixed_state` に列挙した
状態キーを毎期定常値へ固定し直す。警告・T2構造化記録・`binding` の永続化は行わない
（`run.warnings`・`run.binding` に相当する出力はこの関数の対象外）。発散時は当該期以降を
`NaN` で埋めて打ち切る（`capex_run` の T3 契約と同じ扱いだが、`termination_reason` は返さない）。
"""
function _capex_cf_series(
    m::CapexCreditCycleModel,
    p_cf::NamedTuple,
    opts::CapexCreditCycleOptions,
    exog::Dict{Symbol, Vector{Float64}},
    fixed_state::Vector{Symbol},
)
    n = opts.horizon_runup + opts.horizon_eval
    st0 = _ccc_state0_from_steady(m)
    binding = _CCCBinding(k => falses(n) for k in _ccc_default_binding_keys())
    unique_names = vcat(
        collect(_CCC_STATE_BASE),
        _ccc_control_variables(),
        collect(CAPEX_CC_EXOGENOUS_VARIABLES),
        _ccc_diagnostic_variables(),
    )
    series = Dict{Symbol, Vector{Float64}}(nm => fill(NaN, n) for nm in unique_names)

    st = st0
    for idx in 1:n
        pr = _CCCPeriod()
        _ccc_apply_exog!(pr, exog, idx)
        _ccc_financial!(pr, st, p_cf, opts, binding, idx)
        _ccc_plan!(pr, st, p_cf, opts, binding, idx)
        _ccc_funding!(pr, st, p_cf, opts, binding, idx)
        _ccc_orders!(pr, st, p_cf, opts, binding, idx)
        _ccc_production!(pr, st, p_cf, opts, binding, idx)
        _ccc_income!(pr, st, p_cf, opts, binding, idx)
        _ccc_revenue!(pr, st, p_cf, opts, binding, idx)
        _ccc_update!(pr, st, p_cf, opts, binding, idx)

        newst = _CCCState()
        _ccc_shift_state!(newst, pr, st)
        for sym in fixed_state
            newst[sym] = st0[sym]
        end

        state_ok =
            all(isfinite(v) for v in values(newst)) &&
            all(abs(v) <= opts.guard_max for v in values(newst))
        if state_ok
            for nm in unique_names
                series[nm][idx] = haskey(pr, nm) ? pr[nm] : get(newst, nm, NaN)
            end
            st = newst
        else
            break # 残りは初期化時の NaN のまま
        end
    end

    return NamedTuple{Tuple(unique_names)}(Tuple(series[nm] for nm in unique_names))
end

"""
    capex_counterfactual(m::CapexCreditCycleModel, run::CapexCreditCycleRun, kind::Symbol) -> NamedTuple

`kind`（[`CAPEX_CC_COUNTERFACTUAL_KINDS`](@ref)）の反実仮想を、`run` と同一のショック系列
（`run.exog`）・初期状態（定常状態）で再実行し、`simulate` と同じ形の系列 `NamedTuple` を返す。
"""
function capex_counterfactual(
    m::CapexCreditCycleModel,
    run::CapexCreditCycleRun,
    kind::Symbol,
)
    spec = _capex_counterfactual_spec(m, kind)
    p_cf = merge(m.params, spec.overrides)
    return _capex_cf_series(m, p_cf, run.options, run.exog, spec.fixed_state)
end

# ------------------------------------------------------------
# 共通ヘルパー
# ------------------------------------------------------------

_capex_series(run::CapexCreditCycleRun, sym::Symbol) =
    Float64.(getproperty(run.series, sym))

"""期 `idx` における `t ≥ 0`（評価期間）のインデックス一覧。"""
_capex_eval_indices(run::CapexCreditCycleRun) = findall(t -> t >= 0, run.periods)

"""
    _capex_peak(series, periods, idxs) -> (value, period)

`idxs` の範囲で `|series|` を最大化する点の値（符号付き）と期を返す。有限値が無ければ
`(value=NaN, period=nothing)`。
"""
function _capex_peak(series::Vector{Float64}, periods::Vector{Int}, idxs::Vector{Int})
    best_i = 0
    best_v = 0.0
    for i in idxs
        v = series[i]
        isfinite(v) || continue
        if best_i == 0 || abs(v) > abs(best_v)
            best_v = v
            best_i = i
        end
    end
    best_i == 0 && return (value = NaN, period = nothing)
    return (value = best_v, period = periods[best_i])
end

"""baseline（定常状態）比の絶対乖離系列（`x_t − base`）。相対乖離ではなく水準差である
（比の分母が共通であるため `gain(loop)`・`share_C` 系のいずれの比でも相対/絶対の選択は
結果を変えない）。"""
_capex_abs_dev(series::Vector{Float64}, base::Float64) = series .- base

"""相対乖離系列 `(x_t − base) / |base|`（`div_eps` 以下は `NaN`）。分析契約 §4.2 の
深さ閾値（%表記）と比較するために用いる。"""
function _capex_rel_dev(series::Vector{Float64}, base::Float64, eps::Float64)
    return abs(base) <= eps ? fill(NaN, length(series)) : (series .- base) ./ abs(base)
end

"""
    _capex_persistent(breach, periods, idxs, persistence) -> (met, start_period, duration)

`idxs` の範囲で `breach` が連続 `true` となる最長区間を探し、`persistence` 期以上連続していれば
`met = true` とする（分析契約 §4.2 の持続性条件）。
"""
function _capex_persistent(
    breach::Vector{Bool},
    periods::Vector{Int},
    idxs::Vector{Int},
    persistence::Int,
)
    best_len = 0
    best_start = nothing
    cur_len = 0
    cur_start = nothing
    for i in idxs
        if breach[i]
            cur_len == 0 && (cur_start = periods[i])
            cur_len += 1
            if cur_len > best_len
                best_len = cur_len
                best_start = cur_start
            end
        else
            cur_len = 0
            cur_start = nothing
        end
    end
    met = best_len >= persistence
    return (met = met, start_period = met ? best_start : nothing, duration = best_len)
end

# ------------------------------------------------------------
# 診断ラベル（分析契約 §4.2–§4.3。G1–G4・breadth・persistence・Q1）
# ------------------------------------------------------------

"""`(periods, series)` から期 `t` の値を取り出す（`t` が範囲外なら `NaN`）。"""
function _capex_at(series::Vector{Float64}, periods::Vector{Int}, t::Int)
    i = findfirst(==(t), periods)
    i === nothing && return NaN
    return series[i]
end

"""
    _capex_group_breaches(run, ss, thresholds) -> Dict{Symbol,Vector{Bool}}

`G1`–`G4`（分析契約 §4.2）の各期の閾値超過を返す。`G4` は `spread` の水準差（bp）のみを用いる。
`lend_stance` の「引き締め方向へ既定幅超」は上流が具体的な閾値を与えていないため実装しない
（分析契約 §4.2 表の脚注、上流への差し戻し事項）。
"""
function _capex_group_breaches(
    run::CapexCreditCycleRun,
    ss::NamedTuple,
    thresholds::CapexDiagnosticThresholds,
)
    n = length(run.periods)
    eps = run.options.div_eps

    dY = _capex_rel_dev(_capex_series(run, :y_tot), ss.y_tot, eps)
    g1 = [isfinite(dY[i]) && dY[i] <= thresholds.dy_total for i in 1:n]

    dY_s1 = _capex_rel_dev(_capex_series(run, :y_s1), ss.y_s1, eps)
    dY_s2 = _capex_rel_dev(_capex_series(run, :y_s2), ss.y_s2, eps)
    dY_s3 = _capex_rel_dev(_capex_series(run, :y_s3), ss.y_s3, eps)
    dI_s1 = _capex_rel_dev(_capex_series(run, :capex_exec_s1), ss.capex_exec_s1, eps)
    dI_s2 = _capex_rel_dev(_capex_series(run, :invest_s2), ss.invest_s2, eps)
    dI_s3 = _capex_rel_dev(_capex_series(run, :invest_s3), ss.invest_s3, eps)
    g2 = [
        (isfinite(dY_s1[i]) && dY_s1[i] <= thresholds.dy_sector) ||
            (isfinite(dY_s2[i]) && dY_s2[i] <= thresholds.dy_sector) ||
            (isfinite(dY_s3[i]) && dY_s3[i] <= thresholds.dy_sector) ||
            (isfinite(dI_s1[i]) && dI_s1[i] <= thresholds.di_sector) ||
            (isfinite(dI_s2[i]) && dI_s2[i] <= thresholds.di_sector) ||
            (isfinite(dI_s3[i]) && dI_s3[i] <= thresholds.di_sector) for i in 1:n
    ]

    dL = _capex_rel_dev(_capex_series(run, :emp_tot), ss.emp_tot, eps)
    dYD = _capex_rel_dev(_capex_series(run, :hh_income), ss.hh_income, eps)
    dC = _capex_rel_dev(_capex_series(run, :cons), ss.cons, eps)
    g3 = [
        (isfinite(dL[i]) && dL[i] <= thresholds.dl) ||
            (isfinite(dYD[i]) && dYD[i] <= thresholds.dyd) ||
            (isfinite(dC[i]) && dC[i] <= thresholds.dc) for i in 1:n
    ]

    spread_dev = _capex_abs_dev(_capex_series(run, :spread), ss.spread)
    g4 = [isfinite(spread_dev[i]) && spread_dev[i] >= thresholds.spread_bp for i in 1:n]

    return Dict(:G1 => g1, :G2 => g2, :G3 => g3, :G4 => g4)
end

"""
    _capex_breadth_series(run, ss, thresholds; excl_s1=false) -> Vector{Float64}

実体部門（`S1`・`S2`・`S3`・`S5`。`excl_s1=true` なら `S2`・`S3`・`S5`）のうち産出乖離が
`thresholds.dy_total` 以下となった部門の割合（分析契約 §4.2「広がり」）。
"""
function _capex_breadth_series(
    run::CapexCreditCycleRun,
    ss::NamedTuple,
    thresholds::CapexDiagnosticThresholds;
    excl_s1::Bool = false,
)
    eps = run.options.div_eps
    sectors = excl_s1 ? (:s2, :s3, :s5) : (:s1, :s2, :s3, :s5)
    devs = Dict(
        s => _capex_rel_dev(
            _capex_series(run, Symbol("y_$s")),
            getproperty(ss, Symbol("y_$s")),
            eps,
        ) for s in sectors
    )
    n = length(run.periods)
    return [
        count(s -> isfinite(devs[s][i]) && devs[s][i] <= thresholds.dy_total, sectors) /
        length(sectors) for i in 1:n
    ]
end

"""
    _capex_q1_recovery_ok(dev, periods, thresholds) -> Bool

分析契約 §3 Q1 (c): `dev`（部門産出乖離）の peak 後 `q1_recovery_window` 四半期以内に
`|dev|` が `q1_recovery_ratio · |peak|` 以下へ回復し、その後（window 内で）再悪化しないこと。
乖離が実質的にゼロ（悪化していない）場合は自明に成立する。
"""
function _capex_q1_recovery_ok(
    dev::Vector{Float64},
    periods::Vector{Int},
    thresholds::CapexDiagnosticThresholds,
)
    n = length(periods)
    peak = _capex_peak(dev, periods, collect(1:n))
    isfinite(peak.value) || return false
    abs(peak.value) <= 1e-10 && return true

    target = thresholds.q1_recovery_ratio * abs(peak.value)
    window_end = peak.period + thresholds.q1_recovery_window
    window_idx = [i for i in 1:n if periods[i] > peak.period && periods[i] <= window_end]
    isempty(window_idx) && return false

    recovered_from = nothing
    for i in window_idx
        v = dev[i]
        if isfinite(v) && abs(v) <= target
            recovered_from = i
            break
        end
    end
    recovered_from === nothing && return false
    # 回復後、window内で再び 50% ラインを上回らないこと（単調な回復）
    for i in window_idx
        periods[i] < periods[recovered_from] && continue
        v = dev[i]
        (isfinite(v) && abs(v) <= target) || return false
    end
    return true
end

"""
    _capex_q1_contained(run, ss, thresholds) -> Bool

分析契約 §3 Q1 の (a)–(d) をすべて満たすか。
"""
function _capex_q1_contained(
    run::CapexCreditCycleRun,
    ss::NamedTuple,
    thresholds::CapexDiagnosticThresholds,
)
    eps = run.options.div_eps
    periods = run.periods
    eval_idx = _capex_eval_indices(run)

    dY = _capex_rel_dev(_capex_series(run, :y_tot), ss.y_tot, eps)
    peak_dY = _capex_peak(dY, periods, eval_idx)
    cond_a = isfinite(peak_dY.value) && abs(peak_dY.value) <= thresholds.q1_dy

    dL = _capex_rel_dev(_capex_series(run, :emp_tot), ss.emp_tot, eps)
    dC = _capex_rel_dev(_capex_series(run, :cons), ss.cons, eps)
    peak_dL = _capex_peak(dL, periods, eval_idx)
    peak_dC = _capex_peak(dC, periods, eval_idx)
    cond_b =
        isfinite(peak_dL.value) &&
        isfinite(peak_dC.value) &&
        peak_dL.value > thresholds.dl &&
        peak_dC.value > thresholds.dc

    dY_s2 = _capex_rel_dev(_capex_series(run, :y_s2), ss.y_s2, eps)
    dY_s3 = _capex_rel_dev(_capex_series(run, :y_s3), ss.y_s3, eps)
    cond_c =
        _capex_q1_recovery_ok(dY_s2, periods, thresholds) &&
        _capex_q1_recovery_ok(dY_s3, periods, thresholds)

    spread_dev = _capex_abs_dev(_capex_series(run, :spread), ss.spread)
    peak_spread = _capex_peak(spread_dev, periods, eval_idx)
    cond_d = isfinite(peak_spread.value) && peak_spread.value < thresholds.q1_spread_bp

    return cond_a && cond_b && cond_c && cond_d
end

"""
    _capex_label(run, ss, thresholds) -> (label, group_status, breadth_peak, deteriorated)

分析契約 §4.2 の判定ルールに従いラベルを決定する（`capex_diagnostics` と
`capex_label_sensitivity` が共有する軽量経路。反実仮想・ヤコビアンを計算しない）。
"""
function _capex_label(
    run::CapexCreditCycleRun,
    ss::NamedTuple,
    thresholds::CapexDiagnosticThresholds,
)
    periods = run.periods
    eval_idx = _capex_eval_indices(run)
    breaches = _capex_group_breaches(run, ss, thresholds)
    group_status = Dict(
        g => _capex_persistent(breaches[g], periods, eval_idx, thresholds.persistence)
        for g in (:G1, :G2, :G3, :G4)
    )

    breadth_series = _capex_breadth_series(run, ss, thresholds)
    peak_breadth_idx =
        isempty(eval_idx) ? nothing :
        eval_idx[argmax(getindex.(Ref(breadth_series), eval_idx))]
    breadth_peak = peak_breadth_idx === nothing ? 0.0 : breadth_series[peak_breadth_idx]

    n_met = count(g -> group_status[g].met, (:G1, :G2, :G3, :G4))
    broad = group_status[:G1].met && n_met >= 3 && breadth_peak >= thresholds.breadth
    sectoral = group_status[:G2].met && !broad
    contained = !broad && !sectoral && _capex_q1_contained(run, ss, thresholds)

    label =
        broad ? :broad_downturn :
        sectoral ? :sectoral_downturn : contained ? :contained_adjustment : :indeterminate

    return (
        label = label,
        group_status = group_status,
        breadth_peak = breadth_peak,
        peak_breadth_idx = peak_breadth_idx,
    )
end

# ------------------------------------------------------------
# funding_pressure_s（会計仕様 §7.4・動学方程式 §16.8）
# ------------------------------------------------------------

"""
    _capex_funding_pressure(run; atol=1e-8, rtol=1e-6) -> Dict{Symbol,Vector{Symbol}}

`S1`–`S3` の各期について `funding_pressure_s` の5値を precedence
（`fp_invalid` → `fp_unlevered` → `fp_interest_uncovered` → `fp_rollover_dependent` →
`fp_covered`）で判定する（会計仕様 §7.4）。
"""
function _capex_funding_pressure(
    run::CapexCreditCycleRun;
    atol::Float64 = 1e-8,
    rtol::Float64 = 1e-6,
)
    n = length(run.periods)
    st_debt_tol = 0.01 # モデルの数値許容パラメータと同名（`st_debt_tol`）だが会計仕様 §7.4 は
    # 独立の閾値として与えている。既定パラメータ値と揃える（動学方程式 §13.2 の既定値）。
    result = Dict{Symbol, Vector{Symbol}}()
    for s in (:s1, :s2, :s3)
        ocf = _capex_series(run, Symbol("ocf_$s"))
        int_burden = _capex_series(run, Symbol("int_burden_$s"))
        debt_service = _capex_series(run, Symbol("debt_service_$s"))
        labels = Vector{Symbol}(undef, n)
        for idx in 1:n
            debt_lag1 = _capex_prev_state_or_lag(run, s, idx)
            o = ocf[idx]
            ib = int_burden[idx]
            ds = debt_service[idx]
            tau = atol + rtol * max(abs(o), abs(ib), abs(ds), 1.0)
            if !(isfinite(o) && isfinite(ib) && isfinite(ds) && isfinite(debt_lag1))
                labels[idx] = :fp_invalid
            elseif debt_lag1 <= st_debt_tol
                labels[idx] = :fp_unlevered
            elseif o < ib - tau
                labels[idx] = :fp_interest_uncovered
            elseif o < ds - tau
                labels[idx] = :fp_rollover_dependent
            else
                labels[idx] = :fp_covered
            end
        end
        result[s] = labels
    end
    return result
end

"""`debt_s[t−1]`（`_capex_prev_state` は accounting.jl 定義の同名関数だが `debt_s` は
`_CCC_STATE_BASE` のため直接利用できる。ここでは公開APIとしての独立性を保つため薄いラッパを
経由する）。"""
_capex_prev_state_or_lag(run::CapexCreditCycleRun, s::Symbol, idx::Int) =
    _capex_prev_state(run, Symbol("debt_$s"), idx)

# ------------------------------------------------------------
# threshold_proximity（NL-1–NL-7、動学方程式 §16.4）
# ------------------------------------------------------------

"""
    _capex_threshold_proximity(m, run, thresholds) -> Vector{NamedTuple}

`NL-1`–`NL-7`（動学方程式 §16.4）の近傍検出。近傍（`proximity ≤ prox_band`）または閾値を
またいだ（`crossed`）期のみを記録する（近傍でなくてもまたいだ事実は記録する契約）。
"""
function _capex_threshold_proximity(
    m::CapexCreditCycleModel,
    run::CapexCreditCycleRun,
    thresholds::CapexDiagnosticThresholds,
)
    p = m.params
    eps = run.options.div_eps
    band = thresholds.prox_band
    n = length(run.periods)
    entries = NamedTuple[]

    _push!(id, t, sector, qty, thr) = begin
        isfinite(qty) && isfinite(thr) || return nothing
        prox = abs(qty - thr) / max(abs(thr), eps)
        crossed = qty > thr
        if prox <= band || crossed
            push!(
                entries,
                (id = id, period = t, sector = sector, proximity = prox, crossed = crossed),
            )
        end
        return nothing
    end

    # NL-1: 計画修正幅のキャンセル閾値（E6-08・E6-09）。`crossed` はモデル自身が算出した
    # `cancel_s1 > 0` を用いる（`plan_rev_s1` の再計算と整合させるため）。
    capex_plan_s1 = _capex_series(run, :capex_plan_s1)
    cancel_s1 = _capex_series(run, :cancel_s1)
    for idx in 1:n
        t = run.periods[idx]
        plan_lag1 = _capex_prev_lag1(run, :capex_plan_s1, idx)
        denom = max(plan_lag1, eps)
        plan_rev = (capex_plan_s1[idx] - plan_lag1) / denom
        qty = -plan_rev
        isfinite(qty) || continue
        thr = p.bh_cancel_thresh
        prox = abs(qty - thr) / max(abs(thr), eps)
        crossed = isfinite(cancel_s1[idx]) && cancel_s1[idx] > 0.0
        if prox <= band || crossed
            push!(
                entries,
                (
                    id = Symbol("NL-1"),
                    period = t,
                    sector = :s1,
                    proximity = prox,
                    crossed = crossed,
                ),
            )
        end
    end

    # NL-2: 目標在庫比率超での減産（E9-07）
    for s in (:s2, :s3)
        thr = getproperty(p, Symbol("bh_inv_thresh_$s"))
        binding = run.binding[Symbol("inv_threshold_binding_$s")]
        for idx in 1:n
            qty = _capex_prev_lag1(run, Symbol("inv_ratio_$s"), idx)
            isfinite(qty) || continue
            prox = abs(qty - thr) / max(abs(thr), eps)
            crossed = binding[idx]
            if prox <= band || crossed
                push!(
                    entries,
                    (
                        id = Symbol("NL-2"),
                        period = run.periods[idx],
                        sector = s,
                        proximity = prox,
                        crossed = crossed,
                    ),
                )
            end
        end
    end

    # NL-3: カバレッジ閾値でのスプレッド急拡大（E5-04）
    thr3 = p.bh_cov_threshold
    for idx in 1:n
        qty = _capex_prev_lag1(run, :coverage_agg, idx)
        isfinite(qty) || continue
        prox = abs(qty - thr3) / max(abs(thr3), eps)
        crossed = qty < thr3
        if prox <= band || crossed
            push!(
                entries,
                (
                    id = Symbol("NL-3"),
                    period = run.periods[idx],
                    sector = :cross,
                    proximity = prox,
                    crossed = crossed,
                ),
            )
        end
    end

    # NL-4: LTV上限での借換条件悪化（E5-07）
    collateral = _capex_series(run, :collateral)
    rollover = _capex_series(run, :rollover)
    thr4 = p.pl_ltv
    for idx in 1:n
        debt_sum =
            _capex_prev_state(run, :debt_s1, idx) +
            _capex_prev_state(run, :debt_s2, idx) +
            _capex_prev_state(run, :debt_s3, idx)
        col = collateral[idx]
        (isfinite(col) && col > eps) || continue
        qty = debt_sum / col
        prox = abs(qty - thr4) / max(abs(thr4), eps)
        crossed = isfinite(rollover[idx]) && rollover[idx] < 1.0
        if prox <= band || crossed
            push!(
                entries,
                (
                    id = Symbol("NL-4"),
                    period = run.periods[idx],
                    sector = :cross,
                    proximity = prox,
                    crossed = crossed,
                ),
            )
        end
    end

    # NL-5: 借換条件閾値での投資延期（E7-15）
    thr5 = p.bh_roll_thresh
    for idx in 1:n
        qty = rollover[idx]
        isfinite(qty) || continue
        prox = abs(qty - thr5) / max(abs(thr5), eps)
        crossed = qty < thr5
        if prox <= band || crossed
            push!(
                entries,
                (
                    id = Symbol("NL-5"),
                    period = run.periods[idx],
                    sector = :s1,
                    proximity = prox,
                    crossed = crossed,
                ),
            )
        end
    end

    # NL-6: 労働退蔵のデッドバンド（E10-05・E10-06）
    for s in (:s1, :s2, :s3, :s5)
        thr6 = getproperty(p, Symbol("bh_emp_band_$s"))
        for idx in 1:n
            emp_req = _capex_emp_req(m, run, s, idx)
            emp_lag1 = _capex_prev_lag1(run, Symbol("emp_$s"), idx)
            (isfinite(emp_req) && isfinite(emp_lag1) && abs(emp_lag1) > eps) || continue
            gap = emp_req - emp_lag1
            qty = abs(gap) / abs(emp_lag1)
            prox = abs(qty - thr6) / max(abs(thr6), eps)
            crossed = qty > thr6
            if prox <= band || crossed
                push!(
                    entries,
                    (
                        id = Symbol("NL-6"),
                        period = run.periods[idx],
                        sector = s,
                        proximity = prox,
                        crossed = crossed,
                    ),
                )
            end
        end
    end

    # NL-7: 能力・在庫上限の飽和（E9-08・E9-10・E9-18）。稼働率 util_s と bh_util_max_s の近傍。
    for s in (:s1, :s2, :s3)
        thr7 = getproperty(p, Symbol("bh_util_max_$s"))
        binding = run.binding[Symbol("capacity_binding_$s")]
        util = _capex_series(run, Symbol("util_$s"))
        for idx in 1:n
            qty = util[idx]
            isfinite(qty) || continue
            prox = abs(qty - thr7) / max(abs(thr7), eps)
            crossed = binding[idx]
            if prox <= band || crossed
                push!(
                    entries,
                    (
                        id = Symbol("NL-7"),
                        period = run.periods[idx],
                        sector = s,
                        proximity = prox,
                        crossed = crossed,
                    ),
                )
            end
        end
    end

    return entries
end

"""
    _capex_emp_req(m, run, s, idx) -> Float64

労働需要 `emp_req_s`（動学方程式 §10.1、`E10-01`–`E10-04`）を `run.series`/`run.state0` から
再計算する。`emp_req_s` はモデルの出力変数として保持されない中間量である。
"""
function _capex_emp_req(
    m::CapexCreditCycleModel,
    run::CapexCreditCycleRun,
    s::Symbol,
    idx::Int,
)
    p = m.params
    if s === :s1
        return _capex_prev_lag1(run, :y_s1, idx) / p.st_lprod_s1
    elseif s === :s2
        return _capex_prev_lag1(run, :y_s2, idx) / p.st_lprod_s2
    elseif s === :s3
        y_s3_lag1 = _capex_prev_lag1(run, :y_s3, idx)
        price_s3_lag1 = _capex_prev_lag1(run, :price_s3, idx)
        capex_exec_s1 = _capex_series(run, :capex_exec_s1)[idx]
        capex_act_s3 =
            p.st_capex_share_s3 * capex_exec_s1 / max(price_s3_lag1, p.st_price_min_s3)
        return (
            (1 - p.st_cshare_s3) * y_s3_lag1 +
            p.st_cshare_s3 * capex_act_s3 / p.st_capfrac_s3
        ) / p.st_lprod_s3
    else # :s5
        return _capex_prev_lag1(run, :y_s5, idx) / p.st_lprod_s5
    end
end

# ------------------------------------------------------------
# ループ作動フラグ・整合確認（動学方程式 §16.2・§16.9）
# ------------------------------------------------------------

"""`active(R1a)`–`active(R4)`（`E16-04`）。可能な限り `run.binding`（T1 constraint フラグ）を
再利用し、独自の再判定を避ける。"""
function _capex_loop_active(m::CapexCreditCycleModel, run::CapexCreditCycleRun)
    p = m.params
    r1a = any(run.binding[:capacity_binding_s1])
    r1b =
        any(run.binding[:supply_binding_s2]) ||
        any(run.binding[:supply_binding_s3]) ||
        any(run.binding[:inv_threshold_binding_s2]) ||
        any(run.binding[:inv_threshold_binding_s3])

    n = length(run.periods)
    r2 = any(
        isfinite(_capex_prev_lag1(run, :coverage_agg, idx)) &&
            _capex_prev_lag1(run, :coverage_agg, idx) < p.bh_cov_threshold for
        idx in 1:n
    )
    rollover = _capex_series(run, :rollover)
    r3 = any(isfinite(v) && v < 1.0 for v in rollover)

    r4 = false
    for s in (:s1, :s2, :s3, :s5)
        band = getproperty(p, Symbol("bh_emp_band_$s"))
        for idx in 1:n
            emp_req = _capex_emp_req(m, run, s, idx)
            emp_lag1 = _capex_prev_lag1(run, Symbol("emp_$s"), idx)
            (
                isfinite(emp_req) &&
                isfinite(emp_lag1) &&
                abs(emp_lag1) > run.options.div_eps
            ) || continue
            if abs(emp_req - emp_lag1) > band * abs(emp_lag1)
                r4 = true
                break
            end
        end
        r4 && break
    end

    return Dict(:R1a => r1a, :R1b => r1b, :R2 => r2, :R3 => r3, :R4 => r4)
end

"""
    _capex_label_loop_mismatch(label, loop_active) -> Bool

動学方程式 §16.9 の期待されるループ作動状態とラベルの整合を確認する。ラベルは変更せず、
不整合のみを報告する。
"""
function _capex_label_loop_mismatch(label::Symbol, loop_active::Dict{Symbol, Bool})
    r1 = loop_active[:R1a] || loop_active[:R1b]
    r2or3 = loop_active[:R2] || loop_active[:R3]
    r4 = loop_active[:R4]
    if label === :contained_adjustment
        return !r1 || r2or3 || r4
    elseif label === :sectoral_downturn
        return !r1 || !r2or3 || r4
    elseif label === :broad_downturn
        return !r1 || !r2or3 || !r4
    else # :indeterminate — ループ作動状態からラベルを推論しない（契約）
        return false
    end
end

# ------------------------------------------------------------
# g_short（短絡ループの利得、閉形式 E16-05）
# ------------------------------------------------------------

"""
    _capex_short_circuit_gain(m, run) -> Vector{Float64}

`R2` 短絡ループ（`SPREAD → INT_BURDEN_s → COVERAGE_s → SPREAD`）の1周利得 `g_short`
（動学方程式 `E16-05`、閉形式）を各期について計算する。`coverage_agg[t−1]` が定義できない
（無借金等）期は `NaN`。
"""
function _capex_short_circuit_gain(m::CapexCreditCycleModel, run::CapexCreditCycleRun)
    p = m.params
    n = length(run.periods)
    g = fill(NaN, n)
    for idx in 1:n
        cov_lag1 = _capex_prev_lag1(run, :coverage_agg, idx)
        int_burden_sum =
            _capex_prev_lag1(run, :int_burden_s1, idx) +
            _capex_prev_lag1(run, :int_burden_s2, idx) +
            _capex_prev_lag1(run, :int_burden_s3, idx)
        (
            isfinite(cov_lag1) &&
            isfinite(int_burden_sum) &&
            abs(int_burden_sum) > run.options.div_eps
        ) || continue

        d_spread_d_cov =
            -p.bh_spread_cov *
            p.bh_spread_pow *
            max(0.0, p.bh_cov_threshold - cov_lag1)^(p.bh_spread_pow - 1)
        d_cov_d_intburden = -cov_lag1 / int_burden_sum

        total = 0.0
        for s in (:s1, :s2, :s3)
            debt_lag1 = _capex_prev_state(run, Symbol("debt_$s"), idx)
            maturity = getproperty(p, Symbol("st_maturity_$s"))
            phi = 0.25 / maturity
            d_intburden_d_spread = phi * debt_lag1 / 1.0e4
            total += d_intburden_d_spread * d_cov_d_intburden
        end
        g[idx] = total * d_spread_d_cov
    end
    return g
end

# ------------------------------------------------------------
# spectral_radius（数値ヤコビアン、動学方程式 `E16-01`/`E16-02`）
# ------------------------------------------------------------

"""期 `idx` に実現した期首状態（70次元）を `run.state0`/`run.series` から再構成する。"""
function _capex_state_entering(run::CapexCreditCycleRun, idx::Int)
    st = _CCCState()
    for sym in _CCC_STATE_BASE
        st[sym] =
            idx == 1 ? Float64(getproperty(run.state0, sym)) :
            Float64(getproperty(run.series, sym)[idx - 1])
    end
    for base in _CCC_LAG1_BASE
        st[Symbol(string(base) * "_lag1")] = _capex_prev_lag1(run, base, idx)
    end
    for base in _CCC_LAG3_BASE
        v = getproperty(run.series, base)
        for k in 1:3
            key = Symbol(string(base) * "_lag" * string(k))
            src_idx = idx - k
            st[key] =
                src_idx >= 1 ? Float64(v[src_idx]) : Float64(getproperty(run.state0, key))
        end
    end
    return st
end

"""1期分の内部処理（ステップ2–9）を適用する写像 `f`（`E16-01` の `f`）。"""
function _capex_period_map(
    p::NamedTuple,
    opts::CapexCreditCycleOptions,
    exog_t::NamedTuple,
    st::_CCCState,
)
    pr = _CCCPeriod()
    for v in CAPEX_CC_EXOGENOUS_VARIABLES
        pr[v] = getproperty(exog_t, v)
    end
    binding = _CCCBinding(k => falses(1) for k in _ccc_default_binding_keys())
    _ccc_financial!(pr, st, p, opts, binding, 1)
    _ccc_plan!(pr, st, p, opts, binding, 1)
    _ccc_funding!(pr, st, p, opts, binding, 1)
    _ccc_orders!(pr, st, p, opts, binding, 1)
    _ccc_production!(pr, st, p, opts, binding, 1)
    _ccc_income!(pr, st, p, opts, binding, 1)
    _ccc_revenue!(pr, st, p, opts, binding, 1)
    _ccc_update!(pr, st, p, opts, binding, 1)
    newst = _CCCState()
    _ccc_shift_state!(newst, pr, st)
    return newst
end

"""
    _capex_spectral_radius(m, run, idx, jac_h) -> Float64

期 `idx` に実現した期首状態における数値ヤコビアン（前進差分）のスペクトル半径 `ρ_t`
（`E16-01`・`E16-02`）。非有限な期首状態・写像結果に対しては `NaN` を返す。
"""
function _capex_spectral_radius(
    m::CapexCreditCycleModel,
    run::CapexCreditCycleRun,
    idx::Int,
    jac_h::Float64,
)
    st = _capex_state_entering(run, idx)
    all(isfinite, values(st)) || return NaN

    order = _ccc_state_variables()
    nvar = length(order)
    exog_t = NamedTuple{CAPEX_CC_EXOGENOUS_VARIABLES}(
        Tuple(run.exog[v][idx] for v in CAPEX_CC_EXOGENOUS_VARIABLES),
    )

    f0dict = _capex_period_map(m.params, run.options, exog_t, st)
    all(isfinite, values(f0dict)) || return NaN
    f0 = [f0dict[k] for k in order]

    J = zeros(Float64, nvar, nvar)
    for j in 1:nvar
        x0j = st[order[j]]
        h = jac_h * max(1.0, abs(x0j))
        st_pert = copy(st)
        st_pert[order[j]] = x0j + h
        fj_dict = _capex_period_map(m.params, run.options, exog_t, st_pert)
        for i in 1:nvar
            J[i, j] = (fj_dict[order[i]] - f0[i]) / h
        end
    end
    ev = eigvals(J)
    return maximum(abs, ev)
end

# ------------------------------------------------------------
# loop_gain（反実仮想インパルス比、動学方程式 `E16-03`）
# ------------------------------------------------------------

"""`syms` の系列の和。"""
function _capex_combine(series_nt::NamedTuple, syms::Vector{Symbol})
    total = copy(getproperty(series_nt, syms[1]))
    for s in syms[2:end]
        total .+= getproperty(series_nt, s)
    end
    return total
end

"""
    _capex_cf_delta(m, run, kind, syms) -> Vector{Float64}

`kind` の反実仮想を「`run.exog`（ショックあり）」「baseline外生パス（ショックなし）」の対で
実行し、`syms` の合計系列の差分（baseline比乖離に相当）を返す（ファイル冒頭の設計判断）。
"""
function _capex_cf_delta(
    m::CapexCreditCycleModel,
    run::CapexCreditCycleRun,
    kind::Symbol,
    syms::Vector{Symbol},
)
    spec = _capex_counterfactual_spec(m, kind)
    p_cf = merge(m.params, spec.overrides)
    n = length(run.periods)
    baseline_exog = _ccc_baseline_exog(m, n)

    shocked = _capex_cf_series(m, p_cf, run.options, run.exog, spec.fixed_state)
    unshocked = _capex_cf_series(m, p_cf, run.options, baseline_exog, spec.fixed_state)

    return _capex_combine(shocked, syms) .- _capex_combine(unshocked, syms)
end

"""`|peak(dz)|`（評価期間内、`E16-03`）。有限値が無ければ `0.0`。"""
function _capex_peak_abs(dz::Vector{Float64}, periods::Vector{Int}, idxs::Vector{Int})
    peak = _capex_peak(dz, periods, idxs)
    isfinite(peak.value) || return 0.0
    return abs(peak.value)
end

"""
    _capex_loop_gain(m, run) -> Dict{Symbol,Union{Float64,Nothing}}

`gain(loop)`（`R1a`・`R1b`・`R2`・`R2_short`・`R3`・`R4`、`E16-03`）。分母（loop-off側の
`|peak(dz)|`）が0の場合は `nothing`（Q2の `indeterminate` と同型、契約 §16.2表）。
"""
function _capex_loop_gain(m::CapexCreditCycleModel, run::CapexCreditCycleRun)
    periods = run.periods
    eval_idx = _capex_eval_indices(run)
    ss = steady_state(m)
    result = Dict{Symbol, Union{Float64, Nothing}}()
    for loop_id in CAPEX_CC_LOOP_GAIN_IDS
        syms = _CAPEX_LOOP_GAIN_REPRESENTATIVE[loop_id]
        kind = _CAPEX_LOOP_GAIN_TO_CF_KIND[loop_id]

        z_full = _capex_combine(run.series, syms)
        base_full = sum(getproperty(ss, s) for s in syms)
        dz_full = _capex_abs_dev(z_full, base_full)
        peak_full = _capex_peak_abs(dz_full, periods, eval_idx)

        dz_cf = _capex_cf_delta(m, run, kind, syms)
        peak_cf = _capex_peak_abs(dz_cf, periods, eval_idx)

        result[loop_id] = peak_cf <= run.options.div_eps ? nothing : peak_full / peak_cf
    end
    return result
end

# ------------------------------------------------------------
# amplification（Q2、動学方程式 §16.5）
# ------------------------------------------------------------

const _CAPEX_Q2_REPRESENTATIVE = [:capex_exec_s1, :invest_s2, :invest_s3]

"""
    _capex_amplification(m, run, thresholds) -> Union{Float64,Nothing}

`A = |peak(dI^{full})| / |peak(dI^{credit-off})|`（分析契約 §3 Q2、`E`なし表記だが `|·|` 付き）。
"""
function _capex_amplification(m::CapexCreditCycleModel, run::CapexCreditCycleRun)
    periods = run.periods
    eval_idx = _capex_eval_indices(run)
    ss = steady_state(m)

    z_full = _capex_combine(run.series, _CAPEX_Q2_REPRESENTATIVE)
    base_full = sum(getproperty(ss, s) for s in _CAPEX_Q2_REPRESENTATIVE)
    dI_full = _capex_abs_dev(z_full, base_full)
    peak_full = _capex_peak_abs(dI_full, periods, eval_idx)

    dI_cf = _capex_cf_delta(m, run, :credit_off, _CAPEX_Q2_REPRESENTATIVE)
    peak_cf = _capex_peak_abs(dI_cf, periods, eval_idx)

    return peak_cf <= run.options.div_eps ? nothing : peak_full / peak_cf
end

# ------------------------------------------------------------
# share_C（Q3、動学方程式 §16.6）
# ------------------------------------------------------------

"""
    _capex_share_c(m, run) -> Union{Float64,Nothing}

主方式（反実仮想寄与、`E16-07`）: `share_C = (peak(dY^{full}) − peak(dY^{cons-off})) / peak(dY^{full})`。
`peak` は符号付き（分子の減算に符号が必要なため `_capex_amplification` とは異なり `abs` を取らない）。
"""
function _capex_share_c(m::CapexCreditCycleModel, run::CapexCreditCycleRun)
    periods = run.periods
    eval_idx = _capex_eval_indices(run)
    ss = steady_state(m)

    dY_full = _capex_abs_dev(_capex_series(run, :y_tot), ss.y_tot)
    peak_full = _capex_peak(dY_full, periods, eval_idx)
    isfinite(peak_full.value) && abs(peak_full.value) > run.options.div_eps ||
        return nothing

    dY_cf = _capex_cf_delta(m, run, :cons_off, [:y_tot])
    peak_cf = _capex_peak(dY_cf, periods, eval_idx)
    isfinite(peak_cf.value) || return nothing

    return (peak_full.value - peak_cf.value) / peak_full.value
end

"""
    _capex_share_c_additive(m, run) -> Union{Float64,Nothing}

補助方式（加法分解、`E16-08`）: `peak(dY)` が実現した期において、消費経路（`cons`）の
直接寄与を定常状態の価値付加係数 `μ_cons` で評価し、`dY` に対する比を返す。`μ_j` の厳密な
数値的導出（多期間・乗数込み）は #170 に委ねる（動学方程式 §16.6 表）。ここでは定常状態の
会計比率から機械的に定まる「1期・直接効果のみ」の係数を用いる。
"""
function _capex_share_c_additive(m::CapexCreditCycleModel, run::CapexCreditCycleRun)
    ss = steady_state(m)
    periods = run.periods
    eval_idx = _capex_eval_indices(run)

    dY_full = _capex_abs_dev(_capex_series(run, :y_tot), ss.y_tot)
    peak = _capex_peak(dY_full, periods, eval_idx)
    (
        isfinite(peak.value) &&
        abs(peak.value) > run.options.div_eps &&
        peak.period !== nothing
    ) || return nothing

    idx = findfirst(==(peak.period), periods)
    idx === nothing && return nothing

    share_s1_of_cons = ss.cons > run.options.div_eps ? ss.cons_s1 / ss.cons : 0.0
    mu_cons = share_s1_of_cons * m.params.st_va_share_s1 + (1 - share_s1_of_cons) * 1.0

    cons_t = _capex_series(run, :cons)[idx]
    isfinite(cons_t) || return nothing
    contribution_cons = mu_cons * (cons_t - ss.cons)

    return contribution_cons / peak.value
end

# ------------------------------------------------------------
# delayed_containment（動学方程式 `E16-09`）
# ------------------------------------------------------------

"""
    _capex_delayed_containment(m, run, thresholds) -> Bool

`contained_adjustment` と判定された場合のみ呼ばれる。評価期間を+8四半期延長して再実行し、
延長区間で Q1 (a)–(d) のいずれかが破れるかを判定する。判定ラベルへは反映しない（`E16-09`）。
"""
function _capex_delayed_containment(
    m::CapexCreditCycleModel,
    run::CapexCreditCycleRun,
    thresholds::CapexDiagnosticThresholds,
)
    opts_ext = CapexCreditCycleOptions(;
        horizon_runup = run.options.horizon_runup,
        horizon_eval = run.options.horizon_eval + 8,
        div_eps = run.options.div_eps,
        guard_max = run.options.guard_max,
        runup_tol = run.options.runup_tol,
        stop_on_sign_violation = run.options.stop_on_sign_violation,
    )
    scenario = capex_scenario(run.scenario)
    exog_ext = capex_exogenous_paths(m, scenario, opts_ext)
    run_ext = capex_run(
        m;
        scenario = run.scenario,
        exog = exog_ext,
        options = opts_ext,
        validate_accounting = false,
        diagnostics = false,
    )
    ss = steady_state(m)
    still_contained = _capex_q1_contained(run_ext, ss, thresholds)
    return !still_contained
end

# ------------------------------------------------------------
# capex_diagnostics（統合API）
# ------------------------------------------------------------

"""
    capex_diagnostics(m::CapexCreditCycleModel, run::CapexCreditCycleRun;
                       thresholds=CapexDiagnosticThresholds(),
                       accounting::Union{AccountingCheckReport,Nothing}=nothing) -> CapexDiagnostics

診断ラベル・資金繰り・ループ利得・非線形性・反実仮想を統合した [`CapexDiagnostics`](@ref) を
返す（統合設計 §6.4・動学方程式 §16）。`accounting` を与えない場合は
[`validate_capex_accounting`](@ref) を内部で実行する。診断は読み取り専用であり、モデル本体の
動学に影響しない。
"""
function capex_diagnostics(
    m::CapexCreditCycleModel,
    run::CapexCreditCycleRun;
    thresholds::CapexDiagnosticThresholds = CapexDiagnosticThresholds(),
    accounting::Union{AccountingCheckReport, Nothing} = nothing,
)
    ss = steady_state(m)
    accounting_report =
        accounting === nothing ? validate_capex_accounting(m, run) : accounting

    label_result = _capex_label(run, ss, thresholds)
    breadth_peak = label_result.breadth_peak
    breadth_excl_series = _capex_breadth_series(run, ss, thresholds; excl_s1 = true)
    breadth_excl_peak =
        label_result.peak_breadth_idx === nothing ? 0.0 :
        breadth_excl_series[label_result.peak_breadth_idx]

    deteriorated = Symbol[]
    if label_result.peak_breadth_idx !== nothing
        eps = run.options.div_eps
        for s in (:s1, :s2, :s3, :s5)
            dev = _capex_rel_dev(
                _capex_series(run, Symbol("y_$s")),
                getproperty(ss, Symbol("y_$s")),
                eps,
            )[label_result.peak_breadth_idx]
            isfinite(dev) && dev <= thresholds.dy_total && push!(deteriorated, s)
        end
    end

    periods = run.periods
    eval_idx = _capex_eval_indices(run)
    eps = run.options.div_eps
    peaks = Dict{String, NamedTuple}(
        "dY" => _capex_peak(
            _capex_rel_dev(_capex_series(run, :y_tot), ss.y_tot, eps),
            periods,
            eval_idx,
        ),
        "dY_s1" => _capex_peak(
            _capex_rel_dev(_capex_series(run, :y_s1), ss.y_s1, eps),
            periods,
            eval_idx,
        ),
        "dY_s2" => _capex_peak(
            _capex_rel_dev(_capex_series(run, :y_s2), ss.y_s2, eps),
            periods,
            eval_idx,
        ),
        "dY_s3" => _capex_peak(
            _capex_rel_dev(_capex_series(run, :y_s3), ss.y_s3, eps),
            periods,
            eval_idx,
        ),
        "dY_s5" => _capex_peak(
            _capex_rel_dev(_capex_series(run, :y_s5), ss.y_s5, eps),
            periods,
            eval_idx,
        ),
        "dI" => _capex_peak(
            _capex_abs_dev(
                _capex_combine(run.series, _CAPEX_Q2_REPRESENTATIVE),
                sum(getproperty(ss, s) for s in _CAPEX_Q2_REPRESENTATIVE),
            ),
            periods,
            eval_idx,
        ),
        "dL" => _capex_peak(
            _capex_rel_dev(_capex_series(run, :emp_tot), ss.emp_tot, eps),
            periods,
            eval_idx,
        ),
        "dYD" => _capex_peak(
            _capex_rel_dev(_capex_series(run, :hh_income), ss.hh_income, eps),
            periods,
            eval_idx,
        ),
        "dC" => _capex_peak(
            _capex_rel_dev(_capex_series(run, :cons), ss.cons, eps),
            periods,
            eval_idx,
        ),
        "spread" => _capex_peak(
            _capex_abs_dev(_capex_series(run, :spread), ss.spread),
            periods,
            eval_idx,
        ),
    )

    dY_for_recovery = _capex_rel_dev(_capex_series(run, :y_tot), ss.y_tot, eps)
    recovery_period = nothing
    peak_dY = peaks["dY"]
    if isfinite(peak_dY.value) &&
       peak_dY.value <= thresholds.dy_total &&
       peak_dY.period !== nothing
        peak_idx = findfirst(==(peak_dY.period), periods)
        for i in (peak_idx + 1):length(periods)
            v = dY_for_recovery[i]
            if isfinite(v) &&
               v > thresholds.dy_total &&
               all(
                   isfinite(dY_for_recovery[j]) && dY_for_recovery[j] > thresholds.dy_total
                   for j in i:length(periods)
               )
                recovery_period = periods[i]
                break
            end
        end
    end

    funding_pressure = _capex_funding_pressure(run)
    threshold_proximity = _capex_threshold_proximity(m, run, thresholds)
    loop_active = _capex_loop_active(m, run)
    label_loop_mismatch = _capex_label_loop_mismatch(label_result.label, loop_active)
    short_circuit_gain = _capex_short_circuit_gain(m, run)
    spectral_radius =
        [_capex_spectral_radius(m, run, idx, thresholds.jac_h) for idx in eval_idx]
    loop_gain = _capex_loop_gain(m, run)
    amplification = _capex_amplification(m, run)
    share_c = _capex_share_c(m, run)
    share_c_additive = _capex_share_c_additive(m, run)
    delayed_containment =
        label_result.label === :contained_adjustment ?
        _capex_delayed_containment(m, run, thresholds) : nothing

    return CapexDiagnostics(
        label_result.label,
        label_result.group_status,
        breadth_peak,
        breadth_excl_peak,
        deteriorated,
        peaks,
        recovery_period,
        funding_pressure,
        loop_active,
        loop_gain,
        spectral_radius,
        short_circuit_gain,
        threshold_proximity,
        amplification,
        share_c,
        share_c_additive,
        delayed_containment,
        label_loop_mismatch,
        accounting_report.status,
        thresholds,
    )
end

# ------------------------------------------------------------
# capex_label_sensitivity（分析契約 §4.4: 閾値±50%でのラベル併記）
# ------------------------------------------------------------

const _CAPEX_LABEL_SENSITIVITY_FIELDS =
    (:dy_total, :dy_sector, :di_sector, :dl, :dyd, :dc, :spread_bp, :breadth)

function _capex_threshold_variant(
    t::CapexDiagnosticThresholds,
    field::Symbol,
    value::Float64,
)
    kwargs = NamedTuple(f => getfield(t, f) for f in fieldnames(CapexDiagnosticThresholds))
    kwargs = merge(kwargs, NamedTuple{(field,)}((value,)))
    return CapexDiagnosticThresholds(; kwargs...)
end

"""
    capex_label_sensitivity(m, run; thresholds=CapexDiagnosticThresholds())
        -> Dict{Symbol,NamedTuple}

分析契約 §4.4「各閾値を ±50% 変化させたときのラベルを報告する」の実装。深さ・広がり閾値
（`dy_total`・`dy_sector`・`di_sector`・`dl`・`dyd`・`dc`・`spread_bp`・`breadth`）それぞれについて
`baseline`・`minus50`・`plus50` のラベルを返す。反実仮想・ヤコビアンは計算しない軽量経路
（[`_capex_label`](@ref)）のみを用いる。
"""
function capex_label_sensitivity(
    m::CapexCreditCycleModel,
    run::CapexCreditCycleRun;
    thresholds::CapexDiagnosticThresholds = CapexDiagnosticThresholds(),
)
    ss = steady_state(m)
    baseline_label = _capex_label(run, ss, thresholds).label
    result = Dict{Symbol, NamedTuple}()
    for field in _CAPEX_LABEL_SENSITIVITY_FIELDS
        v = getfield(thresholds, field)
        minus = _capex_threshold_variant(thresholds, field, v * 0.5)
        plus = _capex_threshold_variant(thresholds, field, v * 1.5)
        label_minus = _capex_label(run, ss, minus).label
        label_plus = _capex_label(run, ss, plus).label
        result[field] =
            (baseline = baseline_label, minus50 = label_minus, plus50 = label_plus)
    end
    return result
end
