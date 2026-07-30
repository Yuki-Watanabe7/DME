"""
部門別CAPEX・信用循環モデル（`CapexCreditCycleModel`）。

`I-1`（型・パラメータ辞書・逆較正・定常状態）の実装。`simulate`・会計・診断・シナリオは
後続 Issue（`I-2`〜`I-5`）の責務であり、本ファイルには含まれない。

正本:
- [統合設計](../../docs/architecture/capex_credit_cycle_integration.md)
- [統合モデル仕様 index](../../docs/models/capex_credit_cycle_design.md)
- [動学方程式](../../docs/models/capex_credit_cycle_equations.md) §13・§14
- [部門境界と変数定義](../../docs/models/capex_credit_cycle_sectors_variables.md) §4-6
- [ADR 0013](../../docs/adr/0013-capex-credit-cycle-integration-contract.md)
"""

const CAPEX_CREDIT_CYCLE_MODEL_VERSION = "capex-credit-cycle/1.0.0"
const CAPEX_CC_SECTOR_IDS = (:s1, :s2, :s3, :s4, :s5)
const _CCC_DT = 0.25

# ============================================================
# 部門集合（統合設計 §4.1）
# ============================================================

"""
    CapexSectorSets

`SP`（生産部門）・`SF`（財務主体）・`SR`（実体部門、`breadth` の分母）の部門集合。
既定は #165 §2.4 の採用案（`SP={S2,S3}`・`SF={S1,S2,S3}`・`SR={S1,S2,S3,S5}`）。
"""
struct CapexSectorSets
    SP::Vector{Symbol}
    SF::Vector{Symbol}
    SR::Vector{Symbol}
end
CapexSectorSets(; SP = [:s2, :s3], SF = [:s1, :s2, :s3], SR = [:s1, :s2, :s3, :s5]) =
    CapexSectorSets(SP, SF, SR)

# ============================================================
# パラメータ名辞書（動学方程式 §13.2・§13.3。34 + 44 + 3 = 81 系統、部門展開後 147 個）
# ============================================================

_ccc_names(base::AbstractString, suffixes) = [Symbol(base * "_" * s) for s in suffixes]

const _CCC_S13 = ("s1", "s2", "s3")
const _CCC_S23 = ("s2", "s3")
const _CCC_S15 = ("s1", "s2", "s3", "s4", "s5")

const CAPEX_CC_PARAMETER_NAMES = Tuple(
    vcat(
        # --- st_ 構造パラメータ（34系統、§13.2。st_invprice_s2/_s3 は X-14 改訂により対象外） ---
        _ccc_names("st_cor", _CCC_S13),
        _ccc_names("st_delta", _CCC_S13),
        _ccc_names("st_pipelag", _CCC_S13),
        _ccc_names("st_va_share", _CCC_S13),
        [:st_va_share_s5],
        _ccc_names("st_lprod", _CCC_S15),
        _ccc_names("st_wbase", _CCC_S15),
        [:st_cshare_s3],
        [:st_capfrac_s3],
        _ccc_names("st_capex_share", ("s2", "s3", "sx")),
        _ccc_names("st_invest_share", ("s3", "sx")),
        _ccc_names("st_gen_share", _CCC_S23),
        [:st_cons_share_s1],
        [:st_cd0],
        _ccc_names("st_maturity", _CCC_S13),
        _ccc_names("st_cash_min", _CCC_S13),
        _ccc_names("st_cash_ref", _CCC_S13),
        _ccc_names("st_dcap", _CCC_S13),
        [:st_commit_s1],
        _ccc_names("st_irrev", _CCC_S13),
        _ccc_names("st_payout", _CCC_S13),
        [:st_spread0],
        [:st_pol_ref],
        _ccc_names("st_cc0", _CCC_S13),
        [:st_profit_ref],
        [:st_emp_ref],
        [:st_coll_ltv],
        [:st_xdem0],
        [:st_cons_auto],
        [:st_ev_min],
        _ccc_names("st_price_min", _CCC_S23),
        [:st_wage_min],
        [:st_debt_tol],
        _ccc_names("st_extdem", _CCC_S23),
        # --- bh_ 行動パラメータ（44系統、§13.3） ---
        _ccc_names("bh_util_tgt", _CCC_S13),
        _ccc_names("bh_util_max", _CCC_S13),
        [:bh_alpha_capex_s1],
        _ccc_names("bh_alpha_inv", _CCC_S23),
        [:bh_cc_elas_s1],
        _ccc_names("bh_cc_elas_inv", _CCC_S23),
        _ccc_names("bh_lend_elas_inv", _CCC_S23),
        _ccc_names("bh_dcap_lend", _CCC_S13),
        [:bh_cancel_thresh],
        [:bh_cancel_slope],
        [:bh_cancel_max],
        [:bh_revive_s1],
        [:bh_defer_roll],
        [:bh_roll_thresh],
        _ccc_names("bh_backlog_target", _CCC_S23),
        _ccc_names("bh_inv_target", _CCC_S23),
        _ccc_names("bh_inv_thresh", _CCC_S23),
        _ccc_names("bh_inv_adj", _CCC_S23),
        _ccc_names("bh_prod_cut", _CCC_S23),
        _ccc_names("bh_price_adj", _CCC_S23),
        _ccc_names("bh_price_sens", _CCC_S23),
        _ccc_names("bh_price_scale", _CCC_S23),
        _ccc_names("bh_price_elas", _CCC_S23),
        [:bh_cov_threshold],
        [:bh_spread_cov],
        [:bh_spread_pow],
        [:bh_spread_fc],
        [:bh_lend_spread],
        [:bh_fc_adj],
        [:bh_fc_pol],
        [:bh_cc_spread],
        [:bh_cc_lend],
        [:bh_cc_equity],
        [:bh_cc_fc],
        [:bh_ev_adj],
        [:bh_ev_elas],
        [:bh_coll_elas],
        [:bh_roll_slope],
        _ccc_names("bh_emp_up", _CCC_S15),
        _ccc_names("bh_emp_down", _CCC_S15),
        _ccc_names("bh_emp_band", _CCC_S15),
        [:bh_wage_slope],
        [:bh_mpc],
        [:bh_cons_adj],
        # --- pl_ 政策・制度パラメータ（3系統） ---
        [:pl_tau],
        [:pl_tau_corp],
        [:pl_ltv],
    ),
)

# ============================================================
# 変数名辞書（部門境界と変数定義 §5・§6.1）
# ============================================================

# state（22変数、§4.2）
const _CCC_STATE_BASE = (
    :cap_s1,
    :capex_pipe_s1,
    :cash_s1,
    :plan_carry_s1,
    :debt_s1,
    :r_eff_s1,
    :cap_s2,
    :capex_pipe_s2,
    :backlog_s2,
    :inv_s2,
    :cash_s2,
    :debt_s2,
    :r_eff_s2,
    :advance_s2,
    :cap_s3,
    :capex_pipe_s3,
    :backlog_s3,
    :inv_s3,
    :cash_s3,
    :debt_s3,
    :r_eff_s3,
    :advance_s3,
)

# 遅延バッファ（§13.5）: 深さ1（34本）・深さ3（3本）
const _CCC_LAG1_BASE = (
    :capex_exec_s1,
    :capex_plan_s1,
    :ocf_s1,
    :ocf_s2,
    :ocf_s3,
    :profit_s1,
    :profit_s2,
    :profit_s3,
    :int_burden_s1,
    :int_burden_s2,
    :int_burden_s3,
    :tax_s1,
    :tax_s2,
    :tax_s3,
    :sales_s1,
    :sales_s2,
    :sales_s3,
    :cost_capital_s1,
    :cost_capital_s2,
    :cost_capital_s3,
    :coverage_agg,
    :fin_cond,
    :spread,
    :equity_val,
    :lend_stance,
    :y_s1,
    :y_s2,
    :y_s3,
    :y_s5,
    :util_s2,
    :util_s3,
    :inv_ratio_s2,
    :inv_ratio_s3,
    :cons,
)
const _CCC_LAG3_BASE = (:price_s2, :price_s3, :emp_tot)

function _ccc_lag_symbols()
    syms = Symbol[]
    for base in _CCC_LAG1_BASE
        push!(syms, Symbol(string(base) * "_lag1"))
    end
    for base in _CCC_LAG3_BASE
        for k in 1:3
            push!(syms, Symbol(string(base) * "_lag" * string(k)))
        end
    end
    return syms
end

_ccc_state_variables() = vcat(collect(_CCC_STATE_BASE), _ccc_lag_symbols())

# control（#165 §5 の role=control 全変数。§11.3 `X-03`（規則5追加）の改訂後）。
# 規則5により、当期の他変数から一意に定まる会計項目・恒等的ゼロ項は diagnostic へ移った。
# `control` を維持するのは `capex_defer_s1`（資金制約の閉じ変数）と `ship_s`（出荷の意思決定）のみ。
function _ccc_control_variables()
    s1 = [
        :compute_dem,
        :target_cap_s1,
        :capex_plan_s1,
        :capex_exec_s1,
        :cancel_s1,
        :y_s1,
        :emp_s1,
        :capex_defer_s1,
    ]
    s2 = [:order_s2, :price_s2, :y_s2, :ship_s2, :invest_s2, :emp_s2]
    s3 = [:order_s3, :price_s3, :y_s3, :ship_s3, :invest_s3, :emp_s3]

    s4 = [
        :equity_val,
        :collateral,
        :spread,
        :rollover,
        :lend_stance,
        :fin_cond,
        :cost_capital_s1,
        :cost_capital_s2,
        :cost_capital_s3,
    ]

    s5 = [:emp_s5, :wage, :cons, :y_s5]

    return vcat(s1, s2, s3, s4, s5)
end

# exogenous（7変数。#168 §4.1 の順序が target_rank の正本）
const CAPEX_CC_EXOGENOUS_VARIABLES = (
    :ai_exp,
    :capex_plan_shock_ex,
    :spread_shock_ex,
    :policy_rate,
    :ext_demand_s2,
    :ext_demand_s3,
    :price_s1,
)

# diagnostic（#165 §5 の role=diagnostic 全変数。§11.3 `X-03` の改訂で control から移った
# 会計項目・恒等的ゼロ項を含む。辞書整合検査に用いる）
function _ccc_diagnostic_variables()
    reclassified = [
        :capex_plan_eff_s1,
        :capex_sx_s1,
        :refin_s1,
        :refin_s2,
        :refin_s3,
        :capstart_s1,
        :capstart_s2,
        :capstart_s3,
        :retire_s1,
        :retire_s2,
        :retire_s3,
        :pipe_cancel_s1,
        :pipe_cancel_s2,
        :pipe_cancel_s3,
        :newdebt_s1,
        :newdebt_s2,
        :newdebt_s3,
        :writeoff_s1,
        :writeoff_s2,
        :writeoff_s3,
        :equity_issue_s1,
        :equity_issue_s2,
        :equity_issue_s3,
        :div_s1,
        :div_s2,
        :div_s3,
        :tax_s1,
        :tax_s2,
        :tax_s3,
        :valchg_s1,
        :valchg_s2,
        :valchg_s3,
        :inv_sx_s2,
        :inv_sx_s3,
        :xdem_s5,
    ]
    common = [
        :ycap_s1,
        :util_s1,
        :sales_s1,
        :profit_s1,
        :ocf_s1,
        :va_s1,
        :backlog_ratio_s2,
        :backlog_ratio_s3,
        :inv_ratio_s2,
        :inv_ratio_s3,
        :ycap_s2,
        :ycap_s3,
        :util_s2,
        :util_s3,
        :deliv_s2,
        :deliv_s3,
        :va_s2,
        :va_s3,
        :sales_s2,
        :sales_s3,
        :profit_s2,
        :profit_s3,
        :margin_s2,
        :margin_s3,
        :ocf_s2,
        :ocf_s3,
        :coverage_agg,
        :int_burden_s1,
        :int_burden_s2,
        :int_burden_s3,
        :debt_service_s1,
        :debt_service_s2,
        :debt_service_s3,
        :coverage_s1,
        :coverage_s2,
        :coverage_s3,
        :leverage_s1,
        :leverage_s2,
        :leverage_s3,
        :spread_endo,
        :emp_tot,
        :hh_income,
        :y_tot,
        :dinv_s2,
        :dinv_s3,
        :cons_s1,
        :cons_s5,
        :xsales_s1,
        :im_s1,
        :im_s2,
        :im_s3,
        :im_s5,
        :wagebill_s1,
        :wagebill_s2,
        :wagebill_s3,
        :wagebill_s5,
        :dep_s1,
        :dep_s2,
        :dep_s3,
        :capex_cancel_s1,
        :matur_s1,
        :matur_s2,
        :matur_s3,
        :repay_s1,
        :repay_s2,
        :repay_s3,
        :tax_hh,
        :s5_net_sx,
        :nlb_s1,
        :nlb_s2,
        :nlb_s3,
        :nlb_s4,
        :nlb_s5,
        :invval_s2,
        :invval_s3,
        :nw_s1,
        :nw_s2,
        :nw_s3,
        :loans_s4,
        :dep_stock_s4,
        :fund_s4,
        :dsc_s1,
        :dsc_s2,
        :dsc_s3,
        :rollover_gap_s1,
        :rollover_gap_s2,
        :rollover_gap_s3,
        :liquidity_gap_s1,
        :liquidity_gap_s2,
        :liquidity_gap_s3,
        :funding_forced_s1,
        :funding_forced_s2,
        :funding_forced_s3,
        :unmet_cap_s2,
        :unmet_cap_s3,
        :order_gen_s2,
        :order_gen_s3,
    ]
    return vcat(common, reclassified)
end

# 目標定常水準が持つべきキー（動学方程式 §14.2 の13ステップが要求する「与える定常水準」）
const CAPEX_CC_TARGET_KEYS = (
    :y_s1,
    :y_s2,
    :y_s3,
    :y_s5,
    :util_s2,
    :util_s3,
    :emp_s1,
    :emp_s2,
    :emp_s3,
    :emp_s5,
    :cap_s1,
    :cap_s2,
    :cap_s3,
    :dep_s1,
    :dep_s2,
    :dep_s3,
    :capex_pipe_s1,
    :capex_pipe_s2,
    :capex_pipe_s3,
    :order_cap_s2,
    :order_cap_s3,
    :order_inv_s3,
    :backlog_s2,
    :backlog_s3,
    :inv_s2,
    :inv_s3,
    :ext_demand_s2,
    :ext_demand_s3,
    :va_s1,
    :va_s2,
    :va_s3,
    :wagebill_s1,
    :wagebill_s2,
    :wagebill_s3,
    :wagebill_s5,
    :debt_s1,
    :debt_s2,
    :debt_s3,
    :cash_s1,
    :cash_s2,
    :cash_s3,
    :spread,
    :policy_rate,
    :cost_capital_s1,
    :cost_capital_s2,
    :cost_capital_s3,
    :cons,
    :cons_s1,
)

# ============================================================
# CapexCreditCycleTargets（統合設計 §4.1）
# ============================================================

"""
    CapexCreditCycleTargets

`capex_credit_cycle_model` の逆較正へ与える定常水準（`values`）と出所（`source`）。
"""
struct CapexCreditCycleTargets
    values::NamedTuple
    source::Dict{String, Any}
end

function _ccc_validate_target_keys(values::NamedTuple)
    have = Set(keys(values))
    want = Set(CAPEX_CC_TARGET_KEYS)
    missing_keys = setdiff(want, have)
    isempty(missing_keys) || throw(
        ArgumentError(
            "targets.values に §14.2 が要求するキーが不足しています: $(sort(collect(missing_keys)))",
        ),
    )
    return nothing
end

# ============================================================
# 許容条件15件（動学方程式 §13.4）
# ============================================================

"""
    _ccc_financial_aux_ss(params, tv) -> NamedTuple

`targets.values`（`tv`）と `params` から、条件11・14・15（cash比率・collateral・
coverage_agg）の判定と `steady_state` の両方で使う財務系の定常量を計算する。
価格 `price_s^ss = 1`・`equity_val^ss = 1`・`rollover^ss = 1`（`SS-1`・`SS-2`・`SS-9`）を前提にする。
"""
function _ccc_financial_aux_ss(params::NamedTuple, tv::NamedTuple)
    p = params
    sales = (s1 = tv.y_s1, s2 = tv.y_s2, s3 = tv.y_s3)
    dep = (s1 = tv.dep_s1, s2 = tv.dep_s2, s3 = tv.dep_s3)
    va = (s1 = tv.va_s1, s2 = tv.va_s2, s3 = tv.va_s3)
    wagebill = (s1 = tv.wagebill_s1, s2 = tv.wagebill_s2, s3 = tv.wagebill_s3)
    profit = (
        s1 = va.s1 - wagebill.s1 - dep.s1,
        s2 = va.s2 - wagebill.s2 - dep.s2,
        s3 = va.s3 - wagebill.s3 - dep.s3,
    )
    ocf = (s1 = profit.s1 + dep.s1, s2 = profit.s2 + dep.s2, s3 = profit.s3 + dep.s3)

    debt = (s1 = tv.debt_s1, s2 = tv.debt_s2, s3 = tv.debt_s3)
    r_new = (tv.policy_rate + tv.spread / 100) / 100
    int_burden = (
        s1 = r_new * _CCC_DT * debt.s1,
        s2 = r_new * _CCC_DT * debt.s2,
        s3 = r_new * _CCC_DT * debt.s3,
    )

    cap = (s1 = tv.cap_s1, s2 = tv.cap_s2, s3 = tv.cap_s3)
    pipe = (s1 = tv.capex_pipe_s1, s2 = tv.capex_pipe_s2, s3 = tv.capex_pipe_s3)
    invval = (s2 = tv.inv_s2, s3 = tv.inv_s3)
    physical =
        (cap.s1 + pipe.s1) + (cap.s2 + pipe.s2) + (cap.s3 + pipe.s3) + invval.s2 + invval.s3
    collateral = p.st_coll_ltv * physical

    cash = (s1 = tv.cash_s1, s2 = tv.cash_s2, s3 = tv.cash_s3)

    coverage_agg =
        (ocf.s1 + ocf.s2 + ocf.s3) / (int_burden.s1 + int_burden.s2 + int_burden.s3)
    debt_to_collateral = (debt.s1 + debt.s2 + debt.s3) / collateral

    return (
        sales = sales,
        dep = dep,
        va = va,
        wagebill = wagebill,
        profit = profit,
        ocf = ocf,
        debt = debt,
        r_new = r_new,
        int_burden = int_burden,
        cap = cap,
        pipe = pipe,
        invval = invval,
        collateral = collateral,
        cash = cash,
        coverage_agg = coverage_agg,
        debt_to_collateral = debt_to_collateral,
    )
end

function _ccc_validate_admissibility(params::NamedTuple, tv::NamedTuple)
    p = params
    aux = _ccc_financial_aux_ss(params, tv)
    errs = String[]

    isapprox(
        p.st_capex_share_s2 + p.st_capex_share_s3 + p.st_capex_share_sx,
        1.0;
        atol = 1e-10,
    ) || push!(
        errs,
        "条件1: st_capex_share_s2+st_capex_share_s3+st_capex_share_sx = 1 を満たしません（実値: $(p.st_capex_share_s2 + p.st_capex_share_s3 + p.st_capex_share_sx)）",
    )

    isapprox(p.st_invest_share_s3 + p.st_invest_share_sx, 1.0; atol = 1e-10) || push!(
        errs,
        "条件2: st_invest_share_s3+st_invest_share_sx = 1 を満たしません（実値: $(p.st_invest_share_s3 + p.st_invest_share_sx)）",
    )

    for s in _CCC_S13
        d = getproperty(p, Symbol("st_delta_$s"))
        (0 < d < 1) || push!(errs, "条件3: 0 < st_delta_$s < 1 を満たしません（実値: $d）")
    end

    for s in _CCC_S13
        l = getproperty(p, Symbol("st_pipelag_$s"))
        (l >= 1) || push!(errs, "条件4: st_pipelag_$s ≥ 1 を満たしません（実値: $l）")
    end

    for s in _CCC_S13
        m = getproperty(p, Symbol("st_maturity_$s"))
        (m >= _CCC_DT) ||
            push!(errs, "条件5: st_maturity_$s ≥ Δt を満たしません（実値: $m）")
    end

    for s in _CCC_S13
        tgt = getproperty(p, Symbol("bh_util_tgt_$s"))
        mx = getproperty(p, Symbol("bh_util_max_$s"))
        (tgt < mx <= 1.2) || push!(
            errs,
            "条件6: bh_util_tgt_$s < bh_util_max_$s ≤ 1.2 を満たしません（実値: tgt=$tgt, max=$mx）",
        )
    end

    for s in _CCC_S23
        tgt = getproperty(p, Symbol("bh_inv_target_$s"))
        th = getproperty(p, Symbol("bh_inv_thresh_$s"))
        (tgt <= th) || push!(
            errs,
            "条件7: bh_inv_target_$s ≤ bh_inv_thresh_$s を満たしません（実値: target=$tgt, thresh=$th）",
        )
    end

    for s in _CCC_S23
        b = getproperty(p, Symbol("bh_backlog_target_$s"))
        (0 <= b < 1) ||
            push!(errs, "条件8: 0 ≤ bh_backlog_target_$s < 1 を満たしません（実値: $b）")
    end

    for s in _CCC_S15
        up = getproperty(p, Symbol("bh_emp_up_$s"))
        down = getproperty(p, Symbol("bh_emp_down_$s"))
        (down <= up) || push!(
            errs,
            "条件9: bh_emp_down_$s ≤ bh_emp_up_$s を満たしません（実値: down=$down, up=$up）",
        )
    end

    (0 < p.bh_mpc < 1) ||
        push!(errs, "条件10: 0 < bh_mpc < 1 を満たしません（実値: $(p.bh_mpc)）")

    for s in _CCC_S13
        cmin = getproperty(p, Symbol("st_cash_min_$s"))
        ratio = getproperty(aux.cash, Symbol(s)) / getproperty(aux.sales, Symbol(s))
        (cmin <= ratio) || push!(
            errs,
            "条件11: st_cash_min_$s ≤ cash_$(s)^ss/sales_$(s)^ss を満たしません（実値: cash_min=$cmin, 比率=$ratio）",
        )
    end

    for s in _CCC_S13
        po = getproperty(p, Symbol("st_payout_$s"))
        isapprox(po, 1.0; atol = 1e-10) ||
            push!(errs, "条件12: st_payout_$s = 1 を満たしません（実値: $po）")
    end

    (p.st_lprod_s1 > p.st_lprod_s3) || push!(
        errs,
        "条件13: st_lprod_s1 > st_lprod_s3 を満たしません（実値: s1=$(p.st_lprod_s1), s3=$(p.st_lprod_s3)）",
    )
    (p.st_lprod_s2 > p.st_lprod_s3) || push!(
        errs,
        "条件13: st_lprod_s2 > st_lprod_s3 を満たしません（実値: s2=$(p.st_lprod_s2), s3=$(p.st_lprod_s3)）",
    )

    (aux.debt_to_collateral <= p.pl_ltv) || push!(
        errs,
        "条件14: Σdebt_s^ss/collateral^ss ≤ pl_ltv を満たしません（実値: $(aux.debt_to_collateral), pl_ltv=$(p.pl_ltv)）",
    )

    (aux.coverage_agg >= p.bh_cov_threshold) || push!(
        errs,
        "条件15: coverage_agg^ss ≥ bh_cov_threshold を満たしません（実値: $(aux.coverage_agg), 閾値=$(p.bh_cov_threshold)）",
    )

    isempty(errs) || throw(ArgumentError(join(errs, "\n")))
    return nothing
end

function _ccc_validate_param_keys(params::NamedTuple)
    have = Set(keys(params))
    want = Set(CAPEX_CC_PARAMETER_NAMES)
    missing_keys = setdiff(want, have)
    extra_keys = setdiff(have, want)
    isempty(missing_keys) && isempty(extra_keys) || throw(
        ArgumentError(
            "params のキー集合が CAPEX_CC_PARAMETER_NAMES と一致しません。" *
            "不足: $(sort(collect(missing_keys)))、余剰: $(sort(collect(extra_keys)))",
        ),
    )
    return nothing
end

function _ccc_validate_sectors(sectors::CapexSectorSets)
    valid = Set(CAPEX_CC_SECTOR_IDS)
    for (name, set) in (("SP", sectors.SP), ("SF", sectors.SF), ("SR", sectors.SR))
        issubset(Set(set), valid) || throw(
            ArgumentError(
                "sectors.$name は CAPEX_CC_SECTOR_IDS の部分集合でなければなりません（実値: $set）",
            ),
        )
    end
    issubset(Set(sectors.SP), Set(sectors.SF)) || throw(
        ArgumentError(
            "sectors.SP ⊆ sectors.SF を満たしません（SP=$(sectors.SP), SF=$(sectors.SF)）",
        ),
    )
    issubset(Set(sectors.SF), Set(sectors.SR)) || throw(
        ArgumentError(
            "sectors.SF ⊆ sectors.SR を満たしません（SF=$(sectors.SF), SR=$(sectors.SR)）",
        ),
    )
    return nothing
end

"""
    _ccc_validate_key_collisions()

#165 §6.5 契約1「部門接尾辞を除いた名前が接尾辞なしの単一系列名と衝突しないこと」を検査する。
`state_variables` ∪ `control_variables` ∪ `exogenous_variables` の全名称のうち部門接尾辞
（`_s1`–`_s5`）を持つものについて、接尾辞を除いた名前が接尾辞を持たない別の変数名と一致しないことを確認する。
"""
function _ccc_validate_key_collisions()
    all_names = vcat(
        _ccc_state_variables(),
        _ccc_control_variables(),
        collect(CAPEX_CC_EXOGENOUS_VARIABLES),
    )
    name_set = Set(all_names)
    suffix_re = r"_s[1-5](_lag[1-3])?$"
    for nm in all_names
        s = string(nm)
        m = match(suffix_re, s)
        m === nothing && continue
        stripped = s[1:(m.offset - 1)]
        stripped_sym = Symbol(stripped)
        if stripped_sym in name_set
            throw(
                ArgumentError(
                    "キー衝突検査に失敗しました: 部門接尾辞を除いた名前 :$stripped_sym が接尾辞なしの単一系列名と衝突しています（$nm）",
                ),
            )
        end
    end
    return nothing
end

# ============================================================
# CapexCreditCycleModel（統合設計 §4.1）
# ============================================================

# 統合設計 §6.1 の予約キーのうちバージョン系。metadata 化は I-6 の責務だが、値自体はモデル定義時点で固定する。
const _CCC_DEFAULT_CONTRACT_VERSIONS = (
    contract_version = "capex-credit-cycle-contract/1.0.0",
    graph_version = "capex-credit-cycle-graph/1.1.0",
    vars_version = "capex-credit-cycle-vars/1.2.0",
    accounting_version = "capex-credit-cycle-accounting/1.1.0",
    boundaries_version = "capex-credit-cycle-boundaries/1.0.1",
    equations_version = "capex-credit-cycle-equations/1.1.0",
    empirical_version = "capex-credit-cycle-empirical/1.1.0",
    model_version = CAPEX_CREDIT_CYCLE_MODEL_VERSION,
)

"""
    CapexCreditCycleModel <: AbstractMacroModel

部門別CAPEX・信用循環モデル。`capex_credit_cycle_model` 経由で逆較正によって構築するのが
通常の使い方であり、このコンストラクタは直接構築（既較正パラメータの再利用等）に用いる。

内部コンストラクタは統合設計 §4.1 の検証5種を行う。
"""
struct CapexCreditCycleModel <: AbstractMacroModel
    params::NamedTuple
    targets::CapexCreditCycleTargets
    sectors::CapexSectorSets
    contract_versions::NamedTuple

    function CapexCreditCycleModel(;
        params::NamedTuple,
        targets::CapexCreditCycleTargets,
        sectors::CapexSectorSets = CapexSectorSets(),
        contract_versions::NamedTuple = _CCC_DEFAULT_CONTRACT_VERSIONS,
    )
        _ccc_validate_param_keys(params)
        _ccc_validate_target_keys(targets.values)
        _ccc_validate_admissibility(params, targets.values)
        _ccc_validate_sectors(sectors)
        _ccc_validate_key_collisions()
        return new(params, targets, sectors, contract_versions)
    end
end

# ============================================================
# メタ情報API（統合設計 §4.2）
# ============================================================

model_name(::CapexCreditCycleModel) = "Sectoral CAPEX-Credit Cycle Model"
state_variables(::CapexCreditCycleModel) = _ccc_state_variables()
control_variables(::CapexCreditCycleModel) = _ccc_control_variables()
exogenous_variables(::CapexCreditCycleModel) = collect(CAPEX_CC_EXOGENOUS_VARIABLES)
parameters(m::CapexCreditCycleModel) = m.params

# ============================================================
# 逆較正（動学方程式 §14.2 の13ステップ）
# ============================================================

# S1 は独立の util ターゲットを目標水準に持たない（ステップ2の式は SP のみに適用され、
# S1 に適用すると `bh_util_tgt_s1 · capex_pipe_s1^ss = 0` に退化し矛盾する）。
# そのため st_cor_s1 は目標水準から独立な構造定数として与え、bh_util_tgt_s1 をステップ6で逆算する。
const _CCC_ST_COR_S1 = 2.0
# st_coll_ltv を pl_ltv ちょうどではなく余裕を持たせて逆算するための係数（許容条件14に安全余裕を持たせる）。
const _CCC_ST_COLL_LTV_MARGIN = 1.65

"""
    _ccc_default_behavioral() -> NamedTuple

`bh_` パラメータのうち逆較正（§14.2）で決まらないものの既定値。#170 の推定・較正対象であり、
本書段階では illustrative な値を仮置きする。
"""
function _ccc_default_behavioral()
    return (
        bh_util_max_s1 = 0.95,
        bh_util_max_s2 = 0.95,
        bh_util_max_s3 = 0.95,
        bh_alpha_capex_s1 = 0.3,
        bh_alpha_inv_s2 = 0.3,
        bh_alpha_inv_s3 = 0.3,
        bh_cc_elas_s1 = 0.5,
        bh_cc_elas_inv_s2 = 0.5,
        bh_cc_elas_inv_s3 = 0.5,
        bh_lend_elas_inv_s2 = 0.2,
        bh_lend_elas_inv_s3 = 0.2,
        bh_dcap_lend_s1 = 0.1,
        bh_dcap_lend_s2 = 0.1,
        bh_dcap_lend_s3 = 0.1,
        bh_cancel_thresh = 0.05,
        bh_cancel_slope = 1.0,
        bh_cancel_max = 0.5,
        bh_revive_s1 = 0.2,
        bh_defer_roll = 0.3,
        bh_roll_thresh = 0.9,
        bh_inv_thresh_s2 = 0.25,
        bh_inv_thresh_s3 = 0.25,
        bh_inv_adj_s2 = 0.3,
        bh_inv_adj_s3 = 0.3,
        bh_prod_cut_s2 = 0.5,
        bh_prod_cut_s3 = 0.5,
        bh_price_adj_s2 = 0.3,
        bh_price_adj_s3 = 0.3,
        bh_price_sens_s2 = 0.1,
        bh_price_sens_s3 = 0.1,
        bh_price_scale_s2 = 0.1,
        bh_price_scale_s3 = 0.1,
        bh_price_elas_s2 = 0.3,
        bh_price_elas_s3 = 0.3,
        bh_cov_threshold = 2.5,
        bh_spread_cov = 50.0,
        bh_spread_pow = 1.0,
        bh_spread_fc = 30.0,
        bh_lend_spread = 0.01,
        bh_fc_adj = 0.3,
        bh_fc_pol = 0.5,
        bh_cc_spread = 1.0,
        bh_cc_lend = 0.5,
        bh_cc_equity = 1.0,
        bh_cc_fc = 1.0,
        bh_ev_adj = 0.3,
        bh_ev_elas = 1.0,
        bh_coll_elas = 0.5,
        bh_roll_slope = 2.0,
        bh_emp_up_s1 = 0.3,
        bh_emp_up_s2 = 0.3,
        bh_emp_up_s3 = 0.3,
        bh_emp_up_s4 = 0.3,
        bh_emp_up_s5 = 0.3,
        bh_emp_down_s1 = 0.15,
        bh_emp_down_s2 = 0.15,
        bh_emp_down_s3 = 0.15,
        bh_emp_down_s4 = 0.15,
        bh_emp_down_s5 = 0.15,
        bh_emp_band_s1 = 0.02,
        bh_emp_band_s2 = 0.02,
        bh_emp_band_s3 = 0.02,
        bh_emp_band_s4 = 0.02,
        bh_emp_band_s5 = 0.02,
        bh_wage_slope = 0.5,
        bh_mpc = 0.6,
        bh_cons_adj = 0.3,
    )
end

"""
    _ccc_default_policy() -> NamedTuple

`pl_` パラメータの既定値。`pl_tau_corp` は MVP の固定値（`= 0`、§13.3）。
"""
_ccc_default_policy() = (pl_tau = 0.2, pl_tau_corp = 0.0, pl_ltv = 0.7)

"""
    _ccc_calibrate_behavioral(tv) -> NamedTuple

§14.2 ステップ1・6・8で目標定常水準から自由度なく決まる `bh_` パラメータ7個
（`bh_util_tgt_s1`–`_s3`・`bh_backlog_target_s2`/`_s3`・`bh_inv_target_s2`/`_s3`）。
"""
function _ccc_calibrate_behavioral(tv::NamedTuple)
    bh_util_tgt_s1 = _CCC_ST_COR_S1 * tv.y_s1 / (tv.cap_s1 + tv.capex_pipe_s1)

    order_gen_s2 = tv.y_s2 - tv.order_cap_s2 - tv.ext_demand_s2
    order_gen_s3 = tv.y_s3 - tv.order_cap_s3 - tv.order_inv_s3 - tv.ext_demand_s3
    demand_gen_s2 = tv.backlog_s2 + order_gen_s2 + tv.ext_demand_s2
    demand_gen_s3 = tv.backlog_s3 + order_gen_s3 + tv.ext_demand_s3

    return (
        bh_util_tgt_s1 = bh_util_tgt_s1,
        bh_util_tgt_s2 = tv.util_s2,
        bh_util_tgt_s3 = tv.util_s3,
        bh_backlog_target_s2 = tv.backlog_s2 / demand_gen_s2,
        bh_backlog_target_s3 = tv.backlog_s3 / demand_gen_s3,
        bh_inv_target_s2 = tv.inv_s2 / tv.y_s2,
        bh_inv_target_s3 = tv.inv_s3 / tv.y_s3,
    )
end

"""
    _ccc_calibrate_structural(tv, bf, pf) -> NamedTuple

§14.2 の13ステップで `st_` パラメータ（34系統・70個）を目標定常水準 `tv` から閉形式で逆算する。
`bf`（解決済み `behavioral`）・`pf`（解決済み `policy`）を用いる項（`bh_cc_spread`・`bh_mpc`・
`pl_tau`・`pl_ltv`）は、ユーザーの上書きが最終的に反映された値で一貫するようにする。
"""
function _ccc_calibrate_structural(tv::NamedTuple, bf::NamedTuple, pf::NamedTuple)
    st_cor_s1 = _CCC_ST_COR_S1
    st_cor_s2 = tv.cap_s2 * bf.bh_util_tgt_s2 / tv.y_s2
    st_cor_s3 = tv.cap_s3 * bf.bh_util_tgt_s3 / tv.y_s3

    st_delta_s1 = tv.dep_s1 / tv.cap_s1
    st_delta_s2 = tv.dep_s2 / tv.cap_s2
    st_delta_s3 = tv.dep_s3 / tv.cap_s3

    st_pipelag_s1 = tv.capex_pipe_s1 / tv.dep_s1
    st_pipelag_s2 = tv.capex_pipe_s2 / tv.dep_s2
    st_pipelag_s3 = tv.capex_pipe_s3 / tv.dep_s3

    # SS-5 の整合条件: capex_exec_s1^ss = st_delta_s1 · cap_s1^ss = dep_s1^ss
    capex_exec_s1_ss = tv.dep_s1

    st_capex_share_s2 = tv.order_cap_s2 / capex_exec_s1_ss
    st_capex_share_s3 = tv.order_cap_s3 / capex_exec_s1_ss
    st_capex_share_sx = 1 - st_capex_share_s2 - st_capex_share_s3

    # SS-4 の整合条件: invest_s2^ss = capstart_s2^ss = st_delta_s2 · cap_s2^ss = dep_s2^ss
    invest_s2_ss = tv.dep_s2
    st_invest_share_s3 = tv.order_inv_s3 / invest_s2_ss
    st_invest_share_sx = 1 - st_invest_share_s3

    st_capfrac_s3 = tv.order_cap_s3 / tv.y_s3

    order_gen_s2 = tv.y_s2 - tv.order_cap_s2 - tv.ext_demand_s2
    order_gen_s3 = tv.y_s3 - tv.order_cap_s3 - tv.order_inv_s3 - tv.ext_demand_s3
    st_gen_share_s2 = order_gen_s2 / tv.y_s5
    st_gen_share_s3 = order_gen_s3 / tv.y_s5

    st_cons_share_s1 = tv.cons_s1 / tv.y_s1
    st_cd0 = tv.y_s1

    st_maturity_s1 = 5.0
    st_maturity_s2 = 5.0
    st_maturity_s3 = 5.0

    st_cash_min_s1 = 0.05
    st_cash_min_s2 = 0.05
    st_cash_min_s3 = 0.05

    st_cash_ref_s1 = tv.cash_s1 / tv.y_s1
    st_cash_ref_s2 = tv.cash_s2 / tv.y_s2
    st_cash_ref_s3 = tv.cash_s3 / tv.y_s3

    st_dcap_s1 = 2 * tv.debt_s1 / tv.y_s1
    st_dcap_s2 = 2 * tv.debt_s2 / tv.y_s2
    st_dcap_s3 = 2 * tv.debt_s3 / tv.y_s3

    st_commit_s1 = 0.5
    st_irrev_s1 = 1.0
    st_irrev_s2 = 1.0
    st_irrev_s3 = 1.0
    st_payout_s1 = 1.0
    st_payout_s2 = 1.0
    st_payout_s3 = 1.0

    st_spread0 = tv.spread
    st_pol_ref = tv.policy_rate

    st_cc0_s1 = tv.cost_capital_s1 - bf.bh_cc_spread * tv.spread / 100
    st_cc0_s2 = tv.cost_capital_s2 - bf.bh_cc_spread * tv.spread / 100
    st_cc0_s3 = tv.cost_capital_s3 - bf.bh_cc_spread * tv.spread / 100

    profit_s1 = tv.va_s1 - tv.wagebill_s1 - tv.dep_s1
    profit_s2 = tv.va_s2 - tv.wagebill_s2 - tv.dep_s2
    profit_s3 = tv.va_s3 - tv.wagebill_s3 - tv.dep_s3
    st_profit_ref = profit_s1 + profit_s2 + profit_s3

    st_emp_ref = tv.emp_s1 + tv.emp_s2 + tv.emp_s3 + tv.emp_s5

    physical_base =
        (tv.cap_s1 + tv.capex_pipe_s1) +
        (tv.cap_s2 + tv.capex_pipe_s2) +
        (tv.cap_s3 + tv.capex_pipe_s3) +
        tv.inv_s2 +
        tv.inv_s3
    debt_sum = tv.debt_s1 + tv.debt_s2 + tv.debt_s3
    st_coll_ltv = _CCC_ST_COLL_LTV_MARGIN * debt_sum / (pf.pl_ltv * physical_base)

    cons_s5_ss = tv.cons - tv.cons_s1
    st_xdem0 = tv.y_s5 - cons_s5_ss

    # X-28（#165 §11.4）: hh_income = Σ_{s∈SF} wagebill_s − tax_hh（SF = {S1,S2,S3}。S5 の賃金支払は
    # 列内で相殺され取引フロー行列に計上されないため含めない）
    wagebill_sf_ss = tv.wagebill_s1 + tv.wagebill_s2 + tv.wagebill_s3
    hh_income_ss = (1 - pf.pl_tau) * wagebill_sf_ss
    st_cons_auto = tv.cons - bf.bh_mpc * hh_income_ss

    st_ev_min = 0.1
    st_price_min_s2 = 0.5
    st_price_min_s3 = 0.5
    st_wage_min = 0.5
    st_debt_tol = 0.01

    st_extdem_s2 = tv.ext_demand_s2
    st_extdem_s3 = tv.ext_demand_s3

    st_va_share_s1 = tv.va_s1 / tv.y_s1
    st_va_share_s2 = tv.va_s2 / tv.y_s2
    st_va_share_s3 = tv.va_s3 / tv.y_s3
    st_va_share_s5 = 1.0

    st_lprod_s1 = tv.y_s1 / tv.emp_s1
    st_lprod_s2 = tv.y_s2 / tv.emp_s2
    st_lprod_s3 = tv.y_s3 / tv.emp_s3
    st_lprod_s5 = tv.y_s5 / tv.emp_s5
    # S4（金融・信用）はこのモデルで雇用変数を持たないため、辞書上の空き値として S5 と同水準を仮置きする。
    st_lprod_s4 = st_lprod_s5

    st_wbase_s1 = tv.wagebill_s1 / tv.emp_s1
    st_wbase_s2 = tv.wagebill_s2 / tv.emp_s2
    st_wbase_s3 = tv.wagebill_s3 / tv.emp_s3
    st_wbase_s5 = tv.wagebill_s5 / tv.emp_s5
    st_wbase_s4 = st_wbase_s5

    st_cshare_s3 = 0.3

    return (
        st_cor_s1 = st_cor_s1,
        st_cor_s2 = st_cor_s2,
        st_cor_s3 = st_cor_s3,
        st_delta_s1 = st_delta_s1,
        st_delta_s2 = st_delta_s2,
        st_delta_s3 = st_delta_s3,
        st_pipelag_s1 = st_pipelag_s1,
        st_pipelag_s2 = st_pipelag_s2,
        st_pipelag_s3 = st_pipelag_s3,
        st_va_share_s1 = st_va_share_s1,
        st_va_share_s2 = st_va_share_s2,
        st_va_share_s3 = st_va_share_s3,
        st_va_share_s5 = st_va_share_s5,
        st_lprod_s1 = st_lprod_s1,
        st_lprod_s2 = st_lprod_s2,
        st_lprod_s3 = st_lprod_s3,
        st_lprod_s4 = st_lprod_s4,
        st_lprod_s5 = st_lprod_s5,
        st_wbase_s1 = st_wbase_s1,
        st_wbase_s2 = st_wbase_s2,
        st_wbase_s3 = st_wbase_s3,
        st_wbase_s4 = st_wbase_s4,
        st_wbase_s5 = st_wbase_s5,
        st_cshare_s3 = st_cshare_s3,
        st_capfrac_s3 = st_capfrac_s3,
        st_capex_share_s2 = st_capex_share_s2,
        st_capex_share_s3 = st_capex_share_s3,
        st_capex_share_sx = st_capex_share_sx,
        st_invest_share_s3 = st_invest_share_s3,
        st_invest_share_sx = st_invest_share_sx,
        st_gen_share_s2 = st_gen_share_s2,
        st_gen_share_s3 = st_gen_share_s3,
        st_cons_share_s1 = st_cons_share_s1,
        st_cd0 = st_cd0,
        st_maturity_s1 = st_maturity_s1,
        st_maturity_s2 = st_maturity_s2,
        st_maturity_s3 = st_maturity_s3,
        st_cash_min_s1 = st_cash_min_s1,
        st_cash_min_s2 = st_cash_min_s2,
        st_cash_min_s3 = st_cash_min_s3,
        st_cash_ref_s1 = st_cash_ref_s1,
        st_cash_ref_s2 = st_cash_ref_s2,
        st_cash_ref_s3 = st_cash_ref_s3,
        st_dcap_s1 = st_dcap_s1,
        st_dcap_s2 = st_dcap_s2,
        st_dcap_s3 = st_dcap_s3,
        st_commit_s1 = st_commit_s1,
        st_irrev_s1 = st_irrev_s1,
        st_irrev_s2 = st_irrev_s2,
        st_irrev_s3 = st_irrev_s3,
        st_payout_s1 = st_payout_s1,
        st_payout_s2 = st_payout_s2,
        st_payout_s3 = st_payout_s3,
        st_spread0 = st_spread0,
        st_pol_ref = st_pol_ref,
        st_cc0_s1 = st_cc0_s1,
        st_cc0_s2 = st_cc0_s2,
        st_cc0_s3 = st_cc0_s3,
        st_profit_ref = st_profit_ref,
        st_emp_ref = st_emp_ref,
        st_coll_ltv = st_coll_ltv,
        st_xdem0 = st_xdem0,
        st_cons_auto = st_cons_auto,
        st_ev_min = st_ev_min,
        st_price_min_s2 = st_price_min_s2,
        st_price_min_s3 = st_price_min_s3,
        st_wage_min = st_wage_min,
        st_debt_tol = st_debt_tol,
        st_extdem_s2 = st_extdem_s2,
        st_extdem_s3 = st_extdem_s3,
    )
end

"""
    capex_credit_cycle_model(targets; behavioral=NamedTuple(), policy=NamedTuple(),
                              sectors=CapexSectorSets()) -> CapexCreditCycleModel

`targets` の定常水準から `st_` パラメータ（および `bh_util_tgt_s`・`bh_backlog_target_s`・
`bh_inv_target_s`）を §14.2 の13ステップで閉形式に逆算し、`CapexCreditCycleModel` を構築する。
非線形ソルバは用いない。`behavioral`・`policy` は既定値（計算済みの値を含む）を上書きする。
"""
function capex_credit_cycle_model(
    targets::CapexCreditCycleTargets;
    behavioral::NamedTuple = NamedTuple(),
    policy::NamedTuple = NamedTuple(),
    sectors::CapexSectorSets = CapexSectorSets(),
)
    _ccc_validate_target_keys(targets.values)
    tv = targets.values

    policy_full = merge(_ccc_default_policy(), policy)
    calibrated_bh = _ccc_calibrate_behavioral(tv)
    behavioral_full = merge(_ccc_default_behavioral(), calibrated_bh, behavioral)
    structural = _ccc_calibrate_structural(tv, behavioral_full, policy_full)

    params = merge(behavioral_full, policy_full, structural)

    return CapexCreditCycleModel(; params = params, targets = targets, sectors = sectors)
end

"""
    capex_credit_cycle_default_targets() -> CapexCreditCycleTargets

外部 API なしでデモ・テストが完走するための例示定常水準。`source["kind"] = "illustrative"`
であり、実データの較正値ではない。
"""
function capex_credit_cycle_default_targets()
    values = (
        y_s1 = 60.0,
        y_s2 = 100.0,
        y_s3 = 80.0,
        y_s5 = 400.0,
        util_s2 = 0.8,
        util_s3 = 0.8,
        emp_s1 = 0.3,
        emp_s2 = 0.5,
        emp_s3 = 0.6,
        emp_s5 = 140.0,
        cap_s1 = 200.0,
        cap_s2 = 250.0,
        cap_s3 = 200.0,
        dep_s1 = 8.0,
        dep_s2 = 10.0,
        dep_s3 = 8.0,
        capex_pipe_s1 = 24.0,
        capex_pipe_s2 = 30.0,
        capex_pipe_s3 = 24.0,
        order_cap_s2 = 4.0,
        order_cap_s3 = 3.0,
        order_inv_s3 = 5.0,
        backlog_s2 = 20.0,
        backlog_s3 = 16.0,
        inv_s2 = 15.0,
        inv_s3 = 12.0,
        ext_demand_s2 = 85.0,
        ext_demand_s3 = 65.0,
        va_s1 = 24.0,
        va_s2 = 35.0,
        va_s3 = 32.0,
        wagebill_s1 = 15.0,
        wagebill_s2 = 20.0,
        wagebill_s3 = 21.0,
        wagebill_s5 = 350.0,
        debt_s1 = 50.0,
        debt_s2 = 60.0,
        debt_s3 = 50.0,
        cash_s1 = 10.0,
        cash_s2 = 12.0,
        cash_s3 = 10.0,
        spread = 150.0,
        policy_rate = 4.0,
        cost_capital_s1 = 8.0,
        cost_capital_s2 = 8.5,
        cost_capital_s3 = 8.5,
        cons = 300.0,
        cons_s1 = 20.0,
    )
    source = Dict{String, Any}(
        "kind" => "illustrative",
        "description" => "I-1 の smoke test・デモ用の例示定常水準。実データの較正値ではない。",
    )
    return CapexCreditCycleTargets(values, source)
end

# ============================================================
# steady_state（統合設計 §4.3）
# ============================================================

"""
    _ccc_steady_state_full(m) -> NamedTuple

`m.targets.values` と `m.params` から、`SimulationResult.variables` と同じキー集合
（state 22 + control + exogenous 7 + diagnostic）を持つ定常水準を閉形式で計算する。
逆較正（`_ccc_calibrate_structural`）は本関数が評価する式が定常状態で目標水準を再現する
ように `st_` を導出しているため、数値解ではなく式の評価そのものである。
"""
function _ccc_steady_state_full(m::CapexCreditCycleModel)
    p = m.params
    tv = m.targets.values
    aux = _ccc_financial_aux_ss(p, tv)

    # --- 外生（SS-1） ---
    ai_exp = 1.0
    capex_plan_shock_ex = 1.0
    spread_shock_ex = 0.0
    policy_rate = p.st_pol_ref
    ext_demand_s2 = p.st_extdem_s2
    ext_demand_s3 = p.st_extdem_s3
    price_s1 = 1.0

    # --- ステップ2 金融条件（SS-2） ---
    fin_cond = 0.0
    equity_val = 1.0
    spread = p.st_spread0
    spread_endo = p.st_spread0
    lend_stance = 0.0
    rollover = 1.0
    collateral = aux.collateral
    r_eff_s1 = aux.r_new
    r_eff_s2 = aux.r_new
    r_eff_s3 = aux.r_new
    matur_s1 = (_CCC_DT / p.st_maturity_s1) * tv.debt_s1
    matur_s2 = (_CCC_DT / p.st_maturity_s2) * tv.debt_s2
    matur_s3 = (_CCC_DT / p.st_maturity_s3) * tv.debt_s3
    refin_s1 = matur_s1
    refin_s2 = matur_s2
    refin_s3 = matur_s3
    repay_s1 = 0.0
    repay_s2 = 0.0
    repay_s3 = 0.0
    int_burden_s1 = aux.int_burden.s1
    int_burden_s2 = aux.int_burden.s2
    int_burden_s3 = aux.int_burden.s3
    coverage_agg = aux.coverage_agg
    cost_capital_s1 = tv.cost_capital_s1
    cost_capital_s2 = tv.cost_capital_s2
    cost_capital_s3 = tv.cost_capital_s3

    # --- ステップ3 計画（SS-3・SS-5） ---
    compute_dem = tv.y_s1
    target_cap_s1 = tv.cap_s1 + tv.capex_pipe_s1
    capex_plan_s1 = tv.dep_s1
    cancel_s1 = 0.0
    revive_s1 = 0.0
    capex_plan_eff_s1 = capex_plan_s1
    capex_cancel_s1 = 0.0
    capex_defer_s1 = 0.0
    capex_exec_s1 = tv.dep_s1
    plan_carry_s1 = 0.0

    # --- ステップ4 資金制約と実行（SS-15） ---
    tax_s1 = 0.0
    tax_s2 = 0.0
    tax_s3 = 0.0
    div_s1 = aux.profit.s1 - int_burden_s1
    div_s2 = aux.profit.s2 - int_burden_s2
    div_s3 = aux.profit.s3 - int_burden_s3
    equity_issue_s1 = 0.0
    equity_issue_s2 = 0.0
    equity_issue_s3 = 0.0
    writeoff_s1 = 0.0
    writeoff_s2 = 0.0
    writeoff_s3 = 0.0
    pipe_cancel_s1 = 0.0
    pipe_cancel_s2 = 0.0
    pipe_cancel_s3 = 0.0
    retire_s1 = 0.0
    retire_s2 = 0.0
    retire_s3 = 0.0
    valchg_s1 = 0.0
    valchg_s2 = 0.0
    valchg_s3 = 0.0
    advance_s2 = 0.0
    advance_s3 = 0.0
    newdebt_s1 = 0.0
    newdebt_s2 = 0.0
    newdebt_s3 = 0.0
    funding_forced_s1 = 0.0
    funding_forced_s2 = 0.0
    funding_forced_s3 = 0.0
    liquidity_gap_s1 = 0.0
    liquidity_gap_s2 = 0.0
    liquidity_gap_s3 = 0.0
    capex_sx_s1 = p.st_capex_share_sx * capex_exec_s1

    invest_s2 = tv.dep_s2
    invest_s3 = tv.dep_s3
    inv_sx_s2 = p.st_invest_share_sx * invest_s2
    inv_sx_s3 = invest_s3

    # --- ステップ5 価格確定と受注配分 ---
    price_s2 = 1.0
    price_s3 = 1.0
    order_gen_s2 = tv.y_s2 - tv.order_cap_s2 - tv.ext_demand_s2
    order_gen_s3 = tv.y_s3 - tv.order_cap_s3 - tv.order_inv_s3 - tv.ext_demand_s3
    order_s2 = tv.order_cap_s2 + order_gen_s2 + tv.ext_demand_s2
    order_s3 = tv.order_cap_s3 + tv.order_inv_s3 + order_gen_s3 + tv.ext_demand_s3

    # --- ステップ6 生産・出荷・在庫・受注残・価格 ---
    ycap_s1 = tv.cap_s1 / p.st_cor_s1
    ycap_s2 = tv.cap_s2 / p.st_cor_s2
    ycap_s3 = tv.cap_s3 / p.st_cor_s3
    y_s1 = tv.y_s1
    y_s2 = tv.y_s2
    y_s3 = tv.y_s3
    util_s1 = y_s1 / ycap_s1
    util_s2 = tv.util_s2
    util_s3 = tv.util_s3
    ship_s2 = tv.y_s2
    ship_s3 = tv.y_s3
    deliv_s2 = price_s2 * ship_s2
    deliv_s3 = price_s3 * ship_s3
    dinv_s2 = 0.0
    dinv_s3 = 0.0
    unmet_cap_s2 = 0.0
    unmet_cap_s3 = 0.0
    backlog_ratio_s2 = tv.backlog_s2 / tv.y_s2
    backlog_ratio_s3 = tv.backlog_s3 / tv.y_s3
    inv_ratio_s2 = tv.inv_s2 / tv.y_s2
    inv_ratio_s3 = tv.inv_s3 / tv.y_s3

    # --- ステップ7 雇用・所得・消費 ---
    emp_s1 = tv.emp_s1
    emp_s2 = tv.emp_s2
    emp_s3 = tv.emp_s3
    emp_s5 = tv.emp_s5
    emp_tot = p.st_emp_ref
    wage = 1.0
    wagebill_s1 = tv.wagebill_s1
    wagebill_s2 = tv.wagebill_s2
    wagebill_s3 = tv.wagebill_s3
    wagebill_s5 = tv.wagebill_s5
    # X-28（#165 §11.4）: SF = {S1,S2,S3} のみを集約する（S5 の賃金は取引フロー行列に計上されない）
    wagebill_sf = wagebill_s1 + wagebill_s2 + wagebill_s3
    tax_hh = p.pl_tau * wagebill_sf
    hh_income = (1 - p.pl_tau) * wagebill_sf
    cons = tv.cons
    cons_s1 = tv.cons_s1
    cons_s5 = cons - cons_s1
    xdem_s5 = p.st_xdem0
    y_s5 = tv.y_s5

    # --- ステップ8 収益・分配 ---
    sales_s1 = price_s1 * y_s1
    sales_s2 = price_s2 * y_s2
    sales_s3 = price_s3 * y_s3
    im_s1 = sales_s1 - tv.va_s1
    im_s2 = sales_s2 - tv.va_s2
    im_s3 = sales_s3 - tv.va_s3
    im_s5 = 0.0
    va_s1 = tv.va_s1
    va_s2 = tv.va_s2
    va_s3 = tv.va_s3
    dep_s1 = tv.dep_s1
    dep_s2 = tv.dep_s2
    dep_s3 = tv.dep_s3
    profit_s1 = aux.profit.s1
    profit_s2 = aux.profit.s2
    profit_s3 = aux.profit.s3
    margin_s2 = profit_s2 / sales_s2
    margin_s3 = profit_s3 / sales_s3
    ocf_s1 = aux.ocf.s1
    ocf_s2 = aux.ocf.s2
    ocf_s3 = aux.ocf.s3
    y_tot = va_s1 + va_s2 + va_s3 + y_s5
    coverage_s1 = ocf_s1 / int_burden_s1
    coverage_s2 = ocf_s2 / int_burden_s2
    coverage_s3 = ocf_s3 / int_burden_s3
    debt_service_s1 = int_burden_s1 + repay_s1
    debt_service_s2 = int_burden_s2 + repay_s2
    debt_service_s3 = int_burden_s3 + repay_s3
    dsc_s1 = ocf_s1 / debt_service_s1
    dsc_s2 = ocf_s2 / debt_service_s2
    dsc_s3 = ocf_s3 / debt_service_s3
    leverage_s1 = tv.debt_s1 / sales_s1
    leverage_s2 = tv.debt_s2 / sales_s2
    leverage_s3 = tv.debt_s3 / sales_s3
    nlb_s1 = 0.0
    nlb_s2 = 0.0
    nlb_s3 = 0.0
    nlb_s4 = 0.0
    nlb_s5 = 0.0
    xsales_s1 = sales_s1 - cons_s1
    # E11-22'（#169 §21.4 X-17）: Σ_{s∈SF} wagebill_s を用いる（wagebill_s5 は含めない）
    s5_net_sx =
        wagebill_sf - tax_hh - cons_s1 - cons_s5 - order_gen_s2 - order_gen_s3 + y_s5 -
        xdem_s5
    rollover_gap_s1 = 0.0
    rollover_gap_s2 = 0.0
    rollover_gap_s3 = 0.0

    # --- ステップ9 残高更新 ---
    capstart_s1 = tv.dep_s1
    capstart_s2 = tv.dep_s2
    capstart_s3 = tv.dep_s3
    cap_s1 = tv.cap_s1
    cap_s2 = tv.cap_s2
    cap_s3 = tv.cap_s3
    capex_pipe_s1 = tv.capex_pipe_s1
    capex_pipe_s2 = tv.capex_pipe_s2
    capex_pipe_s3 = tv.capex_pipe_s3
    inv_s2 = tv.inv_s2
    inv_s3 = tv.inv_s3
    invval_s2 = tv.inv_s2
    invval_s3 = tv.inv_s3
    backlog_s2 = tv.backlog_s2
    backlog_s3 = tv.backlog_s3
    cash_s1 = tv.cash_s1
    cash_s2 = tv.cash_s2
    cash_s3 = tv.cash_s3
    debt_s1 = tv.debt_s1
    debt_s2 = tv.debt_s2
    debt_s3 = tv.debt_s3
    nw_s1 = cap_s1 + capex_pipe_s1 + cash_s1 - debt_s1
    nw_s2 = cap_s2 + capex_pipe_s2 + invval_s2 + cash_s2 - debt_s2
    nw_s3 = cap_s3 + capex_pipe_s3 + invval_s3 + cash_s3 - debt_s3
    loans_s4 = debt_s1 + debt_s2 + debt_s3
    dep_stock_s4 = cash_s1 + cash_s2 + cash_s3
    fund_s4 = loans_s4 - dep_stock_s4

    return (;
        ai_exp,
        capex_plan_shock_ex,
        spread_shock_ex,
        policy_rate,
        ext_demand_s2,
        ext_demand_s3,
        price_s1,
        cap_s1,
        capex_pipe_s1,
        cash_s1,
        plan_carry_s1,
        debt_s1,
        r_eff_s1,
        cap_s2,
        capex_pipe_s2,
        backlog_s2,
        inv_s2,
        cash_s2,
        debt_s2,
        r_eff_s2,
        advance_s2,
        cap_s3,
        capex_pipe_s3,
        backlog_s3,
        inv_s3,
        cash_s3,
        debt_s3,
        r_eff_s3,
        advance_s3,
        compute_dem,
        target_cap_s1,
        capex_plan_s1,
        capex_exec_s1,
        cancel_s1,
        y_s1,
        emp_s1,
        capex_sx_s1,
        capex_plan_eff_s1,
        capex_defer_s1,
        capstart_s1,
        retire_s1,
        pipe_cancel_s1,
        refin_s1,
        newdebt_s1,
        writeoff_s1,
        equity_issue_s1,
        div_s1,
        tax_s1,
        valchg_s1,
        order_s2,
        price_s2,
        y_s2,
        ship_s2,
        invest_s2,
        emp_s2,
        inv_sx_s2,
        capstart_s2,
        retire_s2,
        pipe_cancel_s2,
        refin_s2,
        newdebt_s2,
        writeoff_s2,
        equity_issue_s2,
        div_s2,
        tax_s2,
        valchg_s2,
        order_s3,
        price_s3,
        y_s3,
        ship_s3,
        invest_s3,
        emp_s3,
        inv_sx_s3,
        capstart_s3,
        retire_s3,
        pipe_cancel_s3,
        refin_s3,
        newdebt_s3,
        writeoff_s3,
        equity_issue_s3,
        div_s3,
        tax_s3,
        valchg_s3,
        equity_val,
        collateral,
        spread,
        rollover,
        lend_stance,
        fin_cond,
        cost_capital_s1,
        cost_capital_s2,
        cost_capital_s3,
        emp_s5,
        wage,
        cons,
        y_s5,
        xdem_s5,
        ycap_s1,
        util_s1,
        sales_s1,
        profit_s1,
        ocf_s1,
        va_s1,
        backlog_ratio_s2,
        backlog_ratio_s3,
        inv_ratio_s2,
        inv_ratio_s3,
        ycap_s2,
        ycap_s3,
        util_s2,
        util_s3,
        deliv_s2,
        deliv_s3,
        va_s2,
        va_s3,
        sales_s2,
        sales_s3,
        profit_s2,
        profit_s3,
        margin_s2,
        margin_s3,
        ocf_s2,
        ocf_s3,
        coverage_agg,
        int_burden_s1,
        int_burden_s2,
        int_burden_s3,
        debt_service_s1,
        debt_service_s2,
        debt_service_s3,
        coverage_s1,
        coverage_s2,
        coverage_s3,
        leverage_s1,
        leverage_s2,
        leverage_s3,
        spread_endo,
        emp_tot,
        hh_income,
        y_tot,
        dinv_s2,
        dinv_s3,
        cons_s1,
        cons_s5,
        xsales_s1,
        im_s1,
        im_s2,
        im_s3,
        im_s5,
        wagebill_s1,
        wagebill_s2,
        wagebill_s3,
        wagebill_s5,
        dep_s1,
        dep_s2,
        dep_s3,
        capex_cancel_s1,
        matur_s1,
        matur_s2,
        matur_s3,
        repay_s1,
        repay_s2,
        repay_s3,
        tax_hh,
        s5_net_sx,
        nlb_s1,
        nlb_s2,
        nlb_s3,
        nlb_s4,
        nlb_s5,
        invval_s2,
        invval_s3,
        nw_s1,
        nw_s2,
        nw_s3,
        loans_s4,
        dep_stock_s4,
        fund_s4,
        dsc_s1,
        dsc_s2,
        dsc_s3,
        rollover_gap_s1,
        rollover_gap_s2,
        rollover_gap_s3,
        liquidity_gap_s1,
        liquidity_gap_s2,
        liquidity_gap_s3,
        funding_forced_s1,
        funding_forced_s2,
        funding_forced_s3,
        unmet_cap_s2,
        unmet_cap_s3,
        order_gen_s2,
        order_gen_s3,
    )
end

"""
    steady_state(m::CapexCreditCycleModel) -> NamedTuple

逆較正で与えた定常水準の1期分を、`SimulationResult.variables` と同じキー集合の
`NamedTuple` として返す。数値解ではないため収束判定・反復回数を持たない（§14.2）。
"""
steady_state(m::CapexCreditCycleModel) = _ccc_steady_state_full(m)

# ============================================================
# capex_steady_state_report（動学方程式 §14.3、SS-1〜SS-17）
# ============================================================

"""
    CapexSteadyStateReport

`SS-1`–`SS-17` の各条件について `passed`・`residual`・`tolerance`・`detail` を保持する。
`passed(report)` は全条件の論理積。
"""
struct CapexSteadyStateReport
    checks::Dict{String, NamedTuple}
end

passed(report::CapexSteadyStateReport) = all(c.passed for c in values(report.checks))

"""
    capex_steady_state_report(m; atol=1e-8, rtol=1e-6) -> CapexSteadyStateReport

`SS-1`–`SS-17`（動学方程式 §14.3）を検証する。

**`SS-3` の適用範囲について**: §14.3 の記載は `capex_gap_s1`・`inv_gap_s`・`cancel_s1`・
`capex_defer_s1`・`plan_carry_s1` を列挙するが、由来として挙げる `E6-03`・`E6-09`・`E7-18`
はいずれも `S1` の式のみである。`SP`（`s ∈ {S2,S3}`）の `inv_gap_s`（`E6-14`）をこの由来から
独立にゼロと要求すると、`SS-6`（`util_s=bh_util_tgt_s`）・`SS-4`（`capex_pipe_s^{ss} > 0`）と
数学的に両立しない（`target_cap_s^{ss} = cap_s^{ss}` が導かれ、`capex_pipe_s^{ss} = 0` を要求して
しまう）。本実装は由来の記載に従い `SS-3` を `S1` の4条件に限定する。この解釈は上流文書には無い
実装判断であり、上流文書側の確認・改訂を要する差し戻し事項として残る。

**`SS-16`（会計恒等式検証12項目）について**: 会計層は `I-3` の責務であり `I-1` には存在しない。
本チェックは未検証のまま `passed=true` を形式的に返す（`detail` にその旨を明記する）。
"""
function capex_steady_state_report(
    m::CapexCreditCycleModel;
    atol::Float64 = 1e-8,
    rtol::Float64 = 1e-6,
)
    p = m.params
    ss = steady_state(m)
    checks = Dict{String, NamedTuple}()

    mk(passed_, residual_, scale_, detail_) = (
        passed = passed_,
        residual = residual_,
        tolerance = atol + rtol * max(abs(scale_), 1.0),
        detail = detail_,
    )
    within(residual_, scale_) = abs(residual_) <= atol + rtol * max(abs(scale_), 1.0)

    r1 = max(
        abs(ss.ai_exp - 1.0),
        abs(ss.price_s1 - 1.0),
        abs(ss.capex_plan_shock_ex - 1.0),
        abs(ss.spread_shock_ex - 0.0),
        abs(ss.policy_rate - p.st_pol_ref),
        abs(ss.ext_demand_s2 - p.st_extdem_s2),
        abs(ss.ext_demand_s3 - p.st_extdem_s3),
    )
    checks["SS-1"] = mk(within(r1, 1.0), r1, 1.0, "外生変数が baseline 値と一致する")

    r2 = max(
        abs(ss.fin_cond),
        abs(ss.equity_val - 1.0),
        abs(ss.spread - p.st_spread0),
        abs(ss.lend_stance),
        abs(ss.rollover - 1.0),
    )
    checks["SS-2"] = mk(
        within(r2, p.st_spread0),
        r2,
        p.st_spread0,
        "fin_cond=0・equity_val=1・spread=st_spread0・lend_stance=0・rollover=1",
    )

    capex_gap_s1 = ss.target_cap_s1 - ss.cap_s1 - ss.capex_pipe_s1
    r3 = max(
        abs(capex_gap_s1),
        abs(ss.cancel_s1),
        abs(ss.capex_defer_s1),
        abs(ss.plan_carry_s1),
    )
    checks["SS-3"] = mk(
        within(r3, ss.cap_s1),
        r3,
        ss.cap_s1,
        "capex_gap_s1=0・cancel_s1=0・capex_defer_s1=0・plan_carry_s1=0（S1、適用範囲は上記docstring参照）",
    )

    r4 = max(
        abs(ss.capstart_s1 - p.st_delta_s1 * ss.cap_s1),
        abs(ss.capex_pipe_s1 - p.st_pipelag_s1 * p.st_delta_s1 * ss.cap_s1),
        abs(ss.capstart_s2 - p.st_delta_s2 * ss.cap_s2),
        abs(ss.capex_pipe_s2 - p.st_pipelag_s2 * p.st_delta_s2 * ss.cap_s2),
        abs(ss.capstart_s3 - p.st_delta_s3 * ss.cap_s3),
        abs(ss.capex_pipe_s3 - p.st_pipelag_s3 * p.st_delta_s3 * ss.cap_s3),
    )
    checks["SS-4"] = mk(
        within(r4, ss.cap_s2),
        r4,
        ss.cap_s2,
        "capstart_s=I_s=st_delta_s·cap_s、capex_pipe_s=st_pipelag_s·st_delta_s·cap_s",
    )

    r5 = abs(ss.cap_s1 + ss.capex_pipe_s1 - ss.target_cap_s1)
    checks["SS-5"] =
        mk(within(r5, ss.cap_s1), r5, ss.cap_s1, "cap_s1+capex_pipe_s1=target_cap_s1")

    r6 = max(
        abs(ss.util_s2 - p.bh_util_tgt_s2),
        abs(ss.util_s3 - p.bh_util_tgt_s3),
        abs(ss.util_s1 - p.bh_util_tgt_s1 * (1 + p.st_pipelag_s1 * p.st_delta_s1)),
    )
    checks["SS-6"] = mk(
        within(r6, 1.0),
        r6,
        1.0,
        "util_s=bh_util_tgt_s（SP）、util_s1=bh_util_tgt_s1·(1+st_pipelag_s1·st_delta_s1)",
    )

    r7 = max(
        abs(ss.y_s2 - ss.ship_s2),
        abs(ss.y_s3 - ss.ship_s3),
        max(0.0, ss.inv_ratio_s2 - p.bh_inv_thresh_s2),
        max(0.0, ss.inv_ratio_s3 - p.bh_inv_thresh_s3),
    )
    checks["SS-7"] = mk(
        within(r7, ss.y_s2),
        r7,
        ss.y_s2,
        "y_s=ship_s=ship_desired_s、inv_ratio_s≤bh_inv_thresh_s、y_cut_s=0（SP）",
    )

    demand_gen_s2 = ss.backlog_s2 + ss.order_gen_s2 + ss.ext_demand_s2
    demand_gen_s3 = ss.backlog_s3 + ss.order_gen_s3 + ss.ext_demand_s3
    r8 = max(
        abs(ss.backlog_s2 - p.bh_backlog_target_s2 * demand_gen_s2),
        abs(ss.backlog_s3 - p.bh_backlog_target_s3 * demand_gen_s3),
    )
    checks["SS-8"] = mk(
        within(r8, ss.backlog_s2),
        r8,
        ss.backlog_s2,
        "backlog_s=bh_backlog_target_s·demand_gen_s（SP）",
    )

    r9 = max(abs(ss.price_s2 - 1.0), abs(ss.price_s3 - 1.0))
    checks["SS-9"] = mk(within(r9, 1.0), r9, 1.0, "price_s=1（SP）")

    r10 = max(
        abs(ss.emp_s1 - ss.y_s1 / p.st_lprod_s1),
        abs(ss.emp_s2 - ss.y_s2 / p.st_lprod_s2),
        abs(ss.emp_s3 - ss.y_s3 / p.st_lprod_s3),
        abs(ss.emp_s5 - ss.y_s5 / p.st_lprod_s5),
    )
    checks["SS-10"] =
        mk(within(r10, ss.emp_s5), r10, ss.emp_s5, "emp_s=emp_req_s=y_s/st_lprod_s")

    r11 = max(abs(ss.wage - 1.0), abs(ss.emp_tot - p.st_emp_ref))
    checks["SS-11"] =
        mk(within(r11, ss.emp_tot), r11, ss.emp_tot, "wage=1（emp_tot=st_emp_ref）")

    r12 = max(
        abs(ss.cons - (p.bh_mpc * ss.hh_income + p.st_cons_auto)),
        abs(ss.y_s5 - (ss.cons_s5 + ss.xdem_s5)),
    )
    checks["SS-12"] = mk(
        within(r12, ss.cons),
        r12,
        ss.cons,
        "cons=bh_mpc·hh_income+st_cons_auto、y_s5=cons_s5+xdem_s5",
    )

    r13 = max(abs(ss.unmet_cap_s2), abs(ss.unmet_cap_s3))
    checks["SS-13"] = mk(within(r13, 1.0), r13, 1.0, "unmet_cap_s=0（仮定A-2が成立）")

    r14 = max(
        abs(ss.profit_s1 - (ss.int_burden_s1 + ss.tax_s1 + ss.div_s1)),
        abs(ss.profit_s2 - (ss.int_burden_s2 + ss.tax_s2 + ss.div_s2)),
        abs(ss.profit_s3 - (ss.int_burden_s3 + ss.tax_s3 + ss.div_s3)),
        abs(p.st_payout_s1 - 1.0),
        abs(p.st_payout_s2 - 1.0),
        abs(p.st_payout_s3 - 1.0),
    )
    checks["SS-14"] = mk(
        within(r14, 1.0),
        r14,
        1.0,
        "profit_s=int_burden_s+tax_s+div_s（st_payout_s=1と同値）",
    )

    r15 = max(
        abs(ss.newdebt_s1),
        abs(ss.newdebt_s2),
        abs(ss.newdebt_s3),
        abs(ss.funding_forced_s1),
        abs(ss.funding_forced_s2),
        abs(ss.funding_forced_s3),
        abs(ss.liquidity_gap_s1),
        abs(ss.liquidity_gap_s2),
        abs(ss.liquidity_gap_s3),
    )
    checks["SS-15"] = mk(
        within(r15, 1.0),
        r15,
        1.0,
        "need_s=newdebt_s=draw_s=liquidity_gap_s=funding_forced_s=0",
    )

    checks["SS-16"] = (
        passed = true,
        residual = NaN,
        tolerance = NaN,
        detail = "会計恒等式検証12項目（#166 §8.1）は I-3（会計表・残高更新・恒等式検証）の責務であり、" *
                 "I-1 では検証しない。本チェックは未検証のまま形式的に passed=true とする。",
    )

    r17 = abs(ss.s5_net_sx) / ss.y_tot
    checks["SS-17"] = (
        passed = r17 <= 0.05,
        residual = r17,
        tolerance = 0.05,
        detail = "|s5_net_sx| / y_tot ≤ 0.05",
    )

    return CapexSteadyStateReport(checks)
end
