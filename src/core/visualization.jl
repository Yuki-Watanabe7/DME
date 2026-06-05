"""
    plot_result(result::SimulationResult; vars=nothing, title=..., xlabel=..., ylabel=..., kwargs...)

`SimulationResult` の変数系列を時系列プロットとして描画し、`Plots.Plot` を返す。

## キーワード引数

- `vars`: プロットする変数名（`String` または `Symbol` の単体か配列）。
  省略または `nothing` を指定するとすべての変数をプロット。
- `title`: プロットタイトル（デフォルト: `"モデル名 — シナリオ名"`）
- `xlabel`: X 軸ラベル（デフォルト: `"Period"`）
- `ylabel`: Y 軸ラベル（デフォルト: `""`）
- `kwargs...`: `Plots.jl` に直接渡す追加オプション

## エラー

存在しない変数名を指定した場合は `ArgumentError` が発生する。
エラーメッセージには利用可能な変数名が含まれる。

## 例

```julia
m = RamseyModel(0.3, 0.99, 0.25)
ep = steady_state(m)
path = transition_path(m, ep.K / 2)
sr = to_simulation_result(m, path, "transition_path")

# 全変数をプロット
p = plot_result(sr)

# 特定の変数をプロット
p = plot_result(sr; vars = "K")
p = plot_result(sr; vars = ["K", "C"])

# タイトル・軸ラベルをカスタマイズ
p = plot_result(sr; vars = ["K", "C"], title = "Ramsey 移行経路", xlabel = "Period", ylabel = "Level")
```
"""
function plot_result(
    result::SimulationResult;
    vars = nothing,
    title::String = "$(result.model_name) — $(result.scenario_name)",
    xlabel::String = "Period",
    ylabel::String = "",
    kwargs...,
)
    requested = _resolve_plot_vars(result, vars)
    t = 1:nperiods(result)
    p = plot(; title = title, xlabel = xlabel, ylabel = ylabel, kwargs...)
    for v in requested
        plot!(p, t, result[v]; label = v)
    end
    return p
end

function _resolve_plot_vars(result::SimulationResult, vars)
    if isnothing(vars)
        return sort(variable_names(result))
    end
    requested = if vars isa Symbol || vars isa AbstractString
        [String(vars)]
    else
        String[String(v) for v in vars]
    end
    missing_vars = filter(v -> !haskey(result, v), requested)
    if !isempty(missing_vars)
        available = sort(variable_names(result))
        throw(
            ArgumentError(
                "次の変数が見つかりません: $(join(missing_vars, ", ")). " *
                "利用可能な変数: $(join(available, ", "))",
            ),
        )
    end
    return requested
end
