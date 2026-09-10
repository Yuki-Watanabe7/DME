# CCC 実証層: 識別診断・推定可否判定・弱識別時の W1–W4（Issue #245 / P-5）。
#
# `EB-1`–`EB-7` の推定ブロック仕様（候補 `EST` パラメータ・必須/補助観測・固定パラメータ・
# 式 ID・識別リスク `ID-1`–`ID-7`・弱識別対応 `W1`–`W4`）を機械可読な const として持ち、
# #244 が構築した観測 dataset に対して「どのブロックを推定してよいか」を決定論的に診断する。
# パラメータ値の最適化は行わない（それは #246 / P-6 の責務）。
#
# 読み取り専用の後処理層（会計層・診断層・較正層と同じ配置規律）。provider / HTTP を呼ばない。
#
# 正本:
#   docs/architecture/capex_credit_cycle_empirical_integration.md §5.6・§8.4・§8.6・§12.5
#   docs/models/capex_credit_cycle_empirical_strategy.md §7.4・§8・§15.1–§15.2・§16.5
#   docs/adr/0018-capex-credit-cycle-empirical-runtime-contract.md 決定 9・14・16

const CAPEX_CC_IDENTIFICATION_VERSION = "capex-credit-cycle-identification/1.0.0"

# 識別診断のステータス語彙（実証統合設計 §6.2）。5 値目を追加しない。
const CAPEX_CC_IDENTIFICATION_STATUSES =
    (:estimable, :weakly_identified, :not_identified, :insufficient_data)

# 弱識別時の対応規則（#170 §8.3）。
#   W1: 固定へ降格（対応する観測変数が E（潜在））          — 事前適用
#   W2: 範囲報告（観測が P / allocation 依存）              — 事前固定・事後発火
#   W3: 複数仕様の並列報告（潜在系列の構成方式が複数）      — 事前固定・事後発火
#   W4: 推定せず感応度のみ（必要系列が揃わない／閾値）      — 事前適用
const CAPEX_CC_WEAK_ID_ACTIONS = (:W1, :W2, :W3, :W4)

# 識別リスク（#170 §8.2）。
const CAPEX_CC_IDENTIFICATION_RISKS = (:ID1, :ID2, :ID3, :ID4, :ID5, :ID6, :ID7)

# ---------------------------------------------------------------------------
# 診断の設定（推定前に固定する。artifact identity の一部）
# ---------------------------------------------------------------------------

"""
    CapexIdentificationConfig

識別診断の検出しきい値。**推定前に固定し、結果を見て変えない**（#170 §8.3-規則・
[ADR 0018](../adr/0018-capex-credit-cycle-empirical-runtime-contract.md) 決定 9）。
`W2` / `W3` の**発火**しきい値は推定層（`CapexEstimationConfig`）の責務であり、ここでは
dataset と catalog から推定前に判定できる項目のみを持つ。

- `min_obs`: ブロックの必須系列がすべて非欠損で揃う四半期数の下限。下回ると
  `:insufficient_data`。
- `variation_tol`: 系列が「変動している」とみなす相対標準偏差の下限
  （`std ≤ variation_tol · max(1, |mean|)` なら定数扱い → `:not_identified`）。
- `collinearity_tol`: 必須系列ペアの `|corr|` がこれ以上なら近似特異
  （`:weakly_identified`）。
"""
struct CapexIdentificationConfig
    version::String
    min_obs::Int
    variation_tol::Float64
    collinearity_tol::Float64
end

function CapexIdentificationConfig(;
    min_obs::Int = 12,
    variation_tol::Float64 = 1e-6,
    collinearity_tol::Float64 = 0.995,
)
    min_obs >= 2 || throw(ArgumentError("min_obs は 2 以上でなければなりません"))
    (0 < variation_tol < 1) ||
        throw(ArgumentError("variation_tol は (0, 1) の範囲でなければなりません"))
    (0 < collinearity_tol <= 1) ||
        throw(ArgumentError("collinearity_tol は (0, 1] の範囲でなければなりません"))
    return CapexIdentificationConfig(
        CAPEX_CC_IDENTIFICATION_VERSION,
        min_obs,
        variation_tol,
        collinearity_tol,
    )
end

# ---------------------------------------------------------------------------
# 推定ブロック仕様
# ---------------------------------------------------------------------------

"""
    CapexEstimationBlockSpec

推定ブロック 1 個の宣言的仕様（実証統合設計 §5.6・#170 §7.4）。正典から機械可読へ転記した
もので、実装者が個別に選ぶ余地を残さない。

- `id`: `:EB1` … `:EB7`。
- `order`: 固定推定順序（#170 §7.4-2。`EB-1 → EB-3 → EB-4 → EB-6 → EB-7 → EB-5 → EB-2`）。
- `est_params`: このブロックで推定する候補パラメータ（改訂後の `EST`。総数 35。`Z-14`）。
- `fixed_params`: 同じ方程式群に現れるが推定しないパラメータ（`FIX`/`CAL-SS`/`CAL-OBS`/
  `SENS`）。`W1` 事前適用で `EST` から外れた `bh_cc_lend`/`_equity`/`_fc` を含む。
- `required_keys`: 欠けるとブロックを実行しないモデル変数（#170 §7.4-1）。
- `supporting_keys`: 識別を補助するが必須ではないモデル変数（潜在・proxy・会計恒等式で
  代替可能なもの）。
- `equation_ids`: #169 の式 ID。推定層の残差関数と 1:1 対応する（`Z-15`）。
- `identification_risks`: `:ID1` … `:ID7`（#170 §8.2）。
- `preassigned_actions`: `param => :W1/:W2/:W3/:W4`。**推定前に割り当てる**（#170 §8.3）。
  `:W1`/`:W4` は事前適用（対象を `est_params` から外す）、`:W2`/`:W3` は事前固定
  （発火の有無のみ推定後に決める）。
"""
struct CapexEstimationBlockSpec
    id::Symbol
    order::Int
    est_params::Vector{Symbol}
    fixed_params::Vector{Symbol}
    required_keys::Vector{Symbol}
    supporting_keys::Vector{Symbol}
    equation_ids::Vector{String}
    identification_risks::Vector{Symbol}
    preassigned_actions::Dict{Symbol, Symbol}
end

# `EB-1`–`EB-7`（#170 §7.4・§15.2・§16.5・実証統合設計 §8.4）。
# `order` の昇順で保持する（`EB-1 → EB-3 → EB-4 → EB-6 → EB-7 → EB-5 → EB-2`）。
# `EST` 総数 = 4 + 4 + 4 + 9 + 2 + 9 + 3 = 35（`Z-14`）。
const CAPEX_CC_ESTIMATION_BLOCKS = CapexEstimationBlockSpec[
    CapexEstimationBlockSpec(
        :EB1,
        1,
        # 4 EST: 金融系列のみで単一方程式ごとに逐次推定できる（#170 §7.4 EB-1）
        [:bh_fc_pol, :bh_spread_cov, :bh_spread_fc, :bh_lend_spread],
        [:bh_fc_adj, :bh_spread_pow, :bh_cov_threshold],
        [:fin_cond, :spread, :lend_stance, :policy_rate],
        [:coverage_agg, :int_burden_s1, :int_burden_s2, :int_burden_s3],
        ["E5-01", "E5-04", "E5-06"],
        [:ID2],
        # bh_spread_cov は coverage_agg（allocation 依存）を要する → W2（#170 §7.4 EB-1・§8.2 ID-2）
        Dict{Symbol, Symbol}(:bh_spread_cov => :W2),
    ),
    CapexEstimationBlockSpec(
        :EB3,
        2,
        # 4 EST（部門別 2×2）。会計恒等式が自由度を削り本モデルで最も識別が良い（#170 §8.2 ID-4）
        [:bh_inv_adj_s2, :bh_inv_adj_s3, :bh_prod_cut_s2, :bh_prod_cut_s3],
        [
            :bh_util_tgt_s2,
            :bh_util_tgt_s3,
            :bh_util_max_s2,
            :bh_util_max_s3,
            :bh_backlog_target_s2,
            :bh_backlog_target_s3,
            :bh_inv_target_s2,
            :bh_inv_target_s3,
            :bh_inv_thresh_s2,
            :bh_inv_thresh_s3,
        ],
        [:inv_s2, :inv_s3, :ship_s2, :ship_s3, :order_s2, :backlog_s2],
        [:y_s2, :y_s3, :order_s3, :backlog_s3, :util_s2, :util_s3],
        ["E9-06", "E9-07"],
        [:ID4],
        Dict{Symbol, Symbol}(),
    ),
    CapexEstimationBlockSpec(
        :EB4,
        3,
        # 4 EST（部門別 2×2）。bh_price_elas_s は SENS でありブロックに含めない
        [:bh_price_adj_s2, :bh_price_adj_s3, :bh_price_sens_s2, :bh_price_sens_s3],
        [:bh_price_scale_s2, :bh_price_scale_s3],
        [:price_s2, :price_s3, :util_s2, :util_s3],
        [:y_s2, :y_s3],
        ["E9-15", "E9-16"],
        Symbol[],
        Dict{Symbol, Symbol}(),
    ),
    CapexEstimationBlockSpec(
        :EB6,
        4,
        # 9 EST（emp_s4 は存在しないため s1/s2/s3/s5 のみ。Z-14・#170 §16.5）
        [
            :bh_emp_up_s1,
            :bh_emp_up_s2,
            :bh_emp_up_s3,
            :bh_emp_up_s5,
            :bh_emp_down_s1,
            :bh_emp_down_s2,
            :bh_emp_down_s3,
            :bh_emp_down_s5,
            :bh_wage_slope,
        ],
        # bh_emp_band_s は NL 閾値であり回帰しない（#170 §7.4 EB-6）。_s4 は空き値で含めない
        [:bh_emp_band_s1, :bh_emp_band_s2, :bh_emp_band_s3, :bh_emp_band_s5],
        [:emp_s1, :emp_s2, :emp_s3, :emp_tot, :wage],
        [:emp_s5, :y_s1, :y_s2, :y_s3, :y_s5, :y_tot],
        ["E10-06", "E10-09"],
        [:ID5],
        Dict{Symbol, Symbol}(),
    ),
    CapexEstimationBlockSpec(
        :EB7,
        5,
        # 2 EST。EB-6 と分離して段階推定する（#170 §8.2 ID-5）
        [:bh_mpc, :bh_cons_adj],
        [:st_cd0, :st_cons_auto, :st_cons_share_s1],
        [:cons, :hh_income],
        [:wage, :y_tot],
        ["E10-13"],
        [:ID5, :ID7],
        Dict{Symbol, Symbol}(),
    ),
    CapexEstimationBlockSpec(
        :EB5,
        6,
        # 9 EST。識別が最も難しいブロック（#170 §8.2 ID-1・ID-2）
        [
            :bh_alpha_capex_s1,
            :bh_cc_elas_s1,
            :bh_alpha_inv_s2,
            :bh_alpha_inv_s3,
            :bh_cc_elas_inv_s2,
            :bh_cc_elas_inv_s3,
            :bh_lend_elas_inv_s2,
            :bh_lend_elas_inv_s3,
            :bh_defer_roll,
        ],
        [
            :bh_dcap_lend_s1,
            :bh_dcap_lend_s2,
            :bh_dcap_lend_s3,
            :bh_cancel_thresh,
            :bh_cancel_slope,
            :bh_cancel_max,
            :bh_revive_s1,
            :bh_roll_thresh,
        ],
        [:capex_exec_s1, :spread, :lend_stance, :fin_cond],
        [
            :invest_s2,
            :invest_s3,
            :cost_capital_s1,
            :cost_capital_s2,
            :cost_capital_s3,
            :target_cap_s1,
            :cancel_s1,
            :ai_exp,
        ],
        ["E6-04", "E6-07", "E6-16", "E7-15"],
        [:ID1, :ID2],
        # ID-1: ai_exp が A → bh_alpha_capex_s1 は 3 仕様を並列報告（W3）
        # ID-2: bh_cc_elas_s1 は objective の等値域をグリッドで範囲報告（W2）。
        #       bh_alpha_capex_s1 と bh_cc_elas_s1 を同時推定しない（#170 §8.2 ID-2）
        Dict{Symbol, Symbol}(:bh_alpha_capex_s1 => :W3, :bh_cc_elas_s1 => :W2),
    ),
    CapexEstimationBlockSpec(
        :EB2,
        7,
        # 3 EST。bh_cc_lend/_equity/_fc は W1 事前適用で CAL-OBS（#170 §15.1）→ est_params に含めない
        [:bh_ev_elas, :bh_coll_elas, :bh_roll_slope],
        [:bh_cc_spread, :bh_cc_lend, :bh_cc_equity, :bh_cc_fc, :bh_ev_adj, :bh_roll_thresh],
        [:spread, :equity_val, :policy_rate],
        [:collateral, :cost_capital_s1, :cost_capital_s2, :cost_capital_s3, :rollover],
        ["E5-02", "E5-03", "E5-07"],
        [:ID2, :ID7],
        # cost_capital_s / collateral が E（潜在）→ bh_cc_* は W1、残り 3 本は W2（範囲報告。#170 §7.4 EB-2）
        Dict{Symbol, Symbol}(
            :bh_cc_lend => :W1,
            :bh_cc_equity => :W1,
            :bh_cc_fc => :W1,
            :bh_ev_elas => :W2,
            :bh_coll_elas => :W2,
            :bh_roll_slope => :W2,
        ),
    ),
]

# ---------------------------------------------------------------------------
# ブロック仕様のバリデーション
# ---------------------------------------------------------------------------

# 1 ブロックの内部整合を検査する（部分集合でも成立すべき契約）。
function _ccc_validate_one_block(
    b::CapexEstimationBlockSpec,
    seen_est::Dict{Symbol, Symbol},
)::Nothing
    param_names = Set(CAPEX_CC_PARAMETER_NAMES)
    placeholders = Set(CAPEX_CC_PARAMETER_DICT_PLACEHOLDERS)

    b.id in (:EB1, :EB2, :EB3, :EB4, :EB5, :EB6, :EB7) ||
        throw(ArgumentError("未知のブロック id :$(b.id)"))
    isempty(b.est_params) && throw(ArgumentError("$(b.id): est_params が空です"))
    isempty(b.equation_ids) && throw(ArgumentError("$(b.id): equation_ids が空です"))

    for p in b.est_params
        p in param_names || throw(ArgumentError("$(b.id): 未知の est_param $(p)"))
        p in placeholders && throw(
            ArgumentError(
                "$(b.id): 辞書上の空き値 $(p) を est_params に含めることはできません（§12.5-40）",
            ),
        )
        cls = capex_parameter_class(p)
        cls === :EST || throw(
            ArgumentError(
                "$(b.id): est_param $(p) の区分が :$(cls) です。:EST 以外を推定対象にできません（§12.5-46）",
            ),
        )
        haskey(seen_est, p) && throw(
            ArgumentError(
                "est_param $(p) が $(seen_est[p]) と $(b.id) の両方に現れます（EB 横断の同時推定を禁止。#170 §7.4）",
            ),
        )
        seen_est[p] = b.id
    end

    for p in b.fixed_params
        p in param_names || throw(ArgumentError("$(b.id): 未知の fixed_param $(p)"))
        p in placeholders && throw(
            ArgumentError(
                "$(b.id): 辞書上の空き値 $(p) を fixed_params に含めることはできません",
            ),
        )
        capex_parameter_class(p) === :EST && throw(
            ArgumentError(
                "$(b.id): fixed_param $(p) の区分が :EST です（fixed に置けません）",
            ),
        )
    end

    for (p, a) in b.preassigned_actions
        a in CAPEX_CC_WEAK_ID_ACTIONS ||
            throw(ArgumentError("$(b.id): 未知の弱識別対応 :$(a)（$(p)）"))
        p in param_names ||
            throw(ArgumentError("$(b.id): preassigned_actions の未知パラメータ $(p)"))
        if a in (:W2, :W3)
            p in b.est_params || throw(
                ArgumentError(
                    "$(b.id): $(p) => :$(a) は事前固定だが $(p) が est_params にありません",
                ),
            )
        end
    end

    for r in b.identification_risks
        r in CAPEX_CC_IDENTIFICATION_RISKS ||
            throw(ArgumentError("$(b.id): 未知の識別リスク :$(r)"))
    end
    return nothing
end

"""
    validate_capex_estimation_blocks(blocks = CAPEX_CC_ESTIMATION_BLOCKS; full = true) -> Nothing

ブロック仕様が正典と 1:1 対応することを検査する（Issue #245 受け入れ条件・実証統合設計
§12.5-39/40/46）。違反はすべて `ArgumentError`。

各ブロックについて（`full` に関わらず）:

- `est_params` は 6 区分の `:EST` のみ（`FIX`/`CAL-SS`/`CAL-OBS`/`SCN`/`SENS` を拒否。§12.5-46）。
- 辞書上の空き値（`bh_emp_*_s4` 等）が `est_params`/`fixed_params` に現れない（§12.5-40）。
- `est_params` がブロック間で重複しない（EB 横断の同時推定を構造的に排除。#170 §7.4 冒頭）。
- `preassigned_actions` の値が `CAPEX_CC_WEAK_ID_ACTIONS`、`:W2`/`:W3` のキーは `est_params` に
  含まれる。

`full = true`（既定）のとき、集合レベルの契約も検査する:

- `id` が `:EB1`–`:EB7` の集合、`order` が `1:7` の置換。
- `est_params` の総数が 35（`Z-14`）。
"""
function validate_capex_estimation_blocks(
    blocks::AbstractVector{CapexEstimationBlockSpec} = CAPEX_CC_ESTIMATION_BLOCKS;
    full::Bool = true,
)::Nothing
    seen_est = Dict{Symbol, Symbol}()
    for b in blocks
        _ccc_validate_one_block(b, seen_est)
    end

    if full
        length(blocks) == 7 || throw(
            ArgumentError(
                "推定ブロックは 7 件でなければなりません（実値: $(length(blocks))）",
            ),
        )
        ids = [b.id for b in blocks]
        Set(ids) == Set((:EB1, :EB2, :EB3, :EB4, :EB5, :EB6, :EB7)) ||
            throw(ArgumentError("ブロック id が :EB1–:EB7 と一致しません: $(ids)"))
        Set(b.order for b in blocks) == Set(1:7) || throw(
            ArgumentError(
                "order が 1:7 の置換ではありません: $([b.order for b in blocks])",
            ),
        )
        total_est = sum(length(b.est_params) for b in blocks)
        total_est == 35 ||
            throw(ArgumentError("EST 総数が $(total_est) です（正典は 35。Z-14）"))
    end
    return nothing
end

"""
    capex_estimation_block(id::Symbol) -> CapexEstimationBlockSpec

`id`（`:EB1` … `:EB7`）のブロック仕様を返す。
"""
function capex_estimation_block(id::Symbol)
    for b in CAPEX_CC_ESTIMATION_BLOCKS
        b.id === id && return b
    end
    throw(ArgumentError("未知の推定ブロック :$(id)（:EB1–:EB7 のいずれか）"))
end

# ---------------------------------------------------------------------------
# 診断結果型
# ---------------------------------------------------------------------------

"""
    CapexIdentificationDiagnostic

推定ブロック 1 個の識別診断（実証統合設計 §5.6）。**推定値は含まない**（診断のみ）。

- `status ∈ CAPEX_CC_IDENTIFICATION_STATUSES`。
  - `:estimable`: 必須系列が direct 観測で揃い、変動・共線性に問題がない。
  - `:weakly_identified`: `armed_actions` に従って `W2`/`W3` へ降格する
    （proxy/allocation 依存・近似特異・事前固定の弱識別）。点推定を額面どおり受け取らない。
  - `:not_identified`: 構造的に識別できない（候補がすべて `W1` 事前適用／必須系列に変動がない）。
  - `:insufficient_data`: 必須系列が欠損／標本が短い。
- `applied_actions`: 推定前に適用した `W1`/`W4`（対象は `effective_est_params` から外れる）。
- `armed_actions`: 推定前に固定した `W2`/`W3`（発火の有無は推定層が推定後に決める）。
- `variation`: 必須系列別の標本標準偏差（変動不足の検出）。
- `collinearity`: 必須系列ペア別の `|corr|`（近似特異の検出）。
- `reasons`: ステータスを決めた根拠（機械可読な接頭辞つき文字列。決定的な順序）。
"""
struct CapexIdentificationDiagnostic
    block::Symbol
    order::Int
    status::Symbol
    est_params::Vector{Symbol}
    effective_est_params::Vector{Symbol}
    required_keys::Vector{Symbol}
    missing_keys::Vector{Symbol}
    proxy_only_keys::Vector{Symbol}
    n_obs::Int
    variation::Dict{Symbol, Float64}
    collinearity::Dict{Tuple{Symbol, Symbol}, Float64}
    applied_actions::Dict{Symbol, Symbol}
    armed_actions::Dict{Symbol, Symbol}
    identification_risks::Vector{Symbol}
    equation_ids::Vector{String}
    reasons::Vector{String}
end

# ---------------------------------------------------------------------------
# 数値ヘルパ（Statistics へ依存しない。0 埋め・補完はしない）
# ---------------------------------------------------------------------------

function _ccc_id_mean(xs::AbstractVector{Float64})
    isempty(xs) && return 0.0
    return sum(xs) / length(xs)
end

# 母標準偏差（n で割る）。
function _ccc_id_std(xs::AbstractVector{Float64})
    length(xs) < 2 && return 0.0
    m = _ccc_id_mean(xs)
    return sqrt(sum((x - m)^2 for x in xs) / length(xs))
end

# Pearson 相関係数の絶対値。どちらかの分散が 0 なら 0（共線性なしと扱う）。
function _ccc_id_abscorr(a::AbstractVector{Float64}, b::AbstractVector{Float64})
    n = min(length(a), length(b))
    n < 2 && return 0.0
    av = @view a[1:n]
    bv = @view b[1:n]
    ma = _ccc_id_mean(collect(av))
    mb = _ccc_id_mean(collect(bv))
    cov = sum((av[i] - ma) * (bv[i] - mb) for i in 1:n)
    va = sum((av[i] - ma)^2 for i in 1:n)
    vb = sum((bv[i] - mb)^2 for i in 1:n)
    (va <= 0 || vb <= 0) && return 0.0
    r = cov / sqrt(va * vb)
    return isfinite(r) ? min(abs(r), 1.0) : 0.0
end

# ---------------------------------------------------------------------------
# モデル変数の観測強度の解決
# ---------------------------------------------------------------------------

# モデル変数 mv を dataset から解決する。
#   strength: :direct（D/C の direct・aggregation が存在）/ :proxy（P または proxy・allocation のみ）
#             / :missing（catalog に無い、または全期欠損）
#   series:   共通四半期軸に沿った Vector{Union{Float64, Missing}}
#   sources:  実際に用いた catalog キー
function _ccc_id_resolve(ds::CapexEmpiricalDataset, mv::Symbol)
    n = length(ds.dates)
    candidates = Tuple{Symbol, Symbol, Symbol}[]   # (key, observability, methodology)
    for (key, meas) in ds.measurements
        (key === mv || mv in meas.spec.model_vars) || continue
        haskey(ds.values, key) || continue
        any(v -> !ismissing(v) && isfinite(v), ds.values[key]) || continue
        push!(candidates, (key, meas.spec.observability, meas.spec.methodology))
    end
    sort!(candidates; by = t -> String(t[1]))

    if isempty(candidates)
        return (
            series = Vector{Union{Float64, Missing}}(missing, n),
            strength = :missing,
            sources = Symbol[],
        )
    end

    is_direct(o, m) = o in (:D, :C) && m in (:direct, :aggregation)
    strength = any(t -> is_direct(t[2], t[3]), candidates) ? :direct : :proxy

    local series::Vector{Union{Float64, Missing}}
    if length(candidates) == 1
        series = copy(ds.values[candidates[1][1]])
    elseif all(t -> t[3] === :aggregation, candidates)
        # 複数の集計系列（例: emp_s3 = machinery + construction + utilities）は要素和。
        series = Vector{Union{Float64, Missing}}(undef, n)
        for i in 1:n
            acc = 0.0
            ok = true
            for (key, _, _) in candidates
                v = ds.values[key][i]
                if ismissing(v) || !isfinite(v)
                    ok = false
                    break
                end
                acc += Float64(v)
            end
            series[i] = ok ? acc : missing
        end
    else
        # 混在: direct を優先、無ければ先頭（決定的）。
        pick = findfirst(t -> is_direct(t[2], t[3]), candidates)
        pick === nothing && (pick = 1)
        series = copy(ds.values[candidates[pick][1]])
    end

    return (
        series = series,
        strength = strength,
        sources = Symbol[t[1] for t in candidates],
    )
end

# ---------------------------------------------------------------------------
# ブロック単位の診断
# ---------------------------------------------------------------------------

function _ccc_diagnose_block(
    ds::CapexEmpiricalDataset,
    block::CapexEstimationBlockSpec,
    cfg::CapexIdentificationConfig,
)
    n = length(ds.dates)
    reasons = String[]

    resolved = Dict{Symbol, NamedTuple}()
    for mv in block.required_keys
        resolved[mv] = _ccc_id_resolve(ds, mv)
    end

    missing_keys =
        sort([mv for mv in block.required_keys if resolved[mv].strength === :missing])
    present = [mv for mv in block.required_keys if resolved[mv].strength !== :missing]
    proxy_only_keys = sort([mv for mv in present if resolved[mv].strength === :proxy])

    # 有効標本: 現存する必須系列がすべて非欠損・有限の四半期。
    valid_mask = falses(n)
    for i in 1:n
        valid_mask[i] = all(present) do mv
            v = resolved[mv].series[i]
            !ismissing(v) && isfinite(v)
        end
    end
    n_obs = count(valid_mask)

    # 変動（標本標準偏差）と近似特異（ペア相関）。
    variation = Dict{Symbol, Float64}()
    sample_vals = Dict{Symbol, Vector{Float64}}()
    for mv in present
        xs = Float64[Float64(resolved[mv].series[i]) for i in 1:n if valid_mask[i]]
        sample_vals[mv] = xs
        variation[mv] = _ccc_id_std(xs)
    end

    low_variation_keys = Symbol[]
    for mv in present
        xs = sample_vals[mv]
        m = _ccc_id_mean(xs)
        if variation[mv] <= cfg.variation_tol * max(1.0, abs(m))
            push!(low_variation_keys, mv)
        end
    end
    sort!(low_variation_keys)

    collinearity = Dict{Tuple{Symbol, Symbol}, Float64}()
    near_singular = Tuple{Symbol, Symbol}[]
    sorted_present = sort(present; by = String)
    for a in eachindex(sorted_present), b in eachindex(sorted_present)
        a < b || continue
        ka, kb = sorted_present[a], sorted_present[b]
        r = _ccc_id_abscorr(sample_vals[ka], sample_vals[kb])
        collinearity[(ka, kb)] = r
        r >= cfg.collinearity_tol && push!(near_singular, (ka, kb))
    end

    # --- 弱識別対応の事前適用 / 事前固定（#170 §8.3・実証統合設計 §8.6） ---
    applied = Dict{Symbol, Symbol}()   # W1 / W4
    armed = Dict{Symbol, Symbol}()     # W2 / W3
    for p in sort(collect(keys(block.preassigned_actions)); by = String)
        a = block.preassigned_actions[p]
        if a === :W1
            applied[p] = :W1
        elseif a === :W4
            applied[p] = :W4
        elseif a in (:W2, :W3) && p in block.est_params
            armed[p] = a
        end
    end

    effective_est = [p for p in block.est_params if !haskey(applied, p)]

    short_sample = n_obs < cfg.min_obs
    if !isempty(missing_keys)
        push!(
            reasons,
            "missing_required_series: " * join(sort(String.(missing_keys)), ", "),
        )
    end
    if short_sample
        push!(reasons, "short_sample: n_obs=$(n_obs) < min_obs=$(cfg.min_obs)")
    end
    if !isempty(low_variation_keys)
        push!(reasons, "no_variation: " * join(sort(String.(low_variation_keys)), ", "))
    end
    for (ka, kb) in near_singular
        push!(
            reasons,
            "near_singular: $(ka)~$(kb) |r|=$(round(collinearity[(ka, kb)]; digits = 3))",
        )
    end
    if !isempty(proxy_only_keys)
        push!(
            reasons,
            "proxy_or_allocation_only: " * join(sort(String.(proxy_only_keys)), ", "),
        )
    end

    # --- ステータス判定（先に一致した規則が優先） ---
    status = if !isempty(missing_keys) || short_sample
        for p in effective_est
            get!(applied, p, :W4)
        end
        :insufficient_data
    elseif !isempty(low_variation_keys)
        for p in effective_est
            get!(applied, p, :W4)
        end
        :not_identified
    elseif isempty(effective_est)
        # 候補がすべて W1 事前適用で外れている（対応する観測変数が潜在）。
        push!(reasons, "all_candidates_structurally_fixed: W1")
        :not_identified
    elseif !isempty(near_singular) || !isempty(proxy_only_keys)
        :weakly_identified
    elseif !isempty(armed)
        :weakly_identified
    else
        :estimable
    end

    # 事前固定・事後発火の補完:
    # proxy/allocation 依存・近似特異が理由のときは、事前割当の無い候補にも W2 を armed する
    # （#170 §8.3 W2 の適用条件「観測が P または allocation 依存」を catalog から推定前に判定）。
    if status === :weakly_identified &&
       (!isempty(near_singular) || !isempty(proxy_only_keys))
        for p in effective_est
            haskey(armed, p) || (armed[p] = :W2)
        end
    end

    effective_est_final = [p for p in block.est_params if !haskey(applied, p)]

    return CapexIdentificationDiagnostic(
        block.id,
        block.order,
        status,
        copy(block.est_params),
        sort(effective_est_final; by = String),
        copy(block.required_keys),
        missing_keys,
        proxy_only_keys,
        n_obs,
        variation,
        collinearity,
        applied,
        armed,
        copy(block.identification_risks),
        copy(block.equation_ids),
        reasons,
    )
end

"""
    diagnose_capex_identification(ds::CapexEmpiricalDataset,
                                  cal::Union{CapexEmpiricalCalibration, Nothing} = nothing;
                                  blocks = CAPEX_CC_ESTIMATION_BLOCKS,
                                  config = CapexIdentificationConfig())
        -> Vector{CapexIdentificationDiagnostic}

`EB-1`–`EB-7` の推定可否を、観測 dataset から決定論的に診断する。
**パラメータ値は推定しない**（較正・推定の前に診断のみ実行できる。#245 受け入れ条件）。

- ブロックは `order` の昇順で返す（`EB-1 → EB-3 → EB-4 → EB-6 → EB-7 → EB-5 → EB-2`。#170 §7.4-2）。
- `blocks` を明示的に渡した場合も 1 ブロックずつ評価する。**EB 横断の一括推定 API は提供しない**
  （ADR 0012 決定 12・#245 対象外）。
- `cal` を渡した場合、`cal.parameter_provenance` と突き合わせ、`est_params` が `:EST` 以外なら
  `ArgumentError`（`validate_capex_estimation_blocks` の区分検査との二重の防御。§12.5-46）。

診断は `ds` と `config` にのみ依存し、同一入力から同一結果を返す（`identification_hash`）。
"""
function diagnose_capex_identification(
    ds::CapexEmpiricalDataset,
    cal::Union{CapexEmpiricalCalibration, Nothing} = nothing;
    blocks::AbstractVector{CapexEstimationBlockSpec} = CAPEX_CC_ESTIMATION_BLOCKS,
    config::CapexIdentificationConfig = CapexIdentificationConfig(),
)::Vector{CapexIdentificationDiagnostic}
    # 呼び出し側が部分集合を渡せる（EB 横断 API ではない。1 ブロックずつ評価）。
    # 集合レベルの契約は正典 const に対してのみ課す。
    validate_capex_estimation_blocks(blocks; full = (blocks === CAPEX_CC_ESTIMATION_BLOCKS))

    # 較正層の 6 区分と齟齬がないことを確認（§12.5-46 の二重の防御）。
    if cal !== nothing
        prov = cal.parameter_provenance
        for b in blocks
            for p in b.est_params
                cls = get(prov, p, capex_parameter_class(p))
                cls === :EST || throw(
                    ArgumentError(
                        "$(b.id): est_param $(p) は較正層で :$(cls) に分類されています。推定対象にできません（§12.5-46）",
                    ),
                )
            end
        end
    end

    ordered = sort(collect(blocks); by = b -> b.order)
    return CapexIdentificationDiagnostic[
        _ccc_diagnose_block(ds, b, config) for b in ordered
    ]
end

# ---------------------------------------------------------------------------
# シリアライズ（決定的順序・artifact identity）
# ---------------------------------------------------------------------------

function _ccc_identification_diag_dict(d::CapexIdentificationDiagnostic)
    return Dict{String, Any}(
        "block" => String(d.block),
        "order" => d.order,
        "status" => String(d.status),
        "est_params" => sort(String.(d.est_params)),
        "effective_est_params" => sort(String.(d.effective_est_params)),
        "required_keys" => sort(String.(d.required_keys)),
        "missing_keys" => sort(String.(d.missing_keys)),
        "proxy_only_keys" => sort(String.(d.proxy_only_keys)),
        "n_obs" => d.n_obs,
        "variation" => Dict{String, Any}(String(k) => v for (k, v) in d.variation),
        "collinearity" =>
            Dict{String, Any}("$(a)__$(b)" => v for ((a, b), v) in d.collinearity),
        "applied_actions" =>
            Dict{String, Any}(String(k) => String(v) for (k, v) in d.applied_actions),
        "armed_actions" =>
            Dict{String, Any}(String(k) => String(v) for (k, v) in d.armed_actions),
        "identification_risks" => sort(String.(d.identification_risks)),
        "equation_ids" => sort(d.equation_ids),
        "reasons" => d.reasons,
    )
end

"""
    capex_identification_to_dict(diags; config, dataset_hash = "", targets_hash = "")
        -> Dict{String, Any}

識別診断一式を再現可能な辞書へ変換する。API キー・URL・ローカルパスは含めない。
`identification_hash` は診断内容（設定・ブロック仕様・ステータス・行動割当）の
canonical hash であり、`dataset_hash` / `targets_hash` を連結して artifact identity を作る。
"""
function capex_identification_to_dict(
    diags::AbstractVector{CapexIdentificationDiagnostic};
    config::CapexIdentificationConfig = CapexIdentificationConfig(),
    dataset_hash::AbstractString = "",
    targets_hash::AbstractString = "",
)
    ordered = sort(collect(diags); by = d -> d.order)
    diag_dicts = [_ccc_identification_diag_dict(d) for d in ordered]

    block_specs = Dict{String, Any}()
    for b in CAPEX_CC_ESTIMATION_BLOCKS
        block_specs[String(b.id)] = Dict{String, Any}(
            "order" => b.order,
            "est_params" => sort(String.(b.est_params)),
            "fixed_params" => sort(String.(b.fixed_params)),
            "required_keys" => sort(String.(b.required_keys)),
            "supporting_keys" => sort(String.(b.supporting_keys)),
            "equation_ids" => sort(b.equation_ids),
            "identification_risks" => sort(String.(b.identification_risks)),
            "preassigned_actions" => Dict{String, Any}(
                String(k) => String(v) for (k, v) in b.preassigned_actions
            ),
        )
    end

    payload = Dict{String, Any}(
        "identification_version" => CAPEX_CC_IDENTIFICATION_VERSION,
        "config" => Dict{String, Any}(
            "version" => config.version,
            "min_obs" => config.min_obs,
            "variation_tol" => config.variation_tol,
            "collinearity_tol" => config.collinearity_tol,
        ),
        "est_total" => sum(length(b.est_params) for b in CAPEX_CC_ESTIMATION_BLOCKS),
        "block_specs" => block_specs,
        "diagnostics" => diag_dicts,
        "status_counts" => Dict{String, Any}(
            String(s) => count(d -> d.status === s, ordered) for
            s in CAPEX_CC_IDENTIFICATION_STATUSES
        ),
    )

    identification_hash = "sha256:" * sha256_hex_of_canonical(payload)
    return Dict{String, Any}(
        "identification_version" => CAPEX_CC_IDENTIFICATION_VERSION,
        "dataset_hash" => String(dataset_hash),
        "targets_hash" => String(targets_hash),
        "identification_hash" => identification_hash,
        payload...,
    )
end

"""
    save_capex_identification(path, diags; config, dataset_hash, targets_hash) -> path

識別診断一式を JSON として保存する（`capex_identification_to_dict`）。
"""
function save_capex_identification(
    path::AbstractString,
    diags::AbstractVector{CapexIdentificationDiagnostic};
    config::CapexIdentificationConfig = CapexIdentificationConfig(),
    dataset_hash::AbstractString = "",
    targets_hash::AbstractString = "",
)
    open(path, "w") do io
        JSON3.pretty(
            io,
            capex_identification_to_dict(
                diags;
                config = config,
                dataset_hash = dataset_hash,
                targets_hash = targets_hash,
            ),
        )
    end
    return path
end
