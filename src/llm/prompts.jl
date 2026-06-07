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

const _DISCLAIMER_JA = "このシミュレーションは特定の仮定に基づく条件付き計算です。" *
    "実際の経済動向の予測ではありません。" *
    "本出力は投資判断・政策立案の根拠として使用することを意図していません。"

"""
    ExplainResultOutput

`explain_result` の出力型。LLMへ渡すプロンプトと構造化された応答を保持する。

Phase 6 初期はLLMを呼ばず、コンテキストから生成した mock 応答を返す。
実LLM接続への差し替えは後続の接続実装 Issue にて行う。

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
    srs  = ctx.simulation_result_summary

    params_str = join(["$(k)=$(round(v isa Number ? Float64(v) : 0.0; digits=4))"
                       for (k, v) in meta.parameters], ", ")

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
    caveats_str = isempty(caveat_items) ?
        "  （特になし）" :
        join(["  - $(c)" for c in caveat_items], "\n")

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

Phase 6 初期実装では LLM API を呼ばず、コンテキストデータからテンプレートベースの
構造化 mock 応答を生成する。出力には必ず `caveats` と `disclaimer` が含まれる。

実LLM応答への差し替えは後続の LLM 接続実装 Issue にて行う。
"""
function explain_result(ctx::AnalysisContext)::ExplainResultOutput
    meta = ctx.model_metadata
    srs  = ctx.simulation_result_summary

    prompt = build_explain_prompt(ctx)

    # 何を計算したか
    shock_clause = isnothing(srs.shock_description) ?
        "移行経路シミュレーション" : "ショック「$(srs.shock_description)」"
    what_computed = "$(meta.model_name) を用いた $(srs.scenario_name) の計算です" *
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
        "このモデルの仮定のもとでは、各変数は以下の動きを示しました" *
        "（数値は対数偏差または水準値）:\n" * join(var_lines, "\n")
    end

    # 経済学的解釈
    economic_interpretation = _mock_economic_interpretation(meta.model_name, srs)

    # モデルの限界
    limitations = vcat(ctx.caveats.model_limitations, ctx.caveats.interpretation_warnings)
    model_limitations = if isempty(limitations)
        "$(meta.model_name) は特定の経済学的仮定に基づく条件付きモデルです。" *
        "仮定が成立しない状況への適用には注意が必要です。"
    else
        join(["- $(l)" for l in limitations], "\n")
    end

    # 次の分析候補（候補提示であり断定推奨ではない）
    next_analyses = [
        "パラメータ感度分析: 主要パラメータ（例: 資本分配率・割引因子）を変化させた" *
            "比較シミュレーションを検討してください。",
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

# --- 内部ヘルパー ---

function _format_var_summary_for_prompt(var_name::String, summary)::Union{String, Nothing}
    if summary isa NamedTuple
        return "$(var_name): 初期値=$(round(summary.initial; digits=4)), " *
               "最終値=$(round(summary.final; digits=4)), " *
               "ピーク応答=$(round(summary.peak_response; digits=4))"
    elseif summary isa Dict
        initial  = get(summary, "initial",       get(summary, :initial,       nothing))
        final_v  = get(summary, "final",         get(summary, :final,         nothing))
        peak     = get(summary, "peak_response", get(summary, :peak_response, nothing))
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
        initial  = get(summary, "initial",       get(summary, :initial,       nothing))
        final_v  = get(summary, "final",         get(summary, :final,         nothing))
        peak     = get(summary, "peak_response", get(summary, :peak_response, nothing))
        (!isnothing(initial) && !isnothing(final_v)) || return nothing
        return "  $(var_name): 初期=$(round(initial; digits=4)) → " *
               "最終=$(round(final_v; digits=4))" *
               (isnothing(peak) ? "" : ", ピーク=$(round(peak; digits=4))")
    end
    nothing
end

function _build_docs_section(docs_excerpts::Union{DocsExcerpts, Nothing})::String
    isnothing(docs_excerpts) && return ""
    de   = docs_excerpts
    parts = String[]
    isempty(de.model_doc)    || push!(parts, "モデル解説:\n$(de.model_doc)")
    isempty(de.output_guide) || push!(parts, "出力ガイド:\n$(de.output_guide)")
    isempty(de.caveats_doc)  || push!(parts, "注意事項抜粋:\n$(de.caveats_doc)")
    isempty(parts) && return ""
    "\n\n参考ドキュメント抜粋:\n" * join(parts, "\n\n")
end

function _mock_economic_interpretation(model_name::String, srs::SimulationResultSummary)::String
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
