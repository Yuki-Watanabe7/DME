# compare.jl: 実データとモデル結果の比較API

"""
    ComparisonResult

`compare_with_data` が返す比較結果。変数マッピングに基づく乖離指標を保持する。

## フィールド
- `model_name::String`    : モデル側の名称
- `data_source::String`   : 実データ側の名称
- `mapping::Dict{String, String}` : 変数名マッピング（モデル変数 => データ変数）
- `comparison_period::Tuple{Int, Int}` : 実際に比較した期間インデックス（開始, 終了）
- `variables::Dict{String, NamedTuple}` : モデル変数名 → 変数別比較指標

### 変数別比較指標（`NamedTuple`）のフィールド

| フィールド | 型 | 説明 |
|---|---|---|
| `model_variable` | String | モデル側変数名 |
| `data_variable` | String | データ側変数名 |
| `n_periods` | Int | 比較に使用した期間数 |
| `level_diff` | Vector{Float64} | 水準差（model − data）。NaNが含まれうる |
| `pct_diff` | Vector{Float64} | 百分率差（(model − data) / abs(data) × 100）。data ≈ 0 またはNaNの場合はNaN |
| `rmse` | Float64 | RMSE（有効ペアのみで計算） |
| `mae` | Float64 | MAE（有効ペアのみで計算） |
| `correlation` | Float64 | ピアソン相関係数（有効ペア < 2 または定数系列の場合はNaN） |
| `mean_level_diff` | Float64 | 水準差の平均（有効ペアのみ） |
| `max_abs_level_diff` | Float64 | 水準差の絶対値最大（有効ペアのみ） |
"""
struct ComparisonResult
    model_name::String
    data_source::String
    mapping::Dict{String, String}
    comparison_period::Tuple{Int, Int}
    variables::Dict{String, NamedTuple}
end

# NaNを含むペアを除いた有効インデックスを返す内部ヘルパー
function _valid_pairs(
    m_vals::Vector{Float64},
    d_vals::Vector{Float64},
)
    n = length(m_vals)
    idx = [i for i in 1:n if !isnan(m_vals[i]) && !isnan(d_vals[i])]
    m_vals[idx], d_vals[idx]
end

# 変数ペアの乖離指標を計算する内部ヘルパー
function _compute_variable_metrics(
    mv::String,
    dv::String,
    m_vals::Vector{Float64},
    d_vals::Vector{Float64},
)
    n = length(m_vals)
    level_diff = m_vals .- d_vals

    pct_diff = Vector{Float64}(undef, n)
    for i in 1:n
        if isnan(m_vals[i]) || isnan(d_vals[i]) || abs(d_vals[i]) < 1e-10
            pct_diff[i] = NaN
        else
            pct_diff[i] = (m_vals[i] - d_vals[i]) / abs(d_vals[i]) * 100.0
        end
    end

    mv_valid, dv_valid = _valid_pairs(m_vals, d_vals)
    n_valid = length(mv_valid)

    if n_valid == 0
        return (
            model_variable = mv,
            data_variable = dv,
            n_periods = n,
            level_diff = level_diff,
            pct_diff = pct_diff,
            rmse = NaN,
            mae = NaN,
            correlation = NaN,
            mean_level_diff = NaN,
            max_abs_level_diff = NaN,
        )
    end

    diff = mv_valid .- dv_valid
    rmse = sqrt(sum(diff .^ 2) / n_valid)
    mae = sum(abs.(diff)) / n_valid
    mean_ld = sum(diff) / n_valid
    max_abs_ld = maximum(abs.(diff))

    corr = if n_valid < 2
        NaN
    else
        m_mean = sum(mv_valid) / n_valid
        d_mean = sum(dv_valid) / n_valid
        num = sum((mv_valid .- m_mean) .* (dv_valid .- d_mean))
        m_std = sqrt(sum((mv_valid .- m_mean) .^ 2))
        d_std = sqrt(sum((dv_valid .- d_mean) .^ 2))
        (m_std < 1e-14 || d_std < 1e-14) ? NaN : num / (m_std * d_std)
    end

    (
        model_variable = mv,
        data_variable = dv,
        n_periods = n,
        level_diff = level_diff,
        pct_diff = pct_diff,
        rmse = rmse,
        mae = mae,
        correlation = corr,
        mean_level_diff = mean_ld,
        max_abs_level_diff = max_abs_ld,
    )
end

"""
    compare_with_data(
        model_result::SimulationResult,
        data_result::SimulationResult;
        mapping::Dict{String, String},
    ) -> ComparisonResult

`SimulationResult` 同士を変数マッピングに基づいて比較し、乖離指標を計算する。

## 引数
- `model_result` : モデルシミュレーション結果
- `data_result`  : 実データ（`to_simulation_result` で変換済み）
- `mapping`      : 変数名の対応（モデル変数名 => データ変数名）。必須キーワード引数。

## 期間合わせ
両者の `nperiods` の小さい方を比較長とする（頻度変換は呼び出し前に完了していること）。

## エラー
- `mapping` のモデル変数名が `model_result` に存在しない場合は `ArgumentError`
- `mapping` のデータ変数名が `data_result` に存在しない場合は `ArgumentError`

## 使用例
```julia
rbc = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)
irf = impulse_response(rbc, 0.01)
model_sr = to_simulation_result(rbc, irf, "technology_shock")

data_sr = to_simulation_result(gdp_series, "actual_data")

cr = compare_with_data(model_sr, data_sr; mapping=Dict("ŷ" => "FRED_GDPC1"))

cr.variables["ŷ"].rmse        # RMSE
cr.variables["ŷ"].correlation  # 相関係数
```
"""
function compare_with_data(
    model_result::SimulationResult,
    data_result::SimulationResult;
    mapping::Dict{String, String},
)
    for (mv, dv) in mapping
        if !haskey(model_result, mv)
            throw(
                ArgumentError(
                    "変数 \"$mv\" がモデル結果に存在しません。" *
                    "利用可能な変数: $(sort(variable_names(model_result)))",
                ),
            )
        end
        if !haskey(data_result, dv)
            throw(
                ArgumentError(
                    "変数 \"$dv\" が実データ結果に存在しません。" *
                    "利用可能な変数: $(sort(variable_names(data_result)))",
                ),
            )
        end
    end

    n = min(nperiods(model_result), nperiods(data_result))

    vars = Dict{String, NamedTuple}()
    for (mv, dv) in mapping
        m_vals = model_result[mv][1:n]
        d_vals = data_result[dv][1:n]
        vars[mv] = _compute_variable_metrics(mv, dv, m_vals, d_vals)
    end

    ComparisonResult(
        model_result.model_name,
        data_result.model_name,
        copy(mapping),
        (1, n),
        vars,
    )
end

"""
    to_data_comparison_summary(
        cr::ComparisonResult;
        caveats::Vector{String} = String[],
    ) -> DataComparisonSummary

`ComparisonResult` を `DataComparisonSummary` に変換する。
`AnalysisContext` に渡すための接続層として使用する。

## 引数
- `cr`       : `compare_with_data` の戻り値
- `caveats`  : データ固有の注意事項（省略可）

## 使用例
```julia
cr  = compare_with_data(model_sr, data_sr; mapping=Dict("ŷ" => "FRED_GDPC1"))
dcs = to_data_comparison_summary(cr; caveats=["対数偏差と水準値の比較"])

ctx = AnalysisContext(rbc, model_sr; data_comparison_summary=dcs)
```
"""
function to_data_comparison_summary(
    cr::ComparisonResult;
    caveats::Vector{String} = String[],
)
    dev_stats = Dict{String, Any}()
    for (mv, metrics) in cr.variables
        dev_stats[mv] = Dict{String, Any}(
            "data_variable" => metrics.data_variable,
            "rmse" => metrics.rmse,
            "mae" => metrics.mae,
            "correlation" => metrics.correlation,
            "mean_level_diff" => metrics.mean_level_diff,
            "max_abs_level_diff" => metrics.max_abs_level_diff,
        )
    end
    DataComparisonSummary(cr.data_source, cr.comparison_period, dev_stats, caveats)
end
