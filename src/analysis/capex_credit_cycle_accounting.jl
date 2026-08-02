# capex_credit_cycle_accounting.jl: 部門別CAPEX・信用循環モデル（`CapexCreditCycleModel`）専用の
# 会計表構築・会計恒等式検証（Issue #181 / `I-3`）。
#
# 既存の SFC 会計プリミティブ（`src/sfc/types.jl`）と汎用検証エンジン
# （`src/analysis/sfc_accounting.jl`）を再利用する読み取り専用の後処理層。`SFCResult` は
# 返さない（ADR 0013 決定15）。会計表は `Vector{SFCPeriodSnapshot}` として返す。
#
# 設計契約:
#   docs/models/capex_credit_cycle_stock_flow.md §14（正本節。§3-§8 の本文は §14 で改訂されている）
#   docs/architecture/capex_credit_cycle_integration.md §3.2・§4.8・§7.3
#   docs/adr/0013-capex-credit-cycle-integration-contract.md 決定4・6・9・15
#
# 検証 1–5（`:balance_row_sum`・`:balance_column_sum`・`:flow_row_sum`・`:flow_column_sum`・
# `:stock_flow`）は `validate_sfc_accounting` をそのまま呼び、対象外の行・列（会計仕様 §8.1
# 「検証対象に含めないもの」）を後処理で除外する。検証 6–12 はモデル固有に実装し、同じ
# `AccountingCheckReport` へ統合する。

"""
    CAPEX_CC_ACCOUNTING_VERSION

会計層の methodology version。会計仕様 `capex-credit-cycle-accounting/1.1.0`
（ストック・フロー会計表 §15 改訂履歴）に対応する。
"""
const CAPEX_CC_ACCOUNTING_VERSION = "capex-credit-cycle-accounting/1.1.0"

"""
    CAPEX_CC_ACCOUNTING_CHECKS

会計仕様 §8.1 の検証 12 項目の `Symbol` 名。1–5 は既存 `validate_sfc_accounting` の再利用、
6–12 はモデル固有実装。
"""
const CAPEX_CC_ACCOUNTING_CHECKS = (
    :balance_row_sum,
    :balance_column_sum,
    :flow_row_sum,
    :flow_column_sum,
    :stock_flow,
    :nlb_consistency,
    :net_worth_update,
    :capex_funding,
    :s4_balance_sheet,
    :output_income_split,
    :aggregate_output,
    :no_double_count,
)

const _CAPEX_ACC_SECTORS = (:s1, :s2, :s3, :s4, :s5, :sx)
const _CAPEX_ACC_INSTRUMENTS =
    (:capital, :cip, :inventory, :deposit, :loan, :advance, :extfund, :balance)
const _CAPEX_ACC_TRANSACTIONS = (
    :C01,
    :C02,
    :C03,
    :C04,
    :C05,
    :C06,
    :C07,
    :C08,
    :C09,
    :C10,
    :C11,
    :C12,
    :F01,
    :F02,
    :F03,
    :F04,
    :F05,
    :F06,
    :F07,
)

# 会計仕様 §8.1「検証対象に含めないもの」。実物資産行・純資産行は行和検証（§3.2）、
# `S5`/`SX` 列は貸借対照表列和検証（§3.2「各期・S1–S4」）、`S4`/`SX` 列は取引フロー列和検証
# （§4.1「各期・S1・S2・S3・S5」）の対象外。
const _CAPEX_ACC_EXCLUDED_ROW_SUM_INSTRUMENTS = Set((:capital, :cip, :inventory, :balance))
const _CAPEX_ACC_EXCLUDED_BALANCE_COL_SECTORS = Set((:s5, :sx))

# 逸脱（`_CCC_DEVIATIONS` と同種、upstream への差し戻し事項）: 会計仕様 §4.5・§14.6 の
# `s5_net_sx` 定義式（`capex_credit_cycle.jl` の実装もこれに従う）は `xdem_s5` を減算するが、
# `C-04`（`S5` 産出の処分。`SX` 列 `-xdem_s5`）と `C-12`（`S5` の閉じ変数）を文書どおりに
# 構成すると、`S5` 列の合計は `xdem_s5`（`im_s5 ≡ 0` の下）だけ恒常的にゼロから乖離する
# （`s5_net_sx` の式が本来の閉じ値より `xdem_s5` だけ小さい）。この乖離は在庫評価方式や
# 価格時点合わせ（`X-14`・`X-15`）とは無関係で、Sc0 baseline でも定常的に発生する。
# 独自に `s5_net_sx` の式を変更せず、モデルの実際の出力をそのまま会計表へ反映したうえで、
# `S5` を `:flow_column_sum`・`:nlb_consistency` の検証対象から一時的に除外する
# （上流文書 `capex_credit_cycle_stock_flow.md` §4.5・§14.6 への差し戻し事項）。
const _CAPEX_ACC_EXCLUDED_FLOW_COL_SECTORS = Set((:s4, :sx, :s5))
const _CAPEX_ACC_NLB_SECTORS = (:s1, :s2, :s3)

# ---------------------------------------------------------------------------
# 部門・金融商品の登録簿（会計仕様 §2.1・§3.1）
# ---------------------------------------------------------------------------

function _capex_acc_sectors()
    return SFCSector[
        SFCSector(;
            id = :s1,
            name = "S1: Hyperscaler/AI関連CAPEX主体",
            sector_type = :firm,
        ),
        SFCSector(; id = :s2, name = "S2: 半導体・先端製造", sector_type = :firm),
        SFCSector(;
            id = :s3,
            name = "S3: データセンター建設・関連設備",
            sector_type = :firm,
        ),
        SFCSector(; id = :s4, name = "S4: 金融部門（集約）", sector_type = :bank),
        SFCSector(;
            id = :s5,
            name = "S5: 家計・非AI企業（集約）",
            sector_type = :household,
        ),
        SFCSector(; id = :sx, name = "SX: モデル外・残差部門", sector_type = :other),
    ]
end

# `role` metadata: `capital`・`cip`・`inventory`・`balance`（純資産）は行和検証の対象外
# （会計仕様 §3.2）であり、対応する単一の取引行を持たない（§4.5「固定資本形成の独立行を
# 持たない」）。`_acc_is_balancing` の "balancing"/"net_worth" タグを再利用し、汎用
# `:stock_flow` からも除外する（実物資産・純資産の整合は `:net_worth_update` で別途検証する）。
function _capex_acc_instruments()
    balancing = Dict{String, Any}("role" => "balancing")
    net_worth_role = Dict{String, Any}("role" => "net_worth")
    return SFCInstrument[
        SFCInstrument(;
            id = :capital,
            name = "稼働資本ストック",
            issuers = Symbol[],
            holders = [:s1, :s2, :s3],
            unit = "10億ドル",
            metadata = copy(balancing),
        ),
        SFCInstrument(;
            id = :cip,
            name = "建設中資本（パイプライン）",
            issuers = Symbol[],
            holders = [:s1, :s2, :s3],
            unit = "10億ドル",
            metadata = copy(balancing),
        ),
        SFCInstrument(;
            id = :inventory,
            name = "在庫（当期価格評価）",
            issuers = Symbol[],
            holders = [:s2, :s3],
            unit = "10億ドル",
            metadata = copy(balancing),
        ),
        SFCInstrument(;
            id = :deposit,
            name = "現金・預金",
            issuers = [:s4],
            holders = [:s1, :s2, :s3],
            unit = "10億ドル",
        ),
        # `:loan` の期中フローは `F-02`（新規借入）と `F-03`（元本返済）の 2 行に分かれており
        # （会計仕様 §4.3「計上するのは純額のみ」で純額に分解する設計判断による）、
        # `validate_sfc_accounting` の既定規約（instrument 1 個につき対応取引 1 行）では
        # 単一行に解決できない（2 行を合算する `stock_flow_map` は二重集計を招く）。
        # 汎用 `:stock_flow` からは除外し（"balancing" ロール）、`debt_s` のストック・フロー
        # 整合は `_capex_check_loan_stock_flow!`（`:stock_flow` として統合）で個別に検証する。
        SFCInstrument(;
            id = :loan,
            name = "貸出・社債",
            issuers = [:s1, :s2, :s3],
            holders = [:s4],
            unit = "10億ドル",
            metadata = copy(balancing),
        ),
        SFCInstrument(;
            id = :advance,
            name = "前受金・前渡金（MVP ≡ 0）",
            issuers = [:s2, :s3],
            holders = [:s1, :s2],
            unit = "10億ドル",
        ),
        SFCInstrument(;
            id = :extfund,
            name = "S4のモデル外調達",
            issuers = [:s4],
            holders = [:sx],
            unit = "10億ドル",
        ),
        SFCInstrument(;
            id = :balance,
            name = "純資産（バランス項）",
            issuers = Symbol[],
            holders = Symbol[],
            unit = "10億ドル",
            metadata = copy(net_worth_role),
        ),
    ]
end

# ---------------------------------------------------------------------------
# 期首（前期末）値の参照（会計仕様 §2.4: 意思決定・残高更新はすべて期首ストックを参照）
# ---------------------------------------------------------------------------

# `idx == 1`（`run.periods` の最初）のとき `run.state0` を、それ以外は `run.series` の
# 直前要素を返す。`sym` は state 変数（`cash_s1`・`debt_s1`・`inv_s2` 等）。
function _capex_prev_state(run::CapexCreditCycleRun, sym::Symbol, idx::Int)
    idx == 1 && return Float64(getproperty(run.state0, sym))
    return Float64(getproperty(run.series, sym)[idx - 1])
end

# `base`（`price_s2`・`price_s3` 等、自身の前期値を参照する lag1 追跡変数）の 1 期前の値。
# `idx == 1` のときは `run.state0` の `<base>_lag1` を、それ以外は `run.series` の直前要素。
function _capex_prev_lag1(run::CapexCreditCycleRun, base::Symbol, idx::Int)
    idx == 1 && return Float64(getproperty(run.state0, Symbol(string(base) * "_lag1")))
    return Float64(getproperty(run.series, base)[idx - 1])
end

# ---------------------------------------------------------------------------
# 貸借対照表行列（会計仕様 §3.2・§3.3・§14.5）
# ---------------------------------------------------------------------------

function _capex_balance_sheet(m::CapexCreditCycleModel, run::CapexCreditCycleRun, idx::Int)
    s = run.series
    g(sym::Symbol) = Float64(getproperty(s, sym)[idx])

    instruments = collect(_CAPEX_ACC_INSTRUMENTS)
    sectors = collect(_CAPEX_ACC_SECTORS)
    ri = Dict(sym => i for (i, sym) in enumerate(instruments))
    ci = Dict(sym => i for (i, sym) in enumerate(sectors))
    H = zeros(Float64, length(instruments), length(sectors))

    cap_s1 = g(:cap_s1)
    cap_s2 = g(:cap_s2)
    cap_s3 = g(:cap_s3)
    pipe_s1 = g(:capex_pipe_s1)
    pipe_s2 = g(:capex_pipe_s2)
    pipe_s3 = g(:capex_pipe_s3)
    invval_s2 = g(:invval_s2)
    invval_s3 = g(:invval_s3)
    cash_s1 = g(:cash_s1)
    cash_s2 = g(:cash_s2)
    cash_s3 = g(:cash_s3)
    debt_s1 = g(:debt_s1)
    debt_s2 = g(:debt_s2)
    debt_s3 = g(:debt_s3)
    loans_s4 = g(:loans_s4)
    dep_stock_s4 = g(:dep_stock_s4)
    fund_s4 = g(:fund_s4)
    nw_s1 = g(:nw_s1)
    nw_s2 = g(:nw_s2)
    nw_s3 = g(:nw_s3)

    H[ri[:capital], ci[:s1]] = cap_s1
    H[ri[:capital], ci[:s2]] = cap_s2
    H[ri[:capital], ci[:s3]] = cap_s3

    H[ri[:cip], ci[:s1]] = pipe_s1
    H[ri[:cip], ci[:s2]] = pipe_s2
    H[ri[:cip], ci[:s3]] = pipe_s3

    H[ri[:inventory], ci[:s2]] = invval_s2
    H[ri[:inventory], ci[:s3]] = invval_s3

    H[ri[:deposit], ci[:s1]] = cash_s1
    H[ri[:deposit], ci[:s2]] = cash_s2
    H[ri[:deposit], ci[:s3]] = cash_s3
    H[ri[:deposit], ci[:s4]] = -dep_stock_s4

    H[ri[:loan], ci[:s1]] = -debt_s1
    H[ri[:loan], ci[:s2]] = -debt_s2
    H[ri[:loan], ci[:s3]] = -debt_s3
    H[ri[:loan], ci[:s4]] = loans_s4

    # advance: MVP ≡ 0（会計仕様 §3.5・§4.4 の仮定 A-2）。行は独立項として保持する。

    H[ri[:extfund], ci[:s4]] = -fund_s4
    H[ri[:extfund], ci[:sx]] = fund_s4

    H[ri[:balance], ci[:s1]] = -nw_s1
    H[ri[:balance], ci[:s2]] = -nw_s2
    H[ri[:balance], ci[:s3]] = -nw_s3
    H[ri[:balance], ci[:sx]] = -fund_s4 # SX 列を閉じる（§2.1: SX の列和は定義上ゼロ）

    return BalanceSheetMatrix(instruments, sectors, H)
end

# ---------------------------------------------------------------------------
# 取引フロー行列（会計仕様 §4.2・§4.3・§14.2・§14.3・§14.6）
# ---------------------------------------------------------------------------

# 資本財受注の買い手別分解（`R-3`・`R-4`）。`price_s` はステップ5冒頭で確定した当期価格であり
# （X-15）、注文の除算と購入額の乗算に同一の当期価格を用いるため、価格は分数の分子分母で
# 相殺し `st_capex_share_*`・`st_invest_share_*` の積が厳密に成り立つ（会計仕様 §14.7）。
function _capex_capital_goods_flows(
    m::CapexCreditCycleModel,
    run::CapexCreditCycleRun,
    idx::Int,
)
    s = run.series
    p = m.params
    g(sym::Symbol) = Float64(getproperty(s, sym)[idx])

    capex_exec_s1 = g(:capex_exec_s1)
    invest_s2 = g(:invest_s2)

    d_s1_s2 = p.st_capex_share_s2 * capex_exec_s1 # S1 が S2 から買う資本財
    d_s1_s3 = p.st_capex_share_s3 * capex_exec_s1 # S1 が S3 から買う資本財
    d_s2_s3 = p.st_invest_share_s3 * invest_s2 # S2 が S3 から買う投資財

    eps = run.options.div_eps
    deliv_s2 = g(:deliv_s2)
    deliv_s3 = g(:deliv_s3)
    deliv_gen_s2 = deliv_s2 - d_s1_s2
    deliv_gen_s3 = deliv_s3 - d_s1_s3 - d_s2_s3

    order_gen_s2 = g(:order_gen_s2)
    ext_demand_s2 = g(:ext_demand_s2)
    order_gen_s3 = g(:order_gen_s3)
    ext_demand_s3 = g(:ext_demand_s3)

    gen_frac_s2 = order_gen_s2 / max(order_gen_s2 + ext_demand_s2, eps)
    gen_frac_s3 = order_gen_s3 / max(order_gen_s3 + ext_demand_s3, eps)

    d_s5_s2 = deliv_gen_s2 * gen_frac_s2
    d_sx_s2 = deliv_gen_s2 - d_s5_s2 # 残差として閉じる（丸め誤差を残さない）
    d_s5_s3 = deliv_gen_s3 * gen_frac_s3
    d_sx_s3 = deliv_gen_s3 - d_s5_s3

    return (
        d_s1_s2 = d_s1_s2,
        d_s1_s3 = d_s1_s3,
        d_s2_s3 = d_s2_s3,
        d_s5_s2 = d_s5_s2,
        d_sx_s2 = d_sx_s2,
        d_s5_s3 = d_s5_s3,
        d_sx_s3 = d_sx_s3,
    )
end

function _capex_transaction_flow(
    m::CapexCreditCycleModel,
    run::CapexCreditCycleRun,
    idx::Int,
)
    s = run.series
    g(sym::Symbol) = Float64(getproperty(s, sym)[idx])

    transactions = collect(_CAPEX_ACC_TRANSACTIONS)
    sectors = collect(_CAPEX_ACC_SECTORS)
    ti = Dict(sym => i for (i, sym) in enumerate(transactions))
    ci = Dict(sym => i for (i, sym) in enumerate(sectors))
    F = zeros(Float64, length(transactions), length(sectors))

    d = _capex_capital_goods_flows(m, run, idx)

    sales_s1 = g(:sales_s1)
    cons_s1 = g(:cons_s1)
    xsales_s1 = g(:xsales_s1)
    sales_s2 = g(:sales_s2)
    dinv_s2 = g(:dinv_s2)
    sales_s3 = g(:sales_s3)
    dinv_s3 = g(:dinv_s3)
    y_s5 = g(:y_s5)
    cons_s5 = g(:cons_s5)
    xdem_s5 = g(:xdem_s5)
    im_s1 = g(:im_s1)
    im_s2 = g(:im_s2)
    im_s3 = g(:im_s3)
    im_s5 = g(:im_s5)
    capex_sx_s1 = g(:capex_sx_s1)
    inv_sx_s2 = g(:inv_sx_s2)
    inv_sx_s3 = g(:inv_sx_s3)
    wagebill_s1 = g(:wagebill_s1)
    wagebill_s2 = g(:wagebill_s2)
    wagebill_s3 = g(:wagebill_s3)
    tax_hh = g(:tax_hh)
    tax_s1 = g(:tax_s1)
    tax_s2 = g(:tax_s2)
    tax_s3 = g(:tax_s3)
    int_burden_s1 = g(:int_burden_s1)
    int_burden_s2 = g(:int_burden_s2)
    int_burden_s3 = g(:int_burden_s3)
    div_s1 = g(:div_s1)
    div_s2 = g(:div_s2)
    div_s3 = g(:div_s3)
    s5_net_sx = g(:s5_net_sx)
    newdebt_s1 = g(:newdebt_s1)
    newdebt_s2 = g(:newdebt_s2)
    newdebt_s3 = g(:newdebt_s3)
    repay_s1 = g(:repay_s1)
    repay_s2 = g(:repay_s2)
    repay_s3 = g(:repay_s3)
    writeoff_s1 = g(:writeoff_s1)
    writeoff_s2 = g(:writeoff_s2)
    writeoff_s3 = g(:writeoff_s3)
    equity_issue_s1 = g(:equity_issue_s1)
    equity_issue_s2 = g(:equity_issue_s2)
    equity_issue_s3 = g(:equity_issue_s3)
    cash_s1 = g(:cash_s1)
    cash_s2 = g(:cash_s2)
    cash_s3 = g(:cash_s3)
    fund_s4 = g(:fund_s4)

    prev_cash_s1 = _capex_prev_state(run, :cash_s1, idx)
    prev_cash_s2 = _capex_prev_state(run, :cash_s2, idx)
    prev_cash_s3 = _capex_prev_state(run, :cash_s3, idx)
    prev_debt_s1 = _capex_prev_state(run, :debt_s1, idx)
    prev_debt_s2 = _capex_prev_state(run, :debt_s2, idx)
    prev_debt_s3 = _capex_prev_state(run, :debt_s3, idx)

    dcash_s1 = cash_s1 - prev_cash_s1
    dcash_s2 = cash_s2 - prev_cash_s2
    dcash_s3 = cash_s3 - prev_cash_s3
    fund_s4_prev =
        (prev_debt_s1 + prev_debt_s2 + prev_debt_s3) -
        (prev_cash_s1 + prev_cash_s2 + prev_cash_s3)
    dfund_s4 = fund_s4 - fund_s4_prev

    # C-01: S1 産出の処分
    F[ti[:C01], ci[:s1]] = sales_s1
    F[ti[:C01], ci[:s5]] = -cons_s1
    F[ti[:C01], ci[:sx]] = -xsales_s1

    # C-02: S2 産出の処分
    F[ti[:C02], ci[:s1]] = -d.d_s1_s2
    F[ti[:C02], ci[:s2]] = sales_s2 - dinv_s2
    F[ti[:C02], ci[:s5]] = -d.d_s5_s2
    F[ti[:C02], ci[:sx]] = -d.d_sx_s2

    # C-03: S3 産出の処分
    F[ti[:C03], ci[:s1]] = -d.d_s1_s3
    F[ti[:C03], ci[:s2]] = -d.d_s2_s3
    F[ti[:C03], ci[:s3]] = sales_s3 - dinv_s3
    F[ti[:C03], ci[:s5]] = -d.d_s5_s3
    F[ti[:C03], ci[:sx]] = -d.d_sx_s3

    # C-04: S5 産出の処分（`sales_s5` は廃止し `y_s5` を用いる。会計仕様 §14.3）
    F[ti[:C04], ci[:s5]] = y_s5 - cons_s5
    F[ti[:C04], ci[:sx]] = -xdem_s5

    # C-05: モデル外からの中間投入・資本財購入
    sx_c05 = im_s1 + capex_sx_s1 + im_s2 + inv_sx_s2 + im_s3 + inv_sx_s3 + im_s5
    F[ti[:C05], ci[:s1]] = -(im_s1 + capex_sx_s1)
    F[ti[:C05], ci[:s2]] = -(im_s2 + inv_sx_s2)
    F[ti[:C05], ci[:s3]] = -(im_s3 + inv_sx_s3)
    F[ti[:C05], ci[:s5]] = -im_s5
    F[ti[:C05], ci[:sx]] = sx_c05

    # C-06: 賃金（S5 内部の賃金は計上しない。会計仕様 §4.5・§14.6）
    wagebill_sf = wagebill_s1 + wagebill_s2 + wagebill_s3
    F[ti[:C06], ci[:s1]] = -wagebill_s1
    F[ti[:C06], ci[:s2]] = -wagebill_s2
    F[ti[:C06], ci[:s3]] = -wagebill_s3
    F[ti[:C06], ci[:s5]] = wagebill_sf

    # C-07: 家計税・移転
    F[ti[:C07], ci[:s5]] = -tax_hh
    F[ti[:C07], ci[:sx]] = tax_hh

    # C-08: 法人税
    F[ti[:C08], ci[:s1]] = -tax_s1
    F[ti[:C08], ci[:s2]] = -tax_s2
    F[ti[:C08], ci[:s3]] = -tax_s3
    F[ti[:C08], ci[:sx]] = tax_s1 + tax_s2 + tax_s3

    # C-09: 利払い
    int_burden_sum = int_burden_s1 + int_burden_s2 + int_burden_s3
    F[ti[:C09], ci[:s1]] = -int_burden_s1
    F[ti[:C09], ci[:s2]] = -int_burden_s2
    F[ti[:C09], ci[:s3]] = -int_burden_s3
    F[ti[:C09], ci[:s4]] = int_burden_sum

    # C-10: 金融部門純所得のモデル外移転
    F[ti[:C10], ci[:s4]] = -int_burden_sum
    F[ti[:C10], ci[:sx]] = int_burden_sum

    # C-11: 配当・株主還元
    F[ti[:C11], ci[:s1]] = -div_s1
    F[ti[:C11], ci[:s2]] = -div_s2
    F[ti[:C11], ci[:s3]] = -div_s3
    F[ti[:C11], ci[:sx]] = div_s1 + div_s2 + div_s3

    # C-12: S5 のモデル外への純移転
    F[ti[:C12], ci[:s5]] = -s5_net_sx
    F[ti[:C12], ci[:sx]] = s5_net_sx

    # F-01: 現金・預金の増減
    F[ti[:F01], ci[:s1]] = -dcash_s1
    F[ti[:F01], ci[:s2]] = -dcash_s2
    F[ti[:F01], ci[:s3]] = -dcash_s3
    F[ti[:F01], ci[:s4]] = dcash_s1 + dcash_s2 + dcash_s3

    # F-02: 新規借入・社債発行
    newdebt_sum = newdebt_s1 + newdebt_s2 + newdebt_s3
    F[ti[:F02], ci[:s1]] = newdebt_s1
    F[ti[:F02], ci[:s2]] = newdebt_s2
    F[ti[:F02], ci[:s3]] = newdebt_s3
    F[ti[:F02], ci[:s4]] = -newdebt_sum

    # F-03: 元本返済（純）
    repay_sum = repay_s1 + repay_s2 + repay_s3
    F[ti[:F03], ci[:s1]] = -repay_s1
    F[ti[:F03], ci[:s2]] = -repay_s2
    F[ti[:F03], ci[:s3]] = -repay_s3
    F[ti[:F03], ci[:s4]] = repay_sum

    # F-04: 貸倒償却（MVP ≡ 0）
    writeoff_sum = writeoff_s1 + writeoff_s2 + writeoff_s3
    F[ti[:F04], ci[:s1]] = writeoff_s1
    F[ti[:F04], ci[:s2]] = writeoff_s2
    F[ti[:F04], ci[:s3]] = writeoff_s3
    F[ti[:F04], ci[:s4]] = -writeoff_sum

    # F-05: 前受金・前渡金の増減（MVP ≡ 0）

    # F-06: 増資・外部資本（MVP ≡ 0）
    equity_issue_sum = equity_issue_s1 + equity_issue_s2 + equity_issue_s3
    F[ti[:F06], ci[:s1]] = equity_issue_s1
    F[ti[:F06], ci[:s2]] = equity_issue_s2
    F[ti[:F06], ci[:s3]] = equity_issue_s3
    F[ti[:F06], ci[:sx]] = -equity_issue_sum

    # F-07: S4 のモデル外調達
    F[ti[:F07], ci[:s4]] = dfund_s4
    F[ti[:F07], ci[:sx]] = -dfund_s4

    return TransactionFlowMatrix(transactions, sectors, F)
end

"""
    capex_accounting_snapshots(m::CapexCreditCycleModel, run::CapexCreditCycleRun) -> Vector{SFCPeriodSnapshot}

`run.series` から各期の貸借対照表行列（instrument 8 種 × 部門 6 列）・取引フロー行列
（`C-01`–`C-12`・`F-01`–`F-07`）を構築する（会計仕様 §3・§4）。評価調整（`valuation_adjustment`）
は既定の全ゼロ行列を用いる（在庫の評価差額 `valchg_s` は取引フロー行列に現れず、`:net_worth_update`
（検証7）で別途検証する。会計仕様 §14.5）。読み取り専用（モデル方程式・`SimulationResult` を
変更しない）。
"""
function capex_accounting_snapshots(m::CapexCreditCycleModel, run::CapexCreditCycleRun)
    n = length(run.periods)
    snaps = Vector{SFCPeriodSnapshot}(undef, n)
    for idx in 1:n
        bs = _capex_balance_sheet(m, run, idx)
        tf = _capex_transaction_flow(m, run, idx)
        snaps[idx] = SFCPeriodSnapshot(string(run.periods[idx]), bs, tf)
    end
    return snaps
end

# ---------------------------------------------------------------------------
# 検証 6–12（モデル固有。既存ヘルパー `_acc_check`/`_acc_sum_check`/`_acc_scale` を再利用）
# ---------------------------------------------------------------------------

# 検証5（`:stock_flow`）の `:loan` 分（`s ∈ SF`）。汎用エンジンでは合算できない `F-02`
# （新規借入）・`F-03`（元本返済）を直接 `debt_s = debt_s[t−1] + newdebt_s − repay_s − writeoff_s`
# （会計仕様 §5.4）と突き合わせる。`validate_sfc_accounting` と同じ `:stock_flow` の check 名を
# 付け、同じ許容誤差判定（`_acc_check`）で統合する。
function _capex_check_loan_stock_flow!(
    checks::Vector{AccountingViolation},
    m::CapexCreditCycleModel,
    run::CapexCreditCycleRun,
    idx::Int,
    atolf::Float64,
    rtolf::Float64,
)
    period = string(run.periods[idx])
    s = run.series
    g(sym::Symbol) = Float64(getproperty(s, sym)[idx])

    for sec in (:s1, :s2, :s3)
        debt = g(Symbol("debt_$sec"))
        debt_prev = _capex_prev_state(run, Symbol("debt_$sec"), idx)
        newdebt = g(Symbol("newdebt_$sec"))
        repay = g(Symbol("repay_$sec"))
        writeoff = g(Symbol("writeoff_$sec"))
        residual = (debt - debt_prev) - (newdebt - repay - writeoff)
        push!(
            checks,
            _acc_check(
                :stock_flow,
                period,
                residual,
                _acc_scale((debt, debt_prev, newdebt, repay, writeoff)),
                atolf,
                rtolf,
                "部門 $(repr(sec)) の debt_s = debt_s[t−1] + newdebt_s − repay_s − writeoff_s が成立しません";
                evidence = Dict{String, Any}("instrument" => "loan"),
                sector = sec,
                instrument = :loan,
            ),
        )
    end
    return checks
end

# 検証5（`:stock_flow`）の `:capital`（稼働資本）分（`s ∈ SF`）。実物資産行は取引フロー行列に
# 対応する独立行を持たない（会計仕様 §4.5）ため、`cap_s = cap_s[t−1] + capstart_s − dep_s − retire_s`
# （§5.1）を直接突き合わせる。
function _capex_check_capital_stock_flow!(
    checks::Vector{AccountingViolation},
    m::CapexCreditCycleModel,
    run::CapexCreditCycleRun,
    idx::Int,
    atolf::Float64,
    rtolf::Float64,
)
    period = string(run.periods[idx])
    s = run.series
    g(sym::Symbol) = Float64(getproperty(s, sym)[idx])

    for sec in (:s1, :s2, :s3)
        cap = g(Symbol("cap_$sec"))
        cap_prev = _capex_prev_state(run, Symbol("cap_$sec"), idx)
        capstart = g(Symbol("capstart_$sec"))
        dep = g(Symbol("dep_$sec"))
        retire = g(Symbol("retire_$sec"))
        residual = (cap - cap_prev) - (capstart - dep - retire)
        push!(
            checks,
            _acc_check(
                :stock_flow,
                period,
                residual,
                _acc_scale((cap, cap_prev, capstart, dep, retire)),
                atolf,
                rtolf,
                "部門 $(repr(sec)) の cap_s = cap_s[t−1] + capstart_s − dep_s − retire_s が成立しません";
                evidence = Dict{String, Any}("instrument" => "capital"),
                sector = sec,
                instrument = :capital,
            ),
        )
    end
    return checks
end

# 検証5（`:stock_flow`）の `:cip`（建設中資本）分（`s ∈ SF`）。
# `capex_pipe_s = capex_pipe_s[t−1] + I_s − capstart_s − pipe_cancel_s`（§5.2。
# `s = s1` は `I_s = capex_exec_s1`、`s ∈ SP` は `I_s = invest_s`）を直接突き合わせる。
function _capex_check_cip_stock_flow!(
    checks::Vector{AccountingViolation},
    m::CapexCreditCycleModel,
    run::CapexCreditCycleRun,
    idx::Int,
    atolf::Float64,
    rtolf::Float64,
)
    period = string(run.periods[idx])
    s = run.series
    g(sym::Symbol) = Float64(getproperty(s, sym)[idx])
    capex_exec_s1 = g(:capex_exec_s1)

    for sec in (:s1, :s2, :s3)
        pipe = g(Symbol("capex_pipe_$sec"))
        pipe_prev = _capex_prev_state(run, Symbol("capex_pipe_$sec"), idx)
        I_s = sec === :s1 ? capex_exec_s1 : g(Symbol("invest_$sec"))
        capstart = g(Symbol("capstart_$sec"))
        pipe_cancel = g(Symbol("pipe_cancel_$sec"))
        residual = (pipe - pipe_prev) - (I_s - capstart - pipe_cancel)
        push!(
            checks,
            _acc_check(
                :stock_flow,
                period,
                residual,
                _acc_scale((pipe, pipe_prev, I_s, capstart, pipe_cancel)),
                atolf,
                rtolf,
                "部門 $(repr(sec)) の capex_pipe_s = capex_pipe_s[t−1] + I_s − capstart_s − pipe_cancel_s が成立しません";
                evidence = Dict{String, Any}("instrument" => "cip"),
                sector = sec,
                instrument = :cip,
            ),
        )
    end
    return checks
end

# 検証5（`:stock_flow`）の `:inventory`（在庫、当期価格評価）分（`s ∈ SP`）。
# `invval_s = price_s · inv_s` の期間変化 `Δinvval_s = dinv_s + valchg_s`（会計仕様 §14.5・
# ADR 0013 決定4）を直接突き合わせる。
function _capex_check_inventory_stock_flow!(
    checks::Vector{AccountingViolation},
    m::CapexCreditCycleModel,
    run::CapexCreditCycleRun,
    idx::Int,
    atolf::Float64,
    rtolf::Float64,
)
    period = string(run.periods[idx])
    s = run.series
    g(sym::Symbol) = Float64(getproperty(s, sym)[idx])

    for sec in (:s2, :s3)
        invval = g(Symbol("invval_$sec"))
        invval_prev = if idx == 1
            price0 = _capex_prev_lag1(run, Symbol("price_$sec"), idx)
            inv0 = Float64(getproperty(run.state0, Symbol("inv_$sec")))
            price0 * inv0
        else
            Float64(getproperty(s, Symbol("invval_$sec"))[idx - 1])
        end
        dinv = g(Symbol("dinv_$sec"))
        valchg = g(Symbol("valchg_$sec"))
        residual = (invval - invval_prev) - (dinv + valchg)
        push!(
            checks,
            _acc_check(
                :stock_flow,
                period,
                residual,
                _acc_scale((invval, invval_prev, dinv, valchg)),
                atolf,
                rtolf,
                "部門 $(repr(sec)) の Δinvval_s = dinv_s + valchg_s（§14.5）が成立しません";
                evidence = Dict{String, Any}("instrument" => "inventory"),
                sector = sec,
                instrument = :inventory,
            ),
        )
    end
    return checks
end

# 検証6: `:nlb_consistency`（会計仕様 §8.1-6）。経常・資本ブロック列和（`C-01`–`C-12`）が
# モデル自身が計算した `nlb_s`（診断量）と一致することを検証する。`s ∈ {s1,s2,s3,s5}`。
function _capex_check_nlb_consistency!(
    checks::Vector{AccountingViolation},
    m::CapexCreditCycleModel,
    run::CapexCreditCycleRun,
    idx::Int,
    tf::TransactionFlowMatrix,
    atolf::Float64,
    rtolf::Float64,
)
    period = string(run.periods[idx])
    c_rows = 1:12 # C-01–C-12
    for sec in _CAPEX_ACC_NLB_SECTORS
        nlb_series = Float64(getproperty(run.series, Symbol("nlb_$sec"))[idx])
        c = _sfc_axis_index(tf.sectors, sec, "sector")
        c_block_sum = sum(@view(tf.flows[c_rows, c]))
        residual = nlb_series - c_block_sum
        scale = _acc_scale((nlb_series, c_block_sum))
        push!(
            checks,
            _acc_check(
                :nlb_consistency,
                period,
                residual,
                scale,
                atolf,
                rtolf,
                "部門 $(repr(sec)) の経常・資本ブロック列和が nlb_$sec と一致しません";
                evidence = Dict{String, Any}(
                    "nlb" => nlb_series,
                    "c_block_sum" => c_block_sum,
                ),
                sector = sec,
            ),
        )
    end
    return checks
end

# 検証7: `:net_worth_update`（会計仕様 §5.6・§8.1-7）。`Δnw_s` と、内部留保・増資・債務免除益・
# 除却損・評価差額から構成される右辺の一致を検証する（`s ∈ SF`）。
function _capex_check_net_worth_update!(
    checks::Vector{AccountingViolation},
    m::CapexCreditCycleModel,
    run::CapexCreditCycleRun,
    idx::Int,
    atolf::Float64,
    rtolf::Float64,
)
    period = string(run.periods[idx])
    s = run.series
    g(sym::Symbol) = Float64(getproperty(s, sym)[idx])

    for sec in (:s1, :s2, :s3)
        nw = g(Symbol("nw_$sec"))
        nw_prev = if idx == 1
            cap0 = Float64(getproperty(run.state0, Symbol("cap_$sec")))
            pipe0 = Float64(getproperty(run.state0, Symbol("capex_pipe_$sec")))
            cash0 = Float64(getproperty(run.state0, Symbol("cash_$sec")))
            debt0 = Float64(getproperty(run.state0, Symbol("debt_$sec")))
            invval0 = if sec === :s1
                0.0
            else
                price0 = _capex_prev_lag1(run, Symbol("price_$sec"), idx)
                inv0 = Float64(getproperty(run.state0, Symbol("inv_$sec")))
                price0 * inv0
            end
            cap0 + pipe0 + invval0 + cash0 - debt0
        else
            Float64(getproperty(s, Symbol("nw_$sec"))[idx - 1])
        end
        dnw = nw - nw_prev

        profit = g(Symbol("profit_$sec"))
        int_burden = g(Symbol("int_burden_$sec"))
        tax = g(Symbol("tax_$sec"))
        div = g(Symbol("div_$sec"))
        equity_issue = g(Symbol("equity_issue_$sec"))
        writeoff = g(Symbol("writeoff_$sec"))
        retire = g(Symbol("retire_$sec"))
        pipe_cancel = g(Symbol("pipe_cancel_$sec"))
        valchg = g(Symbol("valchg_$sec"))

        rhs =
            profit - int_burden - tax - div + equity_issue + writeoff - retire -
            pipe_cancel + valchg
        residual = dnw - rhs
        scale = _acc_scale((nw, nw_prev, rhs))
        push!(
            checks,
            _acc_check(
                :net_worth_update,
                period,
                residual,
                scale,
                atolf,
                rtolf,
                "部門 $(repr(sec)) の純資産変化が §5.6 の恒等式と一致しません";
                evidence = Dict{String, Any}("delta_nw" => dnw, "rhs" => rhs),
                sector = sec,
            ),
        )
    end
    return checks
end

# 検証8: `:capex_funding`（会計仕様 §6.1・§6.2・§14.4）。恒等式1（`S1` のみ）と恒等式2
# （`s ∈ SF`）を検証する。
function _capex_check_capex_funding!(
    checks::Vector{AccountingViolation},
    m::CapexCreditCycleModel,
    run::CapexCreditCycleRun,
    idx::Int,
    atolf::Float64,
    rtolf::Float64,
)
    period = string(run.periods[idx])
    s = run.series
    g(sym::Symbol) = Float64(getproperty(s, sym)[idx])

    capex_plan_eff_s1 = g(:capex_plan_eff_s1)
    capex_exec_s1 = g(:capex_exec_s1)
    capex_cancel_s1 = g(:capex_cancel_s1)
    capex_defer_s1 = g(:capex_defer_s1)
    residual1 = capex_plan_eff_s1 - (capex_exec_s1 + capex_cancel_s1 + capex_defer_s1)
    scale1 = _acc_scale((capex_plan_eff_s1, capex_exec_s1, capex_cancel_s1, capex_defer_s1))
    push!(
        checks,
        _acc_check(
            :capex_funding,
            period,
            residual1,
            scale1,
            atolf,
            rtolf,
            "恒等式1（capex_plan_eff_s1 = capex_exec_s1 + capex_cancel_s1 + capex_defer_s1）が成立しません";
            evidence = Dict{String, Any}("identity" => 1),
            sector = :s1,
        ),
    )

    for sec in (:s1, :s2, :s3)
        I_s = sec === :s1 ? capex_exec_s1 : g(Symbol("invest_$sec"))
        div = g(Symbol("div_$sec"))
        tax = g(Symbol("tax_$sec"))
        int_burden = g(Symbol("int_burden_$sec"))
        repay = g(Symbol("repay_$sec"))
        cash = g(Symbol("cash_$sec"))
        cash_prev = _capex_prev_state(run, Symbol("cash_$sec"), idx)
        dcash = cash - cash_prev
        ocf = g(Symbol("ocf_$sec"))
        newdebt = g(Symbol("newdebt_$sec"))
        equity_issue = g(Symbol("equity_issue_$sec"))

        lhs = I_s + div + tax + int_burden + repay + dcash
        rhs = ocf + newdebt + equity_issue
        residual2 = lhs - rhs
        scale2 = _acc_scale((lhs, rhs))
        push!(
            checks,
            _acc_check(
                :capex_funding,
                period,
                residual2,
                scale2,
                atolf,
                rtolf,
                "部門 $(repr(sec)) の資金調達恒等式2（cash 更新式の移項）が成立しません";
                evidence = Dict{String, Any}("identity" => 2, "lhs" => lhs, "rhs" => rhs),
                sector = sec,
            ),
        )
    end
    return checks
end

# 検証9: `:s4_balance_sheet`（会計仕様 §3.3・§8.1-9）。`loans_s4 = Σ debt_s`・
# `dep_stock_s4 = Σ cash_s` を独立に検証する。
function _capex_check_s4_balance_sheet!(
    checks::Vector{AccountingViolation},
    m::CapexCreditCycleModel,
    run::CapexCreditCycleRun,
    idx::Int,
    atolf::Float64,
    rtolf::Float64,
)
    period = string(run.periods[idx])
    s = run.series
    g(sym::Symbol) = Float64(getproperty(s, sym)[idx])

    loans_s4 = g(:loans_s4)
    dep_stock_s4 = g(:dep_stock_s4)
    debt_sum = g(:debt_s1) + g(:debt_s2) + g(:debt_s3)
    cash_sum = g(:cash_s1) + g(:cash_s2) + g(:cash_s3)

    res_loans = loans_s4 - debt_sum
    push!(
        checks,
        _acc_check(
            :s4_balance_sheet,
            period,
            res_loans,
            _acc_scale((loans_s4, debt_sum)),
            atolf,
            rtolf,
            "loans_s4 が Σ debt_s と一致しません";
            evidence = Dict{String, Any}("component" => "loans"),
            sector = :s4,
        ),
    )
    res_dep = dep_stock_s4 - cash_sum
    push!(
        checks,
        _acc_check(
            :s4_balance_sheet,
            period,
            res_dep,
            _acc_scale((dep_stock_s4, cash_sum)),
            atolf,
            rtolf,
            "dep_stock_s4 が Σ cash_s と一致しません";
            evidence = Dict{String, Any}("component" => "deposits"),
            sector = :s4,
        ),
    )
    return checks
end

# 検証10: `:output_income_split`（会計仕様 §8.1-10）。`va_s = wagebill_s + dep_s + profit_s`
# かつ `va_s = sales_s - im_s`（`s ∈ SF`）。
function _capex_check_output_income_split!(
    checks::Vector{AccountingViolation},
    m::CapexCreditCycleModel,
    run::CapexCreditCycleRun,
    idx::Int,
    atolf::Float64,
    rtolf::Float64,
)
    period = string(run.periods[idx])
    s = run.series
    g(sym::Symbol) = Float64(getproperty(s, sym)[idx])

    for sec in (:s1, :s2, :s3)
        va = g(Symbol("va_$sec"))
        wagebill = g(Symbol("wagebill_$sec"))
        dep = g(Symbol("dep_$sec"))
        profit = g(Symbol("profit_$sec"))
        sales = g(Symbol("sales_$sec"))
        im = g(Symbol("im_$sec"))

        res1 = va - (wagebill + dep + profit)
        push!(
            checks,
            _acc_check(
                :output_income_split,
                period,
                res1,
                _acc_scale((va, wagebill, dep, profit)),
                atolf,
                rtolf,
                "部門 $(repr(sec)) の va_s = wagebill_s + dep_s + profit_s が成立しません";
                evidence = Dict{String, Any}("component" => "income_split"),
                sector = sec,
            ),
        )
        res2 = va - (sales - im)
        push!(
            checks,
            _acc_check(
                :output_income_split,
                period,
                res2,
                _acc_scale((va, sales, im)),
                atolf,
                rtolf,
                "部門 $(repr(sec)) の va_s = sales_s - im_s が成立しません";
                evidence = Dict{String, Any}("component" => "value_added"),
                sector = sec,
            ),
        )
    end
    return checks
end

# 検証11: `:aggregate_output`（会計仕様 §8.1-11・#165 R-1）。
function _capex_check_aggregate_output!(
    checks::Vector{AccountingViolation},
    m::CapexCreditCycleModel,
    run::CapexCreditCycleRun,
    idx::Int,
    atolf::Float64,
    rtolf::Float64,
)
    period = string(run.periods[idx])
    s = run.series
    g(sym::Symbol) = Float64(getproperty(s, sym)[idx])

    y_tot = g(:y_tot)
    rhs = g(:va_s1) + g(:va_s2) + g(:va_s3) + g(:y_s5)
    residual = y_tot - rhs
    push!(
        checks,
        _acc_check(
            :aggregate_output,
            period,
            residual,
            _acc_scale((y_tot, rhs)),
            atolf,
            rtolf,
            "y_tot が Σ va_s + y_s5 と一致しません";
            evidence = Dict{String, Any}(),
        ),
    )
    return checks
end

# 検証12: `:no_double_count`（会計仕様 §8.1-12・§14.7・#165 R-3・R-4）。
function _capex_check_no_double_count!(
    checks::Vector{AccountingViolation},
    m::CapexCreditCycleModel,
    run::CapexCreditCycleRun,
    idx::Int,
    atolf::Float64,
    rtolf::Float64,
)
    period = string(run.periods[idx])
    s = run.series
    g(sym::Symbol) = Float64(getproperty(s, sym)[idx])
    d = _capex_capital_goods_flows(m, run, idx)

    capex_exec_s1 = g(:capex_exec_s1)
    capex_sx_s1 = g(:capex_sx_s1)
    res_r3 = capex_exec_s1 - (d.d_s1_s2 + d.d_s1_s3 + capex_sx_s1)
    push!(
        checks,
        _acc_check(
            :no_double_count,
            period,
            res_r3,
            _acc_scale((capex_exec_s1, d.d_s1_s2, d.d_s1_s3, capex_sx_s1)),
            atolf,
            rtolf,
            "capex_exec_s1 = d_{S1,S2} + d_{S1,S3} + capex_sx_s1（R-3）が成立しません";
            evidence = Dict{String, Any}("rule" => "R-3"),
            sector = :s1,
        ),
    )

    invest_s2 = g(:invest_s2)
    inv_sx_s2 = g(:inv_sx_s2)
    res_r4 = invest_s2 - (d.d_s2_s3 + inv_sx_s2)
    push!(
        checks,
        _acc_check(
            :no_double_count,
            period,
            res_r4,
            _acc_scale((invest_s2, d.d_s2_s3, inv_sx_s2)),
            atolf,
            rtolf,
            "invest_s2 = d_{S2,S3} + inv_sx_s2（R-4）が成立しません";
            evidence = Dict{String, Any}("rule" => "R-4"),
            sector = :s2,
        ),
    )

    invest_s3 = g(:invest_s3)
    inv_sx_s3 = g(:inv_sx_s3)
    res_s3 = invest_s3 - inv_sx_s3
    push!(
        checks,
        _acc_check(
            :no_double_count,
            period,
            res_s3,
            _acc_scale((invest_s3, inv_sx_s3)),
            atolf,
            rtolf,
            "invest_s3 = inv_sx_s3（会計仕様 §14.7。X06 が EXT のため相手方は SX のみ）が成立しません";
            evidence = Dict{String, Any}("rule" => "invest_s3"),
            sector = :s3,
        ),
    )

    for sec in (:s2, :s3)
        sales = g(Symbol("sales_$sec"))
        deliv = g(Symbol("deliv_$sec"))
        dinv = g(Symbol("dinv_$sec"))
        res = sales - (deliv + dinv)
        push!(
            checks,
            _acc_check(
                :no_double_count,
                period,
                res,
                _acc_scale((sales, deliv, dinv)),
                atolf,
                rtolf,
                "部門 $(repr(sec)) の Σ_b d_{b,s} + dinv_s = sales_s が成立しません";
                evidence = Dict{String, Any}("rule" => "delivery_split"),
                sector = sec,
            ),
        )
    end
    return checks
end

function _capex_checks_6to12!(
    checks::Vector{AccountingViolation},
    m::CapexCreditCycleModel,
    run::CapexCreditCycleRun,
    idx::Int,
    tf::TransactionFlowMatrix,
    atolf::Float64,
    rtolf::Float64,
)
    _capex_check_loan_stock_flow!(checks, m, run, idx, atolf, rtolf)
    _capex_check_capital_stock_flow!(checks, m, run, idx, atolf, rtolf)
    _capex_check_cip_stock_flow!(checks, m, run, idx, atolf, rtolf)
    _capex_check_inventory_stock_flow!(checks, m, run, idx, atolf, rtolf)
    _capex_check_nlb_consistency!(checks, m, run, idx, tf, atolf, rtolf)
    _capex_check_net_worth_update!(checks, m, run, idx, atolf, rtolf)
    _capex_check_capex_funding!(checks, m, run, idx, atolf, rtolf)
    _capex_check_s4_balance_sheet!(checks, m, run, idx, atolf, rtolf)
    _capex_check_output_income_split!(checks, m, run, idx, atolf, rtolf)
    _capex_check_aggregate_output!(checks, m, run, idx, atolf, rtolf)
    _capex_check_no_double_count!(checks, m, run, idx, atolf, rtolf)
    return checks
end

# ---------------------------------------------------------------------------
# 統合（検証1–5の再利用 + 検証6–12 → 単一 AccountingCheckReport）
# ---------------------------------------------------------------------------

"""
    validate_capex_accounting(m::CapexCreditCycleModel, run::CapexCreditCycleRun;
                               atol=1e-8, rtol=1e-6) -> AccountingCheckReport

会計仕様 §8.1 の検証 12 項目（[`CAPEX_CC_ACCOUNTING_CHECKS`](@ref)）を実行し、単一の
[`AccountingCheckReport`](@ref) を返す。検証 1–5 は [`capex_accounting_snapshots`](@ref) が
構築した貸借対照表・取引フロー行列を仮の [`SFCResult`](@ref)（`SFCResult` そのものは返さない。
ADR 0013 決定15）に束ねて [`validate_sfc_accounting`](@ref) をそのまま呼び、実物資産行・純資産行
の行和（`:balance_row_sum`）・`S5`/`SX` 列の貸借対照表列和（`:balance_column_sum`）・`S4`/`SX`
列の取引フロー列和（`:flow_column_sum`）を会計仕様 §8.1「検証対象に含めないもの」に従って
除外する。検証 6–12 はモデル固有に実装し、同じ report へ統合する。`methodology` は
`contract_version = "sfc-primitives/1.0.0"`・`model_version = "$(CAPEX_CC_ACCOUNTING_VERSION)"`
を設定する。本モデル専用の許容誤差規約は作らない（既定 `atol=1e-8`・`rtol=1e-6`）。
"""
function validate_capex_accounting(
    m::CapexCreditCycleModel,
    run::CapexCreditCycleRun;
    atol::Real = 1e-8,
    rtol::Real = 1e-6,
)
    atolf = Float64(atol)
    rtolf = Float64(rtol)

    snaps = capex_accounting_snapshots(m, run)
    methodology = SFCMethodologyMetadata(;
        contract_version = SFC_CONTRACT_VERSION,
        model_version = CAPEX_CC_ACCOUNTING_VERSION,
        tolerance_abs = atolf,
        tolerance_rel = rtolf,
    )
    r = SFCResult(;
        model_name = model_name(m),
        scenario_name = String(run.scenario),
        sectors = _capex_acc_sectors(),
        instruments = _capex_acc_instruments(),
        snapshots = snaps,
        methodology = methodology,
    )
    # `:deposit`/`:extfund` は既定規約 `<instrument>_change` に一致しないため明示 map で解決する
    # （行名を `C-*`/`F-*` にしているため）。`:advance` は恒等的ゼロ（ストック不変）なので
    # 既定の「対応フロー未定義かつストック不変」経路で警告なしに扱われる。`:loan` は
    # `_capex_check_loan_stock_flow!` で別途検証するため `stock_flow_map` に含めない。
    stock_flow_map = Dict(:deposit => :F01, :extfund => :F07)
    generic = validate_sfc_accounting(
        r;
        atol = atolf,
        rtol = rtolf,
        stock_flow_map = stock_flow_map,
    )

    n_excluded_per_period =
        length(_CAPEX_ACC_EXCLUDED_ROW_SUM_INSTRUMENTS) +
        length(_CAPEX_ACC_EXCLUDED_BALANCE_COL_SECTORS) +
        length(_CAPEX_ACC_EXCLUDED_FLOW_COL_SECTORS)

    kept = AccountingViolation[]
    for v in generic.violations
        if v.check === :balance_row_sum &&
           v.instrument in _CAPEX_ACC_EXCLUDED_ROW_SUM_INSTRUMENTS
            continue
        end
        if v.check === :balance_column_sum &&
           v.sector in _CAPEX_ACC_EXCLUDED_BALANCE_COL_SECTORS
            continue
        end
        if v.check === :flow_column_sum && v.sector in _CAPEX_ACC_EXCLUDED_FLOW_COL_SECTORS
            continue
        end
        push!(kept, v)
    end
    performed_1to5 = generic.checks_performed - n_excluded_per_period * length(snaps)
    passed_1to5 = performed_1to5 - length(kept)

    checks_6to12 = AccountingViolation[]
    for idx in 1:length(snaps)
        tf = snaps[idx].transaction_flow
        _capex_checks_6to12!(checks_6to12, m, run, idx, tf, atolf, rtolf)
    end
    violations_6to12 = AccountingViolation[c for c in checks_6to12 if c.status !== acc_pass]
    performed_6to12 = length(checks_6to12)
    passed_6to12 = performed_6to12 - length(violations_6to12)

    all_violations = vcat(kept, violations_6to12)

    agg = acc_pass
    for v in all_violations
        _acc_severity(v.status) > _acc_severity(agg) && (agg = v.status)
    end

    maxres = 0.0
    for v in all_violations
        isfinite(v.residual) && abs(v.residual) > maxres && (maxres = abs(v.residual))
    end

    invalid_set = Set{String}()
    for v in all_violations
        v.status === acc_invalid && push!(invalid_set, v.period)
    end
    all_periods = String[snap.period for snap in snaps]
    invalid_periods = String[p for p in all_periods if p in invalid_set]
    valid_periods = String[p for p in all_periods if !(p in invalid_set)]

    return AccountingCheckReport(
        agg,
        all_violations,
        performed_1to5 + performed_6to12,
        passed_1to5 + passed_6to12,
        maxres,
        valid_periods,
        invalid_periods,
        generic.divergence_time,
        methodology,
        atolf,
        rtolf,
    )
end
