"""
部門別CAPEX・信用循環モデル（`CapexCreditCycleModel`）。

`I-1`（型・パラメータ辞書・逆較正・定常状態）と `I-2`（期内動学・数値ガード・`simulate`）の
実装。会計表・診断ラベル・シナリオ定義は後続 Issue（`I-3`〜`I-5`）の責務であり、本ファイルには
含まれない。

正本:
- [統合設計](https://github.com/Yuki-Watanabe7/DME/blob/main/docs/architecture/capex_credit_cycle_integration.md)
- [統合モデル仕様 index](https://github.com/Yuki-Watanabe7/DME/blob/main/docs/models/capex_credit_cycle_design.md)
- [動学方程式](https://github.com/Yuki-Watanabe7/DME/blob/main/docs/models/capex_credit_cycle_equations.md) §3-§17（期内処理順序・全方程式・
  パラメータ辞書・逆較正・数値ガード）
- [部門境界と変数定義](https://github.com/Yuki-Watanabe7/DME/blob/main/docs/models/capex_credit_cycle_sectors_variables.md) §4-6
- [ADR 0011](https://github.com/Yuki-Watanabe7/DME/blob/main/docs/adr/0011-capex-credit-cycle-dynamics-contract.md)
- [ADR 0013](https://github.com/Yuki-Watanabe7/DME/blob/main/docs/adr/0013-capex-credit-cycle-integration-contract.md)
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
#
# `I-2`（本ファイル）で検出した §13.5 の欠落: `E10-07`（`emp_s = max(0, emp_s[t−1] + λ_s·gap_emp_s)`）
# と `E10-09`（`wage = max(st_wage_min, wage[t−1] + …)`）はいずれも自身の前期値を参照する再帰式
# だが、§13.5 の遅延バッファ一覧に `emp_s`（`s1`–`s5`）・`wage` が含まれていない
# （`r_eff_s`・`price_s` 等の他の自己参照変数は state または深さ3バッファとして登録済み）。
# 式が要求する値を式の外から独自に作らずに済ませる方法が無いため、深さ1バッファへ追加する
# （経済的判断ではなく、指定された再帰式を評価可能にするための機械的な追加）。
# 状態次元は 65 から 70 へ増える。上流文書（#169 §13.5）への差し戻し事項として保持する。
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
    :emp_s1,
    :emp_s2,
    :emp_s3,
    :emp_s5,
    :wage,
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

# ============================================================
# I-2: 期内動学・数値ガード・simulate（動学方程式 §5–§12・§15、統合設計 §4.4・§5）
# ============================================================

"""
    _ccc_div(a, b, eps) -> Float64

ゼロ除算規則（動学方程式 §15.4）。`|b| ≤ eps` のとき `NaN` を返す。
分母を下限で置き換えない（`E6-08`・`E11-19` の2箇所を除く。当該箇所は個別に実装する）。
"""
_ccc_div(a::Float64, b::Float64, eps::Float64) = abs(b) <= eps ? NaN : a / b

const CAPEX_CC_WARNING_CODES = (
    :runup_deviation,
    :a2_violation,
    :funding_forced,
    :liquidity_gap,
    :cash_below_min,
    :threshold_proximity,
    :extreme_shock,
    :acc_warning,
    :acc_fail,
    :acc_invalid,
    :sign_constraint,
    :ss_inconsistent,
)

const CAPEX_CC_BINDING_FLAGS = (
    :equity_floor_binding,
    :spread_floor_binding,
    :rollover_binding,
    :cc_floor_binding,
    :liq_binding,
    :plan_floor_binding,
    :cancel_binding,
    :div_floor_binding,
    :fundable_floor_binding,
    :defer_cap_binding,
    :invest_funding_binding,
    :order_gen_floor_binding,
    :inv_threshold_binding,
    :capacity_binding,
    :supply_binding,
    :price_floor_binding,
    :capacity_binding_s1,
    :emp_floor_binding,
    :wage_floor_binding,
    :cons_floor_binding,
    :cons_split_binding,
)

function _ccc_default_binding_keys()
    ks = Symbol[
        :equity_floor_binding,
        :spread_floor_binding,
        :rollover_binding,
        :cancel_binding,
        :defer_cap_binding,
        :capacity_binding_s1,
        :wage_floor_binding,
        :cons_floor_binding,
        :cons_split_binding,
    ]
    for s in _CCC_S13
        push!(ks, Symbol("cc_floor_binding_$s"))
        push!(ks, Symbol("liq_binding_$s"))
        push!(ks, Symbol("plan_floor_binding_$s"))
        push!(ks, Symbol("div_floor_binding_$s"))
        push!(ks, Symbol("fundable_floor_binding_$s"))
    end
    for s in _CCC_S23
        push!(ks, Symbol("order_gen_floor_binding_$s"))
        push!(ks, Symbol("inv_threshold_binding_$s"))
        push!(ks, Symbol("capacity_binding_$s"))
        push!(ks, Symbol("supply_binding_$s"))
        push!(ks, Symbol("price_floor_binding_$s"))
        push!(ks, Symbol("invest_funding_binding_$s"))
    end
    for s in ("s1", "s2", "s3", "s5")
        push!(ks, Symbol("emp_floor_binding_$s"))
    end
    return ks
end

function _ccc_sector_of(sym::Symbol)
    s = string(sym)
    for tag in ("s1", "s2", "s3", "s4", "s5")
        if endswith(s, "_" * tag)
            return tag
        end
    end
    return "aggregate"
end

# ------------------------------------------------------------
# 内部型（統合設計 §5.1）。65（#169）→70 次元（`_CCC_LAG1_BASE` 直上のコメント参照）の
# 期首状態・当期全変数を Dict{Symbol,Float64} として表現する。フィールドを固定した
# struct にすると 200 近い個別フィールドの列挙が必要になり、キー集合が
# `_ccc_state_variables()`/変数辞書と二重管理になるため、キー集合を単一の関数から
# 導出できる Dict 表現を採る。
# ------------------------------------------------------------

const _CCCState = Dict{Symbol, Float64}
const _CCCPeriod = Dict{Symbol, Float64}
const _CCCBinding = Dict{Symbol, Vector{Bool}}

"""
    _ccc_state0_from_steady(m) -> _CCCState

`steady_state(m)` から70次元の初期状態（`t=-8` の期首状態）を構成する。遅延バッファも
定常値で埋める（ゼロで埋めない、動学方程式 §14.4）。
"""
function _ccc_state0_from_steady(m::CapexCreditCycleModel)
    ss = steady_state(m)
    st = _CCCState()
    for sym in _CCC_STATE_BASE
        st[sym] = getproperty(ss, sym)
    end
    for base in _CCC_LAG1_BASE
        st[Symbol(string(base) * "_lag1")] = getproperty(ss, base)
    end
    for base in _CCC_LAG3_BASE
        v = getproperty(ss, base)
        st[Symbol(string(base) * "_lag1")] = v
        st[Symbol(string(base) * "_lag2")] = v
        st[Symbol(string(base) * "_lag3")] = v
    end
    return st
end

function _ccc_state_dict_from_namedtuple(nt)
    st = _CCCState()
    for sym in _ccc_state_variables()
        st[sym] = Float64(getproperty(nt, sym))
    end
    return st
end

"""
    _ccc_shift_state!(newst, pr, st)

期末の70次元状態を組み立てる。base 22 は当期値そのもの、深さ1バッファは当期値、
深さ3バッファはシフトレジスタ（`lag3 ← lag2`・`lag2 ← lag1`・`lag1 ← 当期値`）。
"""
function _ccc_shift_state!(newst::_CCCState, pr::_CCCPeriod, st::_CCCState)
    for sym in _CCC_STATE_BASE
        newst[sym] = pr[sym]
    end
    for base in _CCC_LAG1_BASE
        newst[Symbol(string(base) * "_lag1")] = pr[base]
    end
    for base in _CCC_LAG3_BASE
        newst[Symbol(string(base) * "_lag3")] = st[Symbol(string(base) * "_lag2")]
        newst[Symbol(string(base) * "_lag2")] = st[Symbol(string(base) * "_lag1")]
        newst[Symbol(string(base) * "_lag1")] = pr[base]
    end
    return newst
end

# ------------------------------------------------------------
# ステップ1: 外生入力の適用（§4）
# ------------------------------------------------------------

function _ccc_apply_exog!(pr::_CCCPeriod, exog::Dict{Symbol, Vector{Float64}}, idx::Int)
    for v in CAPEX_CC_EXOGENOUS_VARIABLES
        pr[v] = exog[v][idx]
    end
    return nothing
end

# ------------------------------------------------------------
# ステップ2: 金融条件（§5）
# ------------------------------------------------------------

function _ccc_financial!(
    pr::_CCCPeriod,
    st::_CCCState,
    p::NamedTuple,
    opts::CapexCreditCycleOptions,
    binding::_CCCBinding,
    idx::Int,
)
    eps = opts.div_eps

    fin_cond =
        (1 - p.bh_fc_adj) * st[:fin_cond_lag1] +
        p.bh_fc_adj * p.bh_fc_pol * (pr[:policy_rate] - p.st_pol_ref)
    pr[:fin_cond] = fin_cond

    profit_sf_lag1 = st[:profit_s1_lag1] + st[:profit_s2_lag1] + st[:profit_s3_lag1]
    equity_val_raw =
        (1 - p.bh_ev_adj) * st[:equity_val_lag1] +
        p.bh_ev_adj * (1 + p.bh_ev_elas * (profit_sf_lag1 / p.st_profit_ref - 1))
    equity_val = max(equity_val_raw, p.st_ev_min)
    binding[:equity_floor_binding][idx] = equity_val_raw < p.st_ev_min
    pr[:equity_val] = equity_val

    # invval_s[t-1] は state/lag に持たないため price_s[t-1]・inv_s[t-1] から再構成する（E12-05）
    invval_s2_lag1 = st[:price_s2_lag1] * st[:inv_s2]
    invval_s3_lag1 = st[:price_s3_lag1] * st[:inv_s3]
    physical_sf_lag1 =
        (st[:cap_s1] + st[:capex_pipe_s1]) +
        (st[:cap_s2] + st[:capex_pipe_s2]) +
        (st[:cap_s3] + st[:capex_pipe_s3])
    collateral =
        p.st_coll_ltv *
        (physical_sf_lag1 + invval_s2_lag1 + invval_s3_lag1) *
        equity_val^p.bh_coll_elas
    pr[:collateral] = collateral

    coverage_agg_lag1 = st[:coverage_agg_lag1]
    threshold_term =
        isnan(coverage_agg_lag1) ? 0.0 :
        p.bh_spread_cov * max(0.0, p.bh_cov_threshold - coverage_agg_lag1)^p.bh_spread_pow
    spread_endo = p.st_spread0 + threshold_term + p.bh_spread_fc * st[:fin_cond_lag1]
    pr[:spread_endo] = spread_endo
    spread_raw = spread_endo + pr[:spread_shock_ex]
    spread = max(spread_raw, 0.0)
    binding[:spread_floor_binding][idx] = spread_raw < 0.0
    pr[:spread] = spread

    lend_stance = -p.bh_lend_spread * (st[:spread_lag1] - p.st_spread0)
    pr[:lend_stance] = lend_stance

    debt_sf_lag1 = st[:debt_s1] + st[:debt_s2] + st[:debt_s3]
    local rollover::Float64
    if collateral <= eps
        rollover = NaN
    else
        rollover_raw = 1 - p.bh_roll_slope * max(0.0, debt_sf_lag1 / collateral - p.pl_ltv)
        rollover = clamp(rollover_raw, 0.0, 1.0)
        binding[:rollover_binding][idx] = rollover_raw < 0.0 || rollover_raw > 1.0
    end
    pr[:rollover] = rollover

    for s in _CCC_S13
        debt_lag1 = st[Symbol("debt_$s")]
        maturity = getproperty(p, Symbol("st_maturity_$s"))
        phi = _CCC_DT / maturity
        matur = phi * debt_lag1
        refin = isnan(rollover) ? NaN : rollover * matur
        repay = isnan(rollover) ? NaN : matur - refin
        r_new = (pr[:policy_rate] + spread / 100) / 100
        r_eff_lag1 = st[Symbol("r_eff_$s")]
        r_eff = (1 - phi) * r_eff_lag1 + phi * r_new
        int_burden = r_eff * _CCC_DT * debt_lag1
        pr[Symbol("matur_$s")] = matur
        pr[Symbol("refin_$s")] = refin
        pr[Symbol("repay_$s")] = repay
        pr[Symbol("r_eff_$s")] = r_eff
        pr[Symbol("int_burden_$s")] = int_burden
        pr[Symbol("rollover_gap_$s")] = repay

        cc_raw =
            getproperty(p, Symbol("st_cc0_$s")) + p.bh_cc_spread * spread / 100 -
            p.bh_cc_lend * lend_stance - p.bh_cc_equity * (equity_val - 1) +
            p.bh_cc_fc * fin_cond
        cc = max(cc_raw, 0.0)
        binding[Symbol("cc_floor_binding_$s")][idx] = cc_raw < 0.0
        pr[Symbol("cost_capital_$s")] = cc
    end

    ocf_sf_lag1 = st[:ocf_s1_lag1] + st[:ocf_s2_lag1] + st[:ocf_s3_lag1]
    int_burden_sf_lag1 =
        st[:int_burden_s1_lag1] + st[:int_burden_s2_lag1] + st[:int_burden_s3_lag1]
    pr[:coverage_agg] = _ccc_div(ocf_sf_lag1, int_burden_sf_lag1, eps)

    return nothing
end

# ------------------------------------------------------------
# ステップ3: 計画（§6）
# ------------------------------------------------------------

function _ccc_plan!(
    pr::_CCCPeriod,
    st::_CCCState,
    p::NamedTuple,
    opts::CapexCreditCycleOptions,
    binding::_CCCBinding,
    idx::Int,
)
    eps = opts.div_eps

    compute_dem = p.st_cd0 * pr[:ai_exp]
    pr[:compute_dem] = compute_dem

    target_cap_s1 = p.st_cor_s1 * compute_dem / p.bh_util_tgt_s1
    pr[:target_cap_s1] = target_cap_s1

    capex_gap_s1 = target_cap_s1 - st[:cap_s1] - st[:capex_pipe_s1]
    capex_plan_raw_s1 = p.st_delta_s1 * st[:cap_s1] + p.bh_alpha_capex_s1 * capex_gap_s1

    denom_liq_s1 = p.st_cash_ref_s1 * st[:sales_s1_lag1]
    local liq_s1::Float64
    if abs(denom_liq_s1) <= eps
        liq_s1 = NaN
    else
        liq_raw = st[:cash_s1] / denom_liq_s1
        liq_s1 = clamp(liq_raw, 0.0, 1.0)
        binding[:liq_binding_s1][idx] = liq_raw < 0.0 || liq_raw > 1.0
    end

    cc_dev_s1 = st[:cost_capital_s1_lag1] - p.st_cc0_s1

    liq_term_s1 = isnan(liq_s1) ? NaN : (1 - p.bh_cc_elas_s1 * (1 - liq_s1) * cc_dev_s1)
    plan_raw = capex_plan_raw_s1 * liq_term_s1 * pr[:capex_plan_shock_ex]
    capex_plan_s1 = max(plan_raw, 0.0)
    binding[:plan_floor_binding_s1][idx] = plan_raw < 0.0
    pr[:capex_plan_s1] = capex_plan_s1

    plan_rev_s1 =
        (capex_plan_s1 - st[:capex_plan_s1_lag1]) / max(st[:capex_plan_s1_lag1], eps)
    cancel_raw = p.bh_cancel_slope * max(0.0, -plan_rev_s1 - p.bh_cancel_thresh)
    cancel_s1 = clamp(cancel_raw, 0.0, p.bh_cancel_max)
    binding[:cancel_binding][idx] = cancel_raw < 0.0 || cancel_raw > p.bh_cancel_max
    pr[:cancel_s1] = cancel_s1

    revive_s1 = p.bh_revive_s1 * st[:plan_carry_s1]
    pr[:revive_s1] = revive_s1
    capex_plan_eff_s1 = capex_plan_s1 + revive_s1
    pr[:capex_plan_eff_s1] = capex_plan_eff_s1

    capex_cancel_s1 = cancel_s1 * capex_plan_eff_s1
    pr[:capex_cancel_s1] = capex_cancel_s1

    # SP（s∈{S2,S3}）の投資計画。`inv_gap_s` は §6.5 の E6-14 から `capex_pipe_s[t−1]` の
    # 減算を外している（本ファイル冒頭のコメント「I-2-inv-gap-sp」参照。上流への差し戻し事項）。
    for s in _CCC_S23
        y_lag1 = st[Symbol("y_$(s)_lag1")]
        util_tgt = getproperty(p, Symbol("bh_util_tgt_$s"))
        ycap_tgt = y_lag1 / util_tgt
        target_cap = getproperty(p, Symbol("st_cor_$s")) * ycap_tgt
        inv_gap = target_cap - st[Symbol("cap_$s")]

        cash_ref = getproperty(p, Symbol("st_cash_ref_$s"))
        sales_lag1 = st[Symbol("sales_$(s)_lag1")]
        denom_liq = cash_ref * sales_lag1
        local liq_s::Float64
        if abs(denom_liq) <= eps
            liq_s = NaN
        else
            liq_raw = st[Symbol("cash_$s")] / denom_liq
            liq_s = clamp(liq_raw, 0.0, 1.0)
            binding[Symbol("liq_binding_$s")][idx] = liq_raw < 0.0 || liq_raw > 1.0
        end

        delta = getproperty(p, Symbol("st_delta_$s"))
        alpha_inv = getproperty(p, Symbol("bh_alpha_inv_$s"))
        cc_elas_inv = getproperty(p, Symbol("bh_cc_elas_inv_$s"))
        cc0 = getproperty(p, Symbol("st_cc0_$s"))
        lend_elas_inv = getproperty(p, Symbol("bh_lend_elas_inv_$s"))
        cost_capital_lag1 = st[Symbol("cost_capital_$(s)_lag1")]
        lend_stance_lag1 = st[:lend_stance_lag1]

        liq_term =
            isnan(liq_s) ? NaN : (1 - cc_elas_inv * (1 - liq_s) * (cost_capital_lag1 - cc0))
        plan_raw_s =
            (delta * st[Symbol("cap_$s")] + alpha_inv * inv_gap) *
            liq_term *
            (1 + lend_elas_inv * lend_stance_lag1)
        invest_plan = max(plan_raw_s, 0.0)
        binding[Symbol("plan_floor_binding_$s")][idx] = plan_raw_s < 0.0
        pr[Symbol("invest_plan_$s")] = invest_plan
    end

    return nothing
end

# ------------------------------------------------------------
# ステップ4: 資金制約と実行（§7）
# ------------------------------------------------------------

function _ccc_funding!(
    pr::_CCCPeriod,
    st::_CCCState,
    p::NamedTuple,
    opts::CapexCreditCycleOptions,
    binding::_CCCBinding,
    idx::Int,
)
    for s in _CCC_S13
        profit_lag1 = st[Symbol("profit_$(s)_lag1")]
        int_burden_lag1 = st[Symbol("int_burden_$(s)_lag1")]
        tax_lag1 = st[Symbol("tax_$(s)_lag1")]

        tax = p.pl_tau_corp * max(0.0, profit_lag1 - int_burden_lag1)
        pr[Symbol("tax_$s")] = tax

        payout = getproperty(p, Symbol("st_payout_$s"))
        div_raw = payout * max(0.0, profit_lag1 - int_burden_lag1 - tax_lag1)
        div = max(div_raw, 0.0)
        binding[Symbol("div_floor_binding_$s")][idx] = div_raw < 0.0
        pr[Symbol("div_$s")] = div

        pr[Symbol("equity_issue_$s")] = 0.0
        pr[Symbol("writeoff_$s")] = 0.0
        pr[Symbol("pipe_cancel_$s")] = 0.0
        pr[Symbol("retire_$s")] = 0.0
    end
    pr[:advance_s2] = 0.0
    pr[:advance_s3] = 0.0

    for s in _CCC_S13
        ocf_lag1 = st[Symbol("ocf_$(s)_lag1")]
        int_burden = pr[Symbol("int_burden_$s")]
        tax = pr[Symbol("tax_$s")]
        div = pr[Symbol("div_$s")]
        repay = pr[Symbol("repay_$s")]
        internal = ocf_lag1 - int_burden - tax - div - repay
        pr[Symbol("internal_$s")] = internal

        cash_min = getproperty(p, Symbol("st_cash_min_$s"))
        sales_lag1 = st[Symbol("sales_$(s)_lag1")]
        cash_free_raw = st[Symbol("cash_$s")] - cash_min * sales_lag1
        cash_free = max(cash_free_raw, 0.0)
        binding[Symbol("fundable_floor_binding_$s")][idx] = cash_free_raw < 0.0
        pr[Symbol("cash_free_$s")] = cash_free

        dcap = getproperty(p, Symbol("st_dcap_$s"))
        dcap_lend = getproperty(p, Symbol("bh_dcap_lend_$s"))
        debt_cap_raw = (dcap + dcap_lend * pr[:lend_stance]) * sales_lag1
        debt_cap = max(debt_cap_raw, 0.0)
        pr[Symbol("debt_cap_$s")] = debt_cap

        newdebt_max_raw = debt_cap - (st[Symbol("debt_$s")] - repay)
        newdebt_max = max(newdebt_max_raw, 0.0)
        pr[Symbol("newdebt_max_$s")] = newdebt_max

        fundable_raw = internal + cash_free + newdebt_max
        fundable = max(fundable_raw, 0.0)
        binding[Symbol("fundable_floor_binding_$s")][idx] |= fundable_raw < 0.0
        pr[Symbol("fundable_$s")] = fundable
    end

    commit_s1 = p.st_commit_s1 * st[:capex_exec_s1_lag1]
    pr[:commit_s1] = commit_s1

    defer_roll_s1 =
        p.bh_defer_roll *
        max(0.0, p.bh_roll_thresh - pr[:rollover]) *
        (pr[:capex_plan_eff_s1] - pr[:capex_cancel_s1])
    defer_max_raw = pr[:capex_plan_eff_s1] - pr[:capex_cancel_s1] - commit_s1
    defer_max_s1 = max(defer_max_raw, 0.0)
    defer_need_raw = (pr[:capex_plan_eff_s1] - pr[:capex_cancel_s1]) - pr[:fundable_s1]
    defer_need_s1 = max(defer_need_raw, 0.0)

    defer_candidate = defer_need_s1 + defer_roll_s1
    capex_defer_s1 = min(defer_max_s1, defer_candidate)
    binding[:defer_cap_binding][idx] = defer_candidate > defer_max_s1
    pr[:capex_defer_s1] = capex_defer_s1

    capex_exec_s1 = pr[:capex_plan_eff_s1] - pr[:capex_cancel_s1] - capex_defer_s1
    pr[:capex_exec_s1] = capex_exec_s1

    pr[:capex_sx_s1] = p.st_capex_share_sx * capex_exec_s1

    for s in _CCC_S23
        invest_raw = pr[Symbol("invest_plan_$s")]
        fundable = pr[Symbol("fundable_$s")]
        invest = min(invest_raw, fundable)
        binding[Symbol("invest_funding_binding_$s")][idx] = invest_raw > fundable
        pr[Symbol("invest_$s")] = invest
    end

    pr[:inv_sx_s2] = p.st_invest_share_sx * pr[:invest_s2]
    pr[:inv_sx_s3] = pr[:invest_s3]

    # §7.3 の liquidity_gap_s（E7-20）。`newdebt_s` ではなく `newdebt_max_s`（事前上限）を
    # 用いる読み替え済みの定義（差し戻し `E5`、#166 §14.6 で解決済み）。
    I_of = Dict("s1" => capex_exec_s1, "s2" => pr[:invest_s2], "s3" => pr[:invest_s3])
    for s in _CCC_S13
        I_s = I_of[s]
        gap_raw =
            pr[Symbol("int_burden_$s")] + pr[Symbol("repay_$s")] + I_s -
            st[Symbol("ocf_$(s)_lag1")] - pr[Symbol("newdebt_max_$s")] -
            pr[Symbol("cash_free_$s")]
        pr[Symbol("liquidity_gap_$s")] = max(gap_raw, 0.0)
    end

    return nothing
end

# ------------------------------------------------------------
# ステップ5: 価格確定と受注配分（§8・§9.4、X-15/X-16 改訂により価格生成をここへ前倒し）
# ------------------------------------------------------------

function _ccc_orders!(
    pr::_CCCPeriod,
    st::_CCCState,
    p::NamedTuple,
    opts::CapexCreditCycleOptions,
    binding::_CCCBinding,
    idx::Int,
)
    for s in _CCC_S23
        util_lag1 = st[Symbol("util_$(s)_lag1")]
        util_tgt = getproperty(p, Symbol("bh_util_tgt_$s"))
        price_scale = getproperty(p, Symbol("bh_price_scale_$s"))
        price_sens = getproperty(p, Symbol("bh_price_sens_$s"))
        price_tgt = 1 + price_sens * tanh((util_lag1 - util_tgt) / price_scale)

        price_min = getproperty(p, Symbol("st_price_min_$s"))
        price_adj = getproperty(p, Symbol("bh_price_adj_$s"))
        price_lag1 = st[Symbol("price_$(s)_lag1")]
        price_raw = price_lag1 + price_adj * (price_tgt - price_lag1)
        price = max(price_raw, price_min)
        binding[Symbol("price_floor_binding_$s")][idx] = price_raw < price_min
        pr[Symbol("price_$s")] = price
    end

    order_cap = Dict{String, Float64}()
    for s in _CCC_S23
        share = getproperty(p, Symbol("st_capex_share_$s"))
        price_min = getproperty(p, Symbol("st_price_min_$s"))
        price = pr[Symbol("price_$s")]
        order_cap[s] = share * pr[:capex_exec_s1] / max(price, price_min)
    end

    pr[:order_inv_s2] = 0.0
    order_inv_s3 =
        p.st_invest_share_s3 * pr[:invest_s2] / max(pr[:price_s3], p.st_price_min_s3)
    order_inv = Dict("s2" => 0.0, "s3" => order_inv_s3)

    for s in _CCC_S23
        gen_share = getproperty(p, Symbol("st_gen_share_$s"))
        y_s5_lag1 = st[:y_s5_lag1]
        price_elas = getproperty(p, Symbol("bh_price_elas_$s"))
        price_lag3 = st[Symbol("price_$(s)_lag3")]
        order_gen_raw = gen_share * y_s5_lag1 * (1 - price_elas * (price_lag3 - 1))
        order_gen = max(order_gen_raw, 0.0)
        binding[Symbol("order_gen_floor_binding_$s")][idx] = order_gen_raw < 0.0
        pr[Symbol("order_gen_$s")] = order_gen

        ext_demand = pr[Symbol("ext_demand_$s")]
        pr[Symbol("order_cap_int_$s")] = order_cap[s]
        pr[Symbol("order_inv_int_$s")] = order_inv[s]
        pr[Symbol("order_$s")] = order_cap[s] + order_inv[s] + order_gen + ext_demand
    end

    return nothing
end

# ------------------------------------------------------------
# ステップ6: 生産・出荷・在庫・受注残（§9）
# ------------------------------------------------------------

function _ccc_production!(
    pr::_CCCPeriod,
    st::_CCCState,
    p::NamedTuple,
    opts::CapexCreditCycleOptions,
    binding::_CCCBinding,
    idx::Int,
)
    for s in _CCC_S23
        cor = getproperty(p, Symbol("st_cor_$s"))
        ycap = st[Symbol("cap_$s")] / cor
        pr[Symbol("ycap_$s")] = ycap

        demand_cap = pr[Symbol("order_cap_int_$s")] + pr[Symbol("order_inv_int_$s")]

        backlog_lag1 = st[Symbol("backlog_$s")]
        order_gen = pr[Symbol("order_gen_$s")]
        ext_demand = pr[Symbol("ext_demand_$s")]
        demand_gen = backlog_lag1 + order_gen + ext_demand

        backlog_tgt = getproperty(p, Symbol("bh_backlog_target_$s"))
        ship_desired = demand_cap + (1 - backlog_tgt) * demand_gen

        inv_tgt_ratio = getproperty(p, Symbol("bh_inv_target_$s"))
        inv_tgt = inv_tgt_ratio * ship_desired
        inv_lag1 = st[Symbol("inv_$s")]
        inv_adj = getproperty(p, Symbol("bh_inv_adj_$s"))
        y_norm = ship_desired + inv_adj * (inv_tgt - inv_lag1)

        inv_ratio_lag1 = st[Symbol("inv_ratio_$(s)_lag1")]
        inv_thresh = getproperty(p, Symbol("bh_inv_thresh_$s"))
        prod_cut = getproperty(p, Symbol("bh_prod_cut_$s"))
        y_cut =
            isnan(inv_ratio_lag1) ? 0.0 :
            prod_cut * max(0.0, inv_ratio_lag1 - inv_thresh) * ship_desired
        binding[Symbol("inv_threshold_binding_$s")][idx] =
            !isnan(inv_ratio_lag1) && (inv_ratio_lag1 - inv_thresh) > 0.0

        util_max = getproperty(p, Symbol("bh_util_max_$s"))
        y_pre = max(0.0, y_norm - y_cut)
        y_cap_limit = util_max * ycap
        y = min(y_pre, y_cap_limit)
        binding[Symbol("capacity_binding_$s")][idx] =
            (y_norm - y_cut < 0.0) || (y_pre > y_cap_limit)
        pr[Symbol("y_$s")] = y
        pr[Symbol("util_$s")] = y / ycap

        ship_raw = min(ship_desired, y + inv_lag1)
        binding[Symbol("supply_binding_$s")][idx] = ship_desired > (y + inv_lag1)
        pr[Symbol("ship_$s")] = ship_raw
        ship_gen = max(0.0, ship_raw - demand_cap)
        pr[Symbol("ship_gen_$s")] = ship_gen

        price = pr[Symbol("price_$s")]
        pr[Symbol("deliv_$s")] = price * ship_raw
        pr[Symbol("dinv_$s")] = price * (y - ship_raw)

        pr[Symbol("unmet_cap_$s")] = max(0.0, demand_cap - (y + inv_lag1))
    end

    ycap_s1 = st[:cap_s1] / p.st_cor_s1
    pr[:ycap_s1] = ycap_s1
    y_pre_s1 = pr[:compute_dem]
    y_cap_limit_s1 = p.bh_util_max_s1 * ycap_s1
    y_s1 = min(y_pre_s1, y_cap_limit_s1)
    binding[:capacity_binding_s1][idx] = y_pre_s1 > y_cap_limit_s1
    pr[:y_s1] = y_s1
    pr[:util_s1] = y_s1 / ycap_s1

    return nothing
end

# ------------------------------------------------------------
# ステップ7: 雇用・所得・消費（§10）
# ------------------------------------------------------------

function _ccc_income!(
    pr::_CCCPeriod,
    st::_CCCState,
    p::NamedTuple,
    opts::CapexCreditCycleOptions,
    binding::_CCCBinding,
    idx::Int,
)
    emp_req_s1 = st[:y_s1_lag1] / p.st_lprod_s1
    emp_req_s2 = st[:y_s2_lag1] / p.st_lprod_s2

    capex_act_s3 =
        p.st_capex_share_s3 * pr[:capex_exec_s1] /
        max(st[:price_s3_lag1], p.st_price_min_s3)
    emp_req_s3 =
        (
            (1 - p.st_cshare_s3) * st[:y_s3_lag1] +
            p.st_cshare_s3 * capex_act_s3 / p.st_capfrac_s3
        ) / p.st_lprod_s3

    emp_req_s5 = st[:y_s5_lag1] / p.st_lprod_s5

    emp_req =
        Dict("s1" => emp_req_s1, "s2" => emp_req_s2, "s3" => emp_req_s3, "s5" => emp_req_s5)

    for s in ("s1", "s2", "s3", "s5")
        emp_lag1 = st[Symbol("emp_$(s)_lag1")]
        gap = emp_req[s] - emp_lag1
        band = getproperty(p, Symbol("bh_emp_band_$s"))
        up = getproperty(p, Symbol("bh_emp_up_$s"))
        down = getproperty(p, Symbol("bh_emp_down_$s"))
        lambda = if abs(gap) <= band * emp_lag1
            0.0
        elseif gap > 0
            up
        else
            down
        end
        emp_raw = emp_lag1 + lambda * gap
        emp = max(emp_raw, 0.0)
        binding[Symbol("emp_floor_binding_$s")][idx] = emp_raw < 0.0
        pr[Symbol("emp_$s")] = emp
    end

    pr[:emp_tot] = pr[:emp_s1] + pr[:emp_s2] + pr[:emp_s3] + pr[:emp_s5]

    wage_raw = st[:wage_lag1] + p.bh_wage_slope * (st[:emp_tot_lag3] / p.st_emp_ref - 1)
    wage = max(wage_raw, p.st_wage_min)
    binding[:wage_floor_binding][idx] = wage_raw < p.st_wage_min
    pr[:wage] = wage

    for s in ("s1", "s2", "s3", "s5")
        wbase = getproperty(p, Symbol("st_wbase_$s"))
        pr[Symbol("wagebill_$s")] = wbase * wage * pr[Symbol("emp_$s")]
    end

    # X-21.4（動学方程式 §21.4）: tax_hh・hh_income は SF（= S1,S2,S3）のみを集約する。
    wagebill_sf = pr[:wagebill_s1] + pr[:wagebill_s2] + pr[:wagebill_s3]
    pr[:tax_hh] = p.pl_tau * wagebill_sf
    pr[:hh_income] = (1 - p.pl_tau) * wagebill_sf

    cons_raw =
        st[:cons_lag1] +
        p.bh_cons_adj * (p.bh_mpc * pr[:hh_income] + p.st_cons_auto - st[:cons_lag1])
    cons = max(cons_raw, 0.0)
    binding[:cons_floor_binding][idx] = cons_raw < 0.0
    pr[:cons] = cons

    cons_s1_raw = p.st_cons_share_s1 * pr[:price_s1] * pr[:y_s1]
    cons_s1 = min(cons_s1_raw, cons)
    binding[:cons_split_binding][idx] = cons_s1_raw > cons
    pr[:cons_s1] = cons_s1
    pr[:cons_s5] = cons - cons_s1

    pr[:xdem_s5] = p.st_xdem0
    pr[:y_s5] = pr[:cons_s5] + pr[:xdem_s5]

    return nothing
end

# ------------------------------------------------------------
# ステップ8: 収益・分配（§11）
# ------------------------------------------------------------

function _ccc_revenue!(
    pr::_CCCPeriod,
    st::_CCCState,
    p::NamedTuple,
    opts::CapexCreditCycleOptions,
    binding::_CCCBinding,
    idx::Int,
)
    eps = opts.div_eps

    for s in _CCC_S23
        price = pr[Symbol("price_$s")]
        y = pr[Symbol("y_$s")]
        sales = price * y
        pr[Symbol("sales_$s")] = sales
        va_share = getproperty(p, Symbol("st_va_share_$s"))
        im = (1 - va_share) * sales
        pr[Symbol("im_$s")] = im
        va = sales - im
        pr[Symbol("va_$s")] = va
        delta = getproperty(p, Symbol("st_delta_$s"))
        dep = delta * st[Symbol("cap_$s")]
        pr[Symbol("dep_$s")] = dep
        wagebill = pr[Symbol("wagebill_$s")]
        profit = va - wagebill - dep
        pr[Symbol("profit_$s")] = profit
        pr[Symbol("margin_$s")] = _ccc_div(profit, sales, eps)
        dinv = pr[Symbol("dinv_$s")]
        pr[Symbol("ocf_$s")] = profit + dep - dinv
    end

    sales_s1 = pr[:price_s1] * pr[:y_s1]
    pr[:sales_s1] = sales_s1
    im_s1 = (1 - p.st_va_share_s1) * sales_s1
    pr[:im_s1] = im_s1
    va_s1 = sales_s1 - im_s1
    pr[:va_s1] = va_s1
    dep_s1 = p.st_delta_s1 * st[:cap_s1]
    pr[:dep_s1] = dep_s1
    profit_s1 = va_s1 - pr[:wagebill_s1] - dep_s1
    pr[:profit_s1] = profit_s1
    pr[:ocf_s1] = profit_s1 + dep_s1

    pr[:im_s5] = 0.0

    for s in _CCC_S13
        ocf = pr[Symbol("ocf_$s")]
        int_burden = pr[Symbol("int_burden_$s")]
        repay = pr[Symbol("repay_$s")]
        pr[Symbol("coverage_$s")] = _ccc_div(ocf, int_burden, eps)
        debt_service = int_burden + repay
        pr[Symbol("debt_service_$s")] = debt_service
        pr[Symbol("dsc_$s")] = _ccc_div(ocf, debt_service, eps)
    end

    I_of = Dict("s1" => pr[:capex_exec_s1], "s2" => pr[:invest_s2], "s3" => pr[:invest_s3])
    for s in _CCC_S13
        I_s = I_of[s]
        ocf = pr[Symbol("ocf_$s")]
        int_burden = pr[Symbol("int_burden_$s")]
        tax = pr[Symbol("tax_$s")]
        div = pr[Symbol("div_$s")]
        repay = pr[Symbol("repay_$s")]
        need = I_s + int_burden + tax + div + repay - ocf
        cash_free = pr[Symbol("cash_free_$s")]
        draw = min(max(0.0, need), cash_free)
        newdebt = max(0.0, need - draw)
        pr[Symbol("draw_$s")] = draw
        pr[Symbol("newdebt_$s")] = newdebt
        newdebt_max = pr[Symbol("newdebt_max_$s")]
        pr[Symbol("funding_forced_$s")] = max(0.0, newdebt - newdebt_max)
        pr[Symbol("nlb_$s")] = ocf - I_s - int_burden - tax - div
    end
    pr[:nlb_s4] = 0.0
    pr[:nlb_s5] = 0.0

    d_s1 = Dict{String, Float64}()
    for s in _CCC_S23
        price = pr[Symbol("price_$s")]
        d_s1[s] = price * pr[Symbol("order_cap_int_$s")]
    end
    pr[:d_s2_s3] = pr[:price_s3] * pr[:order_inv_int_s3]

    d_s5 = Dict{String, Float64}()
    for s in _CCC_S23
        price = pr[Symbol("price_$s")]
        ship_gen = pr[Symbol("ship_gen_$s")]
        order_gen = pr[Symbol("order_gen_$s")]
        ext_demand = pr[Symbol("ext_demand_$s")]
        deliv_gen = price * ship_gen
        denom = max(order_gen + ext_demand, eps) # E11-19 例外: 分母を eps で下限
        gen_frac = order_gen / denom
        d_s5[s] = deliv_gen * gen_frac
    end
    pr[:d_s5_s2] = d_s5["s2"]
    pr[:d_s5_s3] = d_s5["s3"]

    pr[:xsales_s1] = pr[:sales_s1] - pr[:cons_s1]
    pr[:y_tot] = pr[:va_s1] + pr[:va_s2] + pr[:va_s3] + pr[:y_s5]

    wagebill_sf = pr[:wagebill_s1] + pr[:wagebill_s2] + pr[:wagebill_s3]
    pr[:s5_net_sx] =
        wagebill_sf - pr[:tax_hh] - pr[:cons_s1] - pr[:cons_s5] - pr[:d_s5_s2] -
        pr[:d_s5_s3] + pr[:y_s5] - pr[:xdem_s5]

    return nothing
end

# ------------------------------------------------------------
# ステップ9: 残高更新（§12）
# ------------------------------------------------------------

function _ccc_update!(
    pr::_CCCPeriod,
    st::_CCCState,
    p::NamedTuple,
    opts::CapexCreditCycleOptions,
    binding::_CCCBinding,
    idx::Int,
)
    eps = opts.div_eps

    for s in _CCC_S13
        pipe_lag1 = st[Symbol("capex_pipe_$s")]
        pipelag = getproperty(p, Symbol("st_pipelag_$s"))
        capstart = pipe_lag1 / pipelag
        pr[Symbol("capstart_$s")] = capstart

        I_s = s == "s1" ? pr[:capex_exec_s1] : pr[Symbol("invest_$s")]
        pr[Symbol("capex_pipe_$s")] = pipe_lag1 + I_s - capstart # pipe_cancel_s ≡ 0

        dep = pr[Symbol("dep_$s")]
        pr[Symbol("cap_$s")] = st[Symbol("cap_$s")] + capstart - dep # retire_s ≡ 0
    end

    for s in _CCC_S23
        inv_lag1 = st[Symbol("inv_$s")]
        y = pr[Symbol("y_$s")]
        ship = pr[Symbol("ship_$s")]
        inv = inv_lag1 + y - ship
        pr[Symbol("inv_$s")] = inv

        price = pr[Symbol("price_$s")]
        price_lag1 = st[Symbol("price_$(s)_lag1")]
        pr[Symbol("invval_$s")] = price * inv # X-14 改訂: 当期価格で評価
        pr[Symbol("valchg_$s")] = (price - price_lag1) * inv_lag1

        backlog_lag1 = st[Symbol("backlog_$s")]
        order_gen = pr[Symbol("order_gen_$s")]
        ext_demand = pr[Symbol("ext_demand_$s")]
        ship_gen = pr[Symbol("ship_gen_$s")]
        pr[Symbol("backlog_$s")] = backlog_lag1 + order_gen + ext_demand - ship_gen

        y_s = pr[Symbol("y_$s")]
        pr[Symbol("inv_ratio_$s")] = _ccc_div(inv, y_s, eps)
        pr[Symbol("backlog_ratio_$s")] = _ccc_div(pr[Symbol("backlog_$s")], y_s, eps)
    end
    pr[:valchg_s1] = 0.0

    pr[:plan_carry_s1] = st[:plan_carry_s1] - pr[:revive_s1] + pr[:capex_defer_s1]

    I_of = Dict("s1" => pr[:capex_exec_s1], "s2" => pr[:invest_s2], "s3" => pr[:invest_s3])
    for s in _CCC_S13
        ocf = pr[Symbol("ocf_$s")]
        int_burden = pr[Symbol("int_burden_$s")]
        tax = pr[Symbol("tax_$s")]
        div = pr[Symbol("div_$s")]
        I_s = I_of[s]
        newdebt = pr[Symbol("newdebt_$s")]
        repay = pr[Symbol("repay_$s")]
        # equity_issue_s ≡ 0
        pr[Symbol("cash_$s")] =
            st[Symbol("cash_$s")] + ocf - int_burden - tax - div - I_s + newdebt - repay

        # writeoff_s ≡ 0
        debt = st[Symbol("debt_$s")] + newdebt - repay
        pr[Symbol("debt_$s")] = debt

        sales = pr[Symbol("sales_$s")]
        pr[Symbol("leverage_$s")] = _ccc_div(debt, sales, eps)

        invval = s == "s1" ? 0.0 : pr[Symbol("invval_$s")]
        pr[Symbol("nw_$s")] =
            pr[Symbol("cap_$s")] +
            pr[Symbol("capex_pipe_$s")] +
            invval +
            pr[Symbol("cash_$s")] - debt
    end

    pr[:loans_s4] = pr[:debt_s1] + pr[:debt_s2] + pr[:debt_s3]
    pr[:dep_stock_s4] = pr[:cash_s1] + pr[:cash_s2] + pr[:cash_s3]
    pr[:fund_s4] = pr[:loans_s4] - pr[:dep_stock_s4]

    return nothing
end

# ------------------------------------------------------------
# T2（符号制約、§15.3）
# ------------------------------------------------------------

const _CCC_T2_NONNEG = (
    :capex_pipe_s1,
    :capex_pipe_s2,
    :capex_pipe_s3,
    :inv_s2,
    :inv_s3,
    :backlog_s2,
    :backlog_s3,
    :cash_s1,
    :cash_s2,
    :cash_s3,
    :debt_s1,
    :debt_s2,
    :debt_s3,
    :plan_carry_s1,
    :y_s1,
    :y_s2,
    :y_s3,
    :ship_s2,
    :ship_s3,
    :order_s2,
    :order_s3,
    :emp_s1,
    :emp_s2,
    :emp_s3,
    :emp_s5,
    :cons,
    :hh_income,
    :cons_s5,
    :spread,
    :cost_capital_s1,
    :cost_capital_s2,
    :cost_capital_s3,
    :int_burden_s1,
    :int_burden_s2,
    :int_burden_s3,
    :matur_s1,
    :matur_s2,
    :matur_s3,
    :repay_s1,
    :repay_s2,
    :repay_s3,
)
const _CCC_T2_POS = (
    :cap_s1,
    :cap_s2,
    :cap_s3,
    :price_s2,
    :price_s3,
    :wage,
    :equity_val,
    :ai_exp,
    :price_s1,
    :y_tot,
    :emp_tot,
)
const _CCC_T2_UTIL_RANGE = (:util_s1, :util_s2, :util_s3)

"""
    _ccc_check_signs!(warnings, pr, t)

#165 §5 の符号制約（動学方程式 §15.3）を検査する。**クリップしない**（値はそのまま保持
される）。違反は `sign_constraint` 警告として記録するのみで、実装が正しければ通常運用時
は常に成立する（反例テストのみが検出する）。
"""
function _ccc_check_signs!(warnings::Vector{Dict{String, Any}}, pr::_CCCPeriod, t::Int)
    for sym in _CCC_T2_NONNEG
        v = get(pr, sym, NaN)
        if isfinite(v) && v < 0.0
            push!(
                warnings,
                Dict{String, Any}(
                    "code" => "sign_constraint",
                    "period" => t,
                    "sector" => _ccc_sector_of(sym),
                    "detail" => "$(sym) < 0（実値: $v）",
                ),
            )
        end
    end
    for sym in _CCC_T2_POS
        v = get(pr, sym, NaN)
        if isfinite(v) && v <= 0.0
            push!(
                warnings,
                Dict{String, Any}(
                    "code" => "sign_constraint",
                    "period" => t,
                    "sector" => _ccc_sector_of(sym),
                    "detail" => "$(sym) ≤ 0（実値: $v）",
                ),
            )
        end
    end
    for sym in _CCC_T2_UTIL_RANGE
        v = get(pr, sym, NaN)
        if isfinite(v) && !(0.0 <= v <= 1.2)
            push!(
                warnings,
                Dict{String, Any}(
                    "code" => "sign_constraint",
                    "period" => t,
                    "sector" => _ccc_sector_of(sym),
                    "detail" => "$(sym) は [0, 1.2] の範囲外（実値: $v）",
                ),
            )
        end
    end
    return nothing
end

# ------------------------------------------------------------
# 外生パス（baseline・検証・extreme_shock）
# ------------------------------------------------------------

_ccc_exog_baseline_values(p::NamedTuple) = (
    ai_exp = 1.0,
    capex_plan_shock_ex = 1.0,
    spread_shock_ex = 0.0,
    policy_rate = p.st_pol_ref,
    ext_demand_s2 = p.st_extdem_s2,
    ext_demand_s3 = p.st_extdem_s3,
    price_s1 = 1.0,
)

"""
    _ccc_baseline_exog(m, n) -> Dict{Symbol,Vector{Float64}}

`Sc0`相当（外生を定常値に固定）の外生パスを構成する。`exog` が与えられなかった場合の既定値。
"""
function _ccc_baseline_exog(m::CapexCreditCycleModel, n::Int)
    baseline = _ccc_exog_baseline_values(m.params)
    return Dict{Symbol, Vector{Float64}}(
        v => fill(getproperty(baseline, v), n) for v in CAPEX_CC_EXOGENOUS_VARIABLES
    )
end

function _ccc_validate_exog(exog::Dict{Symbol, Vector{Float64}}, n::Int)
    have = Set(keys(exog))
    want = Set(CAPEX_CC_EXOGENOUS_VARIABLES)
    have == want || throw(
        ArgumentError(
            "exog のキー集合が exogenous_variables(m) と一致しません（不足: $(setdiff(want, have))、余剰: $(setdiff(have, want))）",
        ),
    )
    for v in CAPEX_CC_EXOGENOUS_VARIABLES
        length(exog[v]) == n || throw(
            ArgumentError(
                "exog[:$v] の長さ（$(length(exog[v]))）が horizon_runup+horizon_eval=$n と一致しません",
            ),
        )
    end
    return nothing
end

function _ccc_extreme_shock_warnings!(
    warnings::Vector{Dict{String, Any}},
    p::NamedTuple,
    exog::Dict{Symbol, Vector{Float64}},
    idx::Int,
    t::Int,
)
    baseline = _ccc_exog_baseline_values(p)
    for v in CAPEX_CC_EXOGENOUS_VARIABLES
        b = getproperty(baseline, v)
        x = exog[v][idx]
        rel = abs(b) > 1e-12 ? (x - b) / abs(b) : (x - b)
        if abs(rel) > 0.5
            push!(
                warnings,
                Dict{String, Any}(
                    "code" => "extreme_shock",
                    "period" => t,
                    "sector" => "exogenous",
                    "detail" => "$(v): baseline比 $(round(rel * 100; digits = 1))%",
                ),
            )
        end
    end
    return nothing
end

"""
    _ccc_check_runup!(warnings, ss, pr, t, tol)

助走区間（`t < 0`）で当期の全変数が定常水準から `tol`（相対）以内であることを検査する
（契約 §2.1）。逸脱した場合、最大乖離の変数名と乖離幅を1件の `runup_deviation` 警告として
記録する。
"""
function _ccc_check_runup!(
    warnings::Vector{Dict{String, Any}},
    ss::NamedTuple,
    pr::_CCCPeriod,
    t::Int,
    tol::Float64,
)
    worst_name = :none
    worst_rel = 0.0
    for nm in keys(pr)
        hasproperty(ss, nm) || continue
        target = getproperty(ss, nm)
        actual = pr[nm]
        (isfinite(target) && isfinite(actual)) || continue
        rel = abs(actual - target) / max(abs(target), 1.0)
        if rel > worst_rel
            worst_rel = rel
            worst_name = nm
        end
    end
    if worst_rel > tol
        push!(
            warnings,
            Dict{String, Any}(
                "code" => "runup_deviation",
                "period" => t,
                "sector" => "aggregate",
                "detail" => "最大乖離: $(worst_name)（相対乖離 $(worst_rel)）",
            ),
        )
    end
    return nothing
end

# ------------------------------------------------------------
# 結果型（統合設計 §5.2）
# ------------------------------------------------------------

"""
    CapexCreditCycleRun

`capex_run` の完全な結果。`series` は `simulate` の返り値と同一。`accounting`・
`diagnostics` は `I-3`・`I-5` の責務であり、本ファイル（`I-2`）では常に `nothing`。
"""
struct CapexCreditCycleRun
    model_name::String
    scenario::Symbol
    series::NamedTuple
    exog::Dict{Symbol, Vector{Float64}}
    periods::Vector{Int}
    state0::NamedTuple
    warnings::Vector{Dict{String, Any}}
    termination_reason::Symbol
    termination_period::Union{Int, Nothing}
    divergence_time::Union{Int, Nothing}
    binding::Dict{Symbol, Vector{Bool}}
    accounting::Any
    diagnostics::Any
    options::CapexCreditCycleOptions
    metadata::Dict{String, Any}
end

# ------------------------------------------------------------
# simulate / capex_run（統合設計 §4.4）
# ------------------------------------------------------------

const _CCC_DEVIATIONS = [
    Dict{String, Any}(
        "id" => "I-2-emp-wage-lag",
        "detail" =>
            "emp_s1–_s3/_s5・wage（E10-07・E10-09）は自身の前期値を参照する再帰式だが、" *
            "動学方程式 §13.5 の遅延バッファ一覧に含まれていない。式を評価可能にするため深さ1" *
            "バッファを5本追加した（状態次元 65→70）。経済的判断ではなく機械的な追加であり、" *
            "上流文書（#169 §13.5）への差し戻し事項として保持する。",
    ),
    Dict{String, Any}(
        "id" => "I-2-inv-gap-sp",
        "detail" =>
            "E6-14（inv_gap_s、s∈SP）から capex_pipe_s[t−1] の減算を外した。#169 §14.2 の" *
            "逆較正（bh_util_tgt_s=util_s^ss・st_cor_s=cap_s^ss·util_s^ss/y_s^ss）の下では" *
            "target_cap_s^ss=cap_s^ssが構造的に導かれ、pipeを減算するとinv_gap_s^ss=" *
            "-capex_pipe_s^ss（非ゼロ）となり、bh_alpha_inv_s>0のもとでbaselineが定常に" *
            "留まらない（§7.4-2の受け入れ条件と両立しない）。§6.2の選択肢(b)（稼働資本のみと" *
            "比較）をSPに適用する上流への差し戻し事項として保持する。",
    ),
    Dict{String, Any}(
        "id" => "E4(i)",
        "detail" =>
            "L27（PROFIT_s → EQUITY_VAL）を遅れ1で実装した（動学方程式 §17・§21.8、期内処理順序" *
            "の制約による）。",
    ),
]

"""
    simulate(m::CapexCreditCycleModel; scenario=:Sc0, exog=nothing, state0=nothing,
             options=CapexCreditCycleOptions()) -> NamedTuple

`capex_run(...).series` を返す（統合設計 §4.4）。既存の汎用コード（`to_simulation_result`・
比較 API）が分岐なしに使えるよう、系列のみの `NamedTuple` を返す。
"""
function simulate(
    m::CapexCreditCycleModel;
    scenario::Symbol = :Sc0,
    exog::Union{Dict{Symbol, Vector{Float64}}, Nothing} = nothing,
    state0 = nothing,
    options::CapexCreditCycleOptions = CapexCreditCycleOptions(),
)
    run = capex_run(
        m;
        scenario = scenario,
        exog = exog,
        state0 = state0,
        options = options,
        validate_accounting = false,
        diagnostics = false,
    )
    return run.series
end

"""
    capex_run(m::CapexCreditCycleModel; scenario=:Sc0, exog=nothing, state0=nothing,
              options=CapexCreditCycleOptions(), validate_accounting=true, diagnostics=true,
              thresholds=nothing) -> CapexCreditCycleRun

期内処理順序10ステップ（動学方程式 §3.1・§5–§12）に沿って `horizon_runup+horizon_eval`
期を前向きに1回ずつ計算する（陽解法、期内に反復・非線形ソルバを用いない）。`validate_accounting`・
`diagnostics`・`thresholds` は `I-3`・`I-5` 実装後に接続するためのキーワードであり、本ファイル
（`I-2`）では受理するが `run.accounting` / `run.diagnostics` は常に `nothing` を返す。
"""
function capex_run(
    m::CapexCreditCycleModel;
    scenario::Symbol = :Sc0,
    exog::Union{Dict{Symbol, Vector{Float64}}, Nothing} = nothing,
    state0 = nothing,
    options::CapexCreditCycleOptions = CapexCreditCycleOptions(),
    validate_accounting::Bool = true,
    diagnostics::Bool = true,
    thresholds = nothing,
)
    report = capex_steady_state_report(m)
    passed(report) || throw(
        ArgumentError(
            "モデルの定常状態が動学方程式 §14.3 の条件を満たしていません" *
            "（simulate の入力検査、ADR 0013 決定14）: " *
            join(
                [
                    "$k（residual=$(v.residual), tolerance=$(v.tolerance)）" for
                    (k, v) in report.checks if !v.passed
                ],
                ", ",
            ),
        ),
    )

    p = m.params
    n = options.horizon_runup + options.horizon_eval
    periods = collect((-options.horizon_runup):(options.horizon_eval - 1))

    ss = steady_state(m)
    exog_full = exog === nothing ? _ccc_baseline_exog(m, n) : exog
    _ccc_validate_exog(exog_full, n)

    st0_dict =
        state0 === nothing ? _ccc_state0_from_steady(m) :
        _ccc_state_dict_from_namedtuple(state0)
    state_vars = _ccc_state_variables()
    state0_nt = NamedTuple{Tuple(state_vars)}(Tuple(st0_dict[s] for s in state_vars))

    binding = _CCCBinding(k => falses(n) for k in _ccc_default_binding_keys())
    warnings = Dict{String, Any}[]

    unique_names = vcat(
        collect(_CCC_STATE_BASE),
        _ccc_control_variables(),
        collect(CAPEX_CC_EXOGENOUS_VARIABLES),
        _ccc_diagnostic_variables(),
    )
    series = Dict{Symbol, Vector{Float64}}(nm => fill(NaN, n) for nm in unique_names)

    st = st0_dict
    termination_reason = :completed
    termination_period = nothing
    divergence_time = nothing
    terminated = false

    for (idx, t) in enumerate(periods)
        terminated && continue

        pr = _CCCPeriod()
        _ccc_apply_exog!(pr, exog_full, idx)
        _ccc_financial!(pr, st, p, options, binding, idx)
        _ccc_plan!(pr, st, p, options, binding, idx)
        _ccc_funding!(pr, st, p, options, binding, idx)
        _ccc_orders!(pr, st, p, options, binding, idx)
        _ccc_production!(pr, st, p, options, binding, idx)
        _ccc_income!(pr, st, p, options, binding, idx)
        _ccc_revenue!(pr, st, p, options, binding, idx)
        _ccc_update!(pr, st, p, options, binding, idx)

        for s in _CCC_S23
            if pr[Symbol("unmet_cap_$s")] > 0.0
                push!(
                    warnings,
                    Dict{String, Any}(
                        "code" => "a2_violation",
                        "period" => t,
                        "sector" => s,
                        "detail" => "unmet_cap_$s = $(pr[Symbol("unmet_cap_$s")])",
                    ),
                )
            end
        end
        for s in _CCC_S13
            if pr[Symbol("funding_forced_$s")] > 0.0
                push!(
                    warnings,
                    Dict{String, Any}(
                        "code" => "funding_forced",
                        "period" => t,
                        "sector" => s,
                        "detail" => "funding_forced_$s = $(pr[Symbol("funding_forced_$s")])",
                    ),
                )
            end
            if pr[Symbol("liquidity_gap_$s")] > 0.0
                push!(
                    warnings,
                    Dict{String, Any}(
                        "code" => "liquidity_gap",
                        "period" => t,
                        "sector" => s,
                        "detail" => "liquidity_gap_$s = $(pr[Symbol("liquidity_gap_$s")])",
                    ),
                )
            end
            cash_min = getproperty(p, Symbol("st_cash_min_$s"))
            sales_lag1 = st[Symbol("sales_$(s)_lag1")]
            if pr[Symbol("cash_$s")] < cash_min * sales_lag1
                push!(
                    warnings,
                    Dict{String, Any}(
                        "code" => "cash_below_min",
                        "period" => t,
                        "sector" => s,
                        "detail" => "cash_$s = $(pr[Symbol("cash_$s")])",
                    ),
                )
            end
        end
        _ccc_extreme_shock_warnings!(warnings, p, exog_full, idx, t)
        _ccc_check_signs!(warnings, pr, t)
        sign_fatal =
            options.stop_on_sign_violation &&
            any(w -> w["code"] == "sign_constraint" && w["period"] == t, warnings)

        newst = _CCCState()
        _ccc_shift_state!(newst, pr, st)
        state_finite = all(isfinite(v) for v in values(newst))
        state_bounded =
            state_finite && all(abs(v) <= options.guard_max for v in values(newst))

        if state_finite && state_bounded
            for nm in unique_names
                series[nm][idx] = haskey(pr, nm) ? pr[nm] : get(newst, nm, NaN)
            end
            if t < 0
                _ccc_check_runup!(warnings, ss, pr, t, options.runup_tol)
            end
            st = newst
            if sign_fatal
                termination_reason = :sign_constraint_fatal
                termination_period = t
                terminated = true
            end
        else
            for nm in unique_names
                series[nm][idx] = NaN
            end
            termination_reason = state_finite ? :divergence_guard : :non_finite_state
            termination_period = t
            state_finite && (divergence_time = t)
            terminated = true
        end
    end

    series_nt = NamedTuple{Tuple(unique_names)}(Tuple(series[nm] for nm in unique_names))

    metadata = Dict{String, Any}(
        "equations_version" => "capex-credit-cycle-equations/1.1.0",
        "unit_conversions" => Dict{String, String}(
            "bp_to_pct_pt" => "spread / 100",
            "annual_to_quarter" => "r * 0.25",
            "maturity_to_rate" => "dt / st_maturity_s",
        ),
        "deviations" => _CCC_DEVIATIONS,
        "measure" => "level",
    )

    return CapexCreditCycleRun(
        model_name(m),
        scenario,
        series_nt,
        exog_full,
        periods,
        state0_nt,
        warnings,
        termination_reason,
        termination_period,
        divergence_time,
        binding,
        nothing,
        nothing,
        options,
        metadata,
    )
end

# ============================================================
# SimulationResult 変換・metadata 予約キー20個（統合設計 §6.1、`I-6`）
# ============================================================

# 変数メタデータ表: symbol => (sector, unit, timing, observability)。
# 出所:
#   sector・unit・timing: 部門境界と変数定義 §5.2-§5.7（`capex-credit-cycle-vars/1.2.0`）。
#     `r_eff_s` の単位は `X-26` により「年率・小数」（`int_burden_s = r_eff_s·Δt·debt_s[t-1]`
#     が10億ドル/四半期になるための小数表現）。
#   observability（D/C/P/E/A）: 観測方程式・識別戦略・検証方針 §3.2-§3.3
#     （`capex-credit-cycle-empirical/1.1.0`）。§3.2 が明示しない会計追加変数（`1.1.0` で追加、
#     部門境界 §5.7）は、構成要素の分類のうち最も弱いもの（`A` > `E` > `P` > `C` > `D` の順に
#     保守側）を採用する（保守的符号化の原則、#170 §3.1 契約3）。
# state・control・exogenous・diagnostic のいずれの役割一覧（`_ccc_*_variables` 系）とも
# 過不足なく対応することを §7.1-11 のテストで検査する。
const _CCC_VAR_META = Dict{Symbol, NTuple{4, String}}(
    # ---- state（22） ----
    :cap_s1 => ("s1", "10億ドル", "EOP", "P"),
    :capex_pipe_s1 => ("s1", "10億ドル", "EOP", "E"),
    :cash_s1 => ("s1", "10億ドル", "EOP", "A"),
    :plan_carry_s1 => ("s1", "10億ドル", "EOP", "A"),
    :debt_s1 => ("s1", "10億ドル", "EOP", "P"),
    :r_eff_s1 => ("s1", "年率・小数", "AVG", "E"),
    :cap_s2 => ("s2", "10億ドル", "EOP", "P"),
    :capex_pipe_s2 => ("s2", "10億ドル", "EOP", "E"),
    :backlog_s2 => ("s2", "10億ドル", "EOP", "D"),
    :inv_s2 => ("s2", "10億ドル", "EOP", "D"),
    :cash_s2 => ("s2", "10億ドル", "EOP", "P"),
    :debt_s2 => ("s2", "10億ドル", "EOP", "P"),
    :r_eff_s2 => ("s2", "年率・小数", "AVG", "E"),
    :advance_s2 => ("s2", "10億ドル", "EOP", "A"),
    :cap_s3 => ("s3", "10億ドル", "EOP", "P"),
    :capex_pipe_s3 => ("s3", "10億ドル", "EOP", "E"),
    :backlog_s3 => ("s3", "10億ドル", "EOP", "P"),
    :inv_s3 => ("s3", "10億ドル", "EOP", "D"),
    :cash_s3 => ("s3", "10億ドル", "EOP", "P"),
    :debt_s3 => ("s3", "10億ドル", "EOP", "P"),
    :r_eff_s3 => ("s3", "年率・小数", "AVG", "E"),
    :advance_s3 => ("s3", "10億ドル", "EOP", "A"),
    # ---- control（33） ----
    :compute_dem => ("s1", "10億ドル/四半期", "SUM", "P"),
    :target_cap_s1 => ("s1", "10億ドル", "EOP", "E"),
    :capex_plan_s1 => ("s1", "10億ドル/四半期", "SUM", "A"),
    :capex_exec_s1 => ("s1", "10億ドル/四半期", "SUM", "C"),
    :cancel_s1 => ("s1", "—", "AVG", "A"),
    :y_s1 => ("s1", "10億ドル/四半期", "SUM", "P"),
    :emp_s1 => ("s1", "百万人", "AVG", "D"),
    :capex_defer_s1 => ("s1", "10億ドル/四半期", "SUM", "A"),
    :order_s2 => ("s2", "10億ドル/四半期", "SUM", "D"),
    :price_s2 => ("s2", "—", "AVG", "D"),
    :y_s2 => ("s2", "10億ドル/四半期", "SUM", "C"),
    :ship_s2 => ("s2", "10億ドル/四半期", "SUM", "D"),
    :invest_s2 => ("s2", "10億ドル/四半期", "SUM", "P"),
    :emp_s2 => ("s2", "百万人", "AVG", "D"),
    :order_s3 => ("s3", "10億ドル/四半期", "SUM", "C"),
    :price_s3 => ("s3", "—", "AVG", "D"),
    :y_s3 => ("s3", "10億ドル/四半期", "SUM", "C"),
    :ship_s3 => ("s3", "10億ドル/四半期", "SUM", "D"),
    :invest_s3 => ("s3", "10億ドル/四半期", "SUM", "P"),
    :emp_s3 => ("s3", "百万人", "AVG", "D"),
    :equity_val => ("s4", "—", "AVG", "P"),
    :collateral => ("s4", "10億ドル", "EOP", "E"),
    :spread => ("s4", "bp", "AVG", "D"),
    :rollover => ("s4", "—", "AVG", "P"),
    :lend_stance => ("s4", "標準化", "AVG", "D"),
    :fin_cond => ("s4", "標準化", "AVG", "D"),
    :cost_capital_s1 => ("s1", "年率%", "AVG", "E"),
    :cost_capital_s2 => ("s2", "年率%", "AVG", "E"),
    :cost_capital_s3 => ("s3", "年率%", "AVG", "E"),
    :emp_s5 => ("s5", "百万人", "AVG", "C"),
    :wage => ("s5", "—", "AVG", "C"),
    :cons => ("s5", "10億ドル/四半期", "SUM", "P"),
    :y_s5 => ("s5", "10億ドル/四半期", "SUM", "C"),
    # ---- exogenous（7） ----
    :ai_exp => ("s1", "—", "AVG", "A"),
    :capex_plan_shock_ex => ("s1", "baseline比%", "SUM", "A"),
    :spread_shock_ex => ("s4", "bp", "AVG", "A"),
    :policy_rate => ("s4", "年率%", "AVG", "D"),
    :ext_demand_s2 => ("s2", "10億ドル/四半期", "SUM", "C"),
    :ext_demand_s3 => ("s3", "10億ドル/四半期", "SUM", "C"),
    :price_s1 => ("s1", "—", "AVG", "P"),
    # ---- diagnostic: common ----
    :ycap_s1 => ("s1", "10億ドル/四半期", "SUM", "E"),
    :util_s1 => ("s1", "—", "AVG", "E"),
    :sales_s1 => ("s1", "10億ドル/四半期", "SUM", "A"),
    :profit_s1 => ("s1", "10億ドル/四半期", "SUM", "A"),
    :ocf_s1 => ("s1", "10億ドル/四半期", "SUM", "A"),
    :va_s1 => ("s1", "10億ドル/四半期", "SUM", "P"),
    :backlog_ratio_s2 => ("s2", "四半期", "EOP", "C"),
    :backlog_ratio_s3 => ("s3", "四半期", "EOP", "C"),
    :inv_ratio_s2 => ("s2", "四半期", "EOP", "D"),
    :inv_ratio_s3 => ("s3", "四半期", "EOP", "D"),
    :ycap_s2 => ("s2", "10億ドル/四半期", "SUM", "P"),
    :ycap_s3 => ("s3", "10億ドル/四半期", "SUM", "P"),
    :util_s2 => ("s2", "—", "AVG", "D"),
    :util_s3 => ("s3", "—", "AVG", "D"),
    :deliv_s2 => ("s2", "10億ドル/四半期", "SUM", "D"),
    :deliv_s3 => ("s3", "10億ドル/四半期", "SUM", "D"),
    :va_s2 => ("s2", "10億ドル/四半期", "SUM", "D"),
    :va_s3 => ("s3", "10億ドル/四半期", "SUM", "D"),
    :sales_s2 => ("s2", "10億ドル/四半期", "SUM", "C"),
    :sales_s3 => ("s3", "10億ドル/四半期", "SUM", "C"),
    :profit_s2 => ("s2", "10億ドル/四半期", "SUM", "P"),
    :profit_s3 => ("s3", "10億ドル/四半期", "SUM", "P"),
    :margin_s2 => ("s2", "—", "AVG", "P"),
    :margin_s3 => ("s3", "—", "AVG", "P"),
    :ocf_s2 => ("s2", "10億ドル/四半期", "SUM", "C"),
    :ocf_s3 => ("s3", "10億ドル/四半期", "SUM", "C"),
    :coverage_agg => ("s4", "倍", "AVG", "C"),
    :int_burden_s1 => ("s1", "10億ドル/四半期", "SUM", "P"),
    :int_burden_s2 => ("s2", "10億ドル/四半期", "SUM", "P"),
    :int_burden_s3 => ("s3", "10億ドル/四半期", "SUM", "P"),
    :debt_service_s1 => ("s1", "10億ドル/四半期", "SUM", "A"),
    :debt_service_s2 => ("s2", "10億ドル/四半期", "SUM", "A"),
    :debt_service_s3 => ("s3", "10億ドル/四半期", "SUM", "A"),
    :coverage_s1 => ("s1", "倍", "AVG", "C"),
    :coverage_s2 => ("s2", "倍", "AVG", "C"),
    :coverage_s3 => ("s3", "倍", "AVG", "C"),
    :leverage_s1 => ("s1", "—", "EOP", "C"),
    :leverage_s2 => ("s2", "—", "EOP", "C"),
    :leverage_s3 => ("s3", "—", "EOP", "C"),
    :spread_endo => ("s4", "bp", "AVG", "A"),
    :emp_tot => ("total", "百万人", "AVG", "D"),
    :hh_income => ("s5", "10億ドル/四半期", "SUM", "P"),
    :y_tot => ("total", "10億ドル/四半期", "SUM", "D"),
    :dinv_s2 => ("s2", "10億ドル/四半期", "SUM", "C"),
    :dinv_s3 => ("s3", "10億ドル/四半期", "SUM", "C"),
    :cons_s1 => ("s1", "10億ドル/四半期", "SUM", "A"),
    :cons_s5 => ("s5", "10億ドル/四半期", "SUM", "A"),
    :xsales_s1 => ("s1", "10億ドル/四半期", "SUM", "A"),
    :im_s1 => ("s1", "10億ドル/四半期", "SUM", "A"),
    :im_s2 => ("s2", "10億ドル/四半期", "SUM", "C"),
    :im_s3 => ("s3", "10億ドル/四半期", "SUM", "C"),
    :im_s5 => ("s5", "10億ドル/四半期", "SUM", "C"),
    :wagebill_s1 => ("s1", "10億ドル/四半期", "SUM", "C"),
    :wagebill_s2 => ("s2", "10億ドル/四半期", "SUM", "C"),
    :wagebill_s3 => ("s3", "10億ドル/四半期", "SUM", "C"),
    :wagebill_s5 => ("s5", "10億ドル/四半期", "SUM", "C"),
    :dep_s1 => ("s1", "10億ドル/四半期", "SUM", "P"),
    :dep_s2 => ("s2", "10億ドル/四半期", "SUM", "P"),
    :dep_s3 => ("s3", "10億ドル/四半期", "SUM", "P"),
    :capex_cancel_s1 => ("s1", "10億ドル/四半期", "SUM", "A"),
    :matur_s1 => ("s1", "10億ドル/四半期", "SUM", "E"),
    :matur_s2 => ("s2", "10億ドル/四半期", "SUM", "E"),
    :matur_s3 => ("s3", "10億ドル/四半期", "SUM", "E"),
    :repay_s1 => ("s1", "10億ドル/四半期", "SUM", "A"),
    :repay_s2 => ("s2", "10億ドル/四半期", "SUM", "A"),
    :repay_s3 => ("s3", "10億ドル/四半期", "SUM", "A"),
    :tax_hh => ("s5", "10億ドル/四半期", "SUM", "C"),
    :s5_net_sx => ("s5", "10億ドル/四半期", "SUM", "A"),
    :nlb_s1 => ("s1", "10億ドル/四半期", "SUM", "A"),
    :nlb_s2 => ("s2", "10億ドル/四半期", "SUM", "A"),
    :nlb_s3 => ("s3", "10億ドル/四半期", "SUM", "A"),
    :nlb_s4 => ("s4", "10億ドル/四半期", "SUM", "A"),
    :nlb_s5 => ("s5", "10億ドル/四半期", "SUM", "A"),
    :invval_s2 => ("s2", "10億ドル", "EOP", "P"),
    :invval_s3 => ("s3", "10億ドル", "EOP", "P"),
    :nw_s1 => ("s1", "10億ドル", "EOP", "A"),
    :nw_s2 => ("s2", "10億ドル", "EOP", "P"),
    :nw_s3 => ("s3", "10億ドル", "EOP", "P"),
    :loans_s4 => ("s4", "10億ドル", "EOP", "P"),
    :dep_stock_s4 => ("s4", "10億ドル", "EOP", "A"),
    :fund_s4 => ("s4", "10億ドル", "EOP", "A"),
    :dsc_s1 => ("s1", "倍", "AVG", "A"),
    :dsc_s2 => ("s2", "倍", "AVG", "A"),
    :dsc_s3 => ("s3", "倍", "AVG", "A"),
    :rollover_gap_s1 => ("s1", "10億ドル/四半期", "SUM", "E"),
    :rollover_gap_s2 => ("s2", "10億ドル/四半期", "SUM", "E"),
    :rollover_gap_s3 => ("s3", "10億ドル/四半期", "SUM", "E"),
    :liquidity_gap_s1 => ("s1", "10億ドル/四半期", "SUM", "A"),
    :liquidity_gap_s2 => ("s2", "10億ドル/四半期", "SUM", "A"),
    :liquidity_gap_s3 => ("s3", "10億ドル/四半期", "SUM", "A"),
    :funding_forced_s1 => ("s1", "10億ドル/四半期", "SUM", "A"),
    :funding_forced_s2 => ("s2", "10億ドル/四半期", "SUM", "A"),
    :funding_forced_s3 => ("s3", "10億ドル/四半期", "SUM", "A"),
    :unmet_cap_s2 => ("s2", "10億ドル/四半期", "SUM", "A"),
    :unmet_cap_s3 => ("s3", "10億ドル/四半期", "SUM", "A"),
    :order_gen_s2 => ("s2", "10億ドル/四半期", "SUM", "C"),
    :order_gen_s3 => ("s3", "10億ドル/四半期", "SUM", "C"),
    # ---- diagnostic: X-03 reclassified（control→diagnostic、34） ----
    :capex_plan_eff_s1 => ("s1", "10億ドル/四半期", "SUM", "A"),
    :capex_sx_s1 => ("s1", "10億ドル/四半期", "SUM", "A"),
    :refin_s1 => ("s1", "10億ドル/四半期", "SUM", "A"),
    :refin_s2 => ("s2", "10億ドル/四半期", "SUM", "A"),
    :refin_s3 => ("s3", "10億ドル/四半期", "SUM", "A"),
    :capstart_s1 => ("s1", "10億ドル/四半期", "SUM", "E"),
    :capstart_s2 => ("s2", "10億ドル/四半期", "SUM", "E"),
    :capstart_s3 => ("s3", "10億ドル/四半期", "SUM", "E"),
    :retire_s1 => ("s1", "10億ドル/四半期", "SUM", "A"),
    :retire_s2 => ("s2", "10億ドル/四半期", "SUM", "A"),
    :retire_s3 => ("s3", "10億ドル/四半期", "SUM", "A"),
    :pipe_cancel_s1 => ("s1", "10億ドル/四半期", "SUM", "A"),
    :pipe_cancel_s2 => ("s2", "10億ドル/四半期", "SUM", "A"),
    :pipe_cancel_s3 => ("s3", "10億ドル/四半期", "SUM", "A"),
    :newdebt_s1 => ("s1", "10億ドル/四半期", "SUM", "A"),
    :newdebt_s2 => ("s2", "10億ドル/四半期", "SUM", "A"),
    :newdebt_s3 => ("s3", "10億ドル/四半期", "SUM", "A"),
    :writeoff_s1 => ("s1", "10億ドル/四半期", "SUM", "A"),
    :writeoff_s2 => ("s2", "10億ドル/四半期", "SUM", "A"),
    :writeoff_s3 => ("s3", "10億ドル/四半期", "SUM", "A"),
    :equity_issue_s1 => ("s1", "10億ドル/四半期", "SUM", "A"),
    :equity_issue_s2 => ("s2", "10億ドル/四半期", "SUM", "A"),
    :equity_issue_s3 => ("s3", "10億ドル/四半期", "SUM", "A"),
    :div_s1 => ("s1", "10億ドル/四半期", "SUM", "A"),
    :div_s2 => ("s2", "10億ドル/四半期", "SUM", "A"),
    :div_s3 => ("s3", "10億ドル/四半期", "SUM", "A"),
    :tax_s1 => ("s1", "10億ドル/四半期", "SUM", "A"),
    :tax_s2 => ("s2", "10億ドル/四半期", "SUM", "A"),
    :tax_s3 => ("s3", "10億ドル/四半期", "SUM", "A"),
    :valchg_s1 => ("s1", "10億ドル/四半期", "SUM", "A"),
    :valchg_s2 => ("s2", "10億ドル/四半期", "SUM", "A"),
    :valchg_s3 => ("s3", "10億ドル/四半期", "SUM", "A"),
    :inv_sx_s2 => ("s2", "10億ドル/四半期", "SUM", "A"),
    :inv_sx_s3 => ("s3", "10億ドル/四半期", "SUM", "A"),
    :xdem_s5 => ("s5", "10億ドル/四半期", "SUM", "A"),
)

# 役割 role は §4.2 の判定規則の適用結果として `_ccc_*_variables` 系がすでに保持しており、
# ここでは再判定せず引き写す（役割の正本は各リスト、`_CCC_VAR_META` は sector/unit/timing/
# observability のみを保持する）。
function _ccc_variable_roles()
    roles = Dict{String, String}()
    for s in _CCC_STATE_BASE
        roles[String(s)] = "state"
    end
    for s in _ccc_control_variables()
        roles[String(s)] = "control"
    end
    for s in CAPEX_CC_EXOGENOUS_VARIABLES
        roles[String(s)] = "exogenous"
    end
    for s in _ccc_diagnostic_variables()
        roles[String(s)] = "diagnostic"
    end
    return roles
end

function _ccc_variable_metadata_dicts()
    sectors = Dict{String, String}()
    units = Dict{String, String}()
    timing = Dict{String, String}()
    observability = Dict{String, String}()
    for (sym, (sector, unit, tm, obs)) in _CCC_VAR_META
        k = String(sym)
        sectors[k] = sector
        units[k] = unit
        timing[k] = tm
        observability[k] = obs
    end
    return (
        roles = _ccc_variable_roles(),
        sectors = sectors,
        units = units,
        timing = timing,
        observability = observability,
    )
end

# ショック1件を metadata へ String 化する（分析契約 §5.2 の指定必須7項目 + magnitude +
# application_mode）。
function _ccc_shock_spec_dict(shock)
    return Dict{String, Any}(
        "target" => String(shock.target),
        "meaning" => shock.meaning,
        "unit" => shock.unit,
        "sign" => shock.sign,
        "timing" => shock.timing,
        "shape" => String(shock.shape),
        "duration" => shock.duration,
        "magnitude" => shock.magnitude,
        "application_mode" => String(shock.application_mode),
    )
end

"""
    _ccc_scenario_metadata(scenario_id::Symbol) -> Dict{String,Any}

`metadata["scenario"]` の値を構成する。`scenario_id` が `CAPEX_CC_SCENARIO_IDS` に含まれる
場合は `capex_scenario(scenario_id)` の正準定義（ショック仕様7項目 + magnitude +
application_mode）を用いる。`capex_run` に独自の `exog` を与えて任意の `scenario` ラベルで
実行した場合（カノニカルなシナリオIDでない場合）は、ショック仕様が存在しないため空配列を返す
（統合設計 §4.4 の「`exog` を優先し `scenario` はラベルの記録にのみ用いる」契約に対応）。
"""
function _ccc_scenario_metadata(scenario_id::Symbol)
    if scenario_id in CAPEX_CC_SCENARIO_IDS
        sc = capex_scenario(scenario_id)
        return Dict{String, Any}(
            "id" => String(sc.id),
            "name" => sc.name,
            "shocks" => [_ccc_shock_spec_dict(s) for s in sc.shocks],
        )
    end
    return Dict{String, Any}(
        "id" => String(scenario_id),
        "name" => String(scenario_id),
        "shocks" => Any[],
    )
end

# `CapexDiagnosticThresholds` の全フィールドを metadata へ String 化する。
function _ccc_diagnostic_threshold_set(thresholds)
    values = Dict{String, Any}()
    for fname in fieldnames(typeof(thresholds))
        fname in (:id, :version) && continue
        values[String(fname)] = getfield(thresholds, fname)
    end
    return Dict{String, Any}(
        "id" => thresholds.id,
        "version" => thresholds.version,
        "values" => values,
    )
end

"""
    to_simulation_result(m::CapexCreditCycleModel, run::CapexCreditCycleRun,
                         scenario_name::AbstractString = String(run.scenario)) -> SimulationResult

`run.series`（統合設計 §6.2 の公開系列）を `SimulationResult` へ変換し、metadata 予約キー
20個 + 補助3キー（統合設計 §6.1）を設定する。会計表（`Vector{SFCPeriodSnapshot}`）・診断ラベル
（`Vector{Symbol}`）・`binding` フラグ（`Vector{Bool}`）・スカラーの診断量は `Vector{Float64}`
で表せないため `variables` に含めない（`capex_accounting_snapshots` / `capex_diagnostics` /
`run.binding` から別途取得する）。

`run.diagnostics` が `nothing`（`capex_run` の既定は診断を計算しない）の場合、
`metadata["diagnostic_threshold_set"]` は既定の `CapexDiagnosticThresholds()` を用いる。
"""
function to_simulation_result(
    m::CapexCreditCycleModel,
    run::CapexCreditCycleRun,
    scenario_name::AbstractString = String(run.scenario),
)
    variables =
        Dict{String, Vector{Float64}}(String(k) => v for (k, v) in pairs(run.series))
    dicts = _ccc_variable_metadata_dicts()

    thresholds =
        run.diagnostics === nothing ? CapexDiagnosticThresholds() :
        run.diagnostics.thresholds
    cv = m.contract_versions

    metadata = Dict{String, Any}(
        "parameters" =>
            Dict{String, Any}(String(k) => v for (k, v) in pairs(parameters(m))),
        "variable_roles" => dicts.roles,
        "variable_sectors" => dicts.sectors,
        "variable_units" => dicts.units,
        "variable_timing" => dicts.timing,
        "variable_observability" => dicts.observability,
        "contract_version" => cv.contract_version,
        "graph_version" => cv.graph_version,
        "vars_version" => cv.vars_version,
        "accounting_version" => cv.accounting_version,
        "boundaries_version" => cv.boundaries_version,
        "equations_version" => cv.equations_version,
        "empirical_version" => cv.empirical_version,
        "model_version" => cv.model_version,
        "scenario" => _ccc_scenario_metadata(run.scenario),
        "diagnostic_threshold_set" => _ccc_diagnostic_threshold_set(thresholds),
        "termination_reason" => String(run.termination_reason),
        "termination_period" => run.termination_period,
        "divergence_time" => run.divergence_time,
        "warnings" => run.warnings,
        "unit_conversions" =>
            get(run.metadata, "unit_conversions", Dict{String, String}()),
        "deviations" => get(run.metadata, "deviations", Any[]),
        "measure" => get(run.metadata, "measure", "level"),
    )

    return SimulationResult(model_name(m), String(scenario_name), variables, metadata)
end
