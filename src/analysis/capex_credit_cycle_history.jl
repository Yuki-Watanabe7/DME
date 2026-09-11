# 部門別CAPEX・信用循環モデル（CCC）の履歴再生候補選定層（Issue #247 / `P-7`）。
#
# `H1`–`H6` を `NC-1`–`NC-7`（docs/models/capex_credit_cycle_empirical_strategy.md §9.1）で
# 機械的に評価し、`selected` / `excluded` / `insufficient_data` を固定する。`L1`
# （`ObservedEvent`）と `L3`（`ScenarioAssumption`）を別フィールドで保持し、`L2` の解釈は
# 人手の `interpretation_notes` として記録する（自動生成しない、`Z-20`）。
#
# 本ファイルは replay の実行（外生パス構築・`capex_run` 呼び出し）を行わない。episode の
# 構成と NC 判定のみが責務であり、モデル呼び出しは一切行わない（#247 対象外：
# replay model execution / parameter estimation）。
#
# Design: docs/architecture/capex_credit_cycle_empirical_integration.md §9.1（`P-7` / #247）・
#         docs/models/capex_credit_cycle_empirical_strategy.md §9（履歴再生の候補と選定基準）・
#         docs/architecture/macro_event_contract.md（4層概念階層）・ADR 0018 決定 8。
#
# depends on: data/capex_credit_cycle_measurements.jl（`CapexEmpiricalDataset`）・
# analysis/capex_credit_cycle_diagnostics.jl（`CapexDiagnosticThresholds`。`NC-2` の深さ閾値を
# 診断層と共有し、独自の magic number を持たない）・scenarios/macro_events.jl（4層型）・
# scenarios/scenario_time.jl（`CalendarQuarter`）・scenarios/scenario_provenance.jl
# （`_scenario_sha256`・`_scenario_assumption_hash_dict`。`event_set_hash` と同じ正準化・
# hash手続きを再利用する）・artifacts/json_canonical.jl（`sha256_hex_of_canonical`）・JSON3。

# ---------------------------------------------------------------------------
# 語彙定数
# ---------------------------------------------------------------------------

"本ファイルの契約 version。"
const CAPEX_CC_HISTORY_VERSION = "capex-credit-cycle-history/1.0.0"

"""
    CAPEX_CC_EPISODE_IDS

履歴再生候補6件の確定集合（実証戦略 §9.2）。**2026-09 の現在局面はここに含めない**
（#260 の live holdout 専用。#247 本文「2026-09の現在episodeをH1–H6へ後付けしない」）。
"""
const CAPEX_CC_EPISODE_IDS = (:H1, :H2, :H3, :H4, :H5, :H6)

"episode の採否状態（実証統合設計 §9.1・§6.3 の表）。"
const CAPEX_CC_EPISODE_STATUSES = (:selected, :excluded, :insufficient_data)

"必要条件7件の識別子（実証戦略 §9.1）。"
const CAPEX_CC_NC_IDS = (:NC1, :NC2, :NC3, :NC4, :NC5, :NC6, :NC7)

"""
    CAPEX_CC_SPECIAL_FACTOR_KINDS

`NC-3` が数える「単一の特殊要因」の4種（実証戦略 §9.1 `NC-3`）。(a) 金融危機、
(b) パンデミック等の供給制約、(c) 大規模財政・金融政策の急転、(d) 統計の定義変更。
この4種**以外**の同時発生要因（商品価格変動・通商政策等）は `NC-3` の判定対象に
含めない（本書の定義を拡張しない。混同すると特殊要因の判定が際限なく広がる）。
"""
const CAPEX_CC_SPECIAL_FACTOR_KINDS =
    (:financial_crisis, :supply_shock, :policy_regime_shift, :statistical_definition_change)

"""
    CAPEX_CC_EXPECTED_DIAGNOSTIC_LABELS

`NC-7`（集合レベルの必要条件）の評価にのみ用いる**事前の想定ラベル**（実証戦略 §9.2 の表の
「想定される診断ラベル」列）。モデルを実行して得た診断ラベル（`capex_diagnostics` の
`label`）とは別物であり、episode の事後選択には使わない。診断層の
`(:broad_downturn, :sectoral_downturn, :contained_adjustment, :indeterminate)` と同じ語彙を
共有する。
"""
const CAPEX_CC_EXPECTED_DIAGNOSTIC_LABELS =
    (:broad_downturn, :sectoral_downturn, :contained_adjustment, :indeterminate)

"""
    CAPEX_CC_EPISODE_REQUIRED_MODEL_VARS

`NC-1` が要求する必須観測変数（`EB-1`・`EB-3`・`EB-6`・`EB-7` の `required_keys` の和集合、
実証戦略 §9.1 `NC-1`）。`CAPEX_CC_ESTIMATION_BLOCKS`（Issue #245）と独立に固定しており、
ブロック定義を変更しても本定数は自動追従しない（`NC-1` の対象ブロックは `EB-1`・`EB-3`・
`EB-6`・`EB-7` の4本のみで `EB-2`・`EB-4`・`EB-5` は含まない、という実証戦略 §9.1 の決定を
明示的に固定するため）。
"""
const CAPEX_CC_EPISODE_REQUIRED_MODEL_VARS = (
    # EB-1（金融条件）
    :fin_cond,
    :spread,
    :lend_stance,
    :policy_rate,
    # EB-3（生産・在庫）
    :inv_s2,
    :inv_s3,
    :ship_s2,
    :ship_s3,
    :order_s2,
    :backlog_s2,
    # EB-6（雇用・賃金）
    :emp_s1,
    :emp_s2,
    :emp_s3,
    :emp_tot,
    :wage,
    # EB-7（消費）
    :cons,
    :hh_income,
)

"""
    CAPEX_CC_NC2_SERIES

`NC-2`（需要・CAPEX・信用・雇用の時間順序）が追跡する4系列（実証戦略 §9.1 `NC-2`）。
"""
const CAPEX_CC_NC2_SERIES = (:order_s2, :capex_exec_s1, :spread, :emp_tot)

"""
    CAPEX_CC_NC2_THRESHOLD_MAP

`NC-2` の4系列と `CapexDiagnosticThresholds`（分析契約 §4.2 `G1`–`G4`）のフィールドの対応。
`order_s2`・`capex_exec_s1` は部門別投資の深さ `dI_{s,t}`（`G2`）に、`emp_tot` は雇用の深さ
`dL_t`（`G3`）に、`spread` は信用条件の深さ `G4` に対応させる。独自の閾値を新設せず、
診断層の既定値を共有する（マジックナンバーの二重管理を避ける）。
"""
const CAPEX_CC_NC2_THRESHOLD_MAP = Dict{Symbol, Symbol}(
    :order_s2 => :di_sector,
    :capex_exec_s1 => :di_sector,
    :emp_tot => :dl,
    :spread => :spread_bp,
)

# ---------------------------------------------------------------------------
# CapexHistoricalEpisodeSpec（実証統合設計 §9.1、`Z-20`）
# ---------------------------------------------------------------------------

"""
    CapexHistoricalEpisodeSpec

履歴再生候補1件の宣言的仕様。`observed_events`（`L1`）と `assumptions`（`L3`）を別フィールドで
保持し、`L2` に相当する人手の解釈は `interpretation_notes` に文章として記録する（自動生成
しない、`Z-20`）。

## フィールド
- `id` / `label`: `CAPEX_CC_EPISODE_IDS` のいずれか、と表示名。
- `period_zero`: 評価区間の起点（`t=0`）。イベント層と同じ `CalendarQuarter`。
- `runup_quarters` / `eval_quarters`: 助走・評価の四半期数（既定 8 / 20）。
- `observed_events::Vector{ObservedEvent}`: 起点イベントの `L1` 記録。magnitude 無しを許す。
- `assumptions::Vector{ScenarioAssumption}`: `L3`。`magnitude_source` を必ず持つ。`L1` から
  自動生成しない（空でもよい）。
- `interpretation_notes`: `L2` に相当する人手の解釈文（自動生成しない）。
- `in_sample`: 推定候補集合に含めるか（`false` は out-of-sample 専用の扱い）。
- `notes`: 一般的な注記。
- `special_factors::Vector{Symbol}`: `NC-3` が数える特殊要因（`CAPEX_CC_SPECIAL_FACTOR_KINDS`
  の部分集合）。実証戦略 §9.1 の4種のみを対象とし、それ以外の同時発生要因（商品価格変動・
  通商政策等）はここに含めない。
- `data_definition_break_resolved::Bool`: `NC-4`。期間内に系列定義変更があっても、接続方法が
  確認できていれば `true`。
- `expected_diagnostic_label::Symbol`: `NC-7`（集合レベル）専用の事前想定ラベル
  （`CAPEX_CC_EXPECTED_DIAGNOSTIC_LABELS`）。モデル診断の出力ではない。
"""
struct CapexHistoricalEpisodeSpec
    id::Symbol
    label::String
    period_zero::CalendarQuarter
    runup_quarters::Int
    eval_quarters::Int
    observed_events::Vector{ObservedEvent}
    assumptions::Vector{ScenarioAssumption}
    interpretation_notes::String
    in_sample::Bool
    notes::String
    special_factors::Vector{Symbol}
    data_definition_break_resolved::Bool
    expected_diagnostic_label::Symbol

    function CapexHistoricalEpisodeSpec(;
        id::Symbol,
        label::AbstractString,
        period_zero::CalendarQuarter,
        runup_quarters::Int = 8,
        eval_quarters::Int = 20,
        observed_events::Vector{ObservedEvent} = ObservedEvent[],
        assumptions::Vector{ScenarioAssumption} = ScenarioAssumption[],
        interpretation_notes::AbstractString = "",
        in_sample::Bool = true,
        notes::AbstractString = "",
        special_factors::Vector{Symbol} = Symbol[],
        data_definition_break_resolved::Bool = true,
        expected_diagnostic_label::Symbol = :indeterminate,
    )
        id in CAPEX_CC_EPISODE_IDS || throw(
            ArgumentError(
                "未知の episode id :$(id)（許容: $(CAPEX_CC_EPISODE_IDS)）",
            ),
        )
        runup_quarters > 0 ||
            throw(ArgumentError("runup_quarters は正の整数でなければなりません"))
        eval_quarters > 0 ||
            throw(ArgumentError("eval_quarters は正の整数でなければなりません"))
        for f in special_factors
            f in CAPEX_CC_SPECIAL_FACTOR_KINDS || throw(
                ArgumentError(
                    "未知の special_factor :$(f)（許容: $(CAPEX_CC_SPECIAL_FACTOR_KINDS)）",
                ),
            )
        end
        expected_diagnostic_label in CAPEX_CC_EXPECTED_DIAGNOSTIC_LABELS || throw(
            ArgumentError(
                "未知の expected_diagnostic_label :$(expected_diagnostic_label)" *
                "（許容: $(CAPEX_CC_EXPECTED_DIAGNOSTIC_LABELS)）",
            ),
        )
        return new(
            id,
            String(label),
            period_zero,
            runup_quarters,
            eval_quarters,
            observed_events,
            assumptions,
            String(interpretation_notes),
            in_sample,
            String(notes),
            special_factors,
            data_definition_break_resolved,
            expected_diagnostic_label,
        )
    end
end

# ---------------------------------------------------------------------------
# CapexEpisodeAssessment（実証統合設計 §9.1）
# ---------------------------------------------------------------------------

"""
    CapexEpisodeAssessment

`assess_capex_episodes` が1 episode ごとに返す判定結果。
"""
struct CapexEpisodeAssessment
    id::Symbol
    status::Symbol
    nc_results::Dict{Symbol, Bool}
    nc_details::Dict{Symbol, String}
    missing_keys::Vector{Symbol}
    coverage_start::Union{String, Nothing}
    coverage_end::Union{String, Nothing}
    exclusion_reason::String
    episode_hash::String
    metadata::Dict{String, Any}
end

# ---------------------------------------------------------------------------
# 四半期インデックスのヘルパ
# ---------------------------------------------------------------------------

# ds.dates（"YYYY-Qn"）→ 絶対四半期インデックスの逆引き表。ds.dates は較正必須系列の inner
# join で決まるため、内部に欠落四半期を含みうる（#243 の契約。連続とは限らない）。
function _capex_hist_index_map(ds::CapexEmpiricalDataset)::Dict{Int, Int}
    return Dict{Int, Int}(_capex_quarter_index(d) => i for (i, d) in enumerate(ds.dates))
end

# [period_zero - runup, period_zero + eval - 1] の絶対四半期インデックス区間。
function _capex_hist_window_abs_indices(ep::CapexHistoricalEpisodeSpec)::Tuple{Int, Int}
    zero_abs = ep.period_zero.year * 4 + (ep.period_zero.quarter - 1)
    return zero_abs - ep.runup_quarters, zero_abs + ep.eval_quarters - 1
end

function _capex_hist_zero_abs(ep::CapexHistoricalEpisodeSpec)::Int
    return ep.period_zero.year * 4 + (ep.period_zero.quarter - 1)
end

# window内でdatasetに存在する最初・最後の日付ラベル（無ければ nothing, nothing）。
function _capex_hist_coverage_bounds(
    ds::CapexEmpiricalDataset,
    lo::Int,
    hi::Int,
    idxmap::Dict{Int, Int},
)::Tuple{Union{String, Nothing}, Union{String, Nothing}}
    present = sort([abs_idx for abs_idx in lo:hi if haskey(idxmap, abs_idx)])
    isempty(present) && return nothing, nothing
    return ds.dates[idxmap[first(present)]], ds.dates[idxmap[last(present)]]
end

# ---------------------------------------------------------------------------
# モデル変数レベルの観測値（catalog キー → model var への投影）。
#
# role でフィルタしない。これは #244 の `_capex_project_observations`（steady-state target
# 構築のための baseline mean 投影）と同じ規約であり、意図的である: catalog の `role`
# （calibration_required / estimation_input / validation_only）は「較正必須 inner join に
# 使うか」という #243 の軸であって、「この model var を観測できるか」という history 層の
# 問いとは別の軸である。EB-7 の `required_keys` である `:cons`・`:hh_income` は catalog 上
# `role=:validation_only`（両者が proxy でありモデルの `cons` は部門範囲が狭いため）だが、
# 観測可能性としては使える（実証戦略 §3.2-8）。role でここを絞ると EB-7 対象の2キーが常に
# 「欠損」と誤判定される。
function _capex_hist_mv_sources(
    ds::CapexEmpiricalDataset,
    mv::Symbol,
)::Vector{Tuple{Symbol, Symbol}}
    return sort(
        [
            (key, meas.spec.methodology) for
            (key, meas) in ds.measurements if mv in meas.spec.model_vars
        ];
        by = first,
    )
end

"""
四半期位置 `i` における mv の値。`_capex_project_observations`（#244）と同じ結合規約を
四半期ごとに適用する: 単一ソースはそのまま、複数ソースがすべて `:aggregation`
（methodology）なら和（例: `capex_exec_s1` の equipment/software/structures、`emp_s3` の
machinery/construction/utilities）、それ以外（例: `spread` の `spread_hy`/`spread_ig`）は
平均。allocation methodology の按分（`nfc_debt_total` 等）は本ファイルの対象変数に現れない
ため実装しない。いずれかのソースが欠損なら、その四半期の mv 値は missing（穴埋めしない）。
"""
function _capex_hist_mv_value(
    ds::CapexEmpiricalDataset,
    mv::Symbol,
    i::Int,
)::Union{Float64, Missing}
    srcs = _capex_hist_mv_sources(ds, mv)
    isempty(srcs) && return missing
    vals = Float64[]
    for (k, _) in srcs
        v = ds.values[k][i]
        (ismissing(v) || !isfinite(v)) && return missing
        push!(vals, v)
    end
    length(srcs) == 1 && return vals[1]
    methods = unique(m for (_, m) in srcs)
    all(m -> m === :aggregation, methods) && return sum(vals)
    return sum(vals) / length(vals)
end

# 単一 catalog キー（生キー）の window 全期非欠損チェック。NC-6 の ai_exp 代替仕様のように
# role を問わず（validation_only を含めて）特定の1系列の可用性だけを見たい場合に使う。
function _capex_hist_key_fully_available(
    ds::CapexEmpiricalDataset,
    key::Symbol,
    lo::Int,
    hi::Int,
    idxmap::Dict{Int, Int},
)::Bool
    haskey(ds.measurements, key) || return false
    haskey(ds.values, key) || return false
    for abs_idx in lo:hi
        pos = get(idxmap, abs_idx, nothing)
        pos === nothing && return false
        v = ds.values[key][pos]
        (ismissing(v) || !isfinite(v)) && return false
    end
    return true
end

# ---------------------------------------------------------------------------
# NC-1: 必須観測系列がすべて利用可能
# ---------------------------------------------------------------------------

function _capex_hist_nc1(
    ds::CapexEmpiricalDataset,
    ep::CapexHistoricalEpisodeSpec,
    idxmap::Dict{Int, Int},
)::Tuple{Bool, String, Vector{Symbol}}
    lo, hi = _capex_hist_window_abs_indices(ep)
    missing_mvs = Symbol[]
    for mv in CAPEX_CC_EPISODE_REQUIRED_MODEL_VARS
        srcs = _capex_hist_mv_sources(ds, mv)
        if isempty(srcs)
            push!(missing_mvs, mv)
            continue
        end
        ok = true
        for abs_idx in lo:hi
            pos = get(idxmap, abs_idx, nothing)
            if pos === nothing || ismissing(_capex_hist_mv_value(ds, mv, pos))
                ok = false
                break
            end
        end
        ok || push!(missing_mvs, mv)
    end
    passed = isempty(missing_mvs)
    detail = if passed
        "EB-1・EB-3・EB-6・EB-7 の必須系列が助走$(ep.runup_quarters)Q+評価$(ep.eval_quarters)Q" *
        "の全期間で非欠損（inner join、実証戦略 §9.1 NC-1）"
    else
        "系列が助走+評価期間の一部で欠損または未測定: " * join(string.(missing_mvs), ", ")
    end
    return passed, detail, missing_mvs
end

# ---------------------------------------------------------------------------
# NC-2: 需要・CAPEX・信用・雇用の時間順序を確認できる
# ---------------------------------------------------------------------------

function _capex_hist_nc2(
    ds::CapexEmpiricalDataset,
    ep::CapexHistoricalEpisodeSpec,
    idxmap::Dict{Int, Int};
    thresholds::CapexDiagnosticThresholds = CapexDiagnosticThresholds(),
)::Tuple{Bool, String}
    lo, hi = _capex_hist_window_abs_indices(ep)
    zero_abs = _capex_hist_zero_abs(ep)
    breaches = Symbol[]
    notes = String[]
    for mv in CAPEX_CC_NC2_SERIES
        base_vals = Float64[]
        for abs_idx in lo:(zero_abs - 1)
            pos = get(idxmap, abs_idx, nothing)
            pos === nothing && continue
            v = _capex_hist_mv_value(ds, mv, pos)
            ismissing(v) || push!(base_vals, v)
        end
        if isempty(base_vals)
            push!(notes, "$(mv): 助走期間のデータが無く判定不能")
            continue
        end
        x_base = sum(base_vals) / length(base_vals)
        if mv !== :spread && x_base == 0.0
            push!(notes, "$(mv): baseline=0 のため相対偏差を計算できない")
            continue
        end
        thr = getproperty(thresholds, CAPEX_CC_NC2_THRESHOLD_MAP[mv])
        worst::Union{Float64, Nothing} = nothing
        for abs_idx in zero_abs:hi
            pos = get(idxmap, abs_idx, nothing)
            pos === nothing && continue
            v = _capex_hist_mv_value(ds, mv, pos)
            ismissing(v) && continue
            dev = mv === :spread ? (v - x_base) * 100.0 : (v - x_base) / abs(x_base)
            if worst === nothing
                worst = dev
            elseif mv === :spread
                worst = max(worst, dev)
            else
                worst = min(worst, dev)
            end
        end
        if worst === nothing
            push!(notes, "$(mv): 評価期間のデータが無く判定不能")
            continue
        end
        breached = mv === :spread ? (worst >= thr) : (worst <= thr)
        breached && push!(breaches, mv)
        push!(
            notes,
            "$(mv): peak_dev=$(round(worst; digits = 4)) threshold=$(thr) breach=$(breached)",
        )
    end
    passed = length(breaches) == length(CAPEX_CC_NC2_SERIES)
    detail = if passed
        "4系列（order_s2・capex_exec_s1・spread・emp_tot）すべてが G1–G4 相当の深さ閾値を" *
        "超える変動を示す: " * join(notes, "; ")
    else
        "一部系列が深さ閾値を超える変動を示さない（悪化開始時点を識別できない）: " *
        join(notes, "; ")
    end
    return passed, detail
end

# ---------------------------------------------------------------------------
# NC-3: 単一の特殊要因だけで説明されない
# ---------------------------------------------------------------------------

function _capex_hist_nc3(ep::CapexHistoricalEpisodeSpec)::Tuple{Bool, String}
    n = length(ep.special_factors)
    passed = n <= 1
    detail = if n == 0
        "期間中に CAPEX_CC_SPECIAL_FACTOR_KINDS の特殊要因は記録されていない"
    elseif n == 1
        "特殊要因1件を記録: $(ep.special_factors[1])（単独要因として許容、実証戦略 §9.1 NC-3）"
    else
        "特殊要因が$(n)件同時に存在: " * join(string.(ep.special_factors), ", ") *
        "（NC-3 違反。実証戦略 §9.1 の「同時に2つ以上存在しない」条件を満たさない）"
    end
    return passed, detail
end

# ---------------------------------------------------------------------------
# NC-4: データ revision・定義変更を追跡できる
# ---------------------------------------------------------------------------

function _capex_hist_nc4(ep::CapexHistoricalEpisodeSpec)::Tuple{Bool, String}
    passed = ep.data_definition_break_resolved
    detail = if passed
        "期間内の系列定義変更（NAICS改訂・BEA産業分類変更・Census区分変更等）は無いか、" *
        "変更前後の接続方法が確認できる"
    else
        "系列定義変更の接続方法が確認できない（NC-4 違反）"
    end
    return passed, detail
end

# ---------------------------------------------------------------------------
# NC-5: baseline 期間と out-of-sample 期間を確保できる（データ可用性の機械判定）
# ---------------------------------------------------------------------------

"""
`runup_deviation`（助走期間がモデルの定常近傍にあるか）自体はモデル実行を要するため、
#247 の対象外（replay model execution）である `capex_run` を呼ばずには確認できない。
本関数は「助走8Q+評価20Qの窓がdatasetの利用可能期間に収まるか」というデータ可用性のみを
機械的に判定し、`runup_deviation` の確認は P-8（#248）の replay 実行時に別途行うことを
`nc_details` へ明記する（`Z-30`: `H6` のように評価末尾が最新データへ近い候補の除外理由を
実データに対して機械的に記録する）。
"""
function _capex_hist_nc5(
    ds::CapexEmpiricalDataset,
    ep::CapexHistoricalEpisodeSpec,
    idxmap::Dict{Int, Int},
)::Tuple{Bool, String}
    isempty(ds.dates) && return false, "dataset に四半期が1件も無い"
    lo, hi = _capex_hist_window_abs_indices(ep)
    all_abs = [_capex_quarter_index(d) for d in ds.dates]
    earliest_abs = minimum(all_abs)
    latest_abs = maximum(all_abs)
    tail_ok = hi <= latest_abs
    head_ok = lo >= earliest_abs
    passed = tail_ok && head_ok
    detail = if !tail_ok
        "評価区間の終端がdatasetの最新四半期を超えており、評価$(ep.eval_quarters)四半期・" *
        "out-of-sample 8四半期以上を確保できない（実データの利用可能期間に依存、`Z-30`）"
    elseif !head_ok
        "助走区間の起点がdatasetの最古四半期より前であり、助走$(ep.runup_quarters)四半期を" *
        "確保できない"
    else
        "助走・評価ウィンドウはdatasetの利用可能期間内に収まる（データ可用性のみの判定。" *
        "runup_deviation自体はP-8のreplay実行時に別途確認する）"
    end
    return passed, detail
end

# ---------------------------------------------------------------------------
# NC-6: ai_exp の代替構成が定義できる（3仕様のうち2つ以上、実証戦略 §8.2 ID-1 / W3）
# ---------------------------------------------------------------------------

function _capex_hist_nc6(
    ds::CapexEmpiricalDataset,
    ep::CapexHistoricalEpisodeSpec,
    idxmap::Dict{Int, Int},
)::Tuple{Bool, String}
    lo, hi = _capex_hist_window_abs_indices(ep)
    specs_ok = Symbol[:constant]  # (a) 定数=1 は常に構成可能（データ不要）
    # (b) compute_dem の観測変動から逆算: y_s1（データ処理/ホスティング部門の実質産出proxy）
    _capex_hist_key_fully_available(ds, :y_s1_proxy, lo, hi, idxmap) &&
        push!(specs_ok, :compute_dem_implied)
    # (c) セクター株価の変動
    _capex_hist_key_fully_available(ds, :equity_val_sector, lo, hi, idxmap) &&
        push!(specs_ok, :equity_price)
    passed = length(specs_ok) >= 2
    detail = "ai_exp 代替構成（実証戦略 §8.2 ID-1）: " * join(string.(specs_ok), ", ") *
        "（$(length(specs_ok))/3 構成可能。2以上でNC-6充足）"
    return passed, detail
end

# ---------------------------------------------------------------------------
# assess_capex_episodes
# ---------------------------------------------------------------------------

"""
    assess_capex_episodes(ds::CapexEmpiricalDataset;
                          specs = CAPEX_CC_EPISODE_SPECS,
                          thresholds = CapexDiagnosticThresholds()) -> Vector{CapexEpisodeAssessment}

`H1`–`H6`（既定）を `ds` に対して `NC-1`–`NC-7` で機械的に評価する。

- `NC-1`–`NC-6` は episode ごとに個別評価する。`NC-7`（集合レベル）は「`NC-1`–`NC-6` を
  すべて満たす episode の集合」の中で `broad_downturn` 想定 1件以上・`contained_adjustment`
  想定 1件以上を含むかどうかで判定し、**同一の値をすべての episode で共有する**
  （実証戦略 §9.2 契約1: 最小の組を選ぶ。fit を見て事後選択しない）。
- `status`: `NC-1`–`NC-7` すべてを満たせば `:selected`。`NC-1`/`NC-5`/`NC-6`
  （データ可用性が原因のもの）のいずれかで落ちれば `:insufficient_data`。`NC-2`/`NC-3`/`NC-4`
  （実質的な判断が原因のもの）または集合レベルの `NC-7` で落ちれば `:excluded`。
- 選定・除外の**両方**を `exclusion_reason` へ記録する（実証戦略 §9.2 契約1）。
"""
function assess_capex_episodes(
    ds::CapexEmpiricalDataset;
    specs::AbstractVector{CapexHistoricalEpisodeSpec} = CAPEX_CC_EPISODE_SPECS,
    thresholds::CapexDiagnosticThresholds = CapexDiagnosticThresholds(),
)::Vector{CapexEpisodeAssessment}
    idxmap = _capex_hist_index_map(ds)

    nc_by_id = Dict{Symbol, Dict{Symbol, Bool}}()
    detail_by_id = Dict{Symbol, Dict{Symbol, String}}()
    missing_by_id = Dict{Symbol, Vector{Symbol}}()

    for ep in specs
        nc1, d1, miss1 = _capex_hist_nc1(ds, ep, idxmap)
        nc2, d2 = _capex_hist_nc2(ds, ep, idxmap; thresholds = thresholds)
        nc3, d3 = _capex_hist_nc3(ep)
        nc4, d4 = _capex_hist_nc4(ep)
        nc5, d5 = _capex_hist_nc5(ds, ep, idxmap)
        nc6, d6 = _capex_hist_nc6(ds, ep, idxmap)
        nc_by_id[ep.id] = Dict(
            :NC1 => nc1,
            :NC2 => nc2,
            :NC3 => nc3,
            :NC4 => nc4,
            :NC5 => nc5,
            :NC6 => nc6,
        )
        detail_by_id[ep.id] = Dict(
            :NC1 => d1,
            :NC2 => d2,
            :NC3 => d3,
            :NC4 => d4,
            :NC5 => d5,
            :NC6 => d6,
        )
        missing_by_id[ep.id] = miss1
    end

    by_id = Dict(ep.id => ep for ep in specs)
    eligible =
        sort([id for id in keys(nc_by_id) if all(values(nc_by_id[id]))]; by = string)
    broad =
        [id for id in eligible if by_id[id].expected_diagnostic_label === :broad_downturn]
    contained = [
        id for id in eligible if
        by_id[id].expected_diagnostic_label === :contained_adjustment
    ]
    nc7_pass = !isempty(broad) && !isempty(contained)
    nc7_detail = if nc7_pass
        "NC-1–NC-6をすべて満たす候補集合（$(join(string.(eligible), ", "))）は " *
        "broad_downturn想定$(length(broad))件・contained_adjustment想定$(length(contained))件を" *
        "含み、集合レベルの識別力条件を満たす（実証戦略 §9.1 NC-7）"
    else
        "NC-1–NC-6をすべて満たす候補集合（$(isempty(eligible) ? "空集合" : join(string.(eligible), ", "))）は " *
        "broad_downturn想定$(length(broad))件・contained_adjustment想定$(length(contained))件であり、" *
        "両方を最低1件ずつ含む条件を満たさない（実証戦略 §9.1 NC-7。集合レベルの必要条件、" *
        "fitを見た事後選択で補わない）"
    end

    out = CapexEpisodeAssessment[]
    for ep in specs
        nc = copy(nc_by_id[ep.id])
        nc[:NC7] = nc7_pass
        detail = copy(detail_by_id[ep.id])
        detail[:NC7] = nc7_detail

        nc1_6_pass = all(nc[k] for k in (:NC1, :NC2, :NC3, :NC4, :NC5, :NC6))
        status = if nc1_6_pass && nc7_pass
            :selected
        elseif !nc[:NC1] || !nc[:NC5] || !nc[:NC6]
            :insufficient_data
        else
            :excluded
        end
        reason = status === :selected ? "" :
            join(["$(k): $(detail[k])" for k in CAPEX_CC_NC_IDS if !nc[k]], " / ")

        lo, hi = _capex_hist_window_abs_indices(ep)
        cov_start, cov_end = _capex_hist_coverage_bounds(ds, lo, hi, idxmap)
        ep_hash = _capex_episode_hash(ep, ds)

        push!(
            out,
            CapexEpisodeAssessment(
                ep.id,
                status,
                nc,
                detail,
                missing_by_id[ep.id],
                cov_start,
                cov_end,
                reason,
                ep_hash,
                Dict{String, Any}(
                    "replay_kind" => "revised_data_historical_replay",
                    "history_version" => CAPEX_CC_HISTORY_VERSION,
                    "eligible_set" => sort(String.(eligible)),
                    "dataset_hash" => get(ds.metadata, "dataset_hash", nothing),
                ),
            ),
        )
    end
    return out
end

# ---------------------------------------------------------------------------
# episode_hash（実証統合設計 §11.3。episode spec・L1/L3・window・dataset_hash から生成）
# ---------------------------------------------------------------------------

# ObservedEvent の hash 対象フィールド（provenance.generated_at・notes は volatile のため
# 除外。scenario_provenance.jl の `_scenario_assumption_hash_dict` と同じ設計）。
function _capex_hist_observed_event_hash_dict(e::ObservedEvent)::Dict{String, Any}
    return Dict{String, Any}(
        "event_id" => e.event_id,
        "event_type" => String(e.event_type),
        "schema_version" => e.schema_version,
        "announced_at" => _scenario_hash_encode(e.announced_at),
        "observed_at" => _scenario_hash_encode(e.observed_at),
        "known_at" => _scenario_hash_encode(e.known_at),
        "effective_from" => _scenario_hash_encode(e.effective_from),
        "effective_until" => _scenario_hash_encode(e.effective_until),
        "source" => Dict{String, Any}(
            "publisher" => e.source.publisher,
            "document_id" => e.source.document_id,
            "url" => e.source.url,
        ),
        "entity" => e.entity,
        "sector" => String(e.sector),
        "geography" => e.geography,
        "direction" => String(e.direction),
        "magnitude" => _scenario_hash_encode(e.magnitude),
        "unit" => e.unit,
        "supersedes" => e.supersedes,
        "provenance" => Dict{String, Any}(
            "layer" => String(e.provenance.layer),
            "derived_from" => sort(copy(e.provenance.derived_from)),
            "rule_id" => e.provenance.rule_id,
            "rule_version" => e.provenance.rule_version,
            "generator" => e.provenance.generator,
        ),
    )
end

"""
    _capex_episode_hash(ep, ds) -> String

episode spec の内容（`L1`/`L3`・window・特殊要因・データ定義断絶・想定ラベル）と
`ds.metadata["dataset_hash"]` から決定論的な `"sha256:…"` を生成する。同一 source/config
から同一 identity となる（#247 受け入れ条件）。`generated_at`・`notes`・`interpretation_notes`
等の表示専用フィールドは対象外とする。
"""
function _capex_episode_hash(
    ep::CapexHistoricalEpisodeSpec,
    ds::CapexEmpiricalDataset,
)::String
    payload = Dict{String, Any}(
        "history_version" => CAPEX_CC_HISTORY_VERSION,
        "id" => String(ep.id),
        "label" => ep.label,
        "period_zero" => Dict{String, Any}(
            "year" => ep.period_zero.year,
            "quarter" => ep.period_zero.quarter,
        ),
        "runup_quarters" => ep.runup_quarters,
        "eval_quarters" => ep.eval_quarters,
        "in_sample" => ep.in_sample,
        "special_factors" => sort(String.(ep.special_factors)),
        "data_definition_break_resolved" => ep.data_definition_break_resolved,
        "expected_diagnostic_label" => String(ep.expected_diagnostic_label),
        "observed_events" => [
            _capex_hist_observed_event_hash_dict(e) for
            e in sort(ep.observed_events; by = e -> e.event_id)
        ],
        "assumptions" => [
            _scenario_assumption_hash_dict(a) for
            a in sort(ep.assumptions; by = a -> a.assumption_id)
        ],
        "dataset_hash" => get(ds.metadata, "dataset_hash", nothing),
    )
    return _scenario_sha256(payload)
end

# ---------------------------------------------------------------------------
# シリアライズ（実証統合設計 §9.1「episode fixture を serialization/replay 可能な形にする」）
# ---------------------------------------------------------------------------

function _capex_hist_event_display_dict(e::ObservedEvent)::Dict{String, Any}
    d = _capex_hist_observed_event_hash_dict(e)
    d["notes"] = e.notes
    return d
end

function _capex_hist_assumption_display_dict(a::ScenarioAssumption)::Dict{String, Any}
    d = _scenario_assumption_hash_dict(a)
    d["notes"] = a.notes
    d["caveats"] = a.caveats
    d["confidence"] = a.confidence
    return d
end

"""
    capex_episode_spec_to_dict(ep::CapexHistoricalEpisodeSpec) -> Dict{String, Any}

`ep` を再現に必要な公開情報へ辞書化する。API キー・URL 以外のローカルパスは含まれない
（`EventSource.url` は一次資料の公開URLであり秘密情報ではない）。
"""
function capex_episode_spec_to_dict(ep::CapexHistoricalEpisodeSpec)::Dict{String, Any}
    return Dict{String, Any}(
        "history_version" => CAPEX_CC_HISTORY_VERSION,
        "id" => String(ep.id),
        "label" => ep.label,
        "period_zero" => Dict{String, Any}(
            "year" => ep.period_zero.year,
            "quarter" => ep.period_zero.quarter,
        ),
        "runup_quarters" => ep.runup_quarters,
        "eval_quarters" => ep.eval_quarters,
        "in_sample" => ep.in_sample,
        "notes" => ep.notes,
        "interpretation_notes" => ep.interpretation_notes,
        "special_factors" => String.(ep.special_factors),
        "data_definition_break_resolved" => ep.data_definition_break_resolved,
        "expected_diagnostic_label" => String(ep.expected_diagnostic_label),
        "observed_events" =>
            [_capex_hist_event_display_dict(e) for e in ep.observed_events],
        "assumptions" => [_capex_hist_assumption_display_dict(a) for a in ep.assumptions],
    )
end

"""
    capex_episode_assessment_to_dict(a::CapexEpisodeAssessment) -> Dict{String, Any}
"""
function capex_episode_assessment_to_dict(a::CapexEpisodeAssessment)::Dict{String, Any}
    return Dict{String, Any}(
        "id" => String(a.id),
        "status" => String(a.status),
        "nc_results" => Dict{String, Any}(String(k) => v for (k, v) in a.nc_results),
        "nc_details" => Dict{String, Any}(String(k) => v for (k, v) in a.nc_details),
        "missing_keys" => sort(String.(a.missing_keys)),
        "coverage_start" => a.coverage_start,
        "coverage_end" => a.coverage_end,
        "exclusion_reason" => a.exclusion_reason,
        "episode_hash" => a.episode_hash,
        "metadata" => a.metadata,
    )
end

"""
    save_capex_episode_assessment(path, a::CapexEpisodeAssessment) -> String

`capex_episode_assessment_to_dict(a)` を正準ではない整形 JSON として `path` へ書き出す
（表示・監査用。canonical identity は `episode_hash` が既に保持する）。
"""
function save_capex_episode_assessment(path::AbstractString, a::CapexEpisodeAssessment)
    open(path, "w") do io
        JSON3.pretty(io, capex_episode_assessment_to_dict(a))
    end
    return path
end

# ---------------------------------------------------------------------------
# CAPEX_CC_EPISODE_SPECS（`H1`–`H6`、実証戦略 §9.2 の表を機械可読へ落とす）
# ---------------------------------------------------------------------------

# 履歴記録の共通 rule_id（人手記録であることを明示。自動生成ルールではない）。
const _CAPEX_HIST_RULE_ID = "capex-credit-cycle-history/manual-record"

function _capex_hist_provenance(layer::Symbol; derived_from::Vector{String} = String[])
    return EventProvenance(;
        layer = layer,
        rule_id = _CAPEX_HIST_RULE_ID,
        rule_version = "1.0.0",
        generator = "human",
        derived_from = derived_from,
    )
end

# H1: 2000–2003（ドットコム後の IT・半導体設備調整）。
# NC-1: wage（EB-6 必須、catalog availability_start=2006-Q1）が助走区間（1998Q4起点）を
#   カバーできないため、実データに対しては機械的に不成立となる見込み（このファイルは
#   その結論を先取りしない。assess_capex_episodes が dataset に対して判定する）。
# NC-4: 採用系列（FRB 鉱工業生産指数 IPG3344S/IPG333S、BEA NAICS へアンカー）は provider が
#   現行 NAICS 分類で再基準化した連続系列であり、#241 の系列選定時点で NAICS 1997→2002 の
#   接続は確認済み（実証戦略 §9.2 の懸念は本カタログの系列選択により解消している）。
const _CAPEX_HIST_H1 = CapexHistoricalEpisodeSpec(;
    id = :H1,
    label = "2000–2003 ドットコム後のIT・半導体設備投資調整",
    period_zero = CalendarQuarter(2000, 4),
    observed_events = [
        ObservedEvent(;
            event_id = "H1-OE1",
            event_type = :DemandOutlookRevision,
            announced_at = Date(2001, 3, 1),
            observed_at = Date(2001, 3, 1),
            known_at = Date(2001, 3, 2),
            source = EventSource(;
                publisher = "NBER",
                document_id = "US Business Cycle Expansions and Contractions (peak 2001-03)",
                url = "https://www.nber.org/research/business-cycle-dating",
            ),
            provenance = _capex_hist_provenance(:observed),
            effective_from = Date(2000, 10, 1),
            sector = :s2,
            direction = :down,
            notes = "ITバブル崩壊後の半導体・情報処理設備投資の減速局面。NBER景気循環日付は" *
                "2001年3月を山、2001年11月を谷とする。",
        ),
    ],
    interpretation_notes = "2000年後半に始まったIT関連設備投資の急減速。半導体・通信機器の" *
        "過剰投資の反動という解釈が一般的（人手記録。自動生成しない）。",
    special_factors = Symbol[],
    data_definition_break_resolved = true,
    expected_diagnostic_label = :broad_downturn,
    notes = "実証戦略 §9.2 の懸念: NC-1（BEA GDP by Industry四半期系列の開始時期。" *
        "データセンター建設区分が存在しない）。NC-4はFRB IP指数の再基準化により解消と判断" *
        "（本ファイルの判断。上記コメント参照）。",
)

# H2: 2008Q3–2010（世界金融危機）。
const _CAPEX_HIST_H2 = CapexHistoricalEpisodeSpec(;
    id = :H2,
    label = "2008Q3–2010 世界金融危機",
    period_zero = CalendarQuarter(2008, 3),
    observed_events = [
        ObservedEvent(;
            event_id = "H2-OE1",
            event_type = :CreditSpreadShock,
            announced_at = Date(2008, 9, 15),
            observed_at = Date(2008, 9, 15),
            known_at = Date(2008, 9, 15),
            source = EventSource(;
                publisher = "NBER",
                document_id = "US Business Cycle Expansions and Contractions (peak 2007-12)",
                url = "https://www.nber.org/research/business-cycle-dating",
            ),
            provenance = _capex_hist_provenance(:observed),
            effective_from = Date(2008, 9, 15),
            sector = :unknown,
            direction = :up,
            notes = "Lehman Brothers破綻（2008年9月15日）を含む世界金融危機下の信用スプレッド" *
                "急拡大。NBER景気循環日付は2007年12月を山、2009年6月を谷とする。",
        ),
    ],
    interpretation_notes = "金融危機による信用収縮と実体経済の同時悪化。政策対応（大規模な" *
        "金融緩和・財政出動）が同時期に急転しており、NC-3の対象となる特殊要因が2件併存する" *
        "（人手記録。自動生成しない）。",
    special_factors = [:financial_crisis, :policy_regime_shift],
    data_definition_break_resolved = true,
    expected_diagnostic_label = :broad_downturn,
    notes = "実証戦略 §9.2 の懸念どおりNC-3が不成立（金融危機と急激な政策転換が同時に2件）。" *
        "ID-6の政策反応問題が最も強く出る候補。",
)

# H3: 2011–2012（半導体在庫調整）。
const _CAPEX_HIST_H3 = CapexHistoricalEpisodeSpec(;
    id = :H3,
    label = "2011–2012 半導体在庫調整",
    period_zero = CalendarQuarter(2011, 3),
    observed_events = [
        ObservedEvent(;
            event_id = "H3-OE1",
            event_type = :OrderCancellation,
            announced_at = Date(2011, 7, 1),
            observed_at = Date(2011, 7, 1),
            known_at = Date(2011, 7, 2),
            source = EventSource(;
                publisher = "Semiconductor Industry Association (SIA) / WSTS",
                document_id = "World Semiconductor Trade Statistics — 2011-2012 sales deceleration",
                url = "https://www.semiconductors.org",
            ),
            provenance = _capex_hist_provenance(:observed),
            effective_from = Date(2011, 7, 1),
            sector = :s2,
            direction = :down,
            notes = "2011年のタイ洪水によるサプライチェーン混乱と在庫調整が重なった半導体" *
                "販売の減速局面。",
        ),
    ],
    interpretation_notes = "在庫調整主導の比較的軽度な減速局面。悪化幅が小さく、悪化開始" *
        "時点の識別可否（NC-2）が実データで検証すべき論点（人手記録。自動生成しない）。",
    special_factors = Symbol[],
    data_definition_break_resolved = true,
    expected_diagnostic_label = :contained_adjustment,
    notes = "実証戦略 §9.2 の懸念: NC-2（変動が小さく悪化開始時点の識別が難しい可能性）。",
)

# H4: 2015–2016（半導体・エネルギー設備調整）。
const _CAPEX_HIST_H4 = CapexHistoricalEpisodeSpec(;
    id = :H4,
    label = "2015–2016 半導体・エネルギー設備投資調整",
    period_zero = CalendarQuarter(2015, 3),
    observed_events = [
        ObservedEvent(;
            event_id = "H4-OE1",
            event_type = :CapexGuidanceRevision,
            announced_at = Date(2014, 11, 27),
            observed_at = Date(2014, 11, 27),
            known_at = Date(2014, 11, 28),
            source = EventSource(;
                publisher = "U.S. Energy Information Administration (EIA)",
                document_id = "Cushing, OK WTI Spot Price — 2014H2-2016 decline",
                url = "https://www.eia.gov/petroleum/",
            ),
            provenance = _capex_hist_provenance(:observed),
            effective_from = Date(2014, 11, 27),
            sector = :s2,
            direction = :down,
            notes = "2014年11月のOPEC総会（減産見送り）を起点とする原油価格急落と、半導体" *
                "メモリ需要減速が重なった設備投資調整局面。",
        ),
    ],
    interpretation_notes = "エネルギー価格急落という半導体サイクルとは別系統の要因が同時期に" *
        "存在するが、NC-3が数える4種の特殊要因（金融危機・供給制約・財政金融政策の急転・" *
        "統計定義変更）のいずれにも該当しないため、NC-3の判定対象には含めない。ただし解釈上の" *
        "confound（交絡）として記録する（人手記録。自動生成しない）。",
    special_factors = Symbol[],
    data_definition_break_resolved = true,
    expected_diagnostic_label = :sectoral_downturn,
    notes = "実証戦略 §9.2 の懸念: エネルギー価格急落という別要因の併存。ただしNC-3の4種の" *
        "定義に厳密には該当しないため special_factors には含めない（本ファイルの判断）。",
)

# H5: 2018Q4–2019（米中貿易摩擦下の半導体調整）。
const _CAPEX_HIST_H5 = CapexHistoricalEpisodeSpec(;
    id = :H5,
    label = "2018Q4–2019 米中貿易摩擦下の半導体調整",
    period_zero = CalendarQuarter(2018, 4),
    observed_events = [
        ObservedEvent(;
            event_id = "H5-OE1",
            event_type = :OrderCancellation,
            announced_at = Date(2018, 9, 24),
            observed_at = Date(2018, 9, 24),
            known_at = Date(2018, 9, 24),
            source = EventSource(;
                publisher = "Office of the U.S. Trade Representative (USTR)",
                document_id = "Section 301 investigation of China's technology transfer, " *
                    "intellectual property, and innovation practices",
                url = "https://ustr.gov/issue-areas/enforcement/section-301-investigations/section-301-china-technology-transfer",
            ),
            provenance = _capex_hist_provenance(:observed),
            effective_from = Date(2018, 9, 24),
            sector = :s2,
            direction = :down,
            notes = "対中制裁関税第3弾（2018年9月24日発効、10%→2019年5月に25%へ引き上げ）に" *
                "伴う半導体受注調整局面。信用条件は比較的安定。",
        ),
    ],
    interpretation_notes = "通商政策という別要因が存在するが、NC-3の4種の定義には該当しない。" *
        "信用スプレッドが比較的安定しており、`credit-off`対照として有用（人手記録。自動生成" *
        "しない）。",
    special_factors = Symbol[],
    data_definition_break_resolved = true,
    expected_diagnostic_label = :contained_adjustment,
    notes = "実証戦略 §9.2 の懸念: 通商政策という別要因。ただしNC-3の4種の定義に厳密には" *
        "該当しないため special_factors には含めない（本ファイルの判断）。",
)

# H6: 2022Q3–2023（メモリ・PC需要調整 + 金融引締め）。
const _CAPEX_HIST_H6 = CapexHistoricalEpisodeSpec(;
    id = :H6,
    label = "2022Q3–2023 メモリ・PC需要調整と金融引締め",
    period_zero = CalendarQuarter(2022, 3),
    observed_events = [
        ObservedEvent(;
            event_id = "H6-OE1",
            event_type = :PolicyRateChange,
            announced_at = Date(2022, 6, 15),
            observed_at = Date(2022, 6, 15),
            known_at = Date(2022, 6, 15),
            source = EventSource(;
                publisher = "Federal Reserve (FOMC)",
                document_id = "FOMC statement — 2022-06-15 75bp increase in the target range",
                url = "https://www.federalreserve.gov/monetarypolicy/openmarket.htm",
            ),
            provenance = _capex_hist_provenance(:observed),
            effective_from = Date(2022, 6, 15),
            sector = :unknown,
            direction = :up,
            notes = "1994年以来となる75bp利上げ（2022年6月15日FOMC）を含む急速な政策金利" *
                "引き上げ局面。",
        ),
        ObservedEvent(;
            event_id = "H6-OE2",
            event_type = :DemandOutlookRevision,
            announced_at = Date(2022, 7, 1),
            observed_at = Date(2022, 7, 1),
            known_at = Date(2022, 7, 2),
            source = EventSource(;
                publisher = "Semiconductor Industry Association (SIA) / WSTS",
                document_id = "World Semiconductor Trade Statistics — 2022H2 memory price " *
                    "and demand decline",
                url = "https://www.semiconductors.org",
            ),
            provenance = _capex_hist_provenance(:observed),
            effective_from = Date(2022, 7, 1),
            sector = :s2,
            direction = :down,
            magnitude = missing,
            notes = "2022年後半のメモリ（DRAM/NAND）・PC需要減速局面。magnitudeは一次資料に" *
                "単一の数量として記載が無いため欠測のまま保持する（L1へ数値を書き戻さない、" *
                "`Z-20`）。",
        ),
    ],
    assumptions = [
        ScenarioAssumption(;
            assumption_id = "H6-SA1",
            event_type = :DemandOutlookRevision,
            sector = :s2,
            direction = :down,
            magnitude = -10.0,
            unit = "%",
            magnitude_source = :assumed_default,
            application_mode = :multiplicative,
            timing = EventTiming(;
                basis = :calendar,
                rule = :same_quarter,
                effective_from = Date(2022, 7, 1),
            ),
            persistence = PersistenceSpec(;
                shape = :step,
                duration = 4,
                params = NamedTuple(),
            ),
            target_concepts = [:demand_expectation],
            provenance = _capex_hist_provenance(:assumption; derived_from = ["H6-OE2"]),
            notes = "H6-OE2（メモリ・PC需要減速）はmagnitude非記載の観測事実。ここではNC判定・" *
                "記録用の例示的な仮定として-10%を置く（#247は replay を実行しないため、この値は" *
                "NC-1–NC-7のいずれの判定にも用いない）。",
            caveats = "この assumption を実際の履歴再生（外生パスへの適用）に使うかどうかはP-8" *
                "（#248）が別途決定する。本ファイルは capex_run を呼ばない。",
        ),
    ],
    interpretation_notes = "金融引締めとメモリ需要減速が同時進行。政策金利は実現値パスで" *
        "baseline外生へ直接与えるため（実証統合設計 §9.2 Z-18）、ここでのL3は需要側の補助的な" *
        "仮定に限る（人手記録。自動生成しない）。",
    special_factors = [:policy_regime_shift],
    data_definition_break_resolved = true,
    expected_diagnostic_label = :sectoral_downturn,
    notes = "実証戦略 §9.2 の懸念: 金融引締めとインフレが同時（インフレ自体はNC-3の4種に" *
        "該当しないため special_factors には金融政策の急転のみを記録する）。NC-5: 期間末が" *
        "最新データに近く評価20四半期を確保できない可能性（`Z-30`。実データに対して機械的に" *
        "判定する）。",
)

"""
    CAPEX_CC_EPISODE_SPECS

`CAPEX_CC_EPISODE_IDS`（`H1`–`H6`）と1:1対応する既定の episode 仕様集合
（実証戦略 §9.2 の表を機械可読へ落としたもの）。`assess_capex_episodes` の既定
`specs` 引数として使う。
"""
const CAPEX_CC_EPISODE_SPECS = CapexHistoricalEpisodeSpec[
    _CAPEX_HIST_H1,
    _CAPEX_HIST_H2,
    _CAPEX_HIST_H3,
    _CAPEX_HIST_H4,
    _CAPEX_HIST_H5,
    _CAPEX_HIST_H6,
]
