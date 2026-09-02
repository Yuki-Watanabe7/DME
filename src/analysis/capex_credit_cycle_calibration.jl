# CCC steady-state target / inverse-calibration layer (Issue #244 / P-4).
#
# Turns a #243 `CapexEmpiricalDataset` into the 48 steady-state targets that the
# closed-form inverse calibration (`capex_credit_cycle_model`) requires, records
# per-target provenance (`source_kind`), assembles the `CAL-OBS` `st_` overrides
# routed through the model's `structural` keyword, runs the `SS-1`–`SS-17`
# checks without auto-correcting inconsistencies, and keeps the six-way parameter
# classification for all 147 parameters.  It adds no empirical-specific branch to
# the model equations and reuses the existing `CapexCreditCycleTargets` path.
#
# Read-only post-processing layer (same placement discipline as the accounting
# and diagnostics layers).  No provider / HTTP calls; no estimation of `EST`
# parameters; no scenario-shock calibration; no historical replay.
#
# 正本:
#   docs/architecture/capex_credit_cycle_empirical_integration.md §5.5・§8.1–§8.5
#   docs/models/capex_credit_cycle_empirical_strategy.md §5・§7・§15・§16
#   docs/adr/0018-capex-credit-cycle-empirical-runtime-contract.md 決定 5–7

const CAPEX_CC_CALIBRATION_VERSION = "capex-credit-cycle-calibration/1.0.0"

# CapexTargetSpec.source_kind の語彙（実証統合設計 §5.5）。
const CAPEX_CC_TARGET_SOURCE_KINDS = (:observed, :derived, :literature, :assumption)

# パラメータ 6 区分（#170 §7.1）。`_class` サフィックスなしの内部表現。
const CAPEX_CC_PARAMETER_CLASSES = (:FIX, :CAL_SS, :CAL_OBS, :EST, :SCN, :SENS)

# `emp_s4` が存在しないため方程式も観測も持たない辞書上の空き値（#170 §16.5・実証統合設計 §8.4）。
# 6 区分のいずれにも割り当てず、`parameter_provenance` では `:dict_placeholder` を返す。
const CAPEX_CC_PARAMETER_DICT_PLACEHOLDERS =
    (:st_lprod_s4, :st_wbase_s4, :bh_emp_up_s4, :bh_emp_down_s4, :bh_emp_band_s4)

# `capex_pipe_s^{ss} = st_pipelag_s^{lit} · dep_s^{ss}`（#170 §5.2-4・§8.2）の既定 pipelag。
# 業界の着工〜完工期間（3 四半期）。文献値であり観測しない（`E` 分類）。
const _CAPEX_CC_DEFAULT_PIPELAG = 3.0
# cost_capital / debt 比率などの既定。実装既定であり `:default_unattributed`。
const _CAPEX_CC_DEFAULT_BH_CC_SPREAD = 1.0
const _CAPEX_CC_DEFAULT_DCAP_MULTIPLIER = 2.0

# ---------------------------------------------------------------------------
# 出力型
# ---------------------------------------------------------------------------

"""
    CapexTargetSpec

48 個の定常水準ターゲットのうち 1 つと、それをどう作ったかの記録。

- `source_kind ∈ CAPEX_CC_TARGET_SOURCE_KINDS`。`:observed` 以外を「観測から較正した」と
  申告しない（実証統合設計 §8.2）。
- `observation_keys` は `:observed` / `:derived` のとき参照した dataset キー。
- `formula` は算式の逐語。`:derived` の残差は「残差である」と明記する（#170 §4.3）。
- `reference` は `source_kind == :literature` のとき必須。空文字なら `:default_unattributed`
  へ落とす（`Z-17`）。
"""
struct CapexTargetSpec
    key::Symbol
    source_kind::Symbol
    observation_keys::Vector{Symbol}
    formula::String
    timing::Symbol
    reference::String
end

"""
    CapexEmpiricalCalibration

観測 dataset から構築した定常水準・逆較正モデル・診断の束（実証統合設計 §5.5）。

- `targets` は既存型（無変更）。`target_specs` が 48 キーの `source_kind` と算式を保持する。
- `structural_overrides` は `structural` 経由で注入した `CAL-OBS` の `st_`（`Z-09`）。
- `steady_state_report` / `ss_inconsistent` は `SS-1`–`SS-17` の結果。自動補正しない（ADR 0007）。
- `ss_residual` は自由度なし整合条件（`capex_exec_s1^{ss} = st_delta_s1 · cap_s1^{ss}` など）の
  観測値と逆算値の乖離（`Z-13`）。
- `parameter_provenance` は 147 パラメータの 6 区分（辞書上の空き値は `:dict_placeholder`）。
"""
struct CapexEmpiricalCalibration
    dataset_hash::String
    targets::CapexCreditCycleTargets
    target_specs::Dict{Symbol, CapexTargetSpec}
    structural_overrides::NamedTuple
    model::CapexCreditCycleModel
    steady_state_report::CapexSteadyStateReport
    ss_residual::Dict{String, Float64}
    ss_inconsistent::Vector{String}
    baseline_window::CapexSampleWindow
    admissibility_warnings::Vector{String}
    parameter_provenance::Dict{Symbol, Symbol}
    warnings::Vector{String}
    targets_hash::String
    metadata::Dict{String, Any}
end

# ---------------------------------------------------------------------------
# パラメータ 6 区分（#170 §7.2–§7.4・§15.1–§15.2・§16.3–§16.5）
# ---------------------------------------------------------------------------

# 明示割当。ここに無い名前は base（`_s` 前の語幹）でグループ判定する。
const _CAPEX_CC_PARAM_CLASS_EXPLICIT = Dict{Symbol, Symbol}(
    # --- st_（構造） ---
    :st_cor_s1 => :SENS,          # util_s1^{ss} が E で逆算できない（§16.3）
    :st_cor_s2 => :CAL_SS,
    :st_cor_s3 => :CAL_SS,
    :st_va_share_s5 => :FIX,      # = 1（§11.1）
    :st_cshare_s3 => :CAL_OBS,
    :st_capfrac_s3 => :CAL_SS,
    :st_cons_share_s1 => :CAL_SS, # §15.5 で CAL-OBS → CAL-SS
    :st_cd0 => :CAL_SS,
    :st_commit_s1 => :SENS,
    :st_spread0 => :CAL_SS,
    :st_pol_ref => :CAL_SS,
    :st_profit_ref => :CAL_SS,
    :st_emp_ref => :CAL_SS,
    :st_coll_ltv => :CAL_SS,      # 余裕幅は SENS だが系統自体は CAL-SS（§7.2）
    :st_xdem0 => :CAL_SS,
    :st_cons_auto => :CAL_SS,
    :st_ev_min => :FIX,
    :st_wage_min => :FIX,
    :st_debt_tol => :FIX,
    # --- bh_（行動） ---
    :bh_cancel_thresh => :CAL_OBS,
    :bh_cancel_slope => :CAL_OBS,
    :bh_cancel_max => :FIX,
    :bh_revive_s1 => :CAL_OBS,
    :bh_defer_roll => :EST,
    :bh_roll_thresh => :CAL_OBS,
    :bh_cov_threshold => :CAL_OBS,
    :bh_spread_cov => :EST,
    :bh_spread_pow => :CAL_OBS,   # 既定 1
    :bh_spread_fc => :EST,
    :bh_lend_spread => :EST,
    :bh_fc_adj => :CAL_OBS,
    :bh_fc_pol => :EST,
    :bh_cc_spread => :CAL_OBS,    # 既定 1
    :bh_cc_lend => :CAL_OBS,      # W1 事前適用（§15.1）
    :bh_cc_equity => :CAL_OBS,    # W1 事前適用
    :bh_cc_fc => :CAL_OBS,        # W1 事前適用
    :bh_ev_adj => :CAL_OBS,
    :bh_ev_elas => :EST,
    :bh_coll_elas => :EST,
    :bh_roll_slope => :EST,
    :bh_wage_slope => :EST,
    :bh_mpc => :EST,
    :bh_cons_adj => :EST,
    :bh_alpha_capex_s1 => :EST,
    :bh_cc_elas_s1 => :EST,
    # --- pl_（政策） ---
    :pl_tau => :FIX,
    :pl_tau_corp => :FIX,
    :pl_ltv => :SENS,
)

# base 語幹ごとの区分（部門展開キーの既定）。
const _CAPEX_CC_PARAM_CLASS_BY_BASE = Dict{String, Symbol}(
    "st_delta" => :CAL_OBS,
    "st_pipelag" => :CAL_OBS,
    "st_va_share" => :CAL_SS,
    "st_lprod" => :CAL_SS,
    "st_wbase" => :CAL_SS,
    "st_capex_share" => :CAL_OBS,
    "st_invest_share" => :CAL_OBS,
    "st_gen_share" => :CAL_OBS,   # §16.4：標本全体の比で先に与え ext_demand を残差にする
    "st_maturity" => :SENS,
    "st_cash_min" => :CAL_OBS,
    "st_cash_ref" => :CAL_OBS,
    "st_dcap" => :CAL_OBS,
    "st_irrev" => :FIX,
    "st_payout" => :FIX,
    "st_cc0" => :CAL_SS,          # cost_capital ターゲットと spread から閉形式
    "st_price_min" => :FIX,
    "st_extdem" => :CAL_SS,       # 残差恒等式の出力（§7.2）
    "bh_util_tgt" => :CAL_SS,
    "bh_util_max" => :CAL_OBS,
    "bh_alpha_inv" => :EST,
    "bh_cc_elas_inv" => :EST,
    "bh_lend_elas_inv" => :EST,
    "bh_dcap_lend" => :CAL_OBS,
    "bh_backlog_target" => :CAL_SS,
    "bh_inv_target" => :CAL_SS,
    "bh_inv_thresh" => :CAL_OBS,
    "bh_inv_adj" => :EST,
    "bh_prod_cut" => :EST,
    "bh_price_adj" => :EST,
    "bh_price_sens" => :EST,
    "bh_price_scale" => :FIX,     # 既定 0.1
    "bh_price_elas" => :SENS,
    "bh_emp_up" => :EST,
    "bh_emp_down" => :EST,
    "bh_emp_band" => :CAL_OBS,    # NL 閾値。回帰しない（§7.4 EB-6）
)

"""
    capex_parameter_class(name::Symbol) -> Symbol

パラメータ 1 個の 6 区分（`:FIX` / `:CAL_SS` / `:CAL_OBS` / `:EST` / `:SCN` / `:SENS`）を返す。
`emp_s4` 系の辞書上の空き値は `:dict_placeholder` を返す（#170 §16.5）。
"""
function capex_parameter_class(name::Symbol)::Symbol
    name in CAPEX_CC_PARAMETER_DICT_PLACEHOLDERS && return :dict_placeholder
    haskey(_CAPEX_CC_PARAM_CLASS_EXPLICIT, name) &&
        return _CAPEX_CC_PARAM_CLASS_EXPLICIT[name]
    s = String(name)
    base = replace(s, r"_s(x|[1-5])$" => "")
    haskey(_CAPEX_CC_PARAM_CLASS_BY_BASE, base) &&
        return _CAPEX_CC_PARAM_CLASS_BY_BASE[base]
    throw(ArgumentError("パラメータ $name の 6 区分が未定義です（CCC 較正層のバグ）"))
end

"""
    capex_parameter_provenance() -> Dict{Symbol, Symbol}

`CAPEX_CC_PARAMETER_NAMES` の 147 パラメータすべてに 6 区分を割り当てた辞書を返す。
辞書上の空き値 5 個（`st_lprod_s4`・`st_wbase_s4`・`bh_emp_up_s4`・`bh_emp_down_s4`・
`bh_emp_band_s4`）は `:dict_placeholder`、残り 142 個はちょうど 1 つの 6 区分を持つ。
`SCN`（ショック規模・初期状態・診断閾値）は `parameters` に含めないため辞書には現れない。
"""
function capex_parameter_provenance()::Dict{Symbol, Symbol}
    return Dict{Symbol, Symbol}(
        n => capex_parameter_class(n) for n in CAPEX_CC_PARAMETER_NAMES
    )
end

# ---------------------------------------------------------------------------
# baseline 期間の系列平均（0 埋め・補完・トレンド除去をしない。#170 §5.1）
# ---------------------------------------------------------------------------

function _capex_window_labels(start_label::AbstractString, end_label::AbstractString)
    lo = _capex_quarter_index(start_label)
    hi = _capex_quarter_index(end_label)
    lo <= hi || throw(
        ArgumentError(
            "baseline_start ($start_label) は baseline_end ($end_label) 以前でなければなりません",
        ),
    )
    return lo, hi
end

# dataset のあるキーの baseline 平均。ウィンドウ内に非欠損・有限が 1 つも無ければ `missing`。
function _capex_baseline_mean(
    ds::CapexEmpiricalDataset,
    key::Symbol,
    lo::Int,
    hi::Int,
)::Union{Float64, Missing}
    haskey(ds.values, key) || return missing
    series = ds.values[key]
    acc = 0.0
    n = 0
    for (label, v) in zip(ds.dates, series)
        idx = _capex_quarter_index(label)
        (lo <= idx <= hi) || continue
        (ismissing(v) || !isfinite(v)) && continue
        acc += Float64(v)
        n += 1
    end
    return n == 0 ? missing : acc / n
end

# 標本全体（dataset の sample 窓）の平均。`st_gen_share_s` は baseline ではなく標本全体で
# 与える（§16.4・§8.3）。
function _capex_full_sample_mean(
    ds::CapexEmpiricalDataset,
    key::Symbol,
)::Union{Float64, Missing}
    haskey(ds.values, key) || return missing
    series = ds.values[key]
    acc = 0.0
    n = 0
    for v in series
        (ismissing(v) || !isfinite(v)) && continue
        acc += Float64(v)
        n += 1
    end
    return n == 0 ? missing : acc / n
end

# ---------------------------------------------------------------------------
# 観測キーの投影（catalog キー → モデル変数名）
# ---------------------------------------------------------------------------

# 各モデル変数について baseline 平均を返す。1:1（direct / proxy / 単一 aggregation）は
# そのまま、複数 aggregation は和、allocation は sector sales share で按分する。
# 未測定・欠損は含めない（穴埋めしない）。
function _capex_project_observations(ds::CapexEmpiricalDataset, lo::Int, hi::Int)
    by_key = Dict{Symbol, Float64}()
    for key in keys(ds.measurements)
        m = _capex_baseline_mean(ds, key, lo, hi)
        ismissing(m) && continue
        by_key[key] = m
    end

    # model var → [(catalog key, methodology)]
    mv_sources = Dict{Symbol, Vector{Tuple{Symbol, Symbol}}}()
    for (key, meas) in ds.measurements
        for mv in meas.spec.model_vars
            push!(
                get!(mv_sources, mv, Tuple{Symbol, Symbol}[]),
                (key, meas.spec.methodology),
            )
        end
    end

    P = Dict{Symbol, Float64}()
    # まず catalog キーそのものを P へ（synthetic fixture は入力キー名で spec を作る）
    for (key, val) in by_key
        P[key] = val
    end

    sales_share = _capex_sales_share(by_key, mv_sources)

    for (mv, srcs) in mv_sources
        present = [(k, meth) for (k, meth) in srcs if haskey(by_key, k)]
        isempty(present) && continue
        methods = unique(meth for (_, meth) in present)
        if length(present) == 1 && first(methods) in (:direct, :proxy, :aggregation)
            P[mv] = by_key[first(present)[1]]
        elseif all(m -> m === :aggregation, methods)
            P[mv] = sum(by_key[k] for (k, _) in present)
        elseif any(m -> m === :allocation, methods)
            # allocation: 総額系列があれば sector sales share で按分、
            # 併記の構成系列（例: order_s3 の construction 分）があれば和。
            alloc_total = 0.0
            for (k, meth) in present
                alloc_total += by_key[k]
            end
            if haskey(sales_share, mv)
                P[mv] = alloc_total * sales_share[mv]
            else
                P[mv] = alloc_total
            end
        else
            P[mv] = sum(by_key[k] for (k, _) in present) / length(present)
        end
    end
    return P
end

# nfc_debt_total / nfc_net_interest 等の allocation_key=:sector_sales_share 用の按分比。
function _capex_sales_share(by_key::Dict{Symbol, Float64}, mv_sources)
    # y_s1..s3 の baseline 平均（proxy/aggregation の単一ソース想定）
    y = Dict{Symbol, Float64}()
    for s in (:y_s1, :y_s2, :y_s3)
        srcs = get(mv_sources, s, Tuple{Symbol, Symbol}[])
        present = [k for (k, _) in srcs if haskey(by_key, k)]
        isempty(present) && continue
        y[s] = sum(by_key[k] for k in present) / length(present)
    end
    length(y) == 3 || return Dict{Symbol, Float64}()
    tot = y[:y_s1] + y[:y_s2] + y[:y_s3]
    tot > 0 || return Dict{Symbol, Float64}()
    return Dict{Symbol, Float64}(
        :debt_s1 => y[:y_s1] / tot,
        :debt_s2 => y[:y_s2] / tot,
        :debt_s3 => y[:y_s3] / tot,
        :cash_s1 => y[:y_s1] / tot,
        :cash_s2 => y[:y_s2] / tot,
        :cash_s3 => y[:y_s3] / tot,
        :int_burden_s1 => y[:y_s1] / tot,
        :int_burden_s2 => y[:y_s2] / tot,
        :int_burden_s3 => y[:y_s3] / tot,
    )
end

# ---------------------------------------------------------------------------
# 48 target キーの構築（実証統合設計 §8.2・§8.3）
# ---------------------------------------------------------------------------

_lit(literature::NamedTuple, key::Symbol, default) =
    haskey(literature, key) ? Float64(getproperty(literature, key)) : default

struct _CapexTargetBuild
    values::Dict{Symbol, Float64}
    specs::Dict{Symbol, CapexTargetSpec}
    missing_inputs::Dict{Symbol, Vector{Symbol}}  # target key => 欠けた観測キー
    warnings::Vector{String}
end

function _capex_spec!(
    b::_CapexTargetBuild,
    key::Symbol,
    source_kind::Symbol,
    obs_keys::Vector{Symbol},
    formula::String,
    timing::Symbol;
    reference::String = "",
)
    ref = reference
    if source_kind === :literature && isempty(strip(ref))
        ref = "default_unattributed"
    end
    b.specs[key] = CapexTargetSpec(key, source_kind, obs_keys, formula, timing, ref)
    return nothing
end

# P から必要な観測キーを取り出す。欠ければ b.missing_inputs へ登録し `nothing` を返す。
function _need(
    b::_CapexTargetBuild,
    target::Symbol,
    P::Dict{Symbol, Float64},
    keys_::Symbol...,
)
    got = Float64[]
    miss = Symbol[]
    for k in keys_
        if haskey(P, k)
            push!(got, P[k])
        else
            push!(miss, k)
        end
    end
    if !isempty(miss)
        append!(get!(b.missing_inputs, target, Symbol[]), miss)
        return nothing
    end
    return got
end

function _capex_build_target_values(
    ds::CapexEmpiricalDataset,
    P::Dict{Symbol, Float64},
    literature::NamedTuple,
    assumptions::NamedTuple,
)::_CapexTargetBuild
    b = _CapexTargetBuild(
        Dict{Symbol, Float64}(),
        Dict{Symbol, CapexTargetSpec}(),
        Dict{Symbol, Vector{Symbol}}(),
        String[],
    )
    V = b.values

    # --- 直接観測（:observed） ---
    _observed(key, src, formula, timing) = begin
        g = _need(b, key, P, src)
        _capex_spec!(b, key, :observed, [src], formula, timing)
        g === nothing || (V[key] = g[1])
    end
    _observed(
        :y_s1,
        :y_s1,
        "baseline mean of BEA GDP-by-industry real output for data processing / hosting (sector scope wider than S1: scope_bias=:over)",
        :SUM,
    )
    _observed(
        :y_s2,
        :y_s2,
        "baseline mean of FRB IP index IPG3344S anchored to BEA NAICS 334 real output",
        :SUM,
    )
    _observed(
        :y_s3,
        :y_s3,
        "baseline mean of FRB IP index IPG333S anchored to BEA NAICS 333 real output",
        :SUM,
    )
    _observed(
        :util_s2,
        :util_s2,
        "baseline mean of FRB capacity utilization CAPUTLG3344S / 100",
        :AVG,
    )
    _observed(
        :util_s3,
        :util_s3,
        "baseline mean of FRB capacity utilization CAPUTLG333S / 100",
        :AVG,
    )
    _observed(:emp_s1, :emp_s1, "baseline mean of BLS CES sector employment (S1)", :AVG)
    _observed(:emp_s2, :emp_s2, "baseline mean of BLS CES sector employment (S2)", :AVG)
    _observed(
        :emp_s3,
        :emp_s3,
        "baseline mean of BLS CES sector employment (S3 = machinery + construction + utilities)",
        :AVG,
    )
    _observed(
        :cap_s1,
        :cap_s1,
        "baseline mean of BEA fixed-asset net stock (S1; annual -> quarterly)",
        :EOP,
    )
    _observed(
        :cap_s2,
        :cap_s2,
        "baseline mean of BEA fixed-asset net stock (S2; annual -> quarterly)",
        :EOP,
    )
    _observed(
        :cap_s3,
        :cap_s3,
        "baseline mean of BEA fixed-asset net stock (S3; annual -> quarterly)",
        :EOP,
    )
    _observed(
        :dep_s1,
        :dep_s1,
        "baseline mean of BEA consumption of fixed capital (S1; annual / 4)",
        :SUM,
    )
    _observed(
        :dep_s2,
        :dep_s2,
        "baseline mean of BEA consumption of fixed capital (S2; annual / 4)",
        :SUM,
    )
    _observed(
        :dep_s3,
        :dep_s3,
        "baseline mean of BEA consumption of fixed capital (S3; annual / 4)",
        :SUM,
    )
    _observed(
        :order_cap_s2,
        :order_cap_s2,
        "baseline mean of Census M3 capital-goods-equivalent orders + BEA investment-goods breakdown (allocation; alternative-proxy sensitivity required, ID-3)",
        :SUM,
    )
    _observed(
        :order_cap_s3,
        :order_cap_s3,
        "baseline mean of Census M3 capital-goods-equivalent orders for S3 (allocation; alternative-proxy sensitivity required, ID-3)",
        :SUM,
    )
    _observed(
        :order_inv_s3,
        :order_inv_s3,
        "baseline mean of Census M3 / BEA investment-goods orders feeding S3 (allocation; st_invest_share_s3 calibration source)",
        :SUM,
    )
    _observed(
        :backlog_s2,
        :backlog_s2,
        "baseline mean of Census M3 NAICS 334 unfilled orders (end of period)",
        :EOP,
    )
    _observed(
        :backlog_s3,
        :backlog_s3,
        "baseline mean of Census M3 NAICS 333 unfilled orders (end of period)",
        :EOP,
    )
    _observed(
        :inv_s2,
        :inv_s2,
        "baseline mean of Census M3 NAICS 334 total inventories (end of period, current-cost)",
        :EOP,
    )
    _observed(
        :inv_s3,
        :inv_s3,
        "baseline mean of Census M3 NAICS 333 total inventories (end of period, current-cost)",
        :EOP,
    )
    _observed(
        :va_s1,
        :va_s1,
        "baseline mean of BEA GDP-by-industry real value added (S1; annual-rate / 4)",
        :SUM,
    )
    _observed(
        :va_s2,
        :va_s2,
        "baseline mean of BEA GDP-by-industry real value added (S2; annual-rate / 4)",
        :SUM,
    )
    _observed(
        :va_s3,
        :va_s3,
        "baseline mean of BEA GDP-by-industry real value added (S3; annual-rate / 4)",
        :SUM,
    )
    _observed(
        :wagebill_s1,
        :wagebill_s1,
        "baseline mean of BEA/BLS industry compensation of employees (S1)",
        :SUM,
    )
    _observed(
        :wagebill_s2,
        :wagebill_s2,
        "baseline mean of BEA/BLS industry compensation of employees (S2)",
        :SUM,
    )
    _observed(
        :wagebill_s3,
        :wagebill_s3,
        "baseline mean of BEA/BLS industry compensation of employees (S3)",
        :SUM,
    )
    _observed(
        :spread,
        :spread,
        "baseline mean of ICE BofA US High Yield OAS (daily -> monthly -> quarterly mean)",
        :AVG,
    )
    _observed(
        :policy_rate,
        :policy_rate,
        "baseline mean of effective federal funds rate FEDFUNDS (quarterly mean)",
        :AVG,
    )
    _observed(
        :cons,
        :cons,
        "baseline mean of PCECC96 real personal consumption (annual-rate / 4; sector scope narrower than model: scope_bias=:under)",
        :SUM,
    )

    # --- 派生（:derived） ---
    let g = _need(b, :y_s5, P, :y_tot, :va_s1, :va_s2, :va_s3)
        _capex_spec!(
            b,
            :y_s5,
            :derived,
            [:y_tot, :va_s1, :va_s2, :va_s3],
            "y_s5^ss = GDPC1^ss - (va_s1^ss + va_s2^ss + va_s3^ss)  (baseline means; #170 §3.2-5)",
            :SUM,
        )
        g === nothing || (V[:y_s5] = g[1] - (g[2] + g[3] + g[4]))
    end
    let g = _need(b, :emp_s5, P, :emp_tot, :emp_s1, :emp_s2, :emp_s3)
        _capex_spec!(
            b,
            :emp_s5,
            :derived,
            [:emp_tot, :emp_s1, :emp_s2, :emp_s3],
            "emp_s5^ss = PAYEMS^ss - (emp_s1^ss + emp_s2^ss + emp_s3^ss)  (baseline means)",
            :AVG,
        )
        g === nothing || (V[:emp_s5] = g[1] - (g[2] + g[3] + g[4]))
    end
    # wagebill_s5: total compensation - Σ_{s1..s3}
    let g = _need(
            b,
            :wagebill_s5,
            P,
            :wagebill_tot,
            :wagebill_s1,
            :wagebill_s2,
            :wagebill_s3,
        )
        _capex_spec!(
            b,
            :wagebill_s5,
            :derived,
            [:wagebill_tot, :wagebill_s1, :wagebill_s2, :wagebill_s3],
            "wagebill_s5^ss = total compensation^ss - (wagebill_s1^ss + wagebill_s2^ss + wagebill_s3^ss)",
            :SUM,
        )
        g === nothing || (V[:wagebill_s5] = g[1] - (g[2] + g[3] + g[4]))
    end
    for s in ("s1", "s2", "s3")
        dk = Symbol("debt_$s")
        g = _need(b, dk, P, dk)
        _capex_spec!(
            b,
            dk,
            :derived,
            [dk],
            "FRB Z.1 B.103 total nonfinancial-corporate debt x sector sales share (allocation; allocation-key sensitivity required, ID-2)",
            :EOP,
        )
        g === nothing || (V[dk] = g[1])
        ck = Symbol("cash_$s")
        gc = _need(b, ck, P, ck)
        _capex_spec!(
            b,
            ck,
            :derived,
            [ck],
            "FRB Z.1 liquid assets x same sector sales share (allocation)",
            :EOP,
        )
        gc === nothing || (V[ck] = gc[1])
    end

    # --- ext_demand_s（残差。§8.3 の識別仮定） ---
    _capex_build_ext_demand!(b, ds, P, V)

    # --- 文献（:literature） ---
    for s in ("s1", "s2", "s3")
        pk = Symbol("capex_pipe_$s")
        dk = Symbol("dep_$s")
        pipelag = _lit(literature, Symbol("st_pipelag_$s"), _CAPEX_CC_DEFAULT_PIPELAG)
        _capex_spec!(
            b,
            pk,
            :literature,
            [dk],
            "capex_pipe_$(s)^ss = st_pipelag_$(s)^lit ($(pipelag)) * dep_$(s)^ss  (E class: not observed; #170 §5.2-4)",
            :SUM;
            reference = haskey(literature, Symbol("st_pipelag_$s")) ?
                        "provided literature st_pipelag_$s (industry start-to-completion lag)" :
                        "",
        )
        haskey(V, dk) && (V[pk] = pipelag * V[dk])
    end
    bh_cc_spread = _lit(literature, :bh_cc_spread, _CAPEX_CC_DEFAULT_BH_CC_SPREAD)
    for s in ("s1", "s2", "s3")
        cck = Symbol("cost_capital_$s")
        intercept_key = Symbol("cost_capital_intercept_$s")
        _capex_spec!(
            b,
            cck,
            :literature,
            [:spread],
            "cost_capital_$(s)^ss = st_cc0_$(s)^lit + bh_cc_spread ($(bh_cc_spread)) * spread^ss / 100  (E class: do not present the level alone, #165 §5.4)",
            :AVG;
            reference = haskey(literature, intercept_key) ?
                        "provided literature intercept" : "",
        )
        if haskey(literature, intercept_key) && haskey(V, :spread)
            V[cck] =
                Float64(getproperty(literature, intercept_key)) +
                bh_cc_spread * V[:spread] / 100
        else
            append!(get!(b.missing_inputs, cck, Symbol[]), [intercept_key])
        end
    end

    # --- 仮定（:assumption） ---
    _capex_spec!(
        b,
        :cons_s1,
        :assumption,
        [:y_s1],
        "cons_s1^ss = cons_s1_share^asm * y_s1^ss  (A class: not observed; company disclosure excluded, ADR 0012 決定6)",
        :SUM;
        reference = "assumed S1 household-consumption share",
    )
    if haskey(assumptions, :cons_s1)
        V[:cons_s1] = Float64(assumptions.cons_s1)
    elseif haskey(assumptions, :cons_s1_share) && haskey(V, :y_s1)
        V[:cons_s1] = Float64(assumptions.cons_s1_share) * V[:y_s1]
    else
        append!(
            get!(b.missing_inputs, :cons_s1, Symbol[]),
            [:cons_s1_or_cons_s1_share_assumption],
        )
    end

    return b
end

# ext_demand_s^{ss} を §8.3 の識別仮定で残差として作る。
#   st_gen_share_s = mean(order_s over full sample) / y_s5^ss              (CAL-OBS)
#   order_gen_s^ss = st_gen_share_s * y_s5^ss
#   ext_demand_s2^ss = y_s2^ss - order_cap_s2^ss - order_gen_s2^ss
#   ext_demand_s3^ss = y_s3^ss - order_cap_s3^ss - order_inv_s3^ss - order_gen_s3^ss
# 負値をクリップしない。分散超過は診断として報告する（#170 §4.3 の 3 契約）。
function _capex_build_ext_demand!(
    b::_CapexTargetBuild,
    ds::CapexEmpiricalDataset,
    P::Dict{Symbol, Float64},
    V::Dict{Symbol, Float64},
)
    for (tgt, extra) in ((:ext_demand_s2, Symbol[]), (:ext_demand_s3, [:order_inv_s3]))
        s = tgt === :ext_demand_s2 ? "s2" : "s3"
        order_key = Symbol("order_$s")
        cap_key = Symbol("order_cap_$s")
        y_key = Symbol("y_$s")
        need_keys = vcat([y_key, cap_key, order_key], extra)
        _capex_spec!(
            b,
            tgt,
            :derived,
            need_keys,
            "ext_demand_$(s)^ss = y_$(s)^ss - order_cap_$(s)^ss" *
            (s == "s3" ? " - order_inv_s3^ss" : "") *
            " - st_gen_share_$(s) * y_s5^ss, where st_gen_share_$(s) = mean(order_$(s) over full sample) / y_s5^ss. " *
            "RESIDUAL: not an external-demand estimate; absorbs measurement/allocation error. Not clipped if negative (#170 §4.3, Z-12).",
            :SUM,
        )
        gen_obs = _capex_full_sample_mean(ds, order_key)
        miss = Symbol[]
        haskey(V, y_key) || push!(miss, y_key)
        haskey(V, cap_key) || push!(miss, cap_key)
        haskey(V, :y_s5) || push!(miss, :y_s5)
        ismissing(gen_obs) && push!(miss, order_key)
        for e in extra
            haskey(V, e) || push!(miss, e)
        end
        if !isempty(miss)
            append!(get!(b.missing_inputs, tgt, Symbol[]), miss)
            continue
        end
        y5 = V[:y_s5]
        gen_share = y5 != 0 ? gen_obs / y5 : 0.0
        order_gen = gen_share * y5
        ext = V[y_key] - V[cap_key] - order_gen
        s == "s3" && (ext -= V[:order_inv_s3])
        V[tgt] = ext
        if ext < 0
            push!(
                b.warnings,
                "$(tgt) の残差が負です（$(round(ext; digits = 4))）。配分比（st_capex_share_s / st_gen_share_s）または部門範囲を見直す（#170 §4.3・§8.3）。クリップしていません。",
            )
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# structural（CAL-OBS の st_）の組み立て
# ---------------------------------------------------------------------------

# `CAPEX_CC_STRUCTURAL_OVERRIDABLE` のうち較正層が観測・文献から与える系統だけを埋める。
# 与える根拠が無い（SENS の既定値のまま／dataset に比率系列が無い）ものは含めず、
# モデルの閉形式・既定値に任せる（穴埋めしない）。
function _capex_structural_overrides(
    P::Dict{Symbol, Float64},
    V::Dict{Symbol, Float64},
    literature::NamedTuple,
)
    ov = Dict{Symbol, Float64}()

    # st_pipelag_s: 文献値を明示指定したときだけ注入（既定 3 は閉形式 capex_pipe/dep と一致）
    for s in ("s1", "s2", "s3")
        k = Symbol("st_pipelag_$s")
        haskey(literature, k) && (ov[k] = Float64(getproperty(literature, k)))
    end
    # st_cshare_s3: 文献/観測比があれば注入（無ければモデル既定 0.3）
    if haskey(literature, :st_cshare_s3)
        ov[:st_cshare_s3] = Float64(literature.st_cshare_s3)
    elseif haskey(P, :cshare_s3_obs)
        ov[:st_cshare_s3] = P[:cshare_s3_obs]
    end
    # st_cash_min_s: Z.1 現金/売上比の下位分位（観測比があれば）
    for s in ("s1", "s2", "s3")
        k = Symbol("st_cash_min_$s")
        ok = Symbol("cash_min_$(s)_obs")
        if haskey(literature, k)
            ov[k] = Float64(getproperty(literature, k))
        elseif haskey(P, ok)
            ov[k] = P[ok]
        end
    end
    # st_dcap_s: debt/sales の倍率。倍率を文献指定したときだけ注入（既定 2 は実装値）
    mult = _lit(literature, :st_dcap_multiplier, NaN)
    if isfinite(mult)
        for s in ("s1", "s2", "s3")
            dk = Symbol("debt_$s")
            yk = Symbol("y_$s")
            (haskey(V, dk) && haskey(V, yk) && V[yk] != 0) || continue
            ov[Symbol("st_dcap_$s")] = mult * V[dk] / V[yk]
        end
    end

    return NamedTuple(ov)
end

# ---------------------------------------------------------------------------
# 公開 API: build_capex_steady_state_targets
# ---------------------------------------------------------------------------

"""
    build_capex_steady_state_targets(ds::CapexEmpiricalDataset;
                                     baseline_start, baseline_end,
                                     literature = NamedTuple(),
                                     assumptions = NamedTuple())
        -> (CapexCreditCycleTargets, Dict{Symbol, CapexTargetSpec}, NamedTuple)

`ds` の baseline 期間（`"YYYY-Qn"` の閉区間、既定は 8 四半期。#170 §5.1）の観測平均から
48 個の定常水準ターゲットを決定論的に算出する。

- `:observed` / `:derived` は baseline 平均・派生式（トレンド除去・HP フィルタを用いない）。
- `:literature`（`capex_pipe_s`・`cost_capital_s`）は `literature` から与える。`st_pipelag_s` は
  既定 3、`cost_capital_intercept_s*` は既定なし（未指定なら構築不能）。
- `:assumption`（`cons_s1`）は `assumptions` から与える（`cons_s1` か `cons_s1_share`）。
- `st_gen_share_s` は標本全体（`ds.sample`）での `order_s` / `y_s5` 比、`ext_demand_s` は残差
  （§8.3。負値をクリップしない）。

観測不足で構築できないターゲットがある場合は `ArgumentError` を投げ、どのターゲットが
どの観測キー欠損で作れないかを列挙する。**0・sample mean・任意 proxy で穴埋めしない**
（#170 受け入れ条件）。

返り値の 3 番目は `structural` へ渡す `CAL-OBS` の `st_` 上書き（`Z-09`）。
"""
function build_capex_steady_state_targets(
    ds::CapexEmpiricalDataset;
    baseline_start::AbstractString,
    baseline_end::AbstractString,
    literature::NamedTuple = NamedTuple(),
    assumptions::NamedTuple = NamedTuple(),
)
    lo, hi = _capex_window_labels(baseline_start, baseline_end)
    P = _capex_project_observations(ds, lo, hi)
    build = _capex_build_target_values(ds, P, literature, assumptions)

    want = Set(CAPEX_CC_TARGET_KEYS)
    have = Set(keys(build.values))
    missing_keys = sort(collect(setdiff(want, have)); by = String)
    if !isempty(missing_keys)
        detail = String[]
        for k in missing_keys
            reasons = get(build.missing_inputs, k, Symbol[])
            spec = get(build.specs, k, nothing)
            sk = spec === nothing ? "unknown" : String(spec.source_kind)
            push!(
                detail,
                "  $(k) [$(sk)] <- 欠損: $(isempty(reasons) ? "（観測キー不明）" : join(sort(String.(unique(reasons))), ", "))",
            )
        end
        throw(
            ArgumentError(
                "baseline 期間 $(baseline_start)..$(baseline_end) の観測から構築できない定常水準ターゲットが " *
                "$(length(missing_keys)) 個あります（穴埋めしません）:\n" *
                join(detail, "\n") *
                "\n:literature / :assumption のターゲットは literature= / assumptions= で明示的に与えてください。",
            ),
        )
    end

    values_nt = NamedTuple(k => build.values[k] for k in CAPEX_CC_TARGET_KEYS)
    source = Dict{String, Any}(
        "kind" => "empirical",
        "calibration_version" => CAPEX_CC_CALIBRATION_VERSION,
        "dataset_hash" => get(ds.metadata, "dataset_hash", ""),
        "baseline_start" => String(baseline_start),
        "baseline_end" => String(baseline_end),
        "description" => "CCC empirical steady-state targets from baseline-window observation means (#244 / P-4).",
    )
    targets = CapexCreditCycleTargets(values_nt, source)
    structural_overrides = _capex_structural_overrides(P, build.values, literature)
    return targets, build.specs, structural_overrides
end

# ---------------------------------------------------------------------------
# 公開 API: calibrate_capex_credit_cycle
# ---------------------------------------------------------------------------

function _capex_baseline_window(
    ds::CapexEmpiricalDataset,
    baseline_start::AbstractString,
    baseline_end::AbstractString,
)
    lo, hi = _capex_window_labels(baseline_start, baseline_end)
    calib_keys = sort(
        [k for (k, r) in ds.roles if r === :calibration_required && haskey(ds.values, k)];
        by = String,
    )
    in_window = String[]
    dropped = String[]
    partial = 0
    for (label, idx_ok) in ((l, lo <= _capex_quarter_index(l) <= hi) for l in ds.dates)
        idx_ok || continue
        anymiss = false
        for k in calib_keys
            i = findfirst(==(label), ds.dates)
            v = ds.values[k][i]
            if ismissing(v) || !isfinite(v)
                anymiss = true
                break
            end
        end
        if anymiss
            push!(dropped, label)
            partial += 1
        else
            push!(in_window, label)
        end
    end
    return CapexSampleWindow(
        String(baseline_start),
        String(baseline_end),
        length(in_window),
        calib_keys,
        sort(dropped; by = _capex_quarter_index),
        Dict{String, Int}("partial_calibration_coverage" => partial),
    )
end

"""
    calibrate_capex_credit_cycle(ds::CapexEmpiricalDataset;
                                 baseline_start, baseline_end,
                                 literature = NamedTuple(),
                                 assumptions = NamedTuple(),
                                 sectors = CapexSectorSets()) -> CapexEmpiricalCalibration

`ds` の baseline 期間から定常水準を作り（[`build_capex_steady_state_targets`](@ref)）、
既存の逆較正 `capex_credit_cycle_model(targets; structural = ...)` を再利用して
`CapexCreditCycleModel` を構築する。モデル方程式に実証固有の分岐を加えない。

- `SS-1`–`SS-17` を逆較正直後に検証し、破れた条件を `ss_inconsistent` に構造化する
  （自動補正しない。ADR 0007）。
- 自由度なし整合条件（`capex_exec_s1^{ss} = st_delta_s1 · cap_s1^{ss}`）の観測値と逆算値の
  乖離を `ss_residual` に記録する（`Z-13`）。
- `parameter_provenance` に 147 パラメータの 6 区分を保持する。
- `SCN` / `SENS` パラメータを較正で上書きしない（`structural` は `CAL-OBS` の
  `CAPEX_CC_STRUCTURAL_OVERRIDABLE` のみ）。
- `dataset_hash` / `targets_hash` / `calibration_version` を `metadata` に残す。
"""
function calibrate_capex_credit_cycle(
    ds::CapexEmpiricalDataset;
    baseline_start::AbstractString,
    baseline_end::AbstractString,
    literature::NamedTuple = NamedTuple(),
    assumptions::NamedTuple = NamedTuple(),
    sectors::CapexSectorSets = CapexSectorSets(),
)
    targets, target_specs, structural_overrides = build_capex_steady_state_targets(
        ds;
        baseline_start = baseline_start,
        baseline_end = baseline_end,
        literature = literature,
        assumptions = assumptions,
    )

    model = capex_credit_cycle_model(
        targets;
        structural = structural_overrides,
        sectors = sectors,
    )

    ss_report = capex_steady_state_report(model)
    ss_inconsistent = sort([k for (k, v) in ss_report.checks if !v.passed])

    # 自由度なし整合条件の乖離（Z-13）: capex_exec_s1 の観測（3 成分の和）vs 逆算（= dep_s1）。
    lo, hi = _capex_window_labels(baseline_start, baseline_end)
    P = _capex_project_observations(ds, lo, hi)
    ss_residual = Dict{String, Float64}()
    if haskey(P, :capex_exec_s1)
        derived = targets.values.dep_s1  # st_delta_s1 · cap_s1^{ss} = dep_s1^{ss}
        ss_residual["capex_exec_s1"] = P[:capex_exec_s1] - derived
    end

    baseline_window = _capex_baseline_window(ds, baseline_start, baseline_end)

    admissibility_warnings = String[]
    if baseline_window.n_obs != 8
        push!(
            admissibility_warnings,
            "baseline 期間の完全観測四半期が $(baseline_window.n_obs) 個です（#170 §2.1 は 8 四半期を想定）。",
        )
    end
    for s in ("s2", "s3")
        k = Symbol("ext_demand_$s")
        haskey(targets.values, k) &&
            getproperty(targets.values, k) < 0 &&
            push!(
                admissibility_warnings,
                "$(k)^ss が負です（残差。クリップしていません。§8.3）。",
            )
    end
    for (name, r) in ss_residual
        rel = abs(r) / max(abs(get(P, Symbol(name), 1.0)), 1.0)
        rel > 0.05 && push!(
            admissibility_warnings,
            "自由度なし整合条件 $(name) の相対乖離が $(round(rel; digits = 3)) です（観測値と逆算値のどちらを優先したか記録すること。#170 §5.2-5）。",
        )
    end

    provenance = capex_parameter_provenance()

    warnings = copy(_capex_target_warnings(target_specs))
    for k in keys(structural_overrides)
        push!(warnings, "structural override 注入: $(k)（CAL-OBS。実証統合設計 §5.5）")
    end
    isempty(ss_inconsistent) || push!(
        warnings,
        "定常条件 $(join(ss_inconsistent, ", ")) が破れています。ss_inconsistent を参照（自動補正しません。ADR 0007）。",
    )

    class_counts = Dict{String, Int}()
    for (_, c) in provenance
        class_counts[String(c)] = get(class_counts, String(c), 0) + 1
    end

    targets_hash = _capex_targets_hash(targets, target_specs, structural_overrides)

    metadata = Dict{String, Any}(
        "calibration_version" => CAPEX_CC_CALIBRATION_VERSION,
        "dataset_hash" => get(ds.metadata, "dataset_hash", ""),
        "target_contract_keys" => length(CAPEX_CC_TARGET_KEYS),
        "parameter_dictionary_size" => length(CAPEX_CC_PARAMETER_NAMES),
        "baseline_start" => String(baseline_start),
        "baseline_end" => String(baseline_end),
        "baseline_n_obs" => baseline_window.n_obs,
        "sample_start" => get(ds.metadata, "sample_start", ""),
        "sample_end" => get(ds.metadata, "sample_end", ""),
        "gen_share_window" => "full_sample",
        "literature_keys" => sort(String.(collect(keys(literature)))),
        "assumption_keys" => sort(String.(collect(keys(assumptions)))),
        "structural_override_keys" =>
            sort(String.(collect(keys(structural_overrides)))),
        "parameter_class_counts" => class_counts,
        "targets_hash" => targets_hash,
        "vintage_mode" => get(ds.metadata, "vintage_mode", "latest_only"),
        "data_vintage" => get(ds.metadata, "data_vintage", "unknown"),
    )

    return CapexEmpiricalCalibration(
        get(ds.metadata, "dataset_hash", ""),
        targets,
        target_specs,
        structural_overrides,
        model,
        ss_report,
        ss_residual,
        ss_inconsistent,
        baseline_window,
        admissibility_warnings,
        provenance,
        warnings,
        targets_hash,
        metadata,
    )
end

function _capex_target_warnings(specs::Dict{Symbol, CapexTargetSpec})
    w = String[]
    for k in sort(collect(keys(specs)); by = String)
        s = specs[k]
        s.source_kind === :literature && push!(
            w,
            "$(k): source_kind=:literature（reference=$(s.reference)）。観測較正値ではない。",
        )
        s.source_kind === :assumption &&
            push!(w, "$(k): source_kind=:assumption。観測不能（#170 §3.3・§6.4）。")
        occursin("RESIDUAL", s.formula) &&
            push!(w, "$(k): 残差構成。モデル外需要の推定値として提示しない（#170 §4.3）。")
    end
    return w
end

# ---------------------------------------------------------------------------
# hash / シリアライズ
# ---------------------------------------------------------------------------

function _capex_targets_hash(
    targets::CapexCreditCycleTargets,
    specs::Dict{Symbol, CapexTargetSpec},
    structural_overrides::NamedTuple,
)
    payload = Dict{String, Any}(
        "calibration_version" => CAPEX_CC_CALIBRATION_VERSION,
        "target_keys" => sort(String.(collect(CAPEX_CC_TARGET_KEYS))),
        "values" => Dict{String, Any}(
            String(k) => Float64(getproperty(targets.values, k)) for
            k in CAPEX_CC_TARGET_KEYS
        ),
        "target_specs" => Dict{String, Any}(
            String(k) => Dict{String, Any}(
                "source_kind" => String(s.source_kind),
                "observation_keys" => sort(String.(s.observation_keys)),
                "formula" => s.formula,
                "timing" => String(s.timing),
                "reference" => s.reference,
            ) for (k, s) in specs
        ),
        "structural_overrides" => Dict{String, Any}(
            String(k) => Float64(v) for (k, v) in pairs(structural_overrides)
        ),
    )
    return "sha256:" * sha256_hex_of_canonical(payload)
end

"""
    capex_calibration_to_dict(cal::CapexEmpiricalCalibration) -> Dict{String, Any}

再現に必要な公開情報（定常水準・target spec・structural override・区分・診断）を辞書化する。
API キー・URL・ローカルパスは含めない。
"""
function capex_calibration_to_dict(cal::CapexEmpiricalCalibration)
    return Dict{String, Any}(
        "calibration_version" => CAPEX_CC_CALIBRATION_VERSION,
        "dataset_hash" => cal.dataset_hash,
        "targets_hash" => cal.targets_hash,
        "targets" => Dict{String, Any}(
            String(k) => Float64(getproperty(cal.targets.values, k)) for
            k in CAPEX_CC_TARGET_KEYS
        ),
        "target_source" => cal.targets.source,
        "target_specs" => Dict{String, Any}(
            String(k) => Dict{String, Any}(
                "source_kind" => String(s.source_kind),
                "observation_keys" => sort(String.(s.observation_keys)),
                "formula" => s.formula,
                "timing" => String(s.timing),
                "reference" => s.reference,
            ) for (k, s) in cal.target_specs
        ),
        "structural_overrides" => Dict{String, Any}(
            String(k) => Float64(v) for (k, v) in pairs(cal.structural_overrides)
        ),
        "parameters" => Dict{String, Any}(
            String(k) => Float64(v) for (k, v) in pairs(parameters(cal.model))
        ),
        "parameter_provenance" => Dict{String, Any}(
            String(k) => String(v) for (k, v) in cal.parameter_provenance
        ),
        "ss_residual" => cal.ss_residual,
        "ss_inconsistent" => cal.ss_inconsistent,
        "steady_state_checks" => Dict{String, Any}(
            k => Dict{String, Any}(
                "passed" => v.passed,
                "residual" => (isfinite(v.residual) ? v.residual : nothing),
                "tolerance" => (isfinite(v.tolerance) ? v.tolerance : nothing),
            ) for (k, v) in cal.steady_state_report.checks
        ),
        "baseline_window" => Dict{String, Any}(
            "sample_start" => cal.baseline_window.sample_start,
            "sample_end" => cal.baseline_window.sample_end,
            "n_obs" => cal.baseline_window.n_obs,
            "binding_series" => sort(String.(cal.baseline_window.binding_series)),
            "dropped_dates" => cal.baseline_window.dropped_dates,
            "exclusion_reasons" => cal.baseline_window.exclusion_reasons,
        ),
        "admissibility_warnings" => cal.admissibility_warnings,
        "warnings" => cal.warnings,
        "metadata" => cal.metadata,
    )
end

"""
    save_capex_calibration(path, cal) -> path

`CapexEmpiricalCalibration` を JSON として保存する（`capex_calibration_to_dict`）。
"""
function save_capex_calibration(path::AbstractString, cal::CapexEmpiricalCalibration)
    open(path, "w") do io
        JSON3.pretty(io, capex_calibration_to_dict(cal))
    end
    return path
end
