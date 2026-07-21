# keen_empirical_visualization.jl: Keen 実証バリデーション結果（#122）の実証比較専用
# 可視化レイヤー（#123）。
#
# `src/core/visualization.jl`（`plot_result` 等）・`src/analysis/minsky_visualization.jl`
# （`plot_financing_regimes` 等）と同じ Plots.jl ベースのパターンに従う。
# `KeenValidationResult`（`validate_keen`）を読み取るだけの読み取り専用レイヤーであり、
# モデル・診断・推定のロジックには一切影響しない。値の再計算も行わない
# （trajectory は `result.trajectories` に、regime は `result.regime_comparison` に事前計算済み）。
#
# 欠損・invalid・発散後の `NaN` は Plots.jl の標準挙動どおり線を途切れさせる
# （線形補間・0 化・塗りつぶしは行わない）。observed proxy regime は集計代理診断であり
# 企業別実測分類ではない（タイトル・docs に明記）。

# observed / literature / calibrated の系列スタイル（色・線種で識別）
const _KEEN_SERIES_STYLE = (
    observed = (
        color = :black,
        linestyle = :solid,
        marker = :circle,
        label = "observed (proxy)",
    ),
    literature = (color = :orange, linestyle = :dash, marker = :none, label = "literature"),
    calibrated = (
        color = :steelblue,
        linestyle = :solid,
        marker = :none,
        label = "calibrated",
    ),
)

const _KEEN_VAR_YLABEL =
    Dict(:ω => "ω (wage share)", :λ => "λ (employment rate)", :d => "d (debt ratio)")

# 期間境界（calibration 終端 / validation 開始）を縦線で示す共通ヘルパー。
function _keen_add_split_marker!(p, bundle::KeenTrajectoryBundle)
    if bundle.validation_start_time !== nothing && bundle.calibration_end_time !== nothing
        # calibration 終端と validation 開始の中点に境界線
        x = 0.5 * (bundle.calibration_end_time + bundle.validation_start_time)
        vline!(p, [x]; color = :gray50, linestyle = :dot, label = "calib | valid")
    end
    return p
end

"""
    plot_keen_empirical_trajectories(result::KeenValidationResult;
                                     variables=[:ω,:λ,:d],
                                     combine::Bool=true,
                                     title::Union{Nothing,String}=nothing,
                                     kwargs...) -> Plots.Plot または Vector{Plots.Plot}

`KeenValidationResult` の full-sample 系列（`result.trajectories`）について、変数ごとに
**observed proxy / literature / calibrated** を同一時間軸で重ねて描画する。calibration と
validation の境界を縦線で示す。

model 系列は観測開始状態（`:observed_start`）からの予測 trajectory。発散後・欠損は `NaN` の
まま線を途切れさせ、線形補間や 0 化は行わない（#123 の要件）。observed は理論変数の近似
proxy、literature は文献 default、calibrated は採用期間・proxy・weight・bounds に依存する
推定値であることに注意（[keen.md](../../docs/models/keen.md)）。

## キーワード引数
- `variables` : 描画対象（`:ω`・`:λ`・`:d` の部分集合）
- `combine` : `true`（既定）で 1 枚のレイアウトに結合、`false` で `Vector{Plots.Plot}`
- `title` : `combine=true` のときの全体タイトル（各パネルは変数名を使う）
- `kwargs...` : `Plots.jl` へ渡す追加オプション
"""
function plot_keen_empirical_trajectories(
    result::KeenValidationResult;
    variables::Vector{Symbol} = [:ω, :λ, :d],
    combine::Bool = true,
    title::Union{Nothing, String} = nothing,
    kwargs...,
)
    for v in variables
        haskey(_KEEN_VAR_YLABEL, v) ||
            throw(ArgumentError("variables は :ω/:λ/:d のみ（指定: $(repr(v))）"))
    end
    b = result.trajectories
    t = b.times

    panels = Plots.Plot[]
    for v in variables
        p = plot(;
            xlabel = "time (years from sample start)",
            ylabel = _KEEN_VAR_YLABEL[v],
            title = string(v),
        )
        so = _KEEN_SERIES_STYLE.observed
        plot!(
            p,
            t,
            b.observed[v];
            color = so.color,
            linestyle = so.linestyle,
            marker = so.marker,
            markersize = 2,
            label = so.label,
        )
        sl = _KEEN_SERIES_STYLE.literature
        plot!(
            p,
            t,
            b.literature[v];
            color = sl.color,
            linestyle = sl.linestyle,
            label = sl.label,
        )
        sc = _KEEN_SERIES_STYLE.calibrated
        plot!(
            p,
            t,
            b.calibrated[v];
            color = sc.color,
            linestyle = sc.linestyle,
            label = sc.label,
        )
        _keen_add_split_marker!(p, b)
        push!(panels, p)
    end

    if !combine
        return panels
    end
    ttl =
        title === nothing ?
        "Keen empirical trajectories — observed proxy vs literature vs calibrated" : title
    plot(panels...; layout = (length(panels), 1), plot_title = ttl, kwargs...)
end

"""
    plot_keen_regime_comparison(result::KeenValidationResult;
                                title::Union{Nothing,String}=nothing,
                                kwargs...) -> Plots.Plot

observed proxy / literature / calibrated の資金調達区分 timeline を 3 段に縦積みで比較する
（各段は `plot_financing_regimes` を再利用）。observed proxy は集計系列への操作的定義の代理で
あり企業別実測分類ではない。model 側は full-sample 予測 trajectory への診断。

時間軸は各 `MinskyDiagnosticsResult` の観測インデックス（1 始まり、`Δt = 0.25` の等間隔四半期）。
"""
function plot_keen_regime_comparison(
    result::KeenValidationResult;
    title::Union{Nothing, String} = nothing,
    kwargs...,
)
    rc = result.regime_comparison
    p_obs = plot_financing_regimes(
        rc.observed;
        title = "observed proxy (aggregate, not firm-level)",
        show_transitions = false,
    )
    p_lit = plot_financing_regimes(
        rc.literature;
        title = "literature",
        show_transitions = false,
    )
    p_cal = plot_financing_regimes(
        rc.calibrated;
        title = "calibrated",
        show_transitions = false,
    )
    ttl =
        title === nothing ?
        "Financing regime comparison — observed proxy vs literature vs calibrated" : title
    plot(p_obs, p_lit, p_cal; layout = (3, 1), plot_title = ttl, kwargs...)
end

# 感応度シナリオから描画するスカラー指標の accessor
const _KEEN_SENSITIVITY_METRICS = Dict{Symbol, NamedTuple}(
    :objective_value => (accessor = r -> r.objective_value, ylabel = "objective value"),
    :peak_debt_ratio => (
        accessor = r -> r.peak_debt_ratio === nothing ? NaN : r.peak_debt_ratio,
        ylabel = "peak debt ratio (model)",
    ),
    :hedge_share => (
        accessor = r -> get(r.regime_share, hedge, NaN),
        ylabel = "hedge share (model, valid periods)",
    ),
    :ponzi_share => (
        accessor = r -> get(r.regime_share, ponzi, NaN),
        ylabel = "ponzi share (model, valid periods)",
    ),
    :n_transitions =>
        (accessor = r -> float(r.n_transitions), ylabel = "regime transitions (model)"),
)

"""
    plot_keen_sensitivity(result::KeenValidationResult;
                          metric::Symbol=:peak_debt_ratio,
                          title::Union{Nothing,String}=nothing,
                          kwargs...) -> Plots.Plot

感応度シナリオ（base を含む）ごとの選択スカラー指標を棒グラフで比較する。シナリオ名を
x 軸ラベルに用いる。`metric` は `:objective_value`・`:peak_debt_ratio`・`:hedge_share`・
`:ponzi_share`・`:n_transitions` のいずれか。

診断のみを変える感応度（`amortization_rate` 等）では推定値・ODE 軌跡は不変で診断指標だけが
変わることを、この棒グラフで確認できる（[keen_empirical_strategy.md §6.1](../../docs/models/keen_empirical_strategy.md)）。
"""
function plot_keen_sensitivity(
    result::KeenValidationResult;
    metric::Symbol = :peak_debt_ratio,
    title::Union{Nothing, String} = nothing,
    kwargs...,
)
    haskey(_KEEN_SENSITIVITY_METRICS, metric) || throw(
        ArgumentError(
            "未知の metric: $(repr(metric))。利用可能: " *
            join(sort(collect(keys(_KEEN_SENSITIVITY_METRICS))), ", "),
        ),
    )
    spec = _KEEN_SENSITIVITY_METRICS[metric]
    names = [r.scenario.name for r in result.sensitivity]
    vals = [spec.accessor(r) for r in result.sensitivity]
    ttl = title === nothing ? "Sensitivity — $(metric)" : title
    bar(
        names,
        vals;
        legend = false,
        ylabel = spec.ylabel,
        title = ttl,
        xrotation = 30,
        kwargs...,
    )
end
