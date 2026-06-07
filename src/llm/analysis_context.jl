# AnalysisContext: LLMへ渡す構造化コンテキスト

"""
    ModelMetadata

モデルの識別情報と変数定義を保持する構造体。

## フィールド
- `model_name::String` : モデルの識別名（例: `"RBC Model"`）
- `state_variables::Vector{Symbol}` : 状態変数のリスト（例: `[:K, :A]`）
- `control_variables::Vector{Symbol}` : 操作変数のリスト（例: `[:C, :L]`）
- `parameters::Dict{String, Any}` : パラメータ名と値（JSON変換可能な形式）
"""
struct ModelMetadata
    model_name::String
    state_variables::Vector{Symbol}
    control_variables::Vector{Symbol}
    parameters::Dict{String, Any}
end

"""
    ModelMetadata(m::AbstractMacroModel) -> ModelMetadata

`AbstractMacroModel` から `ModelMetadata` を作成する。
"""
function ModelMetadata(m::AbstractMacroModel)
    params = parameters(m)
    ModelMetadata(
        model_name(m),
        state_variables(m),
        control_variables(m),
        Dict{String, Any}(String(k) => v for (k, v) in pairs(params)),
    )
end

"""
    SimulationResultSummary

`SimulationResult` から生成した数値サマリー。元の時系列全体ではなく統計量を保持する。

## フィールド
- `scenario_name::String` : シナリオ名
- `n_periods::Int` : シミュレーション期間数
- `variable_summaries::Dict{String, Any}` : 変数ごとの統計サマリー（`summarize_result` 出力の variables フィールド）
- `shock_description::Union{String, Nothing}` : ショックの種類と大きさの説明（IRFの場合）
"""
struct SimulationResultSummary
    scenario_name::String
    n_periods::Int
    variable_summaries::Dict{String, Any}
    shock_description::Union{String, Nothing}
end

"""
    SimulationResultSummary(result::SimulationResult; shock_description=nothing) -> SimulationResultSummary

`SimulationResult` から `SimulationResultSummary` を作成する。
"""
function SimulationResultSummary(
    result::SimulationResult;
    shock_description::Union{String, Nothing} = nothing,
)
    s = summarize_result(result)
    SimulationResultSummary(
        result.scenario_name,
        nperiods(result),
        s["variables"],
        shock_description,
    )
end

"""
    DataComparisonSummary

実データとモデル出力の比較結果サマリー。実データ比較を行った場合にのみ設定する。

## フィールド
- `data_source::String` : 実データの出典（例: `"FRED/GDPC1"`）
- `comparison_period::Tuple{Int, Int}` : 比較対象期間（開始期, 終了期）
- `deviation_statistics::Dict{String, Any}` : 乖離の統計量（平均・最大・方向等）
- `data_caveats::Vector{String}` : データ固有の注意事項
"""
struct DataComparisonSummary
    data_source::String
    comparison_period::Tuple{Int, Int}
    deviation_statistics::Dict{String, Any}
    data_caveats::Vector{String}
end

"""
    Caveats

LLM の出力に含めるべき免責・注意事項。

## フィールド
- `model_limitations::Vector{String}` : モデル仮定の限界リスト
- `data_limitations::Vector{String}` : データ制約・信頼性の注意事項
- `interpretation_warnings::Vector{String}` : 解釈上の警告（例: 対数偏差であること）
"""
struct Caveats
    model_limitations::Vector{String}
    data_limitations::Vector{String}
    interpretation_warnings::Vector{String}
end

"""
    Caveats() -> Caveats

空の `Caveats` を作成する。
"""
Caveats() = Caveats(String[], String[], String[])

"""
    DocsExcerpts

LLM の文脈として提供するドキュメント抜粋。RAG 層が検索・選択して渡すことを想定する。

## フィールド
- `model_doc::String` : `docs/models/` の関連セクション抜粋
- `output_guide::String` : `docs/simulation_outputs.md` の変数解釈セクション抜粋
- `caveats_doc::String` : モデルの限界・注意事項の抜粋
"""
struct DocsExcerpts
    model_doc::String
    output_guide::String
    caveats_doc::String
end

"""
    DocsExcerpts() -> DocsExcerpts

空の `DocsExcerpts` を作成する。
"""
DocsExcerpts() = DocsExcerpts("", "", "")

"""
    AnalysisContext

LLMへ渡す構造化コンテキスト。モデルメタ情報・シミュレーション結果サマリー・
実データ比較サマリー・注意事項・ドキュメント抜粋をまとめた入力構造体。

LLM API は呼ばない。`to_dict` / `to_json` / `to_compact_dict` で
Dict または JSON 文字列に変換してプロンプトへ埋め込む。

## フィールド
- `model_metadata::ModelMetadata` : モデルの識別情報と変数定義
- `simulation_result_summary::SimulationResultSummary` : シミュレーション結果の統計サマリー
- `data_comparison_summary::Union{DataComparisonSummary, Nothing}` : 実データ比較サマリー（任意）
- `caveats::Caveats` : 免責・注意事項
- `docs_excerpts::Union{DocsExcerpts, Nothing}` : ドキュメント抜粋（任意）

## 使用例

```julia
rbc = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)
irf = impulse_response(rbc, 0.01)
sr  = to_simulation_result(rbc, irf, "technology_shock")

ctx = AnalysisContext(
    rbc, sr;
    shock_description = "1% positive technology shock",
    caveats = Caveats(
        ["Closed economy", "Representative agent"],
        String[],
        ["Variables are log deviations from steady state"],
    ),
)

d    = to_dict(ctx)           # Dict{String, Any}
json = to_json(ctx)           # JSON 文字列
cd   = to_compact_dict(ctx)   # トークン量を抑えたコンパクト版
```
"""
struct AnalysisContext
    model_metadata::ModelMetadata
    simulation_result_summary::SimulationResultSummary
    data_comparison_summary::Union{DataComparisonSummary, Nothing}
    caveats::Caveats
    docs_excerpts::Union{DocsExcerpts, Nothing}
end

"""
    AnalysisContext(m::AbstractMacroModel, result::SimulationResult; kwargs...) -> AnalysisContext

`AbstractMacroModel` と `SimulationResult` から `AnalysisContext` を作成する。

## キーワード引数
- `shock_description::Union{String, Nothing} = nothing` : ショックの説明（IRFの場合）
- `caveats::Caveats = Caveats()` : 免責・注意事項
- `data_comparison_summary::Union{DataComparisonSummary, Nothing} = nothing` : 実データ比較サマリー
- `docs_excerpts::Union{DocsExcerpts, Nothing} = nothing` : ドキュメント抜粋
"""
function AnalysisContext(
    m::AbstractMacroModel,
    result::SimulationResult;
    shock_description::Union{String, Nothing} = nothing,
    caveats::Caveats = Caveats(),
    data_comparison_summary::Union{DataComparisonSummary, Nothing} = nothing,
    docs_excerpts::Union{DocsExcerpts, Nothing} = nothing,
)
    AnalysisContext(
        ModelMetadata(m),
        SimulationResultSummary(result; shock_description = shock_description),
        data_comparison_summary,
        caveats,
        docs_excerpts,
    )
end

# NamedTuple を Dict{String, Any} に変換するヘルパー
function _nt_to_dict(nt::NamedTuple)
    Dict{String, Any}(String(k) => v for (k, v) in pairs(nt))
end

"""
    to_dict(meta::ModelMetadata) -> Dict{String, Any}

`ModelMetadata` を `Dict{String, Any}` に変換する。
"""
function to_dict(meta::ModelMetadata)
    Dict{String, Any}(
        "model_name" => meta.model_name,
        "state_variables" => String.(meta.state_variables),
        "control_variables" => String.(meta.control_variables),
        "parameters" => meta.parameters,
    )
end

"""
    to_dict(summary::SimulationResultSummary) -> Dict{String, Any}

`SimulationResultSummary` を `Dict{String, Any}` に変換する。
変数サマリーの `NamedTuple` はネストされた `Dict` に展開される。
"""
function to_dict(summary::SimulationResultSummary)
    var_dicts = Dict{String, Any}()
    for (k, v) in summary.variable_summaries
        var_dicts[k] = v isa NamedTuple ? _nt_to_dict(v) : v
    end
    d = Dict{String, Any}(
        "scenario_name" => summary.scenario_name,
        "n_periods" => summary.n_periods,
        "variable_summaries" => var_dicts,
    )
    if !isnothing(summary.shock_description)
        d["shock_description"] = summary.shock_description
    end
    d
end

"""
    to_dict(dcs::DataComparisonSummary) -> Dict{String, Any}

`DataComparisonSummary` を `Dict{String, Any}` に変換する。
"""
function to_dict(dcs::DataComparisonSummary)
    Dict{String, Any}(
        "data_source" => dcs.data_source,
        "comparison_period" => [dcs.comparison_period[1], dcs.comparison_period[2]],
        "deviation_statistics" => dcs.deviation_statistics,
        "data_caveats" => dcs.data_caveats,
    )
end

"""
    to_dict(c::Caveats) -> Dict{String, Any}

`Caveats` を `Dict{String, Any}` に変換する。
"""
function to_dict(c::Caveats)
    Dict{String, Any}(
        "model_limitations" => c.model_limitations,
        "data_limitations" => c.data_limitations,
        "interpretation_warnings" => c.interpretation_warnings,
    )
end

"""
    to_dict(de::DocsExcerpts) -> Dict{String, Any}

`DocsExcerpts` を `Dict{String, Any}` に変換する。
"""
function to_dict(de::DocsExcerpts)
    Dict{String, Any}(
        "model_doc" => de.model_doc,
        "output_guide" => de.output_guide,
        "caveats_doc" => de.caveats_doc,
    )
end

"""
    to_dict(ctx::AnalysisContext) -> Dict{String, Any}

`AnalysisContext` を `Dict{String, Any}` に変換する。
`Nothing` のオプショナルフィールド（`data_comparison_summary`, `docs_excerpts`）は出力に含まれない。
"""
function to_dict(ctx::AnalysisContext)
    d = Dict{String, Any}(
        "model_metadata" => to_dict(ctx.model_metadata),
        "simulation_result_summary" => to_dict(ctx.simulation_result_summary),
        "caveats" => to_dict(ctx.caveats),
    )
    if !isnothing(ctx.data_comparison_summary)
        d["data_comparison_summary"] = to_dict(ctx.data_comparison_summary)
    end
    if !isnothing(ctx.docs_excerpts)
        d["docs_excerpts"] = to_dict(ctx.docs_excerpts)
    end
    d
end

"""
    to_json(ctx::AnalysisContext) -> String

`AnalysisContext` を JSON 文字列に変換する。
プロンプトへの埋め込みやファイル保存に使用する。
"""
function to_json(ctx::AnalysisContext)
    JSON3.write(to_dict(ctx))
end

"""
    to_compact_dict(ctx::AnalysisContext) -> Dict{String, Any}

`AnalysisContext` をトークン量を抑えたコンパクトな `Dict{String, Any}` に変換する。

通常の `to_dict` との違い:
- 変数サマリーは `initial`, `final`, `peak_response`, `sign_reversal` の4フィールドのみ保持
- 空文字列のみの `docs_excerpts` は省略される
"""
function to_compact_dict(ctx::AnalysisContext)
    d = to_dict(ctx)
    vars = d["simulation_result_summary"]["variable_summaries"]
    compact_vars = Dict{String, Any}()
    for (k, v) in vars
        if v isa Dict
            compact_vars[k] = Dict{String, Any}(
                "initial" => get(v, "initial", nothing),
                "final" => get(v, "final", nothing),
                "peak_response" => get(v, "peak_response", nothing),
                "sign_reversal" => get(v, "sign_reversal", nothing),
            )
        else
            compact_vars[k] = v
        end
    end
    d["simulation_result_summary"]["variable_summaries"] = compact_vars
    if haskey(d, "docs_excerpts")
        de = d["docs_excerpts"]
        if all(v == "" for v in values(de))
            delete!(d, "docs_excerpts")
        end
    end
    d
end
