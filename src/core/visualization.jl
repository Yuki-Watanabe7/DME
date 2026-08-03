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

"""
    plot_comparison(results::Vector{SimulationResult}; var, labels=nothing,
                    title=nothing, xlabel="Period", ylabel=nothing,
                    on_length_mismatch=:truncate, kwargs...)

複数の `SimulationResult` を同一変数について比較プロットし、`Plots.Plot` を返す。

## キーワード引数

- `var`: 比較対象の変数名（`String` または `Symbol`）。必須。
- `labels`: 凡例ラベルの `String` 配列。省略時は各 `SimulationResult` の `scenario_name` を使用。
- `title`: プロットタイトル。省略時は `"Scenario Comparison: var名"` を使用。
- `xlabel`: X 軸ラベル（デフォルト: `"Period"`）
- `ylabel`: Y 軸ラベル。省略時は変数名を使用。
- `on_length_mismatch`: 期間長が異なる場合の挙動。
  - `:truncate`（デフォルト）: 最短期間に合わせて切り捨てる。
  - `:error`: `ArgumentError` を発生させる。
- `kwargs...`: `Plots.jl` に直接渡す追加オプション

## エラー

- `results` が空の場合は `ArgumentError` が発生する。
- 存在しない変数名を指定した場合は `ArgumentError` が発生する。
  エラーメッセージには問題のある `SimulationResult` と利用可能な変数名が含まれる。
- `labels` の長さが `results` の長さと異なる場合は `ArgumentError` が発生する。
- `on_length_mismatch=:error` で期間長が異なる場合は `ArgumentError` が発生する。

## 例

```julia
# New Keynesian モデル: 需要ショック vs 金融政策ショック比較
m = NewKeynesianModel(1.0, 0.02, 0.99, 0.1, 1.5, 0.5, 0.02, 0.8, 0.5, 0.5)
irf_demand   = impulse_response(m; shock = :demand,   T = 20)
irf_monetary = impulse_response(m; shock = :monetary, T = 20)
sr_demand   = to_simulation_result(m, irf_demand,   "demand_shock")
sr_monetary = to_simulation_result(m, irf_monetary, "monetary_shock")

p = plot_comparison([sr_demand, sr_monetary]; var = "π",
                    labels = ["需要ショック", "金融政策ショック"],
                    title  = "インフレ率の比較")
```
"""
function plot_comparison(
    results::Vector{SimulationResult};
    var,
    labels::Union{Nothing, Vector{String}} = nothing,
    title::Union{Nothing, String} = nothing,
    xlabel::String = "Period",
    ylabel::Union{Nothing, String} = nothing,
    on_length_mismatch::Symbol = :truncate,
    kwargs...,
)
    isempty(results) && throw(ArgumentError("results が空です"))

    varname = String(var)

    if !isnothing(labels) && length(labels) != length(results)
        throw(
            ArgumentError(
                "labels の長さ ($(length(labels))) が results の長さ ($(length(results))) と異なります",
            ),
        )
    end

    missing_in = findall(r -> !haskey(r, varname), results)
    if !isempty(missing_in)
        details = join(
            [
                "results[$(i)]($(results[i].scenario_name)): 利用可能な変数 $(join(sort(variable_names(results[i])), ", "))"
                for i in missing_in
            ],
            "; ",
        )
        throw(ArgumentError("変数 \"$(varname)\" が見つかりません — $(details)"))
    end

    lengths = [nperiods(r) for r in results]
    if length(unique(lengths)) > 1
        if on_length_mismatch === :error
            throw(
                ArgumentError(
                    "期間長が一致しません: $(lengths). " *
                    "最短期間に合わせるには on_length_mismatch=:truncate を使用してください。",
                ),
            )
        end
    end
    T = minimum(lengths)

    title_str = isnothing(title) ? "Scenario Comparison: $(varname)" : title
    ylabel_str = isnothing(ylabel) ? varname : ylabel

    p = plot(; title = title_str, xlabel = xlabel, ylabel = ylabel_str, kwargs...)
    for (i, r) in enumerate(results)
        lbl = isnothing(labels) ? r.scenario_name : labels[i]
        plot!(p, 1:T, r[varname][1:T]; label = lbl)
    end
    return p
end

"""
    plot_irf(result::SimulationResult; vars=nothing, shock_size=nothing, title=nothing,
             xlabel="Period", ylabel="Log deviation from steady state", kwargs...)

`SimulationResult` に格納された IRF（インパルス応答）を、ゼロラインを含めて描画し、
`Plots.Plot` を返す。

通常の `plot_result` と異なり：
- y=0 のゼロライン（基準線）を点線で表示する
- x 軸は t=0（ショック発生時点）始まりで表示する
- Y 軸ラベルのデフォルトが「定常状態からの対数偏差」になる

IRF の出力は対数偏差（log deviation）であり、水準系列と異なる解釈が必要。
`plot_result` は水準系列の可視化に、`plot_irf` は IRF の可視化に使用すること。

## キーワード引数

- `vars`: プロットする変数名（`String` または `Symbol` の単体か配列）。
  省略または `nothing` を指定するとすべての変数をプロット。
- `shock_size`: ショックサイズ（数値）。指定するとタイトルに表示される。
  `result.metadata["shock_size"]` に設定しても同様に反映される。
  キーワード引数の指定が `metadata` より優先される。
- `title`: プロットタイトル。省略時は `"モデル名 — シナリオ名 (IRF)"` を使用。
  `shock_size` が判明している場合は `"... (IRF, shock = 値)"` を使用。
- `xlabel`: X 軸ラベル（デフォルト: `"Period"`）
- `ylabel`: Y 軸ラベル（デフォルト: `"Log deviation from steady state"`）
- `kwargs...`: `Plots.jl` に直接渡す追加オプション

## エラー

存在しない変数名を指定した場合は `ArgumentError` が発生する。
エラーメッセージには利用可能な変数名が含まれる。

## 例

```julia
m = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)
irf = impulse_response(m, 0.01)
sr = to_simulation_result(m, irf, "technology_shock")

# 全変数をプロット
p = plot_irf(sr)

# 特定の変数をプロット、ショックサイズをタイトルに表示
p = plot_irf(sr; vars = ["ŷ", "ĉ", "k̂"], shock_size = 0.01)

# metadata にショックサイズを格納する場合
sr_meta = SimulationResult(sr.model_name, sr.scenario_name, sr.variables,
                           Dict{String,Any}("shock_size" => 0.01))
p = plot_irf(sr_meta)
```
"""
function plot_irf(
    result::SimulationResult;
    vars = nothing,
    shock_size = nothing,
    title::Union{Nothing, String} = nothing,
    xlabel::String = "Period",
    ylabel::String = "Log deviation from steady state",
    kwargs...,
)
    requested = _resolve_plot_vars(result, vars)

    sz = if !isnothing(shock_size)
        shock_size
    elseif haskey(result.metadata, "shock_size")
        result.metadata["shock_size"]
    else
        nothing
    end

    title_str = if !isnothing(title)
        title
    elseif !isnothing(sz)
        "$(result.model_name) — $(result.scenario_name) (IRF, shock = $(sz))"
    else
        "$(result.model_name) — $(result.scenario_name) (IRF)"
    end

    T = nperiods(result)
    t = collect(0:(T - 1))

    p = plot(; title = title_str, xlabel = xlabel, ylabel = ylabel, kwargs...)
    for v in requested
        plot!(p, t, result[v]; label = v)
    end
    hline!(p, [0.0]; color = :black, linestyle = :dash, label = "")
    return p
end

"""
    _categorical_bands(times::Vector{Int}, values::Vector{T}) where {T} -> Vector{Tuple{Int,Int,T}}

`times`（昇順・重複なしを仮定）・`values`（同じ長さ）から、連続する同一値の区間
`(start, stop, value)` を抽出する共通ヘルパー。時系列のカテゴリ値（regime・label 等）を
帯（band）として描画するモデル固有可視化層（例: `capex_credit_cycle_visualization.jl` の
`funding_pressure_s` 帯グラフ）が利用する。値の再計算は行わない（読み取り専用）。
"""
function _categorical_bands(times::Vector{Int}, values::Vector{T}) where {T}
    bands = Tuple{Int, Int, T}[]
    isempty(times) && return bands

    run_start = times[1]
    run_value = values[1]
    prev_time = times[1]
    for i in 2:length(times)
        if values[i] != run_value || times[i] != prev_time + 1
            push!(bands, (run_start, prev_time, run_value))
            run_start = times[i]
            run_value = values[i]
        end
        prev_time = times[i]
    end
    push!(bands, (run_start, prev_time, run_value))
    return bands
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
