# モデル結果説明用プロンプト生成と mock 応答
# LLM APIは呼ばない。プロンプト生成と構造化 mock 応答のみを担う。

# docs/llm_safety.md セクション4.1 のシステム指示テンプレート
const _EXPLAIN_SYSTEM_PROMPT = """
あなたは動学的マクロ経済モデル（DME）の分析補助AIです。

【役割】
- モデルのシミュレーション結果を経済学的観点から説明・要約する
- モデルの仮定・限界・解釈上の注意点をユーザーに伝える
- 次に検討すべき分析の候補を提示する

【必ず守るルール】
1. すべての説明は「このモデルの仮定のもとでは」という文脈で行う
2. 断定的な将来予測を行わない（「〜するでしょう」「〜が予測されます」単独使用禁止）
3. 投資判断・売買推奨を行わない
4. 政策判断を断定しない（「〜すべき」はモデルシナリオの文脈でのみ使用可）
5. 根拠のない因果説明を行わない
6. 実データとモデル出力を区別して扱い、混同しない

【必ず含める情報】
- 使用モデルの種類と主要仮定
- パラメータ設定・ショック設定（該当する場合）
- データ出典（実データを参照する場合）
- モデルの限界・解釈上の注意点
- 免責文言（「本出力は投資判断・政策立案の根拠として使用することを意図していません」）
"""

const _DISCLAIMER_JA =
    "このシミュレーションは特定の仮定に基づく条件付き計算です。" *
    "実際の経済動向の予測ではありません。" *
    "本出力は投資判断・政策立案の根拠として使用することを意図していません。"

"""
    ExplainResultOutput

`explain_result` の出力型。LLMへ渡すプロンプトと構造化された応答を保持する。

`explain_result` はLLMを呼ばず、コンテキストから生成した mock 応答を返す。
実LLMで応答を得る場合は `prompt` を `complete_from_prompt` に渡す。

## フィールド
- `prompt::String` : LLMへ渡すプロンプト全文（システム指示＋ユーザープロンプト）
- `what_was_computed::String` : 何を計算したか
- `variable_movements::String` : 主要変数の動き
- `economic_interpretation::String` : 経済学的解釈
- `model_limitations::String` : モデルの仮定と限界
- `next_analyses::Vector{String}` : 次に見るべき分析候補（候補提示であり断定推奨ではない）
- `caveats::Vector{String}` : 免責・注意事項のリスト
- `disclaimer::String` : 免責文言
"""
struct ExplainResultOutput
    prompt::String
    what_was_computed::String
    variable_movements::String
    economic_interpretation::String
    model_limitations::String
    next_analyses::Vector{String}
    caveats::Vector{String}
    disclaimer::String
end

"""
    build_explain_prompt(ctx::AnalysisContext) -> String

`AnalysisContext` からモデル結果説明用のプロンプト全文を生成する。

システム安全指示（`docs/llm_safety.md` セクション4.1）と、コンテキストデータを埋め込んだ
ユーザープロンプトを結合して返す。実際のLLM呼び出しは行わない。

`docs_excerpts` が設定されている場合はプロンプトに含める。
`caveats` の内容は注意事項セクションとして埋め込む。
"""
function build_explain_prompt(ctx::AnalysisContext)::String
    meta = ctx.model_metadata
    srs = ctx.simulation_result_summary

    params_str = join(
        [
            "$(k)=$(round(v isa Number ? Float64(v) : 0.0; digits=4))" for
            (k, v) in meta.parameters
        ],
        ", ",
    )

    var_lines = String[]
    for (var_name, summary) in srs.variable_summaries
        line = _format_var_summary_for_prompt(var_name, summary)
        isnothing(line) || push!(var_lines, "  - " * line)
    end
    sort!(var_lines)
    vars_str = isempty(var_lines) ? "  （変数サマリーなし）" : join(var_lines, "\n")

    shock_str = isnothing(srs.shock_description) ? "（移行経路シミュレーション）" : srs.shock_description

    docs_section = _build_docs_section(ctx.docs_excerpts)

    caveat_items = vcat(
        ctx.caveats.model_limitations,
        ctx.caveats.data_limitations,
        ctx.caveats.interpretation_warnings,
    )
    caveats_str =
        isempty(caveat_items) ? "  （特になし）" : join(["  - $(c)" for c in caveat_items], "\n")

    user_prompt = """
以下のシミュレーション結果を経済学的に要約してください。

モデル: $(meta.model_name)
状態変数: $(join(String.(meta.state_variables), ", "))
操作変数: $(join(String.(meta.control_variables), ", "))
パラメータ: $(params_str)
ショック設定: $(shock_str)
シナリオ名: $(srs.scenario_name)
シミュレーション期間: $(srs.n_periods) 期$(docs_section)

主要変数サマリー:
$(vars_str)

注意事項・前提条件:
$(caveats_str)

要約の要件:
- 何を計算したかを明確に述べる
- 主要変数の動きを数値と経済学的意味を結びつけて説明する
- 経済学的解釈（なぜそのような動態になるか）を述べる
- モデルの仮定・限界を明示する
- 次に検討すべき分析候補を1〜3点提示する（候補の提示であり断定的推奨ではない）
- 以下の免責を必ず含める:
  「$(replace(_DISCLAIMER_JA, "\n" => " "))」
"""

    _EXPLAIN_SYSTEM_PROMPT * "\n---\n" * user_prompt
end

"""
    explain_result(ctx::AnalysisContext) -> ExplainResultOutput

`AnalysisContext` からモデル結果の説明プロンプトを生成し、構造化された mock 応答を返す。

LLM API は呼ばず、コンテキストデータからテンプレートベースの構造化 mock 応答を
生成する。出力には必ず `caveats` と `disclaimer` が含まれる。

実LLMで応答を得る場合は `build_explain_prompt` と `complete_from_prompt` を組み合わせる。
"""
function explain_result(ctx::AnalysisContext)::ExplainResultOutput
    meta = ctx.model_metadata
    srs = ctx.simulation_result_summary

    prompt = build_explain_prompt(ctx)

    # 何を計算したか
    shock_clause =
        isnothing(srs.shock_description) ? "移行経路シミュレーション" : "ショック「$(srs.shock_description)」"
    what_computed =
        "$(meta.model_name) を用いた $(srs.scenario_name) の計算です" *
        "（$(shock_clause)、期間: $(srs.n_periods) 期）。"

    # 主要変数の動き
    var_lines = String[]
    for (var_name, summary) in srs.variable_summaries
        line = _format_var_summary_for_output(var_name, summary)
        isnothing(line) || push!(var_lines, line)
    end
    sort!(var_lines)
    variable_movements = if isempty(var_lines)
        "変数サマリーが利用できません。"
    else
        "このモデルの仮定のもとでは、各変数は以下の動きを示しました" * "（数値は対数偏差または水準値）:\n" * join(var_lines, "\n")
    end

    # 経済学的解釈
    economic_interpretation = _mock_economic_interpretation(meta.model_name, srs)

    # モデルの限界
    limitations = vcat(ctx.caveats.model_limitations, ctx.caveats.interpretation_warnings)
    model_limitations = if isempty(limitations)
        "$(meta.model_name) は特定の経済学的仮定に基づく条件付きモデルです。" * "仮定が成立しない状況への適用には注意が必要です。"
    else
        join(["- $(l)" for l in limitations], "\n")
    end

    # 次の分析候補（候補提示であり断定推奨ではない）
    next_analyses = [
        "パラメータ感度分析: 主要パラメータ（例: 資本分配率・割引因子）を変化させた" * "比較シミュレーションを検討してください。",
        "別シナリオとの比較: 異なるショック規模・種類での IRF 比較を検討してください。",
        "実データとの参考比較: FRED 等から取得した実データとモデル出力を参考比較することで、" *
        "モデルの特性を把握できます（キャリブレーションなしの参考比較として）。",
    ]

    # 免責・注意事項
    all_caveats = vcat(
        ctx.caveats.model_limitations,
        ctx.caveats.data_limitations,
        ctx.caveats.interpretation_warnings,
    )
    if isempty(all_caveats)
        all_caveats = ["$(meta.model_name) は特定の仮定に基づく学術的なマクロ経済モデルです。"]
    end

    ExplainResultOutput(
        prompt,
        what_computed,
        variable_movements,
        economic_interpretation,
        model_limitations,
        next_analyses,
        all_caveats,
        _DISCLAIMER_JA,
    )
end

# === 実データ比較の自然言語説明プロンプト ===

# docs/llm_safety.md セクション4.1 のシステム指示テンプレート（比較分析版）
const _DATA_COMPARISON_SYSTEM_PROMPT = """
あなたは動学的マクロ経済モデル（DME）の分析補助AIです。

【役割】
- モデルのシミュレーション結果と実データの乖離を説明・整理する
- 乖離の大きい変数・小さい変数を比較指標に基づいて整理する
- モデルで説明しやすい点・しにくい点を分類して伝える
- 追加で確認すべきデータ系列の候補を提示する（断定的推奨ではなく候補として）
- モデルの仮定・限界・解釈上の注意点をユーザーに伝える

【必ず守るルール】
1. すべての説明は「このモデルの仮定のもとでは」という文脈で行う
2. 乖離の原因を断定しない（「〜が原因です」「〜によるものです」は禁止）
3. 投資判断・売買推奨を行わない
4. 政策判断を断定しない（「〜すべき」はモデルシナリオの文脈でのみ使用可）
5. 根拠のない因果説明を行わない
6. 実データとモデル出力を区別して扱い、混同しない
7. キャリブレーションなしの参考比較であることを明記する（キャリブレーションを行った場合を除く）

【必ず含める情報】
- 使用モデルと実データの出典・比較期間
- 比較指標（RMSE・MAE・相関係数等）と乖離の方向・大きさ
- モデルが説明しやすい点と説明しにくい点の整理
- 追加で確認すべきデータ系列の候補（候補提示であり断定推奨ではない）
- モデルの限界・解釈上の注意点
- 免責文言（「本出力は投資判断・政策立案の根拠として使用することを意図していません」）
"""

"""
    ExplainDataComparisonOutput

`explain_data_comparison` の出力型。LLMへ渡すプロンプトと構造化された応答を保持する。

`explain_data_comparison` はLLMを呼ばず、コンテキストから生成した mock 応答を返す。
実LLMで応答を得る場合は `prompt` を `complete_from_prompt` に渡す。

## フィールド
- `prompt::String` : LLMへ渡すプロンプト全文（システム指示＋ユーザープロンプト）
- `what_was_compared::String` : 何を比較したか（モデル・データ出典・期間）
- `large_deviation_variables::String` : 乖離の大きい変数とその指標値
- `model_explains_well::String` : モデルが説明しやすい点（乖離が小さい変数・動態）
- `model_explains_poorly::String` : モデルが説明しにくい点（乖離が大きい変数・構造的限界）
- `additional_series::Vector{String}` : 追加で見るべきデータ系列の候補（候補提示であり断定推奨ではない）
- `caveats::Vector{String}` : 免責・注意事項のリスト
- `disclaimer::String` : 免責文言
"""
struct ExplainDataComparisonOutput
    prompt::String
    what_was_compared::String
    large_deviation_variables::String
    model_explains_well::String
    model_explains_poorly::String
    additional_series::Vector{String}
    caveats::Vector{String}
    disclaimer::String
end

"""
    build_data_comparison_prompt(ctx::AnalysisContext) -> String

`AnalysisContext`（`data_comparison_summary` が設定済み）から、実データ比較説明用の
プロンプト全文を生成する。

システム安全指示（`docs/llm_safety.md` セクション4.1）と、比較指標・乖離の方向・大きさを
埋め込んだユーザープロンプトを結合して返す。実際のLLM呼び出しは行わない。

`data_comparison_summary` が `nothing` の場合は `ArgumentError` を送出する。
"""
function build_data_comparison_prompt(ctx::AnalysisContext)::String
    isnothing(ctx.data_comparison_summary) && throw(
        ArgumentError(
            "build_data_comparison_prompt requires data_comparison_summary in AnalysisContext. " *
            "Set data_comparison_summary when constructing AnalysisContext.",
        ),
    )

    meta = ctx.model_metadata
    srs = ctx.simulation_result_summary
    dcs = ctx.data_comparison_summary

    period_str = "期 $(dcs.comparison_period[1])〜$(dcs.comparison_period[2])"

    stats_lines = _format_deviation_statistics(dcs.deviation_statistics)
    stats_str =
        isempty(stats_lines) ? "  （乖離統計情報なし）" :
        join(["  - " * l for l in stats_lines], "\n")

    data_caveat_items = vcat(dcs.data_caveats, ctx.caveats.data_limitations)
    model_caveat_items =
        vcat(ctx.caveats.model_limitations, ctx.caveats.interpretation_warnings)
    all_caveat_items = vcat(data_caveat_items, model_caveat_items)
    caveats_str =
        isempty(all_caveat_items) ? "  （特になし）" :
        join(["  - $(c)" for c in all_caveat_items], "\n")

    docs_section = _build_docs_section(ctx.docs_excerpts)

    user_prompt = """
以下のモデルシミュレーション結果と実データの比較を分析してください。$(docs_section)

モデル: $(meta.model_name)
シナリオ名: $(srs.scenario_name)
シミュレーション期間: $(srs.n_periods) 期

実データ出典: $(dcs.data_source)
比較期間: $(period_str)

比較指標・乖離統計:
$(stats_str)

注意事項・前提条件:
$(caveats_str)

分析の要件:
- 何を比較したか（モデル・データ出典・比較期間・比較変数）を明確に述べる
- 比較指標（RMSE・MAE・相関係数等）の値を示しながら、どの変数で乖離が大きいかを整理する
- モデルが説明しやすい点を、乖離が小さい変数や動態に基づいて述べる
- モデルが説明しにくい点を、乖離が大きい変数・構造的限界に基づいて述べる（原因を断定しない）
- 追加で確認すべきデータ系列の候補を1〜3点提示する（候補の提示であり断定的推奨ではない）
- キャリブレーションを行っていない場合は参考比較である旨を明記する
- 以下の免責を必ず含める:
  「$(replace(_DISCLAIMER_JA, "\n" => " "))」
"""

    _DATA_COMPARISON_SYSTEM_PROMPT * "\n---\n" * user_prompt
end

"""
    explain_data_comparison(ctx::AnalysisContext) -> ExplainDataComparisonOutput

`AnalysisContext`（`data_comparison_summary` が設定済み）から、実データ比較の説明プロンプトを
生成し、構造化された mock 応答を返す。

LLM API は呼ばず、コンテキストデータからテンプレートベースの構造化 mock 応答を
生成する。出力には必ず `caveats` と `disclaimer` が含まれる。

`data_comparison_summary` が `nothing` の場合は `ArgumentError` を送出する。

実LLMで応答を得る場合は `build_data_comparison_prompt` と `complete_from_prompt` を組み合わせる。
"""
function explain_data_comparison(ctx::AnalysisContext)::ExplainDataComparisonOutput
    isnothing(ctx.data_comparison_summary) && throw(
        ArgumentError(
            "explain_data_comparison requires data_comparison_summary in AnalysisContext.",
        ),
    )

    meta = ctx.model_metadata
    srs = ctx.simulation_result_summary
    dcs = ctx.data_comparison_summary

    prompt = build_data_comparison_prompt(ctx)

    # 何を比較したか
    what_compared =
        "$(meta.model_name) のシミュレーション結果（シナリオ: $(srs.scenario_name)）" *
        " と 実データ（出典: $(dcs.data_source)）の比較です" *
        "（比較期間: 期$(dcs.comparison_period[1])〜$(dcs.comparison_period[2])、" *
        "シミュレーション期間: $(srs.n_periods) 期）。"

    # 乖離の大きい変数
    large_dev, well, poorly =
        _classify_deviation_variables(dcs.deviation_statistics, meta.model_name)

    # 追加で見るべき系列（候補提示）
    additional_series = _suggest_additional_series(meta.model_name, dcs)

    # 免責・注意事項
    all_caveats = vcat(
        dcs.data_caveats,
        ctx.caveats.model_limitations,
        ctx.caveats.data_limitations,
        ctx.caveats.interpretation_warnings,
    )
    if isempty(all_caveats)
        all_caveats =
            ["$(meta.model_name) は特定の仮定に基づく学術的なマクロ経済モデルです。", "キャリブレーションなしの参考比較として解釈してください。"]
    end

    ExplainDataComparisonOutput(
        prompt,
        what_compared,
        large_dev,
        well,
        poorly,
        additional_series,
        all_caveats,
        _DISCLAIMER_JA,
    )
end

# --- 内部ヘルパー ---

function _format_var_summary_for_prompt(var_name::String, summary)::Union{String, Nothing}
    if summary isa NamedTuple
        return "$(var_name): 初期値=$(round(summary.initial; digits=4)), " *
               "最終値=$(round(summary.final; digits=4)), " *
               "ピーク応答=$(round(summary.peak_response; digits=4))"
    elseif summary isa Dict
        initial = get(summary, "initial", get(summary, :initial, nothing))
        final_v = get(summary, "final", get(summary, :final, nothing))
        peak = get(summary, "peak_response", get(summary, :peak_response, nothing))
        (!isnothing(initial) && !isnothing(final_v)) || return nothing
        return "$(var_name): 初期値=$(round(initial; digits=4)), " *
               "最終値=$(round(final_v; digits=4))" *
               (isnothing(peak) ? "" : ", ピーク応答=$(round(peak; digits=4))")
    end
    nothing
end

function _format_var_summary_for_output(var_name::String, summary)::Union{String, Nothing}
    if summary isa NamedTuple
        sr_note = summary.sign_reversal ? "（符号反転あり）" : ""
        return "  $(var_name): 初期=$(round(summary.initial; digits=4)) → " *
               "最終=$(round(summary.final; digits=4)), " *
               "ピーク=$(round(summary.peak_response; digits=4))$(sr_note)"
    elseif summary isa Dict
        initial = get(summary, "initial", get(summary, :initial, nothing))
        final_v = get(summary, "final", get(summary, :final, nothing))
        peak = get(summary, "peak_response", get(summary, :peak_response, nothing))
        (!isnothing(initial) && !isnothing(final_v)) || return nothing
        return "  $(var_name): 初期=$(round(initial; digits=4)) → " *
               "最終=$(round(final_v; digits=4))" *
               (isnothing(peak) ? "" : ", ピーク=$(round(peak; digits=4))")
    end
    nothing
end

function _build_docs_section(docs_excerpts::Union{DocsExcerpts, Nothing})::String
    isnothing(docs_excerpts) && return ""
    de = docs_excerpts
    parts = String[]
    isempty(de.model_doc) || push!(parts, "モデル解説:\n$(de.model_doc)")
    isempty(de.output_guide) || push!(parts, "出力ガイド:\n$(de.output_guide)")
    isempty(de.caveats_doc) || push!(parts, "注意事項抜粋:\n$(de.caveats_doc)")
    isempty(parts) && return ""
    "\n\n参考ドキュメント抜粋:\n" * join(parts, "\n\n")
end

function _mock_economic_interpretation(
    model_name::String,
    srs::SimulationResultSummary,
)::String
    base = "このモデルの仮定のもとでは、"
    if !isnothing(srs.shock_description)
        base *= "$(srs.shock_description) に対してモデル変数が動学的に反応します。"
    else
        base *= "$(srs.scenario_name) シナリオにおいて、変数が移行経路に沿って定常状態へ収束します。"
    end
    base *
    " この動態は、代表的家計の最適化行動・市場均衡条件・資本蓄積の方程式から導かれるものであり、" *
    "実際の経済メカニズムを直接反映するものではありません" *
    "（$(model_name) の仮定の範囲内での解釈です）。" *
    " 経済的に根拠ある解釈を得るには、パラメータの感度分析や他モデルとの比較が推奨されます。"
end

# deviation_statistics の Dict を可読な行リストに変換する
function _format_deviation_statistics(stats::Dict{String, Any})::Vector{String}
    lines = String[]
    for (k, v) in stats
        if v isa Dict
            for (var, val) in v
                if val isa Number
                    push!(lines, "$(k) / $(var): $(round(Float64(val); digits=4))")
                else
                    push!(lines, "$(k) / $(var): $(val)")
                end
            end
        elseif v isa Number
            push!(lines, "$(k): $(round(Float64(v); digits=4))")
        else
            push!(lines, "$(k): $(v)")
        end
    end
    sort!(lines)
    lines
end

# deviation_statistics から変数を乖離の大きさで分類する（mock）
# 返り値: (large_deviation_text, explains_well_text, explains_poorly_text)
function _classify_deviation_variables(
    stats::Dict{String, Any},
    model_name::String,
)::Tuple{String, String, String}
    # 相関係数またはRMSEで変数を分類する
    corr_by_var =
        _extract_per_variable_metric(stats, ["correlation_by_variable", "corr_by_variable"])
    rmse_by_var =
        _extract_per_variable_metric(stats, ["rmse_by_variable", "RMSE_by_variable"])

    if !isempty(corr_by_var)
        high_corr = [(k, v) for (k, v) in corr_by_var if v >= 0.7]
        low_corr = [(k, v) for (k, v) in corr_by_var if v < 0.5]
        mid_corr = [(k, v) for (k, v) in corr_by_var if 0.5 <= v < 0.7]

        large_dev = if isempty(low_corr) && isempty(mid_corr)
            "このモデルの仮定のもとでは、すべての変数で比較的高い相関が観察されました。"
        else
            low_names = join([k for (k, _) in vcat(low_corr, mid_corr)], "、")
            "相関係数が低い変数（参考）: $(low_names)。乖離の原因は断定できません。"
        end

        well = if isempty(high_corr)
            "$(model_name) の仮定のもとでは、全変数で相関が低く、定性的な動態の説明にも限界がある可能性があります。"
        else
            high_names =
                join(["$(k)（相関: $(round(v; digits=3))）" for (k, v) in high_corr], "、")
            "このモデルの仮定のもとでは、以下の変数で実データと比較的高い相関が観察されました（参考）: $(high_names)。"
        end

        poorly = if isempty(low_corr)
            "$(model_name) の仮定のもとでは、特定の変数で顕著な乖離は観察されませんでした（相関係数に基づく参考評価）。"
        else
            low_names =
                join(["$(k)（相関: $(round(v; digits=3))）" for (k, v) in low_corr], "、")
            "このモデルの仮定のもとでは、以下の変数で乖離が大きく観察されました（参考）: $(low_names)。" *
            " ただし乖離の原因は断定できません。モデルの構造的な仮定（例: 閉鎖経済・代表的家計）が" *
            "影響している可能性を考慮してください。"
        end

        return (large_dev, well, poorly)
    end

    if !isempty(rmse_by_var)
        sorted = sort(collect(rmse_by_var); by = x -> x[2], rev = true)
        n = length(sorted)
        large_vars = sorted[1:min(2, n)]
        small_vars = sorted[max(1, n - 1):n]

        large_names =
            join(["$(k)（RMSE: $(round(v; digits=4))）" for (k, v) in large_vars], "、")
        small_names =
            join(["$(k)（RMSE: $(round(v; digits=4))）" for (k, v) in small_vars], "、")

        large_dev = "RMSEが大きい変数（参考）: $(large_names)。乖離の原因は断定できません。"
        well = "このモデルの仮定のもとでは、$(small_names) でRMSEが比較的小さく観察されました（参考）。"
        poorly =
            "このモデルの仮定のもとでは、$(large_names) でRMSEが大きく観察されました（参考）。" *
            " モデルの構造的な仮定が乖離に寄与している可能性がありますが、原因の断定は行いません。"

        return (large_dev, well, poorly)
    end

    # 統計情報が十分でない場合のデフォルト
    generic =
        "比較指標（RMSE・MAE・相関係数等）の変数別内訳が提供されていないため、" *
        "変数ごとの詳細な分類は行えません。`deviation_statistics` に変数別統計を追加することを検討してください。"
    well = "$(model_name) の仮定のもとでは、モデルが捉えやすい動態は定性的な方向性の一致（景気拡張・収縮）です。"
    poorly = "$(model_name) の仮定のもとでは、摩擦・不確実性・名目硬直性などを含む動態の説明には限界があります。"
    return (generic, well, poorly)
end

# stats から変数別メトリクスを Dict{String, Float64} として抽出する
function _extract_per_variable_metric(
    stats::Dict{String, Any},
    keys::Vector{String},
)::Dict{String, Float64}
    for k in keys
        if haskey(stats, k) && stats[k] isa Dict
            result = Dict{String, Float64}()
            for (var, val) in stats[k]
                val isa Number && (result[string(var)] = Float64(val))
            end
            isempty(result) || return result
        end
    end
    Dict{String, Float64}()
end

# モデルと比較結果に基づき、追加で見るべきデータ系列の候補を提示する（候補提示のみ）
function _suggest_additional_series(
    model_name::String,
    dcs::DataComparisonSummary,
)::Vector{String}
    suggestions = [
        "異なる期間・周波数のデータ（例: 四半期→年次集計）との比較を検討してください（参考）。",
        "複数の実データ出典（例: FRED・e-Stat）を参照し、データ間の差異を確認することを検討してください（参考）。",
        "モデルの主要パラメータ（例: 資本分配率・割引因子）を変化させた感度分析を検討してください（参考）。",
    ]
    if occursin("RBC", model_name) || occursin("Ramsey", model_name)
        push!(suggestions, "全要素生産性（TFP）や投資系列との追加比較を検討してください（参考）。")
    elseif occursin("ISLM", model_name) || occursin("NewKeynesian", model_name)
        push!(suggestions, "名目金利・物価水準などの名目変数系列との追加比較を検討してください（参考）。")
    elseif occursin("MundellFleming", model_name)
        push!(suggestions, "為替レート・経常収支などの国際収支系列との追加比較を検討してください（参考）。")
    end
    # データ出典ごとの追加提案
    if occursin("FRED", dcs.data_source)
        push!(suggestions, "FRED の改訂履歴（vintage data）を確認し、リアルタイムデータとの差異も考慮してください（参考）。")
    end
    suggestions
end
