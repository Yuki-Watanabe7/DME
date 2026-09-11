# 部門別CAPEX・信用循環モデル（CCC）の履歴再生実行層（Issue #248 / `P-8`）。
#
# `CapexHistoricalEpisodeSpec`（P-7）と `CapexParameterSet`（P-6）を受け取り、
# 観測実現値から baseline 外生パスを構築し（`Z-19`: 助走は定常値固定、評価区間のみ実現値）、
# `map_event` → `schedule_events` → `capex_run` → 会計検証・診断 → `to_simulation_result`
# の順で1回だけ実行する（`Z-18`）。`run_scenario`（scenario_runner.jl）は変更・呼び出しの
# いずれも行わない。低レベル部品（`map_event`・`schedule_events`・`capex_run`・
# `validate_capex_accounting`・`capex_diagnostics`・`to_simulation_result`）を
# `run_scenario` と同じ順序で直接呼ぶ（`run_scenario` はモデル毎のイベント実行層であり、
# 履歴再生は実証層の別責務のため、内部で使う `Scenario` は L3 の運搬容器としてのみ用いる）。
#
# 本ファイルは `:literature_default` / `:calibrated` / `:estimated` の parameter set を
# 同一 episode・同一入力条件で「別 run」として実行できるようにする（実証統合設計 §9.4）。
# calibrated が literature/default より悪化したかどうかの判定・fit 指標そのものは
# P-9（#249）の責務であり、本ファイルは比較対象となる2本の run を作れることだけを担保する。
#
# Design: docs/architecture/capex_credit_cycle_empirical_integration.md §9.2–§9.4（`P-8` / #248・
#         `Z-18`・`Z-19`）・§6（失敗契約の3層分離）・§11（version・provenance・hash対象）・
#         docs/models/capex_credit_cycle_empirical_strategy.md §9.3（履歴再生のbaseline）・
#         §16.4（`ext_demand_s^{ss}` の識別仮定、`Z-12`）・ADR 0015 決定 7（`on_unmapped` の既定）。
#
# depends on: analysis/capex_credit_cycle_history.jl（`CapexHistoricalEpisodeSpec`・
# `_capex_hist_index_map`・`_capex_hist_window_abs_indices`・`_capex_hist_zero_abs`・
# `_capex_hist_mv_value`・`_capex_hist_mv_sources`・`_capex_episode_hash`）・
# analysis/capex_credit_cycle_estimation.jl（`CapexParameterSet`・`CAPEX_CC_PARAMETER_SET_KINDS`）・
# analysis/capex_credit_cycle_calibration.jl（`CapexEmpiricalCalibration`。`capex_replay_model`
# 内でのみ参照する）・models/capex_credit_cycle.jl（`CapexCreditCycleModel`・
# `capex_credit_cycle_model`・`_ccc_baseline_exog`・`capex_run`・`CapexCreditCycleRun`・
# `to_simulation_result`・`CAPEX_CC_EXOGENOUS_VARIABLES`）・
# core/solver_options.jl（`CapexCreditCycleOptions`）・
# analysis/capex_credit_cycle_accounting.jl（`validate_capex_accounting`・`AccountingCheckReport`・
# `accounting_passed`・`accounting_status_label`。すでに前段で include 済み）・
# analysis/capex_credit_cycle_diagnostics.jl（`capex_diagnostics`。すでに前段で include 済み）・
# core/simulation_result.jl（`SimulationResult`。すでに前段で include 済み）。
#
# `scenarios/adapters/capex_credit_cycle_event_adapter.jl`（`map_event`）と
# `scenarios/scenario_provenance.jl`（`event_set_hash`・`_scenario_sha256`・
# `_scenario_hash_encode`）は本ファイルより**後**に include される（DME.jl の順序）。
# Julia は関数本体の中の呼び出しを include 時ではなく呼び出し時に解決するため、これは
# `capex_credit_cycle_history.jl` が `scenario_provenance.jl` の関数を同じ理由で先に
# 参照できているのと同じ規約で問題ない（history.jl 冒頭コメント参照）。
# `scenarios/macro_events.jl`・`scenario_time.jl`・`scenario_types.jl`・`event_scheduler.jl`
# （`Scenario`・`TimingRuleSet`・`AppliedModelInput`・`EventRejection`・`schedule_events`・
# `EventSchedule`・`EventLogEntry`）は本ファイルより前に include 済み。

# ---------------------------------------------------------------------------
# 語彙定数
# ---------------------------------------------------------------------------

"本ファイルの契約 version。"
const CAPEX_CC_HISTORICAL_REPLAY_VERSION = "capex-credit-cycle-historical-replay/1.0.0"

"履歴再生1回の実行結果ステータス（実証統合設計 §6.2）。"
const CAPEX_CC_REPLAY_STATUSES =
    (:completed, :terminated, :accounting_failed, :rejected_input)

# ---------------------------------------------------------------------------
# CapexReplayOptions（実証統合設計 §9.2）
# ---------------------------------------------------------------------------

"""
    CapexReplayOptions

`capex_historical_replay` の実行オプション。

- `parameter_set_kind`: 実行に使う `ps.kind`（`CAPEX_CC_PARAMETER_SET_KINDS`）。`ps.kind` と
  一致しない場合は `ArgumentError`（呼び出し側の取り違えを構造的に防ぐ）。
- `exog_runup_mode`: 助走区間の外生の扱い。現状 `:steady_state_fixed` の1値のみ対応
  （`Z-19`。実データのトレンドを助走へ与えると `runup_deviation` が必ず発生するため）。
- `model_options`: `horizon_runup`/`horizon_eval` は episode の
  `runup_quarters`/`eval_quarters` と一致しなければならない（呼び出し側の契約違反として
  `ArgumentError`）。
- `validate_accounting` / `diagnostics`: 既定 `true`（実証統合設計 §9.2 契約3）。
- `on_unmapped`: `:reject`（既定）または `:warn`（ADR 0015 決定7の継承）。
"""
Base.@kwdef struct CapexReplayOptions
    parameter_set_kind::Symbol = :calibrated
    exog_runup_mode::Symbol = :steady_state_fixed
    model_options::CapexCreditCycleOptions = CapexCreditCycleOptions()
    validate_accounting::Bool = true
    diagnostics::Bool = true
    on_unmapped::Symbol = :reject
end

# ---------------------------------------------------------------------------
# capex_replay_model（parameter set の kind から実行可能なモデルを再構築する）
# ---------------------------------------------------------------------------

"""
    capex_replay_model(cal::CapexEmpiricalCalibration, ps::CapexParameterSet;
                        kind::Symbol = ps.kind) -> CapexCreditCycleModel

`kind` ごとの behavioral パラメータ（`ps.literature_default` のキー集合。`EST` 区分の
`bh_` パラメータに対応する。`_ccc_calibrate_behavioral` が定常水準から自由度なく決める
7パラメータ（`bh_util_tgt_s*`・`bh_backlog_target_s*`・`bh_inv_target_s*`）はここに含まれず、
`capex_credit_cycle_model` が毎回 `cal.targets` から再計算する）を選び、`cal.targets`・
`cal.structural_overrides`・`cal.model.sectors` はそのままに `capex_credit_cycle_model` を
再構築する（`capex_credit_cycle_model` の `structural` 引数の契約どおり、`st_` 系統の逆較正
閉形式は新しい `behavioral` の下で再計算した上で `cal.structural_overrides` を `merge` で
優先させる。これにより定常状態の整合性は `kind` によらず保たれる）。

- `:literature_default`: 文献既定値（`ps.literature_default`）をそのまま使う。
- `:calibrated`: `cal.model`（逆較正済み）の現在値（`ps.calibrated`）を使う。**`calibrate_capex_credit_cycle`
  は behavioral を明示的に上書きしないため、現状の実装では `EST` パラメータについて
  `:literature_default` と `:calibrated` が数値的に一致しうる**（`calibrate_capex_credit_cycle`
  が `capex_credit_cycle_model` を `behavioral` 省略で呼ぶため）。将来 `CAL-OBS` 分類の
  `bh_` パラメータが分岐しても正しく動くよう、この一般形（`get(ps.calibrated, p,
  ps.literature_default[p])`）で実装する。
- `:estimated`: `:calibrated` の値を `ps.estimated`（推定済みパラメータのみ）で上書きする。
"""
function capex_replay_model(
    cal::CapexEmpiricalCalibration,
    ps::CapexParameterSet;
    kind::Symbol = ps.kind,
)::CapexCreditCycleModel
    kind in CAPEX_CC_PARAMETER_SET_KINDS ||
        throw(ArgumentError("kind は $(CAPEX_CC_PARAMETER_SET_KINDS) のいずれかです"))

    behavioral_keys = collect(keys(ps.literature_default))
    base = Dict{Symbol, Float64}(
        p => Float64(get(ps.calibrated, p, ps.literature_default[p])) for
        p in behavioral_keys
    )
    vals = if kind === :literature_default
        ps.literature_default
    elseif kind === :calibrated
        base
    else # :estimated
        merge(base, ps.estimated)
    end

    ks = collect(keys(vals))
    behavioral = NamedTuple{Tuple(ks)}(Tuple(Float64(vals[k]) for k in ks))

    return capex_credit_cycle_model(
        cal.targets;
        behavioral = behavioral,
        structural = cal.structural_overrides,
        sectors = cal.model.sectors,
    )
end

# ---------------------------------------------------------------------------
# baseline 外生パスの構築（実証統合設計 §9.2 実行手順1、`Z-19`）
# ---------------------------------------------------------------------------

# `y_s5` の四半期実現値。#241–#243 時点の catalog に `y_s5` 単独の系列は無く（`y_s5^{ss}` は
# 較正層が baseline 窓平均から `y_tot - (va_s1+va_s2+va_s3)` として1回だけ導出する、
# calibration.jl 参照）、これを四半期ごとに一般化したもの。較正層と同一の恒等式を使う
# （実装上の判断。#170 §3.2-5 の恒等式をそのまま四半期粒度へ適用するだけであり、新しい
# 識別仮定を導入しない）。
function _capex_replay_y_s5_value(
    ds::CapexEmpiricalDataset,
    pos::Int,
)::Union{Float64, Missing}
    ytot = _capex_hist_mv_value(ds, :y_tot, pos)
    va1 = _capex_hist_mv_value(ds, :va_s1, pos)
    va2 = _capex_hist_mv_value(ds, :va_s2, pos)
    va3 = _capex_hist_mv_value(ds, :va_s3, pos)
    (ismissing(ytot) || ismissing(va1) || ismissing(va2) || ismissing(va3)) &&
        return missing
    return ytot - va1 - va2 - va3
end

const _CAPEX_REPLAY_PRICE_S1_WARNING =
    "price_s1（AI・クラウドサービス価格相当の外生変数）は #241 時点の系列 catalog に" *
    "登録が無く（CAPEX_CC_PROVIDER_GAPS にも未登録）、実現値パスを構成できない。" *
    "捏造を避けるため助走・評価の全期間で定常値に固定する（実装, P-8 / #248 の逸脱事項。" *
    "docs/architecture/capex_credit_cycle_empirical_integration.md §9.2 実装ノート参照）。"

"""
    _capex_replay_baseline_exog(m, ds, ep) -> (baseline, missing_detail, warnings)

観測実現値から baseline 外生パス（`Dict{Symbol,Vector{Float64}}`、長さ
`ep.runup_quarters+ep.eval_quarters`）を構築する。助走区間は常に定常値（`_ccc_baseline_exog`
そのまま）。評価区間は `policy_rate`・`ext_demand_s2`・`ext_demand_s3` を実現値で上書きする。
`price_s1`・`ai_exp`・`capex_plan_shock_ex`・`spread_shock_ex` は全期間定常値のまま
（前者は catalog 不在、後3者は `A` 分類で観測に対応が無い）。

`ext_demand_s2`/`ext_demand_s3` は `_capex_build_ext_demand!`（calibration.jl）と同一の
識別仮定（`Z-12`）を四半期ごとに適用する: `gen_share_s = mean(order_s over full sample) /
m.targets.values.y_s5`（`m.targets.values.y_s5` は `cal.targets.values.y_s5` そのもの。
標本全体平均は `_capex_full_sample_mean` を再利用）。

必要な入力（`policy_rate`・`y_s2`/`y_s3`・`order_cap_s2`/`order_cap_s3`・`order_inv_s3`・
`y_s5`（`_capex_replay_y_s5_value` 経由）・`gen_share_s`）のいずれかが評価区間の1四半期でも
欠損の場合、`baseline = nothing` を返す（呼び出し側は `:rejected_input` とする。fail closed）。
"""
function _capex_replay_baseline_exog(
    m::CapexCreditCycleModel,
    ds::CapexEmpiricalDataset,
    ep::CapexHistoricalEpisodeSpec,
)
    n = ep.runup_quarters + ep.eval_quarters
    baseline = _ccc_baseline_exog(m, n)
    lo, hi = _capex_hist_window_abs_indices(ep)
    zero_abs = _capex_hist_zero_abs(ep)
    idxmap = _capex_hist_index_map(ds)

    warnings = String[_CAPEX_REPLAY_PRICE_S1_WARNING]
    missing_detail = String[]

    y5_ss = m.targets.values.y_s5
    gen_share = Dict{Symbol, Union{Float64, Missing}}()
    for (s, order_key) in ((:s2, :order_s2), (:s3, :order_s3))
        gen_obs = _capex_full_sample_mean(ds, order_key)
        if ismissing(gen_obs)
            push!(
                missing_detail,
                "$(order_key) の標本全体平均が計算できません（gen_share_$(s) を構成できず、" *
                "ext_demand_$(s) を再構成できません、`Z-12`）",
            )
            gen_share[s] = missing
        elseif y5_ss == 0.0
            push!(
                missing_detail,
                "m.targets.values.y_s5 が0のため gen_share_$(s) を計算できません",
            )
            gen_share[s] = missing
        else
            gen_share[s] = gen_obs / y5_ss
        end
    end

    for t_abs in zero_abs:hi
        idx = t_abs - lo + 1
        pos = get(idxmap, t_abs, nothing)
        if pos === nothing
            push!(
                missing_detail,
                "abs=$(t_abs)（評価区間内）が dataset に存在しません（policy_rate/" *
                "ext_demand の再構成に必要）",
            )
            continue
        end

        pr = _capex_hist_mv_value(ds, :policy_rate, pos)
        if ismissing(pr)
            push!(missing_detail, "policy_rate が abs=$(t_abs) で欠損です")
        else
            baseline[:policy_rate][idx] = pr
        end

        for (s, tgt) in ((:s2, :ext_demand_s2), (:s3, :ext_demand_s3))
            y_key = Symbol("y_$s")
            cap_key = Symbol("order_cap_$s")
            yv = _capex_hist_mv_value(ds, y_key, pos)
            capv = _capex_hist_mv_value(ds, cap_key, pos)
            y5t = _capex_replay_y_s5_value(ds, pos)
            gs = gen_share[s]
            extra = 0.0
            extra_ok = true
            if s === :s3
                iv = _capex_hist_mv_value(ds, :order_inv_s3, pos)
                if ismissing(iv)
                    extra_ok = false
                else
                    extra = iv
                end
            end
            if ismissing(yv) ||
               ismissing(capv) ||
               ismissing(y5t) ||
               ismissing(gs) ||
               !extra_ok
                push!(
                    missing_detail,
                    "$(tgt) の再構成に必要な系列（$(y_key)/$(cap_key)/y_s5" *
                    (s === :s3 ? "/order_inv_s3" : "") *
                    "/gen_share_$(s)）が abs=$(t_abs) で欠損です",
                )
                continue
            end
            ext = yv - capv - gs * y5t
            s === :s3 && (ext -= extra)
            baseline[tgt][idx] = ext
        end
    end

    isempty(missing_detail) || return nothing, missing_detail, warnings
    return baseline, missing_detail, warnings
end

# ---------------------------------------------------------------------------
# 観測比較系列（P-9 の入力。適用可否・fit はここでは判定しない）
# ---------------------------------------------------------------------------

"""
    _capex_replay_observed_series(ds, ep) -> Dict{Symbol,Vector{Union{Float64,Missing}}}

`ds.measurements` が持つ全 model var について、episode の助走+評価ウィンドウ（`periods` と
同じ時間軸、長さ `ep.runup_quarters+ep.eval_quarters`、`index 1 ↔ t=-runup`）へ整列した
観測値を返す。適用可否（`:not_applicable_latent` 等）・fit 指標は判定しない（P-9 / #249 の
責務）。
"""
function _capex_replay_observed_series(
    ds::CapexEmpiricalDataset,
    ep::CapexHistoricalEpisodeSpec,
)::Dict{Symbol, Vector{Union{Float64, Missing}}}
    lo, hi = _capex_hist_window_abs_indices(ep)
    idxmap = _capex_hist_index_map(ds)
    n = ep.runup_quarters + ep.eval_quarters

    mvs = Set{Symbol}()
    for meas in values(ds.measurements)
        for mv in meas.spec.model_vars
            push!(mvs, mv)
        end
    end

    out = Dict{Symbol, Vector{Union{Float64, Missing}}}()
    for mv in mvs
        series = Vector{Union{Float64, Missing}}(missing, n)
        for t_abs in lo:hi
            pos = get(idxmap, t_abs, nothing)
            pos === nothing && continue
            series[t_abs - lo + 1] = _capex_hist_mv_value(ds, mv, pos)
        end
        out[mv] = series
    end
    return out
end

# ---------------------------------------------------------------------------
# CapexHistoricalReplayRun（実証統合設計 §9.2）
# ---------------------------------------------------------------------------

"""
    CapexHistoricalReplayRun

`capex_historical_replay` の戻り値。

`status === :rejected_input` のとき（fail closed）、`exog`・`model_run`・`result` はすべて
`nothing` である（実証統合設計 §9.2 のスケッチにはこの3フィールドの `Nothing` 許容が
明示されていないが、ADR 0015 / `run_scenario` と同じ fail-closed 規律を継承するために
必要な、非破壊のフィールド型拡張である）。`event_log`・`applied_inputs`・`rejections` は
そこまでに得られたものを保持する（`run_scenario`/`ScenarioRun` と同じ規約）。
"""
struct CapexHistoricalReplayRun
    status::Symbol
    episode::CapexHistoricalEpisodeSpec
    parameter_set::CapexParameterSet
    model::CapexCreditCycleModel
    exog::Union{Dict{Symbol, Vector{Float64}}, Nothing}
    event_log::Vector{EventLogEntry}
    applied_inputs::Vector{AppliedModelInput}
    rejections::Vector{EventRejection}
    model_run::Union{CapexCreditCycleRun, Nothing}
    result::Union{SimulationResult, Nothing}
    observed::Dict{Symbol, Vector{Union{Float64, Missing}}}
    in_sample::Bool
    dataset_hash::String
    parameter_set_hash::String
    episode_hash::String
    event_set_hash::String
    replay_hash::String
    warnings::Vector{String}
    metadata::Dict{String, Any}
end

# ---------------------------------------------------------------------------
# replay_hash（実証統合設計 §11.3）
# ---------------------------------------------------------------------------

function _capex_replay_options_payload(options::CapexReplayOptions)::Dict{String, Any}
    mo = options.model_options
    return Dict{String, Any}(
        "parameter_set_kind" => String(options.parameter_set_kind),
        "exog_runup_mode" => String(options.exog_runup_mode),
        "validate_accounting" => options.validate_accounting,
        "diagnostics" => options.diagnostics,
        "on_unmapped" => String(options.on_unmapped),
        "model_options" => Dict{String, Any}(
            "horizon_runup" => mo.horizon_runup,
            "horizon_eval" => mo.horizon_eval,
            "div_eps" => mo.div_eps,
            "guard_max" => mo.guard_max,
            "runup_tol" => mo.runup_tol,
            "stop_on_sign_violation" => mo.stop_on_sign_violation,
        ),
    )
end

# `parameter_set_hash` + `episode_hash` + `event_set_hash` + 外生パス + `CapexReplayOptions`
# の canonical hash（実証統合設計 §11.3）。警告は正規化（sort+unique）した上で対象に含める
# （§11.3 の「除外しない」規定）。`exog === nothing`（`:rejected_input`）でも計算できる。
function _capex_replay_hash(
    ps::CapexParameterSet,
    episode_hash::AbstractString,
    event_set_hash_val::AbstractString,
    exog::Union{Dict{Symbol, Vector{Float64}}, Nothing},
    options::CapexReplayOptions,
    warnings::Vector{String},
)::String
    payload = Dict{String, Any}(
        "replay_version" => CAPEX_CC_HISTORICAL_REPLAY_VERSION,
        "parameter_set_hash" => ps.parameter_set_hash,
        "episode_hash" => String(episode_hash),
        "event_set_hash" => String(event_set_hash_val),
        "exog" => exog === nothing ? nothing : _scenario_hash_encode(exog),
        "options" => _capex_replay_options_payload(options),
        "warnings" => sort(unique(warnings)),
    )
    return _scenario_sha256(payload)
end

function _capex_replay_base_metadata(
    ep::CapexHistoricalEpisodeSpec,
    ps::CapexParameterSet,
    options::CapexReplayOptions,
)::Dict{String, Any}
    return Dict{String, Any}(
        "replay_version" => CAPEX_CC_HISTORICAL_REPLAY_VERSION,
        "exog_runup_mode" => String(options.exog_runup_mode),
        "parameter_set_kind" => String(ps.kind),
        "in_sample" => ep.in_sample,
        "replay_kind" => "revised_data_historical_replay",
        "price_s1_realized_path" => "unavailable_no_catalog_entry",
    )
end

# ---------------------------------------------------------------------------
# capex_historical_replay（実証統合設計 §9.2、固定手順3段）
# ---------------------------------------------------------------------------

"""
    capex_historical_replay(m, ep, ds, ps; options = CapexReplayOptions()) -> CapexHistoricalReplayRun

`m`（`capex_replay_model` 等で呼び出し側が構築済みのモデル）を episode `ep` の助走+評価
ウィンドウで1回実行する。固定手順:

1. baseline 外生パスの構築（`_capex_replay_baseline_exog`。`Z-19`）。
2. `ep.assumptions`（L3）を `map_event` で L4 へ変換し、`schedule_events` で合成する
   （`run_scenario` と同じ手順を直接呼ぶ。`run_scenario` 自体は呼ばない）。
3. `capex_run` → 会計検証（既定 `true`）→ 診断（既定 `true`）→ `to_simulation_result`。

失敗契約（実証統合設計 §6.1）: 呼び出し側の契約違反（`options` の不整合・`ps.dataset_hash`
不一致）は `ArgumentError`。データ側の事情（欠損・event mapping/scheduling 拒否）は
`status = :rejected_input` の構造化拒否（fail closed。`exog`/`model_run`/`result` が
`nothing`）。`capex_run` の打ち切り・会計不合格は `status` で表現し例外にしない。
"""
function capex_historical_replay(
    m::CapexCreditCycleModel,
    ep::CapexHistoricalEpisodeSpec,
    ds::CapexEmpiricalDataset,
    ps::CapexParameterSet;
    options::CapexReplayOptions = CapexReplayOptions(),
)::CapexHistoricalReplayRun
    # --- 契約検査（例外。実証統合設計 §6.1 層(1)） ---
    ps.kind === options.parameter_set_kind || throw(
        ArgumentError(
            "options.parameter_set_kind=$(options.parameter_set_kind) が " *
            "ps.kind=$(ps.kind) と一致しません",
        ),
    )
    options.on_unmapped in (:reject, :warn) || throw(
        ArgumentError(
            "options.on_unmapped=$(options.on_unmapped) は :reject/:warn のいずれかで" *
            "なければなりません（ADR 0015 決定7）",
        ),
    )
    options.exog_runup_mode === :steady_state_fixed || throw(
        ArgumentError(
            "options.exog_runup_mode=$(options.exog_runup_mode) は現状 :steady_state_fixed " *
            "のみ対応します（`Z-19`）",
        ),
    )
    mo = options.model_options
    (mo.horizon_runup == ep.runup_quarters && mo.horizon_eval == ep.eval_quarters) || throw(
        ArgumentError(
            "options.model_options の horizon_runup/horizon_eval=" *
            "($(mo.horizon_runup),$(mo.horizon_eval)) が episode の " *
            "runup_quarters/eval_quarters=($(ep.runup_quarters),$(ep.eval_quarters)) と" *
            "一致しません",
        ),
    )
    ds_hash = get(ds.metadata, "dataset_hash", "")
    ps.dataset_hash == ds_hash || throw(
        ArgumentError(
            "ps.dataset_hash が ds の dataset_hash と一致しません（別 dataset から構築された " *
            "parameter set です）",
        ),
    )

    # `Scenario` は `map_event`/`schedule_events`/`event_set_hash` を再利用するための運搬
    # 容器としてのみ用いる（`run_scenario` は呼ばない）。
    sc = Scenario(;
        id = ep.id,
        model = model_symbol(m),
        name = ep.label,
        period_zero = ep.period_zero,
        horizon_runup = ep.runup_quarters,
        horizon_eval = ep.eval_quarters,
        assumptions = ep.assumptions,
        timing_rules = TimingRuleSet(),
    )
    periods = collect((-ep.runup_quarters):(ep.eval_quarters - 1))

    episode_hash = _capex_episode_hash(ep, ds)
    event_set_hash_val = event_set_hash(sc)
    dataset_hash = ps.dataset_hash
    parameter_set_hash = ps.parameter_set_hash

    observed = _capex_replay_observed_series(ds, ep)

    # --- 手順1: baseline 外生パス ---
    baseline, missing_detail, baseline_warnings = _capex_replay_baseline_exog(m, ds, ep)

    if baseline === nothing
        warnings = vcat(baseline_warnings, missing_detail)
        replay_hash = _capex_replay_hash(
            ps,
            episode_hash,
            event_set_hash_val,
            nothing,
            options,
            warnings,
        )
        metadata = _capex_replay_base_metadata(ep, ps, options)
        metadata["rejected_stage"] = "baseline_exog"
        return CapexHistoricalReplayRun(
            :rejected_input,
            ep,
            ps,
            m,
            nothing,
            EventLogEntry[],
            AppliedModelInput[],
            EventRejection[],
            nothing,
            nothing,
            observed,
            ep.in_sample,
            dataset_hash,
            parameter_set_hash,
            episode_hash,
            event_set_hash_val,
            replay_hash,
            warnings,
            metadata,
        )
    end

    # --- 手順2a: map_event（L3 → L4）。`_scenario_map_assumptions`（scenario_runner.jl）と
    #     同じ規約を直接実装する（`Scenario`/`ScenarioRunOptions` 専用の私的関数を再利用
    #     しない）。 ---
    inputs = AppliedModelInput[]
    rejections = EventRejection[]
    map_warnings = String[]
    for a in ep.assumptions
        mapped = map_event(
            m,
            a;
            periods = periods,
            baseline = baseline,
            timing_rules = TimingRuleSet(),
            period_zero = ep.period_zero,
        )
        if mapped isa EventRejection
            if mapped.code === :unmapped_target && options.on_unmapped === :warn
                push!(map_warnings, "unmapped_target_accepted: $(mapped.detail)")
            else
                push!(rejections, mapped)
            end
        else
            push!(inputs, mapped)
        end
    end

    if !isempty(rejections)
        warnings = vcat(baseline_warnings, map_warnings)
        replay_hash = _capex_replay_hash(
            ps,
            episode_hash,
            event_set_hash_val,
            baseline,
            options,
            warnings,
        )
        metadata = _capex_replay_base_metadata(ep, ps, options)
        metadata["rejected_stage"] = "map_event"
        return CapexHistoricalReplayRun(
            :rejected_input,
            ep,
            ps,
            m,
            baseline,
            EventLogEntry[],
            inputs,
            rejections,
            nothing,
            nothing,
            observed,
            ep.in_sample,
            dataset_hash,
            parameter_set_hash,
            episode_hash,
            event_set_hash_val,
            replay_hash,
            warnings,
            metadata,
        )
    end

    # --- 手順2b: schedule_events（全順序・固定順合成） ---
    schedule = schedule_events(inputs, sc, baseline)

    if !isempty(schedule.rejections)
        warnings = vcat(
            baseline_warnings,
            map_warnings,
            ["$(w.code): $(w.detail)" for w in schedule.warnings],
        )
        replay_hash = _capex_replay_hash(
            ps,
            episode_hash,
            event_set_hash_val,
            baseline,
            options,
            warnings,
        )
        metadata = _capex_replay_base_metadata(ep, ps, options)
        metadata["rejected_stage"] = "schedule_events"
        return CapexHistoricalReplayRun(
            :rejected_input,
            ep,
            ps,
            m,
            baseline,
            schedule.log,
            inputs,
            schedule.rejections,
            nothing,
            nothing,
            observed,
            ep.in_sample,
            dataset_hash,
            parameter_set_hash,
            episode_hash,
            event_set_hash_val,
            replay_hash,
            warnings,
            metadata,
        )
    end

    # --- 手順3: capex_run → 会計検証 → 診断 → to_simulation_result ---
    model_run = capex_run(
        m;
        scenario = ep.id,
        exog = schedule.paths,
        options = options.model_options,
        validate_accounting = false,
        diagnostics = false,
    )

    accounting =
        options.validate_accounting ? validate_capex_accounting(m, model_run) : nothing

    # `capex_diagnostics` の `delayed_containment` 判定（Phase 1 / #183）は
    # `contained_adjustment` ラベルのときに限り `capex_scenario(run.scenario)`（`Sc0`–`Sc4`
    # の凡例のみを持つ）を内部で呼ぶ。episode id（`:H1` 等）は `Sc0`–`Sc4` の集合に属さない
    # ため、この経路が `ArgumentError` を投げうる（`run_scenario` と同じ Phase 1 由来の
    # 既存の制約であり、`capex_credit_cycle_diagnostics.jl` 側の限界。本 Issue の対象では
    # ない）。`capex_historical_replay` も例外を投げない契約を守るため、この特定の失敗のみを
    # 捕捉し `diagnostics = nothing` に落とす。
    diagnostics = if options.diagnostics
        try
            capex_diagnostics(m, model_run; accounting = accounting)
        catch e
            e isa ArgumentError || rethrow()
            nothing
        end
    else
        nothing
    end

    status = if model_run.termination_reason !== :completed
        :terminated
    elseif accounting !== nothing && !accounting_passed(accounting)
        :accounting_failed
    else
        :completed
    end

    result = to_simulation_result(m, model_run, String(ep.id))

    warnings = vcat(
        baseline_warnings,
        map_warnings,
        ["$(w.code): $(w.detail)" for w in schedule.warnings],
    )

    metadata = _capex_replay_base_metadata(ep, ps, options)
    metadata["termination_reason"] = String(model_run.termination_reason)
    metadata["accounting_status"] =
        accounting === nothing ? nothing : accounting_status_label(accounting.status)
    metadata["diagnostics_available"] = diagnostics !== nothing

    replay_hash = _capex_replay_hash(
        ps,
        episode_hash,
        event_set_hash_val,
        schedule.paths,
        options,
        warnings,
    )

    return CapexHistoricalReplayRun(
        status,
        ep,
        ps,
        m,
        schedule.paths,
        schedule.log,
        inputs,
        EventRejection[],
        model_run,
        result,
        observed,
        ep.in_sample,
        dataset_hash,
        parameter_set_hash,
        episode_hash,
        event_set_hash_val,
        replay_hash,
        warnings,
        metadata,
    )
end

# ---------------------------------------------------------------------------
# シリアライズ（他の実証層 *_to_dict/save_* と同じ規約）
# ---------------------------------------------------------------------------

_capex_replay_json_num(::Missing) = nothing
_capex_replay_json_num(::Nothing) = nothing
_capex_replay_json_num(x::Real) = isfinite(x) ? Float64(x) : nothing

function _capex_replay_event_log_dict(e::EventLogEntry)::Dict{String, Any}
    return Dict{String, Any}(
        "input_id" => e.input_id,
        "assumption_id" => e.assumption_id,
        "target_variable" => String(e.target_variable),
        "t_apply" => e.t_apply,
        "application_mode" => String(e.application_mode),
        "magnitude" => _capex_replay_json_num(e.magnitude),
        "shape" => String(e.shape),
        "duration" => e.duration,
    )
end

"""
    capex_historical_replay_run_to_dict(run::CapexHistoricalReplayRun) -> Dict{String, Any}

再現に必要な公開情報を辞書化する。`ds`（生 dataset）は含めず、`dataset_hash` 等の hash
チェーンのみを参照する。非有限値（`NaN`/`Inf`）は JSON `null` として保存する
（`0` 化しない。実証統合設計 §11.4）。
"""
function capex_historical_replay_run_to_dict(
    run::CapexHistoricalReplayRun,
)::Dict{String, Any}
    series_dict = if run.model_run === nothing
        Dict{String, Any}()
    else
        Dict{String, Any}(
            String(k) => [_capex_replay_json_num(v) for v in vec] for
            (k, vec) in pairs(run.model_run.series)
        )
    end
    observed_dict = Dict{String, Any}(
        String(k) => [_capex_replay_json_num(v) for v in vec] for (k, vec) in run.observed
    )
    return Dict{String, Any}(
        "replay_version" => CAPEX_CC_HISTORICAL_REPLAY_VERSION,
        "status" => String(run.status),
        "episode_id" => String(run.episode.id),
        "parameter_set_kind" => String(run.parameter_set.kind),
        "in_sample" => run.in_sample,
        "dataset_hash" => run.dataset_hash,
        "parameter_set_hash" => run.parameter_set_hash,
        "episode_hash" => run.episode_hash,
        "event_set_hash" => run.event_set_hash,
        "replay_hash" => run.replay_hash,
        "termination_reason" =>
            run.model_run === nothing ? nothing : String(run.model_run.termination_reason),
        "series" => series_dict,
        "observed" => observed_dict,
        "event_log" => [_capex_replay_event_log_dict(e) for e in run.event_log],
        "warnings" => run.warnings,
        "metadata" => run.metadata,
    )
end

"""
    save_capex_historical_replay_run(path, run::CapexHistoricalReplayRun) -> path

`capex_historical_replay_run_to_dict(run)` を整形 JSON として `path` へ書き出す
（表示・監査用。canonical identity は `replay_hash` が既に保持する）。
"""
function save_capex_historical_replay_run(
    path::AbstractString,
    run::CapexHistoricalReplayRun,
)
    open(path, "w") do io
        JSON3.pretty(io, capex_historical_replay_run_to_dict(run))
    end
    return path
end
