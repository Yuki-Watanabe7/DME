# capex_credit_cycle_visualization.jl: 部門別CAPEX・信用循環モデル（`CapexCreditCycleModel`）専用の
# 可視化専用レイヤー（Issue #185 / `I-7`）。
#
# `src/core/visualization.jl`（`plot_result`/`plot_comparison`/`plot_irf`）・
# `src/analysis/minsky_visualization.jl`（`plot_financing_regimes` 等）・
# `src/analysis/keen_empirical_visualization.jl` と同じ Plots.jl ベースのパターンに従う読み取り
# 専用レイヤーである。`SimulationResult`（`to_simulation_result`、`I-6`）・`CapexCreditCycleRun`
# （`capex_run`）・`CapexDiagnostics`（`capex_diagnostics`、`I-5`）を読み取るだけであり、値の再計算・
# モデル本体の動学への影響は一切ない。`dY`/`dI`/`dC` の baseline 比乖離のみ、分析契約 §2.4 の
# 定義済み式（`dY`/`dC` は相対乖離、`dI` は診断層 `_capex_amplification` と同じ絶対乖離）を
# `_capex_rel_dev`/`_capex_abs_dev`/`_capex_combine`（`capex_credit_cycle_diagnostics.jl`）へ
# そのまま委譲して算出する（新しい式を定義しない）。
#
# 設計契約:
#   docs/architecture/capex_credit_cycle_integration.md §9 `I-7`（対象ファイル・実施内容・受け入れ条件）
#   docs/models/capex_credit_cycle_design.md（統合モデル仕様 index）
#   docs/adr/0013-capex-credit-cycle-integration-contract.md
#
# 潜在変数の単独提示抑止（実施内容4）:
#   `SimulationResult.metadata["variable_observability"]`（`I-6`）を参照し、要求された変数が
#   すべて潜在（observability コード `E`「潜在状態として推定が必要」・`A`「観測不能・シナリオ
#   仮定のみ」、[観測方程式・識別戦略](https://github.com/Yuki-Watanabe7/DME/blob/main/docs/models/capex_credit_cycle_empirical_strategy.md)
#   §3 の5分類）である場合に `ArgumentError` を送出する（`_ccc_assert_not_latent_only`）。
#   観測可能な変数と併せて指定する分には抑止しない（「単独提示」の抑止であり、潜在変数を含む
#   図そのものの禁止ではない）。
#
# Keen の資金調達区分との非混同（受け入れ条件・#166 §7.4）:
#   `funding_pressure_s`（5値: `fp_covered`/`fp_rollover_dependent`/`fp_interest_uncovered`/
#   `fp_unlevered`/`fp_invalid`）は Keen の資金調達区分（`hedge`/`speculative`/`ponzi` 等、
#   `minsky_visualization.jl` の `_FINANCING_REGIME_STYLE`）とは別ラベル体系であり同一視しない
#   （#165 §8・#166 §7.4）。本ファイルは独立の配色・独立の関数を用い、両者を同一の図へ重ねない。

# ------------------------------------------------------------
# 潜在変数の単独提示抑止（共通ヘルパー）
# ------------------------------------------------------------

const _CCC_LATENT_OBSERVABILITY_CODES = ("E", "A")

"""
    _ccc_assert_not_latent_only(result::SimulationResult, vars::Vector{String})

`vars` に含まれる全変数の `variable_observability` コードが潜在（`E`・`A`、
[観測方程式・識別戦略 §3](https://github.com/Yuki-Watanabe7/DME/blob/main/docs/models/capex_credit_cycle_empirical_strategy.md)）である場合に
`ArgumentError` を送出する。`variable_observability` が metadata に無い場合（CCC 以外の
`SimulationResult` を誤って渡した場合等）は検査をスキップする。
"""
function _ccc_assert_not_latent_only(result::SimulationResult, vars::Vector{String})
    isempty(vars) && return nothing
    obs = get(result.metadata, "variable_observability", nothing)
    obs === nothing && return nothing

    codes = String[]
    for v in vars
        c = get(obs, v, nothing)
        c === nothing && return nothing
        push!(codes, c)
    end
    all(c -> c in _CCC_LATENT_OBSERVABILITY_CODES, codes) || return nothing

    throw(
        ArgumentError(
            "指定された変数がすべて潜在変数です（variable_observability ∈ " *
            "$(_CCC_LATENT_OBSERVABILITY_CODES)）: $(join(vars, ", "))。潜在変数は単独の水準を" *
            "提示しない契約（統合設計 §8.4-6・観測方程式 §3）のため、観測可能な変数と併せて" *
            "指定してください。",
        ),
    )
end

"""
    plot_capex_series(result::SimulationResult; vars=nothing, kwargs...) -> Plots.Plot

`CapexCreditCycleModel` の `SimulationResult` を [`plot_result`](@ref) と同じ引数で描画する薄い
ラッパー。`plot_result` との違いは、`result.metadata["variable_observability"]` を参照して
指定変数が**すべて潜在変数**（`cost_capital_s1`–`_s3`・`ai_exp`・`target_cap_s1`・`cancel_s1` 等、
observability コード `E`/`A`）の場合に `ArgumentError` を送出する点のみ（`I-7` 実施内容4）。

## エラー

- 存在しない変数名を指定した場合は `ArgumentError`（`plot_result` と同じ）。
- 指定変数がすべて潜在変数の場合は `ArgumentError`。

## 例

```julia
m = capex_credit_cycle_model(capex_credit_cycle_default_targets())
run = capex_run(m; scenario = :Sc3)
sr = to_simulation_result(m, run, "Sc3")

p = plot_capex_series(sr; vars = ["y_tot", "cons"])          # OK
plot_capex_series(sr; vars = ["cost_capital_s1"])             # ArgumentError（潜在変数のみ）
```
"""
function plot_capex_series(result::SimulationResult; vars = nothing, kwargs...)
    requested = _resolve_plot_vars(result, vars)
    _ccc_assert_not_latent_only(result, requested)
    return plot_result(result; vars = requested, kwargs...)
end

# ------------------------------------------------------------
# 部門別系列（受注・稼働率・在庫比率・CAPEX・債務）
# ------------------------------------------------------------

"""
    CAPEX_CC_SECTOR_SERIES_CONCEPTS

[`plot_capex_sector_series`](@ref) が描画できる概念（`concepts`）のキー一覧。
"""
const CAPEX_CC_SECTOR_SERIES_CONCEPTS =
    (:orders, :utilization, :inventory_ratio, :capex, :debt)

const _CAPEX_SECTOR_SERIES_SPEC = Dict(
    :orders =>
        (title = "Orders (受注)", series = [("order_s2", "S2"), ("order_s3", "S3")]),
    :utilization => (
        title = "Capacity utilization (稼働率)",
        series = [("util_s2", "S2"), ("util_s3", "S3")],
    ),
    :inventory_ratio => (
        title = "Inventory ratio (在庫比率)",
        series = [("inv_ratio_s2", "S2"), ("inv_ratio_s3", "S3")],
    ),
    :capex => (
        title = "CAPEX / investment execution",
        series = [("capex_exec_s1", "S1"), ("invest_s2", "S2"), ("invest_s3", "S3")],
    ),
    :debt => (
        title = "Debt stock",
        series = [("debt_s1", "S1"), ("debt_s2", "S2"), ("debt_s3", "S3")],
    ),
)

"""
    plot_capex_sector_series(result::SimulationResult;
                             concepts=collect(CAPEX_CC_SECTOR_SERIES_CONCEPTS),
                             combine::Bool=true, title=nothing, kwargs...) -> Plots.Plot または Vector{Plots.Plot}

部門別系列（受注・稼働率・在庫比率・CAPEX・債務、`I-7` 実施内容1）を概念ごとにパネル描画する。
各パネルは対応する部門（`S1`–`S3` のうち該当するもの）の系列を重ねて表示する
（例: `:orders` パネルは `order_s2`・`order_s3` を重ねる）。

## キーワード引数

- `concepts`: 描画する概念の `Symbol` 配列。既定は [`CAPEX_CC_SECTOR_SERIES_CONCEPTS`](@ref) の全5概念
- `combine`: `true`（既定）で `layout` により1つの `Plots.Plot` へ結合、`false` で `Vector{Plots.Plot}`
- `title`: `combine=true` のときの全体タイトル
- `kwargs...`: `combine=true` のとき、結合後の `Plots.jl` オプションとして渡す

## エラー

- 未知の `concept` を指定した場合は `ArgumentError`
- `result` に該当する変数が無い場合は `ArgumentError`

## 例

```julia
m = capex_credit_cycle_model(capex_credit_cycle_default_targets())
run = capex_run(m; scenario = :Sc3)
sr = to_simulation_result(m, run, "Sc3")

p = plot_capex_sector_series(sr)
p_subset = plot_capex_sector_series(sr; concepts = [:orders, :debt])
```
"""
function plot_capex_sector_series(
    result::SimulationResult;
    concepts::Vector{Symbol} = collect(CAPEX_CC_SECTOR_SERIES_CONCEPTS),
    combine::Bool = true,
    title::Union{Nothing, String} = nothing,
    kwargs...,
)
    unknown = filter(c -> !haskey(_CAPEX_SECTOR_SERIES_SPEC, c), concepts)
    if !isempty(unknown)
        throw(
            ArgumentError(
                "未知の concept: $(join(unknown, ", "))。利用可能な concept: " *
                join(CAPEX_CC_SECTOR_SERIES_CONCEPTS, ", "),
            ),
        )
    end

    t = 1:nperiods(result)
    panels = Plots.Plot[]
    for c in concepts
        spec = _CAPEX_SECTOR_SERIES_SPEC[c]
        varnames = String[v for (v, _) in spec.series]
        missing_vars = filter(v -> !haskey(result, v), varnames)
        if !isempty(missing_vars)
            throw(ArgumentError("変数が見つかりません: $(join(missing_vars, ", "))"))
        end
        _ccc_assert_not_latent_only(result, varnames)

        p = plot(; title = spec.title, xlabel = "Period", ylabel = "")
        for (v, lbl) in spec.series
            plot!(p, t, result[v]; label = lbl)
        end
        push!(panels, p)
    end

    combine || return panels
    n = length(panels)
    ttl =
        title === nothing ?
        "$(result.model_name) — $(result.scenario_name) (sector series)" : title
    return plot(
        panels...;
        layout = (n, 1),
        size = (800, 260 * n),
        plot_title = ttl,
        kwargs...,
    )
end

# ------------------------------------------------------------
# シナリオ比較（dY・dI・dC の baseline 比乖離）
# ------------------------------------------------------------

"""
    CAPEX_CC_SCENARIO_COMPARISON_VARS

[`plot_capex_scenario_comparison`](@ref) が描画できる指標のキー一覧。分析契約 §2.4・§3 Q2 の
`dY`（総産出、相対乖離）・`dI`（`S1`–`S3` 合計の実行CAPEX、絶対乖離）・`dC`（消費、相対乖離）。
"""
const CAPEX_CC_SCENARIO_COMPARISON_VARS = (:dY, :dI, :dC)

const _CAPEX_SCENARIO_COMPARISON_YLABEL = Dict(
    :dY => "dY — baseline比相対乖離（総産出）",
    :dI => "dI — baseline差（S1–S3合計CAPEX実行、絶対乖離）",
    :dC => "dC — baseline比相対乖離（消費）",
)

# `dY`/`dC` は分析契約 §2.4 の相対乖離、`dI` は `_capex_amplification`（動学方程式 §16.5、Q2）と
# 同じ絶対乖離。新しい式は定義せず、診断層の既存関数（`_capex_rel_dev`・`_capex_abs_dev`・
# `_capex_combine`・`_CAPEX_Q2_REPRESENTATIVE`、`capex_credit_cycle_diagnostics.jl`）へ委譲する。
function _capex_dx_series(m::CapexCreditCycleModel, run::CapexCreditCycleRun, var::Symbol)
    ss = steady_state(m)
    eps = run.options.div_eps
    if var === :dY
        return _capex_rel_dev(_capex_series(run, :y_tot), ss.y_tot, eps)
    elseif var === :dI
        z = _capex_combine(run.series, _CAPEX_Q2_REPRESENTATIVE)
        base = sum(getproperty(ss, s) for s in _CAPEX_Q2_REPRESENTATIVE)
        return _capex_abs_dev(z, base)
    elseif var === :dC
        return _capex_rel_dev(_capex_series(run, :cons), ss.cons, eps)
    end
    throw(
        ArgumentError(
            "未知の var: $(var)。利用可能な var: " *
            join(CAPEX_CC_SCENARIO_COMPARISON_VARS, ", "),
        ),
    )
end

"""
    plot_capex_scenario_comparison(m::CapexCreditCycleModel, runs::Vector{CapexCreditCycleRun};
                                   vars=collect(CAPEX_CC_SCENARIO_COMPARISON_VARS),
                                   labels=nothing, combine::Bool=true,
                                   title=nothing, kwargs...) -> Plots.Plot または Vector{Plots.Plot}

複数シナリオ（`Sc0`–`Sc4` 等）を `dY`・`dI`・`dC` の baseline 比乖離で比較する（`I-7` 実施内容2）。
baseline は各シナリオ共通の `steady_state(m)`（`Sc0` は定常値に一致するよう設計されている、
分析契約 §2.4・シナリオ定義 §4.4）であり、シナリオ間で独立に定常状態を計算し直すことはない。

## キーワード引数

- `vars`: 比較する指標の `Symbol` 配列。既定は [`CAPEX_CC_SCENARIO_COMPARISON_VARS`](@ref) の全3指標
- `labels`: 凡例ラベルの `String` 配列。省略時は各 `run.scenario` を使用
- `combine`: `true`（既定）で `layout` により1つの `Plots.Plot` へ結合、`false` で `Vector{Plots.Plot}`
- `title`: `combine=true` のときの全体タイトル
- `kwargs...`: `combine=true` のとき、結合後の `Plots.jl` オプションとして渡す

## エラー

- `runs` が空の場合は `ArgumentError`
- 未知の `var` を指定した場合は `ArgumentError`
- `labels` の長さが `runs` の長さと異なる場合は `ArgumentError`

## 例

```julia
m = capex_credit_cycle_model(capex_credit_cycle_default_targets())
run0 = capex_run(m; scenario = :Sc0)
run3 = capex_run(m; scenario = :Sc3)

p = plot_capex_scenario_comparison(m, [run0, run3])
```
"""
function plot_capex_scenario_comparison(
    m::CapexCreditCycleModel,
    runs::Vector{CapexCreditCycleRun};
    vars::Vector{Symbol} = collect(CAPEX_CC_SCENARIO_COMPARISON_VARS),
    labels::Union{Nothing, Vector{String}} = nothing,
    combine::Bool = true,
    title::Union{Nothing, String} = nothing,
    kwargs...,
)
    isempty(runs) && throw(ArgumentError("runs が空です"))

    unknown = filter(v -> !(v in CAPEX_CC_SCENARIO_COMPARISON_VARS), vars)
    if !isempty(unknown)
        throw(
            ArgumentError(
                "未知の var: $(join(unknown, ", "))。利用可能な var: " *
                join(CAPEX_CC_SCENARIO_COMPARISON_VARS, ", "),
            ),
        )
    end

    if labels !== nothing && length(labels) != length(runs)
        throw(
            ArgumentError(
                "labels の長さ ($(length(labels))) が runs の長さ ($(length(runs))) と異なります",
            ),
        )
    end

    scenario_labels = labels === nothing ? String[String(r.scenario) for r in runs] : labels

    panels = Plots.Plot[]
    for v in vars
        p = plot(;
            title = string(v),
            xlabel = "Period",
            ylabel = _CAPEX_SCENARIO_COMPARISON_YLABEL[v],
        )
        for (i, run) in enumerate(runs)
            dz = _capex_dx_series(m, run, v)
            plot!(p, run.periods, dz; label = scenario_labels[i])
        end
        hline!(p, [0.0]; color = :black, linestyle = :dash, label = "")
        push!(panels, p)
    end

    combine || return panels
    n = length(panels)
    ttl =
        title === nothing ?
        "Scenario comparison — " * join(unique(scenario_labels), " vs ") : title
    return plot(
        panels...;
        layout = (n, 1),
        size = (800, 260 * n),
        plot_title = ttl,
        kwargs...,
    )
end

# ------------------------------------------------------------
# 診断ラベルの時間帯表示
# ------------------------------------------------------------

const _CAPEX_LABEL_STYLE = Dict(
    :contained_adjustment => (color = :steelblue, label = "contained_adjustment"),
    :sectoral_downturn => (color = :orange, label = "sectoral_downturn"),
    :broad_downturn => (color = :firebrick, label = "broad_downturn"),
    :indeterminate => (color = :gray50, label = "indeterminate"),
)

const _CAPEX_GROUP_ORDER = (:G1, :G2, :G3, :G4)

const _CAPEX_GROUP_LABEL = Dict(
    :G1 => "G1 breach (total output)",
    :G2 => "G2 breach (sector real activity)",
    :G3 => "G3 breach (household)",
    :G4 => "G4 breach (credit conditions)",
)

"""
    plot_capex_diagnostic_label(diag::CapexDiagnostics, run::CapexCreditCycleRun;
                                title=nothing, kwargs...) -> Plots.Plot

診断ラベル（`diag.label` ∈ `:contained_adjustment`/`:sectoral_downturn`/`:broad_downturn`/
`:indeterminate`、分析契約 §4.3）を評価期間（`t ≥ 0`）全体の帯として描画し、判定に用いた4指標群
（`G1`–`G4`、`diag.group_status`）のうち持続的に閾値超（`met = true`）となった群を、超過開始時点
から継続四半期数ぶんの帯として重ねる（`I-7` 実施内容3）。値はすべて `diag.group_status`・
`diag.breadth`・`diag.recovery_period` から読み取るのみで再計算しない。

`broad_downturn` は本モデル内の中立的な診断ラベルであり、公式の景気後退判定ではない
（分析契約 §4.1 の契約、タイトルに明記）。

## エラー

`run.periods` に評価期間（`t ≥ 0`）が含まれない場合は `ArgumentError`。

## 例

```julia
diag = capex_diagnostics(m, run3)
p = plot_capex_diagnostic_label(diag, run3)
```
"""
function plot_capex_diagnostic_label(
    diag::CapexDiagnostics,
    run::CapexCreditCycleRun;
    title::Union{Nothing, String} = nothing,
    kwargs...,
)
    eval_periods = filter(t -> t >= 0, run.periods)
    isempty(eval_periods) &&
        throw(ArgumentError("run.periods に評価期間（t ≥ 0）が含まれていません"))
    t0, t1 = minimum(eval_periods), maximum(eval_periods)

    style = _CAPEX_LABEL_STYLE[diag.label]
    ttl = if title !== nothing
        title
    else
        "Diagnostic label — $(diag.label) (breadth peak = $(round(diag.breadth; digits = 2)))\n" *
        "(model-internal diagnostic label — not an official recession call, analysis contract §4.1)"
    end

    p = plot(;
        title = ttl,
        xlabel = "Period",
        ylabel = "",
        ylim = (0.0, 1.0),
        yticks = nothing,
        legend = :outerright,
        kwargs...,
    )

    label_band = Shape([t0 - 0.5, t1 + 0.5, t1 + 0.5, t0 - 0.5], [0.0, 0.0, 1.0, 1.0])
    plot!(
        p,
        label_band;
        fillcolor = style.color,
        linecolor = style.color,
        fillalpha = 0.15,
        label = style.label,
    )

    n = length(_CAPEX_GROUP_ORDER)
    for (i, g) in enumerate(_CAPEX_GROUP_ORDER)
        gs = diag.group_status[g]
        gs.met || continue
        y = i / (n + 1)
        s0 = gs.start_period
        s1 = s0 + gs.duration - 1
        gband = Shape(
            [s0 - 0.5, s1 + 0.5, s1 + 0.5, s0 - 0.5],
            [y - 0.06, y - 0.06, y + 0.06, y + 0.06],
        )
        plot!(
            p,
            gband;
            fillcolor = :gray20,
            linecolor = :gray20,
            fillalpha = 0.75,
            label = _CAPEX_GROUP_LABEL[g],
        )
    end

    if diag.recovery_period !== nothing
        vline!(
            p,
            [diag.recovery_period - 0.5];
            linestyle = :dot,
            color = :black,
            alpha = 0.7,
            label = "recovery",
        )
    end

    return p
end

# ------------------------------------------------------------
# funding_pressure_s の帯グラフ
# ------------------------------------------------------------

const _CAPEX_FUNDING_PRESSURE_STYLE = Dict(
    :fp_covered => (color = :seagreen, label = "fp_covered"),
    :fp_rollover_dependent => (color = :orange, label = "fp_rollover_dependent"),
    :fp_interest_uncovered => (color = :firebrick, label = "fp_interest_uncovered"),
    :fp_unlevered => (color = :gray70, label = "fp_unlevered"),
    :fp_invalid => (color = :gray30, label = "fp_invalid"),
)

const _CAPEX_SECTOR_DISPLAY_LABEL = Dict(:s1 => "S1", :s2 => "S2", :s3 => "S3")

function _capex_funding_pressure_panel(
    run::CapexCreditCycleRun,
    s::Symbol,
    labels::Vector{Symbol},
)
    p = plot(;
        title = "funding_pressure_$(s) ($(_CAPEX_SECTOR_DISPLAY_LABEL[s]))",
        xlabel = "Period",
        ylabel = "",
        ylim = (0.0, 1.0),
        yticks = nothing,
        legend = :outerright,
    )
    seen = Set{Symbol}()
    for (t0, t1, val) in _categorical_bands(run.periods, labels)
        style = _CAPEX_FUNDING_PRESSURE_STYLE[val]
        lbl = val in seen ? "" : style.label
        push!(seen, val)
        band = Shape([t0 - 0.5, t1 + 0.5, t1 + 0.5, t0 - 0.5], [0.0, 0.0, 1.0, 1.0])
        plot!(
            p,
            band;
            fillcolor = style.color,
            linecolor = style.color,
            linestyle = val === :fp_invalid ? :dash : :solid,
            fillalpha = val === :fp_invalid ? 0.30 : 0.55,
            label = lbl,
        )
    end
    return p
end

"""
    plot_capex_funding_pressure(diag::CapexDiagnostics, run::CapexCreditCycleRun;
                                sectors=[:s1,:s2,:s3], combine::Bool=true,
                                title=nothing, kwargs...) -> Plots.Plot または Vector{Plots.Plot}

`funding_pressure_s` の5値（`diag.funding_pressure`、precedence順: `fp_invalid` →
`fp_unlevered` → `fp_interest_uncovered` → `fp_rollover_dependent` → `fp_covered`、
[ストック・フロー会計表 §7.4](https://github.com/Yuki-Watanabe7/DME/blob/main/docs/models/capex_credit_cycle_stock_flow.md)）を部門ごとに
時系列帯として描画する（`I-7` 実施内容3）。`Minsky` の資金調達区分（`hedge`/`speculative`/
`ponzi`）とは**別ラベル体系**であり、独立の配色・独立の関数を用いる。同一の図に重ねない
（#166 §7.4）。

## キーワード引数

- `sectors`: 描画する部門の `Symbol` 配列。既定は `[:s1, :s2, :s3]`
- `combine`: `true`（既定）で `layout` により1つの `Plots.Plot` へ結合、`false` で `Vector{Plots.Plot}`
- `title`: `combine=true` のときの全体タイトル
- `kwargs...`: `combine=true` のとき、結合後の `Plots.jl` オプションとして渡す

## エラー

未知の `sector` を指定した場合は `ArgumentError`。

## 例

```julia
diag = capex_diagnostics(m, run3)
p = plot_capex_funding_pressure(diag, run3)
```
"""
function plot_capex_funding_pressure(
    diag::CapexDiagnostics,
    run::CapexCreditCycleRun;
    sectors::Vector{Symbol} = [:s1, :s2, :s3],
    combine::Bool = true,
    title::Union{Nothing, String} = nothing,
    kwargs...,
)
    unknown = filter(s -> !haskey(diag.funding_pressure, s), sectors)
    if !isempty(unknown)
        throw(
            ArgumentError(
                "未知の sector: $(join(unknown, ", "))。利用可能な sector: s1, s2, s3",
            ),
        )
    end

    panels =
        [_capex_funding_pressure_panel(run, s, diag.funding_pressure[s]) for s in sectors]

    combine || return panels
    n = length(panels)
    ttl =
        title === nothing ?
        "funding_pressure_s — $(run.model_name) ($(String(run.scenario)))" : title
    return plot(
        panels...;
        layout = (n, 1),
        size = (800, 260 * n),
        plot_title = ttl,
        kwargs...,
    )
end
