"""
    SimulationResult

シミュレーション結果を保持するモデル横断的な標準データ構造。

## フィールド
- `model_name::String`    : モデル名（例: "Ramsey Model", "RBC Model"）
- `scenario_name::String` : シナリオ名または計算種別（例: "find_path", "shock"）
- `variables::Dict{String, Vector{Float64}}` : 変数系列（キー: 変数名, 値: 時系列データ）
- `metadata::Dict{String, Any}` : メタデータ（モデルパラメータ等を格納）

## 変数名の規則
各モデルの元の変数名をキーとして使用する。
- Ramseyモデル: "K", "C"
- RBCモデル（find_path）: "A", "r", "w", "L", "K", "Y", "C"
- RBCモデル（shock）: "â", "r̂", "ŵ", "l̂", "k̂", "ŷ", "ĉ"

## メタデータの規則
`to_simulation_result` で生成した場合、`metadata` には以下が自動設定される:
- `"parameters"` : モデルパラメータの NamedTuple
"""
struct SimulationResult
    model_name::String
    scenario_name::String
    variables::Dict{String, Vector{Float64}}
    metadata::Dict{String, Any}
end

"""
    SimulationResult(model_name, scenario_name, variables)

`metadata` を省略できる便利コンストラクタ。
"""
SimulationResult(
    model_name::String,
    scenario_name::String,
    variables::Dict{String, Vector{Float64}},
) = SimulationResult(model_name, scenario_name, variables, Dict{String, Any}())

"""
    result[key]

`variables` から変数系列を取得する。
"""
Base.getindex(r::SimulationResult, key::String) = r.variables[key]

"""
    haskey(result, key)

`variables` に指定した変数名が含まれているか確認する。
"""
Base.haskey(r::SimulationResult, key::String) = haskey(r.variables, key)

"""
    variable_names(result) -> Vector{String}

`SimulationResult` が保持する変数名のリストを返す。
"""
variable_names(r::SimulationResult) = collect(keys(r.variables))

"""
    nperiods(result) -> Int

時系列の長さ（期間数）を返す。変数が存在しない場合は 0 を返す。
"""
nperiods(r::SimulationResult) =
    isempty(r.variables) ? 0 : length(first(values(r.variables)))

"""
    to_simulation_result(m::AbstractMacroModel, result::NamedTuple, scenario::String) -> SimulationResult

任意モデルの NamedTuple 出力（`transition_path` / `simulate` / `impulse_response` など）を
`SimulationResult` に変換する。NamedTuple のキー（Symbol）は String に変換される。
"""
function to_simulation_result(m::AbstractMacroModel, result::NamedTuple, scenario::String)
    vars = Dict{String, Vector{Float64}}(String(k) => v for (k, v) in pairs(result))
    meta = Dict{String, Any}("parameters" => parameters(m))
    SimulationResult(model_name(m), scenario, vars, meta)
end

"""
    to_simulation_result(m::RBCModel, result::Dict{String, Vector{Float64}}, scenario::String) -> SimulationResult

RBCモデルの内部関数 `find_path` / `shock` の Dict 出力を `SimulationResult` に変換する。
後方互換のために維持。新しいコードでは `transition_path` / `impulse_response` を使用すること。
"""
function to_simulation_result(
    m::RBCModel,
    result::Dict{String, Vector{Float64}},
    scenario::String,
)
    meta = Dict{String, Any}("parameters" => parameters(m))
    SimulationResult(model_name(m), scenario, copy(result), meta)
end

"""
    _coerce_values(values) -> Vector{Float64}

`Union{Float64,Missing}` の値ベクトルを `Vector{Float64}` に変換する。
欠損値は `NaN` に置換される。
"""
_coerce_values(values::Vector{Union{Float64, Missing}}) =
    Float64[ismissing(v) ? NaN : v for v in values]

"""
    _series_meta(s::DataSeries) -> Dict{String, Any}

`DataSeries` から `SimulationResult` 用のメタデータ Dict を構築する内部ヘルパー。
"""
function _series_meta(s::DataSeries)
    Dict{String, Any}(
        "source" => s.source,
        "frequency" => string(s.frequency),
        "unit" => s.unit,
        "series_id" => s.id,
        "dates" => s.dates,
        "transformations" => get(s.metadata, "transformations", String[]),
    )
end

"""
    to_simulation_result(series::DataSeries, scenario_name="actual_data") -> SimulationResult

`DataSeries` を `SimulationResult` 互換形式に変換する。

実データを既存の `plot_result` / `summarize_result` などの可視化・分析 API に接続するために使用する。

## 変換規則
- `model_name`    : `series.source`（データ出所）
- `scenario_name` : 引数で指定（デフォルト `"actual_data"`）
- `variables`     : `{ series.id => values }` の 1 要素 Dict。欠損値は `NaN` に変換。
- `metadata`      : 以下のキーを含む
  - `"source"`          : データ出所
  - `"frequency"`       : 観測頻度（文字列）
  - `"unit"`            : 単位
  - `"series_id"`       : 元の系列 id
  - `"dates"`           : 日付ラベルのベクタ
  - `"transformations"` : 変換履歴（`preprocess` 関数が追記）

## 使用例
```julia
s = DataSeries(id="FRED_GDPC1", name="Real GDP", source="FRED",
               frequency=Quarterly, unit="Billions of Chained 2017 Dollars",
               dates=["2020-Q1","2020-Q2"], values=[19254.0, 17302.0])
r = to_simulation_result(s)
plot_result(r, "FRED_GDPC1")
```
"""
function to_simulation_result(s::DataSeries, scenario_name::String = "actual_data")
    vars = Dict{String, Vector{Float64}}(s.id => _coerce_values(s.values))
    meta = _series_meta(s)
    SimulationResult(s.source, scenario_name, vars, meta)
end

"""
    to_simulation_result(dataset::MacroDataset, scenario_name="actual_data") -> SimulationResult

`MacroDataset`（複数系列）を `SimulationResult` 互換形式に変換する。

各系列が `variables` の 1 エントリとなり、系列ごとのメタデータが
`metadata["series_metadata"]` に格納される。

## 変換規則
- `model_name`    : `dataset.name`（データセット名）
- `scenario_name` : 引数で指定（デフォルト `"actual_data"`）
- `variables`     : `{ series.id => values }` の多要素 Dict。欠損値は `NaN` に変換。
- `metadata`      : 以下のキーを含む
  - `"dataset_name"`     : データセット名
  - `"series_metadata"`  : 系列 id → 各系列のメタデータ Dict（source / frequency / unit / dates / transformations）

## 使用例
```julia
ds = MacroDataset("FRED Macro Dataset", [gdp_series, cpi_series])
r = to_simulation_result(ds)
plot_result(r, "FRED_GDPC1")
```
"""
function to_simulation_result(ds::MacroDataset, scenario_name::String = "actual_data")
    vars = Dict{String, Vector{Float64}}(
        id => _coerce_values(s.values) for (id, s) in ds.series
    )
    series_meta = Dict{String, Any}(id => _series_meta(s) for (id, s) in ds.series)
    meta = Dict{String, Any}("dataset_name" => ds.name, "series_metadata" => series_meta)
    SimulationResult(ds.name, scenario_name, vars, meta)
end

# 1変数の統計サマリーを計算する内部ヘルパー
function _var_summary(v::Vector{Float64})
    n = length(v)
    if n == 0
        return (
            initial = 0.0,
            final = 0.0,
            max = 0.0,
            min = 0.0,
            range = 0.0,
            argmax = 0,
            argmin = 0,
            peak_response = 0.0,
            sign_reversal = false,
        )
    end
    mx = maximum(v)
    mn = minimum(v)
    am = argmax(v)
    an = argmin(v)
    peak = abs(mx) >= abs(mn) ? mx : mn
    sr = mx > 0.0 && mn < 0.0
    (
        initial = v[1],
        final = v[n],
        max = mx,
        min = mn,
        range = mx - mn,
        argmax = am,
        argmin = an,
        peak_response = peak,
        sign_reversal = sr,
    )
end

"""
    summarize_result(result::SimulationResult) -> Dict{String, Any}

`SimulationResult` から変数ごとの統計サマリーを抽出する。

## 戻り値

`Dict{String, Any}` で以下のキーを持つ:
- `"model_name"`    : モデル名（String）
- `"scenario_name"` : シナリオ名（String）
- `"nperiods"`      : 期間数（Int）
- `"variables"`     : `Dict{String, NamedTuple}` — 変数名 → 変数サマリー

### 変数サマリーの NamedTuple フィールド

| フィールド | 型 | 説明 |
|---|---|---|
| `initial` | Float64 | 初期値（第1期） |
| `final` | Float64 | 最終値（最終期） |
| `max` | Float64 | 最大値 |
| `min` | Float64 | 最小値 |
| `range` | Float64 | 変化幅（max - min） |
| `argmax` | Int | 最大値の時点（1始まり） |
| `argmin` | Int | 最小値の時点（1始まり） |
| `peak_response` | Float64 | 絶対値最大の値（符号付き）。IRF結果で有用。 |
| `sign_reversal` | Bool | 系列が正と負の両方を取るか。IRF結果で有用。 |

## 使用例

```julia
m = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)
irf = impulse_response(m, 0.01)
sr = to_simulation_result(m, irf, "technology_shock")
summary = summarize_result(sr)

summary["model_name"]              # "RBC Model"
summary["nperiods"]                # 150
summary["variables"]["ŷ"].max      # ŷ の最大値
summary["variables"]["ŷ"].argmax   # ŷ が最大になる期
summary["variables"]["k̂"].sign_reversal  # 資本が符号反転するか
```
"""
function summarize_result(result::SimulationResult)
    vars_summary =
        Dict{String, NamedTuple}(k => _var_summary(v) for (k, v) in result.variables)
    Dict{String, Any}(
        "model_name" => result.model_name,
        "scenario_name" => result.scenario_name,
        "nperiods" => nperiods(result),
        "variables" => vars_summary,
    )
end
