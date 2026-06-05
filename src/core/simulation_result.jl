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
SimulationResult(model_name::String, scenario_name::String,
                 variables::Dict{String, Vector{Float64}}) =
    SimulationResult(model_name, scenario_name, variables, Dict{String, Any}())

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
    to_simulation_result(m::RamseyModel, result::NamedTuple, scenario::String) -> SimulationResult

Ramseyモデルの出力（`find_path` / `simulate_by_nlvar` の NamedTuple）を
`SimulationResult` に変換する。
"""
function to_simulation_result(m::RamseyModel, result::NamedTuple, scenario::String)
    vars = Dict{String, Vector{Float64}}(
        "C" => result.C,
        "K" => result.K,
    )
    meta = Dict{String, Any}("parameters" => parameters(m))
    SimulationResult(model_name(m), scenario, vars, meta)
end

"""
    to_simulation_result(m::RBCModel, result::Dict{String, Vector{Float64}}, scenario::String) -> SimulationResult

RBCモデルの出力（`find_path` / `shock` の Dict）を `SimulationResult` に変換する。
"""
function to_simulation_result(m::RBCModel, result::Dict{String, Vector{Float64}}, scenario::String)
    meta = Dict{String, Any}("parameters" => parameters(m))
    SimulationResult(model_name(m), scenario, copy(result), meta)
end
