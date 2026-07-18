# minsky_visualization.jl: Minsky 資金調達区分・金融不安定性連続診断指標（#112・#113）の
# 可視化専用レイヤー（Phase 2, #114）。
#
# `src/core/visualization.jl`（`plot_result`/`plot_comparison`/`plot_irf`）と同じ
# Plots.jl ベースのパターンに従う。診断値そのものは一切再計算せず、
# `MinskyDiagnosticsResult`/`MinskyDiagnosticsComparison`（`minsky_diagnostics.jl`）を
# 読み取るだけの読み取り専用レイヤーであり、`KeenModel`・診断層のロジックには影響しない。
#
# 発散後の `NaN` は Plots.jl の標準挙動どおり線を途切れさせる（補間・0化・Ponzi塗りつぶしは
# 行わない）。詳細は docs/models/keen.md 「Phase 2 可視化」節を参照。

const _FINANCING_REGIME_STYLE = Dict(
    unlevered => (color = :gray70, marker = :circle, label = "unlevered"),
    hedge => (color = :steelblue, marker = :utriangle, label = "hedge"),
    speculative => (color = :orange, marker = :diamond, label = "speculative"),
    ponzi => (color = :firebrick, marker = :xcross, label = "ponzi"),
    invalid => (
        color = :gray30,
        marker = :star5,
        label = "invalid (unobservable / simulation truncated)",
    ),
)

# times・regimes（同じ長さ）から連続する同一 regime の区間 (start, stop, regime) を抽出する。
# times は昇順・重複なしを仮定（MinskyDiagnosticsResult の観測列がこれを満たす）。
function _contiguous_regime_runs(times::Vector{Int}, regimes::Vector{FinancingRegime})
    runs = Tuple{Int, Int, FinancingRegime}[]
    isempty(times) && return runs

    run_start = times[1]
    run_regime = regimes[1]
    prev_time = times[1]
    for i in 2:length(times)
        if regimes[i] != run_regime || times[i] != prev_time + 1
            push!(runs, (run_start, prev_time, run_regime))
            run_start = times[i]
            run_regime = regimes[i]
        end
        prev_time = times[i]
    end
    push!(runs, (run_start, prev_time, run_regime))
    return runs
end

"""
    plot_financing_regimes(diag::MinskyDiagnosticsResult;
                           title::Union{Nothing,String}=nothing,
                           show_transitions::Bool=true, kwargs...) -> Plots.Plot

`MinskyDiagnosticsResult`（`minsky_diagnostics`）の資金調達区分（`unlevered`/`hedge`/
`speculative`/`ponzi`/`invalid`）を時系列帯として描画し、`Plots.Plot` を返す。

区分は色だけでなく、区分ごとに異なるマーカー形状（塗りつぶし帯の上に重ねる点）でも
識別できる。`invalid`（発散後の `NaN` 埋め区間・非有限入力による判定不能区間）は
経済的な資金調達区分ではないため、破線境界・別配色・別ラベル（"invalid (unobservable /
simulation truncated)"）で明示し、`ponzi` の帯へは一切混入しない。

区分は `KeenModel` の集計量から導かれる代理診断であり、実測の企業比率ではない
（タイトルに明記）。詳細は [Minsky 資金調達区分診断](../../docs/models/minsky_regime_diagnostics.md)
を参照。

## キーワード引数

- `title`: プロットタイトル。省略時は代理診断である旨を含む既定タイトルを使用する
- `show_transitions`: `true`（既定）のとき、区分が変化した時点（`invalid` との遷移を含む）に
  縦線を表示する
- `kwargs...`: `Plots.jl` に直接渡す追加オプション

## エラー

`diag.regime_diagnostics.observations` が空の場合は `ArgumentError` が発生する。

## 例

```julia
m = KeenModel(0.025, 0.02, 0.01, 3.0, 0.03, 0.0400641, 6.41e-5, -0.0065, exp(-5), 20.0)
ss = steady_state(m)
result = simulate(m, ss.ω, ss.λ, 5.0; T = 300)  # 高債務初期値 → 崩壊経路
diag = minsky_diagnostics(m, result)

p = plot_financing_regimes(diag)
```
"""
function plot_financing_regimes(
    diag::MinskyDiagnosticsResult;
    title::Union{Nothing, String} = nothing,
    show_transitions::Bool = true,
    kwargs...,
)
    regime_obs = diag.regime_diagnostics.observations
    isempty(regime_obs) &&
        throw(ArgumentError("diag.regime_diagnostics.observations が空です"))

    ttl = if title !== nothing
        title
    else
        "Financing Regime Timeline — $(diag.model_name) ($(diag.scenario_name))\n" *
        "(aggregate proxy diagnostic — not a measured share of firms)"
    end

    times = [o.time for o in regime_obs]
    regimes = [o.regime for o in regime_obs]

    p = plot(;
        title = ttl,
        xlabel = "Period",
        ylabel = "",
        ylim = (0.0, 1.0),
        yticks = nothing,
        legend = :outerright,
        kwargs...,
    )

    seen = Set{FinancingRegime}()
    for (t0, t1, regime) in _contiguous_regime_runs(times, regimes)
        style = _FINANCING_REGIME_STYLE[regime]
        lbl = regime in seen ? "" : style.label
        push!(seen, regime)
        band = Shape([t0 - 0.5, t1 + 0.5, t1 + 0.5, t0 - 0.5], [0.0, 0.0, 1.0, 1.0])
        plot!(
            p,
            band;
            fillcolor = style.color,
            linecolor = style.color,
            linestyle = regime == invalid ? :dash : :solid,
            fillalpha = regime == invalid ? 0.30 : 0.55,
            label = lbl,
        )
    end

    for regime in (unlevered, hedge, speculative, ponzi, invalid)
        idx = findall(==(regime), regimes)
        isempty(idx) && continue
        style = _FINANCING_REGIME_STYLE[regime]
        scatter!(
            p,
            times[idx],
            fill(0.5, length(idx));
            marker = style.marker,
            markersize = 3,
            markercolor = :black,
            label = "",
        )
    end

    if show_transitions
        transitions = diag.regime_diagnostics.transitions
        for (i, tr) in enumerate(transitions)
            vline!(
                p,
                [tr.time - 0.5];
                linestyle = :dash,
                color = :black,
                alpha = 0.6,
                label = i == 1 ? "regime transition" : "",
            )
        end
    end

    return p
end

# Inf/-Inf をプロット専用に NaN 化する（元の観測値は変更しない）。coverage ratio は
# 分母 0（無借金）のとき Inf になり、そのまま描画すると軸が破綻するため、
# 「オフスケール（無借金域）」区間として線を途切れさせる。
_clip_ratio_for_plot(x::Float64) = isfinite(x) ? x : NaN

const _MINSKY_DIAGNOSTIC_PANEL_KEYS =
    (:debt_ratio, :burden, :coverage, :margin, :profit_growth)

function _panel_debt_ratio(diag::MinskyDiagnosticsResult, t::Vector{Int})
    obs = diag.observations
    p = plot(; title = "Debt ratio", xlabel = "Period", ylabel = "d")
    plot!(p, t, [o.debt_ratio for o in obs]; label = "d", color = :steelblue)
    return p
end

function _panel_burden(diag::MinskyDiagnosticsResult, t::Vector{Int})
    obs = diag.observations
    p = plot(;
        title = "Debt burden vs. operating surplus",
        xlabel = "Period",
        ylabel = "Share of output",
    )
    plot!(
        p,
        t,
        [o.interest_burden for o in obs];
        label = "interest burden",
        color = :firebrick,
    )
    plot!(
        p,
        t,
        [o.principal_commitment_proxy for o in obs];
        label = "principal commitment (proxy)",
        color = :orange,
        linestyle = :dash,
    )
    plot!(
        p,
        t,
        [o.operating_surplus_share for o in obs];
        label = "operating surplus",
        color = :seagreen,
    )
    return p
end

function _panel_coverage(diag::MinskyDiagnosticsResult, t::Vector{Int})
    obs = diag.observations
    icr = _clip_ratio_for_plot.([o.interest_coverage_ratio for o in obs])
    dscr = _clip_ratio_for_plot.([o.debt_service_coverage_ratio for o in obs])
    p = plot(;
        title = "Coverage ratios (Inf periods shown as gaps)",
        xlabel = "Period",
        ylabel = "Ratio",
    )
    plot!(p, t, icr; label = "interest coverage ratio", color = :steelblue)
    plot!(
        p,
        t,
        dscr;
        label = "debt-service coverage ratio",
        color = :purple,
        linestyle = :dash,
    )
    hline!(p, [1.0]; color = :black, linestyle = :dot, label = "coverage = 1")
    return p
end

function _panel_margin(diag::MinskyDiagnosticsResult, t::Vector{Int})
    obs = diag.observations
    p = plot(;
        title = "Ponzi / Hedge margin",
        xlabel = "Period",
        ylabel = "Margin (share of output)",
    )
    plot!(p, t, [o.ponzi_margin for o in obs]; label = "ponzi margin", color = :firebrick)
    plot!(
        p,
        t,
        [o.hedge_margin for o in obs];
        label = "hedge margin",
        color = :steelblue,
        linestyle = :dash,
    )
    hline!(p, [0.0]; color = :black, linestyle = :dot, label = "margin = 0")
    return p
end

function _panel_profit_growth(diag::MinskyDiagnosticsResult, t::Vector{Int})
    obs = diag.observations
    p = plot(;
        title = "Profit share, growth rate, debt change",
        xlabel = "Period",
        ylabel = "",
    )
    plot!(
        p,
        t,
        [o.net_profit_share for o in obs];
        label = "net profit share (π)",
        color = :seagreen,
    )
    plot!(
        p,
        t,
        [o.growth_rate for o in obs];
        label = "growth rate (g)",
        color = :darkorange,
    )
    plot!(
        p,
        t,
        [o.debt_change for o in obs];
        label = "debt change (Δd)",
        color = :gray40,
        linestyle = :dash,
    )
    hline!(p, [0.0]; color = :black, linestyle = :dot, label = "")
    return p
end

function _minsky_diagnostic_panel(
    diag::MinskyDiagnosticsResult,
    t::Vector{Int},
    key::Symbol,
)
    p = if key === :debt_ratio
        _panel_debt_ratio(diag, t)
    elseif key === :burden
        _panel_burden(diag, t)
    elseif key === :coverage
        _panel_coverage(diag, t)
    elseif key === :margin
        _panel_margin(diag, t)
    elseif key === :profit_growth
        _panel_profit_growth(diag, t)
    else
        throw(
            ArgumentError(
                "未知の panel キー: $(key)。利用可能なキー: " *
                join(_MINSKY_DIAGNOSTIC_PANEL_KEYS, ", "),
            ),
        )
    end
    if diag.divergence_time !== nothing
        vline!(
            p,
            [diag.divergence_time - 0.5];
            linestyle = :dot,
            color = :black,
            alpha = 0.6,
            label = "divergence guard",
        )
    end
    return p
end

"""
    plot_minsky_diagnostics(diag::MinskyDiagnosticsResult;
                            panels::Union{Symbol,Vector{Symbol}}=:all,
                            combine::Bool=true, kwargs...) -> Plots.Plot または Vector{Plots.Plot}

`MinskyDiagnosticsResult`（`minsky_diagnostics`）の連続診断指標を複数パネルで描画する。

利用可能なパネル（`panels` キー）:

- `:debt_ratio`     : 債務比率 `d`
- `:burden`         : 利払い負担・元本返済代理・営業余剰
- `:coverage`        : interest coverage ratio / debt-service coverage ratio（`= 1` 境界線付き）
- `:margin`          : ponzi margin / hedge margin（`= 0` 境界線付き）
- `:profit_growth`   : net profit share `π` / growth rate `g` / debt change `Δd`

各パネルに `divergence_time`（発散ガード作動時点、または最初の `invalid` 時点）の縦線を表示する。
発散後の `NaN` は Plots.jl の標準挙動どおり線を途切れさせるだけであり、補間・0化はしない。

1枚に全系列を詰め込まず、既定では `plot(...; layout=(n,1))` で縦に積んだ複合プロットを返す
（`combine=false` で個別の `Plots.Plot` の `Vector` を返す）。

## キーワード引数

- `panels`: 描画するパネルの `Symbol` 配列。省略時は上記5パネルすべて
- `combine`: `true`（既定）のとき `layout` で1つの `Plots.Plot` に結合する。`false` のとき
  `Vector{Plots.Plot}` を返す
- `kwargs...`: `combine=true` のとき、結合後の `Plots.jl` オプションとして渡す

## エラー

- `diag.observations` が空の場合は `ArgumentError`
- `panels` に未知のキーが含まれる場合は `ArgumentError`

## 例

```julia
diag = minsky_diagnostics(m, result)
p = plot_minsky_diagnostics(diag)                       # 5パネル結合
p_subset = plot_minsky_diagnostics(diag; panels = [:debt_ratio, :margin])
plots = plot_minsky_diagnostics(diag; combine = false)   # Vector{Plots.Plot}
```
"""
function plot_minsky_diagnostics(
    diag::MinskyDiagnosticsResult;
    panels::Union{Symbol, Vector{Symbol}} = :all,
    combine::Bool = true,
    kwargs...,
)
    obs = diag.observations
    isempty(obs) && throw(ArgumentError("diag.observations が空です"))

    keys_to_plot = panels === :all ? collect(_MINSKY_DIAGNOSTIC_PANEL_KEYS) : panels
    unknown = filter(k -> !(k in _MINSKY_DIAGNOSTIC_PANEL_KEYS), keys_to_plot)
    if !isempty(unknown)
        throw(
            ArgumentError(
                "未知の panel キー: $(join(unknown, ", "))。利用可能なキー: " *
                join(_MINSKY_DIAGNOSTIC_PANEL_KEYS, ", "),
            ),
        )
    end

    t = [o.time for o in obs]
    subplots = [_minsky_diagnostic_panel(diag, t, k) for k in keys_to_plot]

    if !combine
        return subplots
    end

    n = length(subplots)
    return plot(
        subplots...;
        layout = (n, 1),
        size = (800, 260 * n),
        plot_title = "Minsky Diagnostics — $(diag.model_name) ($(diag.scenario_name))",
        kwargs...,
    )
end

const _SCENARIO_COMPARISON_COLORS =
    (:steelblue, :firebrick, :seagreen, :purple, :darkorange, :teal, :gray40, :magenta)

const _MINSKY_COMPARISON_VARS = Dict(
    :debt_ratio =>
        (accessor = o -> o.debt_ratio, ylabel = "Debt ratio (d)", clip = false),
    :interest_coverage_ratio => (
        accessor = o -> o.interest_coverage_ratio,
        ylabel = "Interest coverage ratio",
        clip = true,
    ),
    :debt_service_coverage_ratio => (
        accessor = o -> o.debt_service_coverage_ratio,
        ylabel = "Debt-service coverage ratio",
        clip = true,
    ),
    :ponzi_margin =>
        (accessor = o -> o.ponzi_margin, ylabel = "Ponzi margin", clip = false),
    :hedge_margin =>
        (accessor = o -> o.hedge_margin, ylabel = "Hedge margin", clip = false),
    :net_profit_share => (
        accessor = o -> o.net_profit_share,
        ylabel = "Net profit share (π)",
        clip = false,
    ),
    :growth_rate =>
        (accessor = o -> o.growth_rate, ylabel = "Growth rate (g)", clip = false),
    :debt_change =>
        (accessor = o -> o.debt_change, ylabel = "Debt change (Δd)", clip = false),
)

# 複数シナリオの診断設定（methodology_version・config）が一致するか検証する。
# strict=true（既定）では不一致を ArgumentError とし、異なる診断設定を暗黙に重ねて
# 比較することを拒否する。strict=false では @warn のみで比較を続行する。
function _check_comparable_minsky_configs(
    diags::Vector{MinskyDiagnosticsResult};
    strict::Bool,
)
    diagnostics_versions = unique(d.methodology_version for d in diags)
    regime_versions = unique(d.config.methodology_version for d in diags)
    amortization_rates = unique(d.config.amortization_rate for d in diags)

    problems = String[]
    if length(diagnostics_versions) > 1
        push!(problems, "methodology_version が一致しません: $(diagnostics_versions)")
    end
    if length(regime_versions) > 1
        push!(problems, "config.methodology_version が一致しません: $(regime_versions)")
    end
    if length(amortization_rates) > 1
        push!(problems, "config.amortization_rate が一致しません: $(amortization_rates)")
    end
    isempty(problems) && return nothing

    msg =
        "シナリオ間で診断設定が一致しません（" *
        join(problems, "; ") *
        "）。" *
        "異なる診断設定を暗黙に重ねて比較することはできません。意図的な比較であれば " *
        "strict=false を指定してください。"
    if strict
        throw(ArgumentError(msg))
    else
        @warn msg
    end
    return nothing
end

"""
    plot_minsky_scenario_comparison(comparison::MinskyDiagnosticsComparison;
                                    var::Symbol=:debt_ratio, strict::Bool=true,
                                    title::Union{Nothing,String}=nothing, kwargs...) -> Plots.Plot

`MinskyDiagnosticsComparison`（`minsky_diagnostics_comparison`、例: baseline・高金利・
高初期債務シナリオ）から、単一指標 `var` を同一の軸・単位で比較するプロットを生成する。

各シナリオについて、最初に `speculative` へ移行した時点（破線）・最初に `ponzi` へ移行した
時点（一点鎖線）・発散ガード作動時点（点線）を、シナリオごとに同じ色で縦線表示する
（イベントが存在しない場合は表示しない）。

## キーワード引数

- `var`: 比較する指標。`:debt_ratio`（既定）・`:interest_coverage_ratio`・
  `:debt_service_coverage_ratio`・`:ponzi_margin`・`:hedge_margin`・`:net_profit_share`・
  `:growth_rate`・`:debt_change` のいずれか
- `strict`: `true`（既定）のとき、シナリオ間で `methodology_version`・`config` が一致しない
  場合に `ArgumentError` を送出して比較を拒否する。`false` のときは `@warn` のみで
  比較を続行する（意図的な感応度比較等向け）
- `title`: プロットタイトル。省略時は `var` とシナリオ名から自動生成する
- `kwargs...`: `Plots.jl` に直接渡す追加オプション

## エラー

- `comparison.diagnostics` が2シナリオ未満の場合は `ArgumentError`
- `var` が未知の場合は `ArgumentError`
- `strict=true` でシナリオ間の診断設定が一致しない場合は `ArgumentError`

## 例

```julia
diag_base = minsky_diagnostics(m_base, simulate(m_base, ss.ω, ss.λ, ss.d; T = 300))
diag_high_r = minsky_diagnostics(m_high_r, simulate(m_high_r, ss.ω, ss.λ, ss.d; T = 300))
cmp = minsky_diagnostics_comparison(["baseline" => diag_base, "high_interest_rate" => diag_high_r])

p = plot_minsky_scenario_comparison(cmp; var = :debt_ratio)
```
"""
function plot_minsky_scenario_comparison(
    comparison::MinskyDiagnosticsComparison;
    var::Symbol = :debt_ratio,
    strict::Bool = true,
    title::Union{Nothing, String} = nothing,
    kwargs...,
)
    diags = comparison.diagnostics
    length(diags) >= 2 || throw(
        ArgumentError("比較には少なくとも2シナリオが必要です（指定: $(length(diags))）"),
    )

    if !haskey(_MINSKY_COMPARISON_VARS, var)
        throw(
            ArgumentError(
                "未知の var: $(var)。利用可能な var: " *
                join(sort(collect(keys(_MINSKY_COMPARISON_VARS))), ", "),
            ),
        )
    end

    _check_comparable_minsky_configs(diags; strict = strict)

    spec = _MINSKY_COMPARISON_VARS[var]
    ttl = if title !== nothing
        title
    else
        "Scenario Comparison: $(var) — " * join(comparison.scenario_names, " vs ")
    end

    p = plot(; title = ttl, xlabel = "Period", ylabel = spec.ylabel, kwargs...)

    for (i, diag) in enumerate(diags)
        obs = diag.observations
        t = [o.time for o in obs]
        y = [spec.accessor(o) for o in obs]
        if spec.clip
            y = _clip_ratio_for_plot.(y)
        end
        color = _SCENARIO_COMPARISON_COLORS[mod1(i, length(_SCENARIO_COMPARISON_COLORS))]
        plot!(p, t, y; label = comparison.scenario_names[i], color = color)

        summary = comparison.summaries[i]
        if summary.first_speculative_time !== nothing
            vline!(
                p,
                [summary.first_speculative_time - 0.5];
                color = color,
                linestyle = :dash,
                alpha = 0.6,
                label = "",
            )
        end
        if summary.first_ponzi_time !== nothing
            vline!(
                p,
                [summary.first_ponzi_time - 0.5];
                color = color,
                linestyle = :dashdot,
                alpha = 0.6,
                label = "",
            )
        end
        if diag.divergence_time !== nothing
            vline!(
                p,
                [diag.divergence_time - 0.5];
                color = color,
                linestyle = :dot,
                alpha = 0.8,
                label = "",
            )
        end
    end

    return p
end
